// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IGate
/// @notice KYT / compliance gate hook consumed by BaseVault on deposit.
///         Return true to permit; false to block. A no-op gate is address(0).
interface IGate {
    /// @notice Returns true if `account` is allowed to interact with the vault.
    function isAllowed(address account) external view returns (bool);
}
