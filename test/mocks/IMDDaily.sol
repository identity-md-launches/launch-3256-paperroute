// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DailyAuthority} from "./DailyAuthority.sol";
import {IMDDailyVault} from "./IMDDailyVault.sol";

/// @notice Collectible newspaper copies, not copyright or an entitlement to financial returns.
/// @dev Non-upgradeable. Publication commits to bytes and URLs permanently. No owner/free mint path.
contract IMDDaily is ERC1155Supply, DailyAuthority, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant name = "The IMD Daily";
    string public constant symbol = "IMDDAILY";
    uint256 public constant PRICE = 100_000_000_000_000_000;
    uint256 public constant MINT_WINDOW = 86_400;

    IMDDailyVault public immutable vault;
    uint256 public issueCount;
    /// @notice Successful paid mints only. Donations to either contract never increase this counter.
    uint256 public totalCollected;

    struct IssueInput {
        string title;
        uint256 editorialDate;
        string pdfURL;
        string coverURL;
        string metadataURI;
        bytes32 pdfHash;
        bytes32 coverHash;
        bytes32 metadataHash;
    }

    struct Issue {
        IssueInput content;
        uint256 publishedAt;
        uint256 closesAt;
    }

    mapping(uint256 id => Issue) private _issues;

    error InvalidVault();
    error InvalidContent();
    error UnknownIssue(uint256 issueId);
    error MintClosed(uint256 issueId);
    error ZeroQuantity();
    error InvalidRecipient();
    error DeadlineExpired();
    error PaymentDecimalsMismatch();
    error InexactPayment();

    event IssuePublished(
        uint256 indexed issueId,
        uint256 indexed editorialDate,
        uint256 publishedAt,
        uint256 closesAt,
        string metadataURI,
        bytes32 pdfHash,
        bytes32 coverHash,
        bytes32 metadataHash
    );
    event CopiesMinted(
        uint256 indexed issueId,
        address indexed payer,
        address indexed recipient,
        uint256 quantity,
        uint256 amountPaid
    );

    /// @dev Static address argument supports the launch manifest's backward contract reference.
    ///      External contracts are checked at use, so construction also works on an empty chain.
    constructor(address vault_) ERC1155("") {
        if (vault_ == address(0) || vault_ == PUBLISHER || vault_ == PAYMENT_TOKEN) revert InvalidVault();
        vault = IMDDailyVault(vault_);
    }

    /// @notice Publish the next sequential issue; metadata and all commitments are immutable.
    /// @param content Hashes are SHA-256 of the exact served PDF, cover and UTF-8 metadata bytes.
    /// Editorial date is a Unix timestamp used for presentation only, normally midnight UTC.
    function createIssue(IssueInput calldata content)
        external
        nonReentrant
        onlyPublisher
        returns (uint256 id)
    {
        if (
            bytes(content.title).length == 0 || bytes(content.pdfURL).length == 0
                || bytes(content.coverURL).length == 0 || bytes(content.metadataURI).length == 0
                || content.pdfHash == bytes32(0) || content.coverHash == bytes32(0)
                || content.metadataHash == bytes32(0)
        ) revert InvalidContent();

        id = ++issueCount;
        uint256 closesAt = block.timestamp + MINT_WINDOW;
        _issues[id] = Issue(content, block.timestamp, closesAt);
        emit IssuePublished(
            id,
            content.editorialDate,
            block.timestamp,
            closesAt,
            content.metadataURI,
            content.pdfHash,
            content.coverHash,
            content.metadataHash
        );
        emit URI(content.metadataURI, id);
    }

    /// @notice Pay for positive quantities during [publishedAt, closesAt). Repeat mints are allowed.
    /// @dev Approve THIS collection to spend IMD. The payer is always msg.sender.
    ///      Payment, counters, ERC1155 supply, and receiver acceptance succeed or revert together.
    /// @param deadline Caller-specified last acceptable timestamp (inclusive); cannot extend the issue window.
    function mint(uint256 id, uint256 quantity, address recipient, uint256 deadline) external nonReentrant {
        Issue storage issue = _requireIssue(id);
        if (block.timestamp < issue.publishedAt || block.timestamp >= issue.closesAt) revert MintClosed(id);
        if (quantity == 0) revert ZeroQuantity();
        if (recipient == address(0)) revert InvalidRecipient();
        if (block.timestamp > deadline) revert DeadlineExpired();
        uint256 amount = quantity * PRICE; // Solidity checked multiplication: never wraps or rounds.

        if (IERC20Metadata(PAYMENT_TOKEN).decimals() != PAYMENT_DECIMALS) revert PaymentDecimalsMismatch();
        if (vault.PUBLISHER() != PUBLISHER || vault.PAYMENT_TOKEN() != PAYMENT_TOKEN) revert InvalidVault();

        IERC20 token = IERC20(PAYMENT_TOKEN);
        uint256 beforeVault = token.balanceOf(address(vault));
        uint256 beforePayer = token.balanceOf(msg.sender);
        totalCollected += amount;
        token.safeTransferFrom(msg.sender, address(vault), amount);
        if (
            token.balanceOf(address(vault)) != beforeVault + amount || beforePayer < amount
                || token.balanceOf(msg.sender) != beforePayer - amount
        ) revert InexactPayment();

        // Emit before the receiver callback, preserving ordering if it transfers its new copies.
        // Reversion from _mint removes this event and rolls back the payment and all state.
        emit CopiesMinted(id, msg.sender, recipient, quantity, amount);
        _mint(recipient, id, quantity, "");
    }

    function getIssue(uint256 id) external view returns (Issue memory) {
        return _requireIssue(id);
    }

    /// @notice Publication exists even if nobody has minted. ERC1155Supply.exists instead means supply > 0.
    function issueExists(uint256 id) public view returns (bool) {
        return id > 0 && id <= issueCount;
    }

    function uri(uint256 id) public view override returns (string memory) {
        return _requireIssue(id).content.metadataURI;
    }

    /// @notice Time eligibility only; the payer still needs IMD and allowance and a valid recipient.
    function isAvailable(uint256 id) public view returns (bool) {
        if (!issueExists(id)) return false;
        Issue storage issue = _issues[id];
        return block.timestamp >= issue.publishedAt && block.timestamp < issue.closesAt;
    }

    function issueStatus(uint256 id)
        external
        view
        returns (uint256 supply, uint256 publishedAt, uint256 closesAt, uint256 price, bool available)
    {
        Issue storage issue = _requireIssue(id);
        return (totalSupply(id), issue.publishedAt, issue.closesAt, PRICE, isAvailable(id));
    }

    /// @notice Checked quote; does not assert window availability.
    function quote(uint256 quantity) external pure returns (uint256) {
        if (quantity == 0) revert ZeroQuantity();
        return quantity * PRICE;
    }

    function _requireIssue(uint256 id) private view returns (Issue storage issue) {
        if (!issueExists(id)) revert UnknownIssue(id);
        return _issues[id];
    }
}
