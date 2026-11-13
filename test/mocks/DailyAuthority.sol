// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed Ethereum IMD and the publisher specified for this collection.
/// @dev Neither the deployment factory nor the transaction sender receives authority.
abstract contract DailyAuthority {
    address public constant PUBLISHER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    address public constant PAYMENT_TOKEN = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint8 public constant PAYMENT_DECIMALS = 18;

    error OnlyPublisher();

    modifier onlyPublisher() {
        if (msg.sender != PUBLISHER) revert OnlyPublisher();
        _;
    }

    /// @notice Conventional authority discovery. There is no ownership transfer function.
    function owner() external pure returns (address) {
        return PUBLISHER;
    }
}

