// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {CreationFeeAction, FeePaymentKind} from "../libs/Types.sol";

/// @title IProtocolFeeConfig
/// @notice Pure configuration for protocol-level creation fees (AssetRegistry.registerAsset,
///         VaultFactory.deployVault). Never custodies funds — callers collect and forward fees
///         directly to `revenuePool()` themselves. Governor-configurable per deployment/network;
///         every (action, payment kind) amount may be set to 0.
interface IProtocolFeeConfig {
    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event FeeSet(CreationFeeAction indexed action, FeePaymentKind indexed kind, uint256 amount, uint256 timestamp);
    event PaymentTokenSet(FeePaymentKind indexed kind, address token, uint256 timestamp);
    event RevenuePoolSet(address oldPool, address newPool, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error NotGovernor();
    error NativeKindHasNoToken();

    // -----------------------------------------------------------------------
    // Mutating functions — Governor only
    // -----------------------------------------------------------------------

    function setFee(CreationFeeAction action, FeePaymentKind kind, uint256 amount) external;
    function setPaymentToken(FeePaymentKind kind, address token) external;
    function setRevenuePool(address pool) external;

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    function feeOf(CreationFeeAction action, FeePaymentKind kind) external view returns (uint256);
    function paymentTokenOf(FeePaymentKind kind) external view returns (address);
    function revenuePool() external view returns (address);
}
