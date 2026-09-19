// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";
import {StateManager} from "../../src/asset-management/StateManager.sol";
import {IStateManager} from "../../src/interfaces/IStateManager.sol";
import {
    ProductState,
    CycleState,
    PauseState,
    StateContext,
    ProductParams,
    ModuleId,
    VaultRole
} from "../../src/libs/Types.sol";

// ---------------------------------------------------------------------------
// Minimal vault-local-roles mock. StateManager only ever performs low-level
// interface calls (owner()/curator()/guardian()/isKeeper()/settlement()) on the
// "vault" address, so a small standalone mock (no real access-control gating on
// its own setters — that's the real BaseVault's job, tested elsewhere) is
// sufficient here and keeps role assignment trivial per-test.
// ---------------------------------------------------------------------------
contract MockVault {
    address public owner;
    address public curator;
    address public guardian;
    address public allocator;
    address public settlement;
    mapping(address => bool) private _keepers;

    constructor(address owner_) {
        owner = owner_;
    }

    function isKeeper(address account) external view returns (bool) {
        return _keepers[account];
    }

    /// @dev `StateManager.setProductParams` pushes the initial subscription cap into the vault.
    uint256 public subscriptionCapShare;

    function initSubscriptionCapShare(uint256 capShare) external {
        subscriptionCapShare = capShare;
    }

    function setCurator(address a) external {
        curator = a;
    }

    function setGuardian(address a) external {
        guardian = a;
    }

    function setAllocator(address a) external {
        allocator = a;
    }

    function setSettlement(address a) external {
        settlement = a;
    }

    function setKeeper(address a, bool approved) external {
        _keepers[a] = approved;
    }
}

