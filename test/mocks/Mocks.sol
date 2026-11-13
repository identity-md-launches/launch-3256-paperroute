// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {PaperRoute} from "../../src/PaperRoute.sol";

/// @dev Stand-in for IMD: a plain 18-decimal ERC-20 whose code is etched at the real IMD address.
contract MockIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Every call reverts: stands in for a stopped or broken IMD Daily.
contract Reverter {
    fallback() external payable {
        revert("stopped");
    }
}

/// @dev A contract subscriber that accepts copies.
contract AcceptingReceiver is ERC1155Holder {}

/// @dev A contract subscriber whose receiver hook reverts.
contract RevertingReceiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("no thanks");
    }
}

/// @dev A contract subscriber whose receiver hook burns every unit of gas it is given.
contract GasBurningReceiver {
    uint256 private _sink;

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        while (true) {
            _sink += 1;
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }
}

/// @dev A contract subscriber that re-enters Paper Route from the receiver hook and lets the revert bubble.
contract ReentrantReceiver {
    PaperRoute public immutable route;
    uint8 public mode; // 0 = cancel, 1 = subscribe, 2 = deliver

    constructor(PaperRoute route_) {
        route = route_;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (mode == 0) {
            route.cancel();
        } else if (mode == 1) {
            route.subscribe(1);
        } else {
            address[] memory list = new address[](1);
            list[0] = address(this);
            route.deliver(id, list);
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }
}

/// @dev A contract subscriber that tries to re-enter, swallows the failure, and accepts the copy anyway.
contract SneakyReentrantReceiver {
    PaperRoute public immutable route;
    uint256 public attempts;
    uint256 public successes;

    constructor(PaperRoute route_) {
        route = route_;
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        attempts += 1;
        try route.cancel() {
            successes += 1;
        } catch {}
        address[] memory list = new address[](1);
        list[0] = address(this);
        try route.deliver(id, list) {
            successes += 1;
        } catch {}
        return IERC1155Receiver.onERC1155Received.selector;
    }
}
