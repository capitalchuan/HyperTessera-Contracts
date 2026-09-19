// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title ILiquidityAdapter
/// @notice LiquidityAdapter-specific additions on top of IAdapter: the Curator-configured
///         LP→Cash bridge target. (development-plan §3.4.1)
interface ILiquidityAdapter {
    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event BridgeTargetSet(address liquidityBridge, address cashVault, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error InvalidCashVault(address cashVault);

    // -----------------------------------------------------------------------
    // Functions
    // -----------------------------------------------------------------------

    /// @notice This Vault's Curator's initial (and any later) configuration of the LP
    ///         structural bridge target, consistent with Curator owning order destinations
    ///         elsewhere.
    function setBridgeTarget(address newLiquidityBridge, address newCashVault) external;

    function liquidityBridge() external view returns (address);
    function cashVault() external view returns (address);
}
