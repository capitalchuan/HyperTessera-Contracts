// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {ProductState, CycleState, PauseState, StateContext, ProductParams, ModuleId} from "../libs/Types.sol";

/// @title IStateManager
/// @notice External surface of the three-layer product state machine.
///         All vault / Settlement / Keeper lifecycle interactions flow through here.
interface IStateManager {
    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event VaultRegistered(
        address indexed vault, ProductState initialProduct, CycleState initialCycle, uint256 timestamp
    );
    event ProductStateChanged(address indexed vault, ProductState from, ProductState to, uint256 timestamp);
    event CycleStateChanged(
        address indexed vault, CycleState from, CycleState to, uint256 cycleNumber, uint256 timestamp
    );
    event VaultPauseSet(address indexed vault, PauseState reason, address indexed actor, uint256 timestamp);
    event VaultUnpaused(address indexed vault, PauseState previousReason, address indexed actor, uint256 timestamp);
    event ProductParamsSet(address indexed vault, uint256 timestamp);
    event FinalCycleStarted(address indexed vault, uint256 cycleNumber, uint256 maturityTimestamp, uint256 timestamp);
    event ModulePaused(ModuleId indexed id, address indexed actor, uint256 timestamp);
    event ModuleUnpaused(ModuleId indexed id, address indexed actor, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error VaultNotRegistered(address vault);
    error VaultAlreadyRegistered(address vault);
    error InvalidStateTransition(ProductState from, ProductState to);
    error InvalidCycleTransition(CycleState from, CycleState to);
    error VaultPausedError(address vault, PauseState reason);
    error WrongProductState(ProductState expected, ProductState actual);
    error WrongCycleState(CycleState expected, CycleState actual);
    error CycleStateMismatch(address vault, CycleState expected, CycleState actual);
    error WalletCapExceeded(address wallet, uint256 cap, uint256 requested);
    error NotFundingFailed(address vault);
    error NotKeeper();
    error NotGovernor();
    error NotGuardian();
    error NotSettlement();
    error Unauthorized();
    error InvalidPauseReason();
    error AlreadyPaused(address vault);
    error NotPaused(address vault);
    error ModuleIsPaused(ModuleId id);
    error ConditionNotMet(string reason);
    error NotVaultFactory();
    error VaultFactoryAlreadySet();
    error InvalidProductParams(string field);

    // -----------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------

    /// @notice One-time wiring of the official VaultFactory allowed to call registerVault.
    /// @dev    GOVERNOR_ROLE. Can only be set once.
    function setVaultFactory(address factory) external;

    /// @notice Register a vault. Its initial three-layer state is fixed at
    ///         CONFIGURING / ACCEPTING / ACTIVE — not taken from the caller.
    /// @dev    Access: the wired VaultFactory only. Reverts VaultAlreadyRegistered if already registered.
    function registerVault(address vault) external;

    // -----------------------------------------------------------------------
    // Product params
    // -----------------------------------------------------------------------

    /// @notice Set lifecycle and fee parameters for a vault, including its initial
    ///         `subscriptionCapShare`, which is pushed straight into the vault.
    /// @dev    Access: that vault's own Curator. Only callable while product is CONFIGURING.
    ///         Reverts InvalidProductParams on an unset or inconsistent parameter set.
    function setProductParams(address vault, ProductParams calldata params) external;

    // -----------------------------------------------------------------------
    // Subscription tracking (called by registered vaults)
    // -----------------------------------------------------------------------

    /// @notice Record a new subscription. Called by BaseVault.requestDeposit.
    /// @dev    Caller must be a registered vault.
    function recordSubscription(address vault, address wallet, uint256 amount) external;

    /// @notice Release a subscription (cancel or refund). Called by BaseVault.
    /// @dev    Caller must be a registered vault.
    function releaseSubscription(address vault, address wallet, uint256 amount) external;

    // -----------------------------------------------------------------------
    // Lifecycle — Keeper
    // -----------------------------------------------------------------------

    /// @notice CONFIGURING → SUBSCRIBING.  Requires now >= params.subscriptionStart.
    function openSubscription(address vault) external;

    /// @notice SUBSCRIBING → OPERATING or FUNDING_FAILED.
    ///         Requires now >= params.subscriptionEnd.
    ///         OPERATING if totalSubscribed >= minRaiseAmount; FUNDING_FAILED otherwise.
    function finalizeSubscription(address vault) external;

    /// @notice ACCEPTING → CALCULATING. Requires now >= currentCycleStart + cycleDuration, OR
    ///         now >= params.maturityTimestamp.
    ///
    ///         Past maturity this also moves the product OPERATING → SETTLING in the same
    ///         transaction and flags the cycle as FINAL, so the final cycle runs from
    ///         SETTLING/CALCULATING: queues are frozen and no new business is admitted for the
    ///         whole time it is being priced and settled.
    function startCycleCalculation(address vault) external;

    /// @notice MATURING → CLAIMING.  Requires now >= params.claimingStart.
    function enterClaiming(address vault) external;

    /// @notice CLAIMING → CLOSED.
    function closeProduct(address vault) external;

    // -----------------------------------------------------------------------
    // Lifecycle — Settlement (atomic cycle completion)
    // -----------------------------------------------------------------------

    /// @notice CALCULATING → FULFILLING → COMPLETED → ACCEPTING (atomic).
    ///         Increments currentCycleNumber. Updates cycle start timestamp.
    ///
    ///         Completing the FINAL cycle also moves the product SETTLING → MATURING in the same
    ///         transaction. That is SETTLING's only exit, so the final cycle can never be
    ///         skipped and its price can never be superseded.
    ///
    ///         Completing an ORDINARY cycle at or after params.maturityTimestamp does not
    ///         promote it: the product moves OPERATING → SETTLING and opens a fresh final cycle
    ///         instead, because a pre-maturity snapshot prices positions that have not yet been
    ///         recovered.
    /// @dev    Access: that vault's own bound Settlement contract only.
    function completeCycle(address vault) external;

    /// @notice Whether this vault's FINAL cycle is currently running (product SETTLING, cycle
    ///         CALCULATING). Settlement uses it to apply the final batch's extra restrictions.
    function isFinalCycle(address vault) external view returns (bool);

    // -----------------------------------------------------------------------
    // Pause layer
    // -----------------------------------------------------------------------

    /// @notice Pause a vault. Access: that vault's own Guardian.
    function pause(address vault, PauseState reason) external;

    /// @notice Lift a vault pause. Access: that vault's own Owner.
    function unpause(address vault) external;

    // -----------------------------------------------------------------------
    // Module-level pause (kept for NAVOracle compat)
    // -----------------------------------------------------------------------

    function pauseModule(ModuleId id) external;
    function unpauseModule(ModuleId id) external;
    function modulePaused(ModuleId id) external view returns (bool);
    function requireModuleActive(ModuleId id) external view;

    // -----------------------------------------------------------------------
    // Gate views (called by Vault contracts; revert on mismatch)
    // -----------------------------------------------------------------------

    /// @notice Revert unless vault can accept a new subscription:
    ///         (SUBSCRIBING || (OPERATING + ACCEPTING)) && ACTIVE.
    function requireSubscribable(address vault) external view;

    /// @notice Revert unless OPERATING + ACCEPTING + ACTIVE.  Used for requestRedeem.
    function requireOperable(address vault) external view;

    /// @notice Revert unless cycle state == expected.
    function requireCycleState(address vault, CycleState expected) external view;

    /// @notice Revert unless pause == ACTIVE.
    function requireActive(address vault) external view;

    // -----------------------------------------------------------------------
    // Getters
    // -----------------------------------------------------------------------

    function getState(address vault) external view returns (StateContext memory);
    function getParams(address vault) external view returns (ProductParams memory);
    function isVaultRegistered(address vault) external view returns (bool);
    /// @dev Alias kept for backward compat with Queue / UnifiedPool / ReservePSM.
    function registeredVaults(address vault) external view returns (bool);
    function totalSubscribed(address vault) external view returns (uint256);
    function subscribedByWallet(address vault, address wallet) external view returns (uint256);
    function currentCycleNumber(address vault) external view returns (uint256);
    function currentCycleStart(address vault) external view returns (uint256);
    function getProductState(address vault) external view returns (ProductState);
    function getCycleState(address vault) external view returns (CycleState);
    function getPauseState(address vault) external view returns (PauseState);
    function accessControl() external view returns (address);

    /// @notice The one VaultFactory allowed to register vaults. Each Vault reads this to gate
    ///         its own one-shot `bindGovernance`.
    function vaultFactory() external view returns (address);

    // -----------------------------------------------------------------------
    // Vault index
    // -----------------------------------------------------------------------
    // `registeredVaults` answers "is this address a vault?"; the functions below answer
    // "what are all the vaults?", so any integrator can enumerate them with eth_call alone
    // instead of replaying VaultRegistered logs. Append-only and in registration order —
    // a vault's index never moves.

    /// @notice Number of vaults ever registered.
    function vaultCount() external view returns (uint256);

    /// @notice Vault at `index` in registration order. Reverts past the end.
    function vaultAt(uint256 index) external view returns (address);

    /// @notice Up to `limit` vaults starting at `offset`, in registration order.
    /// @dev    Clamped, not checked: an offset at or past the end yields an empty array and an
    ///         overlong limit yields a short page, so a caller can page without reading
    ///         `vaultCount` first.
    function vaultsPaged(uint256 offset, uint256 limit) external view returns (address[] memory);

    /// @notice Within the `[offset, offset+limit)` window, the vaults on which `account` holds
    ///         at least one vault-local role, each with a bitmask of which roles.
    /// @dev    Bit `1 << uint8(VaultRole.X)` is set when `account` holds role X. Vaults where
    ///         the account holds nothing are omitted, so both returned arrays are the same
    ///         length and shorter than the window. `account == address(0)` always yields empty.
    ///         View-only and unbounded per vault (five IVaultRoles calls) — page it.
    function vaultsWithRole(address account, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory vaults, uint8[] memory roleMasks);
}
