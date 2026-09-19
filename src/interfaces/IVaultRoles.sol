// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IVaultRoles
/// @notice Vault-local role surface, implemented by BaseVault and consumed by every module that
///         used to check a global HyperAccessControl role (VaultTimelock, StateManager,
///         BaseAdapter, Settlement, UnifiedPool, NAVOracle). Roles are per-Vault: the same address
///         can serve different roles (or none) on different Vaults, and each Vault's Owner
///         appoints/replaces its own Curator/Guardian/Allocator/Keeper independently.
interface IVaultRoles {
    event OwnerTransferred(
        address indexed vault, address indexed oldOwner, address indexed newOwner, uint256 timestamp
    );
    event CuratorSet(address indexed vault, address indexed oldCurator, address indexed newCurator, uint256 timestamp);
    event GuardianSet(
        address indexed vault, address indexed oldGuardian, address indexed newGuardian, uint256 timestamp
    );
    event AllocatorSet(
        address indexed vault, address indexed oldAllocator, address indexed newAllocator, uint256 timestamp
    );
    event KeeperSet(address indexed vault, address indexed account, bool approved, uint256 timestamp);

    error NotOwner();
    error NotCurator();
    error NotGuardian();
    error NotAllocator();
    error NotKeeper();

    function owner() external view returns (address);
    function curator() external view returns (address);
    function guardian() external view returns (address);
    function allocator() external view returns (address);
    function isKeeper(address account) external view returns (bool);
    function vaultTimelock() external view returns (address);
    function stateManager() external view returns (address);

    function transferOwnership(address newOwner) external;
    function setCurator(address account) external;
    function setGuardian(address account) external;
    function setAllocator(address account) external;
    function setKeeper(address account, bool approved) external;
}
