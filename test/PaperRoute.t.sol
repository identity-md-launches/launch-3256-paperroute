// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PaperRouteBase} from "./PaperRouteBase.t.sol";
import {PaperRoute, IIMDDaily} from "../src/PaperRoute.sol";
import {IMDDaily} from "./mocks/IMDDaily.sol";
import {
    AcceptingReceiver,
    GasBurningReceiver,
    ReentrantReceiver,
    Reverter,
    RevertingReceiver,
    SneakyReentrantReceiver
} from "./mocks/Mocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PaperRouteTest is PaperRouteBase {
    // ------------------------------------------------------------------ constants and deployment

    function test_constants() public view {
        assertEq(address(route.IMD()), IMD_ADDRESS);
        assertEq(address(route.DAILY()), DAILY_ADDRESS);
        assertEq(route.COPY_PRICE(), COPY);
        assertEq(route.TIP(), TIP);
        assertEq(route.EDITION_PRICE(), EDITION);
        assertEq(route.DELIVERY_INTERVAL(), 20 hours);
        assertEq(route.COPY_PRICE(), daily.PRICE(), "copy price must match The IMD Daily");
        assertEq(5 ether, 40 * route.EDITION_PRICE(), "5 IMD buys 40 editions");
    }

    function test_deploysOnEmptyChainWithoutExternalCalls() public {
        vm.etch(IMD_ADDRESS, "");
        vm.etch(DAILY_ADDRESS, "");
        PaperRoute fresh = new PaperRoute();
        assertEq(fresh.reservedEditions(), 0);
        assertEq(fresh.subscriberCount(), 0);
    }

    function test_noPrivilegedFunctions() public {
        // Nothing to own: no owner(), no setter, no pause, no sweep. The only state changes are the three
        // user entry points, each acting for msg.sender alone.
        (bool ok,) = address(route).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(route).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
        (ok,) = address(route).call(abi.encodeWithSignature("withdraw(uint256)", 1));
        assertFalse(ok);
        (ok,) = address(route).call(abi.encodeWithSignature("sweep(address)", alice));
        assertFalse(ok);
        (ok,) = address(route).call{value: 1}("");
        assertFalse(ok, "no receive/fallback");
    }

    // ------------------------------------------------------------------ subscribe

    function test_subscribe_pullsExactAmountAndCredits() public {
        fund(alice, 5 ether);
        vm.expectEmit(true, true, true, true);
        emit PaperRoute.Subscribed(alice, 40, 5 ether, 40);
        vm.prank(alice);
        route.subscribe(40);

        assertEq(imd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(address(route)), 5 ether);
        assertEq(route.editionsLeft(alice), 40);
        assertEq(route.reservedEditions(), 40);
        assertEq(route.reservedBalance(), 5 ether);
        assertEq(route.surplus(), 0);
        assertEq(route.subscriberCount(), 1);
        assertEq(route.subscribers(0, 10)[0], alice);
    }

    function test_subscribe_againAddsMore() public {
        subscribeAs(alice, 40);
        subscribeAs(alice, 3);
        assertEq(route.editionsLeft(alice), 43);
        assertEq(route.reservedEditions(), 43);
        assertEq(route.subscriberCount(), 1, "listed once");
        assertEq(imd.balanceOf(address(route)), 43 * EDITION);
    }

    function test_subscribe_anyPositiveNumber() public {
        subscribeAs(alice, 1);
        assertEq(route.editionsLeft(alice), 1);
        assertEq(imd.balanceOf(address(route)), EDITION);
    }

    function test_subscribe_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(PaperRoute.ZeroEditions.selector);
        route.subscribe(0);
    }

    function test_subscribe_withoutAllowanceReverts() public {
        imd.mint(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert();
        route.subscribe(40);
    }

    function test_subscribe_withoutBalanceReverts() public {
        vm.prank(alice);
        imd.approve(address(route), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert();
        route.subscribe(40);
    }

    function test_subscribe_tooManyEditionsReverts() public {
        fund(alice, 1);
        vm.prank(alice);
        vm.expectRevert(PaperRoute.TooManyEditions.selector);
        route.subscribe(uint256(type(uint128).max) + 1);
    }

    function test_subscribe_shortPaymentReverts() public {
        // A token that pays less than asked (fee on transfer) is refused to the wei.
        fund(alice, 5 ether);
        vm.mockCall(
            IMD_ADDRESS,
            abi.encodeWithSelector(imd.balanceOf.selector, address(route)),
            abi.encode(uint256(0))
        );
        vm.prank(alice);
        vm.expectRevert(PaperRoute.InexactPayment.selector);
        route.subscribe(40);
    }

    // ------------------------------------------------------------------ cancel

    function test_cancel_refundsEverythingUnused() public {
        subscribeAs(alice, 40);
        vm.expectEmit(true, true, true, true);
        emit PaperRoute.Cancelled(alice, 40, 5 ether);
        vm.prank(alice);
        route.cancel();

        assertEq(imd.balanceOf(alice), 5 ether);
        assertEq(imd.balanceOf(address(route)), 0);
        assertEq(route.editionsLeft(alice), 0);
        assertEq(route.reservedEditions(), 0);
        assertEq(route.subscriberCount(), 0);
    }

    function test_cancel_afterPartialUseRefundsTheRest() public {
        subscribeAs(alice, 40);
        uint256 id = publishIssue();
        deliverAs(courier, id, list(alice));
        assertEq(route.editionsLeft(alice), 39);

        vm.prank(alice);
        route.cancel();
        assertEq(imd.balanceOf(alice), 39 * EDITION);
        assertEq(imd.balanceOf(address(route)), 0, "nothing left behind");
        assertEq(route.lastIssue(alice), id, "history kept");
        assertEq(route.subscriberCount(), 0);
    }

    function test_cancel_withoutCreditReverts() public {
        vm.prank(alice);
        vm.expectRevert(PaperRoute.NoSubscription.selector);
        route.cancel();
    }

    function test_cancel_twiceReverts() public {
        subscribeAs(alice, 2);
        vm.prank(alice);
        route.cancel();
        vm.prank(alice);
        vm.expectRevert(PaperRoute.NoSubscription.selector);
        route.cancel();
    }

    function test_cancel_worksWhenDailyMintAlwaysReverts() public {
        subscribeAs(alice, 40);
        vm.mockCallRevert(DAILY_ADDRESS, abi.encodeWithSelector(IIMDDaily.mint.selector), "stopped");
        uint256 id = publishIssue();
        address[] memory delivered = deliverAs(courier, id, list(alice));
        assertEq(delivered.length, 0, "every mint fails");
        assertEq(route.editionsLeft(alice), 40, "nothing charged");

        vm.prank(alice);
        route.cancel();
        assertEq(imd.balanceOf(alice), 5 ether);
    }

    function test_cancel_worksWhenDailyRevertsOnEverything() public {
        subscribeAs(alice, 40);
        vm.etch(DAILY_ADDRESS, address(new Reverter()).code);
        vm.prank(alice);
        route.cancel();
        assertEq(imd.balanceOf(alice), 5 ether);
    }

    function test_cancel_worksWhenDailyHasNoCode() public {
        subscribeAs(alice, 40);
        vm.etch(DAILY_ADDRESS, "");
        vm.prank(alice);
        route.cancel();
        assertEq(imd.balanceOf(alice), 5 ether);
    }

    function test_cancel_resubscribeKeepsOneCopyAnIssue() public {
        subscribeAs(alice, 1);
        uint256 id = publishIssue();
        deliverAs(courier, id, list(alice));
        assertEq(route.subscriberCount(), 0, "credit used up");

        subscribeAs(alice, 5);
        (bool isDue, PaperRoute.SkipReason reason) = route.dueStatus(alice, id);
        assertFalse(isDue);
        assertEq(uint8(reason), uint8(PaperRoute.SkipReason.AlreadyDelivered));
    }

    // ------------------------------------------------------------------ deliver: payments

    function test_deliver_paymentsToTheWei() public {
        subscribeAs(alice, 40);
        uint256 id = publishIssue();

        vm.expectEmit(true, true, true, true);
        emit PaperRoute.Delivered(id, alice, courier);
        address[] memory delivered = deliverAs(courier, id, list(alice));

        assertEq(delivered.length, 1);
        assertEq(delivered[0], alice);
        assertEq(daily.balanceOf(alice, id), 1, "one copy");
        assertEq(imd.balanceOf(address(vault)), COPY, "0.1 IMD to The IMD Daily");
        assertEq(imd.balanceOf(courier), TIP, "0.025 IMD tip");
        assertEq(imd.balanceOf(address(route)), 39 * EDITION);
        assertEq(route.editionsLeft(alice), 39);
        assertEq(route.reservedEditions(), 39);
        assertEq(route.lastIssue(alice), id);
        assertEq(route.lastDeliveredAt(alice), block.timestamp);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0, "allowance fully consumed");
    }

    function test_deliver_manySubscribersPaysTipPerCopy() public {
        subscribeAs(alice, 2);
        subscribeAs(bob, 2);
        subscribeAs(carol, 2);
        uint256 id = publishIssue();
        address[] memory delivered = deliverAs(courier, id, list(alice, bob, carol));
        assertEq(delivered.length, 3);
        assertEq(imd.balanceOf(courier), 3 * TIP);
        assertEq(imd.balanceOf(address(vault)), 3 * COPY);
        assertEq(imd.balanceOf(address(route)), 3 * EDITION);
    }

    function test_deliver_oneCopyAnIssue() public {
        subscribeAs(alice, 40);
        uint256 id = publishIssue();
        deliverAs(courier, id, list(alice));

        vm.expectEmit(true, true, true, true);
        emit PaperRoute.Skipped(id, alice, PaperRoute.SkipReason.AlreadyDelivered);
        address[] memory delivered = deliverAs(courier, id, list(alice));
        assertEq(delivered.length, 0);
        assertEq(daily.balanceOf(alice, id), 1);
        assertEq(route.editionsLeft(alice), 39);
        assertEq(imd.balanceOf(courier), TIP, "no second tip");
    }

    function test_deliver_duplicateInListDeliveredOnce() public {
        subscribeAs(alice, 40);
        uint256 id = publishIssue();
        address[] memory delivered = deliverAs(courier, id, list(alice, alice, alice));
        assertEq(delivered.length, 1);
        assertEq(route.editionsLeft(alice), 39);
        assertEq(imd.balanceOf(courier), TIP);
    }

    function test_deliver_twentyHourRule() public {
        subscribeAs(alice, 40);
        uint256 first = publishIssue();
        deliverAs(courier, first, list(alice));

        // A second issue the same day: not due until 20 hours have passed.
        vm.warp(block.timestamp + 19 hours + 59 minutes + 59 seconds);
        uint256 second = publishIssue();
        (bool isDue, PaperRoute.SkipReason reason) = route.dueStatus(alice, second);
        assertFalse(isDue);
        assertEq(uint8(reason), uint8(PaperRoute.SkipReason.TooSoon));
        vm.expectEmit(true, true, true, true);
        emit PaperRoute.Skipped(second, alice, PaperRoute.SkipReason.TooSoon);
        assertEq(deliverAs(courier, second, list(alice)).length, 0);
        assertEq(route.editionsLeft(alice), 39);

        vm.warp(block.timestamp + 1);
        (isDue,) = route.dueStatus(alice, second);
        assertTrue(isDue, "exactly 20 hours is enough");
        assertEq(deliverAs(courier, second, list(alice)).length, 1);
        assertEq(route.editionsLeft(alice), 38);
    }

    function test_deliver_earlierIssueAfterLaterIsSkipped() public {
        subscribeAs(alice, 40);
        uint256 first = publishIssue();
        uint256 second = publishIssue();
        deliverAs(courier, second, list(alice));
        vm.warp(block.timestamp + 21 hours);
        // Issue 1 still open? No: it closes 24h after publication, so publish nothing and re-check the rule
        // through dueStatus, which ignores the window.
        (bool isDue, PaperRoute.SkipReason reason) = route.dueStatus(alice, first);
        assertFalse(isDue);
        assertEq(uint8(reason), uint8(PaperRoute.SkipReason.AlreadyDelivered));
    }

    function test_deliver_noCreditSkipped() public {
        uint256 id = publishIssue();
        vm.expectEmit(true, true, true, true);
        emit PaperRoute.Skipped(id, alice, PaperRoute.SkipReason.NoCredit);
        address[] memory delivered = deliverAs(courier, id, list(alice));
        assertEq(delivered.length, 0);
        assertEq(imd.balanceOf(courier), 0, "no tip for nothing");
    }

    function test_deliver_lastEditionRemovesFromList() public {
        subscribeAs(alice, 1);
        subscribeAs(bob, 1);
        uint256 id = publishIssue();
        deliverAs(courier, id, list(alice));
        assertEq(route.subscriberCount(), 1);
        assertEq(route.subscribers(0, 10)[0], bob);
        assertEq(route.editionsLeft(alice), 0);
        assertEq(route.reservedEditions(), 1);
    }

    function test_deliver_closedIssueReverts() public {
        subscribeAs(alice, 40);
        uint256 id = publishIssue();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(courier);
        vm.expectRevert(abi.encodeWithSelector(PaperRoute.IssueNotOpen.selector, id));
        route.deliver(id, list(alice));
        assertEq(route.due(id, 0, 10).length, 0);
    }

    function test_deliver_unknownIssueReverts() public {
        subscribeAs(alice, 40);
        uint256 id = publishIssue();
        vm.prank(courier);
        vm.expectRevert(abi.encodeWithSelector(PaperRoute.IssueNotOpen.selector, id + 1));
        route.deliver(id + 1, list(alice));
        vm.prank(courier);
        vm.expectRevert(abi.encodeWithSelector(PaperRoute.IssueNotOpen.selector, 0));
        route.deliver(0, list(alice));
        assertEq(route.due(id + 1, 0, 10).length, 0);
    }

    function test_deliver_emptyListIsANoop() public {
        uint256 id = publishIssue();
        address[] memory delivered = deliverAs(courier, id, new address[](0));
        assertEq(delivered.length, 0);
    }

    // ------------------------------------------------------------------ deliver: receivers

    function test_deliver_contractReceiverGetsCopy() public {
        AcceptingReceiver holder = new AcceptingReceiver();
        subscribeAs(address(holder), 2);
        uint256 id = publishIssue();
        assertEq(deliverAs(courier, id, list(address(holder))).length, 1);
        assertEq(daily.balanceOf(address(holder), id), 1);
    }

    function test_deliver_revertingReceiverSkippedOthersDelivered() public {
        RevertingReceiver bad = new RevertingReceiver();
        subscribeAs(alice, 2);
        subscribeAs(address(bad), 2);
        subscribeAs(bob, 2);
        uint256 id = publishIssue();
        uint256 before = imd.balanceOf(address(route));

        vm.expectEmit(true, true, true, true);
        emit PaperRoute.Skipped(id, address(bad), PaperRoute.SkipReason.MintFailed);
        address[] memory delivered = deliverAs(courier, id, list(alice, address(bad), bob));

        assertEq(delivered.length, 2);
        assertEq(delivered[0], alice);
        assertEq(delivered[1], bob);
        assertEq(route.editionsLeft(address(bad)), 2, "nothing charged");
        assertEq(route.lastIssue(address(bad)), 0);
        assertEq(daily.balanceOf(address(bad), id), 0);
        assertEq(imd.balanceOf(courier), 2 * TIP);
        assertEq(imd.balanceOf(address(vault)), 2 * COPY);
        assertEq(imd.balanceOf(address(route)), before - 2 * EDITION);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0, "no allowance left dangling");
    }

    function test_deliver_gasBurningReceiverSkippedOthersDelivered() public {
        GasBurningReceiver burner = new GasBurningReceiver();
        subscribeAs(alice, 2);
        subscribeAs(address(burner), 2);
        subscribeAs(bob, 2);
        uint256 id = publishIssue();

        vm.expectEmit(true, true, true, true);
        emit PaperRoute.Skipped(id, address(burner), PaperRoute.SkipReason.MintFailed);
        vm.prank(courier);
        address[] memory delivered = route.deliver{gas: 2_000_000}(id, list(alice, address(burner), bob));

        assertEq(delivered.length, 2);
        assertEq(delivered[0], alice);
        assertEq(delivered[1], bob);
        assertEq(route.editionsLeft(address(burner)), 2, "nothing charged");
        assertEq(daily.balanceOf(address(burner), id), 0);
        assertEq(imd.balanceOf(courier), 2 * TIP);
        assertEq(imd.balanceOf(address(route)), 4 * EDITION);
    }

    function test_deliver_gasBurnerLastInListStillPaysTip() public {
        GasBurningReceiver burner = new GasBurningReceiver();
        subscribeAs(alice, 2);
        subscribeAs(address(burner), 2);
        uint256 id = publishIssue();
        vm.prank(courier);
        address[] memory delivered = route.deliver{gas: 900_000}(id, list(alice, address(burner)));
        assertEq(delivered.length, 1);
        assertEq(imd.balanceOf(courier), TIP);
        assertEq(imd.balanceOf(address(route)), 3 * EDITION);
    }

    function test_deliver_tooLittleGasCutsListShortWithoutReverting() public {
        subscribeAs(alice, 2);
        subscribeAs(bob, 2);
        uint256 id = publishIssue();
        // Enough for the first mint, not enough to forward a whole allowance for the second.
        vm.prank(courier);
        address[] memory delivered = route.deliver{gas: 760_000}(id, list(alice, bob));
        assertEq(delivered.length, 1);
        assertEq(delivered[0], alice);
        assertEq(route.editionsLeft(bob), 2, "left for another call");
        assertEq(imd.balanceOf(courier), TIP);
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_deliver_anyGasBudgetKeepsHoldingsConsistent(uint256 gas) public {
        gas = bound(gas, 100_000, 3_000_000);
        GasBurningReceiver burner = new GasBurningReceiver();
        subscribeAs(alice, 2);
        subscribeAs(address(burner), 2);
        subscribeAs(bob, 2);
        uint256 id = publishIssue();
        vm.prank(courier);
        (bool ok, bytes memory ret) = address(route).call{gas: gas}(
            abi.encodeCall(route.deliver, (id, list(alice, address(burner), bob)))
        );
        if (ok) {
            address[] memory delivered = abi.decode(ret, (address[]));
            assertEq(imd.balanceOf(courier), delivered.length * TIP);
            assertEq(imd.balanceOf(address(vault)), delivered.length * COPY);
            assertEq(route.editionsLeft(address(burner)), 2);
        }
        assertEq(imd.balanceOf(address(route)), route.reservedBalance(), "holdings cover credit exactly");
    }

    // ------------------------------------------------------------------ reentrancy

    function test_deliver_reentrantCancelFromReceiverIsSkipped() public {
        ReentrantReceiver evil = new ReentrantReceiver(route);
        subscribeAs(address(evil), 2);
        subscribeAs(alice, 2);
        uint256 id = publishIssue();
        for (uint8 mode; mode < 3; ++mode) {
            evil.setMode(mode);
            vm.expectEmit(true, true, true, true);
            emit PaperRoute.Skipped(id, address(evil), PaperRoute.SkipReason.MintFailed);
            address[] memory delivered = deliverAs(courier, id, list(address(evil), alice));
            assertEq(delivered.length, mode == 0 ? 1 : 0);
            assertEq(route.editionsLeft(address(evil)), 2, "nothing charged");
            assertEq(daily.balanceOf(address(evil), id), 0);
        }
        assertEq(imd.balanceOf(address(route)), route.reservedBalance());
    }

    function test_deliver_reentrancySwallowedStillChangesNothing() public {
        SneakyReentrantReceiver sneaky = new SneakyReentrantReceiver(route);
        subscribeAs(address(sneaky), 3);
        uint256 id = publishIssue();
        address[] memory delivered = deliverAs(courier, id, list(address(sneaky)));
        assertEq(delivered.length, 1, "copy accepted");
        assertEq(sneaky.attempts(), 1);
        assertEq(sneaky.successes(), 0, "every re-entry reverted");
        assertEq(route.editionsLeft(address(sneaky)), 2, "charged exactly once");
        assertEq(daily.balanceOf(address(sneaky), id), 1);
        assertEq(imd.balanceOf(courier), TIP);
        assertEq(imd.balanceOf(address(route)), route.reservedBalance());
    }

    // ------------------------------------------------------------------ views

    function test_views_dueAndPaging() public {
        subscribeAs(alice, 1);
        subscribeAs(bob, 1);
        subscribeAs(carol, 1);
        uint256 id = publishIssue();
        assertEq(route.due(id, 0, 10).length, 3);
        assertEq(route.due(id, 1, 1).length, 1);
        assertEq(route.due(id, 1, 1)[0], bob);
        assertEq(route.due(id, 5, 10).length, 0, "offset past the end");
        assertEq(route.subscribers(1, 10).length, 2);
        assertEq(route.subscribers(0, 0).length, 0);

        deliverAs(courier, id, list(bob));
        assertEq(route.subscriberCount(), 2, "bob used his only edition");
        address[] memory dueNow = route.due(id, 0, 10);
        assertEq(dueNow.length, 2);
        assertTrue(dueNow[0] != bob && dueNow[1] != bob);

        PaperRoute.Subscription memory s = route.subscriptionOf(bob);
        assertEq(s.editionsLeft, 0);
        assertEq(s.lastIssue, id);
        assertEq(s.lastDeliveredAt, block.timestamp);
    }

    function test_views_surplusCountsOnlyDonations() public {
        subscribeAs(alice, 4);
        imd.mint(address(route), 1 ether);
        assertEq(route.surplus(), 1 ether);
        assertEq(route.reservedBalance(), 4 * EDITION);
        vm.prank(alice);
        route.cancel();
        assertEq(imd.balanceOf(alice), 4 * EDITION, "refund is credit only");
        assertEq(imd.balanceOf(address(route)), 1 ether, "donation stays");
    }

    function test_subscriberListSwapAndPop() public {
        subscribeAs(alice, 1);
        subscribeAs(bob, 1);
        subscribeAs(carol, 1);
        vm.prank(alice);
        route.cancel();
        address[] memory page = route.subscribers(0, 10);
        assertEq(page.length, 2);
        assertEq(page[0], carol, "last moved into the hole");
        assertEq(page[1], bob);
        vm.prank(carol);
        route.cancel();
        vm.prank(bob);
        route.cancel();
        assertEq(route.subscriberCount(), 0);
        subscribeAs(bob, 1);
        assertEq(route.subscribers(0, 10)[0], bob);
    }
}
