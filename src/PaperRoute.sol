// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The subset of The IMD Daily (ERC-1155) that Paper Route calls.
interface IIMDDaily {
    function mint(uint256 id, uint256 quantity, address recipient, uint256 deadline) external;
    function isAvailable(uint256 id) external view returns (bool);
    function issueCount() external view returns (uint256);
}

/// @title Paper Route: a prepaid subscription to The IMD Daily.
/// @notice A reader pays 0.125 IMD an edition up front. Anyone may then deliver an open issue to every
///         subscriber who is due: one copy is minted from The IMD Daily to the subscriber for 0.1 IMD out
///         of their credit, and the deliverer earns the remaining 0.025 IMD as a tip.
/// @dev Unofficial and not run by The IMD Daily's publisher. Non-upgradeable, no owner, no admin, no fee to
///      its maker, no pause, and nothing to call after deployment. The two existing contracts are constants,
///      so the constructor makes no external call and deploys on an empty chain.
///
///      Custody rule: a subscriber's IMD leaves this contract only as 0.1 IMD to The IMD Daily for a copy
///      minted to that subscriber, 0.025 IMD to whoever delivered that copy, or a refund to that subscriber.
///      The IMD held is therefore never less than `reservedEditions * EDITION_PRICE`; IMD sent in outside
///      `subscribe` is not counted and simply stays here.
contract PaperRoute is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Fixed configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice IMD, the ERC-20 (18 decimals) both this contract and The IMD Daily are paid in.
    IERC20 public constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    /// @notice The IMD Daily, the ERC-1155 collection whose copies are delivered.
    IIMDDaily public constant DAILY = IIMDDaily(0xB8FD2b7fb37cbf03A26B4c4688eD5ccE86C0a9c5);

    /// @notice What The IMD Daily charges for one copy (its `PRICE`).
    uint256 public constant COPY_PRICE = 0.1 ether;
    /// @notice What the deliverer earns for one delivered copy.
    uint256 public constant TIP = 0.025 ether;
    /// @notice What a subscriber pays for one edition of credit.
    uint256 public constant EDITION_PRICE = COPY_PRICE + TIP;
    /// @notice A subscriber is delivered at most once per this interval.
    uint256 public constant DELIVERY_INTERVAL = 20 hours;

    /// @notice Gas forwarded to every `mint` attempt (The IMD Daily's own work plus the subscriber's
    ///         ERC-1155 receiver hook). A receiver that needs more fails inside this allowance and is skipped.
    uint256 public constant MINT_GAS = 400_000;
    /// @dev Gas that must still be available before a mint is attempted, so that EIP-150's 63/64 rule
    ///      forwards the whole `MINT_GAS`, the approval before the call fits, and the bookkeeping, tip
    ///      transfer and return after a gas-burning receiver still fit. A list is cut short, never reverted,
    ///      when less remains.
    uint256 private constant MINT_GAS_FLOOR = MINT_GAS + MINT_GAS / 63 + 1 + 150_000;

    // ---------------------------------------------------------------------------------------------
    // Types, events, errors
    // ---------------------------------------------------------------------------------------------

    struct Subscription {
        /// @dev Prepaid editions not yet delivered.
        uint128 editionsLeft;
        /// @dev Highest issue id delivered by Paper Route (0 = none yet).
        uint64 lastIssue;
        /// @dev Timestamp of the last delivery by Paper Route (0 = none yet).
        uint64 lastDeliveredAt;
    }

    /// @notice Why a listed subscriber was not delivered.
    enum SkipReason {
        NoCredit,
        AlreadyDelivered,
        TooSoon,
        GasAllowance,
        MintFailed
    }

    event Subscribed(address indexed subscriber, uint256 editions, uint256 amount, uint256 editionsLeft);
    event Cancelled(address indexed subscriber, uint256 editions, uint256 amount);
    event Delivered(uint256 indexed issueId, address indexed subscriber, address indexed deliverer);
    event Skipped(uint256 indexed issueId, address indexed subscriber, SkipReason reason);

    error ZeroEditions();
    error TooManyEditions();
    error InexactPayment();
    error NoSubscription();
    error IssueNotOpen(uint256 issueId);

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(address subscriber => Subscription) private _subscriptions;
    /// @dev Every address with credit, in no particular order.
    address[] private _subscribers;
    /// @dev Position in `_subscribers` plus one; zero means absent.
    mapping(address subscriber => uint256) private _subscriberIndex;

    /// @notice Sum of every subscriber's unused editions. `reservedEditions * EDITION_PRICE` is always
    ///         covered by the IMD this contract holds.
    uint256 public reservedEditions;

    // ---------------------------------------------------------------------------------------------
    // Subscribers
    // ---------------------------------------------------------------------------------------------

    /// @notice Pull `editions * 0.125 IMD` from the caller and add the editions to the caller's credit.
    ///         The caller must have approved this contract for the amount. Calling again adds more.
    function subscribe(uint256 editions) external nonReentrant {
        if (editions == 0) revert ZeroEditions();
        uint256 amount = editions * EDITION_PRICE;
        Subscription storage sub = _subscriptions[msg.sender];
        uint256 newLeft = uint256(sub.editionsLeft) + editions;
        if (newLeft > type(uint128).max) revert TooManyEditions();

        if (sub.editionsLeft == 0) _addSubscriber(msg.sender);
        sub.editionsLeft = uint128(newLeft);
        reservedEditions += editions;

        uint256 before = IMD.balanceOf(address(this));
        IMD.safeTransferFrom(msg.sender, address(this), amount);
        if (IMD.balanceOf(address(this)) != before + amount) revert InexactPayment();

        emit Subscribed(msg.sender, editions, amount, newLeft);
    }

    /// @notice Refund the caller's unused editions in full and end the subscription. Touches only IMD,
    ///         never The IMD Daily, so it works whatever state that contract is in. Delivery history
    ///         (last issue, last delivery time) is kept so a later subscription still gets one copy an issue.
    function cancel() external nonReentrant {
        Subscription storage sub = _subscriptions[msg.sender];
        uint256 editions = sub.editionsLeft;
        if (editions == 0) revert NoSubscription();

        sub.editionsLeft = 0;
        reservedEditions -= editions;
        _removeSubscriber(msg.sender);

        uint256 amount = editions * EDITION_PRICE;
        IMD.safeTransfer(msg.sender, amount);
        emit Cancelled(msg.sender, editions, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Delivery
    // ---------------------------------------------------------------------------------------------

    /// @notice Deliver `issueId`, which must be open for minting, to every listed subscriber who is due:
    ///         has credit, has not had this issue or a later one from Paper Route, and whose last delivery
    ///         was at least `DELIVERY_INTERVAL` ago. Each delivery takes one edition of credit, mints one
    ///         copy to the subscriber (paid 0.1 IMD from the IMD held here) and earns the caller 0.025 IMD,
    ///         paid at the end. A subscriber who is not due, or whose mint fails (a reverting receiver, a
    ///         receiver that needs more than `MINT_GAS`, or any other revert), is skipped with nothing
    ///         charged, and the rest of the list goes on. When too little gas remains to forward a whole
    ///         `MINT_GAS`, the rest of the list is left for another call instead of reverting.
    /// @return delivered The subscribers who received a copy in this call, in list order.
    function deliver(uint256 issueId, address[] calldata readers)
        external
        nonReentrant
        returns (address[] memory delivered)
    {
        if (!DAILY.isAvailable(issueId)) revert IssueNotOpen(issueId);

        delivered = new address[](readers.length);
        uint256 count;
        bool approvalLeft;

        for (uint256 i; i < readers.length; ++i) {
            address subscriber = readers[i];
            Subscription storage sub = _subscriptions[subscriber];
            (bool isDue, SkipReason reason) = _dueStatus(sub, issueId);
            if (!isDue) {
                emit Skipped(issueId, subscriber, reason);
                continue;
            }
            if (gasleft() < MINT_GAS_FLOOR) {
                emit Skipped(issueId, subscriber, SkipReason.GasAllowance);
                break;
            }

            // The IMD Daily pulls exactly COPY_PRICE from msg.sender, so the allowance is exactly that.
            IMD.forceApprove(address(DAILY), COPY_PRICE);
            try DAILY.mint{gas: MINT_GAS}(issueId, 1, subscriber, block.timestamp) {
                uint256 left = sub.editionsLeft - 1;
                sub.editionsLeft = uint128(left);
                sub.lastIssue = uint64(issueId);
                sub.lastDeliveredAt = uint64(block.timestamp);
                reservedEditions -= 1;
                if (left == 0) _removeSubscriber(subscriber);
                delivered[count++] = subscriber;
                emit Delivered(issueId, subscriber, msg.sender);
            } catch {
                // The IMD Daily reverted as a whole: no payment left, no copy minted, nothing charged.
                approvalLeft = true;
                emit Skipped(issueId, subscriber, SkipReason.MintFailed);
            }
        }

        if (approvalLeft) IMD.forceApprove(address(DAILY), 0);
        if (count > 0) IMD.safeTransfer(msg.sender, count * TIP);

        assembly ("memory-safe") {
            mstore(delivered, count)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice A subscriber's record: editions left, last issue delivered and last delivery time.
    function subscriptionOf(address subscriber) external view returns (Subscription memory) {
        return _subscriptions[subscriber];
    }

    /// @notice Prepaid editions `subscriber` has not yet received.
    function editionsLeft(address subscriber) external view returns (uint256) {
        return _subscriptions[subscriber].editionsLeft;
    }

    /// @notice Highest issue id Paper Route has delivered to `subscriber` (0 = none).
    function lastIssue(address subscriber) external view returns (uint256) {
        return _subscriptions[subscriber].lastIssue;
    }

    /// @notice When Paper Route last delivered to `subscriber` (0 = never).
    function lastDeliveredAt(address subscriber) external view returns (uint256) {
        return _subscriptions[subscriber].lastDeliveredAt;
    }

    /// @notice Number of addresses with credit.
    function subscriberCount() external view returns (uint256) {
        return _subscribers.length;
    }

    /// @notice A page of the addresses with credit, in storage order.
    function subscribers(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        (uint256 start, uint256 end) = _page(_subscribers.length, offset, limit);
        page = new address[](end - start);
        for (uint256 i = start; i < end; ++i) {
            page[i - start] = _subscribers[i];
        }
    }

    /// @notice The subscribers, among page `offset`/`limit` of those with credit, that a `deliver` call
    ///         for `issueId` would serve now. Empty when the issue is not open for minting. A subscriber
    ///         whose receiver rejects the copy is listed here but skipped by `deliver`: simulate first.
    function due(uint256 issueId, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory list)
    {
        if (!DAILY.isAvailable(issueId)) return list;
        (uint256 start, uint256 end) = _page(_subscribers.length, offset, limit);
        list = new address[](end - start);
        uint256 count;
        for (uint256 i = start; i < end; ++i) {
            address subscriber = _subscribers[i];
            (bool isDue,) = _dueStatus(_subscriptions[subscriber], issueId);
            if (isDue) list[count++] = subscriber;
        }
        assembly ("memory-safe") {
            mstore(list, count)
        }
    }

    /// @notice Whether `subscriber` is due for `issueId` by Paper Route's own rules (credit, one copy an
    ///         issue, the 20-hour rule), and otherwise why not. Does not consult The IMD Daily.
    function dueStatus(address subscriber, uint256 issueId)
        external
        view
        returns (bool isDue, SkipReason reason)
    {
        return _dueStatus(_subscriptions[subscriber], issueId);
    }

    /// @notice IMD that every subscriber's unused editions are worth: `reservedEditions * EDITION_PRICE`.
    function reservedBalance() public view returns (uint256) {
        return reservedEditions * EDITION_PRICE;
    }

    /// @notice IMD held beyond what subscribers are owed: whatever was sent here outside `subscribe`.
    function surplus() external view returns (uint256) {
        uint256 held = IMD.balanceOf(address(this));
        uint256 reserved = reservedBalance();
        return held > reserved ? held - reserved : 0;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _dueStatus(Subscription storage sub, uint256 issueId) private view returns (bool, SkipReason) {
        if (sub.editionsLeft == 0) return (false, SkipReason.NoCredit);
        if (issueId <= sub.lastIssue) return (false, SkipReason.AlreadyDelivered);
        if (block.timestamp < uint256(sub.lastDeliveredAt) + DELIVERY_INTERVAL) {
            return (false, SkipReason.TooSoon);
        }
        return (true, SkipReason.NoCredit);
    }

    function _page(uint256 length, uint256 offset, uint256 limit)
        private
        pure
        returns (uint256 start, uint256 end)
    {
        start = offset > length ? length : offset;
        end = limit > length - start ? length : start + limit;
    }

    function _addSubscriber(address subscriber) private {
        _subscribers.push(subscriber);
        _subscriberIndex[subscriber] = _subscribers.length;
    }

    function _removeSubscriber(address subscriber) private {
        uint256 index = _subscriberIndex[subscriber] - 1;
        uint256 last = _subscribers.length - 1;
        if (index != last) {
            address moved = _subscribers[last];
            _subscribers[index] = moved;
            _subscriberIndex[moved] = index + 1;
        }
        _subscribers.pop();
        delete _subscriberIndex[subscriber];
    }
}
