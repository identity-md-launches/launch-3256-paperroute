// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PaperRouteBase} from "./PaperRouteBase.t.sol";
import {PaperRoute} from "../src/PaperRoute.sol";
import {IMDDaily} from "./mocks/IMDDaily.sol";
import {MockIMD, AcceptingReceiver, RevertingReceiver, GasBurningReceiver} from "./mocks/Mocks.sol";

/// @dev Drives Paper Route with subscribers of every kind, issues published over time, donations and
///      deliveries, and keeps ghost totals the invariants are checked against.
contract PaperRouteHandler is Test {
    PaperRoute public route;
    MockIMD public imd;
    IMDDaily public daily;
    address public constant PUBLISHER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;

    address[] public actors;
    uint256 public donated;
    uint256 public deliveries;
    uint256 public tipsPaid;
    uint256 public copiesPaid;
    mapping(address => mapping(uint256 => bool)) public got;
    mapping(address => uint256) public lastAt;

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
        imd.mint(actor, editions * route.EDITION_PRICE());
        vm.prank(actor);
        route.subscribe(editions);
    }

    function cancel(uint256 who) external {
        address actor = actors[who % actors.length];
        if (route.editionsLeft(actor) == 0) return;
        vm.prank(actor);
        route.cancel();
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        imd.mint(address(route), amount);
        donated += amount;
    }

    function publish(uint256 gap) external {
        vm.warp(block.timestamp + bound(gap, 0, 30 hours));
        IMDDaily.IssueInput memory input = IMDDaily.IssueInput({
            title: "t",
            editorialDate: block.timestamp,
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
        vm.warp(block.timestamp + bound(gap, 0, 30 hours));
    }

    function deliver(uint256 issueSeed, uint256 mask) external {
        uint256 count = daily.issueCount();
        if (count == 0) return;
        uint256 issueId = 1 + (issueSeed % count);
        if (!daily.isAvailable(issueId)) return;
        address[] memory list = new address[](actors.length + 1);
        uint256 n;
        for (uint256 i; i < actors.length; ++i) {
            if (mask & (1 << i) != 0) list[n++] = actors[i];
        }
        list[n++] = actors[mask % actors.length]; // a duplicate now and then
        assembly ("memory-safe") {
            mstore(list, n)
        }
        address courier = makeAddr(string.concat("courier", vm.toString(mask % 3)));
        uint256 courierBefore = imd.balanceOf(courier);
        vm.prank(courier);
        address[] memory delivered = route.deliver{gas: 4_000_000}(issueId, list);
        for (uint256 i; i < delivered.length; ++i) {
            address s = delivered[i];
            assertFalse(got[s][issueId], "one copy an issue");
            assertTrue(lastAt[s] == 0 || block.timestamp >= lastAt[s] + 20 hours, "20-hour rule");
            got[s][issueId] = true;
            lastAt[s] = block.timestamp;
            assertEq(daily.balanceOf(s, issueId), 1, "exactly one copy minted");
        }
        deliveries += delivered.length;
        tipsPaid += delivered.length * route.TIP();
        copiesPaid += delivered.length * route.COPY_PRICE();
        assertEq(imd.balanceOf(courier) - courierBefore, delivered.length * route.TIP(), "tip per copy");
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 32
contract PaperRouteInvariantTest is PaperRouteBase {
    PaperRouteHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new PaperRouteHandler(route, imd, daily);
        targetContract(address(handler));
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
            uint256 left = route.editionsLeft(handler.actors(i));
            sum += left;
            if (left > 0) withCredit += 1;
        }
        assertEq(route.reservedEditions(), sum);
        assertEq(route.subscriberCount(), withCredit);
        address[] memory page = route.subscribers(0, 100);
        assertEq(page.length, withCredit);
        for (uint256 i; i < page.length; ++i) {
            assertGt(route.editionsLeft(page[i]), 0, "listed without credit");
        }
    }

    /// @dev Everything that left matches copies and tips: The IMD Daily's vault holds 0.1 IMD a delivery.
    function invariant_outflowsAreCopiesAndTips() public view {
        assertEq(imd.balanceOf(address(vault)), handler.copiesPaid());
        assertEq(imd.balanceOf(address(vault)), handler.deliveries() * COPY);
        assertEq(route.editionsLeft(address(0)), 0);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0, "no allowance left between calls");
    }
}
