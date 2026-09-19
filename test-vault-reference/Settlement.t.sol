// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HyperAccessControl} from "../src/governance/HyperAccessControl.sol";
import {StateManager} from "../src/asset-management/StateManager.sol";
import {IStateManager} from "../src/interfaces/IStateManager.sol";
import {EarnVault} from "../src/asset-management/vaults/EarnVault.sol";
import {Queue} from "../src/asset-management/settlement/Queue.sol";
import {UnifiedPool} from "../src/asset-management/settlement/UnifiedPool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RevenuePool} from "../src/asset-management/settlement/RevenuePool.sol";
import {Settlement} from "../src/asset-management/settlement/Settlement.sol";
import {ISettlement} from "../src/interfaces/ISettlement.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {IStateManager} from "../src/interfaces/IStateManager.sol";
import {IQueue} from "../src/interfaces/IQueue.sol";
import {IUnifiedPool} from "../src/interfaces/IUnifiedPool.sol";
import {ProductState, CycleState, PauseState, ProductParams, QueueType, RequestSettlement} from "../src/libs/Types.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("MockUSDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title SettlementTest
/// @notice Net-settlement Settlement.sol suite (development-plan §8): M-of-N signatures,
///         per-vault cycle-state check, and pool-cash conservation (availableToDistribute +
///         aggregate batch-vs-actual-cash). No NAVOracle consistency step — BaseVault computes
///         its own on-chain settlement price via snapshotSettlementPrice.
contract SettlementTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    MockUSDT internal usdt;
    RevenuePool internal revPool;
    UnifiedPool internal unifiedPool;
    EarnVault internal vault;
    Settlement internal settlement;

    address internal governor = makeAddr("governor");
    address internal keeper = makeAddr("keeper");
    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    uint256 internal operator1Pk = 0xBEEF1;
    uint256 internal operator2Pk = 0xBEEF2;
    address internal operator1;
    address internal operator2;

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant INITIAL_PRICE = 1_000_000; // 1.0 in 6-dec

    function setUp() public {
        vm.warp(NOW);
        operator1 = vm.addr(operator1Pk);
        operator2 = vm.addr(operator2Pk);

        ac = new HyperAccessControl(governor);
        usdt = new MockUSDT();
        sm = new StateManager(address(ac));
        queue = new Queue(address(sm));
        revPool = new RevenuePool(address(usdt), address(ac));
        UnifiedPool unifiedPoolImpl = new UnifiedPool();
        bytes memory unifiedPoolInitData =
            abi.encodeCall(UnifiedPool.initialize, (address(usdt), address(sm), address(ac)));
        unifiedPool = UnifiedPool(address(new ERC1967Proxy(address(unifiedPoolImpl), unifiedPoolInitData)));

        // `governor` doubles as this vault's Owner (IVaultRoles) — Vault-local roles
        // (Owner/Curator/Keeper) are no longer HyperAccessControl-granted; the deploying
        // account is simply passed in as owner_ and appoints the rest itself below.
        vault = new EarnVault(
            "HyperTessera Cash Earn", "htCASH", address(usdt), address(sm), address(queue), governor, address(0)
        );

        settlement = new Settlement(address(sm), address(unifiedPool), address(queue));

        vm.startPrank(governor);
        revPool.addAuthorizedSource(address(unifiedPool));

        // Registration first: UnifiedPool now only accepts vaults StateManager knows about
        // (审计反馈 2026-08-17 #1).
        sm.setVaultFactory(governor);
        sm.registerVault(address(vault));
        unifiedPool.addVault(address(vault));
        // Governor admission to the shared pool, separate from the Vault opting in above
        // (审计反馈 V3 #1/#2).
        unifiedPool.setVaultWhitelisted(address(vault), true);
        unifiedPool.setSettlementWhitelisted(address(settlement), true);
        vault.setCurator(governor);
        sm.setProductParams(address(vault), _defaultParams());
        vault.setKeeper(keeper, true);
        vault.setSettlement(address(settlement));

        settlement.setOperator(address(vault), operator1, true);
        settlement.setOperator(address(vault), operator2, true);
        settlement.setThreshold(address(vault), 1);
        vm.stopPrank();

        vm.prank(keeper);
        sm.openSubscription(address(vault));

        usdt.mint(alice, 100_000e6);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _defaultParams() internal view returns (ProductParams memory) {
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

    function _requestDeposit(address who, uint256 assets) internal returns (uint256 rid) {
        vm.startPrank(who);
        usdt.approve(address(vault), assets);
        rid = vault.requestDeposit(assets, who);
        vm.stopPrank();
    }

    function _advanceToOperating() internal {
        vm.warp(NOW + 7 days);
        vm.prank(keeper);
        sm.finalizeSubscription(address(vault));
    }

    function _advanceToCalculating() internal {
        uint256 cycleStart = sm.currentCycleStart(address(vault));
        ProductParams memory p = sm.getParams(address(vault));
        uint256 target = cycleStart + p.cycleDuration + 1;
        if (block.timestamp < target) vm.warp(target);
        vm.prank(keeper);
        sm.startCycleCalculation(address(vault));
    }

    /// @dev SETTLING is reached by running the product's FINAL cycle: after maturity the Keeper
    ///      starts one more CALCULATING round and its (possibly empty) batch takes the product
    ///      OPERATING → SETTLING inside `completeCycle`
    ///      (一年期产品最终周期结算与产品参数调整说明 §5).
    function _advanceToSettling() internal {
        _advanceToOperating();
        // Cycle 0 lands on CALCULATING; settle its empty batch first to get back to ACCEPTING.
        _submit(_instruction(ISettlement.Distribution({vault: address(vault), amount: 0})), operator1Pk);
        ProductParams memory p = sm.getParams(address(vault));
        vm.warp(p.maturityTimestamp + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(address(vault));
        _submit(_instruction(ISettlement.Distribution({vault: address(vault), amount: 0})), operator1Pk);
    }

    // -----------------------------------------------------------------------
    // Final cycle (一年期产品最终周期结算与产品参数调整说明)
    // -----------------------------------------------------------------------

    /// @dev The final cycle must be settleable with an empty queue — that is the normal case for
    ///      a one-year product whose last cycle has no pending requests — and its batch is what
    ///      generates the maturity price snapshot and takes the product into SETTLING (§5.4).
    function test_finalCycle_emptyBatchSnapshotsPriceAndEntersSettling() public {
        _advanceToOperating();
        _submit(_instruction(ISettlement.Distribution({vault: address(vault), amount: 0})), operator1Pk);

        ProductParams memory p = sm.getParams(address(vault));
        vm.warp(p.maturityTimestamp + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(address(vault));

        uint256 finalCycle = sm.currentCycleNumber(address(vault));
        _submit(_instruction(ISettlement.Distribution({vault: address(vault), amount: 0})), operator1Pk);

        (,,,,,, bool initialized) = vault.cycleSnapshots(finalCycle);
        assertTrue(initialized, "maturity price snapshot generated");
        assertEq(uint8(sm.getProductState(address(vault))), uint8(ProductState.MATURING));
        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.ACCEPTING));
    }

    /// @dev And the product does not reopen to new requests in between: the cycle returns to
    ///      ACCEPTING in the same transaction that moves the product to SETTLING, where both
    ///      gates reject (§5.5).
    function test_finalCycle_doesNotReopenSubscriptionsOrRedeems() public {
        _advanceToSettling();

        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.SUBSCRIBING, ProductState.MATURING
            )
        );
        sm.requireSubscribable(address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.OPERATING, ProductState.MATURING
            )
        );
        sm.requireOperable(address(vault));
    }

    /// @dev The final batch may not accept subscriptions: a deposit settled at maturity would
    ///      mint shares against a price struck on wound-down assets, with nothing left to invest
    ///      in (最终周期结算及最终兑付补充修改方案 §七.1, §八).
    function test_finalBatch_rejectsDepositSettlements() public {
        _advanceToOperating();
        _submit(_instruction(ISettlement.Distribution({vault: address(vault), amount: 0})), operator1Pk);

        uint256 rid = _requestDeposit(alice, 1_000e6);
        ProductParams memory p = sm.getParams(address(vault));
        vm.warp(p.maturityTimestamp + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(address(vault));

        ISettlement.SettlementInstruction memory instr = _instructionWithRequests(
            ISettlement.Distribution({vault: address(vault), amount: 0}), _rs1(rid, 1_000e6), new RequestSettlement[](0)
        );
        bytes[] memory _s = _sigsFor(instr, operator1Pk); // hoisted: hashInstruction is an external call, expectRevert binds to the next one
        vm.expectRevert(abi.encodeWithSelector(ISettlement.DepositsNotAllowedInFinalBatch.selector, address(vault)));
        settlement.submitBatch(instr, _s);
    }

    function _arr(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _empty() internal pure returns (uint256[] memory out) {
        out = new uint256[](0);
    }

    function _signOperator(uint256 pk, bytes32 batchHash) internal pure returns (bytes memory) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", batchHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _instruction(ISettlement.Distribution memory dist)
        internal
        view
        returns (ISettlement.SettlementInstruction memory instr)
    {
        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](1);
        vs[0] = ISettlement.VaultSettlement({
            distribution: dist, deposits: new RequestSettlement[](0), redeems: new RequestSettlement[](0)
        });
        instr = ISettlement.SettlementInstruction({
            vaultSettlements: vs, cycleNumber: sm.currentCycleNumber(address(vault)), validUntil: block.timestamp + 3600
        });
    }

    function _sigsFor(ISettlement.SettlementInstruction memory instr, uint256 signerPk)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 hash = settlement.hashInstruction(instr); // domain-separated by Settlement address + chainid
        sigs = new bytes[](1);
        sigs[0] = _signOperator(signerPk, hash);
    }

    function _submit(ISettlement.SettlementInstruction memory instr, uint256 signerPk) internal {
        settlement.submitBatch(instr, _sigsFor(instr, signerPk));
    }

    function _instructionWithRequests(
        ISettlement.Distribution memory dist,
        RequestSettlement[] memory deposits,
        RequestSettlement[] memory redeems
    ) internal view returns (ISettlement.SettlementInstruction memory instr) {
        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](1);
        vs[0] = ISettlement.VaultSettlement({distribution: dist, deposits: deposits, redeems: redeems});
        instr = ISettlement.SettlementInstruction({
            vaultSettlements: vs, cycleNumber: sm.currentCycleNumber(address(vault)), validUntil: block.timestamp + 3600
        });
    }

    function _rs1(uint256 id, uint256 amount) internal pure returns (RequestSettlement[] memory out) {
        out = new RequestSettlement[](1);
        out[0] = RequestSettlement({requestId: id, settleAmount: amount});
    }

    // -----------------------------------------------------------------------
    // Happy path — empty batch
    // -----------------------------------------------------------------------

    function test_submitBatch_happyPath_emptyBatch_cycleCompletes() public {
        // Cycle 0 auto-transitions straight to CALCULATING on subscription finalization
        // (StateManager.finalizeSubscription) — no explicit startCycleCalculation needed here.
        _advanceToOperating();

        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);

        uint256 cycleBefore = sm.currentCycleNumber(address(vault));
        _submit(instr, operator1Pk);

        assertEq(uint8(sm.getCycleState(address(vault))), uint8(CycleState.ACCEPTING));
        assertEq(sm.currentCycleNumber(address(vault)), cycleBefore + 1);
    }

    // -----------------------------------------------------------------------
    // Step 1 — signatures
    // -----------------------------------------------------------------------

    function test_submitBatch_replayGuard_reverts() public {
        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);
        bytes32 hash = settlement.hashInstruction(instr);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signOperator(operator1Pk, hash);

        settlement.submitBatch(instr, sigs);

        vm.expectRevert(abi.encodeWithSelector(ISettlement.BatchAlreadyExecuted.selector, hash));
        settlement.submitBatch(instr, sigs);
    }

    function test_submitBatch_expiredValidUntil_reverts() public {
        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);
        instr.validUntil = block.timestamp - 1;

        bytes32 hash = settlement.hashInstruction(instr);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signOperator(operator1Pk, hash);

        vm.expectRevert(abi.encodeWithSelector(ISettlement.BatchExpired.selector, instr.validUntil, block.timestamp));
        settlement.submitBatch(instr, sigs);
    }

    function test_submitBatch_fewerSignaturesThanThreshold_reverts() public {
        vm.prank(governor);
        settlement.setThreshold(address(vault), 2);

        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);

        bytes[] memory _s2 = _sigsFor(instr, operator1Pk); // hoisted above expectRevert
        vm.expectRevert(abi.encodeWithSelector(ISettlement.SignatureValidationFailed.selector, address(vault)));
        settlement.submitBatch(instr, _s2);
    }

    function test_submitBatch_duplicateSigner_reverts() public {
        vm.prank(governor);
        settlement.setThreshold(address(vault), 2);

        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);

        bytes32 hash = settlement.hashInstruction(instr);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signOperator(operator1Pk, hash);
        sigs[1] = _signOperator(operator1Pk, hash);

        vm.expectRevert(abi.encodeWithSelector(ISettlement.SignatureValidationFailed.selector, address(vault)));
        settlement.submitBatch(instr, sigs);
    }

    function test_submitBatch_nonOperatorSigner_reverts() public {
        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);

        bytes[] memory _s2 = _sigsFor(instr, 0xDEAD); // hoisted above expectRevert
        vm.expectRevert(abi.encodeWithSelector(ISettlement.SignatureValidationFailed.selector, address(vault)));
        settlement.submitBatch(instr, _s2);
    }

    function test_submitBatch_badSig_revertReason_isSignatureValidationFailed() public {
        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);

        bytes[] memory _s3 = _sigsFor(instr, 0xC0FFEE); // hoisted above expectRevert
        vm.expectRevert(abi.encodeWithSelector(ISettlement.SignatureValidationFailed.selector, address(vault)));
        settlement.submitBatch(instr, _s3);
    }

    function test_submitBatch_unconfiguredVaultThreshold_reverts() public {
        // A Vault whose Owner never called `setThreshold` has threshold 0. An empty signature
        // array must NOT satisfy the M-of-N check for it.
        address unconfigured = makeAddr("unconfiguredVault");
        _advanceToOperating();

        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: unconfigured, amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);

        assertEq(settlement.threshold(unconfigured), 0);

        vm.expectRevert(abi.encodeWithSelector(ISettlement.SignatureValidationFailed.selector, unconfigured));
        settlement.submitBatch(instr, new bytes[](0));
    }

    // -----------------------------------------------------------------------
    // Step 2 — state
    // -----------------------------------------------------------------------

    function test_submitBatch_vaultNotCalculating_reverts() public {
        // Cycle 0 auto-transitions straight to CALCULATING on subscription finalization, so
        // settle it first — cycle 1 then starts ACCEPTING (not CALCULATING) as the normal case.
        _advanceToOperating();
        _submit(_instruction(ISettlement.Distribution({vault: address(vault), amount: 0})), operator1Pk);

        // Cycle 1: still ACCEPTING, not CALCULATING.
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);

        bytes[] memory _s2 = _sigsFor(instr, operator1Pk); // hoisted above expectRevert
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.CycleStateMismatch.selector, address(vault), CycleState.CALCULATING, CycleState.ACCEPTING
            )
        );
        settlement.submitBatch(instr, _s2);
    }

    function test_submitBatch_cycleNumberMismatch_reverts() public {
        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);
        instr.cycleNumber = instr.cycleNumber + 1;

        bytes[] memory _s2 = _sigsFor(instr, operator1Pk); // hoisted above expectRevert
        vm.expectRevert(abi.encodeWithSelector(ISettlement.StateValidationFailed.selector, address(vault)));
        settlement.submitBatch(instr, _s2);
    }

    // -----------------------------------------------------------------------
    // Step 3 — pool-cash conservation
    // -----------------------------------------------------------------------

    function test_submitBatch_insufficientPending_reverts() public {
        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 1e6});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);

        bytes[] memory _s2 = _sigsFor(instr, operator1Pk); // hoisted above expectRevert
        vm.expectRevert(abi.encodeWithSelector(ISettlement.ConservationCheckFailed.selector, address(vault), 0, 1e6));
        settlement.submitBatch(instr, _s2);
    }

    /// @dev NOTE: despite the historic name this exercises the *per-vault* availability check —
    ///      `availableToDistribute` is `min(pending, poolCash)`, so draining the pool's cash pulls
    ///      the single vault's own availability below its request and ConservationCheckFailed
    ///      fires before the aggregate `BatchExceedsPoolCash` check is ever reached. The genuine
    ///      aggregate case needs two vaults that each fit individually — see
    ///      `test_submitBatch_twoVaultsEachFitButBatchExceedsPoolCash_reverts` below.
    function test_submitBatch_perVaultAvailabilityShortfall_reverts() public {
        // Two vaults each individually within their own pending, but pool cash can't cover both.
        EarnVault vault2 = new EarnVault(
            "HyperTessera Cash Earn 2", "htCASH2", address(usdt), address(sm), address(queue), governor, address(0)
        );
        vm.startPrank(governor);
        sm.registerVault(address(vault2));
        vault2.setCurator(governor);
        sm.setProductParams(address(vault2), _defaultParams());
        vault2.setKeeper(keeper, true);
        vault2.setSettlement(address(settlement));
        unifiedPool.addVault(address(vault2));
        unifiedPool.setVaultWhitelisted(address(vault2), true);
        vm.stopPrank();
        vm.prank(keeper);
        sm.openSubscription(address(vault2));

        // Credit both vaults' pending, but only fund the pool with cash for one of them
        // (simulating pending accrued from an inflow accounted for but not yet reflected).
        usdt.mint(issuer, 1_000e6);
        vm.prank(issuer);
        usdt.approve(address(unifiedPool), 1_000e6);
        vm.prank(issuer);
        unifiedPool.repayInterest(1_000e6);
        vm.prank(operator1);
        unifiedPool.attributeInterest(address(vault), 1_000e6);

        // A Governor transfer takes 700e6 of cash back out of the pool, so only 300e6 of that
        // vault's pending is actually distributable (审计反馈 V3 #1 moved this off the Settlement
        // Operator; the ledger arithmetic is unchanged).
        vm.prank(governor);
        unifiedPool.operatorTransfer(address(vault), makeAddr("sink"), 700e6, bytes32(0));

        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 1_000e6});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);

        bytes[] memory _s2 = _sigsFor(instr, operator1Pk); // hoisted above expectRevert
        vm.expectRevert(
            abi.encodeWithSelector(ISettlement.ConservationCheckFailed.selector, address(vault), 300e6, 1_000e6)
        );
        settlement.submitBatch(instr, _s2);
    }

    /// @dev Spins up a second vault sharing the same StateManager/Settlement/UnifiedPool, wired to
    ///      the same operator set, and drives it to CALCULATING alongside `vault`.
    function _secondVaultInCalculating() internal returns (EarnVault vault2) {
        vault2 = new EarnVault(
            "HyperTessera Note Earn", "htNOTE", address(usdt), address(sm), address(queue), governor, address(0)
        );
        vm.startPrank(governor);
        sm.registerVault(address(vault2));
        vault2.setCurator(governor);
        sm.setProductParams(address(vault2), _defaultParams());
        vault2.setKeeper(keeper, true);
        vault2.setSettlement(address(settlement));
        unifiedPool.addVault(address(vault2));
        unifiedPool.setVaultWhitelisted(address(vault2), true);
        settlement.setOperator(address(vault2), operator1, true);
        settlement.setThreshold(address(vault2), 1);
        vm.stopPrank();
        vm.prank(keeper);
        sm.openSubscription(address(vault2));

        // Both vaults finalize in the same block, so both sit at cycle 0 / CALCULATING.
        vm.warp(NOW + 7 days);
        vm.startPrank(keeper);
        sm.finalizeSubscription(address(vault));
        sm.finalizeSubscription(address(vault2));
        vm.stopPrank();
    }

    function _fundPool(address forVault, uint256 amount) internal {
        usdt.mint(issuer, amount);
        vm.startPrank(issuer);
        usdt.approve(address(unifiedPool), amount);
        unifiedPool.repayInterest(amount);
        vm.stopPrank();
        vm.prank(operator1);
        unifiedPool.attributeInterest(forVault, amount);
    }

    function _twoVaultInstruction(address vaultA, uint256 amountA, address vaultB, uint256 amountB)
        internal
        view
        returns (ISettlement.SettlementInstruction memory instr)
    {
        ISettlement.VaultSettlement[] memory vs = new ISettlement.VaultSettlement[](2);
        vs[0] = ISettlement.VaultSettlement({
            distribution: ISettlement.Distribution({vault: vaultA, amount: amountA}),
            deposits: new RequestSettlement[](0),
            redeems: new RequestSettlement[](0)
        });
        vs[1] = ISettlement.VaultSettlement({
            distribution: ISettlement.Distribution({vault: vaultB, amount: amountB}),
            deposits: new RequestSettlement[](0),
            redeems: new RequestSettlement[](0)
        });
        instr = ISettlement.SettlementInstruction({
            vaultSettlements: vs, cycleNumber: sm.currentCycleNumber(address(vault)), validUntil: block.timestamp + 3600
        });
    }

    /// @dev The aggregate guard `availableToDistribute` alone cannot catch: two distinct vaults
    ///      each ask for 600 against their own 600 of pending, but the pool only holds 1_000 in
    ///      total. Both per-vault checks pass (`min(pending, cash)` == 600 each); only the
    ///      batch-wide sum spots the shortfall.
    /// @dev `pending` is a claim on pool-MANAGED assets, so an operator transfer moving cash
    ///      into an external position legitimately leaves the pool holding less cash than the
    ///      ledger totals (审计报告（一）回复 §1). The aggregate guard is what stops a batch whose
    ///      legs each fit their own vault's pending from collectively exceeding the cash on hand.
    function test_submitBatch_twoVaultsEachFitButBatchExceedsPoolCash_reverts() public {
        EarnVault vault2 = _secondVaultInCalculating();

        _fundPool(address(vault), 600e6);
        _fundPool(address(vault2), 600e6);
        vm.prank(governor);
        unifiedPool.operatorTransfer(address(vault), makeAddr("poolSink"), 200e6, bytes32(0));

        assertEq(unifiedPool.pending(address(vault)), 600e6, "ledger untouched by the transfer");
        assertEq(unifiedPool.pending(address(vault2)), 600e6);
        assertEq(usdt.balanceOf(address(unifiedPool)), 1_000e6, "cash is below the 1_200e6 ledger");
        assertEq(unifiedPool.availableToDistribute(address(vault)), 600e6, "vault A fits on its own");
        assertEq(unifiedPool.availableToDistribute(address(vault2)), 600e6, "vault B fits on its own");

        ISettlement.SettlementInstruction memory instr =
            _twoVaultInstruction(address(vault), 600e6, address(vault2), 600e6);
        bytes[] memory _s4 = _sigsFor(instr, operator1Pk);
        vm.expectRevert(
            abi.encodeWithSelector(ISettlement.BatchExceedsPoolCash.selector, uint256(1_200e6), uint256(1_000e6))
        );
        settlement.submitBatch(instr, _s4);
    }

    /// @dev The same vault appearing twice in one batch must have its distributions *summed*
    ///      before the availability check, not checked independently — otherwise two 600e6 legs
    ///      each pass against 1_000e6 of pending and the vault is paid 1_200e6.
    function test_submitBatch_sameVaultTwice_amountsAreSummedForConservation() public {
        _advanceToOperating();
        _fundPool(address(vault), 1_000e6);

        ISettlement.SettlementInstruction memory instr =
            _twoVaultInstruction(address(vault), 600e6, address(vault), 600e6);

        bytes[] memory _s = _sigsFor(instr, operator1Pk); // hoisted: hashInstruction is an external call, expectRevert binds to the next one
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlement.ConservationCheckFailed.selector, address(vault), uint256(1_000e6), uint256(1_200e6)
            )
        );
        settlement.submitBatch(instr, _s);
    }

    /// @dev Even when the summed legs DO fit inside the vault's pending, a batch that names the
    ///      same vault twice cannot execute: Phase A calls `snapshotSettlementPrice(cycleNumber)`
    ///      once per entry and the second call hits the once-per-cycle guard. So the dedup in
    ///      `_validateConservation` is belt-and-braces — the repeated-vault shape is rejected
    ///      downstream regardless of the amounts. Pinned so a future refactor of either guard
    ///      can't quietly open the double-distribution door.
    function test_submitBatch_sameVaultTwice_isRejectedEvenWhenAmountsFit() public {
        _advanceToOperating();
        _fundPool(address(vault), 1_000e6);

        uint256 vaultUsdtBefore = usdt.balanceOf(address(vault));
        uint256 cycleNumber = sm.currentCycleNumber(address(vault));
        ISettlement.SettlementInstruction memory instr =
            _twoVaultInstruction(address(vault), 400e6, address(vault), 500e6);

        bytes[] memory _s = _sigsFor(instr, operator1Pk); // hoisted: hashInstruction is an external call, expectRevert binds to the next one
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.SnapshotAlreadyInitialized.selector, cycleNumber));
        settlement.submitBatch(instr, _s);

        assertEq(usdt.balanceOf(address(vault)), vaultUsdtBefore, "no partial distribution survived");
        assertEq(unifiedPool.pending(address(vault)), 1_000e6);
    }

    // -----------------------------------------------------------------------
    // Happy path — deposits + redeems with real USDT flow
    // -----------------------------------------------------------------------

    function test_submitBatch_happyPath_settleDeposits_sharesMinted() public {
        uint256 assets = 2_000e6;
        uint256 rid = _requestDeposit(alice, assets);

        _advanceToOperating();

        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);
        instr.vaultSettlements[0].deposits = _rs1(rid, assets);

        _submit(instr, operator1Pk);

        vm.prank(alice);
        vault.claimDeposit(rid, alice);
        assertEq(vault.balanceOf(alice), assets * 1e18 / INITIAL_PRICE);
    }

    function test_submitBatch_happyPath_distributeMovesUsdt_queueDequeued_conservation() public {
        // Fund alice with shares first via a deposit cycle.
        uint256 assets = 2_000e6;
        uint256 depRid = _requestDeposit(alice, assets);
        _advanceToOperating();
        ISettlement.Distribution memory dist0 = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr0 = _instruction(dist0);
        instr0.vaultSettlements[0].deposits = _rs1(depRid, assets);
        _submit(instr0, operator1Pk);
        vm.prank(alice);
        vault.claimDeposit(depRid, alice);

        // Request a redeem.
        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(address(vault), shares);
        uint256 redeemId = vault.requestRedeem(shares, alice);
        vm.stopPrank();
        assertTrue(queue.isInQueue(address(vault), QueueType.REDEEM, redeemId));

        // Fund UnifiedPool with USDT for the payout via repayInterest + attributeInterest (no
        // fee deduction under net settlement — full amount credited).
        uint256 payout = shares * INITIAL_PRICE / 1e18;
        usdt.mint(issuer, payout);
        vm.prank(issuer);
        usdt.approve(address(unifiedPool), payout);
        vm.prank(issuer);
        unifiedPool.repayInterest(payout);
        vm.prank(operator1);
        unifiedPool.attributeInterest(address(vault), payout);
        uint256 pendingBefore = unifiedPool.pending(address(vault));

        _advanceToCalculating();

        ISettlement.Distribution memory dist1 = ISettlement.Distribution({vault: address(vault), amount: pendingBefore});
        ISettlement.SettlementInstruction memory instr1 = _instruction(dist1);
        instr1.vaultSettlements[0].redeems = _rs1(redeemId, shares);

        uint256 vaultUsdtBefore = usdt.balanceOf(address(vault));
        _submit(instr1, operator1Pk);

        assertFalse(queue.isInQueue(address(vault), QueueType.REDEEM, redeemId));
        assertEq(usdt.balanceOf(address(vault)), vaultUsdtBefore + pendingBefore);
        assertEq(unifiedPool.pending(address(vault)), 0);
    }

    // NOTE: test_submitBatch_sumRedeemAmountsMismatchDistribution_reverts and
    // test_submitBatch_wrongRedeemAmount_reverts were removed — both tested the gross-settlement
    // equality checks (ConservationFailed / WrongRedeemAmount) that net settlement deletes.
    // test_submitBatch_navDeviationExceedsTolerance_reverts and test_submitBatch_staleNav_reverts
    // were removed — Settlement no longer validates against NAVOracle; BaseVault computes its
    // own on-chain settlement price via snapshotSettlementPrice (development-plan §8).

    function test_settle_alreadySettledDeposit_reverts() public {
        uint256 assets = 2_000e6;
        uint256 depRid = _requestDeposit(alice, assets);
        _advanceToOperating();
        ISettlement.Distribution memory dist = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr = _instruction(dist);
        instr.vaultSettlements[0].deposits = _rs1(depRid, assets);
        _submit(instr, operator1Pk);

        // Same requestId again in a fresh batch (different validUntil/cycle to avoid the batch-hash replay guard).
        // The deposit FIFO queue now catches this before BaseVault does: depRid was already
        // dequeued in the first batch, so resubmitting it is an out-of-order dequeue, not a
        // BaseVault-level RequestAlreadySettled (Queue.sol is now the first line of defense for
        // both deposit and redeem FIFO, per the net-settlement conversion).
        _advanceToCalculating();
        ISettlement.SettlementInstruction memory instr2 = _instruction(dist);
        instr2.vaultSettlements[0].deposits = _rs1(depRid, assets);

        bytes[] memory _s2 = _sigsFor(instr2, operator1Pk); // hoisted above expectRevert
        vm.expectRevert(
            abi.encodeWithSelector(IQueue.OutOfOrderDequeue.selector, address(vault), QueueType.DEPOSIT, 0, depRid)
        );
        settlement.submitBatch(instr2, _s2);
    }

    // -----------------------------------------------------------------------
    // Operator / threshold management — now per-vault, gated by that vault's Owner rather than
    // a global Governor role. addOperator/removeOperator were replaced by a single
    // setOperator(vault, operator, approved) toggle.
    // -----------------------------------------------------------------------

    function test_setOperator_onlyVaultOwner() public {
        address newOp = makeAddr("newOp");
        vm.prank(attacker);
        vm.expectRevert(ISettlement.NotVaultOwner.selector);
        settlement.setOperator(address(vault), newOp, true);

        vm.prank(governor);
        settlement.setOperator(address(vault), newOp, true);
        assertTrue(settlement.isOperator(address(vault), newOp));

        vm.prank(attacker);
        vm.expectRevert(ISettlement.NotVaultOwner.selector);
        settlement.setOperator(address(vault), newOp, false);

        vm.prank(governor);
        settlement.setOperator(address(vault), newOp, false);
        assertFalse(settlement.isOperator(address(vault), newOp));
    }

    // -----------------------------------------------------------------------
    // Operator index — enumeration
    // -----------------------------------------------------------------------
    // The generated getter for the public `operatorsOf` mapping-to-array exposes no `.length`,
    // and unlike BaseVault.adapters there is no MAX_ constant bounding a probe, so without these
    // the signer set was recoverable only by replaying OperatorSet logs.

    function test_operatorCount_reflectsTheSetUpSigners() public view {
        assertEq(settlement.operatorCount(address(vault)), 2);
    }

    function test_operatorCount_isZeroForAVaultWithNoOperators() public {
        assertEq(settlement.operatorCount(makeAddr("unusedVault")), 0);
    }

    function test_operatorIndex_tracksAdditions() public {
        address newOp = makeAddr("newOp");
        vm.prank(governor);
        settlement.setOperator(address(vault), newOp, true);

        assertEq(settlement.operatorCount(address(vault)), 3);
        address[] memory page = settlement.operatorsPaged(address(vault), 0, 10);
        assertEq(page.length, 3);
        assertEq(page[0], operator1);
        assertEq(page[1], operator2);
        assertEq(page[2], newOp);
    }

    /// @dev Revocation is swap-and-pop, so the last operator moves into the freed slot — the
    ///      reason the doc comment tells callers to pin one blockTag.
    function test_operatorIndex_tracksRevocationAndTheSwapAndPopIndexMove() public {
        vm.prank(governor);
        settlement.setOperator(address(vault), operator1, false);

        assertEq(settlement.operatorCount(address(vault)), 1);
        address[] memory page = settlement.operatorsPaged(address(vault), 0, 10);
        assertEq(page.length, 1);
        assertEq(page[0], operator2, "survivor swapped down into index 0");
        assertTrue(settlement.isOperator(address(vault), page[0]));
    }

    function test_operatorsPaged_returnsTheRequestedWindow() public view {
        address[] memory page = settlement.operatorsPaged(address(vault), 1, 1);
        assertEq(page.length, 1);
        assertEq(page[0], operator2);
    }

    /// @dev A caller paging blind must not have to know the length to avoid reverting.
    function test_operatorsPaged_clampsInsteadOfReverting() public view {
        address[] memory page = settlement.operatorsPaged(address(vault), 1, type(uint256).max);
        assertEq(page.length, 1);
        assertEq(page[0], operator2);

        assertEq(settlement.operatorsPaged(address(vault), 2, 10).length, 0);
        assertEq(settlement.operatorsPaged(address(vault), 99, 10).length, 0);
    }

    function test_setThreshold_exceedsOperatorCount_reverts() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ISettlement.ThresholdExceedsOperatorCount.selector, 10, 2));
        settlement.setThreshold(address(vault), 10);
    }

    function test_setThreshold_onlyVaultOwner() public {
        vm.prank(attacker);
        vm.expectRevert(ISettlement.NotVaultOwner.selector);
        settlement.setThreshold(address(vault), 1);
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(ISettlement.ZeroAddress.selector);
        new Settlement(address(0), address(unifiedPool), address(queue));
    }

    // -----------------------------------------------------------------------
    // Partial-settlement conditional redeem dequeue
    // -----------------------------------------------------------------------

    function test_submitBatch_partialDeposit_coversRedeem_dequeuesOnlyRedeem() public {
        // Bob deposits, settles, redeems in full via a first (empty-fee) submitBatch cycle.
        uint256 bobAssets = 350_000e6;
        address bob = makeAddr("bob");
        usdt.mint(bob, bobAssets);
        uint256 bobRid = _requestDeposit(bob, bobAssets);
        _advanceToOperating(); // cycle 0 auto-transitions straight to CALCULATING here

        ISettlement.Distribution memory dist0 = ISettlement.Distribution({vault: address(vault), amount: 0});
        _submit(_instructionWithRequests(dist0, _rs1(bobRid, bobAssets), new RequestSettlement[](0)), operator1Pk);

        vm.prank(bob);
        vault.claimDeposit(bobRid, bob);
        uint256 bobShares = vault.balanceOf(bob);
        vm.startPrank(bob);
        vault.approve(address(vault), bobShares);
        uint256 redeemId = vault.requestRedeem(bobShares, bob);
        vm.stopPrank();

        // Alice's 400k deposit request is next; only enough to cover bob's redeem is accepted.
        uint256 aliceRequested = 400_000e6;
        usdt.mint(alice, aliceRequested);
        uint256 aliceRid = _requestDeposit(alice, aliceRequested);
        _advanceToCalculating();

        uint256 redeemAssets = bobShares * 1e6 / 1e18; // 1:1 price in this test — matches _assetsFor in EarnVault.t.sol
        ISettlement.Distribution memory dist1 = ISettlement.Distribution({vault: address(vault), amount: 0});
        uint256 aliceBalBefore = usdt.balanceOf(alice);

        _submit(_instructionWithRequests(dist1, _rs1(aliceRid, redeemAssets), _rs1(redeemId, bobShares)), operator1Pk);

        // Alice: partial accept + immediate refund of the untouched portion — never re-queued.
        assertEq(usdt.balanceOf(alice), aliceBalBefore + (aliceRequested - redeemAssets));
        assertFalse(queue.isInQueue(address(vault), QueueType.DEPOSIT, aliceRid));

        // Bob's redeem: fully cleared this cycle, dequeued.
        assertFalse(queue.isInQueue(address(vault), QueueType.REDEEM, redeemId));
        vm.prank(bob);
        uint256 bobAssetsOut = vault.claimRedeem(redeemId, bob);
        assertEq(bobAssetsOut, redeemAssets);
    }

    /// @notice Documents the FIFO constraint noted on ISettlement.submitBatch / IBaseVault.settle:
    ///         Queue.dequeue is strict FIFO-from-head, so a batch that only partially fills the
    ///         head redeem while fully clearing a later redeem in the same batch must revert —
    ///         the later redeem can't be dequeued while the earlier one is still at the head.
    function test_submitBatch_partialRedeemThenLaterFullRedeem_reverts() public {
        uint256 bobAssets = 350_000e6;
        address bob = makeAddr("bob");
        usdt.mint(bob, bobAssets);
        uint256 bobRid = _requestDeposit(bob, bobAssets);
        _advanceToOperating(); // cycle 0 auto-transitions straight to CALCULATING here

        ISettlement.Distribution memory dist0 = ISettlement.Distribution({vault: address(vault), amount: 0});
        _submit(_instructionWithRequests(dist0, _rs1(bobRid, bobAssets), new RequestSettlement[](0)), operator1Pk);

        vm.prank(bob);
        vault.claimDeposit(bobRid, bob);
        uint256 bobShares = vault.balanceOf(bob);

        // Two separate redeem requests, queued in FIFO order: redeemId1 first, redeemId2 second.
        vm.startPrank(bob);
        vault.approve(address(vault), bobShares);
        uint256 redeemId1 = vault.requestRedeem(bobShares / 2, bob);
        uint256 redeemId2 = vault.requestRedeem(bobShares - bobShares / 2, bob);
        vm.stopPrank();

        // Fund the vault with enough free USDT to cover both via a covering deposit.
        uint256 aliceRequested = bobAssets;
        usdt.mint(alice, aliceRequested);
        uint256 aliceRid = _requestDeposit(alice, aliceRequested);
        _advanceToCalculating();

        RequestSettlement[] memory redeems = new RequestSettlement[](2);
        // redeemId1 only partially filled (leaves remainingShares > 0)...
        redeems[0] = RequestSettlement({requestId: redeemId1, settleAmount: (bobShares / 2) / 2});
        // ...while redeemId2, queued after it, is fully cleared in the same batch.
        redeems[1] = RequestSettlement({requestId: redeemId2, settleAmount: bobShares - bobShares / 2});

        ISettlement.Distribution memory dist1 = ISettlement.Distribution({vault: address(vault), amount: 0});
        ISettlement.SettlementInstruction memory instr1 =
            _instructionWithRequests(dist1, _rs1(aliceRid, aliceRequested), redeems);

        bytes[] memory _s2 = _sigsFor(instr1, operator1Pk); // hoisted above expectRevert
        vm.expectRevert(
            abi.encodeWithSelector(
                IQueue.OutOfOrderDequeue.selector, address(vault), QueueType.REDEEM, redeemId1, redeemId2
            )
        );
        settlement.submitBatch(instr1, _s2);
    }
}
