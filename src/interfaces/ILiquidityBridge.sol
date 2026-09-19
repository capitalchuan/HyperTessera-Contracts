// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title ILiquidityBridge
/// @notice Stateless bridge that deposits USDT from one vault into another ERC-4626 vault
///         using the synchronous deposit surface and forwards resulting shares to fromVault.
interface ILiquidityBridge {
    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event DepositBridged(
        address indexed fromVault, address indexed toVault, uint256 assets, uint256 shares, uint256 timestamp
    );

    event BridgeWhitelistUpdated(address indexed vault, bool allowed, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error CallerNotAuthorized(address caller);
    error ZeroAssets();
    error ZeroAddress();
    error UnregisteredVault(address vault);
    error VaultNotWhitelisted(address vault);
    error NotGovernor();

    // -----------------------------------------------------------------------
    // Functions
    // -----------------------------------------------------------------------

    /// @notice Governor admission control: names a Vault as permitted on either end of a bridge.
    /// @dev    Required in addition to StateManager registration — `deployVault` is
    ///         permissionless, so being registered is not a statement of trust.
    function setBridgeWhitelisted(address vault, bool allowed) external;

    /// @notice Whether `vault` is permitted to bridge (either end).
    function bridgeWhitelisted(address vault) external view returns (bool);

    /// @notice Transfers `assets` USDT from `fromVault`, deposits into `toVault`
    ///         synchronously (standard ERC-4626 deposit), returns resulting shares
    ///         directly to `fromVault`.
    /// @param  assets    USDT amount (6-decimal)
    /// @param  fromVault vault providing USDT and receiving resulting shares
    /// @param  toVault   target ERC-4626 vault to deposit into
    /// @return shares    minted to fromVault by toVault
    function bridgeDeposit(uint256 assets, address fromVault, address toVault) external returns (uint256 shares);
}
