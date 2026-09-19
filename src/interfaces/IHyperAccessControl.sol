// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IHyperAccessControl
/// @notice Interface for the protocol-global role registry. Only GOVERNOR_ROLE is a real,
///         protocol-wide authorization source now: protocol infrastructure upgrades and (via
///         StateManager.pauseModule/unpauseModule) module-level emergency pause. Every other role
///         from the pre-2026-07 design (Curator, Guardian, Allocator, Settlement, Issuer, Token
///         Agent, Operator, Keeper, Strategy, Data Provider, Compliance) is now a Vault-local or
///         Asset-local role stored on the relevant Vault/AssetRegistry entry, not a global
///         grantRole/revokeRole grant here.
///         (角色权限与职责修改方案 §2, §4, HAC-01..04)
interface IHyperAccessControl {
    // -----------------------------------------------------------------------
    // Role constant getter
    // -----------------------------------------------------------------------

    function GOVERNOR_ROLE() external view returns (bytes32);

    // -----------------------------------------------------------------------
    // OZ AccessControl surface re-exposed for callers
    // -----------------------------------------------------------------------

    /// @notice Returns true if `account` has been granted `role`.
    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @notice Returns the admin role that controls `role`.
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /// @notice Grants `role` to `account`. Caller must hold the role's admin.
    function grantRole(bytes32 role, address account) external;

    /// @notice Revokes `role` from `account`. Caller must hold the role's admin.
    function revokeRole(bytes32 role, address account) external;
}
