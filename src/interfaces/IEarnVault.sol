// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IBaseVault} from "./IBaseVault.sol";

/// @title IEarnVault
/// @notice EarnVault extensions on top of BaseVault.
///         Cash tranche (cycleDuration=7 days) adds a synchronous ERC-4626 deposit for LiquidityBridge.
///         Note tranche (cycleDuration=365 days) uses no additional surface.
///         (development-plan §3.3.1 — EarnVault)
interface IEarnVault is IBaseVault {
    // -----------------------------------------------------------------------
    // Events (Cash tranche only — harmless on Note tranche)
    // -----------------------------------------------------------------------

    event SyncDeposit(address indexed receiver, uint256 assets, uint256 shares, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error OnlyLiquidityBridge(address caller);

    // -----------------------------------------------------------------------
    // Functions
    // -----------------------------------------------------------------------

    /// @notice Synchronous ERC-4626 deposit restricted to LiquidityBridge.
    ///         Immediately mints shares at current sharePrice; bypasses ERC-7540 queue.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Address of the LiquidityBridge allowed to call the sync deposit.
    function liquidityBridge() external view returns (address);
}
