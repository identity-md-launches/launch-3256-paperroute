// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PaperRoute} from "../../src/PaperRoute.sol";
import {IMDDaily} from "../mocks/IMDDaily.sol";
import {AcceptingReceiver, GasBurningReceiver, RevertingReceiver} from "../mocks/Mocks.sol";

/// @notice Runs against a fork of Ethereum mainnet with the real IMD token and The IMD Daily.
/// @dev Set PAPER_ROUTE_FORK_URL to a mainnet archive RPC to run these; without it every test here is
///      skipped so the suite passes offline. The block is pinned so the results are reproducible:
///      at block 26,406,400 The IMD Daily has 23 issues, and the fork is warped back into issue 23's window.
contract PaperRouteForkTest is Test {
    uint256 internal constant FORK_BLOCK = 26_406_400;
    IERC20Metadata internal constant IMD = IERC20Metadata(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    IMDDaily internal constant DAILY = IMDDaily(0xB8FD2b7fb37cbf03A26B4c4688eD5ccE86C0a9c5);

    uint256 internal constant EDITION = 0.125 ether;
    uint256 internal constant COPY = 0.1 ether;
    uint256 internal constant TIP = 0.025 ether;

    PaperRoute internal route;
    address internal vault;
    uint256 internal issueId;
    uint256 internal closesAt;

    // Unique labels: the usual "alice" test address already carries code on mainnet (an EIP-7702
    // delegation that rejects ERC-1155 copies), which is exactly the case deliver() skips.
    address internal alice = makeAddr("paper-route-fork-reader-1");
    address internal bob = makeAddr("paper-route-fork-reader-2");
    address internal courier = makeAddr("paper-route-fork-courier");
    address internal constant FORGE_ALICE = 0x328809Bc894f92807417D2dAD6b7C998c1aFdac6;

    function setUp() public {
        string memory url = vm.envOr("PAPER_ROUTE_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true, "PAPER_ROUTE_FORK_URL not set");
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);

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
        // Issue 22 is closed at this time, so only one open issue exists on the fork; the rule is checked
        // through dueStatus for the next id, which is what a next-day issue would be.
        subscribeAs(alice, 2);
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(courier);
        route.deliver(issueId, list);
        (bool isDue, PaperRoute.SkipReason reason) = route.dueStatus(alice, issueId + 1);
        assertFalse(isDue);
        assertEq(uint8(reason), uint8(PaperRoute.SkipReason.TooSoon));
        vm.warp(block.timestamp + 20 hours);
        (isDue,) = route.dueStatus(alice, issueId + 1);
        assertTrue(isDue);
        (isDue, reason) = route.dueStatus(alice, issueId);
        assertFalse(isDue);
        assertEq(uint8(reason), uint8(PaperRoute.SkipReason.AlreadyDelivered));
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
        if (FORGE_ALICE.code.length == 0) {
            vm.skip(true, "address no longer delegated at this block");
            return;
        }
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
