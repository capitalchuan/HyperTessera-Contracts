// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IStateManager} from "../interfaces/IStateManager.sol";
import {IHyperAccessControl} from "../interfaces/IHyperAccessControl.sol";
import {IVaultRoles} from "../interfaces/IVaultRoles.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {
    ProductState,
    CycleState,
    PauseState,
    StateContext,
    ProductParams,
    ModuleId,
    VaultRole
} from "../libs/Types.sol";

/// @title StateManager
/// @notice Three-layer (Product × Cycle × Pause) state machine for HyperTessera vaults.
contract StateManager is IStateManager {
    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    mapping(address vault => StateContext) private _states;
    mapping(address vault => ProductParams) private _params;
    mapping(address vault => uint256) private _totalSubscribed;
    mapping(address vault => mapping(address => uint256)) private _subscribedByWallet;
    mapping(address vault => bool) private _registered;
    mapping(address vault => uint256) private _cycleStart;
    /// @dev True while this vault's FINAL cycle is running, i.e. for the whole of
    ///      SETTLING/CALCULATING. Set atomically with the move into SETTLING and cleared by the
    ///      final `completeCycle` as it moves the product to MATURING, so it is exactly the
    ///      window in which a final settlement batch may execute.
    mapping(address vault => bool) private _finalCycleActive;

    /// @dev Set by `setProductParams`. `openSubscription` requires it, so a Curator who never
    ///      configured the product cannot open a raise against an all-zero parameter set.
    mapping(address vault => bool) private _paramsSet;
    mapping(ModuleId => bool) private _modulePaused;

    /// @dev Enumerable counterpart to `_registered`. The mapping answers "is this a vault?";
    ///      this answers "what are all the vaults?" — so a third party can list every vault
    ///      with eth_call alone, the same guarantee AssetRegistry gives for assets via
    ///      nextAssetId/getAsset. Append-only: registration is the only writer and vaults are
    ///      never unregistered, so an index, once assigned, is stable forever.
    address[] private _vaultList;

    address public accessControl;

    /// @notice Official VaultFactory allowed to call registerVault; set once by GOVERNOR_ROLE.
    address public vaultFactory;

    // -----------------------------------------------------------------------
    // Role constant (read from HyperAccessControl)
    // -----------------------------------------------------------------------

    bytes32 private immutable GOVERNOR_ROLE;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address accessControl_) {
        if (accessControl_ == address(0)) revert ZeroAddress();
        accessControl = accessControl_;
        GOVERNOR_ROLE = IHyperAccessControl(accessControl_).GOVERNOR_ROLE();
    }

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyGovernor() {
        if (!IHyperAccessControl(accessControl).hasRole(GOVERNOR_ROLE, msg.sender)) revert NotGovernor();
        _;
    }

    modifier onlyVaultKeeper(address vault) {
        if (!IVaultRoles(vault).isKeeper(msg.sender)) revert NotKeeper();
        _;
    }

    modifier onlyVaultSettlement(address vault) {
        if (msg.sender != IBaseVault(vault).settlement()) revert NotSettlement();
        _;
    }

    modifier onlyRegistered(address vault) {
        if (!_registered[vault]) revert VaultNotRegistered(vault);
        _;
    }

    // -----------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------

    /// @inheritdoc IStateManager
    function setVaultFactory(address factory) external onlyGovernor {
        if (vaultFactory != address(0)) revert VaultFactoryAlreadySet();
        if (factory == address(0)) revert ZeroAddress();
        vaultFactory = factory;
    }

    /// @dev The initial state is fixed here rather than taken from the factory's calldata. The
    ///      "single-direction from CONFIGURING" invariant — and the several call sites that
    ///      implicitly depend on `cycle == ACCEPTING` during SUBSCRIBING (cancelRequest, above
    ///      all) — must not be defeatable by a caller passing something else.
    function registerVault(address vault) external {
        if (msg.sender != vaultFactory) revert NotVaultFactory();
        if (vault == address(0)) revert ZeroAddress();
        if (_registered[vault]) revert VaultAlreadyRegistered(vault);

        _registered[vault] = true;
        _vaultList.push(vault);
        _states[vault] = StateContext({
            product: ProductState.CONFIGURING,
            cycle: CycleState.ACCEPTING,
            pause: PauseState.ACTIVE,
            currentCycleNumber: 0
        });
        _cycleStart[vault] = block.timestamp;

        emit VaultRegistered(vault, ProductState.CONFIGURING, CycleState.ACCEPTING, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Product params
    // -----------------------------------------------------------------------

    function setProductParams(address vault, ProductParams calldata params) external onlyRegistered(vault) {
        if (IVaultRoles(vault).curator() != msg.sender) revert Unauthorized();
        if (_states[vault].product != ProductState.CONFIGURING) {
            revert WrongProductState(ProductState.CONFIGURING, _states[vault].product);
        }
        _validateParams(params);

        _params[vault] = params;
        _paramsSet[vault] = true;

        // The vault, not this contract, is the authority on the live subscription cap — settle()
        // reads its own `subscriptionCapShare`. Curator sets the initial value here, in one
        // transaction with the rest of the product parameters, and this pushes it across; any
        // later change goes through that vault's VaultTimelock instead.
        IBaseVault(vault).initSubscriptionCapShare(params.subscriptionCapShare);

        emit ProductParamsSet(vault, block.timestamp);
    }

    /// @dev Rejects any ordering that would make the lifecycle unreachable. "Never configured at
    ///      all" is caught by `_paramsSet` in `openSubscription` rather than here, so
    ///      `subscriptionStart == 0` stays legal — it means "open as soon as the Keeper calls".
    ///      `walletSubscriptionCap`, `subscriptionCapShare`, `minRaiseAmount` and `feeParams` are
    ///      likewise legitimately 0 (uncapped / no minimum).
    function _validateParams(ProductParams calldata p) internal pure {
        if (p.subscriptionEnd <= p.subscriptionStart) revert InvalidProductParams("subscriptionEnd");
        if (p.cycleDuration == 0) revert InvalidProductParams("cycleDuration");
        if (p.maturityTimestamp < p.subscriptionEnd) revert InvalidProductParams("maturityTimestamp");
        if (p.claimingStart < p.maturityTimestamp) revert InvalidProductParams("claimingStart");
        if (p.claimingEnd < p.claimingStart) revert InvalidProductParams("claimingEnd");
    }

    // -----------------------------------------------------------------------
    // Subscription tracking
    // -----------------------------------------------------------------------

    /// @dev WHAT `_totalSubscribed` / `_subscribedByWallet` MEAN, and for how long.
    ///
    ///      They are a **subscription-window declaration tally**, not a record of principal
    ///      actually subscribed. Three properties follow, and they are deliberate:
    ///
    ///      1. Only requests submitted while `ProductState.SUBSCRIBING` are counted. An
    ///         OPERATING-phase deposit does not add, and — symmetrically — an OPERATING-phase
    ///         cancel does not subtract (see `releaseSubscription`). The asymmetry that used to
    ///         exist here let a later cancel reach back and shrink a historical raise figure.
    ///      2. The value is **frozen** once the raise closes. `finalizeSubscription` is the last
    ///         moment either mapping can move, so `totalSubscribed(vault)` keeps reporting what
    ///         was declared during the window for the rest of the product's life.
    ///      3. It is not reconciled against settlement. A partially-filled request mints shares
    ///         for the accepted amount and refunds the rest without adjusting these totals, so
    ///         the tally can exceed the principal that actually entered the vault. Anything
    ///         needing real subscribed principal must read the vault, not this.
    ///
    ///      Its one on-chain consumer is `finalizeSubscription`'s `minRaiseAmount` decision.
    ///
    ///      Capacity is not enforced here either. It is enforced at settlement, in share terms,
    ///      against the vault's `subscriptionCapShare`. Queueing during SUBSCRIBING is therefore
    ///      unbounded by design: settle() sizes each request and refunds whatever it cannot
    ///      accept, and a user may withdraw beforehand via cancelRequest (reachable because
    ///      CycleState.ACCEPTING is enum 0 and s.cycle is never written during SUBSCRIBING).
    ///      walletSubscriptionCap likewise gates only the initial raise window: recurring
    ///      per-cycle deposits during OPERATING+ACCEPTING are not subject to it, since
    ///      _subscribedByWallet is never decremented on settlement and would otherwise
    ///      permanently lock out deposits after the cap is first hit.
    function recordSubscription(address vault, address wallet, uint256 amount) external onlyRegistered(vault) {
        if (msg.sender != vault) revert Unauthorized();
        if (_states[vault].product != ProductState.SUBSCRIBING) return;

        ProductParams storage p = _params[vault];
        uint256 newTotal = _totalSubscribed[vault] + amount;
        uint256 newWallet = _subscribedByWallet[vault][wallet] + amount;
        if (p.walletSubscriptionCap > 0 && newWallet > p.walletSubscriptionCap) {
            revert WalletCapExceeded(wallet, p.walletSubscriptionCap, newWallet);
        }
        _totalSubscribed[vault] = newTotal;
        _subscribedByWallet[vault][wallet] = newWallet;
    }

    function releaseSubscription(address vault, address wallet, uint256 amount) external onlyRegistered(vault) {
        if (msg.sender != vault) revert Unauthorized();
        // Symmetric with recordSubscription's gate. The ledger only ever accrues during
        // SUBSCRIBING, so releasing outside it (an OPERATING-phase cancel) would subtract an
        // amount that was never added and drive the raise tally below its true total.
        if (_states[vault].product != ProductState.SUBSCRIBING) return;

        uint256 totalSub = _totalSubscribed[vault];
        uint256 walletSub = _subscribedByWallet[vault][wallet];
        _totalSubscribed[vault] = totalSub > amount ? totalSub - amount : 0;
        _subscribedByWallet[vault][wallet] = walletSub > amount ? walletSub - amount : 0;
    }

    // -----------------------------------------------------------------------
    // Lifecycle — Keeper / Curator
    // -----------------------------------------------------------------------

    function openSubscription(address vault) external onlyVaultKeeper(vault) onlyRegistered(vault) {
        StateContext storage s = _states[vault];
        if (s.product != ProductState.CONFIGURING) {
            revert InvalidStateTransition(s.product, ProductState.SUBSCRIBING);
        }
        if (!_paramsSet[vault]) revert ConditionNotMet("product params not set");
        ProductParams storage p = _params[vault];
        if (block.timestamp < p.subscriptionStart) {
            revert ConditionNotMet("subscriptionStart not reached");
        }
        emit ProductStateChanged(vault, s.product, ProductState.SUBSCRIBING, block.timestamp);
        s.product = ProductState.SUBSCRIBING;
    }

    function finalizeSubscription(address vault) external onlyVaultKeeper(vault) onlyRegistered(vault) {
        StateContext storage s = _states[vault];
        if (s.product != ProductState.SUBSCRIBING) {
            revert WrongProductState(ProductState.SUBSCRIBING, s.product);
        }
        ProductParams storage p = _params[vault];
        if (block.timestamp < p.subscriptionEnd) {
            revert ConditionNotMet("subscriptionEnd not reached");
        }

        ProductState next;
        if (_totalSubscribed[vault] >= p.minRaiseAmount) {
            next = ProductState.OPERATING;
            _cycleStart[vault] = block.timestamp;

            // Cycle 0 initial-settlement phase: go straight to CALCULATING instead of opening
            // an ACCEPTING window first. This closes new subscribe/redeem requests immediately
            // and lets Settlement run its normal snapshotSettlementPrice/settle/completeCycle
            // flow right away against cycle 0 — settling every SUBSCRIBING-phase deposit at the
            // standard zero-supply 1 USDT : 1 share price — instead of making the initial
            // subscribers wait out a full cycleDuration before they see shares.
            if (s.cycle != CycleState.CALCULATING) {
                emit CycleStateChanged(vault, s.cycle, CycleState.CALCULATING, s.currentCycleNumber, block.timestamp);
                s.cycle = CycleState.CALCULATING;
            }
        } else {
            next = ProductState.FUNDING_FAILED;
        }
        emit ProductStateChanged(vault, ProductState.SUBSCRIBING, next, block.timestamp);
        s.product = next;
    }

    function startCycleCalculation(address vault) external onlyVaultKeeper(vault) onlyRegistered(vault) {
        StateContext storage s = _states[vault];
        if (s.product != ProductState.OPERATING) {
            revert WrongProductState(ProductState.OPERATING, s.product);
        }
        if (s.cycle != CycleState.ACCEPTING) {
            revert WrongCycleState(CycleState.ACCEPTING, s.cycle);
        }
        ProductParams storage p = _params[vault];
        // Two independent triggers. A normal cycle waits out `cycleDuration` from the previous
        // cycle's actual completion; the FINAL cycle is triggered by `maturityTimestamp` alone.
        // Keeping them separate is the whole point: cycle 0's initial settlement completes at
        // some arbitrary point after subscriptionEnd, so every later cycle boundary is offset by
        // that delay, and a one-year product whose cycleDuration is also one year would otherwise
        // reach maturity with its last cycle not yet due — and skip its final settlement entirely.
        bool maturityDue = block.timestamp >= p.maturityTimestamp;
        if (!maturityDue && block.timestamp < _cycleStart[vault] + p.cycleDuration) {
            revert ConditionNotMet("cycleDuration not elapsed");
        }

        emit CycleStateChanged(
            vault, CycleState.ACCEPTING, CycleState.CALCULATING, s.currentCycleNumber, block.timestamp
        );
        s.cycle = CycleState.CALCULATING;

        // Past maturity the product stops being an operating product in the same transaction that
        // freezes its queues. Running the final cycle from SETTLING/CALCULATING — rather than
        // finishing it in OPERATING and only then moving — means there is never a moment where
        // the product reads OPERATING with no cycle to execute, or where a cycle is running while
        // the product still admits new business.
        if (maturityDue) _beginFinalCycle(s, vault);
    }

    /// @dev OPERATING → SETTLING with the current cycle flagged final. Always called in the same
    ///      transaction as the cycle's own move into CALCULATING.
    function _beginFinalCycle(StateContext storage s, address vault) internal {
        emit ProductStateChanged(vault, s.product, ProductState.SETTLING, block.timestamp);
        s.product = ProductState.SETTLING;
        _finalCycleActive[vault] = true;
    }

    function enterClaiming(address vault) external onlyVaultKeeper(vault) onlyRegistered(vault) {
        StateContext storage s = _states[vault];
        if (s.product != ProductState.MATURING) {
            revert InvalidStateTransition(s.product, ProductState.CLAIMING);
        }
        ProductParams storage p = _params[vault];
        if (block.timestamp < p.claimingStart) {
            revert ConditionNotMet("claimingStart not reached");
        }
        emit ProductStateChanged(vault, ProductState.MATURING, ProductState.CLAIMING, block.timestamp);
        s.product = ProductState.CLAIMING;
    }

    function closeProduct(address vault) external onlyVaultKeeper(vault) onlyRegistered(vault) {
        StateContext storage s = _states[vault];
        if (s.product != ProductState.CLAIMING) {
            revert InvalidStateTransition(s.product, ProductState.CLOSED);
        }
        ProductParams storage p = _params[vault];
        if (block.timestamp < p.claimingEnd) {
            revert ConditionNotMet("claimingEnd not reached");
        }
        emit ProductStateChanged(vault, ProductState.CLAIMING, ProductState.CLOSED, block.timestamp);
        s.product = ProductState.CLOSED;
    }

    // -----------------------------------------------------------------------
    // Lifecycle — Settlement (atomic cycle completion)
    // -----------------------------------------------------------------------

    function completeCycle(address vault) external onlyVaultSettlement(vault) onlyRegistered(vault) {
        StateContext storage s = _states[vault];
        if (s.cycle != CycleState.CALCULATING) {
            revert InvalidCycleTransition(s.cycle, CycleState.FULFILLING);
        }
        uint256 cn = s.currentCycleNumber;

        // CALCULATING → FULFILLING → COMPLETED → ACCEPTING (atomic)
        emit CycleStateChanged(vault, CycleState.CALCULATING, CycleState.FULFILLING, cn, block.timestamp);
        emit CycleStateChanged(vault, CycleState.FULFILLING, CycleState.COMPLETED, cn, block.timestamp);

        s.currentCycleNumber = cn + 1;
        _cycleStart[vault] = block.timestamp;

        emit CycleStateChanged(vault, CycleState.COMPLETED, CycleState.ACCEPTING, cn + 1, block.timestamp);
        s.cycle = CycleState.ACCEPTING;

        if (_finalCycleActive[vault]) {
            // This was the final cycle. Its price is now frozen and the product moves to MATURING
            // in the same transaction — SETTLING has exactly one legal exit, and it runs through
            // a completed final cycle. ACCEPTING here is just the resting cycle state: no new
            // cycle can start, because startCycleCalculation requires OPERATING.
            _finalCycleActive[vault] = false;
            emit ProductStateChanged(vault, ProductState.SETTLING, ProductState.MATURING, block.timestamp);
            s.product = ProductState.MATURING;
            return;
        }

        // An ordinary cycle that happens to finish at or after maturity is NOT promoted to final.
        // It was started before maturity, so it priced the vault while positions were still
        // outstanding — using that snapshot as the final one would lock in book value instead of
        // what was actually recovered, and would retroactively repurpose a batch its signers
        // approved as a routine cycle. Instead the product moves straight into SETTLING and opens
        // a fresh final cycle, which prices only after the assets are actually back.
        if (s.product == ProductState.OPERATING && block.timestamp >= _params[vault].maturityTimestamp) {
            _beginFinalCycle(s, vault);
            emit CycleStateChanged(vault, CycleState.ACCEPTING, CycleState.CALCULATING, cn + 1, block.timestamp);
            s.cycle = CycleState.CALCULATING;
        }
    }

    /// @inheritdoc IStateManager
    function isFinalCycle(address vault) external view returns (bool) {
        return _finalCycleActive[vault];
    }

    // -----------------------------------------------------------------------
    // Pause layer
    // -----------------------------------------------------------------------

    function pause(address vault, PauseState reason) external onlyRegistered(vault) {
        if (reason == PauseState.ACTIVE) revert InvalidPauseReason();
        if (IVaultRoles(vault).guardian() != msg.sender) revert NotGuardian();

        StateContext storage s = _states[vault];
        if (s.pause != PauseState.ACTIVE) revert AlreadyPaused(vault);

        emit VaultPauseSet(vault, reason, msg.sender, block.timestamp);
        s.pause = reason;
    }

    function unpause(address vault) external onlyRegistered(vault) {
        if (IVaultRoles(vault).owner() != msg.sender) revert Unauthorized();
        StateContext storage s = _states[vault];
        if (s.pause == PauseState.ACTIVE) revert NotPaused(vault);
        PauseState prev = s.pause;
        s.pause = PauseState.ACTIVE;
        emit VaultUnpaused(vault, prev, msg.sender, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Module-level pause
    // -----------------------------------------------------------------------

    function pauseModule(ModuleId id) external onlyGovernor {
        _modulePaused[id] = true;
        emit ModulePaused(id, msg.sender, block.timestamp);
    }

    function unpauseModule(ModuleId id) external onlyGovernor {
        _modulePaused[id] = false;
        emit ModuleUnpaused(id, msg.sender, block.timestamp);
    }

    function modulePaused(ModuleId id) external view returns (bool) {
        return _modulePaused[id];
    }

    function requireModuleActive(ModuleId id) external view {
        if (_modulePaused[id]) revert ModuleIsPaused(id);
    }

    // -----------------------------------------------------------------------
    // Gate views
    // -----------------------------------------------------------------------

    function requireSubscribable(address vault) external view onlyRegistered(vault) {
        StateContext storage s = _states[vault];
        if (s.pause != PauseState.ACTIVE) revert VaultPausedError(vault, s.pause);

        bool ok = (s.product == ProductState.SUBSCRIBING)
            || (s.product == ProductState.OPERATING && s.cycle == CycleState.ACCEPTING);
        if (!ok) {
            revert WrongProductState(ProductState.SUBSCRIBING, s.product);
        }
    }

    /// @dev OPERATING/ACCEPTING only. SETTLING used to pass here, which let `requestRedeem`
    ///      keep queueing shares after the maturity cutoff even though no further settlement
    ///      cycle could ever run to fill them. The cutoff is now `completeCycle`'s atomic
    ///      OPERATING → SETTLING step at the end of the final cycle.
    function requireOperable(address vault) external view onlyRegistered(vault) {
        StateContext storage s = _states[vault];
        if (s.pause != PauseState.ACTIVE) revert VaultPausedError(vault, s.pause);
        if (s.product != ProductState.OPERATING) {
            revert WrongProductState(ProductState.OPERATING, s.product);
        }
        if (s.cycle != CycleState.ACCEPTING) {
            revert WrongCycleState(CycleState.ACCEPTING, s.cycle);
        }
    }

    function requireCycleState(address vault, CycleState expected) external view onlyRegistered(vault) {
        CycleState actual = _states[vault].cycle;
        if (actual != expected) revert CycleStateMismatch(vault, expected, actual);
    }

    function requireActive(address vault) external view onlyRegistered(vault) {
        PauseState ps = _states[vault].pause;
        if (ps != PauseState.ACTIVE) revert VaultPausedError(vault, ps);
    }

    // -----------------------------------------------------------------------
    // Getters
    // -----------------------------------------------------------------------

    function getState(address vault) external view returns (StateContext memory) {
        return _states[vault];
    }

    function getParams(address vault) external view returns (ProductParams memory) {
        return _params[vault];
    }

    function isVaultRegistered(address vault) external view returns (bool) {
        return _registered[vault];
    }

    function registeredVaults(address vault) external view returns (bool) {
        return _registered[vault];
    }

    function totalSubscribed(address vault) external view returns (uint256) {
        return _totalSubscribed[vault];
    }

    function subscribedByWallet(address vault, address wallet) external view returns (uint256) {
        return _subscribedByWallet[vault][wallet];
    }

    function currentCycleNumber(address vault) external view returns (uint256) {
        return _states[vault].currentCycleNumber;
    }

    function currentCycleStart(address vault) external view returns (uint256) {
        return _cycleStart[vault];
    }

    function getProductState(address vault) external view returns (ProductState) {
        return _states[vault].product;
    }

    function getCycleState(address vault) external view returns (CycleState) {
        return _states[vault].cycle;
    }

    function getPauseState(address vault) external view returns (PauseState) {
        return _states[vault].pause;
    }

    // -----------------------------------------------------------------------
    // Vault index
    // -----------------------------------------------------------------------

    /// @inheritdoc IStateManager
    function vaultCount() external view returns (uint256) {
        return _vaultList.length;
    }

    /// @inheritdoc IStateManager
    function vaultAt(uint256 index) external view returns (address) {
        return _vaultList[index];
    }

    /// @inheritdoc IStateManager
    function vaultsPaged(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _vaultsPaged(offset, limit);
    }

    /// @inheritdoc IStateManager
    function vaultsWithRole(address account, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory vaults, uint8[] memory roleMasks)
    {
        address[] memory window = _vaultsPaged(offset, limit);
        uint8[] memory masks = new uint8[](window.length);

        // Compact the hits into the head of `window` as we scan. `hits` never overtakes the
        // read cursor, so the in-place rewrite is always behind us.
        uint256 hits;
        for (uint256 i; i < window.length; ++i) {
            uint8 mask = _roleMask(window[i], account);
            if (mask == 0) continue;
            window[hits] = window[i];
            masks[hits] = mask;
            ++hits;
        }

        vaults = new address[](hits);
        roleMasks = new uint8[](hits);
        for (uint256 i; i < hits; ++i) {
            vaults[i] = window[i];
            roleMasks[i] = masks[i];
        }
    }

    /// @dev Clamps `limit` against the remaining length instead of computing `offset + limit`,
    ///      so a caller paging blind with a huge limit gets a short page rather than an
    ///      arithmetic-overflow revert.
    function _vaultsPaged(uint256 offset, uint256 limit) internal view returns (address[] memory page) {
        uint256 len = _vaultList.length;
        if (offset >= len) return new address[](0);

        uint256 count = len - offset;
        if (limit < count) count = limit;

        page = new address[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _vaultList[offset + i];
        }
    }

    /// @dev address(0) is rejected up front: a disconnected front end passes it, and every
    ///      unset role slot on a vault reads as address(0), so matching it would report every
    ///      vault with no curator as "curated by 0x0".
    function _roleMask(address vault, address account) internal view returns (uint8 mask) {
        if (account == address(0)) return 0;

        IVaultRoles v = IVaultRoles(vault);
        if (v.owner() == account) mask |= uint8(1) << uint8(VaultRole.OWNER);
        if (v.curator() == account) mask |= uint8(1) << uint8(VaultRole.CURATOR);
        if (v.guardian() == account) mask |= uint8(1) << uint8(VaultRole.GUARDIAN);
        if (v.allocator() == account) mask |= uint8(1) << uint8(VaultRole.ALLOCATOR);
        if (v.isKeeper(account)) mask |= uint8(1) << uint8(VaultRole.KEEPER);
    }
}
