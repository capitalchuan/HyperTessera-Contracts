// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {QueueType} from "../libs/Types.sol";

/// @title IQueue
/// @notice On-chain FIFO validation anchor for deposit and redeem requests.
///         Maintains per-vault, per-QueueType FIFO queues. Clearing math is computed
///         off-chain. (development-plan §3.2.1, §8 — net settlement conversion)
interface IQueue {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    struct QueueSlot {
        uint256 requestId;
        bytes32 orderHash; // keccak256(abi.encode(requestId, owner, amount, enqueueTimestamp))
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event RequestQueued(
        address indexed vault,
        QueueType indexed queueType,
        uint256 indexed requestId,
        uint256 slotIndex,
        bytes32 orderHash,
        uint256 timestamp
    );
    event RequestDequeued(
        address indexed vault,
        QueueType indexed queueType,
        uint256 indexed requestId,
        uint256 newHead,
        uint256 timestamp
    );
    event RequestCancelledFromQueue(
        address indexed vault, QueueType indexed queueType, uint256 indexed requestId, uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error NotSettlement();
    error UnregisteredVault(address caller);
    error NotInQueue(address vault, QueueType queueType, uint256 requestId);
    error OutOfOrderDequeue(address vault, QueueType queueType, uint256 expectedRequestId, uint256 actualRequestId);

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @notice Append a request to `vault`'s `queueType` queue.
    ///         Caller must be a registered vault (StateManager check), and must be `vault` itself.
    function enqueue(address vault, QueueType queueType, uint256 requestId, address owner, uint256 amount) external;

    /// @notice Remove processed requests from the front of `vault`'s `queueType` queue in FIFO order.
    ///         Tombstoned (cancelled) slots are auto-skipped.
    ///         Reverts OutOfOrderDequeue if FIFO ordering is violated.
    /// @dev    Access: `vault`'s own bound Settlement contract.
    function dequeue(address vault, QueueType queueType, uint256[] calldata requestIds) external;

    /// @notice Mark a pending request as cancelled (tombstone).
    ///         Caller must be the registered vault that owns the queue.
    function remove(address vault, QueueType queueType, uint256 requestId) external;

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @notice Returns the head slot for `vault`'s `queueType` queue (may be a tombstone).
    function peek(address vault, QueueType queueType) external view returns (QueueSlot memory);

    /// @notice Returns the number of slots between head and tail (includes tombstones).
    function depth(address vault, QueueType queueType) external view returns (uint256);

    /// @notice Returns true if `requestId` is in `vault`'s `queueType` queue and not tombstoned.
    function isInQueue(address vault, QueueType queueType, uint256 requestId) external view returns (bool);

    /// @notice Recomputes the orderHash and compares against stored value.
    function verifyOrder(
        address vault,
        QueueType queueType,
        uint256 requestId,
        address owner,
        uint256 amount,
        uint256 timestamp
    ) external view returns (bool);
}
