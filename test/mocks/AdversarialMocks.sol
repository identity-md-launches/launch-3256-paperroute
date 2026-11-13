// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockIMD} from "./Mocks.sol";
import {PaperRoute} from "../../src/PaperRoute.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @dev Payment faults are opt-in; normal transfers have the same semantics as MockIMD.
contract AdversarialIMD is MockIMD {
    enum Incoming {
        Exact,
        ShortByOneWei,
        ExcessByOneWei,
        ReturnFalse,
        NoReturn
    }
    Incoming public incoming;
    bool public failOutgoing;
    bool public failApproval;

    function configure(Incoming mode, bool outgoing, bool approval) external {
        incoming = mode;
        failOutgoing = outgoing;
        failApproval = approval;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (incoming == Incoming.ReturnFalse) return false;
        if (incoming == Incoming.ShortByOneWei) return super.transferFrom(from, to, amount - 1);
        bool result = super.transferFrom(from, to, amount);
        if (incoming == Incoming.ExcessByOneWei) _mint(to, 1);
        if (incoming == Incoming.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return result;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Deliberately mutate before returning false: the caller must roll the transfer back too.
        bool result = super.transfer(to, amount);
        return failOutgoing ? false : result;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (failApproval) return false;
        return super.approve(spender, amount);
    }
}

/// @dev Tries all mutating entry points, records their exact errors, then accepts the copy.
///      Tests fund its extra subscribe attempt so a missing guard cannot hide behind a token failure.
contract GuardProbeReceiver {
    PaperRoute public immutable route;
    uint256 public attempts;
    uint256 public successes;
    bytes4 public cancelError;
    bytes4 public subscribeError;
    bytes4 public deliverError;

    constructor(PaperRoute route_) {
        route = route_;
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        cancelError = _attempt(abi.encodeCall(route.cancel, ()));
        subscribeError = _attempt(abi.encodeCall(route.subscribe, (1)));
        address[] memory readers = new address[](1);
        readers[0] = address(this);
        deliverError = _attempt(abi.encodeCall(route.deliver, (id, readers)));
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function _attempt(bytes memory data) private returns (bytes4 errorSelector) {
        ++attempts;
        (bool ok, bytes memory result) = address(route).call(data);
        if (ok) ++successes;
        if (result.length >= 4) {
            assembly ("memory-safe") { errorSelector := mload(add(result, 32)) }
        }
    }
}

/// @dev Can recover from rejecting copies; tests prove a skipped attempt leaves it due for a retry.
contract SwitchableReceiver {
    bool public rejecting = true;

    function setRejecting(bool value) external {
        rejecting = value;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        require(!rejecting, "receiver unavailable");
        return IERC1155Receiver.onERC1155Received.selector;
    }
}

contract WrongSelectorReceiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return bytes4(0);
    }
}

/// @dev Exercises large revert data inside the bounded mint call.
contract ReturnBombReceiver {
    fallback() external {
        assembly ("memory-safe") { revert(0, 65536) }
    }
}
