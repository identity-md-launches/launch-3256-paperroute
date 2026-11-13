// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PaperRouteBase} from "./PaperRouteBase.t.sol";
import {PaperRoute} from "../src/PaperRoute.sol";
import {IMDDaily} from "./mocks/IMDDaily.sol";
import {MockIMD, AcceptingReceiver, RevertingReceiver, GasBurningReceiver} from "./mocks/Mocks.sol";
import {GuardProbeReceiver, SwitchableReceiver} from "./mocks/AdversarialMocks.sol";

/// @dev Drives Paper Route with subscribers of every kind, issues published over time, donations and
///      deliveries, and keeps ghost totals the invariants are checked against.
contract PaperRouteHandler is Test {
    PaperRoute public route;
    MockIMD public imd;
    IMDDaily public daily;
    address public constant PUBLISHER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;

    address[] public actors;
    address[3] public couriers;
    SwitchableReceiver public switchable;
    GuardProbeReceiver public probe;
    uint256 public donated;
    uint256 public deliveries;
    uint256 public tipsPaid;
    uint256 public copiesPaid;
    mapping(address => mapping(uint256 => bool)) public got;
    mapping(address => uint256) public lastAt;
    mapping(address => uint256) public latestIssue;
    mapping(address => uint256) public purchased;
    mapping(address => uint256) public refunded;
    mapping(address => uint256) public copies;
    mapping(address => uint256) public credit;
    mapping(address => uint256) public courierTips;
    uint256 public totalPurchased;
    uint256 public totalRefunded;
    uint256 public mintCalls;

    constructor(PaperRoute route_, MockIMD imd_, IMDDaily daily_) {
        route = route_;
        imd = imd_;
        daily = daily_;
        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));
        actors.push(address(new AcceptingReceiver()));
        actors.push(address(new RevertingReceiver()));
        actors.push(address(new GasBurningReceiver()));
        probe = new GuardProbeReceiver(route_);
        switchable = new SwitchableReceiver();
        actors.push(address(probe));
        actors.push(address(switchable));
        imd.mint(address(probe), 0.125 ether); // Enough for its attempted reentrant subscribe.
        for (uint256 i; i < couriers.length; ++i) {
            couriers[i] = makeAddr(string.concat("courier", vm.toString(i)));
        }
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            imd.approve(address(route), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function subscribe(uint256 who, uint256 editions) external {
        address actor = actors[who % actors.length];
        editions = bound(editions, 1, 60);
        imd.mint(actor, editions * 0.125 ether);
        vm.prank(actor);
        route.subscribe(editions);
        credit[actor] += editions;
        purchased[actor] += editions;
        totalPurchased += editions;
    }

    function cancel(uint256 who) external {
        address actor = actors[who % actors.length];
        uint256 expected = credit[actor];
        if (expected == 0) {
            vm.expectRevert(PaperRoute.NoSubscription.selector);
            vm.prank(actor);
            route.cancel();
            return;
        }
        uint256 before = imd.balanceOf(actor);
        vm.prank(actor);
        route.cancel();
        assertEq(imd.balanceOf(actor) - before, expected * 0.125 ether, "exact model refund");
        credit[actor] = 0;
        refunded[actor] += expected;
        totalRefunded += expected;
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        imd.mint(address(this), amount);
        imd.transfer(address(route), amount);
        donated += amount;
    }

    function publish(uint256 gap) external {
        vm.warp(vm.getBlockTimestamp() + bound(gap, 0, 30 hours));
        IMDDaily.IssueInput memory input = IMDDaily.IssueInput({
            title: "t",
            editorialDate: vm.getBlockTimestamp(),
            pdfURL: "p",
            coverURL: "c",
            metadataURI: "m",
            pdfHash: bytes32(uint256(1)),
            coverHash: bytes32(uint256(2)),
            metadataHash: bytes32(uint256(3))
        });
        vm.prank(PUBLISHER);
        daily.createIssue(input);
    }

    function warp(uint256 gap) external {
        vm.warp(vm.getBlockTimestamp() + bound(gap, 0, 30 hours));
    }

    function changeReceiver(bool reject) external {
        switchable.setRejecting(reject);
    }

    function invalidSubscribe(uint256 who) external {
        address actor = actors[who % actors.length];
        vm.expectRevert(PaperRoute.ZeroEditions.selector);
        vm.prank(actor);
        route.subscribe(0);
    }

    function deliver(uint256 issueSeed, uint256 mask) external {
        uint256 count = daily.issueCount();
        // Bias toward the latest issue but also exercise zero, unknown, older and closed issues.
        uint256 issueId;
        if (count > 0) {
            uint256 mode = issueSeed % 4;
            issueId = mode == 0 ? count : mode == 1 ? count + 1 : mode == 2 ? 1 + issueSeed % count : 0;
        }
        address[] memory list = new address[](actors.length + 1);
        uint256 n;
        for (uint256 i; i < actors.length; ++i) {
            if (mask & (1 << i) != 0) list[n++] = actors[i];
        }
        list[n++] = actors[mask % actors.length]; // a duplicate now and then
        assembly ("memory-safe") {
            mstore(list, n)
        }
        address courier = couriers[mask % 3];
        if (!daily.isAvailable(issueId)) {
            vm.expectRevert(abi.encodeWithSelector(PaperRoute.IssueNotOpen.selector, issueId));
            vm.prank(courier);
            route.deliver(issueId, list);
            return;
        }

        // Predict before calling the implementation. No ghost balance or success count is inferred
        // from PaperRoute's return value or its storage; missing deliveries must fail too.
        address[] memory expected = new address[](n);
        uint256 expectedCount;
        for (uint256 i; i < n; ++i) {
            address actor = list[i];
            if (credit[actor] == 0 || issueId <= latestIssue[actor]) continue;
            if (lastAt[actor] != 0 && vm.getBlockTimestamp() < lastAt[actor] + 20 hours) continue;
            if (actor == actors[4] || actor == actors[5]) continue;
            if (actor == address(switchable) && switchable.rejecting()) continue;
            assertFalse(got[actor][issueId], "model attempted a duplicate copy");
            expected[expectedCount++] = actor;
            --credit[actor];
            ++copies[actor];
            latestIssue[actor] = issueId;
            lastAt[actor] = vm.getBlockTimestamp();
            got[actor][issueId] = true;
        }
        assembly ("memory-safe") { mstore(expected, expectedCount) }
        uint256 courierBefore = imd.balanceOf(courier);
        vm.prank(courier);
        address[] memory delivered = route.deliver{gas: 6_000_000}(issueId, list);
        ++mintCalls;
        assertEq(delivered, expected, "delivery must match independently predicted recipients and order");
        for (uint256 i; i < delivered.length; ++i) {
            address s = delivered[i];
            assertEq(daily.balanceOf(s, issueId), 1, "exactly one copy minted");
        }
        deliveries += expectedCount;
        tipsPaid += expectedCount * 0.025 ether;
        copiesPaid += expectedCount * 0.1 ether;
        courierTips[courier] += expectedCount * 0.025 ether;
        assertEq(imd.balanceOf(courier) - courierBefore, expectedCount * 0.025 ether, "tip per copy");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract PaperRouteInvariantTest is PaperRouteBase {
    PaperRouteHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new PaperRouteHandler(route, imd, daily);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.subscribe.selector;
        selectors[1] = handler.cancel.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.publish.selector;
        selectors[4] = handler.warp.selector;
        selectors[5] = handler.deliver.selector;
        selectors[6] = handler.changeReceiver.selector;
        selectors[7] = handler.invalidSubscribe.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        // Start with real obligations and at least one successful batch, so conservation cannot pass
        // vacuously even if a generated sequence happens to contain no subscriptions or deliveries.
        for (uint256 i; i < handler.actorCount(); ++i) {
            handler.subscribe(i, 3);
        }
        handler.publish(0);
        handler.deliver(0, 255);
    }

    /// @dev The IMD held is never less than every unused edition x 0.125 IMD, and is exactly that plus
    ///      whatever was sent in outside subscribe.
    function invariant_holdingsCoverCreditExactly() public view {
        uint256 held = imd.balanceOf(address(route));
        uint256 reserved = route.reservedBalance();
        assertGe(held, reserved, "holdings below credit");
        assertEq(held, reserved + handler.donated(), "holdings differ from credit plus donations");
        assertEq(route.surplus(), handler.donated());
    }

    /// @dev reservedEditions is the sum of every subscriber's editions left, and the list holds exactly
    ///      the addresses with credit.
    function invariant_reservedMatchesSubscribers() public view {
        uint256 sum;
        uint256 withCredit;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            uint256 left = handler.credit(actor);
            assertEq(route.editionsLeft(actor), left, "model credit");
            sum += left;
            if (left > 0) withCredit += 1;
        }
        assertEq(route.reservedEditions(), sum);
        assertEq(route.subscriberCount(), withCredit);
        address[] memory page = route.subscribers(0, 100);
        assertEq(page.length, withCredit);
        for (uint256 i; i < page.length; ++i) {
            assertGt(route.editionsLeft(page[i]), 0, "listed without credit");
            for (uint256 j; j < i; ++j) {
                assertTrue(page[i] != page[j], "duplicate list member");
            }
        }
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            uint256 occurrences;
            for (uint256 j; j < page.length; ++j) {
                if (page[j] == actor) ++occurrences;
            }
            assertEq(occurrences, handler.credit(actor) > 0 ? 1 : 0, "membership matches credit");
        }
    }

    /// @dev Everything that left matches copies and tips: The IMD Daily's vault holds 0.1 IMD a delivery.
    function invariant_outflowsAreCopiesAndTips() public view {
        assertEq(imd.balanceOf(address(vault)), handler.copiesPaid());
        assertEq(imd.balanceOf(address(vault)), handler.deliveries() * COPY);
        assertEq(daily.totalCollected(), handler.deliveries() * COPY);
        uint256 tips;
        for (uint256 i; i < 3; ++i) {
            address courierAddress = handler.couriers(i);
            assertEq(imd.balanceOf(courierAddress), handler.courierTips(courierAddress));
            tips += imd.balanceOf(courierAddress);
        }
        assertEq(tips, handler.deliveries() * TIP);
        assertEq(tips, handler.tipsPaid());
        assertEq(route.editionsLeft(address(0)), 0);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0, "no allowance left between calls");
    }

    function invariant_eachPurchaseIsEitherCreditCopyOrRefund() public view {
        uint256 spent;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            uint256 returned = handler.refunded(actor);
            uint256 copies = handler.copies(actor);
            assertEq(handler.purchased(actor), handler.credit(actor) + returned + copies);
            uint256 extra = actor == address(handler.probe()) ? EDITION : 0;
            assertEq(imd.balanceOf(actor), returned * EDITION + extra, "refund belongs to that subscriber");
            assertEq(route.lastIssue(actor), handler.latestIssue(actor), "history cannot reset or regress");
            assertEq(route.lastDeliveredAt(actor), handler.lastAt(actor));
            spent += copies;
        }
        assertEq(spent, handler.deliveries());
        assertEq(handler.totalPurchased(), route.reservedEditions() + spent + handler.totalRefunded());
        assertGt(handler.mintCalls(), 0);
        assertGt(handler.deliveries(), 0);
        assertEq(handler.probe().successes(), 0, "receiver cannot mutate the subscription during mint");
    }

    /// @dev At the end of each sequence all remaining liabilities can be withdrawn independently.
    function afterInvariant() public {
        for (uint256 i; i < handler.actorCount(); ++i) {
            handler.cancel(i);
        }
        assertEq(route.reservedEditions(), 0);
        assertEq(route.subscriberCount(), 0);
        assertEq(imd.balanceOf(address(route)), handler.donated());
        invariant_eachPurchaseIsEitherCreditCopyOrRefund();
        invariant_outflowsAreCopiesAndTips();
    }
}
