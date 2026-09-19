// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HyperAccessControl} from "../src/governance/HyperAccessControl.sol";
import {VaultTimelock} from "../src/governance/VaultTimelock.sol";
import {StateManager} from "../src/asset-management/StateManager.sol";
import {EarnVault} from "../src/asset-management/vaults/EarnVault.sol";
import {BaseVault} from "../src/asset-management/vaults/BaseVault.sol";
import {Queue} from "../src/asset-management/settlement/Queue.sol";
import {IGate} from "../src/interfaces/IGate.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {IStateManager} from "../src/interfaces/IStateManager.sol";
import {IVaultTimelock} from "../src/interfaces/IVaultTimelock.sol";
import {IEarnVault} from "../src/interfaces/IEarnVault.sol";
import {IAdapter} from "../src/interfaces/IAdapter.sol";
import {IVaultRoles} from "../src/interfaces/IVaultRoles.sol";
import {FirstPeriodAdapter} from "../src/asset-management/adaptors/FirstPeriodAdapter.sol";
import {
    ProductState,
    CycleState,
    PauseState,
    ProductParams,
    ModuleId,
    QueueType,
    RequestSettlement,
    DepositRequestState,
    RedeemRequestState
} from "../src/libs/Types.sol";
import {UnifiedPool} from "../src/asset-management/settlement/UnifiedPool.sol";
import {ClaimRegistry} from "../src/asset-infrastructure/ClaimRegistry.sol";
import {IClaimRegistry} from "../src/interfaces/IClaimRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";

// ---------------------------------------------------------------------------
// Test-local helpers
// ---------------------------------------------------------------------------

