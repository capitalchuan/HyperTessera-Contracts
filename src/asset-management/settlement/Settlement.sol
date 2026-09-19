// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {ISettlement} from "../../interfaces/ISettlement.sol";
import {IStateManager} from "../../interfaces/IStateManager.sol";
import {IUnifiedPool} from "../../interfaces/IUnifiedPool.sol";
import {IQueue} from "../../interfaces/IQueue.sol";
import {IBaseVault} from "../../interfaces/IBaseVault.sol";
import {IVaultRoles} from "../../interfaces/IVaultRoles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CycleState, ProductState, QueueType, RequestSettlement} from "../../libs/Types.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title Settlement
/// @notice Translates the off-chain per-cycle FIFO-prefix selection into on-chain
///         share mint/burn and USDT movement, behind M-of-N multi-sig and pool-cash conservation.
///         Redeem payouts and share pricing are computed entirely on-chain by BaseVault from its
///         own per-cycle price snapshot. May serve many Vaults; each Vault's signer set/threshold
///         is independent, managed by that Vault's own Owner.
contract Settlement is ISettlement {
    using ECDSA for bytes32;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    IStateManager public immutable sm;
    IUnifiedPool public immutable unifiedPool;
    IQueue public immutable queue;

    mapping(bytes32 batchHash => bool) public override executed;
    mapping(address vault => address[]) public operatorsOf;
    mapping(address vault => mapping(address => bool)) public override isOperator;
    mapping(address vault => uint256) public override threshold;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address stateManager_, address unifiedPool_, address queue_) {
        if (stateManager_ == address(0) || unifiedPool_ == address(0) || queue_ == address(0)) revert ZeroAddress();

        sm = IStateManager(stateManager_);
        unifiedPool = IUnifiedPool(unifiedPool_);
        queue = IQueue(queue_);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _onlyVaultOwner(address vault) internal view {
        if (IVaultRoles(vault).owner() != msg.sender) revert NotVaultOwner();
    }

    function _depositIds(RequestSettlement[] calldata items) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](items.length);
        for (uint256 i = 0; i < items.length; i++) {
            ids[i] = items[i].requestId;
        }
    }

    // -----------------------------------------------------------------------
    // submitBatch — signature, state, and pool-cash conservation validation
    // -----------------------------------------------------------------------

    /// @inheritdoc ISettlement
    function submitBatch(SettlementInstruction calldata instruction, bytes[] calldata signatures) external override {
        bytes32 batchHash = _hashInstruction(instruction);
        if (executed[batchHash]) revert BatchAlreadyExecuted(batchHash);
        if (block.timestamp > instruction.validUntil) revert BatchExpired(instruction.validUntil, block.timestamp);

        // Step 1 — signature validation, independently per Vault represented in the batch
        for (uint256 i = 0; i < instruction.vaultSettlements.length; i++) {
            _validateSignatures(instruction.vaultSettlements[i].distribution.vault, batchHash, signatures);
        }

        // Step 2 — state validation
        for (uint256 i = 0; i < instruction.vaultSettlements.length; i++) {
            address v = instruction.vaultSettlements[i].distribution.vault;
            sm.requireCycleState(v, CycleState.CALCULATING);
            if (sm.currentCycleNumber(v) != instruction.cycleNumber) revert StateValidationFailed(v);

            // The FINAL batch settles redemptions only. A subscription accepted at maturity would
            // mint shares against a price struck on wound-down assets and immediately have
            // nothing left to invest in, so those requests stay queued for their owners to cancel
            // and reclaim.
            if (instruction.vaultSettlements[i].deposits.length > 0 && sm.isFinalCycle(v)) {
                revert DepositsNotAllowedInFinalBatch(v);
            }
        }

        // Step 3 — pool-cash conservation (dedup by vault, plus an aggregate check against the
        // pool's actual USDT balance — availableToDistribute alone doesn't catch a batch whose
        // per-vault amounts each fit individually but collectively exceed what's on hand).
        _validateConservation(instruction);

        // Execute — two phases, so that cross-vault settlement dependencies can be expressed.
        //
        // Phase A prices every Vault in the batch before ANY of them settles. This matters for
        // the Cash Vault / LP Vault pair: the LP Vault's settle() bridges USDT into the Cash
        // Vault, and that inflow must not land before the Cash Vault has accrued its
        // performance fee (otherwise the fee is charged against the LP's fresh money and the
        // freshly-minted fee shares dilute the LP retroactively).
        //
        // Phase B then settles in the caller-supplied array order. With [LP Vault, Cash Vault]
        // the LP's bridged USDT arrives before the Cash Vault's redeem settlement and can fund
        // it in the same cycle — the property that ordering alone could never give, since
        // [Cash Vault, LP Vault] fixes the fee timing but delivers the USDT too late.
        //
        // Queue dequeue and UnifiedPool distribution stay in Phase A, ahead of the snapshot,
        // exactly where they were relative to it before. Both are per-vault and carry no
        // cross-vault state, and `distribute` is price-neutral (it converts a UnifiedPool
        // receivable that `grossManagedAssets()` already counts into vault-held USDT).
        executed[batchHash] = true;

        for (uint256 i = 0; i < instruction.vaultSettlements.length; i++) {
            VaultSettlement calldata vs = instruction.vaultSettlements[i];
            address v = vs.distribution.vault;

            if (vs.deposits.length > 0) {
                queue.dequeue(v, QueueType.DEPOSIT, _depositIds(vs.deposits));
            }
            if (vs.distribution.amount > 0) unifiedPool.distribute(v, vs.distribution.amount);
            IBaseVault(v).snapshotSettlementPrice(instruction.cycleNumber);
        }

        for (uint256 i = 0; i < instruction.vaultSettlements.length; i++) {
            VaultSettlement calldata vs = instruction.vaultSettlements[i];
            address v = vs.distribution.vault;

            uint256[] memory clearedRedeemIds =
                IBaseVault(v).settle(instruction.cycleNumber, vs.deposits, vs.redeems, vs.distribution.amount);
            if (clearedRedeemIds.length > 0) {
                queue.dequeue(v, QueueType.REDEEM, clearedRedeemIds);
            }
            sm.completeCycle(v);
        }

        emit SettlementExecuted(batchHash, instruction.cycleNumber, block.timestamp);
    }

    function _validateSignatures(address vault, bytes32 batchHash, bytes[] calldata signatures) internal view {
        // An unconfigured Vault (Owner never called `setThreshold`) has threshold 0, which would
        // otherwise let an empty signature array satisfy the M-of-N check. Treat "not yet
        // configured" as "never valid" rather than "always valid".
        if (threshold[vault] == 0) revert SignatureValidationFailed(vault);

        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(batchHash);
        uint256 validSigners = 0;
        address[] memory seen = new address[](signatures.length);

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ethHash.recover(signatures[i]);

            bool dup = false;
            for (uint256 j = 0; j < validSigners; j++) {
                if (seen[j] == signer) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (!isOperator[vault][signer]) continue;

            seen[validSigners] = signer;
            validSigners++;
        }

        if (validSigners < threshold[vault]) revert SignatureValidationFailed(vault);
    }

    function _validateConservation(SettlementInstruction calldata instruction) internal view {
        uint256 len = instruction.vaultSettlements.length;
        address[] memory vaults = new address[](len);
        uint256[] memory totals = new uint256[](len);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < len; i++) {
            address v = instruction.vaultSettlements[i].distribution.vault;
            uint256 amount = instruction.vaultSettlements[i].distribution.amount;

            uint256 idx = type(uint256).max;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (vaults[j] == v) {
                    idx = j;
                    break;
                }
            }
            if (idx == type(uint256).max) {
                vaults[uniqueCount] = v;
                totals[uniqueCount] = amount;
                uniqueCount++;
            } else {
                totals[idx] += amount;
            }
        }

        uint256 batchTotal;
        for (uint256 i = 0; i < uniqueCount; i++) {
            uint256 available = unifiedPool.availableToDistribute(vaults[i]);
            if (available < totals[i]) revert ConservationCheckFailed(vaults[i], available, totals[i]);
            batchTotal += totals[i];
        }

        uint256 poolCashBalance = unifiedPool.usdt().balanceOf(address(unifiedPool));
        if (batchTotal > poolCashBalance) revert BatchExceedsPoolCash(batchTotal, poolCashBalance);
    }

    // -----------------------------------------------------------------------
    // Operator management — that Vault's Owner only
    // -----------------------------------------------------------------------

    /// @inheritdoc ISettlement
    function setOperator(address vault, address operator, bool approved) external override {
        _onlyVaultOwner(vault);
        if (operator == address(0)) revert ZeroAddress();

        if (approved && !isOperator[vault][operator]) {
            isOperator[vault][operator] = true;
            operatorsOf[vault].push(operator);
        } else if (!approved && isOperator[vault][operator]) {
            isOperator[vault][operator] = false;
            address[] storage ops = operatorsOf[vault];
            uint256 len = ops.length;
            for (uint256 i = 0; i < len; i++) {
                if (ops[i] == operator) {
                    ops[i] = ops[len - 1];
                    ops.pop();
                    break;
                }
            }
            if (threshold[vault] > ops.length) revert ThresholdExceedsOperatorCount(threshold[vault], ops.length);
        }

        emit OperatorSet(vault, operator, approved, block.timestamp);
    }

    /// @inheritdoc ISettlement
    function setThreshold(address vault, uint256 newThreshold) external override {
        _onlyVaultOwner(vault);
        uint256 signerCount = operatorsOf[vault].length;
        if (newThreshold == 0 || newThreshold > signerCount) {
            revert ThresholdExceedsOperatorCount(newThreshold, signerCount);
        }
        uint256 old = threshold[vault];
        threshold[vault] = newThreshold;
        emit ThresholdUpdated(vault, old, newThreshold, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @inheritdoc ISettlement
    function operatorCount(address vault) external view override returns (uint256) {
        return operatorsOf[vault].length;
    }

    /// @inheritdoc ISettlement
    /// @dev Clamps `limit` against the remaining length instead of computing `offset + limit`,
    ///      so a caller paging blind with a huge limit gets a short page rather than an
    ///      arithmetic-overflow revert.
    function operatorsPaged(address vault, uint256 offset, uint256 limit)
        external
        view
        override
        returns (address[] memory page)
    {
        address[] storage ops = operatorsOf[vault];
        uint256 len = ops.length;
        if (offset >= len) return new address[](0);

        uint256 count = len - offset;
        if (limit < count) count = limit;

        page = new address[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = ops[offset + i];
        }
    }

    /// @inheritdoc ISettlement
    function hashInstruction(SettlementInstruction calldata instruction) external view override returns (bytes32) {
        return _hashInstruction(instruction);
    }

    /// @dev Domain-separated by this contract's own address and the chain id. Without them the
    ///      same instruction hashes identically on every Settlement instance and every chain, so
    ///      an M-of-N signature set collected for one could be replayed verbatim against another.
    function _hashInstruction(SettlementInstruction calldata instruction) internal view returns (bytes32) {
        return keccak256(abi.encode("HT_SETTLEMENT_BATCH", address(this), block.chainid, instruction));
    }
}
