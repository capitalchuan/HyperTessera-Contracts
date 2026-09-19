// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HyperAccessControl} from "../src/governance/HyperAccessControl.sol";
import {StateManager} from "../src/asset-management/StateManager.sol";
import {Queue} from "../src/asset-management/settlement/Queue.sol";
import {UnifiedPool} from "../src/asset-management/settlement/UnifiedPool.sol";
import {Settlement} from "../src/asset-management/settlement/Settlement.sol";
import {EarnVault} from "../src/asset-management/vaults/EarnVault.sol";
import {LiquidityEarnVault} from "../src/asset-management/vaults/LiquidityEarnVault.sol";
import {LiquidityBridge} from "../src/asset-management/vaults/LiquidityBridge.sol";
import {VaultTimelock} from "../src/governance/VaultTimelock.sol";
import {ISettlement} from "../src/interfaces/ISettlement.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {ILiquidityBridge} from "../src/interfaces/ILiquidityBridge.sol";
import {ProductState, CycleState, ProductParams, RequestSettlement} from "../src/libs/Types.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("MockUSDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title SettlementOrderingTest
/// @notice Cross-vault settlement timing between the Cash Vault (EarnVault) and the LP Vault
///         (LiquidityEarnVault):
///           1. the Cash Vault's performance fee must accrue BEFORE LP USDT bridges in, so the
///              fee is computed on pre-existing assets only and LP enters at the post-fee price;
///           2. the LP's Cash-Token mint must be priced BEFORE its own USDT lands in the Cash
///              Vault, so the deposit does not inflate the price used to size it;
///           3. the bridged LP USDT must still be usable by the Cash Vault's redeem settlement
///              in the same batch.
contract SettlementOrderingTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    MockUSDT internal usdt;
    UnifiedPool internal unifiedPool;
    Settlement internal settlement;
    LiquidityBridge internal bridge;
    EarnVault internal cashVault;
    LiquidityEarnVault internal lpVault;
    VaultTimelock internal cashTl;

    address internal governor = makeAddr("governor");
    address internal keeper = makeAddr("keeper");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal operatorPk = 0xBEEF1;
    address internal operator;

    uint256 internal constant NOW = 1_000_000;

    // Scenario constants — see the arithmetic in test_cashVaultFeeAccruesBeforeLpUsdtEnters.
    uint256 internal constant CASH_SEED = 1_000e6; // alice's Cash Vault deposit, cycle 0
    uint256 internal constant CASH_YIELD = 100e6; // simulated yield, +10% -> fee is due
    uint256 internal constant LP_DEPOSIT = 220e6; // bob's LP deposit, settled in cycle 1

    function setUp() public {
        vm.warp(NOW);
        operator = vm.addr(operatorPk);

        ac = new HyperAccessControl(governor);
        usdt = new MockUSDT();
        sm = new StateManager(address(ac));
        queue = new Queue(address(sm));

        UnifiedPool poolImpl = new UnifiedPool();
        unifiedPool = UnifiedPool(
            address(
                new ERC1967Proxy(
                    address(poolImpl), abi.encodeCall(UnifiedPool.initialize, (address(usdt), address(sm), address(ac)))
                )
            )
        );

        bridge = new LiquidityBridge(address(usdt), address(sm), address(ac));
        settlement = new Settlement(address(sm), address(unifiedPool), address(queue));

        cashVault =
            new EarnVault("Cash Earn", "htCASH", address(usdt), address(sm), address(queue), governor, address(bridge));
        lpVault = new LiquidityEarnVault(
            "LP Earn", "htLP", address(usdt), address(sm), address(queue), governor, address(bridge), address(cashVault)
        );

        // Cash Vault governance binding — subscriptionCapShare is only ever set through the
        // VaultTimelock, so the cap tests below act as Timelock.
        cashTl = new VaultTimelock(address(cashVault));

        vm.startPrank(governor);
        sm.setVaultFactory(governor);
        cashVault.bindGovernance(address(cashTl));
        sm.registerVault(address(cashVault));
        sm.registerVault(address(lpVault));

        _configureVault(address(cashVault));
        _configureVault(address(lpVault));

        // Cash Vault: 10% performance fee, no protocol split (revenuePool unset).
        cashVault.setPerformanceFeeRecipient(feeRecipient);
        cashVault.setPerformanceFeeBps(1_000);

        // Cash Vault is UnifiedPool-wired so tests can park principal in the pool (which keeps
        // totalAssets unchanged but drains freeVaultUSDT).
        cashVault.setUnifiedPool(address(unifiedPool));
        unifiedPool.addVault(address(cashVault));
        // Governor admission to the shared pool, separate from the Vault opting in.
        unifiedPool.setVaultWhitelisted(address(cashVault), true);
        unifiedPool.setSettlementWhitelisted(address(settlement), true);
        // The same admission, one layer down, for the LP → Cash bridge leg.
        bridge.setBridgeWhitelisted(address(lpVault), true);
        bridge.setBridgeWhitelisted(address(cashVault), true);
        vm.stopPrank();

        vm.startPrank(keeper);
        sm.openSubscription(address(cashVault));
        sm.openSubscription(address(lpVault));
        vm.stopPrank();

        usdt.mint(alice, 1_000_000e6);
        usdt.mint(bob, 1_000_000e6);
    }

    // -----------------------------------------------------------------------
    // Setup helpers
    // -----------------------------------------------------------------------

    function _configureVault(address v) internal {
        IBaseVault(v).setCurator(governor);
        IBaseVault(v).setKeeper(keeper, true);
        sm.setProductParams(v, _defaultParams());
        IBaseVault(v).setSettlement(address(settlement));
        settlement.setOperator(v, operator, true);
        settlement.setThreshold(v, 1);
    }

    function _defaultParams() internal pure returns (ProductParams memory) {
        return ProductParams({
            subscriptionStart: NOW,
            subscriptionEnd: NOW + 7 days,
            walletSubscriptionCap: 1_000_000e6,
            minRaiseAmount: 0,
            subscriptionCapShare: 0,
            cycleDuration: 7 days,
            maturityTimestamp: NOW + 365 days,
            claimingStart: NOW + 370 days,
            claimingEnd: NOW + 400 days,
            feeParams: 0
        });
    }

    function _requestDeposit(address v, address who, uint256 assets) internal returns (uint256 rid) {
        vm.startPrank(who);
        usdt.approve(v, assets);
        rid = IBaseVault(v).requestDeposit(assets, who);
        vm.stopPrank();
    }

    function _rs(uint256 id, uint256 amount) internal pure returns (RequestSettlement[] memory out) {
        out = new RequestSettlement[](1);
        out[0] = RequestSettlement({requestId: id, settleAmount: amount});
    }

    function _none() internal pure returns (RequestSettlement[] memory out) {
        out = new RequestSettlement[](0);
    }

    function _vs(address v, RequestSettlement[] memory deposits, RequestSettlement[] memory redeems)
        internal
        pure
        returns (ISettlement.VaultSettlement memory)
    {
        return ISettlement.VaultSettlement({
            distribution: ISettlement.Distribution({vault: v, amount: 0}), deposits: deposits, redeems: redeems
        });
    }

    /// @dev Signing is split out from submission so callers can place `vm.expectRevert`
    ///      immediately before `submitBatch` — the intervening `vm.sign` cheatcode call would
    ///      otherwise consume the expectation.
    function _prepare(ISettlement.VaultSettlement[] memory vs, uint256 cycleNumber)
        internal
        returns (ISettlement.SettlementInstruction memory instr, bytes[] memory sigs)
    {
        instr = ISettlement.SettlementInstruction({
            vaultSettlements: vs, cycleNumber: cycleNumber, validUntil: block.timestamp + 3600
        });
        bytes32 hash = settlement.hashInstruction(instr); // domain-separated by Settlement address + chainid
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, ethHash);
        sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
    }

    function _submit(ISettlement.VaultSettlement[] memory vs, uint256 cycleNumber) internal {
        (ISettlement.SettlementInstruction memory instr, bytes[] memory sigs) = _prepare(vs, cycleNumber);
        settlement.submitBatch(instr, sigs);
    }

    /// @dev Runs cycle 0: alice's CASH_SEED lands in the Cash Vault at the 1.0 initial price,
    ///      leaving the Cash Vault at CASH_SEED assets / CASH_SEED*1e12 shares and HWM = 1.0.
    function _runCycleZero() internal returns (uint256 aliceCashShares) {
        uint256 rid = _requestDeposit(address(cashVault), alice, CASH_SEED);

        vm.warp(NOW + 7 days);
        vm.startPrank(keeper);
        sm.finalizeSubscription(address(cashVault));
        sm.finalizeSubscription(address(lpVault));
        vm.stopPrank();

        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](2);
        vs[0] = _vs(address(lpVault), _none(), _none());
        vs[1] = _vs(address(cashVault), _rs(rid, CASH_SEED), _none());
        _submit(vs, sm.currentCycleNumber(address(cashVault)));

        vm.prank(alice);
        aliceCashShares = cashVault.claimDeposit(rid, alice);
    }

    function _advanceBothToCalculating() internal {
        uint256 target = sm.currentCycleStart(address(cashVault)) + 7 days + 1;
        if (block.timestamp < target) vm.warp(target);
        vm.startPrank(keeper);
        sm.startCycleCalculation(address(cashVault));
        sm.startCycleCalculation(address(lpVault));
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // 1. LP mint pricing — the LP's own USDT must not size its own mint
    // -----------------------------------------------------------------------

    /// @notice Unit-level proof of the pricing bug, no Settlement involved.
    ///         Cash Vault holds 1_000 USDT against 1_000e18 shares (price 1.0). A 100 USDT
    ///         bridge deposit must mint 100e18 shares. Pricing after the transfer lands makes
    ///         the vault look like 1_100 USDT / 1_000e18 shares (price 1.1) and mints only
    ///         90.909e18 — the depositor immediately loses 8.33 USDT to existing holders.
    function test_syncDeposit_isPricedBeforeIncomingAssetsLand() public {
        vm.warp(NOW + 7 days);
        vm.prank(keeper);
        sm.finalizeSubscription(address(cashVault));

        // Seed 1_000 USDT / 1_000e18 shares through the bridge itself (supply == 0 -> price 1.0).
        _bridgeIn(1_000e6);
        assertEq(cashVault.totalSupply(), 1_000e18, "seed supply");
        assertEq(cashVault.totalAssets(), 1_000e6, "seed assets");

        uint256 supplyBefore = cashVault.totalSupply();
        uint256 minted = _bridgeIn(100e6);

        assertEq(minted, 100e18, "mint must be priced at the pre-deposit price");
        assertEq(cashVault.totalSupply(), supplyBefore + minted, "supply grows by minted");
        // Depositor keeps its own money: 100 USDT in, 100 USDT of share value out.
        assertEq(cashVault.convertToAssets(minted), 100e6, "no value donated to existing holders");
    }

    function _bridgeIn(uint256 assets) internal returns (uint256 shares) {
        address from = address(this);
        // Both sides of a bridge must be protocol-registered now; this
        // test contract stands in as `fromVault`.
        if (!sm.registeredVaults(from)) {
            vm.prank(governor);
            sm.registerVault(from);
        }
        // ...and named on the bridge by a Governor, which registration does not imply.
        if (!bridge.bridgeWhitelisted(from)) {
            vm.prank(governor);
            bridge.setBridgeWhitelisted(from, true);
        }
        usdt.mint(from, assets);
        usdt.approve(address(bridge), assets);
        uint256 before = cashVault.balanceOf(from);
        bridge.bridgeDeposit(assets, from, address(cashVault));
        shares = cashVault.balanceOf(from) - before;
    }

    /// @dev LiquidityBridge calls IVaultRoles(fromVault).allocator(); this test contract stands in
    ///      as `fromVault` for _bridgeIn, so it must answer that call.
    function allocator() external view returns (address) {
        return address(this);
    }

    // -----------------------------------------------------------------------
    // 2. Fee isolation + LP enters at the post-fee price
    // -----------------------------------------------------------------------

    /// @notice Cycle 1 state before settlement:
    ///           Cash Vault  assets = 1_100e6, supply = 1_000e18, HWM = 1.0
    ///           LP Vault    one 220e6 deposit from bob
    ///         Fee must be computed on 1_100e6 / 1_000e18 only:
    ///           grossPrice   = 1.100000
    ///           profitAssets = 100e6, feeAssets = 10e6 (10%)
    ///           feeShares    = 10e6 * 1_000e18 / (1_100e6 - 10e6) = 9.174311926605504587e18
    ///           post-fee px  = 1_100e6 * 1e18 / 1_009.174311926605504587e18 = 1.090000
    ///         and bob's 220e6 must then mint 220e6 * 1e18 / 1.090000e6 = 201.834862385321100917e18.
    function test_cashVaultFeeAccruesBeforeLpUsdtEnters() public {
        _runCycleZero();

        usdt.mint(address(cashVault), CASH_YIELD); // simulated yield: 1_000e6 -> 1_100e6
        uint256 lpRid = _requestDeposit(address(lpVault), bob, LP_DEPOSIT);
        _advanceBothToCalculating();

        uint256 cycle = sm.currentCycleNumber(address(cashVault));
        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](2);
        vs[0] = _vs(address(lpVault), _rs(lpRid, LP_DEPOSIT), _none());
        vs[1] = _vs(address(cashVault), _none(), _none());

        vm.recordLogs();
        _submit(vs, cycle);

        (,, uint256 settlementPrice, uint256 feeAssets, uint256 feeShares,, bool init) = cashVault.cycleSnapshots(cycle);
        assertTrue(init, "snapshot taken");

        // Fee is computed on pre-LP assets only.
        assertEq(feeAssets, 10e6, "feeAssets from pre-existing assets only");
        assertEq(feeShares, 9_174_311_926_605_504_587, "feeShares from pre-existing assets only");
        assertEq(settlementPrice, 1_090_000, "post-fee settlement price");

        // Bob receives Cash Tokens sized at the post-fee price, with his own USDT excluded.
        uint256 bobCash = cashVault.balanceOf(bob);
        assertEq(bobCash, 201_834_862_385_321_100_917, "LP minted at post-fee price");
        // Round-trip value: bob put in 220 USDT and holds ~220 USDT of Cash Token.
        assertApproxEqAbs(cashVault.convertToAssets(bobCash), LP_DEPOSIT, 2, "LP keeps its principal");

        // Ordering: the fee accrual must be emitted before the bridge deposit.
        _assertLogOrder(IBaseVault.PerformanceFeeAccrued.selector, ILiquidityBridge.DepositBridged.selector);
    }

    /// @notice The array order only controls whether the LP's USDT is early enough to fund the
    ///         Cash Vault's redeems. Fee isolation and LP mint pricing come from the phase split
    ///         and hold under [Cash Vault, LP Vault] too — which is why the order is left to the
    ///         off-chain Operator rather than enforced on-chain: getting it wrong under-funds the
    ///         redeem and reverts, it never silently misprices anyone.
    function test_feeIsolationHoldsUnderReversedArrayOrder() public {
        _runCycleZero();

        usdt.mint(address(cashVault), CASH_YIELD);
        uint256 lpRid = _requestDeposit(address(lpVault), bob, LP_DEPOSIT);
        _advanceBothToCalculating();

        uint256 cycle = sm.currentCycleNumber(address(cashVault));
        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](2);
        vs[0] = _vs(address(cashVault), _none(), _none());
        vs[1] = _vs(address(lpVault), _rs(lpRid, LP_DEPOSIT), _none());
        _submit(vs, cycle);

        (,, uint256 settlementPrice,, uint256 feeShares,,) = cashVault.cycleSnapshots(cycle);
        assertEq(feeShares, 9_174_311_926_605_504_587, "fee unaffected by array order");
        assertEq(settlementPrice, 1_090_000, "post-fee price unaffected by array order");
        assertEq(cashVault.balanceOf(bob), 201_834_862_385_321_100_917, "LP mint unaffected by array order");
    }

    // -----------------------------------------------------------------------
    // 3. Bridged LP USDT funds the same cycle's Cash redeem
    // -----------------------------------------------------------------------

    /// @dev Parks the Cash Vault's principal in UnifiedPool (totalAssets unchanged, freeVaultUSDT
    ///      drained to CASH_YIELD) and queues a redeem that only the bridged LP USDT can fund.
    function _setupRedeemGapScenario() internal returns (uint256 lpRid, uint256 redeemRid) {
        _runCycleZero();
        usdt.mint(address(cashVault), CASH_YIELD);

        vm.prank(operator);
        cashVault.returnPrincipalToPool(CASH_SEED);
        assertEq(usdt.balanceOf(address(cashVault)), CASH_YIELD, "cash vault drained to yield only");
        assertEq(cashVault.totalAssets(), CASH_SEED + CASH_YIELD, "totalAssets unchanged by parking");

        // 200e18 shares at the post-fee price of 1.090000 => 218e6 USDT owed, against only
        // 100e6 of free vault USDT. Only the LP's 220e6 bridge inflow can close the gap.
        vm.prank(alice);
        redeemRid = cashVault.requestRedeem(200e18, alice);

        lpRid = _requestDeposit(address(lpVault), bob, LP_DEPOSIT);
        _advanceBothToCalculating();
    }

    function test_cashRedeemAlone_revertsWithoutLpInflow() public {
        (, uint256 redeemRid) = _setupRedeemGapScenario();

        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](1);
        vs[0] = _vs(address(cashVault), _none(), _rs(redeemRid, 200e18));
        (ISettlement.SettlementInstruction memory instr, bytes[] memory sigs) =
            _prepare(vs, sm.currentCycleNumber(address(cashVault)));

        vm.expectRevert(abi.encodeWithSelector(IBaseVault.InsufficientSettlementLiquidity.selector, 218e6, 100e6));
        settlement.submitBatch(instr, sigs);
    }

    function test_lpBridgedUsdtFundsSameCycleCashRedeem() public {
        (uint256 lpRid, uint256 redeemRid) = _setupRedeemGapScenario();

        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](2);
        vs[0] = _vs(address(lpVault), _rs(lpRid, LP_DEPOSIT), _none());
        vs[1] = _vs(address(cashVault), _none(), _rs(redeemRid, 200e18));

        vm.recordLogs();
        _submit(vs, sm.currentCycleNumber(address(cashVault)));

        vm.prank(alice);
        uint256 paid = cashVault.claimRedeem(redeemRid, alice);
        assertEq(paid, 218e6, "redeem paid at the post-fee price");

        // The bridge inflow must land before the Cash Vault's redeem settlement.
        _assertLogOrder(ILiquidityBridge.DepositBridged.selector, IBaseVault.RedeemSettled.selector);
    }

    // -----------------------------------------------------------------------
    // 4. subscriptionCapShare across the LP -> Cash bridge
    // -----------------------------------------------------------------------

    function _setCashCapShare(uint256 capShare) internal {
        vm.prank(address(cashTl));
        cashVault.setSubscriptionCapShare(capShare);
    }

    /// @dev Only the LP Vault reaches CALCULATING, so the Cash Vault can legally be left out of
    ///      the batch while the bridge still mints into it.
    function _advanceLpOnlyToCalculating() internal {
        uint256 target = sm.currentCycleStart(address(lpVault)) + 7 days + 1;
        if (block.timestamp < target) vm.warp(target);
        vm.prank(keeper);
        sm.startCycleCalculation(address(lpVault));
    }

    /// @notice The bridge inflow is the whole breach. Cycle 1 leaves the Cash Vault at
    ///         1_100e6 assets / 1_009.174...e18 shares at price 1.090000, and the LP's 220e6
    ///         then lands as 201.834...e18 shares — final state 1_320e6 against a cap worth
    ///         1_100e18 * 1.090000 = 1_199e6.
    ///         The old check rebuilt the projection from `snap.totalAssets` plus the Cash
    ///         Vault's own net flow — 1_100e6 + 0, comfortably under 1_199e6 — and never saw
    ///         the bridge at all. Asserted below so the blind spot cannot come back.
    function test_capShare_catchesLpBridgeInflow() public {
        _runCycleZero();
        _setCashCapShare(1_100e18);

        usdt.mint(address(cashVault), CASH_YIELD);
        uint256 lpRid = _requestDeposit(address(lpVault), bob, LP_DEPOSIT);
        _advanceBothToCalculating();

        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](2);
        vs[0] = _vs(address(lpVault), _rs(lpRid, LP_DEPOSIT), _none());
        vs[1] = _vs(address(cashVault), _none(), _none());
        (ISettlement.SettlementInstruction memory instr, bytes[] memory sigs) =
            _prepare(vs, sm.currentCycleNumber(address(cashVault)));

        // The Cash Vault's own settlement in this batch accepts nothing of its own — its net
        // deposit/redeem movement is zero. The breach comes entirely from the LP Vault's bridged
        // subscription, which charged the quota at mint time inside EarnVault.deposit, so the
        // Cash Vault's authoritative check sees it. The exact overshoot depends on the price the
        // bridge minted at (CASH_YIELD has already moved it), so only the selector is pinned.
        vm.expectPartialRevert(IBaseVault.SupplyCapExceeded.selector);
        settlement.submitBatch(instr, sigs);
    }

    /// @notice LP-only batch: the Cash Vault's settle() is never called, so the only gate is the
    ///         share-form check in EarnVault.deposit(). The Cash Vault stays ACCEPTING here, so
    ///         that check is armed. 1_000e18 outstanding + a 220e6 bridge mint at price 1.0
    ///         breaches the 1_100e18 cap.
    function test_capShare_catchesLpOnlyBatchBridgeMint() public {
        _runCycleZero();
        _setCashCapShare(1_100e18);

        uint256 lpRid = _requestDeposit(address(lpVault), bob, LP_DEPOSIT);
        _advanceLpOnlyToCalculating();

        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](1);
        vs[0] = _vs(address(lpVault), _rs(lpRid, LP_DEPOSIT), _none());
        (ISettlement.SettlementInstruction memory instr, bytes[] memory sigs) =
            _prepare(vs, sm.currentCycleNumber(address(lpVault)));

        vm.expectRevert(
            abi.encodeWithSelector(IBaseVault.SupplyCapExceeded.selector, uint256(1_100e18), uint256(1_220e18))
        );
        settlement.submitBatch(instr, sigs);
    }

    /// @notice No false positive on a net-redeem cycle. The bridge takes supply to
    ///         1_211.009...e18 — over the 1_100e18 cap — mid-settlement, and the 200e18 redeem
    ///         burn brings the final state back to 1_011.009...e18 / 1_102e6, under the 1_199e6
    ///         ceiling. The Cash Vault is CALCULATING throughout, so deposit()'s check stands
    ///         down and only settle()'s end-of-cycle check applies.
    function test_capShare_allowsBridgeOvershootThatRedeemsBurnBackDown() public {
        (uint256 lpRid, uint256 redeemRid) = _setupRedeemGapScenario();
        _setCashCapShare(1_100e18);

        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](2);
        vs[0] = _vs(address(lpVault), _rs(lpRid, LP_DEPOSIT), _none());
        vs[1] = _vs(address(cashVault), _none(), _rs(redeemRid, 200e18));
        _submit(vs, sm.currentCycleNumber(address(cashVault)));

        assertEq(cashVault.totalSupply(), 1_011_009_174_311_926_605_504, "final supply back under cap");
        assertEq(cashVault.totalAssets(), 1_102e6, "final AUM under capShare * price / 1e18");
    }

    /// @notice Documents the known liveness cost of deposit()'s guard standing down while the Cash
    ///         Vault is CALCULATING — not a bug. An LP-only batch bridges 220e6 in, taking the Cash
    ///         Vault to 1_220e18 shares over its 1_100e18 cap, and that batch SUCCEEDS because the
    ///         fast-fail guard is disarmed. The cap is still enforced, just non-atomically: the
    ///         Cash Vault cannot complete its cycle without a settle(), and that settle() reverts
    ///         on the authoritative check. The bridging batch cannot be rolled back, so the Cash
    ///         Vault's cycle wedges in CALCULATING until the cap is raised via the Timelock.
    function test_capShare_calculatingOvershootIsCaughtLateAndWedgesTheCycle() public {
        _runCycleZero();
        _setCashCapShare(1_100e18);

        uint256 lpRid = _requestDeposit(address(lpVault), bob, LP_DEPOSIT);
        _advanceBothToCalculating();

        // 1. LP-only batch. The bridge mints 220e18 into a CALCULATING Cash Vault, breaching the
        //    cap, and the batch still lands.
        ISettlement.VaultSettlement[] memory lpOnly = new ISettlement.VaultSettlement[](1);
        lpOnly[0] = _vs(address(lpVault), _rs(lpRid, LP_DEPOSIT), _none());
        _submit(lpOnly, sm.currentCycleNumber(address(lpVault)));

        assertEq(cashVault.totalSupply(), 1_220e18, "over cap, and it settled anyway");
        assertEq(uint8(sm.getCycleState(address(cashVault))), uint8(CycleState.CALCULATING));

        // 2. The Cash Vault's own settlement is the backstop, and it cannot pass.
        ISettlement.VaultSettlement[] memory cashOnly = new ISettlement.VaultSettlement[](1);
        cashOnly[0] = _vs(address(cashVault), _none(), _none());
        (ISettlement.SettlementInstruction memory instr, bytes[] memory sigs) =
            _prepare(cashOnly, sm.currentCycleNumber(address(cashVault)));

        // Quota usage equals total supply here: cycle zero's subscriptions plus the bridged
        // mint, with no performance fee charged on this vault.
        vm.expectRevert(
            abi.encodeWithSelector(IBaseVault.SupplyCapExceeded.selector, uint256(1_100e18), cashVault.totalSupply())
        );
        settlement.submitBatch(instr, sigs);

        // Wedged: the cycle cannot complete until the Curator raises the cap.
        assertEq(uint8(sm.getCycleState(address(cashVault))), uint8(CycleState.CALCULATING));
    }

    // -----------------------------------------------------------------------
    // Log-order helper
    // -----------------------------------------------------------------------

    function _assertLogOrder(bytes32 firstTopic, bytes32 secondTopic) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256 firstIdx = -1;
        int256 secondIdx = -1;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (firstIdx < 0 && logs[i].topics[0] == firstTopic) firstIdx = int256(i);
            if (secondIdx < 0 && logs[i].topics[0] == secondTopic) secondIdx = int256(i);
        }
        assertGe(firstIdx, 0, "first event not emitted");
        assertGe(secondIdx, 0, "second event not emitted");
        assertLt(firstIdx, secondIdx, "events emitted out of order");
    }
}
