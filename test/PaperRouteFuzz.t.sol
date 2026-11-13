// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PaperRouteBase} from "./PaperRouteBase.t.sol";
import {PaperRoute} from "../src/PaperRoute.sol";
import {RevertingReceiver, GasBurningReceiver} from "./mocks/Mocks.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// forge-config: default.fuzz.runs = 1000
contract PaperRouteFuzzTest is PaperRouteBase {
    function testFuzz_purchaseDeliveryRefundConservesEveryWei(
        uint128 initialSeed,
        uint128 topUpSeed,
        uint8 deliveriesSeed,
        uint128 donation
    ) public {
        uint256 initial = bound(uint256(initialSeed), 1, uint256(type(uint128).max) / 2);
        uint256 topUp = bound(uint256(topUpSeed), 1, uint256(type(uint128).max) - initial);
        uint256 purchased = initial + topUp;
        uint256 count = bound(deliveriesSeed, 0, purchased < 6 ? purchased : 6);
        subscribeAs(alice, initial);
        subscribeAs(alice, topUp);
        imd.mint(bob, donation);
        vm.prank(bob);
        imd.transfer(address(route), donation);
        for (uint256 i; i < count; ++i) {
            uint256 issue = publishIssue();
            assertEq(deliverAs(courier, issue, list(alice)), list(alice));
            assertEq(daily.balanceOf(alice, issue), 1);
            vm.warp(vm.getBlockTimestamp() + 20 hours);
        }
        uint256 remaining = purchased - count;
        assertEq(route.editionsLeft(alice), remaining);
        assertEq(route.reservedBalance(), remaining * EDITION);
        if (remaining > 0) {
            vm.prank(alice);
            route.cancel();
        }
        assertEq(imd.balanceOf(alice), remaining * EDITION);
        assertEq(imd.balanceOf(courier), count * TIP);
        assertEq(imd.balanceOf(address(vault)), count * COPY);
        assertEq(
            imd.balanceOf(alice) + imd.balanceOf(courier) + imd.balanceOf(address(vault)), purchased * EDITION
        );
        assertEq(imd.balanceOf(address(route)), donation, "donations never become refunds or tips");
        assertEq(route.surplus(), donation);
        assertEq(route.reservedEditions(), 0);
        assertEq(route.subscriberCount(), 0);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
    }

    function testFuzz_tooLargeCreditNeverPullsTokens(uint256 seed) public {
        uint256 editions = bound(seed, uint256(type(uint128).max) + 1, type(uint256).max / EDITION);
        fund(alice, 5 ether);
        vm.expectRevert(PaperRoute.TooManyEditions.selector);
        vm.prank(alice);
        route.subscribe(editions);
        assertEq(imd.balanceOf(alice), 5 ether);
        assertEq(imd.balanceOf(address(route)), 0);
        assertEq(route.reservedEditions(), 0);
        assertEq(route.subscriberCount(), 0);
    }

    function testFuzz_shortAllowanceIsAtomic(uint128 editionsSeed, uint256 shortfallSeed) public {
        uint256 editions = bound(editionsSeed, 1, type(uint128).max);
        uint256 amount = editions * EDITION;
        uint256 allowance = amount - bound(shortfallSeed, 1, amount);
        fund(alice, amount);
        vm.prank(alice);
        imd.approve(address(route), allowance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(route), allowance, amount
            )
        );
        vm.prank(alice);
        route.subscribe(editions);
        assertEq(imd.balanceOf(alice), amount);
        assertEq(imd.allowance(alice, address(route)), allowance);
        assertEq(route.editionsLeft(alice), 0);
        assertEq(route.reservedEditions(), 0);
        assertEq(route.subscriberCount(), 0);
    }

    function testFuzz_shortBalanceIsAtomic(uint128 editionsSeed, uint256 shortfallSeed) public {
        uint256 editions = bound(editionsSeed, 1, type(uint128).max);
        uint256 amount = editions * EDITION;
        uint256 balance = amount - bound(shortfallSeed, 1, amount);
        fund(alice, balance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount)
        );
        vm.prank(alice);
        route.subscribe(editions);
        assertEq(imd.balanceOf(alice), balance);
        assertEq(imd.balanceOf(address(route)), 0);
        assertEq(route.editionsLeft(alice), 0);
        assertEq(route.reservedEditions(), 0);
        assertEq(route.subscriberCount(), 0);
    }

    function testFuzz_twentyHourBoundaryControlsActualMint(uint256 elapsedSeed) public {
        uint256 elapsed = bound(elapsedSeed, 0, 24 hours - 1);
        subscribeAs(alice, 3);
        uint256 first = publishIssue();
        uint256 second = publishIssue();
        deliverAs(courier, first, list(alice));
        uint256 firstAt = vm.getBlockTimestamp();
        vm.warp(firstAt + elapsed);
        bool expectedDue = elapsed >= 20 hours;
        (bool isDue,) = route.dueStatus(alice, second);
        assertEq(isDue, expectedDue);
        assertEq(route.due(second, 0, 1).length, expectedDue ? 1 : 0);
        uint256 delivered = deliverAs(courier, second, list(alice)).length;
        assertEq(delivered, expectedDue ? 1 : 0);
        assertEq(route.editionsLeft(alice), 2 - delivered);
        assertEq(route.lastDeliveredAt(alice), expectedDue ? firstAt + elapsed : firstAt);
        assertEq(route.lastIssue(alice), expectedDue ? second : first);
        assertEq(daily.balanceOf(alice, second), delivered);
        assertEq(imd.balanceOf(courier), (1 + delivered) * TIP);
        assertEq(imd.balanceOf(address(route)), (2 - delivered) * EDITION);
    }

    function testFuzz_issueWindowIncludesPublicationExcludesClosing(uint256 elapsedSeed) public {
        uint256 elapsed = bound(elapsedSeed, 0, 48 hours);
        subscribeAs(alice, 1);
        uint256 issue = publishIssue();
        vm.warp(vm.getBlockTimestamp() + elapsed);
        if (elapsed < 24 hours) {
            assertEq(deliverAs(courier, issue, list(alice)), list(alice));
            assertEq(daily.balanceOf(alice, issue), 1);
            assertEq(route.editionsLeft(alice), 0);
        } else {
            vm.expectRevert(abi.encodeWithSelector(PaperRoute.IssueNotOpen.selector, issue));
            vm.prank(courier);
            route.deliver(issue, list(alice));
            assertEq(route.due(issue, 0, type(uint256).max).length, 0);
            assertEq(route.editionsLeft(alice), 1);
            assertEq(imd.balanceOf(courier), 0);
            vm.prank(alice);
            route.cancel();
            assertEq(imd.balanceOf(alice), EDITION);
        }
    }

    function testFuzz_unknownIssueCannotMoveMoney(uint256 issueSeed) public {
        subscribeAs(alice, 2);
        publishIssue();
        uint256 issue = issueSeed == 0 ? 0 : bound(issueSeed, 2, type(uint256).max);
        assertEq(route.due(issue, 0, type(uint256).max).length, 0);
        vm.expectRevert(abi.encodeWithSelector(PaperRoute.IssueNotOpen.selector, issue));
        vm.prank(courier);
        route.deliver(issue, list(alice));
        assertEq(route.editionsLeft(alice), 2);
        assertEq(route.reservedEditions(), 2);
        assertEq(imd.balanceOf(address(route)), 2 * EDITION);
        assertEq(imd.balanceOf(courier), 0);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function testFuzz_arbitraryBatchOrderAndDuplicatesHaveExactResults(uint256 seed, uint8 lengthSeed)
        public
    {
        RevertingReceiver bad = new RevertingReceiver();
        address[5] memory readers = [alice, bob, carol, address(bad), courier];
        for (uint256 i; i < 4; ++i) {
            subscribeAs(readers[i], 2);
        }
        uint256 issue = publishIssue();
        uint256 length = bound(lengthSeed, 0, 25);
        address[] memory batch = new address[](length);
        address[] memory expected = new address[](3);
        bool[5] memory seen;
        uint256 expectedCount;
        for (uint256 i; i < length; ++i) {
            uint256 index = uint256(keccak256(abi.encode(seed, i))) % 5;
            batch[i] = readers[index];
            if (index < 3 && !seen[index]) expected[expectedCount++] = readers[index];
            seen[index] = true;
        }
        assembly ("memory-safe") { mstore(expected, expectedCount) }
        vm.prank(courier);
        assertEq(route.deliver{gas: 8_000_000}(issue, batch), expected);
        for (uint256 i; i < 3; ++i) {
            assertEq(daily.balanceOf(readers[i], issue), seen[i] ? 1 : 0);
            assertEq(route.editionsLeft(readers[i]), seen[i] ? 1 : 2);
        }
        assertEq(route.editionsLeft(address(bad)), 2);
        assertEq(route.lastIssue(address(bad)), 0);
        assertEq(daily.balanceOf(address(bad), issue), 0);
        assertEq(imd.balanceOf(courier), expectedCount * TIP);
        assertEq(imd.balanceOf(address(vault)), expectedCount * COPY);
        assertEq(imd.balanceOf(address(route)), (8 - expectedCount) * EDITION);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
    }

    function testFuzz_pagesHandleOverflowAndFilterWithinSourcePage(uint256 offsetSeed, uint256 limitSeed)
        public
    {
        subscribeAs(alice, 2);
        subscribeAs(bob, 2);
        subscribeAs(carol, 2);
        uint256 issue = publishIssue();
        deliverAs(courier, issue, list(bob));
        // Use small meaningful pages as well as raw full-width offsets/limits (including max uint).
        uint256 offset = offsetSeed % 4 == 0 ? offsetSeed : offsetSeed % 5;
        uint256 limit = limitSeed % 4 == 0 ? limitSeed : limitSeed % 5;
        address[] memory all = list(alice, bob, carol);
        uint256 start = offset > 3 ? 3 : offset;
        uint256 length = limit > 3 - start ? 3 - start : limit;
        address[] memory expectedPage = new address[](length);
        address[] memory expectedDue = new address[](length);
        uint256 dueCount;
        for (uint256 i; i < length; ++i) {
            expectedPage[i] = all[start + i];
            if (all[start + i] != bob) expectedDue[dueCount++] = all[start + i];
        }
        assembly ("memory-safe") { mstore(expectedDue, dueCount) }
        assertEq(route.subscribers(offset, limit), expectedPage);
        assertEq(route.due(issue, offset, limit), expectedDue);
    }

    function testFuzz_gasBoundedBatchCommitsPrefixOrNothing(uint256 gasSeed) public {
        uint256 gasBudget = bound(gasSeed, 100_000, 2_000_000);
        GasBurningReceiver burner = new GasBurningReceiver();
        subscribeAs(alice, 2);
        subscribeAs(address(burner), 2);
        subscribeAs(bob, 2);
        uint256 issue = publishIssue();
        vm.prank(courier);
        (bool ok, bytes memory result) = address(route).call{gas: gasBudget}(
            abi.encodeCall(route.deliver, (issue, list(alice, address(burner), bob)))
        );
        // This bounded list and budget can always return cleanly, even when no mint can be attempted.
        assertTrue(ok, "gas exhaustion should cut this bounded list short, not revert");
        address[] memory delivered = abi.decode(result, (address[]));
        assertLe(delivered.length, 2);
        if (delivered.length > 0) assertEq(delivered[0], alice);
        if (delivered.length == 2) assertEq(delivered[1], bob);
        assertEq(route.editionsLeft(alice), delivered.length > 0 ? 1 : 2);
        assertEq(route.editionsLeft(bob), delivered.length == 2 ? 1 : 2);
        assertEq(route.editionsLeft(address(burner)), 2);
        assertEq(route.lastDeliveredAt(address(burner)), 0);
        assertEq(daily.balanceOf(address(burner), issue), 0);
        assertEq(imd.balanceOf(courier), delivered.length * TIP);
        assertEq(imd.balanceOf(address(vault)), delivered.length * COPY);
        assertEq(imd.balanceOf(address(route)), (6 - delivered.length) * EDITION);
        assertEq(route.reservedEditions(), 6 - delivered.length);
        assertEq(imd.allowance(address(route), DAILY_ADDRESS), 0);
    }
}
