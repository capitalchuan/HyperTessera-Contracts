// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {RequestSettlement} from "../libs/Types.sol";

/// @title ISettlement
/// @notice Net-settlement batch execution: M-of-N signature check, per-vault
///         cycle-state check, and pool-cash conservation. Redeem payouts and share pricing are
///         computed entirely on-chain by BaseVault from its own per-cycle price snapshot — there
///         is no off-chain-supplied redeemAmounts/navSnapshot and no NAVOracle consistency step.
///         Operator sets and thresholds are per-vault: this Settlement contract may serve many
///         Vaults, but each Vault's signer set/threshold is independent and managed by that
///         Vault's own Owner. A batch should normally cover a single Vault (it may still contain
///         that Vault's several deposit/redeem requests); a batch spanning multiple Vaults
///         validates each Vault's signature threshold independently against the same submitted
///         signature list.
interface ISettlement {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    struct Distribution {
        address vault;
        uint256 amount; // poolDistributedAssets: USDT to distribute from UnifiedPool to this vault
    }

    struct VaultSettlement {
        Distribution distribution;
        RequestSettlement[] deposits;
        RequestSettlement[] redeems;
    }

    struct SettlementInstruction {
        VaultSettlement[] vaultSettlements;
        uint256 cycleNumber; // must match each vault's currentCycleNumber
        uint256 validUntil; // expiry; prevents stale batches
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event SettlementExecuted(bytes32 indexed batchHash, uint256 cycleNumber, uint256 timestamp);
    event OperatorSet(address indexed vault, address indexed operator, bool approved, uint256 timestamp);
    event ThresholdUpdated(address indexed vault, uint256 oldThreshold, uint256 newThreshold, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error NotVaultOwner();
    error SignatureValidationFailed(address vault);
    error StateValidationFailed(address vault);
    error DepositsNotAllowedInFinalBatch(address vault);
    error ConservationCheckFailed(address vault, uint256 available, uint256 required);
    error BatchExceedsPoolCash(uint256 totalRequested, uint256 poolCashBalance);
    error ThresholdExceedsOperatorCount(uint256 threshold, uint256 operatorCount);
    error BatchAlreadyExecuted(bytes32 batchHash);
    error BatchExpired(uint256 validUntil, uint256 blockTimestamp);

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @notice Execute a settlement batch after 4-fold validation. Permissionless caller;
    ///         security comes from each Vault's own M-of-N operator signature check (Step 1).
    /// @dev    FIFO constraint: within a single vault's redeem batch, dequeue is strict
    ///         FIFO-from-head (Queue.dequeue). If a redeem request is only partially filled, it
    ///         must be the LAST redeem entry included for that vault in this batch — any request
    ///         queued after it cannot also be included (even if fully cleared), or the batch
    ///         reverts with Queue's OutOfOrderDequeue.
    function submitBatch(SettlementInstruction calldata instruction, bytes[] calldata signatures) external;

    /// @notice Add/remove a settlement operator signer for a single Vault.
    /// @dev    Access: that Vault's Owner.
    function setOperator(address vault, address operator, bool approved) external;

    /// @notice Set the M-of-N signature threshold for a single Vault.
    /// @dev    Access: that Vault's Owner. Must satisfy 1 <= threshold <= that Vault's signer count.
    function setThreshold(address vault, uint256 newThreshold) external;

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    function hashInstruction(SettlementInstruction calldata instruction) external view returns (bytes32);
    function isOperator(address vault, address account) external view returns (bool);
    function executed(bytes32 batchHash) external view returns (bool);
    function threshold(address vault) external view returns (uint256);

    // -----------------------------------------------------------------------
    // Operator index
    // -----------------------------------------------------------------------
    // `isOperator` answers "is this address a signer for that Vault?"; the two below answer
    // "who are that Vault's signers?". The generated getter for the public `operatorsOf`
    // mapping-to-array exposes no `.length`, and unlike `IBaseVault.adapters` there is no
    // MAX_ constant bounding a probe, so without these the signer set is only recoverable by
    // replaying OperatorSet logs.

    /// @notice Number of operators currently approved for `vault`. This is the same count
    ///         `setThreshold` validates against.
    function operatorCount(address vault) external view returns (uint256);

    /// @notice Up to `limit` of `vault`'s current operators starting at `offset`.
    /// @dev    Clamped, not checked: an offset at or past the end yields an empty array and an
    ///         overlong limit yields a short page, so a caller can page without reading
    ///         `operatorCount` first.
    ///         Ordering is NOT stable: revoking an operator swaps the last entry into the freed
    ///         slot and pops, so a revocation moves an unrelated operator's index. Pin a single
    ///         `blockTag` across `operatorCount` and the pages that follow it. Contrast
    ///         `IAdapterFactory`'s adapter index, which is append-only and stable forever.
    function operatorsPaged(address vault, uint256 offset, uint256 limit) external view returns (address[] memory);
}
