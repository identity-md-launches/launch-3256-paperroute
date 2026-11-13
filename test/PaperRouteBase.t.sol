// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PaperRoute, IIMDDaily} from "../src/PaperRoute.sol";
import {IMDDaily} from "./mocks/IMDDaily.sol";
import {IMDDailyVault} from "./mocks/IMDDailyVault.sol";
import {MockIMD} from "./mocks/Mocks.sol";

/// @dev Shared fixture: the real IMDDaily source (vendored under test/mocks) etched at its mainnet address,
///      a plain ERC-20 etched at IMD's mainnet address, and a fresh PaperRoute.
abstract contract PaperRouteBase is Test {
    address internal constant IMD_ADDRESS = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant DAILY_ADDRESS = 0xB8FD2b7fb37cbf03A26B4c4688eD5ccE86C0a9c5;
    address internal constant PUBLISHER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;

    uint256 internal constant EDITION = 0.125 ether;
    uint256 internal constant COPY = 0.1 ether;
    uint256 internal constant TIP = 0.025 ether;

    MockIMD internal imd = MockIMD(IMD_ADDRESS);
    IMDDaily internal daily = IMDDaily(DAILY_ADDRESS);
    IMDDailyVault internal vault;
    PaperRoute internal route;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal courier = makeAddr("courier");

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        vm.etch(IMD_ADDRESS, address(new MockIMD()).code);
        vault = new IMDDailyVault();
        vm.etch(DAILY_ADDRESS, address(new IMDDaily(address(vault))).code);
        vm.label(IMD_ADDRESS, "IMD");
        vm.label(DAILY_ADDRESS, "IMDDaily");
        route = new PaperRoute();
        vm.label(address(route), "PaperRoute");
    }

    function publishIssue() internal returns (uint256 id) {
        IMDDaily.IssueInput memory input = IMDDaily.IssueInput({
            title: "The IMD Daily",
            editorialDate: vm.getBlockTimestamp(),
            pdfURL: "ipfs://pdf",
            coverURL: "ipfs://cover",
            metadataURI: "ipfs://meta",
            pdfHash: keccak256("pdf"),
            coverHash: keccak256("cover"),
            metadataHash: keccak256("meta")
        });
        vm.prank(PUBLISHER);
        id = daily.createIssue(input);
    }

    function fund(address who, uint256 amount) internal {
        imd.mint(who, amount);
        vm.prank(who);
        imd.approve(address(route), type(uint256).max);
    }

    function subscribeAs(address who, uint256 editions) internal {
        fund(who, editions * EDITION);
        vm.prank(who);
        route.subscribe(editions);
    }

    function list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = a;
        l[1] = b;
    }

    function list(address a, address b, address c) internal pure returns (address[] memory l) {
        l = new address[](3);
        l[0] = a;
        l[1] = b;
        l[2] = c;
    }

    function deliverAs(address who, uint256 issueId, address[] memory subs)
        internal
        returns (address[] memory)
    {
        vm.prank(who);
        return route.deliver(issueId, subs);
    }
}
