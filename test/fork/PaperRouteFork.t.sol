// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PaperRoute} from "../../src/PaperRoute.sol";
import {IMDDaily} from "../mocks/IMDDaily.sol";
import {
    AcceptingReceiver,
    GasBurningReceiver,
    RevertingReceiver,
    ReentrantReceiver
} from "../mocks/Mocks.sol";
import {GuardProbeReceiver, SwitchableReceiver} from "../mocks/AdversarialMocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Runs against a fork of Ethereum mainnet with the real IMD token and The IMD Daily.
/// @dev MAINNET_RPC_URL may be a URL or socket path. Skip only when it is absent. The fork always
///      starts at the assignment's pinned block; mint-window tests change only its local timestamp.
contract PaperRouteForkTest is Test {
    uint256 internal constant FORK_BLOCK = 26_406_531;
    IERC20Metadata internal constant IMD = IERC20Metadata(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    IMDDaily internal constant DAILY = IMDDaily(0xB8FD2b7fb37cbf03A26B4c4688eD5ccE86C0a9c5);

    uint256 internal constant EDITION = 0.125 ether;
    uint256 internal constant COPY = 0.1 ether;
    uint256 internal constant TIP = 0.025 ether;

    PaperRoute internal route;
    address internal vault;
    uint256 internal issueId;
    uint256 internal closesAt;
    uint256 internal snapshotTimestamp;

    // Unique labels: the usual "alice" test address already carries code on mainnet (an EIP-7702
    // delegation that rejects ERC-1155 copies), which is exactly the case deliver() skips.
    address internal alice = makeAddr("paper-route-fork-reader-1");
    address internal bob = makeAddr("paper-route-fork-reader-2");
    address internal courier = makeAddr("paper-route-fork-courier");
    address internal constant FORGE_ALICE = 0x328809Bc894f92807417D2dAD6b7C998c1aFdac6;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        assertEq(block.number, FORK_BLOCK);
        assertEq(block.chainid, 1);
        snapshotTimestamp = vm.getBlockTimestamp();

        route = new PaperRoute();
        vault = address(DAILY.vault());
        issueId = DAILY.issueCount();
        assertEq(issueId, 23, "issue count at the pinned block");
        uint256 publishedAt;
        (, publishedAt, closesAt,,) = DAILY.issueStatus(issueId);
        vm.warp(publishedAt + 1 hours);
        assertTrue(DAILY.isAvailable(issueId), "issue open after warping into its window");
    }

    function fund(address who, uint256 amount) internal {
        deal(address(IMD), who, amount);
        vm.prank(who);
        IMD.approve(address(route), type(uint256).max);
    }

    function subscribeAs(address who, uint256 editions) internal {
        fund(who, editions * EDITION);
        vm.prank(who);
        route.subscribe(editions);
    }

    function test_fork_liveContractsMatchAssumptions() public view {
        assertGt(address(IMD).code.length, 0);
        assertGt(address(DAILY).code.length, 0);
        assertGt(vault.code.length, 0);
        assertEq(DAILY.name(), "The IMD Daily");
        assertEq(IMD.decimals(), 18);
        assertEq(IMD.symbol(), "IMD");
        assertEq(DAILY.PRICE(), route.COPY_PRICE());
        assertEq(DAILY.PAYMENT_TOKEN(), address(route.IMD()));
        assertEq(DAILY.MINT_WINDOW(), 24 hours);
    }

    function test_fork_subscribeDeliverCancelToTheWei() public {
        subscribeAs(alice, 40);
        assertEq(IMD.balanceOf(address(route)), 5 ether);

        uint256 vaultBefore = IMD.balanceOf(vault);
        uint256 collectedBefore = DAILY.totalCollected();
        uint256 supplyBefore = DAILY.totalSupply(issueId);

        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(courier);
        address[] memory delivered = route.deliver(issueId, list);

        assertEq(delivered.length, 1);
        assertEq(DAILY.balanceOf(alice, issueId), 1, "one real copy");
        assertEq(DAILY.totalSupply(issueId), supplyBefore + 1);
        assertEq(DAILY.totalCollected(), collectedBefore + COPY);
        assertEq(IMD.balanceOf(vault), vaultBefore + COPY, "0.1 IMD reached the publisher's vault");
        assertEq(IMD.balanceOf(courier), TIP);
        assertEq(IMD.balanceOf(address(route)), 39 * EDITION);
        assertEq(route.editionsLeft(alice), 39);
        assertEq(IMD.allowance(address(route), address(DAILY)), 0);

        // One copy an issue.
        vm.prank(courier);
        assertEq(route.deliver(issueId, list).length, 0);
        assertEq(DAILY.balanceOf(alice, issueId), 1);

        // Refund after partial use.
        vm.prank(alice);
        route.cancel();
        assertEq(IMD.balanceOf(alice), 39 * EDITION);
        assertEq(IMD.balanceOf(address(route)), 0);
    }

    function test_fork_contractReceiverAndBadReceiversInOneBatch() public {
        AcceptingReceiver good = new AcceptingReceiver();
        RevertingReceiver bad = new RevertingReceiver();
        GasBurningReceiver burner = new GasBurningReceiver();
        subscribeAs(alice, 2);
        subscribeAs(address(bad), 2);
        subscribeAs(address(good), 2);
        subscribeAs(address(burner), 2);
        subscribeAs(bob, 2);
        uint256 vaultBefore = IMD.balanceOf(vault);

        address[] memory list = new address[](5);
        list[0] = alice;
        list[1] = address(bad);
        list[2] = address(good);
        list[3] = address(burner);
        list[4] = bob;
        vm.prank(courier);
        address[] memory delivered = route.deliver{gas: 3_000_000}(issueId, list);

        assertEq(delivered.length, 3);
        assertEq(delivered[0], alice);
        assertEq(delivered[1], address(good));
        assertEq(delivered[2], bob);
        assertEq(DAILY.balanceOf(address(good), issueId), 1);
        assertEq(DAILY.balanceOf(address(bad), issueId), 0);
        assertEq(DAILY.balanceOf(address(burner), issueId), 0);
        assertEq(route.editionsLeft(address(bad)), 2, "nothing charged");
        assertEq(route.editionsLeft(address(burner)), 2, "nothing charged");
        assertEq(IMD.balanceOf(vault), vaultBefore + 3 * COPY);
        assertEq(IMD.balanceOf(courier), 3 * TIP);
        assertEq(IMD.balanceOf(address(route)), route.reservedBalance());
        assertEq(IMD.allowance(address(route), address(DAILY)), 0);
    }

    function test_fork_twentyHourRuleAcrossIssues() public {
        subscribeAs(alice, 3);
        address[] memory list = new address[](1);
        list[0] = alice;
        uint256 vaultBefore = IMD.balanceOf(vault);
        vm.prank(courier);
        route.deliver(issueId, list);
        uint256 deliveredAt = vm.getBlockTimestamp();

        // Publish only on the local fork, using the real publisher authorization and collection code.
        // No storage override, etching or mocked collection response is used to open the second issue.
        IMDDaily.IssueInput memory input = DAILY.getIssue(issueId).content;
        vm.prank(DAILY.PUBLISHER());
        uint256 second = DAILY.createIssue(input);
        assertEq(second, issueId + 1);
        assertTrue(DAILY.isAvailable(second));
        vm.warp(deliveredAt + 20 hours - 1);
        (bool isDue, PaperRoute.SkipReason reason) = route.dueStatus(alice, second);
        assertFalse(isDue);
        assertEq(uint8(reason), uint8(PaperRoute.SkipReason.TooSoon));
        assertEq(route.due(second, 0, 25).length, 0);
        vm.prank(courier);
        assertEq(route.deliver(second, list).length, 0);
        assertEq(IMD.balanceOf(courier), TIP);

        vm.warp(deliveredAt + 20 hours);
        (isDue,) = route.dueStatus(alice, second);
        assertTrue(isDue);
        assertEq(route.due(second, 0, 25), list);
        vm.prank(courier);
        assertEq(route.deliver(second, list), list);
        assertEq(DAILY.balanceOf(alice, second), 1);
        assertEq(route.editionsLeft(alice), 1);
        assertEq(IMD.balanceOf(vault), vaultBefore + 2 * COPY);
        assertEq(IMD.balanceOf(courier), 2 * TIP);
        (isDue, reason) = route.dueStatus(alice, issueId);
        assertFalse(isDue);
        assertEq(uint8(reason), uint8(PaperRoute.SkipReason.AlreadyDelivered));
    }

    function test_fork_callbackCannotEnterAnyMutatingFunction() public {
        GuardProbeReceiver probe = new GuardProbeReceiver(route);
        subscribeAs(address(probe), 3);
        fund(address(probe), EDITION);
        uint256 vaultBefore = IMD.balanceOf(vault);
        address[] memory readers = new address[](1);
        readers[0] = address(probe);
        vm.prank(courier);
        assertEq(route.deliver(issueId, readers), readers);
        assertEq(probe.attempts(), 3);
        assertEq(probe.successes(), 0);
        assertEq(probe.cancelError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(probe.subscribeError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(probe.deliverError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(DAILY.balanceOf(address(probe), issueId), 1);
        assertEq(route.editionsLeft(address(probe)), 2);
        assertEq(IMD.balanceOf(address(probe)), EDITION);
        assertEq(IMD.balanceOf(vault), vaultBefore + COPY);
        assertEq(IMD.balanceOf(courier), TIP);
        assertEq(IMD.balanceOf(address(route)), 2 * EDITION);
        assertEq(IMD.allowance(address(route), address(DAILY)), 0);
    }

    function test_fork_acceptingEIP7702DelegateReceivesCopyAtItsOwnAccount() public {
        GuardProbeReceiver implementation = new GuardProbeReceiver(route);
        // Only the synthetic reader is delegated. IMD, the collection and its vault keep live code/state.
        vm.etch(alice, abi.encodePacked(hex"ef0100", address(implementation)));
        subscribeAs(alice, 2);
        fund(alice, EDITION);
        uint256 vaultBefore = IMD.balanceOf(vault);
        address[] memory readers = new address[](1);
        readers[0] = alice;
        vm.prank(courier);
        assertEq(route.deliver(issueId, readers), readers);
        GuardProbeReceiver delegated = GuardProbeReceiver(alice);
        assertEq(delegated.attempts(), 3);
        assertEq(delegated.successes(), 0);
        assertEq(delegated.cancelError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(delegated.subscribeError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(delegated.deliverError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(implementation.attempts(), 0);
        assertEq(DAILY.balanceOf(alice, issueId), 1);
        assertEq(DAILY.balanceOf(address(implementation), issueId), 0);
        assertEq(IMD.balanceOf(vault), vaultBefore + COPY);
        assertEq(IMD.balanceOf(courier), TIP);
        assertEq(route.editionsLeft(alice), 1);
        vm.prank(alice);
        route.cancel();
        assertEq(IMD.balanceOf(alice), 2 * EDITION);
        assertEq(IMD.balanceOf(address(route)), 0);
    }

    function test_fork_bubblingReentrantCancelIsSkipped() public {
        _bubblingReentry(0);
    }

    function test_fork_bubblingReentrantSubscribeIsSkipped() public {
        _bubblingReentry(1);
    }

    function test_fork_bubblingReentrantDeliverIsSkipped() public {
        _bubblingReentry(2);
    }

    function _bubblingReentry(uint8 mode) internal {
        ReentrantReceiver receiver = new ReentrantReceiver(route);
        receiver.setMode(mode);
        subscribeAs(address(receiver), 2);
        fund(address(receiver), EDITION);
        subscribeAs(alice, 1);
        uint256 vaultBefore = IMD.balanceOf(vault);
        uint256 supplyBefore = DAILY.totalSupply(issueId);
        uint256 collectedBefore = DAILY.totalCollected();
        address[] memory readers = new address[](2);
        readers[0] = address(receiver);
        readers[1] = alice;
        vm.expectEmit(true, true, true, true, address(route));
        emit PaperRoute.Skipped(issueId, address(receiver), PaperRoute.SkipReason.MintFailed);
        vm.prank(courier);
        address[] memory delivered = route.deliver{gas: 2_000_000}(issueId, readers);
        assertEq(delivered.length, 1);
        assertEq(delivered[0], alice);
        assertEq(DAILY.balanceOf(address(receiver), issueId), 0);
        assertEq(DAILY.balanceOf(alice, issueId), 1);
        assertEq(DAILY.totalSupply(issueId), supplyBefore + 1);
        assertEq(DAILY.totalCollected(), collectedBefore + COPY);
        assertEq(IMD.balanceOf(vault), vaultBefore + COPY);
        assertEq(IMD.balanceOf(courier), TIP);
        assertEq(route.editionsLeft(address(receiver)), 2);
        assertEq(route.lastIssue(address(receiver)), 0);
        assertEq(route.lastDeliveredAt(address(receiver)), 0);
        assertEq(IMD.balanceOf(address(route)), 2 * EDITION);
        assertEq(IMD.allowance(address(route), address(DAILY)), 0);
        vm.prank(address(receiver));
        route.cancel();
        assertEq(IMD.balanceOf(address(receiver)), 3 * EDITION);
    }

    function test_fork_failedMintCanBeRetriedWithoutChargingTwice() public {
        SwitchableReceiver receiver = new SwitchableReceiver();
        subscribeAs(address(receiver), 2);
        uint256 vaultBefore = IMD.balanceOf(vault);
        address[] memory readers = new address[](1);
        readers[0] = address(receiver);
        vm.prank(courier);
        assertEq(route.deliver(issueId, readers).length, 0);
        assertEq(IMD.balanceOf(vault), vaultBefore);
        assertEq(route.due(issueId, 0, 25), readers);
        assertEq(route.lastDeliveredAt(address(receiver)), 0);
        receiver.setRejecting(false);
        vm.prank(bob);
        assertEq(route.deliver(issueId, readers), readers);
        assertEq(IMD.balanceOf(vault), vaultBefore + COPY);
        assertEq(IMD.balanceOf(bob), TIP);
        assertEq(IMD.balanceOf(courier), 0);
        assertEq(DAILY.balanceOf(address(receiver), issueId), 1);
        assertEq(route.editionsLeft(address(receiver)), 1);
        vm.prank(courier);
        assertEq(route.deliver(issueId, readers).length, 0);
        assertEq(IMD.allowance(address(route), address(DAILY)), 0);
    }

    function test_fork_duplicateAddressesAndCompetingCourierAreNotDoublePaid() public {
        subscribeAs(alice, 2);
        address[] memory readers = new address[](3);
        readers[0] = alice;
        readers[1] = alice;
        readers[2] = alice;
        vm.prank(courier);
        address[] memory delivered = route.deliver(issueId, readers);
        assertEq(delivered.length, 1);
        assertEq(delivered[0], alice);
        vm.prank(bob);
        assertEq(route.deliver(issueId, readers).length, 0);
        assertEq(DAILY.balanceOf(alice, issueId), 1);
        assertEq(route.editionsLeft(alice), 1);
        assertEq(IMD.balanceOf(courier), TIP);
        assertEq(IMD.balanceOf(bob), 0);
    }

    function test_fork_donationSurvivesDeliveryAndAllRefunds() public {
        subscribeAs(alice, 2);
        subscribeAs(bob, 3);
        fund(courier, 7);
        vm.prank(courier);
        IMD.transfer(address(route), 7);
        address[] memory readers = new address[](1);
        readers[0] = alice;
        vm.prank(courier);
        route.deliver(issueId, readers);
        assertEq(route.surplus(), 7);
        vm.prank(alice);
        route.cancel();
        vm.prank(bob);
        route.cancel();
        assertEq(IMD.balanceOf(alice), EDITION);
        assertEq(IMD.balanceOf(bob), 3 * EDITION);
        assertEq(IMD.balanceOf(courier), TIP);
        assertEq(IMD.balanceOf(address(route)), 7);
        assertEq(route.reservedEditions(), 0);
        assertEq(route.subscriberCount(), 0);
        assertEq(route.surplus(), 7);
    }

    function test_fork_cancelAtOriginalSnapshotTimestamp() public {
        // Read state at exactly the supplied block and its original timestamp as well as the
        // locally warped mint-window scenarios. Cancellation is independent of issue availability.
        vm.warp(snapshotTimestamp);
        assertEq(block.number, FORK_BLOCK);
        subscribeAs(alice, 40);
        vm.prank(alice);
        route.cancel();
        assertEq(IMD.balanceOf(alice), 5 ether);
        assertEq(IMD.balanceOf(address(route)), 0);
        assertEq(route.reservedBalance(), 0);
    }

    function test_fork_insufficientGasLeavesReaderForAnotherCourier() public {
        subscribeAs(alice, 1);
        address[] memory readers = new address[](1);
        readers[0] = alice;
        vm.expectCall(address(DAILY), abi.encodeWithSelector(DAILY.mint.selector), uint64(0));
        vm.prank(courier);
        assertEq(route.deliver{gas: 550_000}(issueId, readers).length, 0);
        assertEq(route.editionsLeft(alice), 1);
        assertEq(DAILY.balanceOf(alice, issueId), 0);
        assertEq(IMD.balanceOf(courier), 0);
        assertEq(IMD.allowance(address(route), address(DAILY)), 0);
    }

    function test_fork_closedAndUnknownIssuesRevert() public {
        subscribeAs(alice, 2);
        address[] memory list = new address[](1);
        list[0] = alice;

        vm.prank(courier);
        vm.expectRevert(abi.encodeWithSelector(PaperRoute.IssueNotOpen.selector, issueId - 1));
        route.deliver(issueId - 1, list);

        vm.prank(courier);
        vm.expectRevert(abi.encodeWithSelector(PaperRoute.IssueNotOpen.selector, issueId + 1));
        route.deliver(issueId + 1, list);

        vm.warp(closesAt);
        assertFalse(DAILY.isAvailable(issueId));
        vm.prank(courier);
        vm.expectRevert(abi.encodeWithSelector(PaperRoute.IssueNotOpen.selector, issueId));
        route.deliver(issueId, list);
        assertEq(route.due(issueId, 0, 10).length, 0);

        // Cancel still works with the paper closed.
        vm.prank(alice);
        route.cancel();
        assertEq(IMD.balanceOf(alice), 2 * EDITION);
    }

    function test_fork_delegatedAccountThatRejectsCopiesIsSkippedUncharged() public {
        // A live EIP-7702 account whose delegate has no ERC-1155 receiver: due by Paper Route's rules,
        // but the real mint reverts, so it is skipped with nothing charged and can still cancel.
        assertEq(FORGE_ALICE.code.length, 23, "EIP-7702 designation must exist at the pinned block");
        assertEq(bytes3(FORGE_ALICE.code), hex"ef0100");
        subscribeAs(FORGE_ALICE, 2);
        subscribeAs(bob, 2);
        address[] memory list = new address[](2);
        list[0] = FORGE_ALICE;
        list[1] = bob;
        vm.prank(courier);
        address[] memory delivered = route.deliver(issueId, list);
        assertEq(delivered.length, 1);
        assertEq(delivered[0], bob);
        assertEq(route.editionsLeft(FORGE_ALICE), 2);
        assertEq(IMD.balanceOf(courier), TIP);
        vm.prank(FORGE_ALICE);
        route.cancel();
        assertEq(IMD.balanceOf(FORGE_ALICE), 2 * EDITION);
    }

    function test_fork_dueListMatchesDelivery() public {
        subscribeAs(alice, 1);
        subscribeAs(bob, 1);
        address[] memory dueNow = route.due(issueId, 0, 25);
        assertEq(dueNow.length, 2);
        vm.prank(courier);
        address[] memory delivered = route.deliver(issueId, dueNow);
        assertEq(delivered.length, 2);
        assertEq(route.due(issueId, 0, 25).length, 0);
        assertEq(route.subscriberCount(), 0);
    }
}
