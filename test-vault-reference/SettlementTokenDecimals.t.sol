// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HyperAccessControl} from "../src/governance/HyperAccessControl.sol";
import {VaultTimelock} from "../src/governance/VaultTimelock.sol";
import {StateManager} from "../src/asset-management/StateManager.sol";
import {Queue} from "../src/asset-management/settlement/Queue.sol";
import {EarnVault} from "../src/asset-management/vaults/EarnVault.sol";
import {LiquidityEarnVault} from "../src/asset-management/vaults/LiquidityEarnVault.sol";
import {LiquidityBridge} from "../src/asset-management/vaults/LiquidityBridge.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {ProductState, CycleState, ProductParams, RequestSettlement} from "../src/libs/Types.sol";

/// @notice Settlement-token mock whose `decimals()` is fixed at construction.
contract MockStable is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Mock Stable", "USDT") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title SettlementTokenDecimalsTest
/// @notice Every price in BaseVault is denominated in "settlement-token units per 1e18 shares",
///         so the 1:1 parity price is `10 ** usdt.decimals()` — not the 1_000_000 that was
///         hardcoded while the only settlement token in sight was a 6-decimal USDT. BSC mainnet
///         USDT is 18-decimal, where that constant
///         priced the empty vault's first share at one-trillionth of a token: the opening
///         subscription minted 1e12 times too many shares, and the first performance-fee snapshot
///         read the entire NAV as profit against a 1e6 high-water mark.
///
///         This suite runs the full deposit / settlement / redemption / subscription-cap /
///         LP-bridge surface twice — once against a 6-decimal token, once against an 18-decimal
///         one — and asserts in units of `ONE = 10 ** decimals`, so a decimals-dependent result
///         fails in exactly one of the two concrete contracts at the bottom of this file.
abstract contract SettlementTokenDecimalsTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    MockStable internal usdt;
    LiquidityBridge internal bridge;
    EarnVault internal vault; // Cash vault — also the LP vault's bridge target
    LiquidityEarnVault internal lpVault;
    VaultTimelock internal tl;

    address internal governor = makeAddr("governor");
    address internal curator = makeAddr("curator");
    address internal factory = makeAddr("factory");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal settlement = makeAddr("settlement");
    address internal feeSink = makeAddr("feeSink");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant SHARE_SCALE = 1e18;

    /// @notice One whole settlement token, i.e. the vault's 1:1 parity price.
    uint256 internal ONE;

    mapping(uint256 => uint256) internal _reqAssets;
    mapping(uint256 => uint256) internal _reqShares;

    /// @dev Implemented by the two concrete suites at the bottom of this file.
    function _settlementDecimals() internal pure virtual returns (uint8);

    function setUp() public {
        vm.warp(NOW);

        usdt = new MockStable(_settlementDecimals());
        ONE = 10 ** _settlementDecimals();

        ac = new HyperAccessControl(governor);
        sm = new StateManager(address(ac));
        queue = new Queue(address(sm));
        bridge = new LiquidityBridge(address(usdt), address(sm), address(ac));

        vm.prank(governor);
        sm.setVaultFactory(factory);

        vault = new EarnVault(
            "HyperTessera Cash Earn", "htCASH", address(usdt), address(sm), address(queue), governor, address(bridge)
        );
        lpVault = new LiquidityEarnVault(
            "HyperTessera LP Earn",
            "htLP",
            address(usdt),
            address(sm),
            address(queue),
            governor,
            address(bridge),
            address(vault)
        );

        tl = new VaultTimelock(address(vault));
        vm.startPrank(factory);
        vault.bindGovernance(address(tl));
        sm.registerVault(address(vault));
        sm.registerVault(address(lpVault));
        vm.stopPrank();

        vm.startPrank(governor);
        bridge.setBridgeWhitelisted(address(vault), true);
        bridge.setBridgeWhitelisted(address(lpVault), true);
        vault.setCurator(curator);
        vault.setGuardian(guardian);
        vault.setKeeper(keeper, true);
        vault.setSettlement(settlement);
        lpVault.setCurator(curator);
        lpVault.setGuardian(guardian);
        lpVault.setKeeper(keeper, true);
        lpVault.setSettlement(settlement);
        vm.stopPrank();

        vm.startPrank(curator);
        sm.setProductParams(address(vault), _defaultParams());
        sm.setProductParams(address(lpVault), _defaultParams());
        vm.stopPrank();

        vm.startPrank(keeper);
        sm.openSubscription(address(vault));
        sm.openSubscription(address(lpVault));
        vm.stopPrank();

        usdt.mint(alice, 100_000 * ONE);
        usdt.mint(bob, 100_000 * ONE);
    }

    // -----------------------------------------------------------------------
    // Parity price
    // -----------------------------------------------------------------------

    function test_parityPrice_isOneWholeSettlementToken() public view {
        assertEq(vault.parityPrice(), ONE, "cash vault parity price");
        assertEq(lpVault.parityPrice(), ONE, "lp vault parity price");
    }

    function test_emptyVault_convertsOneTokenToOneShare() public view {
        assertEq(vault.totalSupply(), 0, "precondition: empty vault");
        assertEq(vault.convertToShares(ONE), SHARE_SCALE, "1 token -> 1 share");
        assertEq(vault.convertToAssets(SHARE_SCALE), ONE, "1 share -> 1 token");
    }

    function test_feeHighWaterMark_seededAtParity() public view {
        assertEq(vault.feeHighWaterMark(), ONE, "HWM seeded at the 1:1 reference price");
    }

    // -----------------------------------------------------------------------
    // Deposit → settle → claim
    // -----------------------------------------------------------------------

    function test_deposit_settleAtParity_mintsOneSharePerToken() public {
        uint256 assets = 1_000 * ONE;
        uint256 rid = _requestDeposit(alice, assets);

        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        vm.prank(alice);
        uint256 shares = vault.claimDeposit(rid, alice);

        assertEq(shares, 1_000 * SHARE_SCALE, "shares minted at parity");
        assertEq(vault.balanceOf(alice), 1_000 * SHARE_SCALE);
        assertEq(vault.totalSupply(), 1_000 * SHARE_SCALE);
        assertEq(vault.totalAssets(), assets, "NAV is the deposited token amount");
        assertEq(vault.convertToAssets(shares), assets, "round-trips back to the deposit");
    }

    function test_deposit_secondCycleAtGrownPrice_mintsFewerShares() public {
        _giveAliceShares(1_000 * ONE);

        // +100% yield: 1_000 tokens of adapter profit land in the vault, price doubles.
        usdt.mint(address(vault), 1_000 * ONE);
        assertEq(vault.convertToShares(ONE), SHARE_SCALE / 2, "1 token now buys half a share");

        uint256 rid = _requestDeposit(bob, 1_000 * ONE);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        vm.prank(bob);
        uint256 shares = vault.claimDeposit(rid, bob);
        assertEq(shares, 500 * SHARE_SCALE, "priced at 2 tokens per share");
    }

    // -----------------------------------------------------------------------
    // Settlement price snapshot
    // -----------------------------------------------------------------------

    function test_snapshot_emptyVault_recordsParityPrice() public {
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));

        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        (,, uint256 settlementPrice,,,, bool initialized) = vault.cycleSnapshots(cycleNumber);
        assertTrue(initialized);
        assertEq(settlementPrice, ONE, "empty vault settles at parity, not at 1e6");
    }

    function test_snapshot_afterYield_recordsGrownPrice() public {
        _giveAliceShares(1_000 * ONE);
        usdt.mint(address(vault), 500 * ONE); // +50%

        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        (uint256 totalAssets_, uint256 totalSupply_, uint256 settlementPrice,,,,) = vault.cycleSnapshots(cycleNumber);
        assertEq(totalAssets_, 1_500 * ONE);
        assertEq(totalSupply_, 1_000 * SHARE_SCALE);
        assertEq(settlementPrice, (ONE * 3) / 2, "1.5 tokens per share");
    }

    /// @notice Regression: the high-water mark starts at parity, so a flat first cycle accrues no
    ///         performance fee. Against an 18-decimal token and a 1e6 HWM, the first snapshot read
    ///         the whole NAV as profit and minted a fee against all of it.
    function test_snapshot_flatPrice_accruesNoPerformanceFee() public {
        _enablePerformanceFee(1_000); // 10%
        _giveAliceShares(1_000 * ONE);

        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        (,,, uint256 feeAssets, uint256 feeShares,,) = vault.cycleSnapshots(cycleNumber);
        assertEq(feeAssets, 0, "no profit above the parity HWM");
        assertEq(feeShares, 0);
        assertEq(vault.balanceOf(feeSink), 0);
        assertEq(vault.totalSupply(), 1_000 * SHARE_SCALE, "no dilution");
    }

    function test_snapshot_realProfit_chargesFeeOnTheProfitOnly() public {
        _enablePerformanceFee(1_000); // 10%
        _giveAliceShares(1_000 * ONE);

        usdt.mint(address(vault), 100 * ONE); // +10% profit
        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.prank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);

        (,,, uint256 feeAssets, uint256 feeShares,,) = vault.cycleSnapshots(cycleNumber);
        assertEq(feeAssets, 10 * ONE, "10% of the 100-token profit");
        assertEq(vault.balanceOf(feeSink), feeShares);
        // Fee shares are minted against the post-fee NAV, so their value is the fee itself.
        assertApproxEqAbs(vault.convertToAssets(feeShares), 10 * ONE, 2, "fee shares are worth the fee");
        assertEq(vault.feeHighWaterMark(), vault.convertToAssets(SHARE_SCALE), "HWM ratchets to the new price");
    }

    // -----------------------------------------------------------------------
    // Redeem → settle → claim
    // -----------------------------------------------------------------------

    function test_redeem_atParity_returnsTheDepositedTokens() public {
        uint256 assets = 1_000 * ONE;
        uint256 shares = _giveAliceShares(assets);

        uint256 rid = _queueRedeem(alice, shares);
        _advanceToCalculating();
        _settleRedeems(_arr(rid), 0);

        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        vault.claimRedeem(rid, alice);

        assertEq(usdt.balanceOf(alice) - before, assets, "full principal back");
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.reservedRedeemLiability(), 0);
    }

    function test_redeem_afterYield_returnsGrownValue() public {
        uint256 shares = _giveAliceShares(1_000 * ONE);
        usdt.mint(address(vault), 1_000 * ONE); // price doubles

        uint256 rid = _queueRedeem(alice, shares);
        _advanceToCalculating();
        _settleRedeems(_arr(rid), 0);

        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        vault.claimRedeem(rid, alice);

        assertEq(usdt.balanceOf(alice) - before, 2_000 * ONE, "principal + 100% yield");
    }

    // -----------------------------------------------------------------------
    // Subscription cap — quota is share-denominated, so it is decimals-invariant
    // -----------------------------------------------------------------------

    function test_subscriptionCap_exactlyAtCapPasses() public {
        _giveAliceShares(1_000 * ONE);
        _setCapShare(1_500 * SHARE_SCALE);

        uint256 rid = _requestDeposit(bob, 500 * ONE);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));

        assertEq(vault.totalSupply(), 1_500 * SHARE_SCALE, "share form: exactly at cap");
        assertEq(vault.totalAssets(), 1_500 * ONE, "AUM form: capShare * parity price");
    }

    function test_subscriptionCap_oneTokenUnitOverReverts() public {
        _giveAliceShares(1_000 * ONE);
        _setCapShare(1_500 * SHARE_SCALE);

        // The smallest settlement-token unit buys `1e18 / ONE` shares — 1e12 at 6 decimals,
        // 1 wei of share at 18 — and either way it is enough to reject the batch.
        uint256 overshootShares = SHARE_SCALE / ONE;
        uint256 rid = _requestDeposit(bob, 500 * ONE + 1);
        _advanceToCalculating();

        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseVault.SupplyCapExceeded.selector, 1_500 * SHARE_SCALE, 1_500 * SHARE_SCALE + overshootShares
            )
        );
        vault.settle(cycleNumber, _rs1(rid, 500 * ONE + 1), _rs0(), 0);
        vm.stopPrank();
    }

    function test_subscriptionCap_headroomRepricedAfterYield() public {
        uint256 shares = _giveAliceShares(1_000 * ONE);
        _setCapShare(shares); // zero headroom in share terms

        usdt.mint(address(vault), 500 * ONE); // NAV growth alone must not consume quota

        _advanceToCalculating();
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, _rs0(), _rs0(), 0); // empty batch settles fine at the new price
        vm.stopPrank();

        assertEq(vault.totalSupply(), shares);
        assertEq(vault.totalAssets(), 1_500 * ONE);
    }

    // -----------------------------------------------------------------------
    // LP Bridge — LiquidityEarnVault.settle bridges into the cash vault
    // -----------------------------------------------------------------------

    function test_lpBridge_mintsCashSharesAtParityAndDistributesProRata() public {
        uint256 assetsAlice = 1_000 * ONE;
        uint256 assetsBob = 3_000 * ONE; // 3x alice -> 3x of both outputs
        uint256 bonus = 400 * ONE;

        uint256 ridAlice = _requestLpDeposit(alice, assetsAlice);
        uint256 ridBob = _requestLpDeposit(bob, assetsBob);
        _advanceLpToCalculating();

        // The bonus USDT UnifiedPool would already have distributed in.
        usdt.mint(address(lpVault), bonus);

        uint256 aliceUsdtBefore = usdt.balanceOf(alice);
        uint256 bobUsdtBefore = usdt.balanceOf(bob);

        uint256 cycleNumber = sm.currentCycleNumber(address(lpVault));
        vm.startPrank(settlement);
        lpVault.snapshotSettlementPrice(cycleNumber);
        lpVault.settle(cycleNumber, _lpBatch(ridAlice, ridBob), _rs0(), bonus);
        vm.stopPrank();

        // The LP tranche never mints its own shares; everything is bridged out.
        assertEq(lpVault.totalSupply(), 0);
        assertEq(usdt.balanceOf(address(lpVault)), 0, "no dust left behind");
        assertEq(usdt.balanceOf(address(vault)), assetsAlice + assetsBob, "principal bridged into cash");

        // Cash vault was empty, so the bridged mint prices at parity: 1 token -> 1 share.
        assertEq(vault.totalSupply(), 4_000 * SHARE_SCALE, "bridged mint at parity");
        assertEq(vault.balanceOf(alice), 1_000 * SHARE_SCALE);
        assertEq(vault.balanceOf(bob), 3_000 * SHARE_SCALE);
        assertEq(vault.balanceOf(address(lpVault)), 0, "cash shares fully distributed");

        // Bonus USDT pro-rata in the settlement token's own decimals.
        assertEq(usdt.balanceOf(alice) - aliceUsdtBefore, 100 * ONE);
        assertEq(usdt.balanceOf(bob) - bobUsdtBefore, 300 * ONE);
    }

    function test_lpBridge_mintsAtTheCashVaultsCurrentPrice() public {
        // Seed the cash vault and double its price, so the bridged mint is not at parity.
        _giveAliceShares(1_000 * ONE);
        usdt.mint(address(vault), 1_000 * ONE);

        uint256 rid = _requestLpDeposit(bob, 1_000 * ONE);
        _advanceLpToCalculating();

        uint256 cycleNumber = sm.currentCycleNumber(address(lpVault));
        vm.startPrank(settlement);
        lpVault.snapshotSettlementPrice(cycleNumber);
        lpVault.settle(cycleNumber, _lpBatch1(rid), _rs0(), 0);
        vm.stopPrank();

        assertEq(vault.balanceOf(bob), 500 * SHARE_SCALE, "bridged in at 2 tokens per share");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _defaultParams() internal pure returns (ProductParams memory) {
        return ProductParams({
            subscriptionStart: NOW,
            subscriptionEnd: NOW + 7 days,
            walletSubscriptionCap: 0,
            minRaiseAmount: 0,
            subscriptionCapShare: 0,
            cycleDuration: 7 days,
            maturityTimestamp: NOW + 365 days,
            claimingStart: NOW + 370 days,
            claimingEnd: NOW + 400 days,
            feeParams: 0
        });
    }

    function _scheduleAndExecute(address proposer, bytes memory data) internal {
        vm.prank(proposer);
        bytes32 id = tl.scheduleParamChange(address(vault), data);
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(id);
    }

    function _enablePerformanceFee(uint16 bps) internal {
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (feeSink)));
        _scheduleAndExecute(curator, abi.encodeCall(IBaseVault.setPerformanceFeeBps, (bps)));
    }

    function _setCapShare(uint256 capShare) internal {
        vm.prank(address(tl));
        vault.setSubscriptionCapShare(capShare);
    }

    function _requestDeposit(address user, uint256 amount) internal returns (uint256 rid) {
        vm.startPrank(user);
        usdt.approve(address(vault), amount);
        rid = vault.requestDeposit(amount, user);
        vm.stopPrank();
        _reqAssets[rid] = amount;
    }

    function _requestLpDeposit(address user, uint256 amount) internal returns (uint256 rid) {
        vm.startPrank(user);
        usdt.approve(address(lpVault), amount);
        rid = lpVault.requestDeposit(amount, user);
        vm.stopPrank();
        _reqAssets[rid] = amount;
    }

    function _giveAliceShares(uint256 assets) internal returns (uint256 shares) {
        uint256 rid = _requestDeposit(alice, assets);
        _advanceToCalculating();
        _settleDeposits(_arr(rid));
        vm.prank(alice);
        shares = vault.claimDeposit(rid, alice);
    }

    function _queueRedeem(address user, uint256 shares) internal returns (uint256 rid) {
        vm.startPrank(user);
        vault.approve(address(vault), shares);
        rid = vault.requestRedeem(shares, user);
        vm.stopPrank();
        _reqShares[rid] = shares;
    }

    function _advanceToCalculating() internal {
        _advanceToCalculating(address(vault));
    }

    function _advanceLpToCalculating() internal {
        _advanceToCalculating(address(lpVault));
    }

    function _advanceToCalculating(address v) internal {
        ProductParams memory p = sm.getParams(v);

        if (uint8(sm.getProductState(v)) == uint8(ProductState.SUBSCRIBING)) {
            uint256 target = p.subscriptionEnd + p.cycleDuration + 1;
            if (block.timestamp < target) vm.warp(target);
            vm.prank(keeper);
            sm.finalizeSubscription(v);
        }

        if (
            uint8(sm.getProductState(v)) == uint8(ProductState.OPERATING)
                && uint8(sm.getCycleState(v)) == uint8(CycleState.ACCEPTING)
        ) {
            uint256 target = sm.currentCycleStart(v) + p.cycleDuration + 1;
            if (block.timestamp < target) vm.warp(target);
            vm.prank(keeper);
            sm.startCycleCalculation(v);
        }
    }

    function _settleDeposits(uint256[] memory ids) internal {
        _settle(_toDeposits(ids), _rs0(), 0);
    }

    function _settleRedeems(uint256[] memory ids, uint256 poolDistributedAssets) internal {
        _settle(_rs0(), _toRedeems(ids), poolDistributedAssets);
    }

    function _settle(
        RequestSettlement[] memory deposits,
        RequestSettlement[] memory redeems,
        uint256 poolDistributedAssets
    ) internal {
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        vm.startPrank(settlement);
        vault.snapshotSettlementPrice(cycleNumber);
        vault.settle(cycleNumber, deposits, redeems, poolDistributedAssets);
        sm.completeCycle(address(vault));
        vm.stopPrank();
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

    function _lpBatch1(uint256 id) internal view returns (RequestSettlement[] memory out) {
        out = new RequestSettlement[](1);
        out[0] = RequestSettlement({requestId: id, settleAmount: _reqAssets[id]});
    }

    function _lpBatch(uint256 a, uint256 b) internal view returns (RequestSettlement[] memory out) {
        out = new RequestSettlement[](2);
        out[0] = RequestSettlement({requestId: a, settleAmount: _reqAssets[a]});
        out[1] = RequestSettlement({requestId: b, settleAmount: _reqAssets[b]});
    }

    function _rs1(uint256 id, uint256 amount) internal pure returns (RequestSettlement[] memory out) {
        out = new RequestSettlement[](1);
        out[0] = RequestSettlement({requestId: id, settleAmount: amount});
    }

    function _rs0() internal pure returns (RequestSettlement[] memory) {
        return new RequestSettlement[](0);
    }
}

/// @notice 6-decimal settlement token — the shape every earlier version was tested against.
contract SettlementToken6DecimalsTest is SettlementTokenDecimalsTest {
    function _settlementDecimals() internal pure override returns (uint8) {
        return 6;
    }
}

/// @notice 18-decimal settlement token — BSC mainnet USDT.
contract SettlementToken18DecimalsTest is SettlementTokenDecimalsTest {
    function _settlementDecimals() internal pure override returns (uint8) {
        return 18;
    }
}