contract StateManagerTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    MockVault internal vaultMock;

    address internal governor = makeAddr("governor");
    address internal vaultFactory = makeAddr("vaultFactory");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal settlement = makeAddr("settlement");
    address internal curator = makeAddr("curator");
    address internal vaultOwner = makeAddr("vaultOwner");
    address internal alice = makeAddr("alice");
    address internal vault; // address of vaultMock

    // Default product params for most tests
    ProductParams internal defaultParams;
    uint256 internal constant NOW = 1_000_000;

    function setUp() public {
        vm.warp(NOW);
        ac = new HyperAccessControl(governor);
        sm = new StateManager(address(ac));

        vaultMock = new MockVault(vaultOwner);
        vault = address(vaultMock);
        vaultMock.setCurator(curator);
        vaultMock.setGuardian(guardian);
        vaultMock.setSettlement(settlement);
        vaultMock.setKeeper(keeper, true);

        vm.prank(governor);
        sm.setVaultFactory(vaultFactory);

        defaultParams = ProductParams({
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

    // -----------------------------------------------------------------------
    // setVaultFactory
    // -----------------------------------------------------------------------

    function test_setVaultFactory_onlyOnce() public {
        // Already set once in setUp(); calling again must revert.
        vm.prank(governor);
        vm.expectRevert(IStateManager.VaultFactoryAlreadySet.selector);
        sm.setVaultFactory(alice);
    }

    function test_setVaultFactory_zeroAddressReverts() public {
        StateManager fresh = new StateManager(address(ac));
        vm.prank(governor);
        vm.expectRevert(IStateManager.ZeroAddress.selector);
        fresh.setVaultFactory(address(0));
    }

    function test_setVaultFactory_nonGovernorReverts() public {
        StateManager fresh = new StateManager(address(ac));
        vm.prank(alice);
        vm.expectRevert(IStateManager.NotGovernor.selector);
        fresh.setVaultFactory(vaultFactory);
    }

    // -----------------------------------------------------------------------
    // registerVault
    // -----------------------------------------------------------------------

    function test_registerVault_factorySucceeds() public {
        vm.prank(vaultFactory);
        sm.registerVault(vault);

        assertTrue(sm.isVaultRegistered(vault));
        StateContext memory ctx = sm.getState(vault);
        assertEq(uint8(ctx.product), uint8(ProductState.CONFIGURING));
        assertEq(uint8(ctx.cycle), uint8(CycleState.ACCEPTING));
        assertEq(uint8(ctx.pause), uint8(PauseState.ACTIVE));
        assertEq(ctx.currentCycleNumber, 0);
    }

    function test_registerVault_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit IStateManager.VaultRegistered(vault, ProductState.CONFIGURING, CycleState.ACCEPTING, NOW);
        vm.prank(vaultFactory);
        sm.registerVault(vault);
    }

    function test_registerVault_nonFactoryReverts() public {
        vm.prank(alice);
        vm.expectRevert(IStateManager.NotVaultFactory.selector);
        sm.registerVault(vault);
    }

    // Governor no longer has a bypass for registerVault — only the wired factory can call it.
    function test_registerVault_governorAloneReverts() public {
        vm.prank(governor);
        vm.expectRevert(IStateManager.NotVaultFactory.selector);
        sm.registerVault(vault);
    }

    function test_registerVault_duplicateReverts() public {
        vm.prank(vaultFactory);
        sm.registerVault(vault);
        vm.prank(vaultFactory);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.VaultAlreadyRegistered.selector, vault));
        sm.registerVault(vault);
    }

    function test_registeredVaults_backwardCompat() public {
        vm.prank(vaultFactory);
        sm.registerVault(vault);
        assertTrue(sm.registeredVaults(vault));
        assertFalse(sm.registeredVaults(alice));
    }

    // -----------------------------------------------------------------------
    // setProductParams
    // -----------------------------------------------------------------------

    function test_setProductParams_curatorInConfiguring() public {
        _registerVault();
        vm.prank(curator);
        sm.setProductParams(vault, defaultParams);
        ProductParams memory p = sm.getParams(vault);
        assertEq(p.walletSubscriptionCap, defaultParams.walletSubscriptionCap);
    }

    function test_setProductParams_emitsEvent() public {
        _registerVault();
        vm.expectEmit(true, false, false, false);
        emit IStateManager.ProductParamsSet(vault, NOW);
        vm.prank(curator);
        sm.setProductParams(vault, defaultParams);
    }

    // Governor no longer has a bypass for setProductParams — only that vault's own Curator.
    function test_setProductParams_governorReverts() public {
        _registerVault();
        vm.prank(governor);
        vm.expectRevert(IStateManager.Unauthorized.selector);
        sm.setProductParams(vault, defaultParams);
    }

    function test_setProductParams_nonAuthorizedReverts() public {
        _registerVault();
        vm.prank(alice);
        vm.expectRevert(IStateManager.Unauthorized.selector);
        sm.setProductParams(vault, defaultParams);
    }

    function test_setProductParams_wrongStateReverts() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.CONFIGURING, ProductState.SUBSCRIBING
            )
        );
        sm.setProductParams(vault, defaultParams);
    }

    // -----------------------------------------------------------------------
    // Product-parameter validation
    // -----------------------------------------------------------------------

    /// @dev A Curator who never called setProductParams must not be able to open a raise: the
    ///      product would run on an all-zero parameter set (cycleDuration 0, minRaiseAmount 0,
    ///      every timestamp 0).
    function test_openSubscription_revertsWhenParamsNeverSet() public {
        _registerVault();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.ConditionNotMet.selector, "product params not set"));
        sm.openSubscription(vault);
    }

    /// @dev `subscriptionStart == 0` stays legal — it means "open as soon as the Keeper calls".
    ///      "Never configured" is caught by the params-set flag, not by this field.
    function test_setProductParams_acceptsZeroSubscriptionStart() public {
        _registerVault();
        ProductParams memory p = defaultParams;
        p.subscriptionStart = 0;
        vm.prank(curator);
        sm.setProductParams(vault, p);
        assertEq(sm.getParams(vault).subscriptionStart, 0);
    }

    function test_setProductParams_rejectsZeroCycleDuration() public {
        _registerVault();
        ProductParams memory p = defaultParams;
        p.cycleDuration = 0;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.InvalidProductParams.selector, "cycleDuration"));
        sm.setProductParams(vault, p);
    }

    function test_setProductParams_rejectsOutOfOrderTimestamps() public {
        _registerVault();
        ProductParams memory p = defaultParams;
        p.subscriptionEnd = p.subscriptionStart;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.InvalidProductParams.selector, "subscriptionEnd"));
        sm.setProductParams(vault, p);

        p = defaultParams;
        p.maturityTimestamp = p.subscriptionEnd - 1;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.InvalidProductParams.selector, "maturityTimestamp"));
        sm.setProductParams(vault, p);

        p = defaultParams;
        p.claimingStart = p.maturityTimestamp - 1;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.InvalidProductParams.selector, "claimingStart"));
        sm.setProductParams(vault, p);

        p = defaultParams;
        p.claimingEnd = p.claimingStart - 1;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.InvalidProductParams.selector, "claimingEnd"));
        sm.setProductParams(vault, p);
    }

    /// @dev A 0 cap and a 0 minimum raise both stay legal — they mean "no cap" / "no minimum".
    function test_setProductParams_acceptsZeroCapAndZeroMinRaise() public {
        _registerVault();
        ProductParams memory p = defaultParams;
        p.subscriptionCapShare = 0;
        p.minRaiseAmount = 0;
        p.walletSubscriptionCap = 0;
        vm.prank(curator);
        sm.setProductParams(vault, p);
        assertEq(sm.getParams(vault).subscriptionCapShare, 0);
    }

    /// @dev The cap is pushed straight into the vault, which is the authority settle() reads.
    function test_setProductParams_pushesCapIntoVault() public {
        _registerVault();
        ProductParams memory p = defaultParams;
        p.subscriptionCapShare = 1_234e18;
        vm.prank(curator);
        sm.setProductParams(vault, p);
        assertEq(vaultMock.subscriptionCapShare(), 1_234e18);
    }

    // -----------------------------------------------------------------------
    // openSubscription
    // -----------------------------------------------------------------------

    function test_openSubscription_configuring_to_subscribing() public {
        _registerVaultAndParams();
        _openSubscription();
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.SUBSCRIBING));
    }

    function test_openSubscription_tooEarlyReverts() public {
        _registerVaultAndParams();
        vm.warp(NOW - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.ConditionNotMet.selector, "subscriptionStart not reached"));
        sm.openSubscription(vault);
    }

    function test_openSubscription_wrongStateReverts() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.InvalidStateTransition.selector, ProductState.SUBSCRIBING, ProductState.SUBSCRIBING
            )
        );
        sm.openSubscription(vault);
    }

    function test_openSubscription_nonKeeperReverts() public {
        _registerVaultAndParams();
        vm.prank(alice);
        vm.expectRevert(IStateManager.NotKeeper.selector);
        sm.openSubscription(vault);
    }

    function test_openSubscription_vaultOwnerWithoutKeeperGrantReverts() public {
        // Owner no longer gets implicit Keeper access; without an explicit setKeeper, it reverts.
        _registerVaultAndParams();
        vm.prank(vaultOwner);
        vm.expectRevert(IStateManager.NotKeeper.selector);
        sm.openSubscription(vault);
    }

    // -----------------------------------------------------------------------
    // finalizeSubscription
    // -----------------------------------------------------------------------

    function test_finalizeSubscription_operating_when_raised() public {
        _registerVaultAndParams();
        _openSubscription();
        // Simulate enough subscriptions
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 100_000e6);
        // Warp past subscriptionEnd
        vm.warp(NOW + 7 days + 1);
        vm.prank(keeper);
        sm.finalizeSubscription(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.OPERATING));
    }

    function test_finalizeSubscription_fundingFailed_when_not_raised() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.warp(NOW + 7 days + 1);
        vm.prank(keeper);
        sm.finalizeSubscription(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.FUNDING_FAILED));
    }

    function test_finalizeSubscription_tooEarlyReverts() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.ConditionNotMet.selector, "subscriptionEnd not reached"));
        sm.finalizeSubscription(vault);
    }

    // -----------------------------------------------------------------------
    // Cycle-0 fix: successful raise goes straight to CALCULATING (not ACCEPTING),
    // blocking new deposit/redeem requests until the bound Settlement contract
    // completes cycle 0, at which point currentCycleNumber becomes 1 and the
    // vault re-opens to ACCEPTING. This is the fix for initial
    // subscribers otherwise being stuck waiting a full cycleDuration.
    // -----------------------------------------------------------------------

    function test_finalizeSubscription_raiseSucceeds_entersCalculating_notAccepting() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 100_000e6);
        vm.warp(NOW + 7 days + 1);
        vm.prank(keeper);
        sm.finalizeSubscription(vault);

        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.OPERATING));
        assertEq(uint8(sm.getCycleState(vault)), uint8(CycleState.CALCULATING));
        assertEq(sm.currentCycleNumber(vault), 0);
    }

    function test_cycle0_blocksNewSubscriptionsAndRedeemsUntilSettled() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 100_000e6);
        vm.warp(NOW + 7 days + 1);
        vm.prank(keeper);
        sm.finalizeSubscription(vault);

        // OPERATING but cycle == CALCULATING: neither subscribe nor redeem gates pass.
        // requireSubscribable rejects on ProductState (it only accepts SUBSCRIBING, or
        // OPERATING+ACCEPTING); requireOperable gets past the ProductState check and rejects on
        // CycleState. Asserting the distinct selectors pins which guard each one trips.
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.SUBSCRIBING, ProductState.OPERATING
            )
        );
        sm.requireSubscribable(vault);
        vm.expectRevert(
            abi.encodeWithSelector(IStateManager.WrongCycleState.selector, CycleState.ACCEPTING, CycleState.CALCULATING)
        );
        sm.requireOperable(vault);

        // Only completeCycle (by the vault's bound Settlement) reopens ACCEPTING and
        // bumps currentCycleNumber from 0 to 1.
        vm.prank(settlement);
        sm.completeCycle(vault);

        assertEq(uint8(sm.getCycleState(vault)), uint8(CycleState.ACCEPTING));
        assertEq(sm.currentCycleNumber(vault), 1);
        sm.requireSubscribable(vault); // now passes
        sm.requireOperable(vault); // now passes
    }

    // -----------------------------------------------------------------------
    // startCycleCalculation
    // -----------------------------------------------------------------------

    function test_startCycleCalculation_succeeds() public {
        _fullSubscribeToOperatingAndAccepting();
        vm.warp(NOW + 7 days + 7 days + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);
        assertEq(uint8(sm.getCycleState(vault)), uint8(CycleState.CALCULATING));
    }

    function test_startCycleCalculation_tooEarlyReverts() public {
        _fullSubscribeToOperatingAndAccepting();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.ConditionNotMet.selector, "cycleDuration not elapsed"));
        sm.startCycleCalculation(vault);
    }

    // -----------------------------------------------------------------------
    // Final cycle → SETTLING
    // -----------------------------------------------------------------------

    /// @dev maturityTimestamp is its own trigger: the final cycle runs even though only a
    ///      fraction of cycleDuration has elapsed, and starting it moves the product to SETTLING
    ///      in the same transaction.
    function test_finalCycle_startsOnMaturityIgnoringCycleDuration() public {
        _fullSubscribeToOperatingAndAccepting();
        vm.warp(NOW + 365 days);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);
        assertEq(uint8(sm.getCycleState(vault)), uint8(CycleState.CALCULATING));
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.SETTLING));
    }

    /// @dev A one-year product whose cycle 0 completed late still reaches its final cycle.
    function test_finalCycle_notSkippedWhenCycleZeroWasDelayed() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 100_000e6);
        vm.warp(NOW + 7 days + 1);
        vm.prank(keeper);
        sm.finalizeSubscription(vault);
        vm.warp(NOW + 37 days);
        vm.prank(settlement);
        sm.completeCycle(vault);

        vm.warp(NOW + 365 days);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);
        vm.prank(settlement);
        sm.completeCycle(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.MATURING));
    }

    /// @dev A normal cycle that entered CALCULATING before maturity but completes at or after it
    ///      is NOT promoted to final: it priced the vault while positions were still outstanding.
    ///      The product moves to SETTLING and opens a FRESH final cycle instead, which prices
    ///      only once the assets are actually back.
    function test_finalCycle_normalCycleAfterMaturityOpensAFreshFinalCycle() public {
        _fullSubscribeToOperatingAndAccepting();
        vm.warp(NOW + 365 days - 1);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);
        vm.warp(NOW + 365 days + 1);
        vm.prank(settlement);
        sm.completeCycle(vault);

        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.SETTLING));
        assertEq(uint8(sm.getCycleState(vault)), uint8(CycleState.CALCULATING), "a new final cycle is open");
        assertTrue(sm.isFinalCycle(vault));

        // And it is that fresh cycle whose completion takes the product to MATURING.
        vm.prank(settlement);
        sm.completeCycle(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.MATURING));
    }

    /// @dev Before maturity, completeCycle leaves the product OPERATING as always.
    function test_completeCycle_beforeMaturityStaysOperating() public {
        _fullSubscribeToOperatingAndAccepting();
        vm.warp(NOW + 14 days + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);
        vm.prank(settlement);
        sm.completeCycle(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.OPERATING));
        assertEq(uint8(sm.getCycleState(vault)), uint8(CycleState.ACCEPTING));
    }

    // -----------------------------------------------------------------------
    // enterMaturing / enterClaiming / closeProduct
    // -----------------------------------------------------------------------

    /// @dev Starting the final cycle at maturity is one atomic step: OPERATING → SETTLING and
    ///      ACCEPTING → CALCULATING together, so the product never reads SETTLING with no cycle
    ///      to run, nor runs a cycle while still admitting business.
    function test_finalCycle_startIsAtomicIntoSettlingCalculating() public {
        _fullSubscribeToOperatingAndAccepting();
        vm.warp(NOW + 365 days + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);

        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.SETTLING));
        assertEq(uint8(sm.getCycleState(vault)), uint8(CycleState.CALCULATING));
        assertTrue(sm.isFinalCycle(vault), "flagged as the final cycle");
    }

    /// @dev Completing the final cycle moves straight to MATURING — SETTLING has exactly one
    ///      exit and it runs through a completed final cycle.
    function test_finalCycle_completeCycleEntersMaturingAtomically() public {
        _fullSubscribeToSettling();
        vm.prank(settlement);
        sm.completeCycle(vault);

        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.MATURING));
        assertEq(uint8(sm.getCycleState(vault)), uint8(CycleState.ACCEPTING));
        assertFalse(sm.isFinalCycle(vault), "final cycle is done");
    }

    /// @dev No new cycle can start once the product has left OPERATING, so the resting
    ///      ACCEPTING cycle state after MATURING cannot be used to reopen anything.
    function test_finalCycle_noNewCycleAfterMaturing() public {
        _fullSubscribeToMaturing();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.OPERATING, ProductState.MATURING
            )
        );
        sm.startCycleCalculation(vault);
    }

    function test_enterClaiming_maturing_to_claiming() public {
        _fullSubscribeToMaturing();
        vm.warp(NOW + 370 days + 1);
        vm.prank(keeper);
        sm.enterClaiming(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.CLAIMING));
    }

    function test_closeProduct_claiming_to_closed() public {
        _fullSubscribeToMaturing();
        vm.warp(NOW + 370 days + 1);
        vm.prank(keeper);
        sm.enterClaiming(vault);
        vm.warp(defaultParams.claimingEnd);
        vm.prank(keeper);
        sm.closeProduct(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.CLOSED));
    }

    function test_closeProduct_revertsBeforeClaimingEnd() public {
        _fullSubscribeToMaturing();
        vm.warp(NOW + 370 days + 1);
        vm.prank(keeper);
        sm.enterClaiming(vault);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.ConditionNotMet.selector, "claimingEnd not reached"));
        sm.closeProduct(vault);
    }

    function test_closeProduct_succeedsAtClaimingEnd() public {
        _fullSubscribeToMaturing();
        vm.warp(NOW + 370 days + 1);
        vm.prank(keeper);
        sm.enterClaiming(vault);
        vm.warp(defaultParams.claimingEnd);

        vm.prank(keeper);
        sm.closeProduct(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.CLOSED));
    }

    // -----------------------------------------------------------------------
    // completeCycle
    // -----------------------------------------------------------------------

    function test_completeCycle_atomic_CALCULATING_to_ACCEPTING() public {
        _fullSubscribeToOperatingAndAccepting();
        vm.warp(NOW + 7 days + 7 days + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);
        assertEq(sm.currentCycleNumber(vault), 1);
        vm.prank(settlement);
        sm.completeCycle(vault);
        assertEq(uint8(sm.getCycleState(vault)), uint8(CycleState.ACCEPTING));
        assertEq(sm.currentCycleNumber(vault), 2);
    }

    function test_completeCycle_nonSettlementReverts() public {
        // finalizeSubscription already leaves cycle 0 at CALCULATING (cycle-0 fix).
        _fullSubscribeToOperating();
        vm.prank(alice);
        vm.expectRevert(IStateManager.NotSettlement.selector);
        sm.completeCycle(vault);
    }

    function test_completeCycle_wrongCycleStateReverts() public {
        // Registered but never finalized: cycle is ACCEPTING (initial), not CALCULATING.
        _registerVault();
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.InvalidCycleTransition.selector, CycleState.ACCEPTING, CycleState.FULFILLING
            )
        );
        sm.completeCycle(vault);
    }

    // -----------------------------------------------------------------------
    // Pause layer
    // -----------------------------------------------------------------------

    function test_guardian_pause_PAUSED_BY_GUARDIAN() public {
        _registerVault();
        vm.prank(guardian);
        sm.pause(vault, PauseState.PAUSED_BY_GUARDIAN);
        assertEq(uint8(sm.getPauseState(vault)), uint8(PauseState.PAUSED_BY_GUARDIAN));
    }

    // Governor no longer has any pause bypass — only that vault's own Guardian, regardless
    // of the PauseState reason passed (removed: old test_governor_pause_PAUSED_BY_GOVERNOR,
    // which relied on a Governor-specific pause path that no longer exists).
    function test_governor_cannot_pause() public {
        _registerVault();
        vm.prank(governor);
        vm.expectRevert(IStateManager.NotGuardian.selector);
        sm.pause(vault, PauseState.PAUSED_BY_GOVERNOR);
    }

    // Guardian may pause with any non-ACTIVE reason now (removed: old
    // test_guardian_cannot_pause_PAUSED_BY_GOVERNOR, which assumed the reason enum value
    // itself gated who could call — it no longer does; only guardian identity is checked).
    function test_guardian_can_pause_with_any_reason() public {
        _registerVault();
        vm.prank(guardian);
        sm.pause(vault, PauseState.PAUSED_BY_GOVERNOR);
        assertEq(uint8(sm.getPauseState(vault)), uint8(PauseState.PAUSED_BY_GOVERNOR));
    }

    function test_nonAuth_pause_reverts() public {
        _registerVault();
        vm.prank(alice);
        vm.expectRevert(IStateManager.NotGuardian.selector);
        sm.pause(vault, PauseState.PAUSED_BY_GUARDIAN);
    }

    function test_vaultOwner_can_unpause() public {
        _registerVault();
        vm.prank(guardian);
        sm.pause(vault, PauseState.PAUSED_BY_GUARDIAN);
        vm.prank(vaultOwner);
        sm.unpause(vault);
        assertEq(uint8(sm.getPauseState(vault)), uint8(PauseState.ACTIVE));
    }

    // Governor no longer has an unpause bypass — only that vault's own Owner.
    function test_governor_cannot_unpause() public {
        _registerVault();
        vm.prank(guardian);
        sm.pause(vault, PauseState.PAUSED_BY_GUARDIAN);
        vm.prank(governor);
        vm.expectRevert(IStateManager.Unauthorized.selector);
        sm.unpause(vault);
    }

    function test_guardian_cannot_unpause() public {
        _registerVault();
        vm.prank(guardian);
        sm.pause(vault, PauseState.PAUSED_BY_GUARDIAN);
        vm.prank(guardian);
        vm.expectRevert(IStateManager.Unauthorized.selector);
        sm.unpause(vault);
    }

    function test_pause_ACTIVE_is_invalid_reason() public {
        _registerVault();
        vm.prank(guardian);
        vm.expectRevert(IStateManager.InvalidPauseReason.selector);
        sm.pause(vault, PauseState.ACTIVE);
    }

    function test_double_pause_reverts() public {
        _registerVault();
        vm.prank(guardian);
        sm.pause(vault, PauseState.PAUSED_BY_GUARDIAN);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.AlreadyPaused.selector, vault));
        sm.pause(vault, PauseState.PAUSED_BY_GOVERNOR);
    }

    // -----------------------------------------------------------------------
    // Gate views
    // -----------------------------------------------------------------------

    function test_requireSubscribable_in_SUBSCRIBING() public {
        _registerVaultAndParams();
        _openSubscription();
        sm.requireSubscribable(vault); // should not revert
    }

    function test_requireSubscribable_in_OPERATING_ACCEPTING() public {
        _fullSubscribeToOperatingAndAccepting();
        sm.requireSubscribable(vault); // should not revert
    }

    function test_requireSubscribable_paused_reverts() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(guardian);
        sm.pause(vault, PauseState.PAUSED_BY_GUARDIAN);
        vm.expectRevert(
            abi.encodeWithSelector(IStateManager.VaultPausedError.selector, vault, PauseState.PAUSED_BY_GUARDIAN)
        );
        sm.requireSubscribable(vault);
    }

    function test_requireSubscribable_wrong_state_reverts() public {
        _registerVaultAndParams();
        // CONFIGURING — should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.SUBSCRIBING, ProductState.CONFIGURING
            )
        );
        sm.requireSubscribable(vault);
    }

    function test_requireOperable_in_OPERATING_ACCEPTING() public {
        _fullSubscribeToOperatingAndAccepting();
        sm.requireOperable(vault); // should not revert
    }

    function test_requireOperable_wrong_state_reverts() public {
        _registerVaultAndParams();
        _openSubscription();
        // SUBSCRIBING — not operable
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.OPERATING, ProductState.SUBSCRIBING
            )
        );
        sm.requireOperable(vault);
    }

    function test_requireCycleState_correct() public {
        _fullSubscribeToOperatingAndAccepting();
        vm.warp(NOW + 7 days + 7 days + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);
        sm.requireCycleState(vault, CycleState.CALCULATING); // should not revert
    }

    function test_requireCycleState_wrong_reverts() public {
        _fullSubscribeToOperatingAndAccepting();
        // cycle is ACCEPTING, but we ask for CALCULATING
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.CycleStateMismatch.selector, vault, CycleState.CALCULATING, CycleState.ACCEPTING
            )
        );
        sm.requireCycleState(vault, CycleState.CALCULATING);
    }

    function test_requireActive_paused_reverts() public {
        _registerVault();
        vm.prank(guardian);
        sm.pause(vault, PauseState.PAUSED_BY_GUARDIAN);
        vm.expectRevert(
            abi.encodeWithSelector(IStateManager.VaultPausedError.selector, vault, PauseState.PAUSED_BY_GUARDIAN)
        );
        sm.requireActive(vault);
    }

    function test_requireActive_active_ok() public {
        _registerVault();
        sm.requireActive(vault); // should not revert
    }

    // -----------------------------------------------------------------------
    // Subscription tracking
    // -----------------------------------------------------------------------

    function test_recordSubscription_updates_totals() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(vault); // caller must be vault
        sm.recordSubscription(vault, alice, 1_000e6);
        assertEq(sm.totalSubscribed(vault), 1_000e6);
        assertEq(sm.subscribedByWallet(vault, alice), 1_000e6);
    }

    function test_releaseSubscription_decrements_totals() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 1_000e6);
        vm.prank(vault);
        sm.releaseSubscription(vault, alice, 500e6);
        assertEq(sm.totalSubscribed(vault), 500e6);
        assertEq(sm.subscribedByWallet(vault, alice), 500e6);
    }

    /// @dev `recordSubscription` only ever accrues while SUBSCRIBING, so releasing outside that
    ///      window would subtract an amount that was never added and drive the raise tally below
    ///      its true total. An OPERATING-phase cancel is a no-op on the ledger.
    function test_releaseSubscription_noOpOutsideSubscribing() public {
        _fullSubscribeToOperatingAndAccepting();
        uint256 before = sm.totalSubscribed(vault);
        assertGt(before, 0);

        vm.prank(vault);
        sm.releaseSubscription(vault, alice, before);

        assertEq(sm.totalSubscribed(vault), before);
        assertEq(sm.subscribedByWallet(vault, alice), before);
    }

    /// @dev The full lifecycle: the tally moves
    ///      only during the raise window, in both directions, and is frozen afterwards.
    function test_totalSubscribed_frozenAfterRaiseCloses() public {
        _registerVaultAndParams();
        _openSubscription();

        // Inside the window: adds, and a cancel symmetrically subtracts.
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 100_000e6);
        vm.prank(vault);
        sm.releaseSubscription(vault, alice, 40_000e6);
        assertEq(sm.totalSubscribed(vault), 60_000e6);

        vm.prank(vault);
        sm.recordSubscription(vault, alice, 40_000e6);
        assertEq(sm.totalSubscribed(vault), 100_000e6);

        vm.warp(NOW + 7 days + 1);
        vm.prank(keeper);
        sm.finalizeSubscription(vault);
        uint256 frozen = sm.totalSubscribed(vault);
        assertEq(frozen, 100_000e6, "closes at what was declared during the window");

        // Past the window nothing moves it: neither an OPERATING-phase subscription...
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 25_000e6);
        assertEq(sm.totalSubscribed(vault), frozen);
        assertEq(sm.subscribedByWallet(vault, alice), frozen);

        // ...nor an OPERATING-phase cancel of one.
        vm.prank(vault);
        sm.releaseSubscription(vault, alice, 25_000e6);
        assertEq(sm.totalSubscribed(vault), frozen);
        assertEq(sm.subscribedByWallet(vault, alice), frozen);
    }

    /// @dev A failed raise freezes it just the same — refunds do not rewrite the raise figure.
    function test_totalSubscribed_frozenAfterFundingFailed() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 10_000e6);

        vm.warp(NOW + 7 days + 1);
        vm.prank(keeper);
        sm.finalizeSubscription(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.FUNDING_FAILED));

        vm.prank(vault);
        sm.releaseSubscription(vault, alice, 10_000e6);
        assertEq(sm.totalSubscribed(vault), 10_000e6, "refunds leave the declared tally alone");
    }

    function test_recordSubscription_nonVaultReverts() public {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(alice);
        vm.expectRevert(IStateManager.Unauthorized.selector);
        sm.recordSubscription(vault, alice, 1_000e6);
    }

    function test_recordSubscription_noTotalRaiseCap_acceptsUnbounded() public {
        // There is no request-time total-raise cap any more: capacity is enforced at settlement
        // in share terms against the vault's subscriptionCapShare, which sizes (and partially
        // accepts) each request rather than rejecting whole orders up front. recordSubscription
        // only tracks raise progress, so it must accept an arbitrarily large running total.
        ProductParams memory p = defaultParams;
        p.walletSubscriptionCap = 0; // isolate: only the per-wallet limit could reject here
        _registerVault();
        vm.prank(curator);
        sm.setProductParams(vault, p);
        _openSubscription();

        vm.prank(vault);
        sm.recordSubscription(vault, alice, 400e6);
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 200e6);
        address whale = makeAddr("whale");
        vm.prank(vault);
        sm.recordSubscription(vault, whale, 10_000_000e6);

        assertEq(sm.totalSubscribed(vault), 10_000_600e6);
        assertEq(sm.subscribedByWallet(vault, alice), 600e6);
        assertEq(sm.subscribedByWallet(vault, whale), 10_000_000e6);
    }

    function test_walletCap_exceeded_reverts() public {
        ProductParams memory p = defaultParams;
        p.walletSubscriptionCap = 500e6;
        _registerVault();
        vm.prank(curator);
        sm.setProductParams(vault, p);
        _openSubscription();
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 400e6);
        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(IStateManager.WalletCapExceeded.selector, alice, uint256(500e6), uint256(600e6))
        );
        sm.recordSubscription(vault, alice, 200e6);
    }

    function test_recordSubscription_notEnforced_afterOperating() public {
        // walletSubscriptionCap is a one-time initial-raise gate; once the vault is
        // OPERATING (recurring per-cycle deposits), totals never decrement,
        // so re-enforcing the same cap would permanently lock out deposits.
        ProductParams memory p = defaultParams;
        p.walletSubscriptionCap = 500e6;
        p.minRaiseAmount = 0;
        _registerVault();
        vm.prank(curator);
        sm.setProductParams(vault, p);
        _openSubscription();
        vm.prank(vault); // hits cap during SUBSCRIBING
        sm.recordSubscription(vault, alice, 500e6);
        vm.warp(NOW + 7 days + 1);
        vm.prank(keeper); // -> OPERATING (raised >= minRaiseAmount)
        sm.finalizeSubscription(vault);

        // Further recurring-cycle deposits must not revert despite total already at cap.
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 1_000e6);
    }

    // -----------------------------------------------------------------------
    // requireOperable during SETTLING (request cutoff)
    // -----------------------------------------------------------------------

    /// @dev SETTLING is the hard request cutoff: no further CALCULATING cycle can be opened,
    ///      so a redeem queued here would never be fillable. requireOperable must reject.
    function test_requireOperable_revertsIn_SETTLING() public {
        _fullSubscribeToSettling();
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.OPERATING, ProductState.SETTLING
            )
        );
        sm.requireOperable(vault);
    }

    /// @dev A half-run batch must never be stranded: with cycle 0 still CALCULATING, the Keeper
    ///      cannot start another cycle even past maturity — it has to wait for cycle 0's batch.
    function test_finalCycle_cannotStartWhileAnotherCycleIsCalculating() public {
        _fullSubscribeToOperating(); // cycle 0 lands on CALCULATING, never completed
        vm.warp(NOW + 365 days + 1);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IStateManager.WrongCycleState.selector, CycleState.ACCEPTING, CycleState.CALCULATING)
        );
        sm.startCycleCalculation(vault);
    }

    // -----------------------------------------------------------------------
    // Lifecycle transition reverts for invalid paths
    // -----------------------------------------------------------------------

    function test_invalid_product_transitions_revert() public {
        _registerVaultAndParams();
        // Cannot finalizeSubscription from CONFIGURING
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.SUBSCRIBING, ProductState.CONFIGURING
            )
        );
        sm.finalizeSubscription(vault);
    }

    function test_invalid_cycle_transition_revert() public {
        _fullSubscribeToOperatingAndAccepting();
        // Cannot startCycleCalculation from CALCULATING
        vm.warp(NOW + 7 days + 7 days + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IStateManager.WrongCycleState.selector, CycleState.ACCEPTING, CycleState.CALCULATING)
        );
        sm.startCycleCalculation(vault);
    }

    // -----------------------------------------------------------------------
    // Module pause (backward compat)
    // -----------------------------------------------------------------------

    function test_modulePaused_default_false() public view {
        assertFalse(sm.modulePaused(ModuleId.PSM_POOL));
    }

    function test_pauseModule_unpauseModule() public {
        vm.prank(governor);
        sm.pauseModule(ModuleId.PSM_POOL);
        assertTrue(sm.modulePaused(ModuleId.PSM_POOL));
        vm.prank(governor);
        sm.unpauseModule(ModuleId.PSM_POOL);
        assertFalse(sm.modulePaused(ModuleId.PSM_POOL));
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _registerVault() internal {
        vm.prank(vaultFactory);
        sm.registerVault(vault);
    }

    function _registerVaultAndParams() internal {
        _registerVault();
        vm.prank(curator);
        sm.setProductParams(vault, defaultParams);
    }

    function _openSubscription() internal {
        vm.prank(keeper);
        sm.openSubscription(vault);
    }

    function _fullSubscribeToOperating() internal {
        _registerVaultAndParams();
        _openSubscription();
        vm.prank(vault);
        sm.recordSubscription(vault, alice, 100_000e6);
        vm.warp(NOW + 7 days + 1);
        vm.prank(keeper);
        sm.finalizeSubscription(vault);
    }

    /// @dev Cycle-0 fix: finalizeSubscription lands on CALCULATING at cycle 0, not
    ///      ACCEPTING. Tests that need the vault in a "steady state" OPERATING+ACCEPTING
    ///      (post-cycle-0) must additionally complete cycle 0 via the bound Settlement.
    function _fullSubscribeToOperatingAndAccepting() internal {
        _fullSubscribeToOperating();
        vm.prank(settlement);
        sm.completeCycle(vault);
    }

    /// @dev SETTLING is where the FINAL cycle RUNS: starting it at maturity moves the product
    ///      into SETTLING and the cycle into CALCULATING in one transaction.
    function _fullSubscribeToSettling() internal {
        _fullSubscribeToOperatingAndAccepting();
        vm.warp(NOW + 365 days + 1);
        vm.prank(keeper);
        sm.startCycleCalculation(vault);
    }

    /// @dev Completing the final cycle is SETTLING's only exit, and it lands on MATURING.
    function _fullSubscribeToMaturing() internal {
        _fullSubscribeToSettling();
        vm.prank(settlement);
        sm.completeCycle(vault);
    }

    // -----------------------------------------------------------------------
    // Late-lifecycle transitions — every wrong-state guard, with its own selector
    // -----------------------------------------------------------------------

    function test_finalCycle_wrongProductStateReverts() public {
        _registerVaultAndParams();
        _openSubscription(); // SUBSCRIBING, not OPERATING
        vm.warp(NOW + 365 days + 1);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.WrongProductState.selector, ProductState.OPERATING, ProductState.SUBSCRIBING
            )
        );
        sm.startCycleCalculation(vault);
    }

    /// @dev MATURING is reachable only through the final cycle's own completeCycle, which only
    ///      that vault's bound Settlement may call. The separate Keeper transition and the
    ///      separate M-of-N confirmation that used to guard it are both gone — the final batch is
    ///      already M-of-N protected, so confirming it again was duplicate machinery.
    function test_maturing_onlyReachableViaFinalCompleteCycle() public {
        _fullSubscribeToSettling();

        vm.prank(alice);
        vm.expectRevert(IStateManager.NotSettlement.selector);
        sm.completeCycle(vault);

        vm.prank(settlement);
        sm.completeCycle(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.MATURING));
    }

    function test_enterClaiming_wrongProductStateReverts() public {
        _fullSubscribeToSettling(); // SETTLING, not MATURING
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.InvalidStateTransition.selector, ProductState.SETTLING, ProductState.CLAIMING
            )
        );
        sm.enterClaiming(vault);
    }

    function test_enterClaiming_beforeClaimingStartReverts() public {
        _reachMaturing();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.ConditionNotMet.selector, "claimingStart not reached"));
        sm.enterClaiming(vault);
    }

    function test_closeProduct_wrongProductStateReverts() public {
        _reachMaturing(); // MATURING, not CLAIMING
        vm.warp(NOW + 400 days + 1);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.InvalidStateTransition.selector, ProductState.MATURING, ProductState.CLOSED
            )
        );
        sm.closeProduct(vault);
    }

    function test_closeProduct_beforeClaimingEndReverts() public {
        _reachClaiming();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.ConditionNotMet.selector, "claimingEnd not reached"));
        sm.closeProduct(vault);
    }

    /// @dev Walks the full tail of the lifecycle in one go, so the ordering constraint between
    ///      MATURING -> CLAIMING -> CLOSED is pinned end to end and not just per-revert.
    function test_lifecycle_maturingThroughClosed() public {
        _reachClaiming();
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.CLAIMING));

        vm.warp(NOW + 400 days + 1);
        vm.prank(keeper);
        sm.closeProduct(vault);
        assertEq(uint8(sm.getProductState(vault)), uint8(ProductState.CLOSED));

        // CLOSED is terminal — nothing moves it further.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateManager.InvalidStateTransition.selector, ProductState.CLOSED, ProductState.CLOSED
            )
        );
        sm.closeProduct(vault);
    }

    function _reachMaturing() internal {
        _fullSubscribeToMaturing();
    }

    function _reachClaiming() internal {
        _reachMaturing();
        vm.warp(NOW + 370 days + 1);
        vm.prank(keeper);
        sm.enterClaiming(vault);
    }

    // -----------------------------------------------------------------------
    // Module pause gate
    // -----------------------------------------------------------------------

    function test_requireModuleActive_passesWhileUnpausedAndRevertsAfter() public {
        sm.requireModuleActive(ModuleId.SETTLEMENT); // must not revert

        vm.prank(governor);
        sm.pauseModule(ModuleId.SETTLEMENT);
        vm.expectRevert(abi.encodeWithSelector(IStateManager.ModuleIsPaused.selector, ModuleId.SETTLEMENT));
        sm.requireModuleActive(ModuleId.SETTLEMENT);

        // Module pauses are independent of one another.
        sm.requireModuleActive(ModuleId.CASH_VAULT);

        vm.prank(governor);
        sm.unpauseModule(ModuleId.SETTLEMENT);
        sm.requireModuleActive(ModuleId.SETTLEMENT);
    }

    // -----------------------------------------------------------------------
    // registerVault / setVaultFactory guards
    // -----------------------------------------------------------------------

    function test_registerVault_revertsOnZeroVault() public {
        vm.prank(vaultFactory);
        vm.expectRevert(IStateManager.ZeroAddress.selector);
        sm.registerVault(address(0));
    }

    function test_constructor_revertsOnZeroAccessControl() public {
        vm.expectRevert(IStateManager.ZeroAddress.selector);
        new StateManager(address(0));
    }

    /// @dev `onlyRegistered` guards the whole read/write surface — an unknown vault must be
    ///      rejected by name, not fall through to a zeroed default.
    function test_unregisteredVault_isRejectedByTheGates() public {
        address ghost = makeAddr("ghostVault");
        vm.expectRevert(abi.encodeWithSelector(IStateManager.VaultNotRegistered.selector, ghost));
        sm.requireActive(ghost);

        vm.expectRevert(abi.encodeWithSelector(IStateManager.VaultNotRegistered.selector, ghost));
        sm.requireSubscribable(ghost);

        vm.expectRevert(abi.encodeWithSelector(IStateManager.VaultNotRegistered.selector, ghost));
        sm.requireOperable(ghost);

        vm.expectRevert(abi.encodeWithSelector(IStateManager.VaultNotRegistered.selector, ghost));
        sm.requireCycleState(ghost, CycleState.ACCEPTING);

        assertFalse(sm.isVaultRegistered(ghost));
        assertFalse(sm.registeredVaults(ghost));
    }

    // -----------------------------------------------------------------------
    // Vault index — enumeration
    // -----------------------------------------------------------------------
    // The `_registered` mapping answers "is this address a vault?" but cannot answer
    // "what are all the vaults?". The index below is the enumerable counterpart, so a
    // third party can list every vault with eth_call alone — the same guarantee
    // AssetRegistry already gives for assets via nextAssetId/getAsset.

    /// @dev Registers a fresh MockVault owned by `vaultOwner` and returns it.
    function _newRegisteredVault() internal returns (MockVault mv) {
        mv = new MockVault(vaultOwner);
        vm.prank(vaultFactory);
        sm.registerVault(address(mv));
    }

    function test_vaultCount_isZeroBeforeAnyRegistration() public view {
        assertEq(sm.vaultCount(), 0);
    }

    function test_registerVault_appendsToTheIndex() public {
        vm.prank(vaultFactory);
        sm.registerVault(vault);

        assertEq(sm.vaultCount(), 1);
        assertEq(sm.vaultAt(0), vault);
    }

    function test_vaultIndex_preservesRegistrationOrder() public {
        vm.prank(vaultFactory);
        sm.registerVault(vault);
        MockVault second = _newRegisteredVault();
        MockVault third = _newRegisteredVault();

        assertEq(sm.vaultCount(), 3);
        assertEq(sm.vaultAt(0), vault);
        assertEq(sm.vaultAt(1), address(second));
        assertEq(sm.vaultAt(2), address(third));
    }

    function test_vaultAt_revertsPastTheEnd() public {
        vm.prank(vaultFactory);
        sm.registerVault(vault);

        vm.expectRevert();
        sm.vaultAt(1);
    }

    function test_vaultsPaged_returnsTheRequestedWindow() public {
        vm.prank(vaultFactory);
        sm.registerVault(vault);
        MockVault second = _newRegisteredVault();
        MockVault third = _newRegisteredVault();

        address[] memory page = sm.vaultsPaged(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], address(second));
        assertEq(page[1], address(third));
    }

    /// @dev A caller paging blind must not have to know the length to avoid reverting.
    function test_vaultsPaged_clampsALimitThatOverrunsTheEnd() public {
        vm.prank(vaultFactory);
        sm.registerVault(vault);
        MockVault second = _newRegisteredVault();

        address[] memory page = sm.vaultsPaged(1, 500);
        assertEq(page.length, 1);
        assertEq(page[0], address(second));
    }

    function test_vaultsPaged_returnsEmptyWhenOffsetIsAtOrPastTheEnd() public {
        vm.prank(vaultFactory);
        sm.registerVault(vault);

        assertEq(sm.vaultsPaged(1, 10).length, 0);
        assertEq(sm.vaultsPaged(99, 10).length, 0);
    }

    // -----------------------------------------------------------------------
    // Vault index — role lookup
    // -----------------------------------------------------------------------

    function test_vaultsWithRole_reportsEachRoleAsItsOwnBit() public {
        MockVault mv = _newRegisteredVault();
        mv.setCurator(curator);
        mv.setGuardian(guardian);
        mv.setAllocator(alice);
        mv.setKeeper(keeper, true);

        (, uint8[] memory ownerMask) = sm.vaultsWithRole(vaultOwner, 0, 10);
        (, uint8[] memory curatorMask) = sm.vaultsWithRole(curator, 0, 10);
        (, uint8[] memory guardianMask) = sm.vaultsWithRole(guardian, 0, 10);
        (, uint8[] memory allocatorMask) = sm.vaultsWithRole(alice, 0, 10);
        (, uint8[] memory keeperMask) = sm.vaultsWithRole(keeper, 0, 10);

        assertEq(ownerMask[0], uint8(1) << uint8(VaultRole.OWNER));
        assertEq(curatorMask[0], uint8(1) << uint8(VaultRole.CURATOR));
        assertEq(guardianMask[0], uint8(1) << uint8(VaultRole.GUARDIAN));
        assertEq(allocatorMask[0], uint8(1) << uint8(VaultRole.ALLOCATOR));
        assertEq(keeperMask[0], uint8(1) << uint8(VaultRole.KEEPER));
    }

    function test_vaultsWithRole_returnsTheVaultAlongsideItsMask() public {
        MockVault mv = _newRegisteredVault();

        (address[] memory vaults, uint8[] memory masks) = sm.vaultsWithRole(vaultOwner, 0, 10);
        assertEq(vaults.length, 1);
        assertEq(masks.length, 1);
        assertEq(vaults[0], address(mv));
    }

    function test_vaultsWithRole_unionsEveryRoleOneAccountHolds() public {
        MockVault mv = _newRegisteredVault();
        mv.setCurator(vaultOwner);
        mv.setKeeper(vaultOwner, true);

        (, uint8[] memory masks) = sm.vaultsWithRole(vaultOwner, 0, 10);
        uint8 expected = (uint8(1) << uint8(VaultRole.OWNER)) | (uint8(1) << uint8(VaultRole.CURATOR))
            | (uint8(1) << uint8(VaultRole.KEEPER));
        assertEq(masks[0], expected);
    }

    function test_vaultsWithRole_omitsVaultsWhereTheAccountHoldsNothing() public {
        _newRegisteredVault(); // vaultOwner owns this one
        MockVault other = new MockVault(alice); // alice owns this one
        vm.prank(vaultFactory);
        sm.registerVault(address(other));

        (address[] memory vaults, uint8[] memory masks) = sm.vaultsWithRole(alice, 0, 10);
        assertEq(vaults.length, 1);
        assertEq(masks.length, 1);
        assertEq(vaults[0], address(other));
    }

    function test_vaultsWithRole_returnsEmptyForAnAccountWithNoRoleAnywhere() public {
        _newRegisteredVault();

        (address[] memory vaults, uint8[] memory masks) = sm.vaultsWithRole(makeAddr("nobody"), 0, 10);
        assertEq(vaults.length, 0);
        assertEq(masks.length, 0);
    }

    /// @dev A disconnected front end passes address(0). Matching it against unset role slots
    ///      would report every vault with no curator as "curated by 0x0" — worse than empty.
    function test_vaultsWithRole_neverMatchesTheZeroAddress() public {
        _newRegisteredVault(); // curator/guardian/allocator all left unset, i.e. address(0)

        (address[] memory vaults, uint8[] memory masks) = sm.vaultsWithRole(address(0), 0, 10);
        assertEq(vaults.length, 0);
        assertEq(masks.length, 0);
    }

    /// @dev The scan must stay inside the requested window — the whole point of paging an
    ///      unbounded list is that a caller can bound the work per eth_call.
    function test_vaultsWithRole_scansOnlyTheRequestedWindow() public {
        MockVault first = _newRegisteredVault();
        MockVault second = _newRegisteredVault();

        (address[] memory firstPage,) = sm.vaultsWithRole(vaultOwner, 0, 1);
        assertEq(firstPage.length, 1);
        assertEq(firstPage[0], address(first));

        (address[] memory secondPage,) = sm.vaultsWithRole(vaultOwner, 1, 1);
        assertEq(secondPage.length, 1);
        assertEq(secondPage[0], address(second));
    }
}
