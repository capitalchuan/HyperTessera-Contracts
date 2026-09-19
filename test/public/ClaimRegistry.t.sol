// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClaimRegistry} from "../../src/asset-infrastructure/ClaimRegistry.sol";
import {IClaimRegistry} from "../../src/interfaces/IClaimRegistry.sol";

// Mock StateManager: whitelists specific vaults, mirroring the subset ClaimRegistry needs.
contract MockStateManagerCR {
    mapping(address => bool) public registeredVaults;

    function registerVault(address v) external {
        registeredVaults[v] = true;
    }
}

// Mock vault: implements the IVaultRoles.curator() getter ClaimRegistry now checks
// (plus isKeeper(), kept only so existing tests can prove Keeper is no longer authorized).
contract MockVaultCR {
    address public curator;
    mapping(address => bool) public isKeeper;

    function setCurator(address account) external {
        curator = account;
    }

    function setKeeper(address account, bool approved) external {
        isKeeper[account] = approved;
    }
}

contract ClaimRegistryTest is Test {
    ClaimRegistry internal registry;
    MockStateManagerCR internal sm;
    MockVaultCR internal vault1;
    MockVaultCR internal vault2;

    address internal keeper = makeAddr("keeper");
    address internal curator = makeAddr("curator");
    address internal attacker = makeAddr("attacker");

    address internal owner1 = makeAddr("owner1");
    address internal owner2 = makeAddr("owner2");

    function setUp() public {
        vault1 = new MockVaultCR();
        vault2 = new MockVaultCR();
        vault1.setCurator(curator);
        vault2.setCurator(curator);
        vault1.setKeeper(keeper, true);
        vault2.setKeeper(keeper, true);

        sm = new MockStateManagerCR();
        sm.registerVault(address(vault1));
        sm.registerVault(address(vault2));

        registry = new ClaimRegistry(address(sm));
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroStateManager() public {
        vm.expectRevert(IClaimRegistry.ZeroAddress.selector);
        new ClaimRegistry(address(0));
    }

    /// @dev StateManager is a constructor immutable — there is no runtime configuration role and
    ///      therefore no post-deploy rebinding path at all.
    function test_stateManager_isFixedAtConstruction() public view {
        assertEq(address(registry.stateManager()), address(sm));
    }

    function test_recordClaim_revertsForUnregisteredVault() public {
        MockVaultCR unregisteredVault = new MockVaultCR();
        // Prank as the vault itself (msg.sender == vault) so the call reaches the
        // StateManager registration check without needing a keeper grant.
        vm.prank(address(unregisteredVault));
        vm.expectRevert(abi.encodeWithSelector(IClaimRegistry.UnregisteredVault.selector, address(unregisteredVault)));
        registry.recordClaim(address(unregisteredVault), owner1, 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
    }

    // -----------------------------------------------------------------------
    // recordClaim — access control
    // -----------------------------------------------------------------------

    function test_recordClaim_revertsForNonCurator() public {
        vm.prank(attacker);
        vm.expectRevert(IClaimRegistry.UnauthorizedClaimRecorder.selector);
        registry.recordClaim(address(vault1), owner1, 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
    }

    function test_recordClaim_revertsForKeeper_notCurator() public {
        // `keeper` is still granted via setKeeper in setUp — it must no longer be authorized.
        vm.prank(keeper);
        vm.expectRevert(IClaimRegistry.UnauthorizedClaimRecorder.selector);
        registry.recordClaim(address(vault1), owner1, 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
    }

    function test_recordClaim_curatorSucceeds() public {
        vm.prank(curator);
        uint256 id = registry.recordClaim(address(vault1), owner1, 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
        assertEq(id, 0);
    }

    function test_recordClaim_vaultItselfSucceeds() public {
        // msg.sender == vault is authorized without any Keeper grant.
        vm.prank(address(vault1));
        uint256 id = registry.recordClaim(address(vault1), owner1, 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
        assertEq(id, 0);
    }

    function test_recordClaim_revertsOnZeroVault() public {
        vm.prank(curator);
        vm.expectRevert(IClaimRegistry.ZeroAddress.selector);
        registry.recordClaim(address(0), owner1, 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
    }

    function test_recordClaim_revertsOnZeroOwner() public {
        vm.prank(curator);
        vm.expectRevert(IClaimRegistry.ZeroAddress.selector);
        registry.recordClaim(address(vault1), address(0), 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
    }

    // -----------------------------------------------------------------------
    // recordClaim — happy path
    // -----------------------------------------------------------------------

    function test_recordClaim_succeedsAndReturnsSequentialId() public {
        vm.prank(curator);
        uint256 id0 = registry.recordClaim(address(vault1), owner1, 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
        assertEq(id0, 0);

        vm.prank(curator);
        uint256 id1 = registry.recordClaim(address(vault1), owner2, 2, 500e6, IClaimRegistry.ClaimKind.DEPOSIT_REFUND);
        assertEq(id1, 1);

        assertEq(registry.getClaimCount(), 2);
    }

    function test_recordClaim_emitsEvent() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit IClaimRegistry.ClaimRecorded(
            0, address(vault1), owner1, 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT, block.timestamp
        );

        vm.prank(curator);
        registry.recordClaim(address(vault1), owner1, 1, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
    }

    function test_recordClaim_storesFields() public {
        vm.prank(curator);
        uint256 id = registry.recordClaim(address(vault1), owner1, 7, 1_000e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);

        IClaimRegistry.ClaimRecord memory rec = registry.getClaim(id);
        assertEq(rec.vault, address(vault1));
        assertEq(rec.owner, owner1);
        assertEq(rec.requestId, 7);
        assertEq(rec.assets, 1_000e6);
        assertEq(uint8(rec.kind), uint8(IClaimRegistry.ClaimKind.REDEEM_PAYOUT));
        assertEq(rec.recordedAt, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Views — error cases
    // -----------------------------------------------------------------------

    function test_getClaim_revertsIfDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimRegistry.ClaimDoesNotExist.selector, 0));
        registry.getClaim(0);
    }

    function test_getClaimCount_zeroInitially() public view {
        assertEq(registry.getClaimCount(), 0);
    }

    function test_getClaimsByVault_emptyForUnknownVault() public view {
        assertEq(registry.getClaimsByVault(address(vault1)).length, 0);
    }

    // -----------------------------------------------------------------------
    // Per-vault ledgers
    // -----------------------------------------------------------------------

    function test_getClaimsByVault_returnsOnlyThatVaultsClaimsInOrder() public {
        vm.startPrank(curator);
        uint256 a = registry.recordClaim(address(vault1), owner1, 1, 100e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
        registry.recordClaim(address(vault2), owner1, 2, 200e6, IClaimRegistry.ClaimKind.REDEEM_PAYOUT);
        uint256 b = registry.recordClaim(address(vault1), owner2, 3, 300e6, IClaimRegistry.ClaimKind.DEPOSIT_REFUND);
        vm.stopPrank();

        uint256[] memory vault1Claims = registry.getClaimsByVault(address(vault1));
        assertEq(vault1Claims.length, 2);
        assertEq(vault1Claims[0], a);
        assertEq(vault1Claims[1], b);

        assertEq(registry.getClaimsByVault(address(vault2)).length, 1);
    }
}
