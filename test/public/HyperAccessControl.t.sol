// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title HyperAccessControl Tests
/// @notice TDD suite for HyperAccessControl
/// @dev    NOTE: vm.prank is consumed by the next external call including view getters.
///         All role constants are cached into locals BEFORE any prank/startPrank call.
///         GOVERNOR_ROLE is the only role registered on this contract now — every other
///         role (Curator/Guardian/Allocator/Settlement/Issuer/Token Agent/Operator/Keeper/
///         Strategy/Data Provider/Compliance) moved to Vault-local or Asset-local storage
///         and is no longer a HyperAccessControl role constant.
contract HyperAccessControlTest is Test {
    HyperAccessControl internal ac;

    address internal governor = makeAddr("governor");
    address internal newGovernor = makeAddr("newGovernor");
    address internal alice = makeAddr("alice");

    // Role constant cache — populated in setUp, used by every test.
    bytes32 internal GOVERNOR_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE;

    function setUp() public {
        ac = new HyperAccessControl(governor);

        // Cache all role constants before any prank so view calls don't eat pranks.
        GOVERNOR_ROLE = ac.GOVERNOR_ROLE();
        DEFAULT_ADMIN_ROLE = ac.DEFAULT_ADMIN_ROLE();
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_governorHasGovernorRole() public view {
        assertTrue(ac.hasRole(GOVERNOR_ROLE, governor));
    }

    function test_constructor_revertsOnZeroGovernor() public {
        vm.expectRevert(HyperAccessControl.ZeroAddress.selector);
        new HyperAccessControl(address(0));
    }

    // -----------------------------------------------------------------------
    // Role admin: GOVERNOR_ROLE is admin of itself and of DEFAULT_ADMIN_ROLE
    // -----------------------------------------------------------------------

    function test_roleAdmin_governorIsAdminOfGovernorRole() public view {
        assertEq(ac.getRoleAdmin(GOVERNOR_ROLE), GOVERNOR_ROLE);
    }

    function test_roleAdmin_governorIsAdminOfDefaultAdminRole() public view {
        // DEFAULT_ADMIN_ROLE must be neutralised — GOVERNOR_ROLE is its admin
        assertEq(ac.getRoleAdmin(DEFAULT_ADMIN_ROLE), GOVERNOR_ROLE);
    }

    // -----------------------------------------------------------------------
    // grantRole: only an existing GOVERNOR_ROLE holder may grant GOVERNOR_ROLE
    // -----------------------------------------------------------------------

    function test_grantRole_governorCanGrantGovernorRole() public {
        vm.prank(governor);
        ac.grantRole(GOVERNOR_ROLE, newGovernor);
        assertTrue(ac.hasRole(GOVERNOR_ROLE, newGovernor));
    }

    function test_grantRole_emitsRoleGranted() public {
        // §3.1.3: grantRole by GOVERNOR emits RoleGranted (sender = governor).
        vm.expectEmit(true, true, true, false, address(ac));
        emit IAccessControl.RoleGranted(GOVERNOR_ROLE, newGovernor, governor);
        vm.prank(governor);
        ac.grantRole(GOVERNOR_ROLE, newGovernor);
    }

    function test_grantRole_nonAdminReverts() public {
        // Cache GOVERNOR_ROLE before prank — view call would consume the prank.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, GOVERNOR_ROLE)
        );
        ac.grantRole(GOVERNOR_ROLE, newGovernor);
    }

    function test_grantRole_newlyGrantedGovernorCanGrantFurther() public {
        // A newly-granted GOVERNOR_ROLE holder is itself the admin of GOVERNOR_ROLE, so it can
        // grant it onward — demonstrating the role is admin-of-itself, not just admin-by-founder.
        vm.prank(governor);
        ac.grantRole(GOVERNOR_ROLE, newGovernor);

        vm.prank(newGovernor);
        ac.grantRole(GOVERNOR_ROLE, alice);
        assertTrue(ac.hasRole(GOVERNOR_ROLE, alice));
    }

    function test_grantRole_revertsZeroAddress() public {
        vm.prank(governor);
        vm.expectRevert(HyperAccessControl.ZeroAddress.selector);
        ac.grantRole(GOVERNOR_ROLE, address(0));
    }

    // -----------------------------------------------------------------------
    // revokeRole: only an existing GOVERNOR_ROLE holder may revoke GOVERNOR_ROLE
    // -----------------------------------------------------------------------

    function test_revokeRole_governorCanRevoke() public {
        vm.prank(governor);
        ac.grantRole(GOVERNOR_ROLE, newGovernor);
        assertTrue(ac.hasRole(GOVERNOR_ROLE, newGovernor));

        vm.prank(governor);
        ac.revokeRole(GOVERNOR_ROLE, newGovernor);
        assertFalse(ac.hasRole(GOVERNOR_ROLE, newGovernor));
    }

    function test_revokeRole_emitsRoleRevoked() public {
        vm.prank(governor);
        ac.grantRole(GOVERNOR_ROLE, newGovernor);

        // §3.1.3: revokeRole by GOVERNOR emits RoleRevoked (sender = governor).
        vm.expectEmit(true, true, true, false, address(ac));
        emit IAccessControl.RoleRevoked(GOVERNOR_ROLE, newGovernor, governor);
        vm.prank(governor);
        ac.revokeRole(GOVERNOR_ROLE, newGovernor);
    }

    function test_revokeRole_nonAdminReverts() public {
        vm.prank(governor);
        ac.grantRole(GOVERNOR_ROLE, newGovernor);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, GOVERNOR_ROLE)
        );
        ac.revokeRole(GOVERNOR_ROLE, newGovernor);
    }

    // -----------------------------------------------------------------------
    // hasRole is permissionless (any caller)
    // -----------------------------------------------------------------------

    function test_hasRole_permissionless() public view {
        // alice (no role) can call hasRole without revert
        assertFalse(ac.hasRole(GOVERNOR_ROLE, alice));
    }

    // -----------------------------------------------------------------------
    // DEFAULT_ADMIN_ROLE is neutralised — random address cannot use it
    // -----------------------------------------------------------------------

    function test_defaultAdminRole_isNeutralised() public {
        // alice cannot grant herself DEFAULT_ADMIN_ROLE because its admin is GOVERNOR_ROLE
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, GOVERNOR_ROLE)
        );
        ac.grantRole(DEFAULT_ADMIN_ROLE, alice);
    }
}
