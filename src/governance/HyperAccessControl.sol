// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IHyperAccessControl} from "../interfaces/IHyperAccessControl.sol";

/// @title HyperAccessControl
/// @notice Protocol-global role registry. GOVERNOR_ROLE is the only role registered here —
///         it admins protocol infrastructure upgrades and (via StateManager) module-level
///         emergency pause. It does NOT register or deploy Vaults, set Vault product params,
///         appoint Vault-local roles (Curator/Guardian/Allocator/Settlement Operator/Keeper),
///         manage a single RWA Token/PoR/Wrapped Asset, or submit/cancel/execute Vault parameter
///         changes — those are Vault-local (VaultTimelock + BaseVault-stored roles) or Asset-local
///         (AssetRegistry-stored owner/issuer/token agent/proof publisher) authority now.
contract HyperAccessControl is AccessControl, IHyperAccessControl {
    // -----------------------------------------------------------------------
    // Custom errors
    // -----------------------------------------------------------------------

    /// @notice Reverts when a zero address is passed where an account is required. // INFERRED
    error ZeroAddress();

    // -----------------------------------------------------------------------
    // Role constant
    // -----------------------------------------------------------------------

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Grants GOVERNOR_ROLE to `governor` and makes GOVERNOR_ROLE the admin
    ///         of itself and DEFAULT_ADMIN_ROLE (neutralising the latter).
    /// @param  governor Address of the Governor multi-sig; must be non-zero.
    constructor(address governor) {
        if (governor == address(0)) revert ZeroAddress();

        _setRoleAdmin(DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);

        _grantRole(GOVERNOR_ROLE, governor);
    }

    // -----------------------------------------------------------------------
    // grantRole override — zero-address guard
    // -----------------------------------------------------------------------

    /// @inheritdoc IHyperAccessControl
    /// @dev Adds a ZeroAddress guard on top of OZ access enforcement. // INFERRED
    function grantRole(bytes32 role, address account)
        public
        override(AccessControl, IHyperAccessControl)
        onlyRole(getRoleAdmin(role))
    {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(role, account);
    }

    // -----------------------------------------------------------------------
    // IHyperAccessControl view overrides (satisfy interface; delegated to OZ)
    // -----------------------------------------------------------------------

    /// @inheritdoc IHyperAccessControl
    function hasRole(bytes32 role, address account)
        public
        view
        override(AccessControl, IHyperAccessControl)
        returns (bool)
    {
        return super.hasRole(role, account);
    }

    /// @inheritdoc IHyperAccessControl
    function getRoleAdmin(bytes32 role) public view override(AccessControl, IHyperAccessControl) returns (bytes32) {
        return super.getRoleAdmin(role);
    }

    /// @inheritdoc IHyperAccessControl
    function revokeRole(bytes32 role, address account)
        public
        override(AccessControl, IHyperAccessControl)
        onlyRole(getRoleAdmin(role))
    {
        _revokeRole(role, account);
    }
}
