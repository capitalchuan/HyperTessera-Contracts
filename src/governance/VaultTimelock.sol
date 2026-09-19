// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IVaultTimelock} from "../interfaces/IVaultTimelock.sol";
import {IVaultRoles} from "../interfaces/IVaultRoles.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {IStateManager} from "../interfaces/IStateManager.sol";
import {ProductState} from "../libs/Types.sol";

/// @title VaultTimelock
/// @notice One instance per Vault, deployed and bound by VaultFactory; never rebindable to a
///         different Vault. Delay-queues Owner-class and Curator-class parameter changes behind
///         a per-target-and-selector whitelist. Replaces the global ProtocolTimelock: the
///         protocol layer runs no Timelock of its own.
contract VaultTimelock is IVaultTimelock {
    // -----------------------------------------------------------------------
    // Delay bounds
    // -----------------------------------------------------------------------

    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant DEFAULT_DELAY = 48 hours;
    uint256 public constant EXECUTION_WINDOW = 7 days;

    // -----------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------

    /// @inheritdoc IVaultTimelock
    address public immutable override vault;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    struct PendingChange {
        address target;
        bytes data;
        address proposer;
        uint256 executableAfter;
        uint256 expiresAt;
        bool executed;
        bool cancelled;
    }

    /// @inheritdoc IVaultTimelock
    uint256 public override delay;

    /// @inheritdoc IVaultTimelock
    uint256 public override changeNonce;

    mapping(bytes32 changeId => PendingChange) public pendingChanges;

    /// @dev Enumerable counterpart to `pendingChanges`, which is bytes32-keyed and therefore
    ///      answers "what is change X?" but never "what is queued right now?". Holds exactly the
    ///      changeIds that have been scheduled and neither executed nor cancelled — both of those
    ///      paths swap-and-pop, so indices are not stable. Note an *expired* change is still in
    ///      here: nothing sweeps it, and no path mutates its flags, so read `expiresAt` per entry
    ///      if you need to distinguish "actionable" from merely "not yet resolved".
    bytes32[] private _pendingList;

    /// @inheritdoc IVaultTimelock
    mapping(address target => mapping(bytes4 selector => mapping(ActionClass class => bool)))
        public
        override isActionAllowed;

    /// @dev Enumerable counterpart to `isActionAllowed`, which is triple-nested and so cannot be
    ///      walked at all — "what is this Timelock permitted to do?" is a security-review question
    ///      that otherwise requires replaying every `setAllowedAction`. Append-only, unlike
    ///      `_pendingList`: an entry is pushed the first time a tuple is allowed and never
    ///      removed, so indices are stable forever, and callers MUST re-check each entry through
    ///      `isActionAllowed` because it may since have been set false.
    AllowedAction[] private _allowedActionList;

    /// @dev Dedupe guard for `_allowedActionList` — a tuple toggled off and back on must not be
    ///      pushed twice.
    mapping(address target => mapping(bytes4 selector => mapping(ActionClass class => bool))) private _actionListed;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @param vault_ The Vault this Timelock is permanently bound to.
    /// @dev    Pre-seeds the whitelist for the fixed set of BaseVault/self targets known at deploy
    ///         time. Adapter-specific targets are not known yet at this
    ///         point — the Vault Owner whitelists those directly while the Vault is still
    ///         CONFIGURING (see `setAllowedAction`), mirroring the same direct-during-CONFIGURING /
    ///         Timelock-gated-after pattern used throughout the rest of the Vault's own parameter
    ///         surface. NAVOracle is no longer Vault-governed at all (NAVOracle/RWAAdapter redesign).
    constructor(address vault_) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        delay = DEFAULT_DELAY;

        _setAllowed(vault_, IBaseVault.setSettlement.selector, ActionClass.OWNER, true);
        _setAllowed(vault_, IBaseVault.setUnifiedPool.selector, ActionClass.OWNER, true);
        _setAllowed(vault_, IBaseVault.setGate.selector, ActionClass.OWNER, true);
        _setAllowed(vault_, IBaseVault.configureClaimRegistry.selector, ActionClass.OWNER, true);
        _setAllowed(vault_, IBaseVault.writeDownInsolvency.selector, ActionClass.OWNER, true);
        _setAllowed(address(this), this.setDelay.selector, ActionClass.OWNER, true);
        _setAllowed(address(this), this.setAllowedAction.selector, ActionClass.OWNER, true);

        _setAllowed(vault_, IBaseVault.setPerformanceFeeBps.selector, ActionClass.CURATOR, true);
        _setAllowed(vault_, IBaseVault.setPerformanceFeeRecipient.selector, ActionClass.CURATOR, true);
        _setAllowed(vault_, IBaseVault.addAdapter.selector, ActionClass.CURATOR, true);
        _setAllowed(vault_, IBaseVault.removeAdapter.selector, ActionClass.CURATOR, true);
        _setAllowed(vault_, IBaseVault.setSubscriptionCapShare.selector, ActionClass.CURATOR, true);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// @dev Writes the whitelist mapping and indexes the tuple the first time it is ever allowed.
    ///      The list is append-only, so a later `allowed == false` leaves the entry in place —
    ///      readers filter through `isActionAllowed`.
    function _setAllowed(address target, bytes4 selector, ActionClass class, bool allowed) internal {
        isActionAllowed[target][selector][class] = allowed;
        if (allowed && !_actionListed[target][selector][class]) {
            _actionListed[target][selector][class] = true;
            _allowedActionList.push(AllowedAction({target: target, selector: selector, class: class}));
        }
    }

    /// @dev Drops `changeId` from the pending list. Swap-and-pop, so an unrelated entry's index
    ///      moves; called from both the execute and the cancel path so the list and the mapping
    ///      flags never disagree.
    function _dropPending(bytes32 changeId) internal {
        uint256 len = _pendingList.length;
        for (uint256 i; i < len; ++i) {
            if (_pendingList[i] == changeId) {
                _pendingList[i] = _pendingList[len - 1];
                _pendingList.pop();
                break;
            }
        }
    }

    function _isConfiguring() internal view returns (bool) {
        address sm = IVaultRoles(vault).stateManager();
        return IStateManager(sm).getProductState(vault) == ProductState.CONFIGURING;
    }

    // -----------------------------------------------------------------------
    // scheduleParamChange
    // -----------------------------------------------------------------------

    /// @inheritdoc IVaultTimelock
    function scheduleParamChange(address target, bytes calldata data) external override returns (bytes32 changeId) {
        if (target == address(0)) revert ZeroAddress();

        IVaultRoles roles = IVaultRoles(vault);
        ActionClass class;
        if (msg.sender == roles.owner()) {
            class = ActionClass.OWNER;
        } else if (msg.sender == roles.curator()) {
            class = ActionClass.CURATOR;
        } else {
            revert NotOwnerOrCurator();
        }

        bytes4 selector = bytes4(data);
        if (!isActionAllowed[target][selector][class]) revert ActionNotAllowed(target, selector);

        changeId = keccak256(abi.encode(address(this), block.chainid, vault, target, data, changeNonce));
        changeNonce += 1;

        uint256 executableAfter = block.timestamp + delay;
        uint256 expiresAt = executableAfter + EXECUTION_WINDOW;
        pendingChanges[changeId] = PendingChange({
            target: target,
            data: data,
            proposer: msg.sender,
            executableAfter: executableAfter,
            expiresAt: expiresAt,
            executed: false,
            cancelled: false
        });

        _pendingList.push(changeId);

        emit ParamChangeScheduled(changeId, target, data, executableAfter, expiresAt);
    }

    // -----------------------------------------------------------------------
    // executeParamChange
    // -----------------------------------------------------------------------

    /// @inheritdoc IVaultTimelock
    function executeParamChange(bytes32 changeId) external override {
        PendingChange storage c = pendingChanges[changeId];

        if (c.executableAfter == 0) revert EntryNotFound();
        if (c.executed) revert AlreadyExecuted();
        if (c.cancelled) revert AlreadyCancelled();
        if (block.timestamp < c.executableAfter) revert TooEarly();
        if (block.timestamp > c.expiresAt) revert Expired();

        c.executed = true;
        _dropPending(changeId);

        (bool success,) = c.target.call(c.data);
        if (!success) revert CallFailed();

        emit ParamChangeExecuted(changeId, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // cancelParamChange
    // -----------------------------------------------------------------------

    /// @inheritdoc IVaultTimelock
    function cancelParamChange(bytes32 changeId) external override {
        PendingChange storage c = pendingChanges[changeId];
        if (c.executableAfter == 0) revert EntryNotFound();
        if (c.executed) revert AlreadyExecuted();
        if (c.cancelled) revert AlreadyCancelled();

        IVaultRoles roles = IVaultRoles(vault);
        if (msg.sender != roles.owner() && msg.sender != roles.guardian() && msg.sender != c.proposer) {
            revert NotOwnerOrGuardianOrProposer();
        }

        c.cancelled = true;
        _dropPending(changeId);

        emit ParamChangeCancelled(changeId, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Self-scheduled configuration
    // -----------------------------------------------------------------------

    /// @inheritdoc IVaultTimelock
    function setDelay(uint256 newDelay) external override {
        if (msg.sender != address(this)) revert NotSelf();
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert DelayOutOfRange();

        uint256 oldDelay = delay;
        delay = newDelay;

        emit DelayUpdated(oldDelay, newDelay, block.timestamp);
    }

    /// @inheritdoc IVaultTimelock
    function setAllowedAction(address target, bytes4 selector, ActionClass class, bool allowed) external override {
        bool isSelf = msg.sender == address(this);
        bool isOwnerBootstrapping = !isSelf && msg.sender == IVaultRoles(vault).owner() && _isConfiguring();
        if (!isSelf && !isOwnerBootstrapping) revert NotSelf();

        _setAllowed(target, selector, class, allowed);
        emit AllowedActionSet(target, selector, class, allowed, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Pending-change index
    // -----------------------------------------------------------------------

    /// @inheritdoc IVaultTimelock
    function pendingChangeCount() external view override returns (uint256) {
        return _pendingList.length;
    }

    /// @inheritdoc IVaultTimelock
    /// @dev Clamps `limit` against the remaining length instead of computing `offset + limit`,
    ///      so a caller paging blind with a huge limit gets a short page rather than an
    ///      arithmetic-overflow revert.
    function pendingChangesPaged(uint256 offset, uint256 limit) external view override returns (bytes32[] memory page) {
        uint256 len = _pendingList.length;
        if (offset >= len) return new bytes32[](0);

        uint256 count = len - offset;
        if (limit < count) count = limit;

        page = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _pendingList[offset + i];
        }
    }

    // -----------------------------------------------------------------------
    // Allowed-action index
    // -----------------------------------------------------------------------

    /// @inheritdoc IVaultTimelock
    function allowedActionCount() external view override returns (uint256) {
        return _allowedActionList.length;
    }

    /// @inheritdoc IVaultTimelock
    /// @dev Clamped on the same terms as `pendingChangesPaged`.
    function allowedActionsPaged(uint256 offset, uint256 limit)
        external
        view
        override
        returns (AllowedAction[] memory page)
    {
        uint256 len = _allowedActionList.length;
        if (offset >= len) return new AllowedAction[](0);

        uint256 count = len - offset;
        if (limit < count) count = limit;

        page = new AllowedAction[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _allowedActionList[offset + i];
        }
    }
}
