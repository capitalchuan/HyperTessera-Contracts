// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title Constants — HyperTessera Earn protocol-wide constants
/// @notice Only universal, non-product-specific values live here. Per-product parameters
///         (cycle duration, maturity, NAV tolerance, fees, etc.) belong in ProductParams.
library Constants {
    /// @notice Basis-points denominator.
    uint256 internal constant BPS_DENOMINATOR = 10_000;
}
