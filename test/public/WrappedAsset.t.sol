// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {WrappedAsset} from "../../src/wrapped-assets/WrappedAsset.sol";
import {ReservePSM} from "../../src/wrapped-assets/ReservePSM.sol";
import {IReservePSM} from "../../src/interfaces/IReservePSM.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";

// Minimal ERC-20 used as the TOKEN_CUSTODY underlying, mirroring ReservePSM.t.sol's stand-in.
contract MockUnderlying {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
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
}

/// @title WrappedAssetTest
/// @notice WrappedAsset's ERC-20 surface had zero direct coverage: ReservePSM.t.sol only ever
///         reads `balanceOf`/`decimals`, so `transfer`, `transferFrom`, `approve`, `allowance`,
///         `totalSupply` and every one of the four custom errors were unreached (0% branch
///         coverage on the file).
///
///         The token under test is the real one ReservePSM deploys, and `psm` is that real PSM —
///         `mint`/`burn` are reached through `wrap`/`unwrap` wherever the PSM offers a path, and
///         only the direct-caller *rejection* cases prank a non-PSM address, which is the point
///         of those assertions.
contract WrappedAssetTest is Test {
    HyperAccessControl internal ac;
    ReservePSM internal psm;
    MockUnderlying internal underlying;
    WrappedAsset internal token;

    address internal governor = makeAddr("governor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant ASSET_ID = 1;

    function setUp() public {
        ac = new HyperAccessControl(governor);
        psm = new ReservePSM(address(ac));
        underlying = new MockUnderlying();

        vm.prank(governor);
        psm.deployWrappedToken(
            ASSET_ID, IReservePSM.AssetMode.TOKEN_CUSTODY, address(underlying), "wCustody", "wC", 6, true
        );
        token = WrappedAsset(psm.wrappedTokenOf(ASSET_ID));
    }

    /// @dev Mints through the real PSM path (wrap), never by pranking the PSM.
    function _wrapTo(address who, uint256 amount) internal {
        underlying.mint(who, amount);
        vm.startPrank(who);
        underlying.approve(address(psm), amount);
        psm.wrap(ASSET_ID, amount, who);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Constructor / metadata
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroPSM() public {
        vm.expectRevert(WrappedAsset.ZeroAddress.selector);
        new WrappedAsset(address(0), "n", "s", 6);
    }

    function test_constructor_setsMetadataAndPsm() public view {
        assertEq(token.name(), "wCustody");
        assertEq(token.symbol(), "wC");
        assertEq(token.decimals(), 6);
        assertEq(token.psm(), address(psm));
    }

    // -----------------------------------------------------------------------
    // mint / burn — PSM-gated
    // -----------------------------------------------------------------------

    function test_mint_onlyPSM() public {
        vm.prank(attacker);
        vm.expectRevert(WrappedAsset.OnlyPSM.selector);
        token.mint(attacker, 1_000e6);

        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(attacker), 0);
    }

    /// @dev The Governor who deployed the token is no more privileged than anyone else here —
    ///      the gate is the PSM address, not a role.
    function test_mint_governorIsNotPrivileged() public {
        vm.prank(governor);
        vm.expectRevert(WrappedAsset.OnlyPSM.selector);
        token.mint(governor, 1);
    }

    function test_burn_onlyPSM() public {
        _wrapTo(alice, 1_000e6);

        vm.prank(attacker);
        vm.expectRevert(WrappedAsset.OnlyPSM.selector);
        token.burn(alice, 1_000e6);

        assertEq(token.balanceOf(alice), 1_000e6);
    }

    function test_mintViaWrap_updatesSupplyAndBalance() public {
        assertEq(token.totalSupply(), 0);

        _wrapTo(alice, 1_000e6);
        assertEq(token.totalSupply(), 1_000e6);
        assertEq(token.balanceOf(alice), 1_000e6);

        _wrapTo(bob, 250e6);
        assertEq(token.totalSupply(), 1_250e6);
        assertEq(token.balanceOf(bob), 250e6);
    }

    function test_burnViaUnwrap_updatesSupplyAndBalance() public {
        _wrapTo(alice, 1_000e6);

        vm.prank(alice);
        psm.unwrap(ASSET_ID, 400e6, alice);

        assertEq(token.balanceOf(alice), 600e6);
        assertEq(token.totalSupply(), 600e6);
    }

    /// @dev The PSM burns only what the holder owns; a larger burn must hit the token's own
    ///      InsufficientBalance guard rather than silently underflowing the supply.
    function test_burn_moreThanBalanceReverts() public {
        _wrapTo(alice, 100e6);

        vm.prank(address(psm));
        vm.expectRevert(WrappedAsset.InsufficientBalance.selector);
        token.burn(alice, 100e6 + 1);

        assertEq(token.totalSupply(), 100e6, "supply untouched by the rejected burn");
    }

    // -----------------------------------------------------------------------
    // transfer
    // -----------------------------------------------------------------------

    function test_transfer_movesBalanceAndEmits() public {
        _wrapTo(alice, 1_000e6);

        vm.expectEmit(true, true, false, true, address(token));
        emit WrappedAsset.Transfer(alice, bob, 400e6);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 400e6));

        assertEq(token.balanceOf(alice), 600e6);
        assertEq(token.balanceOf(bob), 400e6);
        assertEq(token.totalSupply(), 1_000e6, "transfer never changes supply");
    }

    function test_transfer_insufficientBalanceReverts() public {
        _wrapTo(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(WrappedAsset.InsufficientBalance.selector);
        token.transfer(bob, 100e6 + 1);

        assertEq(token.balanceOf(alice), 100e6);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transfer_exactBalanceSucceeds() public {
        _wrapTo(alice, 100e6);
        vm.prank(alice);
        token.transfer(bob, 100e6);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100e6);
    }

    function test_transfer_zeroAmountFromEmptyAccountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Self-transfer must be a no-op on the balance, not a way to mint (the unchecked
    ///      subtract-then-add would double-count if `from == to` were mishandled).
    function test_transfer_toSelfIsBalanceNeutral() public {
        _wrapTo(alice, 500e6);
        vm.prank(alice);
        token.transfer(alice, 500e6);
        assertEq(token.balanceOf(alice), 500e6);
        assertEq(token.totalSupply(), 500e6);
    }

    // -----------------------------------------------------------------------
    // approve / allowance
    // -----------------------------------------------------------------------

    function test_approve_setsAllowanceAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit WrappedAsset.Approval(alice, bob, 700e6);
        vm.prank(alice);
        assertTrue(token.approve(bob, 700e6));

        assertEq(token.allowance(alice, bob), 700e6);
        assertEq(token.allowance(bob, alice), 0, "allowance is directional");
    }

    function test_approve_overwritesRatherThanAccumulates() public {
        vm.startPrank(alice);
        token.approve(bob, 700e6);
        token.approve(bob, 100e6);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 100e6);
    }

    // -----------------------------------------------------------------------
    // transferFrom
    // -----------------------------------------------------------------------

    function test_transferFrom_spendsAllowanceAndMovesBalance() public {
        _wrapTo(alice, 1_000e6);
        vm.prank(alice);
        token.approve(bob, 600e6);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 250e6));

        assertEq(token.balanceOf(alice), 750e6);
        assertEq(token.balanceOf(carol), 250e6);
        assertEq(token.allowance(alice, bob), 350e6, "allowance decremented by the spent amount");
    }

    function test_transferFrom_insufficientAllowanceReverts() public {
        _wrapTo(alice, 1_000e6);
        vm.prank(alice);
        token.approve(bob, 100e6);

        vm.prank(bob);
        vm.expectRevert(WrappedAsset.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 100e6 + 1);

        assertEq(token.balanceOf(alice), 1_000e6);
        assertEq(token.allowance(alice, bob), 100e6);
    }

    function test_transferFrom_noAllowanceReverts() public {
        _wrapTo(alice, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(WrappedAsset.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 1);
    }

    /// @dev Allowance is checked before balance, so a fully-approved spender still can't move
    ///      more than the owner holds.
    function test_transferFrom_allowanceOkButBalanceShortReverts() public {
        _wrapTo(alice, 10e6);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(WrappedAsset.InsufficientBalance.selector);
        token.transferFrom(alice, carol, 10e6 + 1);
    }

    /// @dev Infinite approval is the branch that skips the allowance decrement entirely.
    function test_transferFrom_infiniteAllowanceIsNotDecremented() public {
        _wrapTo(alice, 1_000e6);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, 400e6);

        assertEq(token.allowance(alice, bob), type(uint256).max, "unlimited approval stays unlimited");
        assertEq(token.balanceOf(carol), 400e6);
    }

    function test_transferFrom_exactAllowanceLeavesZero() public {
        _wrapTo(alice, 1_000e6);
        vm.prank(alice);
        token.approve(bob, 300e6);

        vm.prank(bob);
        token.transferFrom(alice, carol, 300e6);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(bob);
        vm.expectRevert(WrappedAsset.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 1);
    }

    function test_transferFrom_emitsTransferFromTheOwnerNotTheSpender() public {
        _wrapTo(alice, 1_000e6);
        vm.prank(alice);
        token.approve(bob, 500e6);

        vm.expectEmit(true, true, false, true, address(token));
        emit WrappedAsset.Transfer(alice, carol, 500e6);
        vm.prank(bob);
        token.transferFrom(alice, carol, 500e6);
    }

    // -----------------------------------------------------------------------
    // Supply accounting across the whole lifecycle
    // -----------------------------------------------------------------------

    /// @dev Every wrapped unit is redeemable: after transfers move the tokens around, the PSM's
    ///      custodied underlying still exactly backs `totalSupply()`.
    function test_supplyStaysBackedAcrossTransfersAndUnwraps() public {
        _wrapTo(alice, 1_000e6);
        _wrapTo(bob, 500e6);
        assertEq(token.totalSupply(), 1_500e6);
        assertEq(underlying.balanceOf(address(psm)), 1_500e6);

        vm.prank(alice);
        token.transfer(carol, 600e6);

        // carol never wrapped anything, but holds real claims now.
        vm.prank(carol);
        psm.unwrap(ASSET_ID, 600e6, carol);

        assertEq(token.balanceOf(carol), 0);
        assertEq(underlying.balanceOf(carol), 600e6);
        assertEq(token.totalSupply(), 900e6);
        assertEq(underlying.balanceOf(address(psm)), 900e6, "custody still matches supply");
    }
}
