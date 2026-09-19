// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IQueue} from "../../interfaces/IQueue.sol";
import {IStateManager} from "../../interfaces/IStateManager.sol";
import {IBaseVault} from "../../interfaces/IBaseVault.sol";
import {QueueType} from "../../libs/Types.sol";

/// @title Queue
/// @notice On-chain FIFO validation anchor for deposit and redeem requests.
///         Each vault has two independent FIFO queues (DEPOSIT, REDEEM). Clearing math is
///         computed off-chain by the SettlementOperator; this contract validates ordering
///         on-chain during settlement.
///
///         Tombstone pattern: cancelled slots are marked with requestId = TOMBSTONE (uint256.max)
///         and auto-skipped during dequeue — the queue array is never shifted.
///
///         LP priority is enforced at the Settlement layer, not here.
contract Queue is IQueue {
    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    uint256 private constant TOMBSTONE = type(uint256).max;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    IStateManager public immutable sm;

    // per-vault, per-queueType FIFO storage
    mapping(address vault => mapping(QueueType queueType => mapping(uint256 slotIndex => QueueSlot))) private _slots;
    mapping(address vault => mapping(QueueType queueType => uint256)) public queueHead;
    mapping(address vault => mapping(QueueType queueType => uint256)) public queueTail;

    // O(1) membership and reverse-lookup, keyed by keccak256(abi.encode(vault, queueType, requestId))
    mapping(bytes32 queueKey => bool) private _isInQueue;
    mapping(bytes32 queueKey => uint256) private _queueIndex;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address _sm) {
        if (_sm == address(0)) revert ZeroAddress();
        sm = IStateManager(_sm);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _onlySettlement(address vault) internal view {
        if (msg.sender != IBaseVault(vault).settlement()) revert NotSettlement();
    }

    function _onlyRegisteredVault(address vault) internal view {
        if (!sm.registeredVaults(vault)) revert UnregisteredVault(vault);
    }

    function _key(address vault, QueueType queueType, uint256 requestId) internal pure returns (bytes32) {
        return keccak256(abi.encode(vault, queueType, requestId));
    }

    // Advance head past any tombstones.
    function _skipTombstones(address vault, QueueType queueType) internal {
        uint256 head = queueHead[vault][queueType];
        uint256 tail = queueTail[vault][queueType];
        while (head < tail && _slots[vault][queueType][head].requestId == TOMBSTONE) {
            ++head;
        }
        queueHead[vault][queueType] = head;
    }

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @inheritdoc IQueue
    function enqueue(address vault, QueueType queueType, uint256 requestId, address owner, uint256 amount)
        external
        override
    {
        _onlyRegisteredVault(vault);
        // Caller must be the vault itself.
        if (msg.sender != vault) revert UnregisteredVault(msg.sender);

        uint256 slotIdx = queueTail[vault][queueType];
        bytes32 orderHash = keccak256(abi.encode(requestId, owner, amount, block.timestamp));

        _slots[vault][queueType][slotIdx] = QueueSlot({requestId: requestId, orderHash: orderHash});
        queueTail[vault][queueType] = slotIdx + 1;

        bytes32 key = _key(vault, queueType, requestId);
        _isInQueue[key] = true;
        _queueIndex[key] = slotIdx;

        emit RequestQueued(vault, queueType, requestId, slotIdx, orderHash, block.timestamp);
    }

    /// @inheritdoc IQueue
    function dequeue(address vault, QueueType queueType, uint256[] calldata requestIds) external override {
        // Matches enqueue/remove. Queue storage is keyed per vault, so a forged vault could only
        // ever churn its own empty queue — but the entry points should not disagree about what a
        // vault is.
        _onlyRegisteredVault(vault);
        _onlySettlement(vault);

        for (uint256 i = 0; i < requestIds.length; ++i) {
            uint256 rid = requestIds[i];
            _skipTombstones(vault, queueType);

            uint256 head = queueHead[vault][queueType];
            uint256 headRid = _slots[vault][queueType][head].requestId;

            if (headRid != rid) revert OutOfOrderDequeue(vault, queueType, headRid, rid);

            queueHead[vault][queueType] = head + 1;
            _isInQueue[_key(vault, queueType, rid)] = false;

            emit RequestDequeued(vault, queueType, rid, head + 1, block.timestamp);
        }
    }

    /// @inheritdoc IQueue
    function remove(address vault, QueueType queueType, uint256 requestId) external override {
        // Caller must be the vault that owns the queue.
        if (msg.sender != vault) revert UnregisteredVault(msg.sender);
        _onlyRegisteredVault(vault);

        bytes32 key = _key(vault, queueType, requestId);
        if (!_isInQueue[key]) revert NotInQueue(vault, queueType, requestId);

        uint256 slotIdx = _queueIndex[key];
        _slots[vault][queueType][slotIdx].requestId = TOMBSTONE;
        _isInQueue[key] = false;

        emit RequestCancelledFromQueue(vault, queueType, requestId, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @inheritdoc IQueue
    function peek(address vault, QueueType queueType) external view override returns (QueueSlot memory) {
        return _slots[vault][queueType][queueHead[vault][queueType]];
    }

    /// @inheritdoc IQueue
    function depth(address vault, QueueType queueType) external view override returns (uint256) {
        return queueTail[vault][queueType] - queueHead[vault][queueType];
    }

    /// @inheritdoc IQueue
    function isInQueue(address vault, QueueType queueType, uint256 requestId) external view override returns (bool) {
        return _isInQueue[_key(vault, queueType, requestId)];
    }

    /// @inheritdoc IQueue
    function verifyOrder(
        address vault,
        QueueType queueType,
        uint256 requestId,
        address owner,
        uint256 amount,
        uint256 timestamp
    ) external view override returns (bool) {
        uint256 slotIdx = _queueIndex[_key(vault, queueType, requestId)];
        bytes32 stored = _slots[vault][queueType][slotIdx].orderHash;
        bytes32 computed = keccak256(abi.encode(requestId, owner, amount, timestamp));
        return stored == computed;
    }
}
