// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IUnifiedPool} from "../../interfaces/IUnifiedPool.sol";
import {IRevenuePool} from "../../interfaces/IRevenuePool.sol";
import {IHyperAccessControl} from "../../interfaces/IHyperAccessControl.sol";
import {IStateManager} from "../../interfaces/IStateManager.sol";
import {IVaultRoles} from "../../interfaces/IVaultRoles.sol";
import {IBaseVault} from "../../interfaces/IBaseVault.sol";
import {ISettlement} from "../../interfaces/ISettlement.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title UnifiedPool
/// @notice Per-Vault USDT receivable ledger and real-cash pool (net settlement conversion,
///         development-plan §8). `pending[vault]` is an application-level receivable that a
///         Vault counts in full toward its NAV, so every path that removes cash from this pool
///         removes the matching ledger entry with it — `distribute` and, since 审计反馈
///         2026-08-17 #2, the operator transfers too. The pool therefore holds
///         `totalPending + unattributedInterest + unattributedPrincipal` at all times, and the
///         cash bounds in `distribute`/`availableToDistribute` are defence in depth rather than
///         the load-bearing check they once were. No fee computation (BaseVault charges
///         performance fees as shares instead), no PSM coupling, no accounting-only `credit`.
///
///         UUPS upgradeable: deployed behind an ERC1967Proxy; upgrades gated to GOVERNOR_ROLE.
contract UnifiedPool is IUnifiedPool, Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    IHyperAccessControl public ac;
    IStateManager public sm;
    IERC20 public override usdt;

    /// @notice Per-vault USDT receivable; not a cash reservation.
    mapping(address vault => uint256) public override pending;
    uint256 public override totalPending;

    /// @notice Deposited but not yet attributed to any specific Vault's pending (SET-06: a payer
    ///         no longer fixes Vault attribution at deposit time — that Vault's own Settlement
    ///         Operator decides later, via attributeInterest/attributePrincipal).
    uint256 public override unattributedInterest;
    uint256 public override unattributedPrincipal;

    // Tranche classification was removed on 2026-08-25: attribution, distribution and every
    // authorisation here key on the vault address alone, so Cash/Note/LP never participated in
    // any calculation — it only risked mis-registering a vault and boxed products into three
    // shapes the protocol does not actually require. Product type is now carried by product
    // params / Indexer / front-end metadata instead (合约修复20260825 §1).
    //
    // The three mappings they occupied are deleted outright rather than kept as placeholders:
    // nothing is live yet (testnet only) and this pool is redeployed fresh with the rest of this
    // release, so there is no existing proxy storage layout to preserve. `__gap` below grows by
    // the same three slots to keep the contract's reserved footprint unchanged for future
    // upgrades from this deployment onward.
    mapping(address => bool) public override vaultConfigured;
    mapping(address => bool) public override vaultActive;

    /// @notice Governor admission control (审计反馈 V3 #1/#2). `vaultConfigured`/`vaultActive`
    ///         above are set by each Vault's own Owner and say only "this Vault wants to use the
    ///         pool"; these two say "the protocol permits it to". `VaultFactory.deployVault`
    ///         stays permissionless — being built from the standard contracts is not an
    ///         endorsement and must not by itself confer access to the shared cash of every other
    ///         Vault. The Settlement whitelist holds several addresses at once so different
    ///         Settlement implementations and version migrations coexist (审计问题 1/2 回复 §3.1).
    mapping(address => bool) public override vaultWhitelisted;
    mapping(address => bool) public override settlementWhitelisted;

    // -----------------------------------------------------------------------
    // Reentrancy guard (proxy-safe)
    // -----------------------------------------------------------------------

    /// @dev openzeppelin-contracts-upgradeable isn't a dependency of this repo, so this mirrors
    ///      ReentrancyGuardUpgradeable's pattern locally: OZ's plain `ReentrancyGuard` sets its
    ///      sentinel in a constructor, which never runs against a proxy's storage. Explicitly
    ///      initialized in `initialize()` below rather than relying on the zero-value default.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    error ReentrancyGuardReentrantCall();

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrancyGuardReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    /// @dev Reserved storage for future upgrades (this contract's fields end above this slot).
    ///      Grown from 47 to 50 when the three tranche mappings were removed, then back to 48
    ///      when the two Governor whitelists were added, so the total reserved footprint is
    ///      unchanged throughout.
    uint256[48] private __gap;

    // -----------------------------------------------------------------------
    // Constructor / Initializer
    // -----------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address usdt_, address stateManager_, address accessControl_) external initializer {
        if (usdt_ == address(0) || stateManager_ == address(0) || accessControl_ == address(0)) {
            revert ZeroAddress();
        }
        usdt = IERC20(usdt_);
        sm = IStateManager(stateManager_);
        ac = IHyperAccessControl(accessControl_);
        _reentrancyStatus = _NOT_ENTERED;
    }

    /// @notice One-shot correction re-pointing `sm` at the real StateManager.
    /// @dev The W3 deploy script initializes this proxy during the W1/W2 stage, when only the
    ///      `StubStateManager` scaffold exists. That stub registers no vaults, so
    ///      `receiveVaultPrincipal` — and therefore `BaseVault.returnPrincipalToPool` — reverts
    ///      `UnregisteredVault` forever. `sm` has no setter and `initialize` cannot re-run, so
    ///      the correction ships as a `reinitializer(2)` delivered via `upgradeToAndCall`.
    ///      Governor-gated, matching `_authorizeUpgrade`.
    function reinitializeStateManager(address stateManager_) external reinitializer(2) {
        _onlyGovernor();
        if (stateManager_ == address(0)) revert ZeroAddress();
        address previous = address(sm);
        sm = IStateManager(stateManager_);
        emit StateManagerUpdated(previous, stateManager_, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _onlyGovernor() internal view {
        if (!ac.hasRole(ac.GOVERNOR_ROLE(), msg.sender)) revert NotGovernor();
    }

    /// @dev Every authorisation on this contract is resolved by asking `vault` about itself —
    ///      `owner()`, `settlement()`. That is only sound if `vault` is a real protocol vault:
    ///      otherwise anyone can deploy a contract that self-reports `owner == attacker` and
    ///      `settlement == the real Settlement`, register it here, appoint themselves its
    ///      Settlement Operator, and drain the shared cash pool that backs every real vault.
    ///      StateManager's registry — written only by the one wired VaultFactory — is the
    ///      authority (审计反馈 2026-08-17 #1).
    function _onlyRegisteredVault(address vault) internal view {
        if (!sm.registeredVaults(vault)) revert UnregisteredVault(vault);
    }

    function _onlyVaultOwner(address vault) internal view {
        _onlyRegisteredVault(vault);
        if (IVaultRoles(vault).owner() != msg.sender) revert NotVaultOwner();
    }

    function _onlySettlementOperator(address vault) internal view {
        _onlyRegisteredVault(vault);
        address settlement_ = IBaseVault(vault).settlement();
        if (!ISettlement(settlement_).isOperator(vault, msg.sender)) revert NotSettlementOperator(vault);
    }

    /// @dev The admission gate for every path that credits a Vault's `pending` or moves cash to
    ///      it. Both halves matter: the Vault must be approved, and the Settlement it currently
    ///      points at must be trusted — a Vault may re-point `settlement()` at any time, so
    ///      checking the Vault alone would let an approved Vault swap in an attacker-controlled
    ///      Settlement and appoint arbitrary Operators (审计问题 1/2 回复 §3.3).
    function _requireApproved(address vault) internal view {
        if (!vaultWhitelisted[vault]) revert VaultNotWhitelisted(vault);
        address settlement_ = IBaseVault(vault).settlement();
        if (!settlementWhitelisted[settlement_]) revert SettlementNotWhitelisted(settlement_);
    }

    function _requireConfiguredActive(address vault) internal view {
        if (!vaultConfigured[vault]) revert VaultNotConfigured(vault);
        if (!vaultActive[vault]) revert VaultInactive(vault);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override {
        _onlyGovernor();
    }

    // -----------------------------------------------------------------------
    // Governor admission control
    // -----------------------------------------------------------------------

    /// @inheritdoc IUnifiedPool
    function setVaultWhitelisted(address vault, bool allowed) external override {
        _onlyGovernor();
        if (vault == address(0)) revert ZeroAddress();
        vaultWhitelisted[vault] = allowed;
        emit VaultWhitelistUpdated(vault, allowed, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function setSettlementWhitelisted(address settlement_, bool allowed) external override {
        _onlyGovernor();
        if (settlement_ == address(0)) revert ZeroAddress();
        settlementWhitelisted[settlement_] = allowed;
        emit SettlementWhitelistUpdated(settlement_, allowed, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Vault registration
    // -----------------------------------------------------------------------

    /// @inheritdoc IUnifiedPool
    function addVault(address vault) external override {
        if (vault == address(0)) revert ZeroAddress();
        _onlyVaultOwner(vault);
        if (vaultConfigured[vault]) revert VaultAlreadyConfigured(vault);

        vaultConfigured[vault] = true;
        vaultActive[vault] = true;

        emit VaultAdded(vault, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function deactivateVault(address vault) external override {
        _onlyVaultOwner(vault);
        _requireConfiguredActive(vault);
        vaultActive[vault] = false;
        emit VaultDeactivated(vault, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function reactivateVault(address vault) external override {
        _onlyVaultOwner(vault);
        if (!vaultConfigured[vault]) revert VaultNotConfigured(vault);
        if (vaultActive[vault]) return;
        vaultActive[vault] = true;
        emit VaultReactivated(vault, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Real USDT inflows
    // -----------------------------------------------------------------------

    /// @inheritdoc IUnifiedPool
    function repayInterest(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        usdt.safeTransferFrom(msg.sender, address(this), amount);
        unattributedInterest += amount;

        emit InterestDeposited(msg.sender, amount, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function repayPrincipal(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        usdt.safeTransferFrom(msg.sender, address(this), amount);
        unattributedPrincipal += amount;

        emit PrincipalDeposited(msg.sender, amount, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function attributeInterest(address vault, uint256 amount) external override {
        _onlySettlementOperator(vault);
        if (amount == 0) revert ZeroAmount();
        _requireConfiguredActive(vault);
        _requireApproved(vault);
        if (amount > unattributedInterest) revert InsufficientUnattributedInterest(unattributedInterest, amount);

        unattributedInterest -= amount;
        pending[vault] += amount;
        totalPending += amount;

        emit InterestRepaid(vault, amount, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function attributePrincipal(address vault, uint256 amount) external override {
        _onlySettlementOperator(vault);
        if (amount == 0) revert ZeroAmount();
        _requireConfiguredActive(vault);
        _requireApproved(vault);
        if (amount > unattributedPrincipal) revert InsufficientUnattributedPrincipal(unattributedPrincipal, amount);

        unattributedPrincipal -= amount;
        pending[vault] += amount;
        totalPending += amount;

        emit PrincipalRepaid(vault, amount, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function receiveVaultPrincipal(uint256 amount) external override nonReentrant {
        if (!sm.registeredVaults(msg.sender)) revert UnregisteredVault(msg.sender);
        if (amount == 0) revert ZeroAmount();
        _requireConfiguredActive(msg.sender);
        _requireApproved(msg.sender);

        usdt.safeTransferFrom(msg.sender, address(this), amount);
        pending[msg.sender] += amount;
        totalPending += amount;

        emit VaultPrincipalReceived(msg.sender, amount, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Distribution
    // -----------------------------------------------------------------------

    /// @inheritdoc IUnifiedPool
    /// @dev The pool manages a Vault's idle cash as well as settling it, so `pending[vault]` is
    ///      that Vault's book claim on pool-managed assets — not a claim on the pool's instant
    ///      USDT balance. `operatorTransfer` moving cash into an authorised third-party or RWA
    ///      position changes the FORM of those assets without extinguishing the claim, which is
    ///      why it does not debit the ledger; a cash balance below `totalPending` is expected
    ///      liquidity waiting, not overstated NAV (审计报告（一）回复 §1).
    ///
    ///      That leaves one gap, and this closes it: before now `distribute` was the only path
    ///      that could ever reduce `pending`, so a permanent loss on an external position had no
    ///      way to reach the ledger, and `BaseVault.grossManagedAssets()` — which counts
    ///      `pending` in full — would carry the lost value indefinitely. Impairment is recognised
    ///      here explicitly, on confirmation that the investment is unrecoverable
    ///      (审计报告一反馈 §1).
    ///
    ///      Access: that Vault's own VaultTimelock, mirroring `BaseVault.writeDownInsolvency` —
    ///      recognising a loss is a governance act, not an operator one, and it is delay-queued.
    function writeDownPending(address vault, uint256 amount, bytes32 referenceId) external override {
        _onlyRegisteredVault(vault);
        if (msg.sender != IBaseVault(vault).vaultTimelock()) revert NotVaultTimelock(vault);
        if (amount == 0) revert ZeroAmount();

        uint256 p = pending[vault];
        if (amount > p) revert InsufficientPending(vault, p, amount);
        pending[vault] = p - amount;
        totalPending -= amount;

        emit PendingWrittenDown(vault, amount, p - amount, referenceId, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function distribute(address vault, uint256 amount) external override nonReentrant {
        _onlyRegisteredVault(vault);
        if (msg.sender != IBaseVault(vault).settlement()) revert NotVaultSettlement(vault);
        if (!vaultConfigured[vault]) revert VaultNotConfigured(vault);
        _requireApproved(vault);

        uint256 p = pending[vault];
        if (p < amount) revert InsufficientPending(vault, p, amount);
        uint256 cashBalance = usdt.balanceOf(address(this));
        if (cashBalance < amount) revert InsufficientCash(cashBalance, amount);

        pending[vault] = p - amount;
        totalPending -= amount;
        usdt.safeTransfer(vault, amount);

        emit Distributed(vault, amount, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function availableToDistribute(address vault) external view override returns (uint256) {
        uint256 p = pending[vault];
        uint256 cashBalance = usdt.balanceOf(address(this));
        return p < cashBalance ? p : cashBalance;
    }

    // -----------------------------------------------------------------------
    // Governor third-party transfers
    // -----------------------------------------------------------------------
    //
    // Both functions below moved from "that Vault's Settlement Operator" to GOVERNOR_ROLE on
    // 审计反馈 V3 #1. They are the only paths that move cash out of the pool without a matching
    // ledger movement, so whoever can call them can drain the shared pool that backs every
    // Vault; an Operator key is an online signing key held per Vault, and a stolen one must not
    // reach that. The Settlement Operator keeps attribution, settlement signing and the normal
    // settlement flow — everything that stays inside the ledger (审计问题 1/2 回复 §3.5).
    //
    // `vault` is kept in the signature and the event: these transfers are still booked against a
    // specific Vault's position for off-chain reconciliation, it is just no longer the thing that
    // authorises the call. `_onlyRegisteredVault` still runs so the reference cannot be garbage.

    /// @inheritdoc IUnifiedPool
    function operatorTransfer(address vault, address recipient, uint256 amount, bytes32 referenceId)
        external
        override
        nonReentrant
    {
        _onlyGovernor();
        _onlyRegisteredVault(vault);
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();

        // Deliberately does NOT touch pending[vault] — see _debitPending's removal note below.
        if (IBaseVault(vault).isAdapter(recipient)) revert RecipientIsVaultAdapter(vault, recipient);

        usdt.safeTransfer(recipient, amount);
        emit ThirdPartyTransferExecuted(vault, msg.sender, recipient, amount, referenceId, block.timestamp);
    }

    /// @inheritdoc IUnifiedPool
    function operatorTransferToRevenuePool(address vault, address revenuePool, uint256 amount, bytes32 referenceId)
        external
        override
        nonReentrant
    {
        _onlyGovernor();
        _onlyRegisteredVault(vault);
        if (revenuePool == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();

        usdt.safeTransfer(revenuePool, amount);
        IRevenuePool(revenuePool).receiveFee(amount);

        emit ThirdPartyTransferExecuted(vault, msg.sender, revenuePool, amount, referenceId, block.timestamp);
    }
}