contract MockUSDT is ERC20 {
    constructor() ERC20("MockUSDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BlockingGate is IGate {
    address public blocked;

    constructor(address _blocked) {
        blocked = _blocked;
    }

    function isAllowed(address account) external view returns (bool) {
        return account != blocked;
    }
}

contract AllowAllGate is IGate {
    function isAllowed(address) external pure returns (bool) {
        return true;
    }
}

/// @notice Minimal IUnifiedPool.pending() stand-in for grossManagedAssets() aggregation tests.
contract MockUnifiedPool {
    mapping(address => uint256) public pending;

    function setPending(address vault, uint256 amount) external {
        pending[vault] = amount;
    }
}

/// @notice Minimal ISettlement.isOperator(vault, account) stand-in for Settlement-Operator-gated
///         BaseVault functions (e.g. returnPrincipalToPool). setUp()'s `settlement` is a bare
///         makeAddr() EOA with no isOperator function, so tests that need a real Settlement
///         Operator check point the vault's settlement at one of these instead.
contract MockSettlementOperator {
    mapping(address => mapping(address => bool)) public isOperator;

    function setOperator(address vault_, address account, bool approved) external {
        isOperator[vault_][account] = approved;
    }
}

contract RevertingRealAssetsAdapter {
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function realAssets() external pure returns (uint256) {
        revert("malformed adapter");
    }
}

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------

contract EarnVaultTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    MockUSDT internal usdt;
    EarnVault internal vault;
    VaultTimelock internal tl;

    // `governor` is the HyperAccessControl protocol Governor (used only to wire
    // StateManager.setVaultFactory); it is also reused as this vault's Owner (IVaultRoles) for
    // test simplicity. `curator` is kept as a distinct address from `governor`/owner because
    // VaultTimelock.scheduleParamChange resolves the caller's ActionClass by checking
    // `== owner()` before `== curator()` — an address that is both would always resolve to
    // OWNER class and could never schedule a CURATOR-class action.
    address internal governor = makeAddr("governor");
    address internal curator = makeAddr("curator");
    address internal factory = makeAddr("factory");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal settlement = makeAddr("settlement");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    mapping(uint256 => uint256) internal _reqAssets; // requestId -> deposit's original assets
    mapping(uint256 => uint256) internal _reqShares; // requestId -> redeem's original shares

    uint256 internal constant NOW = 1_000_000;
    // Initial (and, absent any yield/fee, stable) price: 1e18 shares per 1_000_000 (6-dec) USDT.
    uint256 internal constant PRICE_ONE = 1_000_000;
    uint256 internal constant SHARE_SCALE = 1e18;

    function setUp() public {
        vm.warp(NOW);

        ac = new HyperAccessControl(governor);
        usdt = new MockUSDT();
        sm = new StateManager(address(ac));

        vm.prank(governor);
        sm.setVaultFactory(factory);

        queue = new Queue(address(sm));

        vault = new EarnVault(
            "HyperTessera Cash Earn",
            "htCASH",
            address(usdt),
            address(sm),
            address(queue),
            governor, // owner_ (was accessControl_ under the old global-role model)
            address(0) // liquidityBridge (none for this test)
        );

        tl = new VaultTimelock(address(vault));
        vm.prank(factory);
        vault.bindGovernance(address(tl));

        // Register vault, appoint vault-local roles, set params, open subscription
        vm.prank(factory);
        sm.registerVault(address(vault));

        vm.startPrank(governor);
        vault.setCurator(curator);
        vault.setGuardian(guardian);
        vault.setKeeper(keeper, true);
        vm.stopPrank();

        vm.prank(curator);
        sm.setProductParams(address(vault), _defaultParams());

        vm.prank(governor);
        vault.setSettlement(settlement);

        vm.prank(keeper);
        sm.openSubscription(address(vault));

        // Pre-mint USDT for alice and bob
        usdt.mint(alice, 100_000e6);
        usdt.mint(bob, 100_000e6);
    }

    /// @notice Schedules `data` against `vault` via VaultTimelock as `proposer` (must be
    ///         vault.owner() or vault.curator() matching the target selector's whitelisted
    ///         ActionClass), warps past the delay, and executes it.
    function _scheduleAndExecute(address proposer, bytes memory data) internal returns (bytes32 id) {
        vm.prank(proposer);
        id = tl.scheduleParamChange(address(vault), data);
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(id);
    }

    // -----------------------------------------------------------------------
    // requestDeposit
    // -----------------------------------------------------------------------

    function test_requestDeposit_transfersUSDT_createsRequest() public {
        uint256 assets = 1_000e6;
        vm.startPrank(alice);
        usdt.approve(address(vault), assets);
        uint256 rid = vault.requestDeposit(assets, alice);
        vm.stopPrank();

        assertEq(rid, 1);
        assertEq(usdt.balanceOf(address(vault)), assets);
        assertEq(usdt.balanceOf(alice), 100_000e6 - assets);
        assertEq(vault.pendingDepositLiability(), assets);
        assertEq(vault.pendingDepositByOwner(alice), assets);
    }

    function test_requestDeposit_emitsDepositRequested() public {
        uint256 assets = 1_000e6;
        vm.startPrank(alice);
        usdt.approve(address(vault), assets);
        vm.expectEmit(true, true, false, true);
        emit IBaseVault.DepositRequested(1, alice, assets, NOW);
        vault.requestDeposit(assets, alice);
        vm.stopPrank();
    }

    function test_requestDeposit_gate_addressZero_alwaysPasses() public {
        // gate is address(0) by default
        vm.startPrank(alice);
        usdt.approve(address(vault), 100e6);
        vault.requestDeposit(100e6, alice);
        vm.stopPrank();
    }

    function test_requestDeposit_gate_blocksOwner() public {
        BlockingGate g = new BlockingGate(alice);
        // Vault is already past CONFIGURING (setUp opened subscription), so setGate is now
        // Timelock-only — route through VaultTimelock instead of calling directly as Owner.
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setGate, (address(g))));

        vm.startPrank(alice);
        usdt.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.GateBlocked.selector, alice));
        vault.requestDeposit(100e6, alice);
        vm.stopPrank();
    }

    function test_requestDeposit_zero_assets_reverts() public {
        vm.startPrank(alice);
        usdt.approve(address(vault), 0);
        vm.expectRevert(IBaseVault.ZeroAssets.selector);
        vault.requestDeposit(0, alice);
        vm.stopPrank();
    }

    /// @dev The aggregate raise cap no longer exists at request time — capacity is enforced at
    ///      settlement in share terms (subscriptionCapShare), which can size a borderline order
    ///      down and refund the rest instead of rejecting it whole. This is the aggregate case,
    ///      not the per-wallet one: the per-wallet limit is deliberately kept out of the way here
    ///      by using distinct wallets, so nothing but the (removed) aggregate gate could reject.
    function test_requestDeposit_aboveOldTotalRaiseCap_isQueuedNotRejected() public {
        ProductParams memory p = _defaultParams();
        uint256 walletCap = p.walletSubscriptionCap; // 100_000e6
        uint256 oldTotalCap = 1_000_000e6; // the removed ProductParams.subscriptionCap
        uint256 wallets = oldTotalCap / walletCap; // 10 wallets exactly fill the old cap

        for (uint256 i = 0; i < wallets; i++) {
            address w = address(uint160(0xC0DE0000 + i));
            usdt.mint(w, walletCap);
            vm.startPrank(w);
            usdt.approve(address(vault), walletCap);
            vault.requestDeposit(walletCap, w);
            vm.stopPrank();
        }
        assertEq(sm.totalSubscribed(address(vault)), oldTotalCap);

        // One more USDT past the old cap. This used to revert SubscriptionCapExceeded.
        address extra = makeAddr("capExtra");
        usdt.mint(extra, 1e6);
        vm.startPrank(extra);
        usdt.approve(address(vault), 1e6);
        uint256 rid = vault.requestDeposit(1e6, extra);
        vm.stopPrank();

        // Accepted into the queue and left PENDING for settlement to size.
        IBaseVault.DepositRequest memory req = vault.getDepositRequest(rid);
        assertEq(uint8(req.state), uint8(DepositRequestState.PENDING));
        assertEq(req.owner, extra);
        assertEq(req.assets, 1e6);
        assertEq(sm.totalSubscribed(address(vault)), oldTotalCap + 1e6);
        assertEq(vault.pendingDepositLiability(), oldTotalCap + 1e6);
    }

    function test_requestDeposit_walletCap_reverts() public {
        vm.startPrank(alice);
        usdt.approve(address(vault), 100_000e6);
        vault.requestDeposit(100_000e6, alice); // hits wallet cap
        usdt.mint(alice, 1e6);
        usdt.approve(address(vault), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WalletCapExceeded.selector, alice, uint256(100_000e6), uint256(100_001e6)
            )
        );
        vault.requestDeposit(1e6, alice);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // claimDeposit
    // -----------------------------------------------------------------------

    function test_claimDeposit_before_settled_reverts() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.RequestNotSettled.selector, rid));
        vault.claimDeposit(rid, alice);
    }

    function test_claimDeposit_after_settled_transfers_shares() public {
        uint256 assets = 1_000e6;
        uint256 rid = _requestDeposit(alice, assets);

        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        vm.prank(alice);
        uint256 shares = vault.claimDeposit(rid, alice);
        assertEq(shares, _sharesFor(assets));
        assertEq(vault.balanceOf(alice), shares);
        // Alice's liability is released once her deposit is settled (before claim); the
        // funder2 deposit _advanceToCalculating() injects to meet minRaiseAmount is still
        // PENDING (not part of this settlement batch).
        assertEq(vault.pendingDepositLiability(), _defaultParams().minRaiseAmount);
    }

    function test_claimDeposit_emitsDepositClaimed() public {
        uint256 assets = 1_000e6;
        uint256 rid = _requestDeposit(alice, assets);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        uint256 expectedShares = _sharesFor(assets);
        vm.startPrank(alice);
        // checkData on: the share amount in the payload is part of the assertion, not decoration.
        vm.expectEmit(true, true, false, true, address(vault));
        emit IBaseVault.DepositClaimed(rid, alice, expectedShares, block.timestamp);
        vault.claimDeposit(rid, alice);
        vm.stopPrank();
    }

    function test_claimDeposit_twice_reverts() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        vm.prank(alice);
        vault.claimDeposit(rid, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.RequestNotSettled.selector, rid));
        vault.claimDeposit(rid, alice);
    }

    // -----------------------------------------------------------------------
    // requestRedeem
    // -----------------------------------------------------------------------

    function test_requestRedeem_locks_shares() public {
        // Get some shares first
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 shares = vault.balanceOf(alice);
        // requestId 2 is taken by funder in _advanceToCalculating; alice's redeem is id 3
        vm.startPrank(alice);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        vm.stopPrank();
        assertGt(redeemId, 1);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
    }

    function test_requestRedeem_emitsEvent() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        // requestId 2 is taken by funder in _advanceToCalculating
        vm.expectEmit(true, true, false, true, address(vault));
        emit IBaseVault.RedeemRequested(3, alice, shares, block.timestamp);
        vault.requestRedeem(shares, alice);
        vm.stopPrank();
    }

    /// @dev Must reach OPERATING+ACCEPTING first. While the product is still SUBSCRIBING,
    ///      `requireOperable()` rejects the call before the share balance is ever read — the
    ///      earlier version of this test used a bare `vm.expectRevert()` and passed on
    ///      `WrongProductState(OPERATING, SUBSCRIBING)`, never touching the guard it is named for.
    function test_requestRedeem_insufficient_shares_reverts() public {
        _advanceToCalculating();
        _completeCycle(); // OPERATING + ACCEPTING

        assertEq(vault.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IBaseVault.InsufficientShares.selector, alice, uint256(0), uint256(1_000e6))
        );
        vault.requestRedeem(1_000e6, alice);
    }

    /// @dev The state guard the old insufficient-shares test was actually exercising, pinned
    ///      on its own so both reverts stay covered and distinguishable.
    function test_requestRedeem_beforeOperating_revertsWrongProductState() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.OPERATING, ProductState.SUBSCRIBING
            )
        );
        vault.requestRedeem(1_000e6, alice);
    }

    // -----------------------------------------------------------------------
    // cancelRequest
    // -----------------------------------------------------------------------

    function test_cancelRequest_deposit_returns_USDT() public {
        uint256 assets = 1_000e6;
        uint256 rid = _requestDeposit(alice, assets);

        uint256 balBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        vault.cancelRequest(rid);
        assertEq(usdt.balanceOf(alice), balBefore + assets);
        assertEq(vault.pendingDepositLiability(), 0);
        assertEq(vault.pendingDepositByOwner(alice), 0);
    }

    function test_cancelRequest_during_CALCULATING_reverts() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseVault.CancelNotAllowed.selector, rid, ProductState.OPERATING, CycleState.CALCULATING
            )
        );
        vault.cancelRequest(rid);
    }

    function test_cancelRequest_redeem_returns_shares() public {
        // Acquire shares
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(vault), shares);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        vm.stopPrank();

        uint256 sharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.cancelRequest(redeemId);
        assertEq(vault.balanceOf(alice), sharesBefore + shares);
    }

    // -----------------------------------------------------------------------
    // claimRedeem
    // -----------------------------------------------------------------------

    function test_claimRedeem_before_settled_reverts() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(vault), shares);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.RequestNotSettled.selector, redeemId));
        vault.claimRedeem(redeemId, alice);
    }

    function test_claimRedeem_after_settled_transfers_USDT() public {
        uint256 assets = 1_000e6;
        uint256 depRid = _requestDeposit(alice, assets);
        _advanceToCalculating();
        _settleDeposits(_arr(depRid));
        vm.prank(alice);
        vault.claimDeposit(depRid, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(vault), shares);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        vm.stopPrank();
        _reqShares[redeemId] = shares;

        // Advance another cycle to CALCULATING. The original deposit's USDT is still sitting
        // in the vault (no Adapter/UnifiedPool wired), so freeVaultUSDT() already covers the
        // redeem — no extra funding needed to demonstrate net settlement.
        _advanceToCalculating();
        _settleRedeems(_arr(redeemId), 0);

        uint256 redeemAmt = _assetsFor(shares);
        uint256 balBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        vault.claimRedeem(redeemId, alice);
        assertEq(usdt.balanceOf(alice), balBefore + redeemAmt);
        assertEq(vault.reservedRedeemLiability(), 0);
    }

    // -----------------------------------------------------------------------
    // freeVaultUSDT / totalAssets
    // -----------------------------------------------------------------------

    function test_freeVaultUSDT_excludesPendingDeposit() public {
        uint256 assets = 1_000e6;
        _requestDeposit(alice, assets);
        assertEq(vault.freeVaultUSDT(), 0);
        assertEq(usdt.balanceOf(address(vault)), assets);
    }

    function test_totalAssets_zeroWhenEmpty() public view {
        assertEq(vault.totalAssets(), 0);
    }

    // -----------------------------------------------------------------------
    // snapshotSettlementPrice / settle
    // -----------------------------------------------------------------------

    function test_settle_by_non_settlement_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.OnlySettlement.selector, alice));
        vault.settle(1, _rs0(), _rs0(), 0);
    }

    function test_snapshotSettlementPrice_by_non_settlement_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.OnlySettlement.selector, alice));
        vault.snapshotSettlementPrice(1);
    }

    function test_settle_revertsIfSnapshotNotInitialized() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.SnapshotNotInitialized.selector, cycleNumber));
        vault.settle(cycleNumber, _rs1(rid, 1_000e6), _rs0(), 0);
    }

    function test_snapshotSettlementPrice_revertsIfAlreadyInitialized() public {
        _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.SnapshotAlreadyInitialized.selector, cycleNumber));
        vault.snapshotSettlementPrice(cycleNumber);
    }

    function test_settle_mints_correct_shares() public {
        uint256 assets = 2_000e6;
        uint256 rid = _requestDeposit(alice, assets);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);
        assertEq(vault.balanceOf(alice), _sharesFor(assets));
    }

    function test_settle_carriesOverUnselectedDeposit() public {
        uint256 rid1 = _requestDeposit(alice, 1_000e6);
        uint256 rid2 = _requestDeposit(bob, 500e6);
        _advanceToCalculating();

        // Only settle alice's deposit; bob's stays PENDING and rolls to next cycle.
        _settleDeposits(_arr(rid1));

        vm.prank(alice);
        vault.claimDeposit(rid1, alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.RequestNotSettled.selector, rid2));
        vault.claimDeposit(rid2, bob);
        // Bob's unselected deposit plus the funder2 deposit _advanceToCalculating() injects
        // to meet minRaiseAmount are both still PENDING.
        assertEq(vault.pendingDepositLiability(), 500e6 + _defaultParams().minRaiseAmount);
    }

    function test_settle_insufficientLiquidity_reverts() public {
        // Deposit, settle, claim, then request a redeem — but move the vault's free USDT to
        // UnifiedPool (simulating capital deployed elsewhere), with UnifiedPool.pending()
        // reflecting it so totalAssets()/price stay unchanged — only *liquid* cash (checked by
        // freeVaultUSDT()) drops, so the redeem becomes unfundable this cycle without being
        // an actual loss.
        MockUnifiedPool pool = new MockUnifiedPool();
        // Vault is already past CONFIGURING — setUnifiedPool is Timelock-only now.
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setUnifiedPool, (address(pool))));

        uint256 assets = 1_000e6;
        uint256 rid = _requestDeposit(alice, assets);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(vault), shares);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        vm.stopPrank();

        uint256 freeAmount = vault.freeVaultUSDT();
        vm.prank(address(vault));
        usdt.transfer(address(pool), freeAmount);
        pool.setPending(address(vault), freeAmount);

        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        uint256 redeemAmt = _assetsFor(shares);
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.InsufficientSettlementLiquidity.selector, redeemAmt, 0));
        vault.settle(cycleNumber, _rs0(), _rs1(redeemId, shares), 0);
    }

    function test_settle_partialDeposit_refundsRemainderImmediately() public {
        uint256 requested = 400_000e6;
        uint256 accepted = 350_000e6;
        // walletSubscriptionCap only gates the initial raise (SUBSCRIBING) — clear that phase
        // first via a funder-only cycle so alice's single 400k deposit isn't cap-blocked.
        _seedFirstCycle();
        usdt.mint(alice, requested); // top up beyond setUp's 100_000e6
        uint256 rid = _requestDeposit(alice, requested);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        uint256 balBefore = usdt.balanceOf(alice);
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IBaseVault.DepositSettled(rid, requested, accepted, requested - accepted, cycleNumber, block.timestamp);
        vault.settle(cycleNumber, _rs1(rid, accepted), _rs0(), 0);
        vm.stopPrank();

        // Refunded immediately — no claimRefund step, no re-queue.
        assertEq(usdt.balanceOf(alice), balBefore + (requested - accepted));
        assertEq(vault.pendingDepositLiability(), 0);
        assertEq(vault.pendingDepositByOwner(alice), 0);

        vm.prank(alice);
        uint256 shares = vault.claimDeposit(rid, alice);
        assertEq(shares, _sharesFor(accepted));
    }

    function test_settle_partialRedeem_staysQueuedAcrossCycles() public {
        uint256 assets = 3_000e6;
        uint256 rid = _requestDeposit(alice, assets);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(vault), shares);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        vm.stopPrank();

        // Cycle 1: pay out 1/3 of the shares only.
        uint256 firstChunk = shares / 3;
        _advanceToCalculating();
        uint256 cycle1 = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycle1);
        vault.settle(cycle1, _rs0(), _rs1(redeemId, firstChunk), 0);
        vm.stopPrank();
        _completeCycle();

        // Claimable already for the filled third, and the request keeps its queue slot for the
        // rest (审计反馈 V3 #3). Left unclaimed here so the cumulative-across-cycles assertion
        // below still measures what it always did; the claim-then-claim-again path has its own
        // test further down.
        assertEq(vault.getRedeemRequest(redeemId).settledAssets, _assetsFor(firstChunk));

        // Cycle 2: pay out the rest.
        uint256 remaining = shares - firstChunk;
        _advanceToCalculating();
        uint256 cycle2 = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycle2);
        vault.settle(cycle2, _rs0(), _rs1(redeemId, remaining), 0);
        vm.stopPrank();
        _completeCycle();

        uint256 balBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.claimRedeem(redeemId, alice);
        assertEq(assetsOut, _assetsFor(shares)); // cumulative across both cycles
        assertEq(usdt.balanceOf(alice), balBefore + assetsOut);
    }

    function test_settle_clientExample_depositCoversRedeem_excessRefunded() public {
        // Bob acquires shares, then queues a 350k redeem.
        uint256 bobAssets = 350_000e6;
        // walletSubscriptionCap only gates the initial raise (SUBSCRIBING) — clear that phase
        // first via a funder-only cycle so bob's single 350k deposit isn't cap-blocked.
        _seedFirstCycle();
        usdt.mint(bob, bobAssets); // top up beyond setUp's 100_000e6
        uint256 bobRid = _requestDeposit(bob, bobAssets);
        _advanceToCalculating();
        _settleDeposits(_arr(bobRid));
        vm.prank(bob);
        vault.claimDeposit(bobRid, bob);
        uint256 bobShares = vault.balanceOf(bob);
        vm.startPrank(bob);
        vault.approve(address(vault), bobShares);
        uint256 redeemId = vault.requestRedeem(bobShares, bob);
        vm.stopPrank();

        // Alice's 400k deposit request is next in the queue.
        uint256 aliceRequested = 400_000e6;
        usdt.mint(alice, aliceRequested);
        uint256 aliceRid = _requestDeposit(alice, aliceRequested);

        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        uint256 redeemAssets = _assetsFor(bobShares); // == 350_000e6 at the stable 1:1 price in this test

        uint256 aliceBalBefore = usdt.balanceOf(alice);
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        // Accept exactly enough of alice's deposit to cover bob's redeem; refund the rest immediately.
        uint256[] memory cleared = vault.settle(cycleNumber, _rs1(aliceRid, redeemAssets), _rs1(redeemId, bobShares), 0);
        vm.stopPrank();

        assertEq(cleared.length, 1);
        assertEq(cleared[0], redeemId); // bob's redeem fully cleared this cycle

        // Alice: partial accept + immediate refund of the untouched 50k.
        assertEq(usdt.balanceOf(alice), aliceBalBefore + (aliceRequested - redeemAssets));
        vm.prank(alice);
        uint256 aliceShares = vault.claimDeposit(aliceRid, alice);
        assertEq(aliceShares, _sharesFor(redeemAssets));

        // Bob: fully paid, claimable now.
        vm.prank(bob);
        uint256 bobAssetsOut = vault.claimRedeem(redeemId, bob);
        assertEq(bobAssetsOut, redeemAssets);
    }

    function test_settle_deposit_zeroSettleAmount_reverts() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.InvalidSettleAmount.selector, rid));
        vault.settle(cycleNumber, _rs1(rid, 0), _rs0(), 0);
        vm.stopPrank();
    }

    function test_settle_deposit_settleAmountExceedsRequest_reverts() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.InvalidSettleAmount.selector, rid));
        vault.settle(cycleNumber, _rs1(rid, 1_000e6 + 1), _rs0(), 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    // FIFO prefix rule — only the last deposit in a batch may be partially filled
    // -------------------------------------------------------------------

    function test_settle_deposits_lastEntryPartial_precedingFull_succeeds() public {
        uint256 aliceRid = _requestDeposit(alice, 1_000e6);
        uint256 bobRid = _requestDeposit(bob, 2_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        RequestSettlement[] memory items = new RequestSettlement[](2);
        items[0] = RequestSettlement({requestId: aliceRid, settleAmount: 1_000e6}); // full
        items[1] = RequestSettlement({requestId: bobRid, settleAmount: 800e6}); // partial, last

        uint256 bobBalBefore = usdt.balanceOf(bob);
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, items, _rs0(), 0);
        vm.stopPrank();

        assertEq(usdt.balanceOf(bob), bobBalBefore + 1_200e6); // unaccepted remainder refunded
        assertEq(vault.pendingDepositByOwner(alice), 0);
        assertEq(vault.pendingDepositByOwner(bob), 0);

        vm.prank(alice);
        assertEq(vault.claimDeposit(aliceRid, alice), _sharesFor(1_000e6));
        vm.prank(bob);
        assertEq(vault.claimDeposit(bobRid, bob), _sharesFor(800e6));
    }

    function test_settle_deposits_partialFillNotLast_reverts() public {
        uint256 aliceRid = _requestDeposit(alice, 1_000e6);
        uint256 bobRid = _requestDeposit(bob, 2_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        RequestSettlement[] memory items = new RequestSettlement[](2);
        items[0] = RequestSettlement({requestId: aliceRid, settleAmount: 600e6}); // partial, NOT last
        items[1] = RequestSettlement({requestId: bobRid, settleAmount: 2_000e6});

        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.PartialFillMustBeLast.selector, aliceRid));
        vault.settle(cycleNumber, items, _rs0(), 0);
        vm.stopPrank();
    }

    function test_settle_deposits_twoPartialsInOneBatch_reverts() public {
        uint256 aliceRid = _requestDeposit(alice, 1_000e6);
        uint256 bobRid = _requestDeposit(bob, 2_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        RequestSettlement[] memory items = new RequestSettlement[](2);
        items[0] = RequestSettlement({requestId: aliceRid, settleAmount: 600e6}); // partial, not last
        items[1] = RequestSettlement({requestId: bobRid, settleAmount: 1_500e6}); // partial, last

        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.PartialFillMustBeLast.selector, aliceRid));
        vault.settle(cycleNumber, items, _rs0(), 0);
        vm.stopPrank();
    }

    function test_settle_deposits_singleEntryBatchPartial_succeeds() public {
        // The only entry is also the last entry, so a partial fill is legal.
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        uint256 balBefore = usdt.balanceOf(alice);
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, _rs1(rid, 250e6), _rs0(), 0);
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), balBefore + 750e6);
        vm.prank(alice);
        assertEq(vault.claimDeposit(rid, alice), _sharesFor(250e6));
    }

    function test_settle_deposits_allEntriesFull_unaffectedByFifoRule() public {
        uint256 aliceRid = _requestDeposit(alice, 1_000e6);
        uint256 bobRid = _requestDeposit(bob, 2_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        uint256 aliceBalBefore = usdt.balanceOf(alice);
        RequestSettlement[] memory items = new RequestSettlement[](2);
        items[0] = RequestSettlement({requestId: aliceRid, settleAmount: 1_000e6});
        items[1] = RequestSettlement({requestId: bobRid, settleAmount: 2_000e6});

        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, items, _rs0(), 0);
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), aliceBalBefore); // nothing refunded
        vm.prank(alice);
        assertEq(vault.claimDeposit(aliceRid, alice), _sharesFor(1_000e6));
        vm.prank(bob);
        assertEq(vault.claimDeposit(bobRid, bob), _sharesFor(2_000e6));
    }

    function test_settle_cycle0_fifoPrefix_thirdPartial_fourthStaysPending() public {
        // Client's Cycle 0 example: the queue holds four subscriptions, the batch accepts the
        // first two in full, partially fills the third (the marginal request), and simply omits
        // the fourth, which stays PENDING for a later cycle. This is exactly the shape the FIFO
        // prefix rule permits.
        address dave = makeAddr("dave");
        address erin = makeAddr("erin");
        usdt.mint(dave, 40_000e6);
        usdt.mint(erin, 40_000e6);
        usdt.mint(alice, 40_000e6);
        usdt.mint(bob, 40_000e6);

        uint256 rid1 = _requestDeposit(alice, 40_000e6);
        uint256 rid2 = _requestDeposit(bob, 40_000e6);
        uint256 rid3 = _requestDeposit(dave, 40_000e6);
        uint256 rid4 = _requestDeposit(erin, 40_000e6);

        // Total subscribed (160k) already clears minRaiseAmount, so no extra funder is queued
        // and finalizeSubscription lands the vault on cycle 0 / CALCULATING directly.
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        assertEq(cycleNumber, 0);

        RequestSettlement[] memory items = new RequestSettlement[](3);
        items[0] = RequestSettlement({requestId: rid1, settleAmount: 40_000e6});
        items[1] = RequestSettlement({requestId: rid2, settleAmount: 40_000e6});
        items[2] = RequestSettlement({requestId: rid3, settleAmount: 25_000e6}); // marginal, partial

        uint256 daveBalBefore = usdt.balanceOf(dave);
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, items, _rs0(), 0);
        vm.stopPrank();

        assertEq(usdt.balanceOf(dave), daveBalBefore + 15_000e6); // unaccepted remainder refunded
        vm.prank(alice);
        assertEq(vault.claimDeposit(rid1, alice), _sharesFor(40_000e6));
        vm.prank(bob);
        assertEq(vault.claimDeposit(rid2, bob), _sharesFor(40_000e6));
        vm.prank(dave);
        assertEq(vault.claimDeposit(rid3, dave), _sharesFor(25_000e6));

        // Erin's request was never in the array: still PENDING, liability intact, no refund.
        assertEq(vault.pendingDepositByOwner(erin), 40_000e6);
        assertEq(vault.pendingDepositLiability(), 40_000e6);
        vm.prank(erin);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.RequestNotSettled.selector, rid4));
        vault.claimDeposit(rid4, erin);
    }

    function test_settle_redeem_settleAmountExceedsRemaining_reverts() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(vault), shares);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        vm.stopPrank();

        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.InvalidSettleAmount.selector, redeemId));
        vault.settle(cycleNumber, _rs0(), _rs1(redeemId, shares + 1), 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    // writeDownInsolvency
    // -------------------------------------------------------------------

    /// @notice Drains the vault's own USDT balance to simulate an Adapter-side loss, without
    ///         crediting UnifiedPool/anything else — grossManagedAssets() drops for real.
    function _simulateLoss(uint256 amount) internal {
        vm.prank(address(vault));
        usdt.transfer(makeAddr("lossSink"), amount);
    }

    /// @notice The recovery path now works only on the classes that remain eligible — settled
    ///         redemptions and refunds. A deficit driven by PENDING subscriptions cannot be
    ///         cleared this way at all, because that money is no longer haircuttable
    ///         (审计报告（一）回复 §2).
    /// @dev Builds the one situation writeDownInsolvency exists for: assets that cannot cover
    ///      even the FIXED claims. Returns the two settled redemption ids, in ascending order.
    function _insolventWithTwoSettledRedeems() internal returns (uint256 idA, uint256 idB) {
        _seedFirstCycle();

        uint256 ridA = _requestDeposit(alice, 2_000e6);
        uint256 ridB = _requestDeposit(bob, 1_000e6);
        _advanceToCalculating();
        _settle(_toIds(ridA, ridB), new uint256[](0), 0);
        vm.prank(alice);
        vault.claimDeposit(ridA, alice);
        vm.prank(bob);
        vault.claimDeposit(ridB, bob);

        uint256 sharesA = vault.balanceOf(alice);
        uint256 sharesB = vault.balanceOf(bob);
        vm.startPrank(alice);
        vault.approve(address(vault), sharesA);
        idA = vault.requestRedeem(sharesA, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        vault.approve(address(vault), sharesB);
        idB = vault.requestRedeem(sharesB, bob);
        vm.stopPrank();

        _advanceToCalculating();
        uint256 cn = sm.currentCycleNumber(address(vault));
        RequestSettlement[] memory reds = new RequestSettlement[](2);
        reds[0] = RequestSettlement({requestId: idA, settleAmount: sharesA});
        reds[1] = RequestSettlement({requestId: idB, settleAmount: sharesB});
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cn);
        vault.settle(cn, _rs0(), reds, 0);
        vm.stopPrank();
        _completeCycle();

        // Drain until gross no longer covers even the fixed claims — that, and only that, is
        // what this path is for. The protected classes are zero here (every subscription has
        // settled), so everything above the reserved redemptions can go.
        uint256 reserved = vault.reservedRedeemLiability();
        uint256 gross = vault.grossManagedAssets();
        _simulateLoss(gross - (reserved / 2));
        assertLt(vault.grossManagedAssets(), reserved, "must be short of the fixed claims");

        (idA, idB) = idA < idB ? (idA, idB) : (idB, idA);
    }

    /// @dev Claims `rid` for `who` and returns the USDT actually received.
    function _claimRedeemAmount(address who, uint256 rid) internal returns (uint256) {
        uint256 before = usdt.balanceOf(who);
        vm.prank(who);
        vault.claimRedeem(rid, who);
        return usdt.balanceOf(who) - before;
    }

    function _toIds(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    /// @notice The whole point of the redesign: one ratio, computed on-chain, applied to every
    ///         outstanding settled redemption (0826 最小化修改方案 §四, §五).
    function test_writeDownInsolvency_appliesOneUniformRatioToEveryClaim() public {
        (uint256 idA, uint256 idB) = _insolventWithTwoSettledRedeems();

        uint256 reserved = vault.reservedRedeemLiability();
        uint256 gross = vault.grossManagedAssets();
        uint256 protectedLiab = vault.pendingDepositLiability() + vault.refundableLiability();
        uint256 available = gross - protectedLiab;

        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.writeDownInsolvency, (_toIds(idA, idB))));

        assertTrue(vault.insolvencyLiquidated());
        assertEq(vault.reservedRedeemLiability(), available, "the whole remainder is allocated");

        // What each holder can actually draw is the proof the ratio was uniform: alice put in
        // twice what bob did, so she must come out with twice as much, and the two together
        // must exhaust exactly what was available.
        uint256 paidA = _claimRedeemAmount(alice, idA);
        uint256 paidB = _claimRedeemAmount(bob, idB);
        assertApproxEqAbs(paidA, paidB * 2, 2, "same ratio applied to both");
        assertEq(paidA + paidB, available, "nothing left over, nothing conjured");
    }

    /// @notice Ordinary investment losses are out of scope: while the fixed claims are still
    ///         covered, the loss belongs in NAV and this path must stay shut (§二).
    function test_writeDownInsolvency_revertsWhenFixedClaimsStillCovered() public {
        (uint256 idA, uint256 idB) = _insolventWithTwoSettledRedeems();
        // Put the money back so the vault is solvent against its fixed claims again.
        usdt.mint(address(vault), 1_000_000e6);

        vm.prank(governor);
        bytes32 id =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.writeDownInsolvency, (_toIds(idA, idB))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector); // NotInsolvent
        tl.executeParamChange(id);
    }

    /// @notice Omitting a holder is impossible: the submitted originals must sum to the entire
    ///         outstanding reserved liability (§五).
    function test_writeDownInsolvency_revertsOnOmittedRequest() public {
        (uint256 idA,) = _insolventWithTwoSettledRedeems();

        vm.prank(governor);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.writeDownInsolvency, (_arr(idA))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector); // IncompleteWriteDown
        tl.executeParamChange(id);
    }

    /// @notice And so is submitting anyone twice, or out of order.
    function test_writeDownInsolvency_revertsOnRepeatedOrUnsortedIds() public {
        (uint256 idA, uint256 idB) = _insolventWithTwoSettledRedeems();

        vm.prank(governor);
        bytes32 dup =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.writeDownInsolvency, (_toIds(idA, idA))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector); // IdsNotStrictlyAscending
        tl.executeParamChange(dup);

        vm.prank(governor);
        bytes32 unsorted =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.writeDownInsolvency, (_toIds(idB, idA))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(unsorted);
    }

    /// @notice PENDING and REFUNDABLE are protected in full — neither ever bought into the
    ///         portfolio (§三).
    function test_writeDownInsolvency_leavesProtectedClassesWhole() public {
        (uint256 idA, uint256 idB) = _insolventWithTwoSettledRedeems();
        uint256 pendingBefore = vault.pendingDepositLiability();
        uint256 refundableBefore = vault.refundableLiability();

        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.writeDownInsolvency, (_toIds(idA, idB))));

        assertEq(vault.pendingDepositLiability(), pendingBefore);
        assertEq(vault.refundableLiability(), refundableBefore);
    }

    /// @notice It may only ever run once.
    function test_writeDownInsolvency_cannotRunTwice() public {
        (uint256 idA, uint256 idB) = _insolventWithTwoSettledRedeems();
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.writeDownInsolvency, (_toIds(idA, idB))));

        vm.prank(governor);
        bytes32 id =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.writeDownInsolvency, (_toIds(idA, idB))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector); // AlreadyLiquidated
        tl.executeParamChange(id);
    }

    /// @notice After liquidation the vault only unwinds: no new business, and claimFinal is shut
    ///         permanently because shares rank behind claims the assets already could not cover
    ///         (§七). Claiming the haircut redemption still works.
    function test_writeDownInsolvency_afterLiquidationOnlyUnwindIsAllowed() public {
        (uint256 idA, uint256 idB) = _insolventWithTwoSettledRedeems();
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.writeDownInsolvency, (_toIds(idA, idB))));

        vm.startPrank(alice);
        usdt.approve(address(vault), 100e6);
        vm.expectRevert(IBaseVault.VaultLiquidated.selector);
        vault.requestDeposit(100e6, alice);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(IBaseVault.VaultLiquidated.selector);
        vault.claimFinal(1, alice, alice);

        // The already-settled (now haircut) redemption is still claimable.
        assertGt(_claimRedeemAmount(alice, idA), 0, "haircut redemption still pays out");
    }

    function test_writeDownInsolvency_by_non_governor_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.writeDownInsolvency(new uint256[](0));
    }

    // -------------------------------------------------------------------
    // Partial-fill claiming and post-liquidation exit (审计反馈 V3 #3)
    // -------------------------------------------------------------------

    /// @dev Reproduces the exact trap: alice's redeem is only partially filled and stays QUEUED,
    ///      bob's clears in full, then the liquidation lands while the cycle sits in CALCULATING.
    ///      From there `snapshotSettlementPrice` reverts forever so alice's remainder can never
    ///      be filled, and the cycle never returns to ACCEPTING so `_requireCancellable` used to
    ///      reject `cancelRequest` forever too. Returns the ids in ascending order plus alice's
    ///      unfilled share count.
    function _insolventWithPartiallyFilledQueuedRedeem()
        internal
        returns (uint256 idAlice, uint256 idBob, uint256 aliceRemaining)
    {
        _seedFirstCycle();

        uint256 ridA = _requestDeposit(alice, 2_000e6);
        uint256 ridB = _requestDeposit(bob, 1_000e6);
        _advanceToCalculating();
        _settle(_toIds(ridA, ridB), new uint256[](0), 0);
        vm.prank(alice);
        vault.claimDeposit(ridA, alice);
        vm.prank(bob);
        vault.claimDeposit(ridB, bob);

        uint256 sharesA = vault.balanceOf(alice);
        uint256 sharesB = vault.balanceOf(bob);
        vm.startPrank(alice);
        vault.approve(address(vault), sharesA);
        idAlice = vault.requestRedeem(sharesA, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        vault.approve(address(vault), sharesB);
        idBob = vault.requestRedeem(sharesB, bob);
        vm.stopPrank();

        // Fill bob in full and alice for half only — alice stays QUEUED holding real settled cash.
        uint256 aliceFilled = sharesA / 2;
        aliceRemaining = sharesA - aliceFilled;
        _advanceToCalculating();
        uint256 cn = sm.currentCycleNumber(address(vault));
        RequestSettlement[] memory reds = new RequestSettlement[](2);
        reds[0] = RequestSettlement({requestId: idBob, settleAmount: sharesB});
        reds[1] = RequestSettlement({requestId: idAlice, settleAmount: aliceFilled});
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cn);
        vault.settle(cn, _rs0(), reds, 0);
        vm.stopPrank();
        _completeCycle();

        uint256 reserved = vault.reservedRedeemLiability();
        uint256 gross = vault.grossManagedAssets();
        _simulateLoss(gross - (reserved / 2));

        // The bad timing the audit calls out: liquidate mid-CALCULATING, so the cycle can never
        // be walked back to ACCEPTING.
        _advanceToCalculating();
        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.CALCULATING));

        _scheduleAndExecute(
            governor,
            abi.encodeCall(
                IBaseVault.writeDownInsolvency, (idAlice < idBob ? _toIds(idAlice, idBob) : _toIds(idBob, idAlice))
            )
        );
    }

    /// @notice The defect itself: before this fix the partially-filled holder could not reach a
    ///         single cent of cash their fully-filled peer was paid, at the same haircut ratio,
    ///         purely because the Operator had not put their remainder in a later batch.
    function test_claimRedeem_partiallyFilledIsPaidAfterLiquidation() public {
        (uint256 idAlice, uint256 idBob, uint256 aliceRemaining) = _insolventWithPartiallyFilledQueuedRedeem();

        assertEq(uint8(vault.getRedeemRequest(idAlice).state), uint8(RedeemRequestState.QUEUED));

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 paidAlice = _claimRedeemAmount(alice, idAlice);
        uint256 paidBob = _claimRedeemAmount(bob, idBob);

        assertGt(paidAlice, 0, "the whole point: the partial fill pays out");
        assertGt(paidBob, 0);

        // Same liquidation, same ratio: alice was filled for half of a position twice bob's, so
        // the two written-down payouts must come out equal.
        assertApproxEqAbs(paidAlice, paidBob, 2, "one uniform ratio, partial and full alike");

        // Paid AND exited: queue slot released and the unfilled shares handed back.
        assertEq(vault.balanceOf(alice), sharesBefore + aliceRemaining, "unfilled shares returned");
        IBaseVault.RedeemRequest memory req = vault.getRedeemRequest(idAlice);
        assertEq(req.remainingShares, 0);
        assertEq(req.settledAssets, 0);
        assertEq(uint8(req.state), uint8(RedeemRequestState.CLAIMED));
        assertEq(vault.reservedRedeemLiability(), 0, "liability fully discharged");
    }

    function test_claimRedeem_cannotBeClaimedTwice() public {
        (uint256 idAlice,,) = _insolventWithPartiallyFilledQueuedRedeem();
        assertGt(_claimRedeemAmount(alice, idAlice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.RequestNotSettled.selector, idAlice));
        vault.claimRedeem(idAlice, alice);
    }

    /// @notice A liquidated request with nothing written down to collect still has to be able to
    ///         release its shares, and the cycle-state gate must not stand in the way
    ///         (审计问题 3 回复 §三.4).
    function test_cancelRequest_afterLiquidationIgnoresCycleState() public {
        (uint256 idAlice,, uint256 aliceRemaining) = _insolventWithPartiallyFilledQueuedRedeem();

        // The cycle is stuck in CALCULATING, which `_requireCancellable` rejects outright — this
        // call only goes through because liquidation drops that gate.
        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.CALCULATING));

        uint256 sharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.cancelRequest(idAlice);

        assertEq(vault.balanceOf(alice), sharesBefore + aliceRemaining, "shares released");
        // Cancelling never forfeits cash already owed — the request is promoted to SETTLED and
        // stays claimable (审计问题 3 回复 §二.5).
        IBaseVault.RedeemRequest memory req = vault.getRedeemRequest(idAlice);
        assertEq(uint8(req.state), uint8(RedeemRequestState.SETTLED));
        assertGt(req.settledAssets, 0);
        assertGt(_claimRedeemAmount(alice, idAlice), 0, "written-down cash still collectable");
    }

    /// @notice 审计问题 3 回复 §三.4 / 测试要求 8: a liquidated request with **zero** written-down
    ///         cash — never filled at all — must still be able to release its shares and leave the
    ///         queue. `claimRedeem` has nothing to pay here, so `cancelRequest` is the only exit,
    ///         and its cycle-state gate has to be out of the way for that to work.
    function test_cancelRequest_afterLiquidation_zeroSettledAssets_stillReleasesShares() public {
        _seedFirstCycle();

        uint256 ridA = _requestDeposit(alice, 2_000e6);
        uint256 ridB = _requestDeposit(bob, 1_000e6);
        _advanceToCalculating();
        _settle(_toIds(ridA, ridB), new uint256[](0), 0);
        vm.prank(alice);
        vault.claimDeposit(ridA, alice);
        vm.prank(bob);
        vault.claimDeposit(ridB, bob);

        uint256 sharesA = vault.balanceOf(alice);
        uint256 sharesB = vault.balanceOf(bob);
        // Bob splits his position in two so the second half can be left untouched by the batch.
        uint256 bobHalf = sharesB / 2;
        vm.startPrank(alice);
        vault.approve(address(vault), sharesA);
        uint256 idAlice = vault.requestRedeem(sharesA, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        vault.approve(address(vault), sharesB);
        vault.requestRedeem(bobHalf, bob);
        uint256 idBobUnfilled = vault.requestRedeem(sharesB - bobHalf, bob);
        vm.stopPrank();

        // Fill alice only. Bob's two requests stay QUEUED with settledAssets == 0.
        _advanceToCalculating();
        uint256 cn = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cn);
        vault.settle(cn, _rs0(), _rs1(idAlice, sharesA), 0);
        vm.stopPrank();
        _completeCycle();

        _simulateLoss(vault.grossManagedAssets() - (vault.reservedRedeemLiability() / 2));
        _advanceToCalculating();

        uint256[] memory settledIds = new uint256[](1);
        settledIds[0] = idAlice;
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.writeDownInsolvency, (settledIds)));

        IBaseVault.RedeemRequest memory before = vault.getRedeemRequest(idBobUnfilled);
        assertEq(before.settledAssets, 0, "nothing was ever filled on this one");
        assertGt(before.remainingShares, 0);

        uint256 sharesBefore = vault.balanceOf(bob);
        vm.prank(bob);
        vault.cancelRequest(idBobUnfilled);

        IBaseVault.RedeemRequest memory afterCancel = vault.getRedeemRequest(idBobUnfilled);
        assertEq(vault.balanceOf(bob), sharesBefore + before.remainingShares, "shares came back");
        assertEq(afterCancel.remainingShares, 0);
        // No cash was ever owed, so the request goes terminal as CANCELLED rather than SETTLED.
        assertEq(uint8(afterCancel.state), uint8(RedeemRequestState.CANCELLED));
    }

    /// @notice Normal operation: claim what has been filled, stay queued for the rest at the same
    ///         FIFO position, and claim again when a later batch fills more.
    ///         `reservedRedeemLiability` must equal the unclaimed total at every step.
    function test_claimRedeem_partialClaimStaysQueuedAndCanClaimAgain() public {
        uint256 rid = _requestDeposit(alice, 3_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(vault), shares);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        vm.stopPrank();

        // Cycle 1: fill a third.
        uint256 firstChunk = shares / 3;
        _advanceToCalculating();
        uint256 cycle1 = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycle1);
        vault.settle(cycle1, _rs0(), _rs1(redeemId, firstChunk), 0);
        vm.stopPrank();
        _completeCycle();

        assertEq(vault.reservedRedeemLiability(), _assetsFor(firstChunk));

        // 测试要求 11: the cash leaving was already carried as a liability, so paying it out
        // moves neither the Vault's net assets nor the share price.
        uint256 assetsBefore = vault.totalAssets();
        uint256 priceBefore = vault.convertToAssets(1e18);

        uint256 firstPaid = _claimRedeemAmount(alice, redeemId);
        assertEq(firstPaid, _assetsFor(firstChunk), "paid exactly what was filled");
        assertEq(vault.reservedRedeemLiability(), 0, "liability follows the cash out");
        assertEq(vault.totalAssets(), assetsBefore, "partial claim does not move net assets");
        assertEq(vault.convertToAssets(1e18), priceBefore, "partial claim does not move share price");

        IBaseVault.RedeemRequest memory req = vault.getRedeemRequest(redeemId);
        assertEq(uint8(req.state), uint8(RedeemRequestState.QUEUED), "still queued for the rest");
        assertEq(req.remainingShares, shares - firstChunk);
        assertEq(req.settledAssets, 0, "nothing left owed on the claimed portion");

        // Nothing new filled yet, so there is nothing to claim.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.RequestNotSettled.selector, redeemId));
        vault.claimRedeem(redeemId, alice);

        // Cycle 2: fill the remainder, which both clears the request and makes it claimable again.
        uint256 remaining = shares - firstChunk;
        _advanceToCalculating();
        uint256 cycle2 = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycle2);
        vault.settle(cycle2, _rs0(), _rs1(redeemId, remaining), 0);
        vm.stopPrank();
        _completeCycle();

        uint256 secondPaid = _claimRedeemAmount(alice, redeemId);
        assertEq(secondPaid, _assetsFor(remaining));
        assertEq(firstPaid + secondPaid, _assetsFor(shares), "the two claims sum to the whole");
        assertEq(uint8(vault.getRedeemRequest(redeemId).state), uint8(RedeemRequestState.CLAIMED));
        assertEq(vault.reservedRedeemLiability(), 0);
    }

    // -------------------------------------------------------------------
    // Performance fee — unset recipient
    // -------------------------------------------------------------------

    function test_setPerformanceFeeBps_revertsIfRecipientUnset_viaTimelock() public {
        // Task 5's recipient-must-already-be-set guard on setPerformanceFeeBps makes the old
        // "fee enabled but recipient unset -> PerformanceFeeSkipped" scenario unreachable via the
        // public API: the vault has no recipient configured yet (setUp() never sets one), so
        // enabling a nonzero fee now reverts up front, whether called directly or via Timelock.
        vm.prank(curator);
        bytes32 id =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(100))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);

        assertEq(vault.performanceFeeBps(), 0);
    }

    function test_snapshotSettlementPrice_accruesPerformanceFee_whenRecipientSet() public {
        // Vault is already past CONFIGURING — Curator-class actions are Timelock-only now.
        // Recipient must be set first: setPerformanceFeeBps now guards against enabling a nonzero
        // fee before a recipient exists.
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (bob)));
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(100)))); // 1%

        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        usdt.mint(address(vault), 10_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        assertGt(vault.balanceOf(bob), 0);
    }

    // -------------------------------------------------------------------
    // Performance fee — cap raised to 10,000 bps
    // -------------------------------------------------------------------

    function test_setPerformanceFeeBps_allowsAboveOldFivePercentCeiling() public {
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (bob)));
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(5000)))); // 50%
        assertEq(vault.performanceFeeBps(), 5000);
    }

    function test_setPerformanceFeeBps_revertsAboveTenThousandBps() public {
        vm.prank(curator); // still CONFIGURING at this point in a fresh vault — direct Curator call
        EarnVault v =
            new EarnVault("Fee Cap", "htFEE", address(usdt), address(sm), address(queue), governor, address(0));
        vm.prank(governor);
        v.setCurator(curator);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.FeeTooHigh.selector, uint16(10_001)));
        v.setPerformanceFeeBps(10_001);
    }

    function test_setPerformanceFeeBps_revertsIfRecipientNotYetSet() public {
        EarnVault v =
            new EarnVault("Fee Guard", "htFEEG", address(usdt), address(sm), address(queue), governor, address(0));
        vm.prank(governor);
        v.setCurator(curator);
        vm.prank(curator);
        vm.expectRevert(IBaseVault.InvalidFeeRecipient.selector);
        v.setPerformanceFeeBps(100);
    }

    // -------------------------------------------------------------------
    // Protocol fee split — Governor-only config
    // -------------------------------------------------------------------

    function test_setProtocolFeeConfig_governorSucceeds() public {
        address revPool = makeAddr("revenuePool");
        vm.prank(governor); // this test file's `governor` doubles as HyperAccessControl's GOVERNOR_ROLE holder
        vault.setProtocolFeeConfig(revPool, 3000);
        assertEq(vault.revenuePool(), revPool);
        assertEq(vault.protocolFeeShareBps(), 3000);
    }

    function test_setProtocolFeeConfig_revertsForNonGovernor() public {
        vm.prank(curator);
        // Unauthorized — governed by HyperAccessControl, not Vault-local Curator
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setProtocolFeeConfig(makeAddr("revenuePool"), 3000);
    }

    function test_setProtocolFeeConfig_revertsAboveTenThousandBps() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.FeeTooHigh.selector, uint16(10_001)));
        vault.setProtocolFeeConfig(makeAddr("revenuePool"), 10_001);
    }

    function test_setProtocolFeeConfig_revertsForZeroRevenuePoolWithNonzeroShare() public {
        vm.prank(governor);
        vm.expectRevert(IBaseVault.InvalidFeeRecipient.selector);
        vault.setProtocolFeeConfig(address(0), 1);
    }

    function test_setProtocolFeeConfig_allowsZeroShareWithZeroRevenuePool() public {
        vm.prank(governor);
        vault.setProtocolFeeConfig(address(0), 0);
        assertEq(vault.revenuePool(), address(0));
        assertEq(vault.protocolFeeShareBps(), 0);
    }

    // -------------------------------------------------------------------
    // Performance fee — split between recipient and revenuePool
    // -------------------------------------------------------------------

    function test_snapshotSettlementPrice_splitsFeeBetweenRecipientAndRevenuePool() public {
        address revPool = makeAddr("revenuePool");
        vm.prank(governor);
        vault.setProtocolFeeConfig(revPool, 3000); // protocol 30%

        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (bob)));
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(2000)))); // 20% total fee

        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 yield = 100_000e6; // matches the client's worked example
        usdt.mint(address(vault), yield);

        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.recordLogs();
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        // Client's worked example: 100_000 USDT profit, 20% fee -> 20_000 Share total,
        // 30% protocol / 70% manager split -> 6_000 / 14_000 Share.
        // (Exact totalSupply/assets at snapshot time differ from the doc's simplified example, so
        // assert the *split ratio* rather than the literal 6_000/14_000 numbers.)
        uint256 revPoolShares = vault.balanceOf(revPool);
        uint256 bobShares = vault.balanceOf(bob);
        assertGt(revPoolShares, 0);
        assertGt(bobShares, 0);
        // protocolFeeShares = feeShares * 3000 / 10_000 (floored) — exact, same floor-division
        // semantics as the contract, no tolerance.
        assertEq(revPoolShares, ((revPoolShares + bobShares) * 3000) / 10_000);

        // No-drift invariant: decode the PerformanceFeeDistributed event and cross-check its
        // reported totals against both the event's own split and the actual on-chain balances.
        // This is the check that would fail if recipientFeeShares were computed via an
        // independent second mulDiv instead of feeShares - protocolFeeShares.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        uint256 feeShares;
        uint256 protocolFeeShares;
        uint256 recipientFeeShares;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IBaseVault.PerformanceFeeDistributed.selector) {
                (, feeShares, protocolFeeShares, recipientFeeShares,,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, address, address));
                found = true;
                break;
            }
        }
        assertTrue(found, "PerformanceFeeDistributed not emitted");
        assertEq(protocolFeeShares + recipientFeeShares, feeShares);
        assertEq(feeShares, vault.balanceOf(revPool) + vault.balanceOf(bob));
    }

    function test_snapshotSettlementPrice_singleMint_whenRecipientEqualsRevenuePool() public {
        vm.prank(governor);
        vault.setProtocolFeeConfig(bob, 3000); // revenuePool == performanceFeeRecipient == bob

        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (bob)));
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(2000))));

        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        usdt.mint(address(vault), 100_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        vm.recordLogs();
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        assertGt(vault.balanceOf(bob), 0);

        // Prove the single-mint branch (revenuePool == performanceFeeRecipient) actually took a
        // single _mintShares call for the fee, rather than two separate mints that happened to
        // land on the same balance. Count Transfer(0x0, bob, _) mint events emitted for the fee.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        uint256 mintToBobCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(vault) && logs[i].topics[0] == transferTopic
                    && logs[i].topics[1] == bytes32(0) && address(uint160(uint256(logs[i].topics[2]))) == bob
            ) {
                mintToBobCount++;
            }
        }
        assertEq(mintToBobCount, 1, "expected exactly one mint Transfer to bob (single-mint branch)");
    }

    function test_snapshotSettlementPrice_protocolOnlyWhenShareIs100Percent() public {
        address revPool = makeAddr("revenuePool");
        vm.prank(governor);
        vault.setProtocolFeeConfig(revPool, 10_000); // 100% to protocol

        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (bob)));
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(2000))));

        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        usdt.mint(address(vault), 100_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        assertGt(vault.balanceOf(revPool), 0);
        assertEq(vault.balanceOf(bob), 0); // manager gets nothing this cycle — 100% went to protocol
    }

    function test_snapshotSettlementPrice_emitsPerformanceFeeDistributed() public {
        address revPool = makeAddr("revenuePool");
        vm.prank(governor);
        vault.setProtocolFeeConfig(revPool, 3000);
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (bob)));
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(2000))));

        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        usdt.mint(address(vault), 100_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        // Don't assert exact feeAssets/feeShares values inline (depends on live totalAssets/totalSupply
        // at snapshot time) — `IBaseVault.PerformanceFeeDistributed.selector` on an event identifier
        // doesn't compile as a topic-matching expression, so use vm.expectEmit checking only the
        // indexed cycleNumber topic (the non-indexed fee amounts aren't known ahead of the call) and
        // let a separate balance-based test (above) cover the numeric split.
        vm.expectEmit(true, false, false, false, address(vault));
        emit IBaseVault.PerformanceFeeDistributed(cycleNumber, 0, 0, 0, 0, revPool, bob);
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
    }

    function test_settle_supplyCapExceeded_reverts() public {
        // Fresh vault with a small share cap. StateManager.recordSubscription enforces no
        // capacity limit at all, so a first deposit gets the product to OPERATING and a second
        // OPERATING-phase deposit (recordSubscription no-ops there) pushes the end-of-settle
        // state over the share cap — only BaseVault.settle()'s own subscriptionCapShare check
        // catches this.
        EarnVault v =
            new EarnVault("Cap Test", "htCAP", address(usdt), address(sm), address(queue), governor, address(0));
        vm.prank(factory);
        sm.registerVault(address(v));

        vm.startPrank(governor);
        v.setCurator(governor); // reused as Curator here too; still CONFIGURING, no Timelock class conflict
        ProductParams memory p = _defaultParams();
        p.walletSubscriptionCap = 10_000e6;
        p.minRaiseAmount = 100e6;
        // 500e18 shares == 500e6 USDT at the flat 1.0 price this scenario runs at. The cap now
        // travels with the rest of the product parameters and StateManager pushes it into the
        // vault (募集上限参数调整建议 §2).
        p.subscriptionCapShare = 500e18;
        sm.setProductParams(address(v), p);
        assertEq(v.subscriptionCapShare(), 500e18);
        v.setSettlement(settlement);
        v.setKeeper(keeper, true);
        vm.stopPrank();
        vm.prank(keeper);
        sm.openSubscription(address(v));

        vm.startPrank(alice);
        usdt.approve(address(v), 100e6);
        uint256 rid0 = v.requestDeposit(100e6, alice);
        vm.stopPrank();

        uint256 target = p.subscriptionEnd + p.cycleDuration + 1;
        vm.warp(target);
        // Cycle-0 fix: finalizeSubscription now force-sets CycleState to CALCULATING directly
        // on a successful raise, instead of leaving it at ACCEPTING — no separate
        // startCycleCalculation call needed (and calling it here would now revert
        // WrongCycleState since the cycle is no longer ACCEPTING).
        vm.prank(keeper);
        sm.finalizeSubscription(address(v));

        uint256 cycle0 = sm.currentCycleNumber(address(v));
        vm.startPrank(settlement);
        v.snapshotSettlementPrice(cycle0);
        v.settle(cycle0, _rs1(rid0, 100e6), _rs0(), 0);
        vm.stopPrank();
        vm.prank(settlement);
        sm.completeCycle(address(v));

        // OPERATING-phase deposit: recordSubscription no-ops here, so this is only caught by
        // BaseVault.settle()'s own subscriptionCapShare check.
        vm.startPrank(bob);
        usdt.approve(address(v), 500e6);
        uint256 rid1 = v.requestDeposit(500e6, bob);
        vm.stopPrank();

        uint256 cycleStart = sm.currentCycleStart(address(v));
        vm.warp(cycleStart + p.cycleDuration + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(address(v));

        uint256 cycle1 = sm.currentCycleNumber(address(v));
        vm.prank(settlement);
        v.snapshotSettlementPrice(cycle1);

        vm.prank(settlement);
        // Reported in share units: the cap is a quota on subscribed shares, not on AUM.
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.SupplyCapExceeded.selector, 500e18, 600e18));
        v.settle(cycle1, _rs1(rid1, 500e6), _rs0(), 0);
    }

    // -----------------------------------------------------------------------
    // subscriptionCapShare — share-denominated settle-time cap
    // -----------------------------------------------------------------------

    /// @dev Sets the cap through the VaultTimelock caller identity. `vault` is already past
    ///      CONFIGURING by the end of setUp, so a direct Curator call would revert.
    function _setCapShare(uint256 capShare) internal {
        vm.prank(address(tl));
        vault.setSubscriptionCapShare(capShare);
    }

    function test_settle_capShareZero_neverReverts() public {
        assertEq(vault.subscriptionCapShare(), 0, "unlimited by default");

        _giveAliceShares(100_000e6);
        uint256 rid = _requestDeposit(bob, 100_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        assertEq(vault.totalSupply(), 200_000e18, "no cap, no limit on supply");
    }

    /// @notice Boundary, AUM side and share side. The batch that lands the vault exactly on
    ///         `capShare * settlementPrice / 1e18` must pass, and it is exactly the batch that
    ///         leaves `totalSupply() == capShare` — the two forms are the same check.
    function test_settle_capShare_exactlyAtCap_passes() public {
        _giveAliceShares(100_000e6); // 100_000e6 assets / 100_000e18 shares, price 1.0
        _setCapShare(101_000e18);

        uint256 rid = _requestDeposit(bob, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        assertEq(vault.totalSupply(), 101_000e18, "share form: exactly at cap");
        assertEq(vault.totalAssets(), 101_000e6, "AUM form: exactly at capShare * price / 1e18");
    }

    function test_settle_capShare_oneWeiOver_reverts() public {
        _giveAliceShares(100_000e6);
        _setCapShare(101_000e18);

        // One extra wei of USDT mints 1e12 extra shares — a single minimum share unit over the
        // quota is enough to reject the whole batch (净募集额度修改方案 §四 验收要求).
        uint256 rid = _requestDeposit(bob, 1_000e6 + 1);
        _advanceToCalculating();

        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseVault.SupplyCapExceeded.selector, uint256(101_000e18), uint256(101_000e18 + 1e12)
            )
        );
        vault.settle(cycleNumber, _rs1(rid, 1_000e6 + 1), _rs0(), 0);
        vm.stopPrank();
    }

    /// @notice Regression: under the old fixed-USDT cap, pure NAV growth inflated the projected
    ///         AUM and blocked settlement — including the redeem side — even on a cycle whose
    ///         accepted deposits exactly matched its accepted redeems. A share cap has no such
    ///         behaviour: the headroom is re-priced every cycle.
    function test_settle_navGrowth_withMatchedFlows_passes() public {
        uint256 aliceShares = _giveAliceShares(100_000e6);
        _setCapShare(aliceShares); // zero headroom in share terms

        usdt.mint(address(vault), 10_000e6); // +10% adapter yield -> price 1.100000

        uint256 depRid = _requestDeposit(bob, 1_100e6);
        vm.startPrank(alice);
        vault.approve(address(vault), 1_000e18);
        uint256 redRid = vault.requestRedeem(1_000e18, alice);
        vm.stopPrank();
        _reqShares[redRid] = 1_000e18;

        _advanceToCalculating();
        _settle(_arr(depRid), _arr(redRid), 0);

        assertEq(vault.totalSupply(), aliceShares, "1_100e6 in mints exactly what 1_000e18 out burns");
        assertEq(vault.totalAssets(), 110_000e6, "NAV growth is untouched by the cap");
    }

    /// @notice Performance-fee shares do NOT consume subscription quota. No new money arrives
    ///         behind them, so charging them against the raise ceiling would shrink the product's
    ///         real capacity every time it performed well — the whole point of tracking quota
    ///         separately from `totalSupply()` (净募集额度修改方案 §一, §四 验收要求 1).
    function test_settle_performanceFeeSharesDoNotConsumeQuota() public {
        uint256 aliceShares = _giveAliceShares(100_000e6);
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (bob)));
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(2000))));
        _setCapShare(aliceShares); // zero headroom left for any *subscription*

        usdt.mint(address(vault), 10_000e6); // +10% -> 20% of the 10_000e6 profit accrues as shares
        _advanceToCalculating();

        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        assertGt(vault.totalSupply(), aliceShares, "fee shares already minted in Phase A");
        // totalSupply is now above the cap, but quota usage is not: the empty batch settles.
        vault.settle(cycleNumber, _rs0(), _rs0(), 0);
        vm.stopPrank();

        assertGt(vault.totalSupply(), vault.subscriptionCapShare(), "supply exceeds the cap...");
    }

    /// @notice ...and the quota freed by burning fee shares is real: redeeming them releases
    ///         capacity that was never charged, which is why the running total floors at zero
    ///         instead of underflowing (净募集额度修改方案 §3).
    function test_settle_burningFeeSharesReleasesQuotaAndFloorsAtZero() public {
        _giveAliceShares(100_000e6);
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (bob)));
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(2000))));
        _setCapShare(100_000e18);

        usdt.mint(address(vault), 10_000e6);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vm.prank(settlement);
        vault.settle(cycleNumber, _rs0(), _rs0(), 0);
        _completeCycle();

        // Alice redeems everything she holds, plus bob redeems his fee shares: burns exceed the
        // quota ever charged, and the running total must floor rather than revert.
        uint256 all = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(vault), all);
        uint256 redRid = vault.requestRedeem(all, alice);
        vm.stopPrank();

        uint256 feeShares = vault.balanceOf(bob);
        vm.startPrank(bob);
        vault.approve(address(vault), feeShares);
        uint256 feeRid = vault.requestRedeem(feeShares, bob);
        vm.stopPrank();

        _advanceToCalculating();
        uint256 cn2 = sm.currentCycleNumber(address(vault));
        RequestSettlement[] memory reds = new RequestSettlement[](2);
        reds[0] = RequestSettlement({requestId: redRid, settleAmount: all});
        reds[1] = RequestSettlement({requestId: feeRid, settleAmount: feeShares});
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cn2);
        vault.settle(cn2, _rs0(), reds, 0);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 0, "every share burned");
    }

    /// @notice A batch that subscribes and redeems in the same cycle is checked on the NET
    ///         movement, not on the intermediate state after the deposits alone
    ///         (净募集额度修改方案 §4).
    function test_settle_capCheckedOnBatchNetNotIntermediate() public {
        uint256 aliceShares = _giveAliceShares(100_000e6);
        _setCapShare(aliceShares); // exactly full: any un-netted deposit would breach

        uint256 depRid = _requestDeposit(bob, 1_000e6);
        vm.startPrank(alice);
        vault.approve(address(vault), 1_000e18);
        uint256 redRid = vault.requestRedeem(1_000e18, alice);
        vm.stopPrank();
        _reqShares[redRid] = 1_000e18;

        _advanceToCalculating();
        // Deposits are processed before redeems inside settle(), so the mid-batch usage is
        // capShare + 1_000e18. Netting is what lets this through.
        _settle(_arr(depRid), _arr(redRid), 0);

        assertEq(vault.totalSupply(), aliceShares, "net zero");
    }

    /// @notice Partial settlement charges only what was actually accepted and minted — the
    ///         refunded remainder never occupied quota (净募集额度修改方案 §2, §四 验收要求).
    function test_settle_partialFill_chargesOnlyTheAcceptedPart() public {
        uint256 aliceShares = _giveAliceShares(100_000e6);
        // Room for exactly 1_000e18 more shares.
        _setCapShare(aliceShares + 1_000e18);

        // Bob asks for 2_000e6 (= 2_000e18 shares) — double the headroom. Accepting only half
        // fits; if the full request were charged, this would breach.
        uint256 rid = _requestDeposit(bob, 2_000e6);
        _advanceToCalculating();

        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, _rs1(rid, 1_000e6), _rs0(), 0);
        vm.stopPrank();

        assertEq(vault.totalSupply(), aliceShares + 1_000e18, "only the accepted half minted");
        assertEq(usdt.balanceOf(bob), 100_000e6 - 1_000e6, "the unaccepted half was refunded");
    }

    /// @notice Interest arriving as USDT mints no shares, so it consumes no quota at all — the
    ///         vault stays settleable at a full cap (净募集额度修改方案 §四 验收要求 1).
    function test_settle_interestInflowConsumesNoQuota() public {
        uint256 aliceShares = _giveAliceShares(100_000e6);
        _setCapShare(aliceShares); // exactly full

        usdt.mint(address(vault), 50_000e6); // +50% interest, no shares minted
        _advanceToCalculating();

        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, _rs0(), _rs0(), 0);
        vm.stopPrank();

        assertEq(vault.totalSupply(), aliceShares, "supply untouched by interest");
    }

    /// @notice capShare == 0 keeps meaning "no limit" under the quota rule.
    function test_settle_zeroCapShareImposesNoLimit() public {
        _giveAliceShares(100_000e6);
        _setCapShare(0);

        uint256 rid = _requestDeposit(bob, 50_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        assertGt(vault.totalSupply(), 100_000e18, "settles with no ceiling");
    }

    // --- setSubscriptionCapShare access control ---

    /// @dev A fresh, still-CONFIGURING vault.
    function _newConfiguringVault() internal returns (EarnVault v) {
        v = new EarnVault("Cap Cfg", "htCFG", address(usdt), address(sm), address(queue), governor, address(0));
        vm.prank(factory);
        sm.registerVault(address(v));
        vm.prank(governor);
        v.setCurator(curator);
    }

    /// @dev The initial cap is set by the Curator in one shot, through
    ///      `StateManager.setProductParams`, which pushes it into the vault — the Curator never
    ///      calls the vault directly for it (募集上限参数调整建议 §2, §3).
    function test_initSubscriptionCapShare_setViaProductParams() public {
        EarnVault v = _newConfiguringVault();
        ProductParams memory p = _defaultParams();
        p.subscriptionCapShare = 500e18;

        vm.expectEmit(false, false, false, true, address(v));
        emit IBaseVault.SubscriptionCapShareUpdated(0, 500e18, block.timestamp);
        vm.prank(curator);
        sm.setProductParams(address(v), p);

        assertEq(v.subscriptionCapShare(), 500e18);
    }

    /// @dev 0 keeps its "no cap" meaning.
    function test_initSubscriptionCapShare_zeroMeansUnlimited() public {
        EarnVault v = _newConfiguringVault();
        ProductParams memory p = _defaultParams();
        p.subscriptionCapShare = 0;
        vm.prank(curator);
        sm.setProductParams(address(v), p);
        assertEq(v.subscriptionCapShare(), 0);
    }

    /// @dev Only that vault's own StateManager may initialise the cap.
    function test_initSubscriptionCapShare_revertsForNonStateManager() public {
        EarnVault v = _newConfiguringVault();
        vm.prank(curator);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        v.initSubscriptionCapShare(500e18);
    }

    /// @dev And only while CONFIGURING — once the product has moved on, StateManager loses the
    ///      right to touch the cap and every later change is a Timelock action.
    function test_initSubscriptionCapShare_revertsAfterConfiguring() public {
        vm.prank(address(sm));
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.initSubscriptionCapShare(500e18);
    }

    function test_setSubscriptionCapShare_curatorDirect_reverts() public {
        vm.prank(curator);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setSubscriptionCapShare(500e18);
    }

    function test_setSubscriptionCapShare_timelockSucceeds() public {
        vm.prank(address(tl));
        vault.setSubscriptionCapShare(500e18);
        assertEq(vault.subscriptionCapShare(), 500e18);
    }

    function test_setSubscriptionCapShare_timelock_succeedsAfterConfiguring() public {
        vm.prank(address(tl));
        vault.setSubscriptionCapShare(500e18);
        assertEq(vault.subscriptionCapShare(), 500e18);
    }

    function test_setSubscriptionCapShare_randomAddress_alwaysReverts() public {
        EarnVault v = _newConfiguringVault();
        vm.prank(alice);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        v.setSubscriptionCapShare(500e18);

        vm.prank(alice);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setSubscriptionCapShare(500e18);
    }

    function test_settle_reverts_when_vault_paused() public {
        uint256 assets = 1_000e6;
        uint256 rid = _requestDeposit(alice, assets);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        vm.prank(guardian);
        sm.pause(address(vault), PauseState.PAUSED_BY_GUARDIAN);

        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.VaultPausedError.selector, address(vault), PauseState.PAUSED_BY_GUARDIAN
            )
        );
        vault.settle(cycleNumber, _rs1(rid, 1_000e6), _rs0(), 0);
    }

    // -----------------------------------------------------------------------
    // Pause coverage — every value-out and share-movement path (审计反馈 2026-08-17 #4)
    // -----------------------------------------------------------------------

    function _pause() internal {
        vm.prank(guardian);
        sm.pause(address(vault), PauseState.PAUSED_BY_GUARDIAN);
    }

    function _pausedRevert() internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                IStateManager.VaultPausedError.selector, address(vault), PauseState.PAUSED_BY_GUARDIAN
            );
    }

    /// @dev A Guardian pause exists to stop withdrawals against a price believed to be wrong. It
    ///      only does that if the claim of an already-settled redemption is frozen too.
    function test_pause_blocksClaimRedeem() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, _rs0(), _rs1(redeemId, shares), 0);
        vm.stopPrank();
        _completeCycle();

        _pause();
        vm.prank(alice);
        vm.expectRevert(_pausedRevert());
        vault.claimRedeem(redeemId, alice);
    }

    function test_pause_blocksClaimDeposit() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        _pause();
        vm.prank(alice);
        vm.expectRevert(_pausedRevert());
        vault.claimDeposit(rid, alice);
    }

    function test_pause_blocksCancelRequest() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _pause();
        vm.prank(alice);
        vm.expectRevert(_pausedRevert());
        vault.cancelRequest(rid);
    }

    function test_pause_blocksShareTransfer() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);
        uint256 shares = vault.balanceOf(alice);

        _pause();
        vm.prank(alice);
        vm.expectRevert(_pausedRevert());
        vault.transfer(bob, shares);
    }

    function test_pause_blocksShareTransferFrom() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.approve(bob, shares);

        _pause();
        vm.prank(bob);
        vm.expectRevert(_pausedRevert());
        vault.transferFrom(alice, bob, shares);
    }

    function test_pause_blocksClaimRefund() public {
        (EarnVault v,) = _makeFundingFailedVault();
        uint256 rid = v.nextRequestId() - 1;
        vm.prank(governor);
        v.setGuardian(guardian);
        vm.prank(curator);
        v.markRefundable(_arr(rid));

        vm.prank(guardian);
        sm.pause(address(v), PauseState.PAUSED_BY_GUARDIAN);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IStateManager.VaultPausedError.selector, address(v), PauseState.PAUSED_BY_GUARDIAN)
        );
        v.claimRefund(rid);
    }

    function test_pause_blocksSnapshotSettlementPrice() public {
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        _pause();
        vm.prank(settlement);
        vm.expectRevert(_pausedRevert());
        vault.snapshotSettlementPrice(cycleNumber);
    }

    // -----------------------------------------------------------------------
    // Insolvency write-down (审计反馈 2026-08-17 #3)
    // -----------------------------------------------------------------------

    /// @notice PENDING subscriptions are no longer an eligible write-down target at all. That
    ///         money is unsettled, has minted no shares and never reached an Adapter — it is a
    ///         protected liability its owner may still cancel and be refunded in full, so it must
    ///         not absorb portfolio losses (审计报告（一）回复 §2). Ordinary losses reach the
    ///         people who actually bear them through NAV instead.
    function test_writeDownInsolvency_cannotTouchPendingDeposits() public {
        _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        uint256 pendingBefore = vault.pendingDepositLiability();
        _simulateLoss(101_000e6 - 500e6);

        // And with the pending pass gone there is nothing eligible to haircut here at all, so
        // the recovery call cannot clear the deficit and reverts InsufficientWriteDown.
        vm.prank(governor);
        bytes32 id =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.writeDownInsolvency, (new uint256[](0))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);

        assertEq(vault.pendingDepositLiability(), pendingBefore, "pending subscriptions untouched");
    }

    // -----------------------------------------------------------------------
    // Adapter / UnifiedPool wiring
    // -----------------------------------------------------------------------

    function test_setUnifiedPool_by_non_governor_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setUnifiedPool(alice);
    }

    function test_setUnifiedPool_by_governor_succeeds() public {
        // Vault is already past CONFIGURING — setUnifiedPool is Timelock-only now.
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setUnifiedPool, (alice)));
        assertEq(vault.unifiedPool(), alice);
    }

    /// @dev Swapping pools with a balance left behind would drop that receivable out of NAV in
    ///      one step and strand the cash in the old pool (审计反馈 2026-08-17 #6).
    function test_setUnifiedPool_revertsWhileOldPoolStillOwesThisVault() public {
        StubPool oldPool = new StubPool();
        StubPool newPool = new StubPool();
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setUnifiedPool, (address(oldPool))));

        oldPool.setPending(address(vault), 500e6);
        vm.prank(governor);
        bytes32 id =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setUnifiedPool, (address(newPool))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);

        // Drained back to the vault, the swap goes through.
        oldPool.setPending(address(vault), 0);
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setUnifiedPool, (address(newPool))));
        assertEq(vault.unifiedPool(), address(newPool));
    }

    function test_addAdapter_revertsIfRealAssetsReverts() public {
        // Create a fresh vault in CONFIGURING state to test direct call (not through Timelock)
        EarnVault testVault =
            new EarnVault("Test Vault", "tVault", address(usdt), address(sm), address(queue), governor, address(0));
        vm.prank(factory);
        sm.registerVault(address(testVault));

        vm.prank(governor);
        testVault.setCurator(curator);
        vm.prank(factory);
        testVault.bindGovernance(address(tl));

        RevertingRealAssetsAdapter badAdapter = new RevertingRealAssetsAdapter(address(testVault));

        vm.prank(curator);
        vm.expectRevert("malformed adapter");
        testVault.addAdapter(address(badAdapter));
    }

    // -----------------------------------------------------------------------
    // setGate
    // -----------------------------------------------------------------------

    function test_setGate_by_governor() public {
        AllowAllGate g = new AllowAllGate();
        // Vault is already past CONFIGURING — setGate is Timelock-only now.
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setGate, (address(g))));
        assertEq(vault.gate(), address(g));
    }

    function test_setGate_by_non_governor_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setGate(alice);
    }

    // -----------------------------------------------------------------------
    // setSettlement
    // -----------------------------------------------------------------------

    // NOTE: SettlementAlreadySet was removed in the redesign — setSettlement may now be called
    // again to replace an already-set settlement, subject to the same CONFIGURING/Timelock
    // gating and the new CycleState.CALCULATING/FULFILLING guard. Split into two tests below.

    function test_setSettlement_replaceable_viaTimelock() public {
        // Vault is already past CONFIGURING (setUp opened subscription) — route through
        // VaultTimelock. A second call to setSettlement no longer reverts.
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setSettlement, (alice)));
        assertEq(vault.settlement(), alice);
    }

    function test_setSettlement_revertsDuringActiveCycle() public {
        // finalizeSubscription drops the vault straight into cycle 0's CALCULATING window, which
        // setSettlement blocks regardless of the CONFIGURING/Timelock gating.
        _advanceToCalculating();
        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.CALCULATING));

        vm.prank(address(tl));
        vm.expectRevert(
            abi.encodeWithSelector(IBaseVault.SettlementChangeDuringActiveCycle.selector, CycleState.CALCULATING)
        );
        vault.setSettlement(settlement);
    }

    // -----------------------------------------------------------------------
    // Sync ERC-4626 deposit (EarnVault specific)
    // -----------------------------------------------------------------------

    function test_syncDeposit_only_liquidityBridge() public {
        // vault has no liquidityBridge set (address(0))
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEarnVault.OnlyLiquidityBridge.selector, alice));
        vault.deposit(1_000e6, alice);
    }

    function test_syncDeposit_with_liquidityBridge() public {
        address lb = makeAddr("lb");
        EarnVault v = new EarnVault("Cash", "htCASH", address(usdt), address(sm), address(queue), governor, lb);
        vm.prank(factory);
        sm.registerVault(address(v));

        uint256 assets = 1_000e6;
        usdt.mint(lb, assets);
        vm.startPrank(lb);
        usdt.approve(address(v), assets);
        uint256 shares = v.deposit(assets, alice);
        vm.stopPrank();

        assertEq(shares, _sharesFor(assets));
        assertEq(v.balanceOf(alice), shares);
    }

    // -----------------------------------------------------------------------
    // markRefundable — Curator-only (moved off Keeper)
    // -----------------------------------------------------------------------

    function _makeFundingFailedVault() internal returns (EarnVault v, ProductParams memory p) {
        v = new EarnVault("Refund Test", "htREF", address(usdt), address(sm), address(queue), governor, address(0));
        vm.prank(factory);
        sm.registerVault(address(v));

        vm.startPrank(governor);
        v.setCurator(curator);
        v.setKeeper(keeper, true);
        vm.stopPrank();

        p = _defaultParams();
        p.minRaiseAmount = 100_000e6; // deliberately never met below
        vm.prank(curator);
        sm.setProductParams(address(v), p);

        vm.prank(keeper);
        sm.openSubscription(address(v));

        // Small deposit, well under minRaiseAmount. Alice already has 100_000e6 from setUp.
        vm.startPrank(alice);
        usdt.approve(address(v), 1_000e6);
        v.requestDeposit(1_000e6, alice);
        vm.stopPrank();

        vm.warp(p.subscriptionEnd + 1);
        vm.prank(keeper);
        sm.finalizeSubscription(address(v));
        assertEq(uint8(sm.getProductState(address(v))), uint8(ProductState.FUNDING_FAILED));
    }

    function test_markRefundable_revertsForKeeper() public {
        (EarnVault v,) = _makeFundingFailedVault();
        uint256[] memory ids = new uint256[](1);
        ids[0] = v.nextRequestId() - 1;

        vm.prank(keeper);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        v.markRefundable(ids);
    }

    function test_markRefundable_revertsForRandomCaller() public {
        (EarnVault v,) = _makeFundingFailedVault();
        uint256[] memory ids = new uint256[](1);
        ids[0] = v.nextRequestId() - 1;

        vm.prank(alice);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        v.markRefundable(ids);
    }

    function test_markRefundable_curatorSucceeds() public {
        (EarnVault v,) = _makeFundingFailedVault();
        uint256 rid = v.nextRequestId() - 1;
        uint256[] memory ids = new uint256[](1);
        ids[0] = rid;

        assertEq(v.pendingDepositLiability(), 1_000e6);
        assertEq(v.refundableLiability(), 0);

        vm.prank(curator);
        v.markRefundable(ids);

        assertEq(v.pendingDepositLiability(), 0);
        assertEq(v.refundableLiability(), 1_000e6);

        // A REFUNDABLE request can now be refunded; a still-PENDING one could not (proves the
        // state actually flipped, without needing a dedicated field getter).
        vm.prank(alice);
        v.claimRefund(rid);
        assertEq(usdt.balanceOf(alice), 100_000e6); // alice started with 100_000e6, spent 1_000e6, got it back
    }

    function test_markRefundable_emitsDepositMarkedRefundable() public {
        (EarnVault v,) = _makeFundingFailedVault();
        uint256 rid = v.nextRequestId() - 1;
        uint256[] memory ids = new uint256[](1);
        ids[0] = rid;

        vm.expectEmit(true, true, false, true, address(v));
        emit IBaseVault.DepositMarkedRefundable(rid, alice, 1_000e6, block.timestamp);
        vm.prank(curator);
        v.markRefundable(ids);
    }

    function test_markRefundable_skippedRequestEmitsNothing() public {
        (EarnVault v,) = _makeFundingFailedVault();
        uint256 rid = v.nextRequestId() - 1;
        uint256[] memory ids = new uint256[](1);
        ids[0] = rid;

        // First pass flips PENDING -> REFUNDABLE.
        vm.prank(curator);
        v.markRefundable(ids);

        // Second pass hits the `req.state == PENDING` guard and must be a no-op — no event.
        vm.recordLogs();
        vm.prank(curator);
        v.markRefundable(ids);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IBaseVault.DepositMarkedRefundable.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != topic, "skipped request must not emit DepositMarkedRefundable");
        }
    }

    // -----------------------------------------------------------------------
    // returnPrincipalToPool
    // -----------------------------------------------------------------------

    /// @notice Points `vault`'s settlement at a fresh MockSettlementOperator and approves
    ///         `settlement` (the plain EOA from setUp) as that vault's Settlement Operator, so
    ///         `vm.prank(settlement)` satisfies `_onlySettlementOperator()`'s real
    ///         `ISettlement(vault.settlement()).isOperator(vault, msg.sender)` check.
    function _wireSettlementOperator() internal {
        MockSettlementOperator mockSettlement = new MockSettlementOperator();
        // Subscription is already open at this point (post-setUp), so setSettlement is a
        // VaultTimelock-only OWNER action, not a direct-owner call.
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setSettlement, (address(mockSettlement))));
        mockSettlement.setOperator(address(vault), settlement, true);
    }

    function test_returnPrincipalToPool_revertsIfUnifiedPoolNotSet() public {
        _wireSettlementOperator();
        usdt.mint(address(vault), 100e6);

        vm.prank(settlement);
        vm.expectRevert(IBaseVault.UnifiedPoolNotSet.selector);
        vault.returnPrincipalToPool(100e6);
    }

    function test_returnPrincipalToPool_movesUSDTAndCreditsPending() public {
        _wireSettlementOperator();

        // Wire a real UnifiedPool for this one test.
        UnifiedPool poolImpl = new UnifiedPool();
        bytes memory initData = abi.encodeCall(UnifiedPool.initialize, (address(usdt), address(sm), address(ac)));
        UnifiedPool pool = UnifiedPool(address(new ERC1967Proxy(address(poolImpl), initData)));

        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setUnifiedPool, (address(pool))));

        vm.prank(governor); // vault's Owner == this pool's expected addVault caller
        pool.addVault(address(vault));
        vm.startPrank(governor); // and the protocol Governor admitting it (审计反馈 V3 #1/#2)
        pool.setVaultWhitelisted(address(vault), true);
        pool.setSettlementWhitelisted(vault.settlement(), true);
        vm.stopPrank();

        usdt.mint(address(vault), 5_000e6);

        vm.prank(settlement); // this vault's Settlement Operator (see _wireSettlementOperator)
        vault.returnPrincipalToPool(3_000e6);

        assertEq(pool.pending(address(vault)), 3_000e6);
        assertEq(usdt.balanceOf(address(vault)), 2_000e6);
        assertEq(usdt.balanceOf(address(pool)), 3_000e6);
    }

    function test_returnPrincipalToPool_revertsIfExceedsFreeUSDT() public {
        _wireSettlementOperator();

        UnifiedPool poolImpl = new UnifiedPool();
        bytes memory initData = abi.encodeCall(UnifiedPool.initialize, (address(usdt), address(sm), address(ac)));
        UnifiedPool pool = UnifiedPool(address(new ERC1967Proxy(address(poolImpl), initData)));
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.setUnifiedPool, (address(pool))));

        usdt.mint(address(vault), 100e6);

        // freeVaultUSDT() is exactly the 100e6 just minted (no pending/reserved/refundable
        // liabilities on this vault at this point), so the args are fully determined.
        assertEq(vault.freeVaultUSDT(), 100e6);
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(IBaseVault.InsufficientFreeUSDT.selector, uint256(101e6), uint256(100e6))
        );
        vault.returnPrincipalToPool(101e6);
    }

    // -----------------------------------------------------------------------
    // Overdue claim registration (Audit Feedback V2 #11)
    // -----------------------------------------------------------------------

    function _wireClaimRegistry(uint256 gracePeriod) internal returns (ClaimRegistry reg) {
        reg = new ClaimRegistry(address(sm));
        _scheduleAndExecute(governor, abi.encodeCall(IBaseVault.configureClaimRegistry, (address(reg), gracePeriod)));
    }

    /// @dev Settles a deposit and leaves it unclaimed, then warps past maturity + grace.
    function _overdueSettledDeposit() internal returns (uint256 rid) {
        _seedFirstCycle();
        rid = _requestDeposit(alice, 10_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.warp(_defaultParams().maturityTimestamp + 30 days + 1);
    }

    function test_recordOverdueClaims_revertsWhenRegistryNotConfigured() public {
        vm.expectRevert(IBaseVault.ClaimRegistryNotConfigured.selector);
        vault.recordOverdueClaims(_arr(1));
    }

    function test_recordOverdueClaims_revertsBeforeGracePeriodElapses() public {
        ClaimRegistry reg = _wireClaimRegistry(30 days);
        reg;
        uint256 dueFrom = _defaultParams().maturityTimestamp + 30 days;
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.ClaimGracePeriodNotElapsed.selector, dueFrom));
        vault.recordOverdueClaims(_arr(1));
    }

    /// @dev The audit's actual complaint: `recordClaim`'s `msg.sender == vault` branch was dead
    ///      because nothing on-chain ever called it, leaving the backstop register entirely
    ///      dependent on the Curator acting by hand.
    function test_recordOverdueClaims_vaultItselfRecordsUnclaimedDeposit() public {
        uint256 rid = _overdueSettledDeposit();
        ClaimRegistry reg = _wireClaimRegistry(30 days);

        vault.recordOverdueClaims(_arr(rid));

        assertEq(reg.getClaimCount(), 1);
        IClaimRegistry.ClaimRecord memory rec = reg.getClaim(0);
        assertEq(rec.vault, address(vault));
        assertEq(rec.owner, alice);
        assertEq(rec.requestId, rid);
        assertEq(uint8(rec.kind), uint8(IClaimRegistry.ClaimKind.DEPOSIT_REFUND));
        assertTrue(vault.claimRecorded(rid));
    }

    function test_recordOverdueClaims_isIdempotent() public {
        uint256 rid = _overdueSettledDeposit();
        ClaimRegistry reg = _wireClaimRegistry(30 days);

        vault.recordOverdueClaims(_arr(rid));
        vault.recordOverdueClaims(_arr(rid));

        assertEq(reg.getClaimCount(), 1, "duplicate record written for the same request");
    }

    /// @dev Requests that are terminal, already claimed, or still awaiting settlement carry no
    ///      unclaimed balance and must be skipped rather than reverting the whole batch.
    function test_recordOverdueClaims_skipsRequestsWithNothingOutstanding() public {
        _seedFirstCycle();
        uint256 settledRid = _requestDeposit(alice, 10_000e6);
        uint256 pendingRid = _requestDeposit(bob, 10_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(settledRid));

        vm.prank(alice);
        vault.claimDeposit(settledRid, alice);

        vm.warp(_defaultParams().maturityTimestamp + 30 days + 1);
        ClaimRegistry reg = _wireClaimRegistry(30 days);

        uint256[] memory ids = new uint256[](3);
        ids[0] = settledRid; // CLAIMED — terminal
        ids[1] = pendingRid; // PENDING — not yet settled
        ids[2] = 9_999; // never existed
        vault.recordOverdueClaims(ids);

        assertEq(reg.getClaimCount(), 0);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _defaultParams() internal view returns (ProductParams memory) {
        return ProductParams({
            subscriptionStart: NOW,
            subscriptionEnd: NOW + 7 days,
            walletSubscriptionCap: 100_000e6,
            minRaiseAmount: 100_000e6,
            subscriptionCapShare: 0,
            cycleDuration: 7 days,
            maturityTimestamp: NOW + 365 days,
            claimingStart: NOW + 370 days,
            claimingEnd: NOW + 400 days,
            feeParams: 0
        });
    }

    function _sharesFor(uint256 assets) internal pure returns (uint256) {
        return assets * SHARE_SCALE / PRICE_ONE;
    }

    function _assetsFor(uint256 shares) internal pure returns (uint256) {
        return shares * PRICE_ONE / SHARE_SCALE;
    }

    function _requestDeposit(address user, uint256 amount) internal returns (uint256) {
        vm.startPrank(user);
        usdt.approve(address(vault), amount);
        uint256 rid = vault.requestDeposit(amount, user);
        vm.stopPrank();
        _reqAssets[rid] = amount;
        return rid;
    }

    function _advanceToCalculating() internal {
        ProductParams memory p = sm.getParams(address(vault));

        if (uint8(sm.getProductState(address(vault))) == uint8(ProductState.SUBSCRIBING)) {
            // Warp past subscriptionEnd + cycleDuration so both checks pass
            uint256 target = p.subscriptionEnd + p.cycleDuration + 1;
            if (block.timestamp < target) vm.warp(target);
            // Use a dedicated funder to meet minRaiseAmount without hitting alice's wallet cap
            if (sm.totalSubscribed(address(vault)) < p.minRaiseAmount) {
                address funder = makeAddr("funder2");
                usdt.mint(funder, p.minRaiseAmount);
                vm.startPrank(funder);
                usdt.approve(address(vault), p.minRaiseAmount);
                uint256 fRid = vault.requestDeposit(p.minRaiseAmount, funder);
                vm.stopPrank();
                _reqAssets[fRid] = p.minRaiseAmount;
            }
            vm.prank(keeper);
            sm.finalizeSubscription(address(vault));
        }

        if (
            uint8(sm.getProductState(address(vault))) == uint8(ProductState.OPERATING)
                && uint8(sm.getCycleState(address(vault))) == uint8(CycleState.ACCEPTING)
        ) {
            // Warp past current cycle start + cycleDuration
            uint256 cycleStart = sm.currentCycleStart(address(vault));
            uint256 target = cycleStart + p.cycleDuration + 1;
            if (block.timestamp < target) vm.warp(target);
            vm.prank(keeper);
            sm.startCycleCalculation(address(vault));
        }
    }

    /// @notice Clears the vault's initial SUBSCRIBING-phase raise (via funder2, as
    ///         _advanceToCalculating() already does) and settles/completes that cycle, so the
    ///         vault lands in OPERATING+ACCEPTING for cycle 2. StateManager.recordSubscription
    ///         only enforces walletSubscriptionCap while SUBSCRIBING — tests that need a single
    ///         deposit above that per-wallet cap must run it in a later, already-OPERATING
    ///         cycle, which this sets up.
    function _seedFirstCycle() internal {
        _advanceToCalculating();
        uint256 funderRid = vault.nextRequestId() - 1;
        _settleDeposits(_arr(funderRid));
    }

    function _completeCycle() internal {
        vm.prank(settlement);
        sm.completeCycle(address(vault));
    }

    function _settle(uint256[] memory depIds, uint256[] memory redeemIds, uint256 poolDistributedAssets) internal {
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, _toDeposits(depIds), _toRedeems(redeemIds), poolDistributedAssets);
        vm.stopPrank();
        _completeCycle();
    }

    function _settleDeposits(uint256[] memory depIds) internal {
        _settle(depIds, new uint256[](0), 0);
    }

    function _settleRedeems(uint256[] memory redeemIds, uint256 poolDistributedAssets) internal {
        _settle(new uint256[](0), redeemIds, poolDistributedAssets);
    }

    function _arr(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _toDeposits(uint256[] memory ids) internal view returns (RequestSettlement[] memory out) {
        out = new RequestSettlement[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            out[i] = RequestSettlement({requestId: ids[i], settleAmount: _reqAssets[ids[i]]});
        }
    }

    function _toRedeems(uint256[] memory ids) internal view returns (RequestSettlement[] memory out) {
        out = new RequestSettlement[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            out[i] = RequestSettlement({requestId: ids[i], settleAmount: _reqShares[ids[i]]});
        }
    }

    function _rs1(uint256 id, uint256 amount) internal pure returns (RequestSettlement[] memory out) {
        out = new RequestSettlement[](1);
        out[0] = RequestSettlement({requestId: id, settleAmount: amount});
    }

    function _rs0() internal pure returns (RequestSettlement[] memory) {
        return new RequestSettlement[](0);
    }

    // -----------------------------------------------------------------------
    // Request getters
    //
    // `nextRequestId` was public but the request mappings were `internal` with no accessor, so a
    // caller could learn how many requests existed and read none of them. Front-ends need the
    // per-request state to gate claim/refund actions.
    // -----------------------------------------------------------------------

    function test_getDepositRequest_returnsStoredFields() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);

        IBaseVault.DepositRequest memory req = vault.getDepositRequest(rid);

        assertEq(req.owner, alice);
        assertEq(req.assets, 1_000e6);
        assertEq(req.settledShares, 0);
        assertEq(uint8(req.state), uint8(DepositRequestState.PENDING));
    }

    function test_getDepositRequest_unknownIdReturnsNoneState() public view {
        IBaseVault.DepositRequest memory req = vault.getDepositRequest(999_999);

        assertEq(req.owner, address(0));
        assertEq(req.assets, 0);
        assertEq(uint8(req.state), uint8(DepositRequestState.NONE));
    }

    function test_getDepositRequest_tracksStateThroughCancel() public {
        uint256 rid = _requestDeposit(alice, 1_000e6);

        vm.prank(alice);
        vault.cancelRequest(rid);

        IBaseVault.DepositRequest memory req = vault.getDepositRequest(rid);
        assertEq(uint8(req.state), uint8(DepositRequestState.CANCELLED));
        assertEq(req.owner, alice, "owner survives cancellation");
    }

    function test_getDepositRequest_reportsSettledSharesAndCycle() public {
        uint256 assets = 1_000e6;
        uint256 rid = _requestDeposit(alice, assets);
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        _settleDeposits(_arr(rid));

        IBaseVault.DepositRequest memory req = vault.getDepositRequest(rid);
        assertEq(uint8(req.state), uint8(DepositRequestState.SETTLED));
        assertEq(req.settledShares, _sharesFor(assets));
        assertEq(req.cycleNumber, cycleNumber);
        assertEq(req.assets, assets, "original request size is preserved after settlement");
    }

    // -----------------------------------------------------------------------
    // IVaultRoles — Owner-appointed vault-local roles
    // -----------------------------------------------------------------------

    function test_transferOwnership_movesOwnerAndRevokesOldOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(true, true, true, true, address(vault));
        emit IVaultRoles.OwnerTransferred(address(vault), governor, newOwner, block.timestamp);
        vm.prank(governor);
        vault.transferOwnership(newOwner);

        assertEq(vault.owner(), newOwner);

        // The old Owner is now just an address.
        vm.prank(governor);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setCurator(alice);

        vm.prank(newOwner);
        vault.setCurator(alice);
        assertEq(vault.curator(), alice);
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.transferOwnership(alice);
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.prank(governor);
        vm.expectRevert(IBaseVault.ZeroAddress.selector);
        vault.transferOwnership(address(0));
    }

    function test_setCurator_setGuardian_setAllocator_ownerOnly() public {
        address newCurator = makeAddr("c2");
        address newGuardian = makeAddr("g2");
        address newAllocator = makeAddr("a2");

        vm.startPrank(alice);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setCurator(newCurator);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setGuardian(newGuardian);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setAllocator(newAllocator);
        vm.stopPrank();

        vm.startPrank(governor);
        vault.setCurator(newCurator);
        vault.setGuardian(newGuardian);
        vault.setAllocator(newAllocator);
        vm.stopPrank();

        assertEq(vault.curator(), newCurator);
        assertEq(vault.guardian(), newGuardian);
        assertEq(vault.allocator(), newAllocator);
    }

    function test_setKeeper_grantsAndRevokes() public {
        address k2 = makeAddr("k2");
        assertFalse(vault.isKeeper(k2));

        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultRoles.KeeperSet(address(vault), k2, true, block.timestamp);
        vm.prank(governor);
        vault.setKeeper(k2, true);
        assertTrue(vault.isKeeper(k2));

        vm.prank(governor);
        vault.setKeeper(k2, false);
        assertFalse(vault.isKeeper(k2));
    }

    function test_setKeeper_revertsForNonOwner() public {
        vm.prank(curator);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.setKeeper(alice, true);
    }

    /// @dev The Keeper grant is what StateManager's `onlyVaultKeeper` reads, so revoking it must
    ///      actually stop the lifecycle calls — not just flip a flag.
    function test_setKeeper_revokedKeeperCannotDriveLifecycle() public {
        vm.prank(governor);
        vault.setKeeper(keeper, false);

        vm.warp(_defaultParams().subscriptionEnd + _defaultParams().cycleDuration + 1);
        vm.prank(keeper);
        vm.expectRevert(IStateManager.NotKeeper.selector);
        sm.finalizeSubscription(address(vault));
    }

    function test_bindGovernance_cannotBeRebound() public {
        vm.prank(factory);
        vm.expectRevert(IBaseVault.GovernanceAlreadyBound.selector);
        vault.bindGovernance(makeAddr("otherTimelock"));
    }

    function test_bindGovernance_revertsOnZeroArgs() public {
        EarnVault fresh =
            new EarnVault("Fresh", "FRSH", address(usdt), address(sm), address(queue), governor, address(0));
        vm.prank(factory);
        vm.expectRevert(IBaseVault.ZeroAddress.selector);
        fresh.bindGovernance(address(0));
    }

    /// @dev Governance binding is gated to the one VaultFactory wired into StateManager, not
    ///      merely to "not yet bound" — otherwise any non-atomic deploy window lets an attacker
    ///      front-run the bind with a timelock they control (审计反馈 2026-08-17 #9).
    function test_bindGovernance_revertsForNonFactory() public {
        EarnVault fresh =
            new EarnVault("Fresh", "FRSH", address(usdt), address(sm), address(queue), governor, address(0));
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        fresh.bindGovernance(makeAddr("attackerTimelock"));
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(IBaseVault.ZeroAddress.selector);
        new EarnVault("z", "z", address(0), address(sm), address(queue), governor, address(0));

        vm.expectRevert(IBaseVault.ZeroAddress.selector);
        new EarnVault("z", "z", address(usdt), address(0), address(queue), governor, address(0));

        vm.expectRevert(IBaseVault.ZeroAddress.selector);
        new EarnVault("z", "z", address(usdt), address(sm), address(0), governor, address(0));

        vm.expectRevert(IBaseVault.ZeroAddress.selector);
        new EarnVault("z", "z", address(usdt), address(sm), address(queue), address(0), address(0));
    }

    // -----------------------------------------------------------------------
    // ERC-20 share surface (approve / allowance / transferFrom)
    // -----------------------------------------------------------------------

    /// @dev Gives alice real shares through the deposit → settle → claim path (never by
    ///      minting or dealing them), so every ERC-20 assertion below runs on shares the
    ///      protocol actually issued.
    function _giveAliceShares(uint256 assets) internal returns (uint256 shares) {
        uint256 rid = _requestDeposit(alice, assets);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        shares = vault.claimDeposit(rid, alice);
    }

    function test_approve_setsAllowanceAndEmits() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit BaseVault.Approval(alice, bob, 123e18);
        vm.prank(alice);
        assertTrue(vault.approve(bob, 123e18));

        assertEq(vault.allowance(alice, bob), 123e18);
        assertEq(vault.allowance(bob, alice), 0, "allowance is directional");
    }

    function test_transferFrom_spendsAllowance() public {
        uint256 shares = _giveAliceShares(1_000e6);

        vm.prank(alice);
        vault.approve(bob, shares);

        vm.prank(bob);
        assertTrue(vault.transferFrom(alice, bob, shares / 4));

        assertEq(vault.balanceOf(bob), shares / 4);
        assertEq(vault.balanceOf(alice), shares - shares / 4);
        assertEq(vault.allowance(alice, bob), shares - shares / 4);
    }

    function test_transferFrom_insufficientAllowanceReverts() public {
        uint256 shares = _giveAliceShares(1_000e6);

        vm.prank(alice);
        vault.approve(bob, 10);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(BaseVault.InsufficientAllowance.selector, alice, bob, uint256(10), shares)
        );
        vault.transferFrom(alice, bob, shares);
    }

    function test_transferFrom_infiniteAllowanceNotDecremented() public {
        uint256 shares = _giveAliceShares(1_000e6);

        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vault.transferFrom(alice, bob, shares);

        assertEq(vault.allowance(alice, bob), type(uint256).max);
        assertEq(vault.balanceOf(bob), shares);
    }

    function test_transfer_insufficientSharesReverts() public {
        uint256 shares = _giveAliceShares(1_000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.InsufficientShares.selector, alice, shares, shares + 1));
        vault.transfer(bob, shares + 1);
    }

    function test_transfer_movesSharesWithoutChangingSupply() public {
        uint256 shares = _giveAliceShares(1_000e6);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(alice);
        vault.transfer(bob, shares);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), shares);
        assertEq(vault.totalSupply(), supplyBefore);
    }

    // -----------------------------------------------------------------------
    // ERC-7540 operator approval
    // -----------------------------------------------------------------------

    function test_setOperator_letsOperatorActOnOwnersBehalf() public {
        assertFalse(vault.isOperator(alice, bob));
        vm.prank(alice);
        vault.setOperator(bob, true);
        assertTrue(vault.isOperator(alice, bob));

        // bob funds and submits a deposit request whose `owner` is alice.
        usdt.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdt.approve(address(vault), 1_000e6);
        uint256 rid = vault.requestDeposit(1_000e6, alice);
        vm.stopPrank();
        _reqAssets[rid] = 1_000e6; // the request bypassed _requestDeposit's bookkeeping

        assertEq(vault.pendingDepositByOwner(alice), 1_000e6, "request is booked against alice");

        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        // ...and bob may claim it, delivering the shares wherever alice's operator directs.
        vm.prank(bob);
        uint256 shares = vault.claimDeposit(rid, alice);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_setOperator_revokedOperatorIsRejected() public {
        vm.prank(alice);
        vault.setOperator(bob, true);
        vm.prank(alice);
        vault.setOperator(bob, false);
        assertFalse(vault.isOperator(alice, bob));

        usdt.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdt.approve(address(vault), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.NotOwnerOrOperator.selector, bob, alice));
        vault.requestDeposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_requestDeposit_forAnotherOwnerWithoutApprovalReverts() public {
        usdt.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdt.approve(address(vault), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.NotOwnerOrOperator.selector, bob, alice));
        vault.requestDeposit(1_000e6, alice);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // addAdapter / removeAdapter
    // -----------------------------------------------------------------------

    /// @dev Registers a fresh FirstPeriodAdapter on `vault`. The vault is past CONFIGURING by
    ///      the end of setUp, so addAdapter is VaultTimelock-only.
    function _addAdapter() internal returns (FirstPeriodAdapter a) {
        a = new FirstPeriodAdapter(usdt, address(vault), 36 hours);
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.addAdapter, (address(a))));
    }

    function test_addAdapter_registersAndCountsTowardGrossAssets() public {
        FirstPeriodAdapter a = _addAdapter();
        assertTrue(vault.isAdapter(address(a)));
        assertEq(vault.adapters(0), address(a));

        // Idle adapter balance is part of grossManagedAssets via realAssets().
        usdt.mint(address(a), 5_000e6);
        assertEq(a.realAssets(), 5_000e6);
        assertEq(vault.grossManagedAssets(), 5_000e6);
    }

    function test_addAdapter_revertsForAdapterBoundToAnotherVault() public {
        EarnVault other =
            new EarnVault("Other", "OTH", address(usdt), address(sm), address(queue), governor, address(0));
        FirstPeriodAdapter foreign = new FirstPeriodAdapter(usdt, address(other), 36 hours);

        vm.prank(curator);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.addAdapter, (address(foreign))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);
        assertFalse(vault.isAdapter(address(foreign)));
    }

    function test_addAdapter_twiceReverts() public {
        FirstPeriodAdapter a = _addAdapter();

        vm.prank(curator);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.addAdapter, (address(a))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);
        assertEq(vault.adapters(0), address(a));
    }

    function test_removeAdapter_dropsRegistrationWhenDrained() public {
        FirstPeriodAdapter a = _addAdapter();
        assertTrue(vault.isAdapter(address(a)));

        vm.prank(curator);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.removeAdapter, (address(a))));
        vm.warp(block.timestamp + tl.delay());

        vm.expectEmit(true, false, false, true, address(vault));
        emit IBaseVault.AdapterRemoved(address(a), block.timestamp);
        tl.executeParamChange(id);

        assertFalse(vault.isAdapter(address(a)));
        // The auto-generated array getter reverts with empty returndata on an out-of-bounds
        // index — assert exactly that rather than "reverts somehow".
        vm.expectRevert(bytes(""));
        vault.adapters(0); // array is empty again
    }

    // -----------------------------------------------------------------------
    // adapterCount — enumeration
    // -----------------------------------------------------------------------
    // The generated getter for the public `adapters` array exposes no `.length`, so without
    // `adapterCount` an off-chain caller has to probe indices until one reverts. Unlike
    // AdapterFactory's append-only index, this one is swap-and-pop: indices move on removal.

    /// @dev Registers a second FirstPeriodAdapter on `vault`.
    function _addSecondAdapter() internal returns (FirstPeriodAdapter a) {
        a = new FirstPeriodAdapter(usdt, address(vault), 12 hours);
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.addAdapter, (address(a))));
    }

    function test_adapterCount_isZeroBeforeAnyAdapterIsAdded() public view {
        assertEq(vault.adapterCount(), 0);
    }

    function test_adapterCount_tracksAdditions() public {
        FirstPeriodAdapter first = _addAdapter();
        assertEq(vault.adapterCount(), 1);
        assertEq(vault.adapters(0), address(first));

        FirstPeriodAdapter second = _addSecondAdapter();
        assertEq(vault.adapterCount(), 2);
        assertEq(vault.adapters(1), address(second));
    }

    /// @dev removeAdapter is swap-and-pop: dropping index 0 moves the last adapter into it, so
    ///      an index a caller cached in an earlier block now names a different adapter. That is
    ///      exactly why the doc comment tells callers to pin one blockTag.
    function test_adapterCount_tracksRemovalAndTheSwapAndPopIndexMove() public {
        FirstPeriodAdapter first = _addAdapter();
        FirstPeriodAdapter second = _addSecondAdapter();
        assertEq(vault.adapterCount(), 2);

        vm.prank(curator);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.removeAdapter, (address(first))));
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(id);

        assertEq(vault.adapterCount(), 1);
        // The survivor was swapped down into the freed slot rather than keeping index 1.
        assertEq(vault.adapters(0), address(second));
        vm.expectRevert(bytes(""));
        vault.adapters(1);
    }

    function test_removeAdapter_revertsWhileAdapterStillHoldsAssets() public {
        FirstPeriodAdapter a = _addAdapter();
        usdt.mint(address(a), 1e6);
        assertEq(a.realAssets(), 1e6);

        vm.prank(curator);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.removeAdapter, (address(a))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);

        assertTrue(vault.isAdapter(address(a)), "adapter still registered while it holds assets");
    }

    function test_removeAdapter_revertsForUnknownAdapter() public {
        vm.prank(curator);
        bytes32 id =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.removeAdapter, (makeAddr("neverAdded"))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);
    }

    function test_addRemoveAdapter_revertForDirectCallerOnceOutOfConfiguring() public {
        FirstPeriodAdapter a = new FirstPeriodAdapter(usdt, address(vault), 36 hours);

        vm.prank(curator);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.addAdapter(address(a));

        vm.prank(curator);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.removeAdapter(address(a));
    }

    // -----------------------------------------------------------------------
    // Insolvency reached through a real Adapter loss (no vault-address prank)
    // -----------------------------------------------------------------------

    /// @dev `_simulateLoss` above shortcuts to the insolvent state by pranking the Vault and
    ///      transferring its own USDT out — no such entry point exists on-chain. This test drives
    ///      a *total* Adapter loss entirely through functions real actors can call (Allocator
    ///      funds the Adapter, Curator books a TOKEN_RETURN purchase, Allocator executes it so the
    ///      cash leaves for a counterparty, then writes the position off with `clearDealValue`
    ///      when the goods never arrive) and pins what that can and cannot do:
    ///
    ///        - it wipes out shareholder equity exactly (`totalAssets()` -> 0), and
    ///        - it can never breach `gross >= liabilities`, because `fundAdapter` may only deploy
    ///          `freeVaultUSDT()` — investor-earmarked USDT is structurally out of reach.
    ///
    ///      That second half is why `writeDownInsolvency` still refuses to run here: the deficit
    ///      it exists to clear cannot be produced by an Adapter loss alone.
    function test_totalAdapterLoss_wipesEquityButNeverBreachesSolvency() public {
        vm.prank(governor);
        vault.setAllocator(makeAddr("allocator"));
        address allocator = vault.allocator();

        // Alice deposits and claims; funder2's minRaiseAmount deposit stays PENDING.
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        uint256 funderRid = vault.nextRequestId() - 1;
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        FirstPeriodAdapter a = _addAdapter();

        // Only free USDT is deployable — funder2's pending 100_000e6 is off limits.
        uint256 free = vault.freeVaultUSDT();
        assertEq(free, 1_000e6);
        assertEq(vault.totalAssets(), 1_000e6, "equity == alice's stake");

        vm.prank(allocator);
        vault.fundAdapter(address(a), free);
        assertEq(vault.grossManagedAssets(), 101_000e6, "capital moved, not destroyed");

        // Counterparty takes the cash and never delivers; the Allocator writes the deal off.
        address counterparty = makeAddr("counterparty");
        vm.prank(curator);
        uint256 orderId = a.createBuyOrder(free, counterparty, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        a.executeBuy(orderId);
        assertEq(a.realAssets(), free, "deal value stands in for the cash");

        vm.prank(allocator);
        a.clearDealValue(orderId);

        // The loss is real and on-chain: the counterparty holds the money, the adapter reports
        // nothing, and gross drops by exactly what was deployed.
        assertEq(a.realAssets(), 0);
        assertEq(usdt.balanceOf(counterparty), free);
        assertEq(vault.grossManagedAssets(), 100_000e6);

        // Shareholders ate all of it; depositors are untouched.
        assertEq(vault.totalAssets(), 0, "equity wiped");
        assertEq(vault.pendingDepositLiability(), 100_000e6, "pending deposits unharmed");
        assertEq(vault.freeVaultUSDT(), 0);
        assertEq(vault.grossManagedAssets(), vault.pendingDepositLiability(), "exactly solvent, not under");

        // And therefore the insolvency recovery path stays shut. Note the pending deposits are
        // not even an eligible target any more — they are a protected, still-refundable liability
        // that never reached an Adapter (审计报告（一）回复 §2) — so the shareholders' equity
        // absorbing the whole loss is exactly the intended outcome here.
        vm.prank(governor);
        bytes32 id =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.writeDownInsolvency, (new uint256[](0))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector); // NotInsolvent, swallowed by the Timelock
        tl.executeParamChange(id);
        assertEq(vault.pendingDepositLiability(), 100_000e6, "no haircut applied");
    }

    /// @dev The other half of the same guarantee, stated directly: an Adapter can never be handed
    ///      USDT that a pending deposit is owed, no matter how the Allocator sizes the call.
    function test_fundAdapter_cannotReachInvestorEarmarkedUSDT() public {
        vm.prank(governor);
        vault.setAllocator(makeAddr("allocator"));
        address allocator = vault.allocator();

        _requestDeposit(alice, 1_000e6); // PENDING — 1_000e6 of the vault's balance is spoken for
        FirstPeriodAdapter a = _addAdapter();

        assertEq(usdt.balanceOf(address(vault)), 1_000e6);
        assertEq(vault.freeVaultUSDT(), 0);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.InsufficientFreeUSDT.selector, uint256(1), uint256(0)));
        vault.fundAdapter(address(a), 1);
    }

    // -----------------------------------------------------------------------
    // cancelRequest — which product/cycle phases let an owner withdraw their own
    // still-open request (合约修改建议0820 补充说明 §1)
    // -----------------------------------------------------------------------

    /// @dev SETTLING is where the FINAL cycle RUNS: starting it at maturity moves the product
    ///      into SETTLING and the cycle into CALCULATING in one transaction
    ///      (最终周期结算及最终兑付补充修改方案 §四.1).
    function _advanceToSettling() internal {
        ProductParams memory p = sm.getParams(address(vault));
        if (block.timestamp < p.maturityTimestamp) vm.warp(p.maturityTimestamp);
        if (uint8(sm.getCycleState(address(vault))) == uint8(CycleState.ACCEPTING)) {
            vm.prank(keeper);
            sm.startCycleCalculation(address(vault));
        }
    }

    /// @dev Completing the final cycle is SETTLING's only exit, and it lands on MATURING.
    function _advanceToMaturing() internal {
        _advanceToSettling();
        vm.prank(settlement);
        sm.completeCycle(address(vault));
    }

    function _advanceToClaiming() internal {
        _advanceToMaturing();
        ProductParams memory p = sm.getParams(address(vault));
        if (block.timestamp < p.claimingStart) vm.warp(p.claimingStart);
        vm.prank(keeper);
        sm.enterClaiming(address(vault));
    }

    function _advanceToClosed() internal {
        _advanceToClaiming();
        ProductParams memory p = sm.getParams(address(vault));
        if (block.timestamp < p.claimingEnd) vm.warp(p.claimingEnd);
        vm.prank(keeper);
        sm.closeProduct(address(vault));
    }

    function _queueRedeem(address user, uint256 shares) internal returns (uint256 rid) {
        vm.startPrank(user);
        vault.approve(address(vault), shares);
        rid = vault.requestRedeem(shares, user);
        vm.stopPrank();
    }

    /// @dev Asserts that alice can cancel a PENDING deposit right now and get her USDT back.
    function _assertDepositCancellable(uint256 rid, uint256 assets) internal {
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        vault.cancelRequest(rid);
        assertEq(usdt.balanceOf(alice), before + assets);
        assertEq(uint8(vault.getDepositRequest(rid).state), uint8(DepositRequestState.CANCELLED));
        assertEq(vault.pendingDepositLiability(), 0);
        assertEq(vault.pendingDepositByOwner(alice), 0);
    }

    // --- allowed phases ----------------------------------------------------

    /// @notice The ordinary case: OPERATING with the cycle in its ACCEPTING window.
    function test_cancel_allowedInOperatingAccepting() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        assertEq(uint8(sm.getProductState(address(vault))), uint8(ProductState.OPERATING));
        _assertDepositCancellable(rid, 1_000e6);
    }

    /// @notice MATURING re-opens cancellation: no settlement round can run any more, so a
    ///         still-queued request would otherwise be locked in forever.
    function test_cancel_allowedInMaturing() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToMaturing();
        _assertDepositCancellable(rid, 1_000e6);
    }

    function test_cancel_allowedInClaiming() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToClaiming();
        _assertDepositCancellable(rid, 1_000e6);
    }

    function test_cancel_allowedInClosed() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToClosed();
        _assertDepositCancellable(rid, 1_000e6);
    }

    /// @notice A queued redeem is cancellable in the post-settlement tail too: all locked
    ///         shares come back and the request is CANCELLED, with nothing left to claim.
    function test_cancel_unfilledRedeem_inClosed_returnsAllShares() public {
        _seedFirstCycle();
        uint256 shares = _giveAliceShares(3_000e6);
        uint256 redeemId = _queueRedeem(alice, shares);
        assertEq(vault.balanceOf(alice), 0, "shares locked in the vault while queued");

        _advanceToClosed();

        vm.prank(alice);
        vault.cancelRequest(redeemId);

        assertEq(vault.balanceOf(alice), shares);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.RequestNotSettled.selector, redeemId));
        vault.claimRedeem(redeemId, alice);
    }

    // --- the two closed settlement phases ----------------------------------

    /// @notice An ordinary cycle being computed: the request is in the batch being settled.
    function test_cancel_revertsWhileCycleCalculating() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseVault.CancelNotAllowed.selector, rid, ProductState.OPERATING, CycleState.CALCULATING
            )
        );
        vault.cancelRequest(rid);
    }

    /// @notice The final settlement window. The cycle still reads ACCEPTING throughout SETTLING
    ///         — the final cycle's completeCycle returned it there in the same transaction that
    ///         set SETTLING, and nothing after that touches it — so this is blocked by the
    ///         ProductState clause, not the cycle one.
    function test_cancel_revertsInSettling() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToSettling();

        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.CALCULATING));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseVault.CancelNotAllowed.selector, rid, ProductState.SETTLING, CycleState.CALCULATING
            )
        );
        vault.cancelRequest(rid);
    }

    /// @notice Cancelling stays closed for the whole of SETTLING — the final batch may still
    ///         fill the request — and re-opens the moment the final cycle completes into
    ///         MATURING (最终周期结算及最终兑付补充修改方案 §十).
    function test_cancel_revertsThroughoutSettling_reopensInMaturing() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToSettling();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseVault.CancelNotAllowed.selector, rid, ProductState.SETTLING, CycleState.CALCULATING
            )
        );
        vault.cancelRequest(rid);

        vm.prank(settlement);
        sm.completeCycle(address(vault));
        _assertDepositCancellable(rid, 1_000e6);
    }

    /// @notice Redeems go through the same gate as deposits.
    function test_cancel_redeem_revertsInSettling() public {
        _seedFirstCycle();
        uint256 shares = _giveAliceShares(3_000e6);
        uint256 redeemId = _queueRedeem(alice, shares);
        _advanceToSettling();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseVault.CancelNotAllowed.selector, redeemId, ProductState.SETTLING, CycleState.CALCULATING
            )
        );
        vault.cancelRequest(redeemId);
    }

    // --- partially-filled redeem -------------------------------------------

    /// @notice Cancelling a partially-filled redeem returns only the unfilled remainder and
    ///         promotes the request to SETTLED, so the USDT already reserved for the filled part
    ///         stays claimable. Marking it CANCELLED would strand that USDT permanently.
    function test_cancel_partiallyFilledRedeem_keepsSettledPortionClaimable() public {
        _seedFirstCycle();
        uint256 shares = _giveAliceShares(3_000e6);
        uint256 redeemId = _queueRedeem(alice, shares);

        // Fill 40% in one cycle; 60% stays queued.
        uint256 filled = shares * 2 / 5;
        _advanceToCalculating();
        uint256 cyc = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cyc);
        vault.settle(cyc, _rs0(), _rs1(redeemId, filled), 0);
        vm.stopPrank();
        _completeCycle();

        uint256 sharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.cancelRequest(redeemId);

        // Only the unfilled remainder comes back.
        assertEq(vault.balanceOf(alice), sharesBefore + (shares - filled));

        // Promoted to SETTLED, asserted behaviourally: claimRedeem pays the cumulative
        // settledAssets, and never twice.
        uint256 usdtBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.claimRedeem(redeemId, alice);
        assertEq(assetsOut, _assetsFor(filled));
        assertEq(usdt.balanceOf(alice), usdtBefore + assetsOut);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.RequestNotSettled.selector, redeemId));
        vault.claimRedeem(redeemId, alice);
    }

    /// @notice The same, in a phase that only the relaxed gate reaches.
    function test_cancel_partiallyFilledRedeem_inMaturing() public {
        _seedFirstCycle();
        uint256 shares = _giveAliceShares(3_000e6);
        uint256 redeemId = _queueRedeem(alice, shares);

        uint256 filled = shares / 4;
        _advanceToCalculating();
        uint256 cyc = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cyc);
        vault.settle(cyc, _rs0(), _rs1(redeemId, filled), 0);
        vm.stopPrank();
        _completeCycle();

        _advanceToMaturing();

        vm.prank(alice);
        vault.cancelRequest(redeemId);
        assertEq(vault.balanceOf(alice), shares - filled);

        vm.prank(alice);
        assertEq(vault.claimRedeem(redeemId, alice), _assetsFor(filled));
    }

    // --- caller authorisation ----------------------------------------------

    /// @notice Only the request's own owner, or an operator they approved, may cancel it —
    ///         cancellation is not permissionless in any phase.
    function test_cancel_revertsForStranger_inClosed() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToClosed();

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.NotOwnerOrOperator.selector, stranger, alice));
        vault.cancelRequest(rid);
    }

    function test_cancel_allowedForApprovedOperator_inClosed() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToClosed();

        address op = makeAddr("operator");
        vm.prank(alice);
        vault.setOperator(op, true);

        uint256 before = usdt.balanceOf(alice);
        vm.prank(op);
        vault.cancelRequest(rid);
        // The refund goes to the request's owner, not to the operator.
        assertEq(usdt.balanceOf(alice), before + 1_000e6);
        assertEq(usdt.balanceOf(op), 0);
    }

    // -------------------------------------------------------------------
    // 审计反馈 V4 #5 — a liquidation must not lock PENDING subscriptions in
    // -------------------------------------------------------------------

    /// @dev Reproduces the wedge exactly: liquidate while the cycle is CALCULATING, with a
    ///      PENDING deposit outstanding. From that moment `snapshotSettlementPrice` reverts on
    ///      `insolvencyLiquidated`, so no batch can finish, `completeCycle` never runs, and the
    ///      cycle can never return to ACCEPTING. Returns alice's PENDING deposit id and amount.
    function _liquidatedMidCalculatingWithPendingDeposit()
        internal
        returns (uint256 pendingRid, uint256 pendingAssets)
    {
        _seedFirstCycle();

        uint256 ridA = _requestDeposit(alice, 2_000e6);
        uint256 ridB = _requestDeposit(bob, 1_000e6);
        _advanceToCalculating();
        _settle(_toIds(ridA, ridB), new uint256[](0), 0);
        vm.prank(alice);
        vault.claimDeposit(ridA, alice);
        vm.prank(bob);
        vault.claimDeposit(ridB, bob);

        uint256 sharesA = vault.balanceOf(alice);
        uint256 sharesB = vault.balanceOf(bob);
        uint256 idA = _queueRedeem(alice, sharesA);
        uint256 idB = _queueRedeem(bob, sharesB);

        _advanceToCalculating();
        uint256 cn = sm.currentCycleNumber(address(vault));
        RequestSettlement[] memory reds = new RequestSettlement[](2);
        reds[0] = RequestSettlement({requestId: idA, settleAmount: sharesA});
        reds[1] = RequestSettlement({requestId: idB, settleAmount: sharesB});
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cn);
        vault.settle(cn, _rs0(), reds, 0);
        vm.stopPrank();
        _completeCycle();

        // The protected class this test is about: a subscription that has settled nothing, minted
        // no shares and never reached an Adapter.
        pendingAssets = 500e6;
        pendingRid = _requestDeposit(alice, pendingAssets);
        assertEq(vault.pendingDepositLiability(), pendingAssets);

        // Drain down to insolvency while leaving the protected class fully backed in cash —
        // `writeDownInsolvency` requires exactly that before it will haircut anyone.
        uint256 reserved = vault.reservedRedeemLiability();
        _simulateLoss(vault.grossManagedAssets() - pendingAssets - (reserved / 2));
        assertLt(vault.grossManagedAssets(), pendingAssets + reserved, "must be short of the fixed claims");
        assertGe(usdt.balanceOf(address(vault)), pendingAssets, "protected class must stay backed");

        // The bad timing: the liquidation lands mid-CALCULATING.
        _advanceToCalculating();
        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.CALCULATING));

        _scheduleAndExecute(
            governor, abi.encodeCall(IBaseVault.writeDownInsolvency, (idA < idB ? _toIds(idA, idB) : _toIds(idB, idA)))
        );
        assertTrue(vault.insolvencyLiquidated());
    }

    /// @notice The defect: `writeDownInsolvency` checks
    ///         `cash >= pendingDepositLiability + refundableLiability` precisely to declare the
    ///         PENDING class protected in full, then — before this fix — closed its only exit.
    ///         `_unwindPendingDeposit` via `cancelRequest` is that exit: `markRefundable` needs
    ///         FUNDING_FAILED, unreachable from OPERATING, and `evictDepositRequest` exists only
    ///         on LiquidityEarnVault.
    function test_cancelRequest_pendingDepositStillExitsAfterLiquidation() public {
        (uint256 pendingRid, uint256 pendingAssets) = _liquidatedMidCalculatingWithPendingDeposit();

        // The wedge is real: the cycle is stuck outside ACCEPTING for good, which is what the
        // old unconditional `_requireCancellable` would have failed on.
        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.CALCULATING));
        assertEq(uint8(sm.getProductState(address(vault))), uint8(ProductState.OPERATING));

        uint256 before = usdt.balanceOf(alice);
        uint256 reservedBefore = vault.reservedRedeemLiability();
        uint256 grossBefore = vault.grossManagedAssets();

        vm.prank(alice);
        vault.cancelRequest(pendingRid);

        assertEq(usdt.balanceOf(alice), before + pendingAssets, "protected in full means paid in full");
        assertEq(uint8(vault.getDepositRequest(pendingRid).state), uint8(DepositRequestState.CANCELLED));
        assertEq(vault.pendingDepositLiability(), 0);
        assertEq(vault.pendingDepositByOwner(alice), 0);

        // The refund comes out of the money that was always earmarked for it, not out of the
        // haircut pot: the liquidation's `gross >= protected + reservedRedeem` invariant holds
        // because gross and the protected liability fall by exactly the same amount.
        assertEq(vault.reservedRedeemLiability(), reservedBefore, "the haircut pot is untouched");
        assertEq(vault.grossManagedAssets(), grossBefore - pendingAssets);
        assertGe(vault.grossManagedAssets(), vault.reservedRedeemLiability(), "invariant preserved");
    }

    // -------------------------------------------------------------------
    // ERC-4626 virtual-share residue — an Adapter that made a gain must still be removable
    // -------------------------------------------------------------------

    /// @dev Sets up the exact shape the residue needs: the Vault is the Adapter's only shareholder
    ///      and the Adapter has since made a gain, so `totalAssets > totalSupply`.
    function _adapterWithAGain() internal returns (FirstPeriodAdapter a, address allocator) {
        vm.prank(governor);
        vault.setAllocator(makeAddr("allocator"));
        allocator = vault.allocator();

        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        vault.claimDeposit(rid, alice);

        a = _addAdapter();
        vm.prank(allocator);
        vault.fundAdapter(address(a), 1_000e6);

        usdt.mint(address(a), 100e6); // +10% yield
        assertEq(a.realAssets(), 1_100e6);
        assertEq(a.totalSupply(), 1_000e6, "vault is the only holder");
    }

    /// @notice The defect the auditor reported. ERC-4626's virtual-share math makes the last unit
    ///         unreachable from both directions once the Adapter is in profit, so the exact-zero
    ///         gate on `removeAdapter` can never be satisfied by recall alone.
    function test_erc4626Residue_recallAloneCanNeverEmptyAProfitableAdapter() public {
        (FirstPeriodAdapter a, address allocator) = _adapterWithAGain();

        // Direction 1 — withdrawing the full reported balance asks for more shares than exist.
        assertEq(a.previewWithdraw(a.realAssets()), 1_000e6 + 1, "one share more than the vault holds");
        vm.prank(allocator);
        vm.expectRevert();
        vault.recallAdapter(address(a), 1_100e6);

        // Direction 2 — redeeming every share rounds down and strands the remainder.
        uint256 maxOut = a.previewRedeem(a.totalSupply());
        assertEq(maxOut, 1_100e6 - 1, "rounds down");
        vm.prank(allocator);
        vault.recallAdapter(address(a), maxOut);

        assertEq(a.totalSupply(), 0, "every share is gone");
        assertEq(a.realAssets(), 1, "...and a wei is stranded anyway");

        // Which is exactly what the exact-zero gate rejects, permanently.
        vm.prank(curator);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.removeAdapter, (address(a))));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);
        assertTrue(vault.isAdapter(address(a)), "stuck forever");
    }

    /// @notice The fix: `windDownToVault` moves the balance instead of converting it, so
    ///         `realAssets()` reaches exactly zero and the gate can be satisfied.
    function test_windDownToVault_emptiesAProfitableAdapterAndAllowsRemoval() public {
        (FirstPeriodAdapter a, address allocator) = _adapterWithAGain();

        uint256 grossBefore = vault.grossManagedAssets();
        uint256 vaultBefore = usdt.balanceOf(address(vault));

        vm.prank(allocator);
        a.windDownToVault();

        assertEq(a.realAssets(), 0, "exactly zero, not dust");
        assertEq(a.totalSupply(), 0, "shares burned with the balance");
        assertEq(usdt.balanceOf(address(a)), 0);
        assertEq(usdt.balanceOf(address(vault)), vaultBefore + 1_100e6, "every wei came home");

        // Value moved, none created or destroyed — the same USDT is simply counted in the Vault
        // now rather than through the Adapter.
        assertEq(vault.grossManagedAssets(), grossBefore, "gross is unchanged");

        vm.prank(curator);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.removeAdapter, (address(a))));
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(id);
        assertFalse(vault.isAdapter(address(a)), "removable at last");
    }

    /// @notice The same residue blocks the final cycle, which is the worse of the two failures:
    ///         `_requireAssetsWoundDown` compares against exact zero too, so a profitable Adapter
    ///         would leave the product unable to ever price its final cycle.
    function test_windDownToVault_unblocksTheFinalCycleWindDownCheck() public {
        (FirstPeriodAdapter a, address allocator) = _adapterWithAGain();

        uint256 maxOut = a.previewRedeem(a.totalSupply());
        vm.prank(allocator);
        vault.recallAdapter(address(a), maxOut);
        assertEq(a.realAssets(), 1, "the residue that wedges maturity");

        _advanceToSettling();
        uint256 cn = sm.currentCycleNumber(address(vault));
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.AssetsNotWoundDown.selector, address(a), 1));
        vault.snapshotSettlementPrice(cn);

        vm.prank(allocator);
        a.windDownToVault();

        vm.prank(settlement);
        vault.snapshotSettlementPrice(cn); // now prices cleanly
    }

    function test_windDownToVault_refusesWhileADealIsLive() public {
        (FirstPeriodAdapter a, address allocator) = _adapterWithAGain();

        vm.prank(curator);
        uint256 orderId = a.createBuyOrder(500e6, makeAddr("counterparty"), IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        a.executeBuy(orderId);

        // An un-retired position would silently vanish from grossManagedAssets on removal.
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.AdapterNotWoundDown.selector, 1, 0));
        a.windDownToVault();
    }

    /// @dev Reaches the (no live deals, money still escrowed) corner the other way round: the
    ///      Sell Order's deal is retired by `clearDealValue` while the order stays FUNDED, so the
    ///      only thing left outstanding is the buyer's payment.
    function test_windDownToVault_refusesWhileProceedsAreEscrowed() public {
        (FirstPeriodAdapter a, address allocator) = _adapterWithAGain();
        address payer = makeAddr("sellPayer");

        vm.prank(curator);
        uint256 dealKey = a.createBuyOrder(500e6, makeAddr("counterparty"), IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        a.executeBuy(dealKey);

        vm.prank(curator);
        uint256 sellId = a.createSellOrder(
            address(0), 0, 400e6, payer, makeAddr("assetRecipient"), dealKey, true, 500e6, block.timestamp + 7 days
        );
        usdt.mint(payer, 400e6);
        vm.startPrank(payer);
        usdt.approve(address(a), 400e6);
        a.fundSellOrder(sellId);
        vm.stopPrank();

        // The delivery lands, retiring the deal — but the buyer's money is still held pending
        // executeSell, and it is not the Vault's to walk out.
        vm.prank(allocator);
        a.clearDealValue(dealKey);
        assertEq(a.lockedProceeds(), 400e6);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.AdapterNotWoundDown.selector, 0, 400e6));
        a.windDownToVault();
    }

    function test_windDownToVault_onlyAllocator() public {
        (FirstPeriodAdapter a,) = _adapterWithAGain();

        vm.prank(alice);
        vm.expectRevert(IAdapter.NotAllocator.selector);
        a.windDownToVault();

        // The Curator is not the Allocator either — this is a fund movement, not a parameter change.
        vm.prank(curator);
        vm.expectRevert(IAdapter.NotAllocator.selector);
        a.windDownToVault();
    }

    /// @notice Why `writeDownInsolvency` must NOT gain a `cs == ACCEPTING` precondition
    ///         (审计反馈 V4 #5 附带建议，未采纳). This pins the state that makes that gate
    ///         unsafe: the vault is insolvent, the cycle is CALCULATING, and the only writer that
    ///         returns the cycle to ACCEPTING is unreachable — so gating the recovery path on
    ///         ACCEPTING would make it unreachable in exactly the case it exists for.
    function test_writeDownInsolvency_mustStayReachableWhileTheCycleIsWedged() public {
        _seedFirstCycle();

        uint256 ridA = _requestDeposit(alice, 2_000e6);
        uint256 ridB = _requestDeposit(bob, 1_000e6);
        _advanceToCalculating();
        _settle(_toIds(ridA, ridB), new uint256[](0), 0);
        vm.prank(alice);
        vault.claimDeposit(ridA, alice);
        vm.prank(bob);
        vault.claimDeposit(ridB, bob);

        uint256 sharesA = vault.balanceOf(alice);
        uint256 sharesB = vault.balanceOf(bob);
        uint256 idA = _queueRedeem(alice, sharesA);
        uint256 idB = _queueRedeem(bob, sharesB);

        _advanceToCalculating();
        uint256 cn = sm.currentCycleNumber(address(vault));
        RequestSettlement[] memory reds = new RequestSettlement[](2);
        reds[0] = RequestSettlement({requestId: idA, settleAmount: sharesA});
        reds[1] = RequestSettlement({requestId: idB, settleAmount: sharesB});
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cn);
        vault.settle(cn, _rs0(), reds, 0);
        vm.stopPrank();
        _completeCycle();

        // An Adapter-side loss lands, and the keeper opens the next cycle before anyone knows.
        uint256 reserved = vault.reservedRedeemLiability();
        _simulateLoss(vault.grossManagedAssets() - (reserved / 2));
        _advanceToCalculating();
        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.CALCULATING));

        // 1. The insolvency is discovered the ordinary way: settlement cannot price the cycle.
        uint256 cn2 = sm.currentCycleNumber(address(vault));
        vm.prank(settlement);
        vm.expectRevert(IBaseVault.AccountingInsolvent.selector);
        vault.snapshotSettlementPrice(cn2);

        // 2. `completeCycle` is the only writer that returns the cycle to ACCEPTING, and it is
        //    onlyVaultSettlement — reachable only through the settle path step 1 just closed.
        //    `startCycleCalculation` cannot reopen a cycle that is not ACCEPTING either.
        vm.prank(keeper);
        vm.expectRevert();
        sm.startCycleCalculation(address(vault));
        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.CALCULATING), "wedged for good");

        // 3. So the recovery path has to work from right here. A `cs == ACCEPTING` precondition
        //    would have made this call — the only way out for every claim in the vault — revert.
        _scheduleAndExecute(
            governor, abi.encodeCall(IBaseVault.writeDownInsolvency, (idA < idB ? _toIds(idA, idB) : _toIds(idB, idA)))
        );
        assertTrue(vault.insolvencyLiquidated(), "liquidation must be reachable from CALCULATING");

        // And the money really does come out afterwards.
        assertGt(_claimRedeemAmount(alice, idA), 0);
        assertGt(_claimRedeemAmount(bob, idB), 0);
    }

    /// @dev The exemption is scoped to liquidation and nothing else: an ordinary CALCULATING
    ///      cycle still closes the cancellation window, because a settlement round really may be
    ///      in flight over the request.
    function test_cancelRequest_pendingDepositStillBlockedWhileMerelyCalculating() public {
        _seedFirstCycle();
        uint256 rid = _requestDeposit(alice, 1_000e6);
        _advanceToCalculating();

        assertFalse(vault.insolvencyLiquidated());
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseVault.CancelNotAllowed.selector, rid, ProductState.OPERATING, CycleState.CALCULATING
            )
        );
        vault.cancelRequest(rid);
    }
}

/// @dev Minimal UnifiedPool stand-in: BaseVault only reads `pending(address)` from whichever pool
///      is wired in (grossManagedAssets, and the drain check in setUnifiedPool).
contract StubPool {
    mapping(address => uint256) public pending;

    function setPending(address vault, uint256 amount) external {
        pending[vault] = amount;
    }
}
