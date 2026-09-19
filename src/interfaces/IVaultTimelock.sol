// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IVaultTimelock
/// @notice Per-Vault delay queue protecting Owner-class and Curator-class parameter changes.
///         Replaces the global ProtocolTimelock — the protocol layer no longer runs a Timelock;
///         every Vault gets its own instance, bound at deploy time and never rebindable.
interface IVaultTimelock {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    /// @notice Which local role may schedule a given (target, selector) pair.
    enum ActionClass {
        OWNER,
        CURATOR
    }

    /// @notice One whitelisted (target, selector, class) tuple, as returned by
    ///         `allowedActionsPaged`.
    struct AllowedAction {
        address target;
        bytes4 selector;
        ActionClass class;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event ParamChangeScheduled(
        bytes32 indexed changeId, address indexed target, bytes data, uint256 executableAfter, uint256 expiresAt
    );
    event ParamChangeExecuted(bytes32 indexed changeId, uint256 executedAt);
    event ParamChangeCancelled(bytes32 indexed changeId, uint256 cancelledAt);
    event DelayUpdated(uint256 oldDelay, uint256 newDelay, uint256 timestamp);
    event AllowedActionSet(
        address indexed target, bytes4 indexed selector, ActionClass class, bool allowed, uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error NotOwnerOrCurator();
    error NotOwnerOrGuardianOrProposer();
    error NotSelf();
    error ActionNotAllowed(address target, bytes4 selector);
    error EntryNotFound();
    error AlreadyExecuted();
    error AlreadyCancelled();
    error TooEarly();
    error Expired();
    error CallFailed();
    error DelayOutOfRange();

    // -----------------------------------------------------------------------
    // State accessors
    // -----------------------------------------------------------------------

    function vault() external view returns (address);
    function delay() external view returns (uint256);
    function changeNonce() external view returns (uint256);
    function isActionAllowed(address target, bytes4 selector, ActionClass class) external view returns (bool);

    // -----------------------------------------------------------------------
    // Pending-change index
    // -----------------------------------------------------------------------
    // `pendingChanges` is bytes32-keyed, so it answers "what is change X?" but never "what is
    // queued on this Vault right now?" — today that needs a three-way replay of
    // ParamChangeScheduled / ParamChangeExecuted / ParamChangeCancelled with the surviving set
    // reconstructed by hand. Missing a queued change means missing a pending privileged action,
    // so this is the one index here whose absence is a monitoring gap rather than a convenience gap.

    /// @notice Number of changes scheduled and neither executed nor cancelled.
    function pendingChangeCount() external view returns (uint256);

    /// @notice Up to `limit` currently-pending changeIds starting at `offset`. Pass each to
    ///         `pendingChanges(changeId)` for its target, calldata, proposer and timing.
    /// @dev    Clamped, not checked: an offset at or past the end yields an empty array and an
    ///         overlong limit yields a short page, so a caller can page without reading
    ///         `pendingChangeCount` first.
    ///         This is the exact live queue: executing or cancelling removes the entry. Ordering
    ///         is therefore NOT stable — both removal paths swap the last entry into the freed
    ///         slot and pop — so pin a single `blockTag` across the count and the pages that
    ///         follow it.
    ///         An *expired* change is still listed: expiry is a timestamp comparison, not a state
    ///         transition, and no path sweeps it. Check `expiresAt` per entry to separate
    ///         actionable changes from stale ones.
    function pendingChangesPaged(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    // -----------------------------------------------------------------------
    // Allowed-action index
    // -----------------------------------------------------------------------
    // `isActionAllowed` is a triple-nested mapping and so cannot be walked at all: "what is this
    // Timelock permitted to do?" is answerable today only by replaying every `setAllowedAction`
    // against the constructor's pre-seeded set.

    /// @notice Number of distinct (target, selector, class) tuples ever allowed on this Timelock,
    ///         including the constructor's pre-seeded set.
    function allowedActionCount() external view returns (uint256);

    /// @notice Up to `limit` allowed-action tuples starting at `offset`.
    /// @dev    Clamped on the same terms as `pendingChangesPaged`.
    ///         This index is APPEND-ONLY, unlike the pending-change index above: a tuple is
    ///         recorded the first time it is allowed and is never removed, so an index is stable
    ///         forever and safe to cache across blocks. The cost of that stability is that an
    ///         entry is a candidate, not a permission — `setAllowedAction(..., false)` leaves it
    ///         listed. Callers MUST re-check every entry through `isActionAllowed(target,
    ///         selector, class)` before treating it as currently permitted.
    function allowedActionsPaged(uint256 offset, uint256 limit) external view returns (AllowedAction[] memory);

    // -----------------------------------------------------------------------
    // Core functions
    // -----------------------------------------------------------------------

    /// @notice Schedules a parameter change. Caller must be the bound Vault's Owner (may submit
    ///         any whitelisted OWNER-class action) or Curator (may submit any whitelisted
    ///         CURATOR-class action); `target`+`selector` must be on the allowed-action whitelist
    ///         for the caller's class.
    function scheduleParamChange(address target, bytes calldata data) external returns (bytes32 changeId);

    /// @notice Executes a previously scheduled change after its delay elapses and before it
    ///         expires. Permissionless — any caller (including a Relayer/Keeper Bot) may execute.
    function executeParamChange(bytes32 changeId) external;

    /// @notice Cancels a pending change. Caller must be the Vault Owner, Vault Guardian, or the
    ///         original proposer.
    function cancelParamChange(bytes32 changeId) external;

    /// @notice Updates this Timelock's own delay. Self-scheduled only (msg.sender == address(this))
    ///         — i.e. must be queued through scheduleParamChange/executeParamChange against the old
    ///         delay like any other change; the Owner cannot shorten or lengthen it instantly.
    function setDelay(uint256 newDelay) external;

    /// @notice Adds/removes a (target, selector) pair from the allowed-action whitelist for a
    ///         given class. Self-scheduled only (msg.sender == address(this)) — the Owner submits
    ///         this through the normal schedule/execute flow, it is never called directly.
    function setAllowedAction(address target, bytes4 selector, ActionClass class, bool allowed) external;
}
