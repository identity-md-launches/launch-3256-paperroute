// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DailyAuthority} from "./DailyAuthority.sol";

/// @notice Receives IMD directly. Only the fixed publisher can withdraw, to itself.
/// @dev Deploy this before IMDDaily. No initializer, collection registration, or external constructor call.
///      Mint revenue is accounted in IMDDaily.totalCollected(); direct transfers are not mint revenue.
contract IMDDailyVault is DailyAuthority, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice All IMD paid out, including any donated IMD. Never inferred from balance changes.
    uint256 public totalWithdrawn;

    error ZeroAmount();
    error InsufficientFunds(uint256 available, uint256 requested);
    error InexactWithdrawal();

    event Withdrawal(address indexed publisher, uint256 amount, uint256 totalWithdrawn);

    function balance() public view returns (uint256) {
        return IERC20(PAYMENT_TOKEN).balanceOf(address(this));
    }

    /// @notice Withdraw any positive amount up to the actual IMD balance, including donations.
    function withdraw(uint256 amount) external nonReentrant onlyPublisher {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(PAYMENT_TOKEN);
        uint256 beforeVault = token.balanceOf(address(this));
        if (amount > beforeVault) revert InsufficientFunds(beforeVault, amount);
        uint256 beforePublisher = token.balanceOf(PUBLISHER);

        totalWithdrawn += amount;
        token.safeTransfer(PUBLISHER, amount);
        if (
            token.balanceOf(address(this)) != beforeVault - amount
                || token.balanceOf(PUBLISHER) != beforePublisher + amount
        ) revert InexactWithdrawal();

        emit Withdrawal(PUBLISHER, amount, totalWithdrawn);
    }
}

