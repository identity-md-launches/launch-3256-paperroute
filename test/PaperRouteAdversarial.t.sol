// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PaperRouteBase} from "./PaperRouteBase.t.sol";
import {PaperRoute, IIMDDaily} from "../src/PaperRoute.sol";
import {
    AdversarialIMD,
    GuardProbeReceiver,
    SwitchableReceiver,
    WrongSelectorReceiver,
    ReturnBombReceiver
} from "./mocks/AdversarialMocks.sol";
import {GasBurningReceiver, RevertingReceiver} from "./mocks/Mocks.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {stdError} from "forge-std/StdError.sol";

contract PaperRouteAdversarialTest is PaperRouteBase {
    function test_fortyDailyEditionsSpendExactlyFiveIMD() public {
        subscribeAs(alice, 40);
        for (uint256 i; i < 40; ++i) {
            uint256 id = publishIssue();
            assertEq(deliverAs(courier, id, list(alice)), list(alice));
            assertEq(daily.balanceOf(alice, id), 1);
            assertEq(route.editionsLeft(alice), 39 - i);
            assertEq(imd.balanceOf(address(route)), (39 - i) * EDITION);
            assertEq(route.reservedBalance(), (39 - i) * EDITION);
            vm.warp(vm.getBlockTimestamp() + 24 hours);
        }
        assertEq(imd.balanceOf(address(vault)), 4 ether);
        assertEq(daily.totalCollected(), 4 ether);
        assertEq(imd.balanceOf(courier), 1 ether);
        assertEq(imd.balanceOf(alice), 0);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
        _assertEmpty(alice);
        uint256 next = publishIssue();
        assertEq(deliverAs(courier, next, list(alice)).length, 0);
        assertEq(daily.balanceOf(alice, next), 0);
        vm.expectRevert(PaperRoute.NoSubscription.selector);
        vm.prank(alice);
        route.cancel();
    }

    function test_exactApprovalAndExtraWalletBalance() public {
        fund(alice, 5 ether + 1);
        vm.startPrank(alice);
        imd.approve(address(route), 5 ether);
        route.subscribe(40);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), 1);
        assertEq(imd.allowance(alice, address(route)), 0);
        vm.prank(alice);
        route.cancel();
        assertEq(imd.balanceOf(alice), 5 ether + 1);
        assertEq(route.reservedBalance(), 0);
    }

    function test_allowanceOneWeiShortLeavesNoSubscription() public {
        fund(alice, EDITION);
        vm.prank(alice);
        imd.approve(address(route), EDITION - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(route), EDITION - 1, EDITION
            )
        );
        vm.prank(alice);
        route.subscribe(1);
        _assertEmpty(alice);
        assertEq(imd.balanceOf(alice), EDITION);
        assertEq(imd.allowance(alice, address(route)), EDITION - 1);
    }

    function test_balanceOneWeiShortLeavesNoSubscription() public {
        fund(alice, EDITION - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, EDITION - 1, EDITION
            )
        );
        vm.prank(alice);
        route.subscribe(1);
        _assertEmpty(alice);
        assertEq(imd.balanceOf(alice), EDITION - 1);
    }

    function test_maximumCreditCanBeRefundedWithoutRounding() public {
        uint256 maximum = type(uint128).max;
        subscribeAs(alice, maximum);
        assertEq(route.reservedBalance(), maximum * EDITION);
        vm.prank(alice);
        vm.expectRevert(PaperRoute.TooManyEditions.selector);
        route.subscribe(1);
        assertEq(route.editionsLeft(alice), maximum);
        assertEq(route.subscriberCount(), 1);
        vm.prank(alice);
        route.cancel();
        assertEq(imd.balanceOf(alice), maximum * EDITION);
        _assertEmpty(alice);
    }

    function test_arithmeticOverflowCannotMutateExistingCredit() public {
        subscribeAs(alice, 2);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
        route.subscribe(type(uint256).max);
        assertEq(route.editionsLeft(alice), 2);
        assertEq(route.reservedEditions(), 2);
        assertEq(route.subscribers(0, 10), list(alice));
        assertEq(imd.balanceOf(address(route)), 2 * EDITION);
    }

    function test_inexactIncomingTransfersRollBackTokenAndCredit() public {
        AdversarialIMD token = _adversarialToken();
        fund(alice, 5 ether);
        uint256 supply = token.totalSupply();
        for (uint8 mode = 1; mode <= 2; ++mode) {
            token.configure(AdversarialIMD.Incoming(mode), false, false);
            vm.expectRevert(PaperRoute.InexactPayment.selector);
            vm.prank(alice);
            route.subscribe(40);
            _assertEmpty(alice);
            assertEq(token.balanceOf(alice), 5 ether);
            assertEq(token.totalSupply(), supply, "even token-side changes must roll back");
        }
    }

    function test_failedTopUpPreservesCreditHistoryAndMembership() public {
        AdversarialIMD token = _adversarialToken();
        subscribeAs(alice, 3);
        uint256 id = publishIssue();
        deliverAs(courier, id, list(alice));
        fund(alice, EDITION);
        token.configure(AdversarialIMD.Incoming.ShortByOneWei, false, false);
        vm.expectRevert(PaperRoute.InexactPayment.selector);
        vm.prank(alice);
        route.subscribe(1);
        assertEq(route.editionsLeft(alice), 2);
        assertEq(route.reservedEditions(), 2);
        assertEq(route.lastIssue(alice), id);
        assertEq(route.lastDeliveredAt(alice), vm.getBlockTimestamp());
        assertEq(route.subscribers(0, 100), list(alice));
        assertEq(token.balanceOf(alice), EDITION);
        assertEq(token.balanceOf(address(route)), 2 * EDITION);
    }

    function test_falseReturningPaymentRevertsWithoutAddingMember() public {
        AdversarialIMD token = _adversarialToken();
        fund(alice, EDITION);
        token.configure(AdversarialIMD.Incoming.ReturnFalse, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD_ADDRESS));
        vm.prank(alice);
        route.subscribe(1);
        _assertEmpty(alice);
        assertEq(token.balanceOf(alice), EDITION);
    }

    function test_noReturnPaymentStillRequiresExactReceipt() public {
        AdversarialIMD token = _adversarialToken();
        fund(alice, 2 * EDITION);
        token.configure(AdversarialIMD.Incoming.NoReturn, false, false);
        vm.prank(alice);
        route.subscribe(2);
        uint256 id = publishIssue();
        assertEq(deliverAs(courier, id, list(alice)), list(alice));
        vm.prank(alice);
        route.cancel();
        assertEq(token.balanceOf(alice), EDITION);
        assertEq(token.balanceOf(address(vault)), COPY);
        assertEq(token.balanceOf(courier), TIP);
        _assertEmpty(alice);
    }

    function test_failedRefundRestoresSwapAndPopThenCanBeRetried() public {
        AdversarialIMD token = _adversarialToken();
        subscribeAs(alice, 3);
        subscribeAs(bob, 2);
        token.configure(AdversarialIMD.Incoming.Exact, true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD_ADDRESS));
        vm.prank(alice);
        route.cancel();
        assertEq(route.subscribers(0, 10), list(alice, bob));
        assertEq(route.editionsLeft(alice), 3);
        assertEq(route.reservedEditions(), 5);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(route)), 5 * EDITION);
        token.configure(AdversarialIMD.Incoming.Exact, false, false);
        vm.prank(alice);
        route.cancel();
        vm.prank(bob);
        route.cancel();
        assertEq(token.balanceOf(alice), 3 * EDITION);
        assertEq(token.balanceOf(bob), 2 * EDITION);
        _assertEmpty(alice);
    }

    function test_failedTipRollsBackWholeBatchIncludingCopiesAndVaultPayment() public {
        AdversarialIMD token = _adversarialToken();
        subscribeAs(alice, 1);
        subscribeAs(bob, 2);
        uint256 id = publishIssue();
        token.configure(AdversarialIMD.Incoming.Exact, true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD_ADDRESS));
        vm.prank(courier);
        route.deliver(id, list(alice, bob));
        assertEq(daily.totalSupply(id), 0);
        assertEq(daily.totalCollected(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(courier), 0);
        assertEq(token.balanceOf(address(route)), 3 * EDITION);
        assertEq(route.editionsLeft(alice), 1);
        assertEq(route.editionsLeft(bob), 2);
        assertEq(route.lastIssue(alice), 0);
        assertEq(route.lastDeliveredAt(bob), 0);
        assertEq(route.reservedEditions(), 3);
        assertEq(route.subscribers(0, 10), list(alice, bob));
        assertEq(token.allowance(address(route), DAILY_ADDRESS), 0);
        token.configure(AdversarialIMD.Incoming.Exact, false, false);
        assertEq(deliverAs(courier, id, list(alice, bob)), list(alice, bob));
        assertEq(token.balanceOf(courier), 2 * TIP);
        assertEq(token.balanceOf(address(vault)), 2 * COPY);
    }

    function test_failedApprovalCannotConsumeCredit() public {
        AdversarialIMD token = _adversarialToken();
        subscribeAs(alice, 2);
        uint256 id = publishIssue();
        token.configure(AdversarialIMD.Incoming.Exact, false, true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD_ADDRESS));
        vm.prank(courier);
        route.deliver(id, list(alice));
        assertEq(route.editionsLeft(alice), 2);
        assertEq(route.reservedEditions(), 2);
        assertEq(daily.totalSupply(id), 0);
        assertEq(token.balanceOf(address(route)), 2 * EDITION);
        assertEq(token.allowance(address(route), DAILY_ADDRESS), 0);
        vm.prank(alice);
        route.cancel();
        assertEq(token.balanceOf(alice), 2 * EDITION, "refund does not need an approval");
    }

    function test_allMutatingEntryPointsRejectReceiverWithGuardError() public {
        GuardProbeReceiver probe = new GuardProbeReceiver(route);
        subscribeAs(address(probe), 3);
        fund(address(probe), EDITION);
        uint256 id = publishIssue();
        assertEq(deliverAs(courier, id, list(address(probe), alice)), list(address(probe)));
        assertEq(probe.attempts(), 3);
        assertEq(probe.successes(), 0);
        assertEq(probe.cancelError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(probe.subscribeError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(probe.deliverError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(route.editionsLeft(address(probe)), 2);
        assertEq(imd.balanceOf(address(probe)), EDITION);
        assertEq(daily.balanceOf(address(probe), id), 1);
        assertEq(imd.balanceOf(address(vault)), COPY);
        assertEq(imd.balanceOf(courier), TIP);
        assertEq(imd.balanceOf(address(route)), 2 * EDITION);
    }

    function test_acceptingEIP7702DelegateReceivesAtSubscriberAddress() public {
        GuardProbeReceiver implementation = new GuardProbeReceiver(route);
        // Install the post-authorization EIP-7702 designation on a test account. No key or broadcast.
        vm.etch(alice, abi.encodePacked(hex"ef0100", address(implementation)));
        subscribeAs(alice, 3);
        fund(alice, EDITION);
        uint256 id = publishIssue();
        assertEq(deliverAs(courier, id, list(alice)), list(alice));
        GuardProbeReceiver delegated = GuardProbeReceiver(alice);
        assertEq(delegated.attempts(), 3, "callback executes in subscriber account context");
        assertEq(delegated.successes(), 0);
        assertEq(delegated.subscribeError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(delegated.cancelError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(delegated.deliverError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(implementation.attempts(), 0, "delegate implementation is not the recipient");
        assertEq(daily.balanceOf(alice, id), 1);
        assertEq(daily.balanceOf(address(implementation), id), 0);
        assertEq(route.editionsLeft(alice), 2);
        vm.prank(alice);
        route.cancel();
        assertEq(imd.balanceOf(alice), 3 * EDITION);
        assertEq(imd.balanceOf(address(route)), 0);
    }

    function test_rejectingReceiverCanRecoverAndRetrySameIssueWithoutWaiting() public {
        SwitchableReceiver receiver = new SwitchableReceiver();
        subscribeAs(address(receiver), 2);
        uint256 id = publishIssue();
        assertEq(route.due(id, 0, 25), list(address(receiver)));
        assertEq(deliverAs(courier, id, list(address(receiver))).length, 0);
        assertEq(route.lastDeliveredAt(address(receiver)), 0);
        assertEq(route.lastIssue(address(receiver)), 0);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
        receiver.setRejecting(false);
        assertEq(deliverAs(bob, id, list(address(receiver))), list(address(receiver)));
        assertEq(route.editionsLeft(address(receiver)), 1);
        assertEq(daily.balanceOf(address(receiver), id), 1);
        assertEq(imd.balanceOf(courier), 0);
        assertEq(imd.balanceOf(bob), TIP);
        assertEq(deliverAs(courier, id, list(address(receiver))).length, 0);
    }

    function test_wrongSelectorAndLargeRevertDataCannotBlockNextReader() public {
        WrongSelectorReceiver wrong = new WrongSelectorReceiver();
        ReturnBombReceiver bomb = new ReturnBombReceiver();
        subscribeAs(address(wrong), 2);
        subscribeAs(address(bomb), 2);
        subscribeAs(alice, 2);
        uint256 id = publishIssue();
        vm.prank(courier);
        address[] memory served =
            route.deliver{gas: 2_000_000}(id, list(address(wrong), address(bomb), alice));
        assertEq(served, list(alice));
        assertEq(route.editionsLeft(address(wrong)), 2);
        assertEq(route.editionsLeft(address(bomb)), 2);
        assertEq(route.lastIssue(address(wrong)), 0);
        assertEq(route.lastDeliveredAt(address(bomb)), 0);
        assertEq(daily.totalSupply(id), 1);
        assertEq(imd.balanceOf(address(vault)), COPY);
        assertEq(imd.balanceOf(courier), TIP);
        assertEq(imd.balanceOf(address(route)), 5 * EDITION);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
    }

    function test_allMintsFailLeavingEverythingRefundableAndNoAllowance() public {
        RevertingReceiver receiver = new RevertingReceiver();
        GasBurningReceiver burner = new GasBurningReceiver();
        subscribeAs(address(receiver), 2);
        subscribeAs(address(burner), 3);
        uint256 id = publishIssue();
        vm.prank(courier);
        assertEq(route.deliver{gas: 2_000_000}(id, list(address(receiver), address(burner))).length, 0);
        assertEq(daily.totalSupply(id), 0);
        assertEq(daily.totalCollected(), 0);
        assertEq(imd.balanceOf(courier), 0);
        assertEq(imd.balanceOf(address(route)), 5 * EDITION);
        assertEq(route.reservedBalance(), 5 * EDITION);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
        vm.prank(address(receiver));
        route.cancel();
        vm.prank(address(burner));
        route.cancel();
        assertEq(imd.balanceOf(address(receiver)), 2 * EDITION);
        assertEq(imd.balanceOf(address(burner)), 3 * EDITION);
    }

    function test_selfDeliveryPaysOwnTipAndRefundOnlyUnusedCredit() public {
        subscribeAs(alice, 2);
        uint256 id = publishIssue();
        assertEq(deliverAs(alice, id, list(alice)), list(alice));
        assertEq(imd.balanceOf(alice), TIP);
        vm.prank(alice);
        route.cancel();
        assertEq(imd.balanceOf(alice), EDITION + TIP);
        assertEq(imd.balanceOf(address(vault)), COPY);
        assertEq(daily.balanceOf(alice, id), 1);
        _assertEmpty(alice);
    }

    function test_competingCouriersCannotEarnTwoTipsForSameCopy() public {
        subscribeAs(alice, 2);
        uint256 id = publishIssue();
        address[] memory stalePage = route.due(id, 0, 25);
        assertEq(deliverAs(courier, id, stalePage), list(alice));
        assertEq(deliverAs(bob, id, stalePage).length, 0);
        assertEq(imd.balanceOf(courier), TIP);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(daily.balanceOf(alice, id), 1);
        assertEq(route.editionsLeft(alice), 1);
    }

    function test_cancelAndResubscribeCannotResetTwentyHourRule() public {
        subscribeAs(alice, 2);
        uint256 first = publishIssue();
        deliverAs(courier, first, list(alice));
        uint256 deliveredAt = vm.getBlockTimestamp();
        vm.prank(alice);
        route.cancel();
        subscribeAs(alice, 2);
        uint256 second = publishIssue();
        assertEq(deliverAs(courier, second, list(alice)).length, 0);
        vm.warp(deliveredAt + 20 hours - 1);
        assertEq(route.due(second, 0, 25).length, 0);
        assertEq(deliverAs(courier, second, list(alice)).length, 0);
        vm.warp(deliveredAt + 20 hours);
        assertEq(route.due(second, 0, 25), list(alice));
        assertEq(deliverAs(courier, second, list(alice)), list(alice));
    }

    function test_exhaustedCreditTopUpCannotResetHistory() public {
        subscribeAs(alice, 1);
        uint256 first = publishIssue();
        deliverAs(courier, first, list(alice));
        assertEq(route.subscriberCount(), 0);
        subscribeAs(alice, 2);
        uint256 second = publishIssue();
        assertEq(deliverAs(courier, first, list(alice)).length, 0);
        assertEq(deliverAs(courier, second, list(alice)).length, 0);
        assertEq(route.editionsLeft(alice), 2);
        assertEq(route.subscriberCount(), 1);
        assertEq(route.lastIssue(alice), first);
    }

    function test_openEarlierIssueStillSkippedAfterTwentyHours() public {
        subscribeAs(alice, 3);
        uint256 first = publishIssue();
        uint256 second = publishIssue();
        deliverAs(courier, second, list(alice));
        vm.warp(vm.getBlockTimestamp() + 20 hours);
        assertTrue(daily.isAvailable(first));
        vm.expectEmit(true, true, true, true, address(route));
        emit PaperRoute.Skipped(first, alice, PaperRoute.SkipReason.AlreadyDelivered);
        assertEq(deliverAs(bob, first, list(alice)).length, 0);
        assertEq(daily.balanceOf(alice, first), 0);
        assertEq(route.lastIssue(alice), second);
        assertEq(route.editionsLeft(alice), 2);
        assertEq(imd.balanceOf(bob), 0);
    }

    function test_noMintAttemptWithoutEntireGasAllowance() public {
        subscribeAs(alice, 2);
        uint256 id = publishIssue();
        vm.expectCall(DAILY_ADDRESS, abi.encodeWithSelector(IIMDDaily.mint.selector), uint64(0));
        vm.expectEmit(true, true, true, true, address(route));
        emit PaperRoute.Skipped(id, alice, PaperRoute.SkipReason.GasAllowance);
        vm.prank(courier);
        assertEq(route.deliver{gas: 550_000}(id, list(alice)).length, 0);
        assertEq(route.editionsLeft(alice), 2);
        assertEq(route.lastDeliveredAt(alice), 0);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
    }

    function test_successfulMintForwardsWholeAllowanceAndExactArguments() public {
        subscribeAs(alice, 1);
        uint256 id = publishIssue();
        vm.expectCallMinGas(
            DAILY_ADDRESS,
            0,
            uint64(route.MINT_GAS()),
            abi.encodeCall(IIMDDaily.mint, (id, 1, alice, vm.getBlockTimestamp())),
            1
        );
        vm.prank(courier);
        assertEq(route.deliver{gas: 800_000}(id, list(alice)), list(alice));
        assertEq(daily.balanceOf(alice, id), 1);
    }

    function test_gasTruncatedBatchCanBeRetriedWithoutChargingFirstReaderAgain() public {
        subscribeAs(alice, 2);
        subscribeAs(bob, 2);
        uint256 id = publishIssue();
        address[] memory readers = list(alice, bob);
        vm.prank(courier);
        assertEq(route.deliver{gas: 760_000}(id, readers), list(alice));
        assertEq(route.due(id, 0, 25), list(bob));
        assertEq(deliverAs(carol, id, readers), list(bob));
        assertEq(daily.balanceOf(alice, id), 1);
        assertEq(daily.balanceOf(bob, id), 1);
        assertEq(route.editionsLeft(alice), 1);
        assertEq(route.editionsLeft(bob), 1);
        assertEq(imd.balanceOf(courier), TIP);
        assertEq(imd.balanceOf(carol), TIP);
        assertEq(imd.balanceOf(address(vault)), 2 * COPY);
        assertEq(imd.balanceOf(address(route)), 2 * EDITION);
    }

    function test_twentyFiveGasBurnersFitEthereumTransactionLimit() public {
        address[] memory readers = new address[](25);
        for (uint256 i; i < readers.length; ++i) {
            readers[i] = address(new GasBurningReceiver());
            subscribeAs(readers[i], 1);
        }
        uint256 id = publishIssue();
        vm.expectCallMinGas(
            DAILY_ADDRESS, 0, uint64(route.MINT_GAS()), abi.encodeWithSelector(IIMDDaily.mint.selector), 25
        );
        vm.prank(courier);
        assertEq(route.deliver{gas: 16_000_000}(id, readers).length, 0);
        assertEq(route.reservedEditions(), 25);
        assertEq(route.subscriberCount(), 25);
        assertEq(daily.totalSupply(id), 0);
        assertEq(imd.balanceOf(address(route)), 25 * EDITION);
        assertEq(imd.balanceOf(courier), 0);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
    }

    function test_twentyFourGasBurnersDoNotStarveFinalHealthySubscriber() public {
        address[] memory readers = new address[](25);
        for (uint256 i; i < 24; ++i) {
            readers[i] = address(new GasBurningReceiver());
            subscribeAs(readers[i], 1);
        }
        readers[24] = alice;
        subscribeAs(alice, 1);
        uint256 id = publishIssue();
        vm.expectCallMinGas(
            DAILY_ADDRESS, 0, uint64(route.MINT_GAS()), abi.encodeWithSelector(IIMDDaily.mint.selector), 25
        );
        vm.prank(courier);
        assertEq(route.deliver{gas: 16_000_000}(id, readers), list(alice));
        assertEq(route.reservedEditions(), 24);
        assertEq(route.subscriberCount(), 24);
        assertEq(daily.balanceOf(alice, id), 1);
        assertEq(imd.balanceOf(address(route)), 24 * EDITION);
        assertEq(imd.balanceOf(courier), TIP);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
    }

    function _adversarialToken() internal returns (AdversarialIMD token) {
        vm.etch(IMD_ADDRESS, address(new AdversarialIMD()).code);
        token = AdversarialIMD(IMD_ADDRESS);
    }

    function _assertEmpty(address who) internal view {
        assertEq(route.editionsLeft(who), 0);
        assertEq(route.reservedEditions(), 0);
        assertEq(route.subscriberCount(), 0);
        assertEq(imd.balanceOf(address(route)), 0);
    }
}
