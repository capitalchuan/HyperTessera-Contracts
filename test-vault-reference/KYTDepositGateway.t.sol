// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HyperAccessControl} from "../src/governance/HyperAccessControl.sol";
import {VaultTimelock} from "../src/governance/VaultTimelock.sol";
import {StateManager} from "../src/asset-management/StateManager.sol";
import {EarnVault} from "../src/asset-management/vaults/EarnVault.sol";
import {Queue} from "../src/asset-management/settlement/Queue.sol";
import {KYTDepositGateway} from "../src/compliance/KYTDepositGateway.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {ProductParams} from "../src/libs/Types.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("MockUSDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract KYTDepositGatewayTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    MockUSDT internal usdt;
    EarnVault internal vault;
    VaultTimelock internal tl;
    KYTDepositGateway internal gw;

    address internal governor = makeAddr("governor");
    address internal curator = makeAddr("curator");
    address internal factory = makeAddr("factory");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal settlement = makeAddr("settlement");
    address internal oracle = makeAddr("oracle");
    address internal gwAdmin = makeAddr("gwAdmin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant NOW = 1_000_000;
    uint64 internal constant VALIDITY = 1 hours;

    function setUp() public {
        vm.warp(NOW);

        ac = new HyperAccessControl(governor);
        usdt = new MockUSDT();
        sm = new StateManager(address(ac));

        vm.prank(governor);
        sm.setVaultFactory(factory);

        queue = new Queue(address(sm));

        vault = new EarnVault(
            "HyperTessera Cash Earn", "htCASH", address(usdt), address(sm), address(queue), governor, address(0)
        );

        tl = new VaultTimelock(address(vault));
        vm.prank(factory);
        vault.bindGovernance(address(tl));

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

        gw = new KYTDepositGateway(address(vault), oracle, gwAdmin, VALIDITY);

        // setGate while still CONFIGURING — direct Owner call, no timelock needed.
        vm.prank(governor);
        vault.setGate(address(gw));

        vm.prank(keeper);
        sm.openSubscription(address(vault));

        usdt.mint(alice, 100_000e6);
        usdt.mint(bob, 100_000e6);
    }

    function _defaultParams() internal pure returns (ProductParams memory) {
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

    /// @notice alice approves the Gateway for USDT and authorises it as her Vault operator —
    ///         the two-step setup the spec describes for KYT-on mode.
    function _prepare(address payer, address owner, uint256 amount) internal {
        vm.prank(payer);
        usdt.approve(address(gw), amount);
        vm.prank(owner);
        vault.setOperator(address(gw), true);
    }

    function _request(address payer, address owner, uint256 amount) internal returns (uint256 id) {
        vm.prank(payer);
        id = gw.requestDeposit(amount, owner);
    }

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    function test_constructor_wiresVaultAssetAndConfig() public view {
        assertEq(gw.vault(), address(vault));
        assertEq(gw.asset(), address(usdt));
        assertEq(gw.oracle(), oracle);
        assertEq(gw.admin(), gwAdmin);
        assertEq(gw.validityPeriod(), VALIDITY);
        assertEq(gw.nextRequestId(), 1);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(KYTDepositGateway.ZeroAddress.selector);
        new KYTDepositGateway(address(0), oracle, gwAdmin, VALIDITY);

        vm.expectRevert(KYTDepositGateway.ZeroAddress.selector);
        new KYTDepositGateway(address(vault), address(0), gwAdmin, VALIDITY);

        vm.expectRevert(KYTDepositGateway.ZeroAddress.selector);
        new KYTDepositGateway(address(vault), oracle, address(0), VALIDITY);
    }

    function test_constructor_revertsOnOutOfBoundsValidityPeriod() public {
        vm.expectRevert(abi.encodeWithSelector(KYTDepositGateway.InvalidValidityPeriod.selector, uint64(1 minutes)));
        new KYTDepositGateway(address(vault), oracle, gwAdmin, 1 minutes);

        vm.expectRevert(abi.encodeWithSelector(KYTDepositGateway.InvalidValidityPeriod.selector, uint64(8 days)));
        new KYTDepositGateway(address(vault), oracle, gwAdmin, 8 days);
    }

    // -----------------------------------------------------------------------
    // Gate behaviour — the Gateway is the only subscription entry point when KYT is ON
    // -----------------------------------------------------------------------

    function test_directVaultDeposit_blockedWhileGateInstalled() public {
        vm.startPrank(alice);
        usdt.approve(address(vault), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.GateBlocked.selector, alice));
        vault.requestDeposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_isAllowed_falseOutsideFulfil() public view {
        assertFalse(gw.isAllowed(alice));
        assertFalse(gw.isAllowed(address(0)));
        assertFalse(gw.isAllowed(address(gw)));
    }

    function test_isAllowed_falseAfterFulfilCompletes() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);
        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));

        assertFalse(gw.isAllowed(alice));
    }

    function test_kytOff_directVaultDepositWorks() public {
        // Governance clears the gate; the Gateway is bypassed entirely.
        _scheduleAndExecute(governor, abi.encodeWithSelector(IBaseVault.setGate.selector, address(0)));

        vm.startPrank(alice);
        usdt.approve(address(vault), 1_000e6);
        uint256 rid = vault.requestDeposit(1_000e6, alice);
        vm.stopPrank();

        assertEq(rid, 1);
        assertEq(usdt.balanceOf(address(vault)), 1_000e6);
    }

    function _scheduleAndExecute(address proposer, bytes memory data) internal returns (bytes32 id) {
        vm.prank(proposer);
        id = tl.scheduleParamChange(address(vault), data);
        vm.warp(block.timestamp + tl.delay());
        tl.executeParamChange(id);
    }

    // -----------------------------------------------------------------------
    // requestDeposit
    // -----------------------------------------------------------------------

    function test_requestDeposit_recordsRequestAndMovesNoFunds() public {
        _prepare(alice, alice, 1_000e6);
        uint256 balBefore = usdt.balanceOf(alice);

        uint256 id = _request(alice, alice, 1_000e6);

        assertEq(id, 1);
        assertEq(gw.nextRequestId(), 2);
        assertEq(usdt.balanceOf(alice), balBefore, "no funds pulled at request time");
        assertEq(usdt.balanceOf(address(gw)), 0);
        assertEq(usdt.balanceOf(address(vault)), 0);

        KYTDepositGateway.ScreeningRequest memory r = gw.getRequest(id);
        assertEq(r.payer, alice);
        assertEq(r.owner, alice);
        assertEq(r.assets, 1_000e6);
        assertEq(r.requestedAt, uint64(NOW));
        assertEq(r.expiresAt, uint64(NOW) + VALIDITY);
        assertEq(uint8(r.state), uint8(KYTDepositGateway.RequestState.PENDING));
    }

    function test_requestDeposit_emitsScreeningRequested() public {
        _prepare(alice, alice, 1_000e6);
        vm.expectEmit(true, true, true, true);
        emit KYTDepositGateway.ScreeningRequested(1, alice, alice, 1_000e6, uint64(NOW) + VALIDITY);
        vm.prank(alice);
        gw.requestDeposit(1_000e6, alice);
    }

    /// @dev The payer is the caller, never calldata — a caller cannot have someone else screened
    ///      in their place.
    function test_requestDeposit_payerIsAlwaysCaller() public {
        _prepare(bob, alice, 1_000e6);
        uint256 id = _request(bob, alice, 1_000e6);

        KYTDepositGateway.ScreeningRequest memory r = gw.getRequest(id);
        assertEq(r.payer, bob, "payer is msg.sender");
        assertEq(r.owner, alice);
    }

    function test_requestDeposit_revertsOnZeroAssets() public {
        vm.expectRevert(KYTDepositGateway.ZeroAssets.selector);
        vm.prank(alice);
        gw.requestDeposit(0, alice);
    }

    function test_requestDeposit_revertsOnZeroOwner() public {
        vm.expectRevert(KYTDepositGateway.ZeroAddress.selector);
        vm.prank(alice);
        gw.requestDeposit(1_000e6, address(0));
    }

    function test_requestDeposit_snapshotsValidityPeriodAtRequestTime() public {
        _prepare(alice, alice, 2_000e6);
        uint256 first = _request(alice, alice, 1_000e6);

        vm.prank(gwAdmin);
        gw.setValidityPeriod(2 hours);

        uint256 second = _request(alice, alice, 1_000e6);

        assertEq(gw.getRequest(first).expiresAt, uint64(NOW) + VALIDITY, "existing request keeps its window");
        assertEq(gw.getRequest(second).expiresAt, uint64(NOW) + 2 hours);
    }

    // -----------------------------------------------------------------------
    // fulfill — pass
    // -----------------------------------------------------------------------

    function test_fulfill_passed_movesPayerFundsIntoVaultAndCreditsOwner() public {
        uint256 amount = 1_000e6;
        _prepare(alice, alice, amount);
        uint256 id = _request(alice, alice, amount);

        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));

        assertEq(usdt.balanceOf(alice), 100_000e6 - amount, "payer debited");
        assertEq(usdt.balanceOf(address(gw)), 0, "gateway holds nothing");
        assertEq(usdt.balanceOf(address(vault)), amount, "vault funded");
        assertEq(vault.pendingDepositByOwner(alice), amount, "subscription credited to owner");
        assertEq(uint8(gw.getRequest(id).state), uint8(KYTDepositGateway.RequestState.EXECUTED));
    }

    function test_fulfill_passed_payerDiffersFromOwner() public {
        uint256 amount = 1_000e6;
        _prepare(bob, alice, amount); // bob pays, alice owns
        uint256 id = _request(bob, alice, amount);

        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));

        assertEq(usdt.balanceOf(bob), 100_000e6 - amount, "payer debited");
        assertEq(usdt.balanceOf(alice), 100_000e6, "owner untouched");
        assertEq(vault.pendingDepositByOwner(alice), amount, "subscription credited to owner");
        assertEq(vault.pendingDepositByOwner(bob), 0);
    }

    function test_fulfill_passed_emitsDepositExecuted() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.expectEmit(true, true, true, true);
        emit KYTDepositGateway.DepositExecuted(id, 1, alice, 1_000e6, uint64(block.timestamp));
        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));
    }

    function test_fulfill_passed_leavesNoStandingAllowance() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));

        assertEq(IERC20(address(usdt)).allowance(address(gw), address(vault)), 0);
    }

    function test_fulfill_passed_revertsWhenOwnerHasNotAuthorisedGatewayAsOperator() public {
        vm.prank(alice);
        usdt.approve(address(gw), 1_000e6);
        // deliberately no vault.setOperator(gw, true)
        uint256 id = _request(alice, alice, 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(IBaseVault.NotOwnerOrOperator.selector, address(gw), alice));
        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));
    }

    function test_fulfill_passed_revertsWhenPayerRevokedApproval() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.prank(alice);
        usdt.approve(address(gw), 0);

        vm.prank(oracle);
        vm.expectRevert();
        gw.fulfill(id, true, uint64(block.timestamp));

        // Request is untouched and no funds moved — the listener may retry.
        assertEq(uint8(gw.getRequest(id).state), uint8(KYTDepositGateway.RequestState.PENDING));
        assertEq(usdt.balanceOf(address(vault)), 0);
    }

    // -----------------------------------------------------------------------
    // fulfill — reject
    // -----------------------------------------------------------------------

    function test_fulfill_rejected_marksRejectedAndMovesNoFunds() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.expectEmit(true, true, false, true);
        emit KYTDepositGateway.ScreeningRejected(id, alice, uint64(block.timestamp), block.timestamp);
        vm.prank(oracle);
        gw.fulfill(id, false, uint64(block.timestamp));

        assertEq(uint8(gw.getRequest(id).state), uint8(KYTDepositGateway.RequestState.REJECTED));
        assertEq(usdt.balanceOf(alice), 100_000e6, "payer not debited");
        assertEq(usdt.balanceOf(address(vault)), 0);
        assertEq(vault.pendingDepositByOwner(alice), 0);
    }

    // -----------------------------------------------------------------------
    // fulfill — authorisation, replay, expiry, timestamp validation
    // -----------------------------------------------------------------------

    function test_fulfill_revertsForNonOracle() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(alice);
        gw.fulfill(id, true, uint64(block.timestamp));

        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(gwAdmin);
        gw.fulfill(id, true, uint64(block.timestamp));
    }

    function test_fulfill_revertsForUnknownRequest() public {
        vm.expectRevert(abi.encodeWithSelector(KYTDepositGateway.RequestNotFound.selector, uint256(99)));
        vm.prank(oracle);
        gw.fulfill(99, true, uint64(block.timestamp));
    }

    function test_fulfill_cannotBeReplayed() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(
                KYTDepositGateway.RequestNotPending.selector, id, KYTDepositGateway.RequestState.EXECUTED
            )
        );
        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));
    }

    function test_fulfill_revertsAfterExpiry() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.warp(NOW + VALIDITY + 1);

        vm.expectRevert(abi.encodeWithSelector(KYTDepositGateway.RequestExpired.selector, id));
        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));
    }

    function test_fulfill_succeedsExactlyAtExpiryBoundary() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.warp(NOW + VALIDITY);
        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));

        assertEq(uint8(gw.getRequest(id).state), uint8(KYTDepositGateway.RequestState.EXECUTED));
    }

    function test_fulfill_revertsOnFutureScreeningTime() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        uint64 future = uint64(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(KYTDepositGateway.InvalidScreeningTime.selector, future));
        vm.prank(oracle);
        gw.fulfill(id, true, future);
    }

    /// @dev A screening performed BEFORE the request is explicitly allowed: screening results
    ///      are commonly cached and reused, and rejecting them would break that flow without
    ///      buying any safety (an oracle willing to submit a stale screening can submit
    ///      `passed = true` outright). Staleness policy belongs to the listener.
    function test_fulfill_acceptsCachedScreeningPredatingRequest() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        uint64 cached = uint64(NOW - 5 minutes);
        vm.prank(oracle);
        gw.fulfill(id, true, cached);

        assertEq(uint8(gw.getRequest(id).state), uint8(KYTDepositGateway.RequestState.EXECUTED));
        assertEq(usdt.balanceOf(address(vault)), 1_000e6);
    }

    // -----------------------------------------------------------------------
    // cancel
    // -----------------------------------------------------------------------

    function test_cancel_byPayer() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.expectEmit(true, true, false, true);
        emit KYTDepositGateway.RequestCancelled(id, alice, block.timestamp);
        vm.prank(alice);
        gw.cancel(id);

        assertEq(uint8(gw.getRequest(id).state), uint8(KYTDepositGateway.RequestState.CANCELLED));
    }

    function test_cancel_revertsForNonPayer() public {
        _prepare(bob, alice, 1_000e6);
        uint256 id = _request(bob, alice, 1_000e6);

        // Not even the owner may cancel — only the recorded payer.
        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(alice);
        gw.cancel(id);

        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(oracle);
        gw.cancel(id);
    }

    function test_cancel_revertsForUnknownRequest() public {
        vm.expectRevert(abi.encodeWithSelector(KYTDepositGateway.RequestNotFound.selector, uint256(99)));
        vm.prank(alice);
        gw.cancel(99);
    }

    function test_cancel_thenFulfilReverts() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.prank(alice);
        gw.cancel(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                KYTDepositGateway.RequestNotPending.selector, id, KYTDepositGateway.RequestState.CANCELLED
            )
        );
        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));
    }

    function test_cancel_cannotBeRepeated() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.prank(alice);
        gw.cancel(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                KYTDepositGateway.RequestNotPending.selector, id, KYTDepositGateway.RequestState.CANCELLED
            )
        );
        vm.prank(alice);
        gw.cancel(id);
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    function test_setOracle_byAdmin() public {
        address newOracle = makeAddr("newOracle");

        vm.expectEmit(true, true, false, true);
        emit KYTDepositGateway.OracleUpdated(oracle, newOracle, block.timestamp);
        vm.prank(gwAdmin);
        gw.setOracle(newOracle);

        assertEq(gw.oracle(), newOracle);

        // The rotated-out oracle loses fulfil rights immediately.
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);
        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));

        vm.prank(newOracle);
        gw.fulfill(id, true, uint64(block.timestamp));
        assertEq(uint8(gw.getRequest(id).state), uint8(KYTDepositGateway.RequestState.EXECUTED));
    }

    function test_setOracle_revertsForNonAdmin() public {
        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(oracle);
        gw.setOracle(alice);

        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(governor);
        gw.setOracle(alice);
    }

    function test_setOracle_revertsOnZeroAddress() public {
        vm.expectRevert(KYTDepositGateway.ZeroAddress.selector);
        vm.prank(gwAdmin);
        gw.setOracle(address(0));
    }

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.expectEmit(true, true, false, true);
        emit KYTDepositGateway.AdminTransferred(gwAdmin, newAdmin, block.timestamp);
        vm.prank(gwAdmin);
        gw.transferAdmin(newAdmin);

        assertEq(gw.admin(), newAdmin);

        // Old admin loses authority, new admin gains it.
        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(gwAdmin);
        gw.setOracle(alice);

        vm.prank(newAdmin);
        gw.setOracle(alice);
        assertEq(gw.oracle(), alice);
    }

    function test_transferAdmin_revertsForNonAdmin() public {
        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(oracle);
        gw.transferAdmin(alice);
    }

    function test_transferAdmin_revertsOnZeroAddress() public {
        vm.expectRevert(KYTDepositGateway.ZeroAddress.selector);
        vm.prank(gwAdmin);
        gw.transferAdmin(address(0));
    }

    function test_setValidityPeriod_byAdmin() public {
        vm.expectEmit(false, false, false, true);
        emit KYTDepositGateway.ValidityPeriodUpdated(VALIDITY, 2 hours, block.timestamp);
        vm.prank(gwAdmin);
        gw.setValidityPeriod(2 hours);

        assertEq(gw.validityPeriod(), 2 hours);
    }

    function test_setValidityPeriod_revertsForNonAdmin() public {
        vm.expectRevert(KYTDepositGateway.Unauthorized.selector);
        vm.prank(oracle);
        gw.setValidityPeriod(2 hours);
    }

    function test_setValidityPeriod_revertsOutOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(KYTDepositGateway.InvalidValidityPeriod.selector, uint64(1 minutes)));
        vm.prank(gwAdmin);
        gw.setValidityPeriod(1 minutes);

        vm.expectRevert(abi.encodeWithSelector(KYTDepositGateway.InvalidValidityPeriod.selector, uint64(8 days)));
        vm.prank(gwAdmin);
        gw.setValidityPeriod(8 days);
    }

    // -----------------------------------------------------------------------
    // End-to-end
    // -----------------------------------------------------------------------

    /// @notice The full spec flow: one approval pair up front, then one call per subscription.
    function test_e2e_repeatSubscriptionsAfterOneTimeSetup() public {
        _prepare(alice, alice, 3_000e6);

        for (uint256 i = 0; i < 3; i++) {
            uint256 id = _request(alice, alice, 1_000e6);
            vm.prank(oracle);
            gw.fulfill(id, true, uint64(block.timestamp));
        }

        assertEq(usdt.balanceOf(address(vault)), 3_000e6);
        assertEq(vault.pendingDepositByOwner(alice), 3_000e6);
        assertEq(usdt.balanceOf(alice), 100_000e6 - 3_000e6);
    }

    /// @notice A rejected payer cannot reach the Vault by any route while the gate is installed.
    function test_e2e_rejectedPayerHasNoPathIntoVault() public {
        _prepare(alice, alice, 1_000e6);
        uint256 id = _request(alice, alice, 1_000e6);

        vm.prank(oracle);
        gw.fulfill(id, false, uint64(block.timestamp));

        // Direct deposit is gated.
        vm.startPrank(alice);
        usdt.approve(address(vault), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.GateBlocked.selector, alice));
        vault.requestDeposit(1_000e6, alice);
        vm.stopPrank();

        // The rejected request cannot be re-fulfilled.
        vm.expectRevert(
            abi.encodeWithSelector(
                KYTDepositGateway.RequestNotPending.selector, id, KYTDepositGateway.RequestState.REJECTED
            )
        );
        vm.prank(oracle);
        gw.fulfill(id, true, uint64(block.timestamp));

        assertEq(usdt.balanceOf(address(vault)), 0);
    }
}
