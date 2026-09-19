// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HyperAccessControl} from "../src/governance/HyperAccessControl.sol";
import {VaultTimelock} from "../src/governance/VaultTimelock.sol";
import {StateManager} from "../src/asset-management/StateManager.sol";
import {Queue} from "../src/asset-management/settlement/Queue.sol";
import {EarnVault} from "../src/asset-management/vaults/EarnVault.sol";
import {IVaultTimelock} from "../src/interfaces/IVaultTimelock.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {IVaultRoles} from "../src/interfaces/IVaultRoles.sol";
import {ProductState, CycleState, ProductParams} from "../src/libs/Types.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("MockUSDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title VaultTimelockTest
/// @notice VaultTimelock had no dedicated suite: everything it was exercised for came in
///         incidentally through EarnVault.t.sol's `_scheduleAndExecute` happy path, leaving
///         `cancelParamChange`, `setDelay`, `setAllowedAction` and every lifecycle revert
///         (EntryNotFound / TooEarly / Expired / AlreadyExecuted / AlreadyCancelled /
///         NotOwnerOrCurator / ActionNotAllowed / DelayOutOfRange / NotSelf) unreached.
///
///         The Timelock is bound to a real EarnVault, not a mock, because `_isConfiguring()`
///         reads the Vault's own `stateManager()` and that Vault's registered ProductState —
///         the CONFIGURING / post-CONFIGURING split is the whole point of `setAllowedAction`'s
///         Owner-bootstrapping branch.
contract VaultTimelockTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    MockUSDT internal usdt;
    EarnVault internal vault;
    VaultTimelock internal tl;

    address internal governor = makeAddr("governor");
    address internal vaultOwner = makeAddr("vaultOwner");
    address internal curator = makeAddr("curator");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant NOW = 1_000_000;

    function setUp() public {
        vm.warp(NOW);

        ac = new HyperAccessControl(governor);
        sm = new StateManager(address(ac));
        queue = new Queue(address(sm));
        usdt = new MockUSDT();

        vm.prank(governor);
        sm.setVaultFactory(address(this));

        vault = new EarnVault(
            "Timelock Vault", "tlVLT", address(usdt), address(sm), address(queue), vaultOwner, address(0)
        );
        tl = new VaultTimelock(address(vault));
        vault.bindGovernance(address(tl));

        sm.registerVault(address(vault));

        vm.startPrank(vaultOwner);
        vault.setCurator(curator);
        vault.setGuardian(guardian);
        vault.setKeeper(keeper, true);
        vm.stopPrank();

        vm.prank(curator);
        sm.setProductParams(address(vault), _defaultParams());
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

    /// @dev Moves the Vault out of CONFIGURING so the Owner-bootstrapping branch of
    ///      `setAllowedAction` closes and `_isConfiguring()` returns false. Idempotent.
    function _leaveConfiguring() internal {
        if (sm.getProductState(address(vault)) == ProductState.CONFIGURING) {
            vm.prank(keeper);
            sm.openSubscription(address(vault));
        }
        assertEq(uint8(sm.getProductState(address(vault))), uint8(ProductState.SUBSCRIBING));
    }

    /// @dev Schedules an OWNER-class `setGate`. Leaves CONFIGURING first: BaseVault's
    ///      `_onlyOwnerDirectOrTimelock()` accepts only the *Owner* while CONFIGURING, so a
    ///      Timelock-issued call would fail there and every execution assertion below would
    ///      collapse into an indistinguishable `CallFailed`.
    function _scheduleGate(address proposer) internal returns (bytes32 id) {
        _leaveConfiguring();
        vm.prank(proposer);
        id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setGate, (makeAddr("gate"))));
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(IVaultTimelock.ZeroAddress.selector);
        new VaultTimelock(address(0));
    }

    function test_constructor_bindsVaultAndDefaultDelay() public view {
        assertEq(tl.vault(), address(vault));
        assertEq(tl.delay(), tl.DEFAULT_DELAY());
        assertEq(tl.changeNonce(), 0);
    }

    function test_constructor_seedsOwnerAndCuratorWhitelists() public view {
        assertTrue(
            tl.isActionAllowed(address(vault), IBaseVault.setSettlement.selector, IVaultTimelock.ActionClass.OWNER)
        );
        assertTrue(
            tl.isActionAllowed(address(vault), IBaseVault.setUnifiedPool.selector, IVaultTimelock.ActionClass.OWNER)
        );
        assertTrue(tl.isActionAllowed(address(vault), IBaseVault.setGate.selector, IVaultTimelock.ActionClass.OWNER));
        assertTrue(
            tl.isActionAllowed(
                address(vault), IBaseVault.writeDownInsolvency.selector, IVaultTimelock.ActionClass.OWNER
            )
        );
        assertTrue(tl.isActionAllowed(address(tl), VaultTimelock.setDelay.selector, IVaultTimelock.ActionClass.OWNER));
        assertTrue(
            tl.isActionAllowed(address(tl), VaultTimelock.setAllowedAction.selector, IVaultTimelock.ActionClass.OWNER)
        );

        assertTrue(
            tl.isActionAllowed(
                address(vault), IBaseVault.setPerformanceFeeBps.selector, IVaultTimelock.ActionClass.CURATOR
            )
        );
        assertTrue(
            tl.isActionAllowed(
                address(vault), IBaseVault.setPerformanceFeeRecipient.selector, IVaultTimelock.ActionClass.CURATOR
            )
        );
        assertTrue(
            tl.isActionAllowed(address(vault), IBaseVault.addAdapter.selector, IVaultTimelock.ActionClass.CURATOR)
        );
        assertTrue(
            tl.isActionAllowed(address(vault), IBaseVault.removeAdapter.selector, IVaultTimelock.ActionClass.CURATOR)
        );
        assertTrue(
            tl.isActionAllowed(
                address(vault), IBaseVault.setSubscriptionCapShare.selector, IVaultTimelock.ActionClass.CURATOR
            )
        );

        // The two classes are disjoint — an OWNER-class selector is not schedulable as CURATOR.
        assertFalse(tl.isActionAllowed(address(vault), IBaseVault.setGate.selector, IVaultTimelock.ActionClass.CURATOR));
        assertFalse(
            tl.isActionAllowed(address(vault), IBaseVault.addAdapter.selector, IVaultTimelock.ActionClass.OWNER)
        );
    }

    // -----------------------------------------------------------------------
    // scheduleParamChange
    // -----------------------------------------------------------------------

    function test_scheduleParamChange_revertsOnZeroTarget() public {
        vm.prank(vaultOwner);
        vm.expectRevert(IVaultTimelock.ZeroAddress.selector);
        tl.scheduleParamChange(address(0), abi.encodeCall(IBaseVault.setGate, (address(1))));
    }

    function test_scheduleParamChange_revertsForNonOwnerNonCurator() public {
        vm.prank(attacker);
        vm.expectRevert(IVaultTimelock.NotOwnerOrCurator.selector);
        tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setGate, (address(1))));
    }

    /// @dev The Curator resolves to CURATOR class, which is not whitelisted for an OWNER-class
    ///      selector — the class, not just the selector, is part of the whitelist key.
    function test_scheduleParamChange_curatorCannotScheduleOwnerAction() public {
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultTimelock.ActionNotAllowed.selector, address(vault), IBaseVault.setGate.selector
            )
        );
        tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setGate, (address(1))));
    }

    function test_scheduleParamChange_ownerCannotScheduleCuratorAction() public {
        vm.prank(vaultOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultTimelock.ActionNotAllowed.selector, address(vault), IBaseVault.setPerformanceFeeBps.selector
            )
        );
        tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(10))));
    }

    function test_scheduleParamChange_unlistedTargetReverts() public {
        address stranger = makeAddr("strangerTarget");
        vm.prank(vaultOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultTimelock.ActionNotAllowed.selector, stranger, IBaseVault.setGate.selector)
        );
        tl.scheduleParamChange(stranger, abi.encodeCall(IBaseVault.setGate, (address(1))));
    }

    function test_scheduleParamChange_recordsWindowAndBumpsNonce() public {
        bytes memory data = abi.encodeCall(IBaseVault.setGate, (makeAddr("gate")));
        vm.prank(vaultOwner);
        bytes32 id = tl.scheduleParamChange(address(vault), data);

        (
            address target,
            bytes memory stored,
            address proposer,
            uint256 execAfter,
            uint256 expires,
            bool executed,
            bool cancelled
        ) = tl.pendingChanges(id);
        assertEq(target, address(vault));
        assertEq(stored, data);
        assertEq(proposer, vaultOwner);
        assertEq(execAfter, NOW + tl.DEFAULT_DELAY());
        assertEq(expires, NOW + tl.DEFAULT_DELAY() + tl.EXECUTION_WINDOW());
        assertFalse(executed);
        assertFalse(cancelled);
        assertEq(tl.changeNonce(), 1);
    }

    /// @dev Identical calldata scheduled twice must produce distinct ids — the nonce is part of
    ///      the id preimage, so the second schedule cannot silently overwrite the first.
    function test_scheduleParamChange_identicalDataYieldsDistinctIds() public {
        bytes32 first = _scheduleGate(vaultOwner);
        bytes32 second = _scheduleGate(vaultOwner);
        assertTrue(first != second);
        assertEq(tl.changeNonce(), 2);
    }

    function test_scheduleParamChange_emitsEvent() public {
        bytes memory data = abi.encodeCall(IBaseVault.setGate, (makeAddr("gate")));
        vm.expectEmit(false, false, false, true, address(tl));
        emit IVaultTimelock.ParamChangeScheduled(
            keccak256(abi.encode(address(tl), block.chainid, address(vault), address(vault), data, uint256(0))),
            address(vault),
            data,
            NOW + tl.DEFAULT_DELAY(),
            NOW + tl.DEFAULT_DELAY() + tl.EXECUTION_WINDOW()
        );
        vm.prank(vaultOwner);
        tl.scheduleParamChange(address(vault), data);
    }

    // -----------------------------------------------------------------------
    // executeParamChange
    // -----------------------------------------------------------------------

    function test_executeParamChange_unknownIdReverts() public {
        vm.expectRevert(IVaultTimelock.EntryNotFound.selector);
        tl.executeParamChange(keccak256("nope"));
    }

    function test_executeParamChange_beforeDelayReverts() public {
        bytes32 id = _scheduleGate(vaultOwner);
        vm.warp(block.timestamp + tl.delay() - 1);
        vm.expectRevert(IVaultTimelock.TooEarly.selector);
        tl.executeParamChange(id);
    }

    function test_executeParamChange_afterWindowReverts() public {
        bytes32 id = _scheduleGate(vaultOwner);
        vm.warp(block.timestamp + tl.delay() + tl.EXECUTION_WINDOW() + 1);
        vm.expectRevert(IVaultTimelock.Expired.selector);
        tl.executeParamChange(id);
    }

    function test_executeParamChange_atExactBoundariesSucceeds() public {
        bytes32 id = _scheduleGate(vaultOwner);
        // executableAfter is inclusive (`block.timestamp < executableAfter` reverts).
        vm.warp(NOW + tl.delay());
        tl.executeParamChange(id);

        bytes32 id2 = _scheduleGate(vaultOwner);
        // expiresAt is inclusive too (`block.timestamp > expiresAt` reverts).
        (,,,, uint256 expires,,) = tl.pendingChanges(id2);
        vm.warp(expires);
        tl.executeParamChange(id2);
    }

    function test_executeParamChange_appliesTheCallAndIsPermissionless() public {
        _leaveConfiguring();
        address newGate = makeAddr("newGate");
        vm.prank(vaultOwner);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setGate, (newGate)));
        vm.warp(block.timestamp + tl.delay());

        // Execution is deliberately open to anyone once the delay has elapsed.
        vm.prank(attacker);
        tl.executeParamChange(id);

        assertEq(vault.gate(), newGate);
        (,,,,, bool executed,) = tl.pendingChanges(id);
        assertTrue(executed);
    }

    function test_executeParamChange_twiceReverts() public {
        bytes32 id = _scheduleGate(vaultOwner);
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(id);

        vm.expectRevert(IVaultTimelock.AlreadyExecuted.selector);
        tl.executeParamChange(id);
    }

    /// @dev A reverting target surfaces as the generic CallFailed — the underlying revert data is
    ///      swallowed by the low-level `.call`. Pinned so nobody mistakes it for a passing call.
    function test_executeParamChange_targetRevertSurfacesAsCallFailed() public {
        _leaveConfiguring(); // otherwise the Timelock is not an authorised caller at all and the
        // CallFailed would prove nothing about the fee guard
        vm.prank(curator);
        tl.scheduleParamChange(
            address(vault), abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (makeAddr("feeRecipient")))
        );
        // Control: the same Curator-class route succeeds when the target accepts the call.
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(
            keccak256(
                abi.encode(
                    address(tl),
                    block.chainid,
                    address(vault),
                    address(vault),
                    abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (makeAddr("feeRecipient"))),
                    uint256(0)
                )
            )
        );
        assertEq(vault.performanceFeeRecipient(), makeAddr("feeRecipient"), "control call landed");

        // Now the failing one: above MAX_PERFORMANCE_FEE_BPS the Vault reverts FeeTooHigh, which
        // the low-level `.call` swallows and re-raises as the generic CallFailed.
        vm.prank(curator);
        bytes32 id =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setPerformanceFeeBps, (uint16(10_001))));
        vm.warp(block.timestamp + tl.delay());

        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);

        assertEq(vault.performanceFeeBps(), 0);
    }

    /// @dev The share-denominated issuance cap is a Curator-class Vault parameter, so past
    ///      CONFIGURING the only route to it is a scheduled Timelock call.
    function test_executeParamChange_curatorSetsSubscriptionCapShare() public {
        _leaveConfiguring();
        vm.prank(curator);
        bytes32 id =
            tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setSubscriptionCapShare, (750e18)));
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(id);

        assertEq(vault.subscriptionCapShare(), 750e18);
    }

    function test_scheduleParamChange_subscriptionCapShareRejectsStranger() public {
        _leaveConfiguring();
        vm.prank(attacker);
        vm.expectRevert(IVaultTimelock.NotOwnerOrCurator.selector);
        tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setSubscriptionCapShare, (750e18)));
    }

    function test_executeParamChange_emitsEvent() public {
        bytes32 id = _scheduleGate(vaultOwner);
        vm.warp(block.timestamp + tl.delay());

        vm.expectEmit(true, false, false, true, address(tl));
        emit IVaultTimelock.ParamChangeExecuted(id, block.timestamp);
        tl.executeParamChange(id);
    }

    // -----------------------------------------------------------------------
    // cancelParamChange
    // -----------------------------------------------------------------------

    function test_cancelParamChange_unknownIdReverts() public {
        vm.expectRevert(IVaultTimelock.EntryNotFound.selector);
        tl.cancelParamChange(keccak256("nope"));
    }

    function test_cancelParamChange_byOwner() public {
        bytes32 id = _scheduleGate(curator == vaultOwner ? curator : vaultOwner);
        vm.prank(vaultOwner);
        tl.cancelParamChange(id);
        (,,,,,, bool cancelled) = tl.pendingChanges(id);
        assertTrue(cancelled);
    }

    function test_cancelParamChange_byGuardian() public {
        bytes32 id = _scheduleGate(vaultOwner);
        vm.prank(guardian);
        tl.cancelParamChange(id);
        (,,,,,, bool cancelled) = tl.pendingChanges(id);
        assertTrue(cancelled);
    }

    /// @dev The proposer branch needs a proposer who is neither Owner nor Guardian — otherwise the
    ///      earlier two checks short-circuit and this path is never taken. The Curator scheduling
    ///      a CURATOR-class action is exactly that case.
    function test_cancelParamChange_byProposerWhoIsNeitherOwnerNorGuardian() public {
        vm.prank(curator);
        bytes32 id = tl.scheduleParamChange(
            address(vault), abi.encodeCall(IBaseVault.setPerformanceFeeRecipient, (makeAddr("feeRecipient")))
        );

        vm.prank(curator);
        tl.cancelParamChange(id);

        (,,,,,, bool cancelled) = tl.pendingChanges(id);
        assertTrue(cancelled);
    }

    function test_cancelParamChange_byStrangerReverts() public {
        bytes32 id = _scheduleGate(vaultOwner);
        vm.prank(attacker);
        vm.expectRevert(IVaultTimelock.NotOwnerOrGuardianOrProposer.selector);
        tl.cancelParamChange(id);
    }

    function test_cancelParamChange_thenExecuteReverts() public {
        address gateBefore = vault.gate();
        bytes32 id = _scheduleGate(vaultOwner);
        vm.prank(guardian);
        tl.cancelParamChange(id);

        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.AlreadyCancelled.selector);
        tl.executeParamChange(id);

        assertEq(vault.gate(), gateBefore, "cancelled change must not have applied");
    }

    function test_cancelParamChange_twiceReverts() public {
        bytes32 id = _scheduleGate(vaultOwner);
        vm.prank(guardian);
        tl.cancelParamChange(id);

        vm.prank(guardian);
        vm.expectRevert(IVaultTimelock.AlreadyCancelled.selector);
        tl.cancelParamChange(id);
    }

    function test_cancelParamChange_afterExecutionReverts() public {
        bytes32 id = _scheduleGate(vaultOwner);
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(id);

        vm.prank(guardian);
        vm.expectRevert(IVaultTimelock.AlreadyExecuted.selector);
        tl.cancelParamChange(id);
    }

    function test_cancelParamChange_emitsEvent() public {
        bytes32 id = _scheduleGate(vaultOwner);
        vm.expectEmit(true, false, false, true, address(tl));
        emit IVaultTimelock.ParamChangeCancelled(id, block.timestamp);
        vm.prank(guardian);
        tl.cancelParamChange(id);
    }

    // -----------------------------------------------------------------------
    // setDelay — self-scheduled only
    // -----------------------------------------------------------------------

    function test_setDelay_directCallReverts() public {
        vm.prank(vaultOwner);
        vm.expectRevert(IVaultTimelock.NotSelf.selector);
        tl.setDelay(2 hours);
    }

    function test_setDelay_viaScheduledSelfCall() public {
        uint256 oldDelay = tl.delay();
        vm.prank(vaultOwner);
        bytes32 id = tl.scheduleParamChange(address(tl), abi.encodeCall(VaultTimelock.setDelay, (3 hours)));
        vm.warp(block.timestamp + oldDelay);

        vm.expectEmit(false, false, false, true, address(tl));
        emit IVaultTimelock.DelayUpdated(oldDelay, 3 hours, block.timestamp);
        tl.executeParamChange(id);

        assertEq(tl.delay(), 3 hours);
    }

    /// @dev The new delay applies to changes scheduled *after* it lands; already-queued entries
    ///      keep the window stamped at schedule time.
    function test_setDelay_appliesToSubsequentSchedulesOnly() public {
        bytes32 early = _scheduleGate(vaultOwner);
        (,,, uint256 earlyExecAfter,,,) = tl.pendingChanges(early);

        vm.prank(vaultOwner);
        bytes32 delayId = tl.scheduleParamChange(address(tl), abi.encodeCall(VaultTimelock.setDelay, (1 hours)));
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(delayId);
        assertEq(tl.delay(), 1 hours);

        bytes32 late = _scheduleGate(vaultOwner);
        (,,, uint256 lateExecAfter,,,) = tl.pendingChanges(late);
        assertEq(lateExecAfter, block.timestamp + 1 hours);
        assertEq(earlyExecAfter, NOW + tl.DEFAULT_DELAY(), "queued entry keeps its original window");
    }

    function test_setDelay_belowMinReverts() public {
        uint256 tooSmall = tl.MIN_DELAY() - 1; // read before the prank so it isn't consumed by it
        vm.prank(vaultOwner);
        bytes32 id = tl.scheduleParamChange(address(tl), abi.encodeCall(VaultTimelock.setDelay, (tooSmall)));
        vm.warp(block.timestamp + tl.delay());
        // DelayOutOfRange is raised inside the self-call, so it surfaces as CallFailed.
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);
        assertEq(tl.delay(), tl.DEFAULT_DELAY());
    }

    function test_setDelay_aboveMaxReverts() public {
        uint256 tooLarge = tl.MAX_DELAY() + 1; // read before the prank so it isn't consumed by it
        vm.prank(vaultOwner);
        bytes32 id = tl.scheduleParamChange(address(tl), abi.encodeCall(VaultTimelock.setDelay, (tooLarge)));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);
        assertEq(tl.delay(), tl.DEFAULT_DELAY());
    }

    // -----------------------------------------------------------------------
    // setAllowedAction — Owner bootstrap while CONFIGURING, self-call afterwards
    // -----------------------------------------------------------------------

    function test_setAllowedAction_ownerBootstrapsWhileConfiguring() public {
        address adapterTarget = makeAddr("adapterTarget");
        bytes4 sel = bytes4(keccak256("setStalenessWindow(uint256)"));

        assertFalse(tl.isActionAllowed(adapterTarget, sel, IVaultTimelock.ActionClass.CURATOR));

        vm.expectEmit(true, true, false, true, address(tl));
        emit IVaultTimelock.AllowedActionSet(
            adapterTarget, sel, IVaultTimelock.ActionClass.CURATOR, true, block.timestamp
        );
        vm.prank(vaultOwner);
        tl.setAllowedAction(adapterTarget, sel, IVaultTimelock.ActionClass.CURATOR, true);

        assertTrue(tl.isActionAllowed(adapterTarget, sel, IVaultTimelock.ActionClass.CURATOR));
    }

    /// @dev The bootstrap window closes with CONFIGURING — this is the `_isConfiguring() == false`
    ///      branch, and the only way to whitelist anything afterwards is a scheduled self-call.
    function test_setAllowedAction_ownerBlockedOnceOutOfConfiguring() public {
        _leaveConfiguring();

        vm.prank(vaultOwner);
        vm.expectRevert(IVaultTimelock.NotSelf.selector);
        tl.setAllowedAction(makeAddr("t"), bytes4(0x12345678), IVaultTimelock.ActionClass.CURATOR, true);
    }

    function test_setAllowedAction_strangerBlockedEvenWhileConfiguring() public {
        vm.prank(attacker);
        vm.expectRevert(IVaultTimelock.NotSelf.selector);
        tl.setAllowedAction(makeAddr("t"), bytes4(0x12345678), IVaultTimelock.ActionClass.CURATOR, true);
    }

    function test_setAllowedAction_curatorBlockedEvenWhileConfiguring() public {
        vm.prank(curator);
        vm.expectRevert(IVaultTimelock.NotSelf.selector);
        tl.setAllowedAction(makeAddr("t"), bytes4(0x12345678), IVaultTimelock.ActionClass.CURATOR, true);
    }

    function test_setAllowedAction_viaScheduledSelfCallAfterConfiguring() public {
        _leaveConfiguring();

        address adapterTarget = makeAddr("adapterTarget2");
        bytes4 sel = bytes4(keccak256("setDataProvider(address)"));

        vm.prank(vaultOwner);
        bytes32 id = tl.scheduleParamChange(
            address(tl),
            abi.encodeCall(
                VaultTimelock.setAllowedAction, (adapterTarget, sel, IVaultTimelock.ActionClass.CURATOR, true)
            )
        );
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(id);

        assertTrue(tl.isActionAllowed(adapterTarget, sel, IVaultTimelock.ActionClass.CURATOR));
    }

    /// @dev Whitelisting is revocable, and a revoked action can no longer be scheduled.
    function test_setAllowedAction_revokeBlocksFurtherScheduling() public {
        vm.prank(vaultOwner);
        tl.setAllowedAction(address(vault), IBaseVault.setGate.selector, IVaultTimelock.ActionClass.OWNER, false);

        vm.prank(vaultOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultTimelock.ActionNotAllowed.selector, address(vault), IBaseVault.setGate.selector
            )
        );
        tl.scheduleParamChange(address(vault), abi.encodeCall(IBaseVault.setGate, (address(1))));
    }

    /// @dev Whitelisting flips the Timelock's own gate: the same schedule goes from
    ///      ActionNotAllowed (rejected by the Timelock) to reaching the Vault, whose separate
    ///      Owner-only gate then rejects it. Two different rejections, two different layers.
    function test_setAllowedAction_newlyAllowedActionReachesTheVaultsOwnGate() public {
        // setKeeper is not in the constructor's seed list for either class.
        vm.prank(vaultOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultTimelock.ActionNotAllowed.selector, address(vault), IVaultRoles.setKeeper.selector
            )
        );
        tl.scheduleParamChange(address(vault), abi.encodeCall(IVaultRoles.setKeeper, (attacker, true)));

        vm.prank(vaultOwner);
        tl.setAllowedAction(address(vault), IVaultRoles.setKeeper.selector, IVaultTimelock.ActionClass.OWNER, true);

        // The Vault's own setKeeper is `_onlyOwner()`-gated, so a Timelock-issued call would be
        // rejected by the Vault — the point here is only that the Timelock now lets it through
        // its own whitelist and surfaces the Vault's rejection rather than ActionNotAllowed.
        vm.prank(vaultOwner);
        bytes32 id = tl.scheduleParamChange(address(vault), abi.encodeCall(IVaultRoles.setKeeper, (attacker, true)));
        vm.warp(block.timestamp + tl.delay());
        vm.expectRevert(IVaultTimelock.CallFailed.selector);
        tl.executeParamChange(id);
        assertFalse(vault.isKeeper(attacker));
    }

    // -----------------------------------------------------------------------
    // Pending-change index — the CURRENT queue
    // -----------------------------------------------------------------------
    // `pendingChanges` is bytes32-keyed and so answers "what is change X?" but never "what is
    // queued on this Vault right now?" — today that needs a three-way replay of Scheduled /
    // Executed / Cancelled. Missing a queued change means missing a pending privileged action.

    function test_pendingChangeCount_isZeroBeforeAnythingIsScheduled() public view {
        assertEq(tl.pendingChangeCount(), 0);
    }

    function test_pendingIndex_tracksScheduling() public {
        bytes32 first = _scheduleGate(vaultOwner);
        assertEq(tl.pendingChangeCount(), 1);
        assertEq(tl.pendingChangesPaged(0, 10)[0], first);

        bytes32 second = _scheduleGate(vaultOwner);
        assertEq(tl.pendingChangeCount(), 2);
        bytes32[] memory page = tl.pendingChangesPaged(0, 10);
        assertEq(page[0], first);
        assertEq(page[1], second);
    }

    /// @dev Executing drops the entry. Swap-and-pop, so the survivor moves into the freed slot —
    ///      the reason the doc comment tells callers to pin one blockTag.
    function test_pendingIndex_dropsAnExecutedChangeAndSwapsDownTheSurvivor() public {
        bytes32 first = _scheduleGate(vaultOwner);
        bytes32 second = _scheduleGate(vaultOwner);

        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(first);

        assertEq(tl.pendingChangeCount(), 1);
        bytes32[] memory page = tl.pendingChangesPaged(0, 10);
        assertEq(page.length, 1);
        assertEq(page[0], second, "survivor swapped down into index 0");
    }

    /// @dev Cancelling must drop the entry too — the list would otherwise report a cancelled
    ///      change as still-pending, which is exactly the monitoring failure this index exists
    ///      to prevent.
    function test_pendingIndex_dropsACancelledChange() public {
        bytes32 first = _scheduleGate(vaultOwner);
        bytes32 second = _scheduleGate(vaultOwner);

        vm.prank(guardian);
        tl.cancelParamChange(first);

        assertEq(tl.pendingChangeCount(), 1);
        assertEq(tl.pendingChangesPaged(0, 10)[0], second);
    }

    function test_pendingIndex_emptiesOnceEveryChangeIsResolved() public {
        bytes32 first = _scheduleGate(vaultOwner);
        bytes32 second = _scheduleGate(vaultOwner);

        vm.prank(guardian);
        tl.cancelParamChange(second);
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(first);

        assertEq(tl.pendingChangeCount(), 0);
        assertEq(tl.pendingChangesPaged(0, 10).length, 0);
    }

    /// @dev Expiry is a timestamp comparison, not a state transition: nothing sweeps an expired
    ///      entry, so it stays listed and callers must read `expiresAt` themselves. Asserting the
    ///      documented behaviour rather than an idealised one.
    function test_pendingIndex_stillListsAnExpiredChange() public {
        bytes32 id = _scheduleGate(vaultOwner);

        (,,,, uint256 expiresAt,,) = tl.pendingChanges(id);
        vm.warp(expiresAt + 1);

        assertEq(tl.pendingChangeCount(), 1, "expired but never swept");
        assertEq(tl.pendingChangesPaged(0, 10)[0], id);

        vm.expectRevert(IVaultTimelock.Expired.selector);
        tl.executeParamChange(id);
    }

    function test_pendingChangesPaged_clampsInsteadOfReverting() public {
        _scheduleGate(vaultOwner);
        bytes32 second = _scheduleGate(vaultOwner);

        bytes32[] memory page = tl.pendingChangesPaged(1, type(uint256).max);
        assertEq(page.length, 1);
        assertEq(page[0], second);

        assertEq(tl.pendingChangesPaged(2, 10).length, 0);
        assertEq(tl.pendingChangesPaged(99, 10).length, 0);
    }

    // -----------------------------------------------------------------------
    // Allowed-action index — APPEND-ONLY, unlike the pending-change index
    // -----------------------------------------------------------------------
    // `isActionAllowed` is triple-nested and cannot be walked at all. Entries are candidates,
    // not permissions: a tuple set back to false stays listed, so callers must re-filter.

    function test_allowedActionCount_coversTheConstructorSeededSet() public view {
        // Five OWNER-class on the Vault, two OWNER-class on the Timelock itself, five CURATOR-class.
        assertEq(tl.allowedActionCount(), 12);
    }

    function test_allowedActionsPaged_returnsTheSeededTuples() public view {
        IVaultTimelock.AllowedAction[] memory page = tl.allowedActionsPaged(0, 100);
        assertEq(page.length, 12);

        assertEq(page[0].target, address(vault));
        assertEq(page[0].selector, IBaseVault.setSettlement.selector);
        assertTrue(page[0].class == IVaultTimelock.ActionClass.OWNER);

        assertEq(page[5].target, address(tl));
        assertEq(page[5].selector, VaultTimelock.setDelay.selector);
        assertTrue(page[5].class == IVaultTimelock.ActionClass.OWNER);

        assertEq(page[11].target, address(vault));
        assertEq(page[11].selector, IBaseVault.setSubscriptionCapShare.selector);
        assertTrue(page[11].class == IVaultTimelock.ActionClass.CURATOR);
    }

    function test_allowedActionIndex_appendsANewlyAllowedTuple() public {
        address target = makeAddr("adapterTarget");
        bytes4 sel = bytes4(keccak256("someAdapterCall()"));

        vm.prank(vaultOwner); // Owner may bootstrap directly while CONFIGURING
        tl.setAllowedAction(target, sel, IVaultTimelock.ActionClass.CURATOR, true);

        assertEq(tl.allowedActionCount(), 13);
        IVaultTimelock.AllowedAction[] memory page = tl.allowedActionsPaged(12, 10);
        assertEq(page.length, 1);
        assertEq(page[0].target, target);
        assertEq(page[0].selector, sel);
        assertTrue(page[0].class == IVaultTimelock.ActionClass.CURATOR);
    }

    /// @dev The list is append-only, so a revoked tuple STAYS listed. That is the documented
    ///      cost of stable indices — callers must filter through `isActionAllowed`.
    function test_allowedActionIndex_keepsARevokedTupleListedButNotAllowed() public {
        address target = makeAddr("adapterTarget");
        bytes4 sel = bytes4(keccak256("someAdapterCall()"));

        vm.startPrank(vaultOwner);
        tl.setAllowedAction(target, sel, IVaultTimelock.ActionClass.CURATOR, true);
        tl.setAllowedAction(target, sel, IVaultTimelock.ActionClass.CURATOR, false);
        vm.stopPrank();

        assertEq(tl.allowedActionCount(), 13, "entry survives revocation");
        IVaultTimelock.AllowedAction[] memory page = tl.allowedActionsPaged(12, 10);
        assertEq(page[0].target, target);
        // ...but it is no longer permitted, which the caller only learns by re-checking.
        assertFalse(tl.isActionAllowed(target, sel, IVaultTimelock.ActionClass.CURATOR));
    }

    /// @dev Toggling off and back on must not double-list the tuple.
    function test_allowedActionIndex_doesNotDoubleListOnReAllow() public {
        address target = makeAddr("adapterTarget");
        bytes4 sel = bytes4(keccak256("someAdapterCall()"));

        vm.startPrank(vaultOwner);
        tl.setAllowedAction(target, sel, IVaultTimelock.ActionClass.CURATOR, true);
        tl.setAllowedAction(target, sel, IVaultTimelock.ActionClass.CURATOR, false);
        tl.setAllowedAction(target, sel, IVaultTimelock.ActionClass.CURATOR, true);
        vm.stopPrank();

        assertEq(tl.allowedActionCount(), 13);
    }

    /// @dev Never-allowed tuples must not be listed at all.
    function test_allowedActionIndex_ignoresARevokeOfAnUnlistedTuple() public {
        vm.prank(vaultOwner);
        tl.setAllowedAction(makeAddr("stranger"), bytes4(0x12345678), IVaultTimelock.ActionClass.OWNER, false);

        assertEq(tl.allowedActionCount(), 12);
    }

    /// @dev The same (target, selector) under a different class is a distinct tuple.
    function test_allowedActionIndex_treatsEachClassAsItsOwnEntry() public {
        address target = makeAddr("adapterTarget");
        bytes4 sel = bytes4(keccak256("someAdapterCall()"));

        vm.startPrank(vaultOwner);
        tl.setAllowedAction(target, sel, IVaultTimelock.ActionClass.OWNER, true);
        tl.setAllowedAction(target, sel, IVaultTimelock.ActionClass.CURATOR, true);
        vm.stopPrank();

        assertEq(tl.allowedActionCount(), 14);
    }

    function test_allowedActionsPaged_clampsInsteadOfReverting() public view {
        IVaultTimelock.AllowedAction[] memory page = tl.allowedActionsPaged(11, type(uint256).max);
        assertEq(page.length, 1);

        assertEq(tl.allowedActionsPaged(12, 10).length, 0);
        assertEq(tl.allowedActionsPaged(99, 10).length, 0);
    }
}
