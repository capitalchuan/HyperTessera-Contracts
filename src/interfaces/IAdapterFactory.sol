// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

interface IAdapterFactory {
    struct AdapterParams {
        address asset; // USDT
        address vault; // EarnVault this adapter serves
        uint256 stalenessWindow; // pendingDeposits staleness window; default 36h
    }

    struct RWAAdapterParams {
        address asset; // Vault's accounting asset
        address vault; // EarnVault this adapter serves, fixed at deploy
        address rwaToken; // RWA Token this adapter values, fixed at deploy
        address navOracle; // NAVOracle instance queried for rwaToken's price, fixed at deploy
        uint256 dealDataStalenessWindow; // BaseAdapter's existing pending-deal staleness window
    }

    event AdapterDeployed(address indexed adapter, address indexed vault, uint256 timestamp);

    error ZeroAddress();
    error InvalidAdapterParams();

    function deployAdapter(AdapterParams calldata params) external returns (address adapter);
    function deployLiquidityAdapter(AdapterParams calldata params) external returns (address adapter);
    function deployRWAAdapter(RWAAdapterParams calldata params) external returns (address adapter);

    function isAdapter(address adapter) external view returns (bool);

    // -----------------------------------------------------------------------
    // Adapter index
    // -----------------------------------------------------------------------
    // `isAdapter` answers "did this factory deploy that address?"; the functions below answer
    // "what has this factory deployed?", so any integrator can enumerate them with eth_call
    // alone instead of crawling AdapterDeployed logs over a bounded block window — a crawl that
    // silently loses adapters deployed before the window starts. Append-only and in deployment
    // order: this factory never removes an entry, so an adapter's index is stable forever and a
    // caller may cache it across blocks.

    /// @notice Number of adapters ever deployed by this factory.
    function adapterCount() external view returns (uint256);

    /// @notice Adapter at `index` in deployment order. Reverts past the end.
    function adapterAt(uint256 index) external view returns (address);

    /// @notice Up to `limit` adapters starting at `offset`, in deployment order.
    /// @dev    Clamped, not checked: an offset at or past the end yields an empty array and an
    ///         overlong limit yields a short page, so a caller can page without reading
    ///         `adapterCount` first.
    function adaptersPaged(uint256 offset, uint256 limit) external view returns (address[] memory);

    /// @notice Number of adapters this factory deployed for `vault`.
    function adapterCountForVault(address vault) external view returns (uint256);

    /// @notice Up to `limit` of `vault`'s adapters starting at `offset`, in deployment order.
    /// @dev    Clamped on the same terms as `adaptersPaged`. This lists what the factory
    ///         deployed for `vault`, which is not the same as what the vault currently uses:
    ///         adapters are admitted to a vault separately via `BaseVault.addAdapter`, so read
    ///         `IBaseVault.adapters` for the active set.
    function adaptersForVaultPaged(address vault, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory);
}
