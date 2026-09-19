// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {FeePaymentKind, CreationFeeAction} from "../libs/Types.sol";

/// @title IVaultFactory
/// @notice Interface for the VaultFactory that deploys and registers HyperTessera vaults.
///         Permissionless — anyone may deploy a Vault; the caller (or `params.owner`, if set)
///         becomes its Owner. (development-plan §3.3.1 — VaultFactory; 角色权限与职责修改方案 §5,
///         §12.1 G-56)
interface IVaultFactory {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    enum VaultType {
        EARN,
        LP
    }

    struct VaultParams {
        VaultType vaultType;
        string name;
        string symbol;
        address usdt;
        address stateManager;
        address settlement; // address(0) at W3 deploy; wired post-W4
        address queue;
        address owner; // address(0) => msg.sender becomes Owner
        address liquidityBridge; // address(0) for Note tranche EarnVault
        address cashVault; // LiquidityEarnVault only
        FeePaymentKind feeKind;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event VaultDeployed(
        VaultType indexed vaultType,
        address indexed vault,
        address indexed owner,
        address vaultTimelock,
        string name,
        string symbol,
        uint256 timestamp
    );

    event VaultCreationFeeCollected(
        CreationFeeAction indexed action,
        FeePaymentKind indexed kind,
        uint256 amount,
        address indexed payer,
        uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error InvalidVaultType(uint8 vaultType);
    error ZeroAddress();
    error IncorrectNativeFee(uint256 expected, uint256 provided);
    error UnexpectedNativeValue();
    error FeeTransferFailed();
    error PaymentTokenNotConfigured(FeePaymentKind kind);

    // -----------------------------------------------------------------------
    // Functions
    // -----------------------------------------------------------------------

    /// @notice Deploy a Vault, its own VaultTimelock, register it in StateManager, and wire all
    ///         addresses. Permissionless.
    function deployVault(VaultParams calldata params) external payable returns (address vault);

    /// @notice Address of the wired ProtocolFeeConfig used to gate deployVault's creation fee.
    function feeConfig() external view returns (address);
}
