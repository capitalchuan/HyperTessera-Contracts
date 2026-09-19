// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RevenuePool} from "../../src/asset-management/settlement/RevenuePool.sol";
import {IRevenuePool} from "../../src/interfaces/IRevenuePool.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Minimal mock ERC-20 (6 decimals, like USDT).
contract MockUSDT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract RevenuePoolTest is Test {
    HyperAccessControl internal ac;
    MockUSDT internal usdt;
    RevenuePool internal pool;

    address internal governor = makeAddr("governor");
    address internal source = makeAddr("source");
    address internal recipient = makeAddr("recipient");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        ac = new HyperAccessControl(governor);
        usdt = new MockUSDT();
        pool = new RevenuePool(address(usdt), address(ac));

        // Authorize source.
        vm.prank(governor);
        pool.addAuthorizedSource(source);
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(IRevenuePool.ZeroAddress.selector);
        new RevenuePool(address(0), address(ac));

        vm.expectRevert(IRevenuePool.ZeroAddress.selector);
        new RevenuePool(address(usdt), address(0));
    }

    // -----------------------------------------------------------------------
    // addAuthorizedSource / removeAuthorizedSource
    // -----------------------------------------------------------------------

    function test_addAuthorizedSource_setsFlag() public view {
        assertTrue(pool.authorizedSources(source));
    }

    function test_addAuthorizedSource_revertsForNonGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(IRevenuePool.NotGovernor.selector);
        pool.addAuthorizedSource(attacker);
    }

    function test_removeAuthorizedSource_clearsFlag() public {
        vm.prank(governor);
        pool.removeAuthorizedSource(source);
        assertFalse(pool.authorizedSources(source));
    }

    // -----------------------------------------------------------------------
    // receiveFee
    // -----------------------------------------------------------------------

    function test_receiveFee_revertsForUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IRevenuePool.UnauthorizedFeeSource.selector, attacker));
        pool.receiveFee(100e6);
    }

    function test_receiveFee_succeeds() public {
        // Transfer USDT to pool first.
        usdt.mint(address(pool), 500e6);

        vm.prank(source);
        pool.receiveFee(500e6);

        assertEq(pool.totalFeesReceived(), 500e6);
    }

    function test_receiveFee_emitsEvent() public {
        usdt.mint(address(pool), 100e6);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IRevenuePool.FeeReceived(source, 100e6, block.timestamp);

        vm.prank(source);
        pool.receiveFee(100e6);
    }

    // -----------------------------------------------------------------------
    // withdraw
    // -----------------------------------------------------------------------

    function test_withdraw_transfersUSDT() public {
        usdt.mint(address(pool), 1_000e6);

        vm.prank(governor);
        pool.withdraw(recipient, 1_000e6);

        assertEq(usdt.balanceOf(recipient), 1_000e6);
    }

    function test_withdraw_revertsForNonGovernor() public {
        usdt.mint(address(pool), 100e6);

        vm.prank(attacker);
        vm.expectRevert(IRevenuePool.NotGovernor.selector);
        pool.withdraw(recipient, 100e6);
    }

    function test_withdraw_revertsIfInsufficientBalance() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IRevenuePool.InsufficientBalance.selector, uint256(0), uint256(1)));
        pool.withdraw(recipient, 1);
    }

    function test_withdraw_emitsEvent() public {
        usdt.mint(address(pool), 200e6);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IRevenuePool.FeeWithdrawn(recipient, 200e6, block.timestamp);

        vm.prank(governor);
        pool.withdraw(recipient, 200e6);
    }

    // -----------------------------------------------------------------------
    // withdrawToken — generic ERC-20 sweep (e.g. Vault Shares minted here as protocol fee)
    // -----------------------------------------------------------------------

    function test_withdrawToken_transfersArbitraryToken() public {
        MockUSDT otherToken = new MockUSDT(); // stand-in for a minted Vault Share token
        otherToken.mint(address(pool), 500e18);

        vm.prank(governor);
        pool.withdrawToken(address(otherToken), recipient, 500e18);

        assertEq(otherToken.balanceOf(recipient), 500e18);
        assertEq(otherToken.balanceOf(address(pool)), 0);
    }

    function test_withdrawToken_revertsForNonGovernor() public {
        MockUSDT otherToken = new MockUSDT();
        otherToken.mint(address(pool), 100e18);

        vm.prank(attacker);
        vm.expectRevert(IRevenuePool.NotGovernor.selector);
        pool.withdrawToken(address(otherToken), recipient, 100e18);
    }

    function test_withdrawToken_emitsEvent() public {
        MockUSDT otherToken = new MockUSDT();
        otherToken.mint(address(pool), 200e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit IRevenuePool.TokenWithdrawn(address(otherToken), recipient, 200e18, block.timestamp);

        vm.prank(governor);
        pool.withdrawToken(address(otherToken), recipient, 200e18);
    }

    function test_withdrawToken_doesNotAffectTotalFeesReceived() public {
        // Sanity check for the "USDT vs Vault Share accounting split" requirement:
        // sweeping a non-USDT token must never touch totalFeesReceived.
        MockUSDT otherToken = new MockUSDT();
        otherToken.mint(address(pool), 1_000e18);
        uint256 before = pool.totalFeesReceived();

        vm.prank(governor);
        pool.withdrawToken(address(otherToken), recipient, 1_000e18);

        assertEq(pool.totalFeesReceived(), before);
    }

    function test_withdrawToken_worksOnUsdtToo() public {
        // withdrawToken is generic — it also works on the pool's own USDT, distinct from `withdraw`.
        usdt.mint(address(pool), 300e6);

        vm.prank(governor);
        pool.withdrawToken(address(usdt), recipient, 300e6);

        assertEq(usdt.balanceOf(recipient), 300e6);
    }

    // -----------------------------------------------------------------------
    // setYieldStrategy — interface reservation only
    // -----------------------------------------------------------------------

    function test_yieldStrategy_defaultsToZeroAddress() public view {
        assertEq(pool.yieldStrategy(), address(0));
    }

    function test_setYieldStrategy_onlyGovernor() public {
        vm.prank(recipient);
        vm.expectRevert(IRevenuePool.NotGovernor.selector);
        pool.setYieldStrategy(makeAddr("strategy"));
    }

    function test_setYieldStrategy_setsAddressAndEmitsEvent() public {
        address strategy = makeAddr("strategy");

        vm.expectEmit(true, false, false, true, address(pool));
        emit IRevenuePool.YieldStrategySet(strategy, block.timestamp);

        vm.prank(governor);
        pool.setYieldStrategy(strategy);

        assertEq(pool.yieldStrategy(), strategy);
    }

    function test_setYieldStrategy_isNoOp_doesNotMoveFunds() public {
        usdt.mint(address(pool), 100e6);
        uint256 balBefore = usdt.balanceOf(address(pool));

        vm.prank(governor);
        pool.setYieldStrategy(makeAddr("strategy"));

        assertEq(usdt.balanceOf(address(pool)), balBefore);
    }

    // -----------------------------------------------------------------------
    // Native currency
    // -----------------------------------------------------------------------

    function test_receive_acceptsNativeCurrency() public {
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(pool).balance, 1 ether);
    }

    function test_withdrawNative_governorSucceeds() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);

        address nativeRecipient = makeAddr("nativeRecipient");
        vm.prank(governor);
        pool.withdrawNative(nativeRecipient, 1 ether);
        assertEq(nativeRecipient.balance, 1 ether);
        assertEq(address(pool).balance, 0);
    }

    function test_withdrawNative_nonGovernorReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);

        vm.prank(attacker);
        vm.expectRevert(IRevenuePool.NotGovernor.selector);
        pool.withdrawNative(makeAddr("nativeRecipient"), 1 ether);
    }

    function test_withdrawNative_zeroRecipientReverts() public {
        vm.prank(governor);
        vm.expectRevert(IRevenuePool.ZeroAddress.selector);
        pool.withdrawNative(address(0), 0);
    }

    function test_withdrawNative_emitsEvent() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);

        address nativeRecipient = makeAddr("nativeRecipient2");
        vm.expectEmit(true, false, false, true, address(pool));
        emit IRevenuePool.NativeWithdrawn(nativeRecipient, 1 ether, block.timestamp);
        vm.prank(governor);
        pool.withdrawNative(nativeRecipient, 1 ether);
    }

    /// @dev A recipient that rejects the transfer must surface NativeTransferFailed rather than
    ///      silently leaving the funds behind with a "successful" call.
    function test_withdrawNative_revertingRecipientReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);

        RejectingReceiver bad = new RejectingReceiver();
        vm.prank(governor);
        vm.expectRevert(IRevenuePool.NativeTransferFailed.selector);
        pool.withdrawNative(address(bad), 1 ether);

        assertEq(address(pool).balance, 1 ether, "funds stay put on failure");
    }

    function test_withdrawToken_zeroRecipientReverts() public {
        vm.prank(governor);
        vm.expectRevert(IRevenuePool.ZeroAddress.selector);
        pool.withdrawToken(address(usdt), address(0), 1);
    }

    function test_addAuthorizedSource_zeroAddressReverts() public {
        vm.prank(governor);
        vm.expectRevert(IRevenuePool.ZeroAddress.selector);
        pool.addAuthorizedSource(address(0));
    }

    function test_removeAuthorizedSource_nonGovernorReverts() public {
        vm.prank(attacker);
        vm.expectRevert(IRevenuePool.NotGovernor.selector);
        pool.removeAuthorizedSource(source);
    }

    /// @dev `receiveFee` is a *claim* against an already-transferred balance, so a claim larger
    ///      than the contract actually holds must be rejected — otherwise totalFeesReceived
    ///      drifts above the real cash.
    function test_receiveFee_revertsIfClaimExceedsBalance() public {
        usdt.mint(address(pool), 10e6);

        vm.prank(source);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenuePool.InsufficientBalance.selector, uint256(10e6), uint256(10e6 + 1))
        );
        pool.receiveFee(10e6 + 1);

        assertEq(pool.totalFeesReceived(), 0);
    }

    function test_removeAuthorizedSource_blocksFurtherReceiveFee() public {
        usdt.mint(address(pool), 10e6);
        vm.prank(source);
        pool.receiveFee(10e6);
        assertEq(pool.totalFeesReceived(), 10e6);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IRevenuePool.SourceRevoked(source, block.timestamp);
        vm.prank(governor);
        pool.removeAuthorizedSource(source);

        usdt.mint(address(pool), 10e6);
        vm.prank(source);
        vm.expectRevert(abi.encodeWithSelector(IRevenuePool.UnauthorizedFeeSource.selector, source));
        pool.receiveFee(10e6);

        assertEq(pool.totalFeesReceived(), 10e6, "ledger unchanged after revocation");
    }

    function test_addAuthorizedSource_emitsEvent() public {
        address src2 = makeAddr("source2");
        vm.expectEmit(true, false, false, true, address(pool));
        emit IRevenuePool.SourceAuthorized(src2, block.timestamp);
        vm.prank(governor);
        pool.addAuthorizedSource(src2);
        assertTrue(pool.authorizedSources(src2));
    }

    // -----------------------------------------------------------------------
    // Authorized source index — the CURRENT allowlist
    // -----------------------------------------------------------------------
    // `authorizedSources` answers "may this address deposit fees?"; the index answers "who may?",
    // otherwise recoverable only by replaying SourceAuthorized/SourceRevoked and reconstructing
    // the surviving set by hand. Swap-and-pop, so it is the exact live set.

    function test_authorizedSourceCount_reflectsTheSetUpSource() public view {
        assertEq(pool.authorizedSourceCount(), 1);
        assertEq(pool.authorizedSourcesPaged(0, 10)[0], source);
    }

    function test_authorizedSourceIndex_tracksAdditions() public {
        address second = makeAddr("source2");
        vm.prank(governor);
        pool.addAuthorizedSource(second);

        assertEq(pool.authorizedSourceCount(), 2);
        address[] memory page = pool.authorizedSourcesPaged(0, 10);
        assertEq(page[0], source);
        assertEq(page[1], second);
    }

    /// @dev Re-authorizing an already-authorized source must not double-list it.
    function test_authorizedSourceIndex_ignoresARedundantAdd() public {
        vm.prank(governor);
        pool.addAuthorizedSource(source);

        assertEq(pool.authorizedSourceCount(), 1);
    }

    /// @dev Revocation is swap-and-pop, so the survivor moves into the freed slot.
    function test_authorizedSourceIndex_tracksRemovalAndTheSwapAndPopIndexMove() public {
        address second = makeAddr("source2");
        vm.startPrank(governor);
        pool.addAuthorizedSource(second);
        pool.removeAuthorizedSource(source);
        vm.stopPrank();

        assertEq(pool.authorizedSourceCount(), 1);
        address[] memory page = pool.authorizedSourcesPaged(0, 10);
        assertEq(page.length, 1);
        assertEq(page[0], second, "survivor swapped down into index 0");
        assertTrue(pool.authorizedSources(page[0]));
        assertFalse(pool.authorizedSources(source));
    }

    /// @dev Revoking something never authorized must not corrupt the list.
    function test_authorizedSourceIndex_ignoresARedundantRemove() public {
        vm.prank(governor);
        pool.removeAuthorizedSource(makeAddr("neverAuthorized"));

        assertEq(pool.authorizedSourceCount(), 1);
        assertEq(pool.authorizedSourcesPaged(0, 10)[0], source);
    }

    function test_authorizedSourcesPaged_clampsInsteadOfReverting() public {
        address second = makeAddr("source2");
        vm.prank(governor);
        pool.addAuthorizedSource(second);

        address[] memory page = pool.authorizedSourcesPaged(1, type(uint256).max);
        assertEq(page.length, 1);
        assertEq(page[0], second);

        assertEq(pool.authorizedSourcesPaged(2, 10).length, 0);
        assertEq(pool.authorizedSourcesPaged(99, 10).length, 0);
    }
}

/// @notice Rejects every incoming native transfer, for the NativeTransferFailed path.
contract RejectingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}
