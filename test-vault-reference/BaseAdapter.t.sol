// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HyperAccessControl} from "../src/governance/HyperAccessControl.sol";
import {StateManager} from "../src/asset-management/StateManager.sol";
import {Queue} from "../src/asset-management/settlement/Queue.sol";
import {EarnVault} from "../src/asset-management/vaults/EarnVault.sol";
import {FirstPeriodAdapter} from "../src/asset-management/adaptors/FirstPeriodAdapter.sol";
import {IAdapter} from "../src/interfaces/IAdapter.sol";
import {ProductState, CycleState, ProductParams, PauseState} from "../src/libs/Types.sol";

/// @dev Stands in for an on-chain investment token this Adapter holds and can sell.
contract MockExitToken is ERC20 {
    constructor() ERC20("Exit", "EXIT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockUSDT is ERC20 {
    constructor() ERC20("MockUSDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BaseAdapterTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    EarnVault internal vault;
    MockUSDT internal usdt;
    FirstPeriodAdapter internal adapter;

    address internal governor = makeAddr("governor");
    address internal vaultOwner = makeAddr("vaultOwner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal guardian = makeAddr("guardian");
    address internal dataProvider = makeAddr("dataProvider");
    address internal vaultAddr;
    address internal destination = makeAddr("destination");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant STALENESS_WINDOW = 36 hours;

    function setUp() public {
        vm.warp(NOW);
        ac = new HyperAccessControl(governor);
        sm = new StateManager(address(ac));
        queue = new Queue(address(sm));
        usdt = new MockUSDT();

        // Vault stays in its default ProductState.CONFIGURING, which is all BaseAdapter's
        // Curator-class setters (setStalenessWindow/setDataProvider) need to allow direct
        // Curator calls. It is registered with `sm` (this contract as VaultFactory) purely so
        // requireActive — now consulted by _onlyCurator/_onlyAllocator — has a StateContext to
        // read; product/cycle state are otherwise unused by BaseAdapter.
        vault = new EarnVault("Test Vault", "tVLT", address(usdt), address(sm), address(queue), vaultOwner, address(0));
        vaultAddr = address(vault);

        vm.prank(governor);
        sm.setVaultFactory(address(this));
        sm.registerVault(vaultAddr);

        vm.startPrank(vaultOwner);
        vault.setCurator(curator);
        vault.setGuardian(guardian);
        vault.setAllocator(allocator);
        vm.stopPrank();

        adapter = new FirstPeriodAdapter(usdt, vaultAddr, STALENESS_WINDOW);

        vm.prank(curator);
        adapter.setDataProvider(dataProvider);

        usdt.mint(vaultAddr, 1_000_000e6);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _fundAdapterViaVaultDeposit(uint256 amount) internal {
        vm.startPrank(vaultAddr);
        usdt.approve(address(adapter), amount);
        adapter.deposit(amount, vaultAddr);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(IAdapter.ZeroAddress.selector);
        new FirstPeriodAdapter(usdt, address(0), STALENESS_WINDOW);
    }

    function test_constructor_defaultStalenessWindow() public view {
        assertEq(adapter.defaultStalenessWindow(), STALENESS_WINDOW);
    }

    // -----------------------------------------------------------------------
    // ERC-4626 deposit
    // -----------------------------------------------------------------------

    function test_vaultDeposit_pullsUsdt_mintsAdapterShares() public {
        uint256 amount = 5_000e6;
        _fundAdapterViaVaultDeposit(amount);
        assertEq(usdt.balanceOf(address(adapter)), amount);
        assertGt(adapter.balanceOf(vaultAddr), 0);
    }

    // -----------------------------------------------------------------------
    // createBuyOrder / executeBuy — TOKEN_RETURN
    // -----------------------------------------------------------------------

    function test_createBuyOrder_onlyCurator() public {
        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotCurator.selector);
        adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
    }

    function test_createBuyOrder_selfDestination_reverts() public {
        vm.prank(curator);
        vm.expectRevert(IAdapter.SelfDestinationNotAllowed.selector);
        adapter.createBuyOrder(1_000e6, address(adapter), IAdapter.SettlementMode.TOKEN_RETURN);
    }

    function test_createBuyOrder_zeroDestination_reverts() public {
        vm.prank(curator);
        vm.expectRevert(IAdapter.ZeroAddress.selector);
        adapter.createBuyOrder(1_000e6, address(0), IAdapter.SettlementMode.TOKEN_RETURN);
    }

    function test_createBuyOrder_externalDestination_succeeds() public {
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);

        (uint256 amount, address dest,,,,) = adapter.buyOrders(orderId);
        assertEq(amount, 1_000e6);
        assertEq(dest, destination);
    }

    function test_createBuyOrder_sequentialIds_recordsFields() public {
        vm.startPrank(curator);
        uint256 id0 = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        uint256 id1 = adapter.createBuyOrder(2_000e6, destination, IAdapter.SettlementMode.VALUE_RETURN);
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        (uint256 amount,,, IAdapter.SettlementMode mode,,) = adapter.buyOrders(id1);
        assertEq(amount, 2_000e6);
        assertEq(uint8(mode), uint8(IAdapter.SettlementMode.VALUE_RETURN));
    }

    function test_executeBuy_happyPath_deploysCapital_andInitializesDealData() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);

        vm.expectEmit(true, false, false, true);
        emit IAdapter.CapitalDeployed(destination, amount, block.timestamp);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        assertEq(usdt.balanceOf(destination), amount);
        (uint256 dealValue, uint256 updatedAt,) = adapter.pendingDeposits(orderId);
        assertEq(dealValue, amount);
        assertEq(updatedAt, block.timestamp);
        assertEq(adapter.realAssets(), amount);
    }

    function test_executeBuy_onlyAllocator() public {
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);

        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotAllocator.selector);
        adapter.executeBuy(orderId);
    }

    function test_executeBuy_unknownOrderId_reverts() public {
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.OrderDoesNotExist.selector, 999));
        adapter.executeBuy(999);
    }

    function test_executeBuy_cancelledOrder_reverts() public {
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(curator);
        adapter.cancelBuyOrder(orderId);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.OrderAlreadyCancelled.selector, orderId));
        adapter.executeBuy(orderId);
    }

    function test_executeBuy_twice_reverts() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.OrderAlreadyExecuted.selector, orderId));
        adapter.executeBuy(orderId);
    }

    function test_executeBuy_selector_takesOnlyOrderId() public pure {
        assertEq(IAdapter.executeBuy.selector, bytes4(keccak256("executeBuy(uint256)")));
    }

    function test_executeSell_selector_takesOnlyOrderId() public pure {
        assertEq(IAdapter.executeSell.selector, bytes4(keccak256("executeSell(uint256)")));
    }

    // -----------------------------------------------------------------------
    // clearDealValue — TOKEN_RETURN
    // -----------------------------------------------------------------------

    function test_clearDealValue_happyPath_zeroesAndRemovesFromLiveDeals() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.prank(allocator);
        adapter.clearDealValue(orderId);

        (uint256 dealValue,,) = adapter.pendingDeposits(orderId);
        assertEq(dealValue, 0);
        assertEq(adapter.realAssets(), 0);
    }

    // clearDealValue is now Allocator-ONLY — the old `_onlyAllocatorOrDataProvider()` path and
    // its `NotAllocatorOrDataProvider` error were removed, so the Data Provider can no longer
    // clear a deal value. Flipped from "byDataProvider_alsoSucceeds" to a revert expectation.
    function test_clearDealValue_byDataProvider_reverts() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.prank(dataProvider);
        vm.expectRevert(IAdapter.NotAllocator.selector);
        adapter.clearDealValue(orderId);
    }

    function test_clearDealValue_nonAuthorized_reverts() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotAllocator.selector);
        adapter.clearDealValue(orderId);
    }

    function test_clearDealValue_onValueReturnOrder_reverts() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.prank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAdapter.WrongSettlementMode.selector,
                orderId,
                uint8(IAdapter.SettlementMode.TOKEN_RETURN),
                uint8(IAdapter.SettlementMode.VALUE_RETURN)
            )
        );
        adapter.clearDealValue(orderId);
    }

    // -----------------------------------------------------------------------
    // updateDealData — VALUE_RETURN
    // -----------------------------------------------------------------------

    function test_updateDealData_happyPath_refreshesPendingDeposits() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(dataProvider);
        adapter.updateDealData(orderId, 1_500e6);

        (uint256 dealValue, uint256 updatedAt,) = adapter.pendingDeposits(orderId);
        assertEq(dealValue, 1_500e6);
        assertEq(updatedAt, block.timestamp);
        assertEq(adapter.realAssets(), 1_500e6);
    }

    function test_updateDealData_onTokenReturnOrder_reverts() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.prank(dataProvider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAdapter.WrongSettlementMode.selector,
                orderId,
                uint8(IAdapter.SettlementMode.VALUE_RETURN),
                uint8(IAdapter.SettlementMode.TOKEN_RETURN)
            )
        );
        adapter.updateDealData(orderId, 2_000e6);
    }

    function test_updateDealData_unexecutedOrder_reverts() public {
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.VALUE_RETURN);

        vm.prank(dataProvider);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.OrderDoesNotExist.selector, orderId));
        adapter.updateDealData(orderId, 2_000e6);
    }

    function test_updateDealData_nonDataProvider_reverts() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotDataProvider.selector);
        adapter.updateDealData(orderId, 2_000e6);
    }

    // -----------------------------------------------------------------------
    // realAssets — staleness + mixed orders
    // -----------------------------------------------------------------------

    function test_realAssets_staleEntry_reverts() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        // VALUE_RETURN: value is knowable only from updateDealData, so staleness still binds.
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.warp(block.timestamp + STALENESS_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IAdapter.StaleAdapterData.selector, NOW, STALENESS_WINDOW));
        adapter.realAssets();
    }

    /// @dev A TOKEN_RETURN deal has no refresh path (`updateDealData`
    ///      rejects it, `clearDealValue` needs the token delivered), so enforcing staleness on it
    ///      bricked `realAssets()` — and with it pricing, settlement and `removeAdapter` — for any
    ///      delivery slower than the window.
    function test_realAssets_staleTokenReturnEntry_doesNotRevert() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.warp(block.timestamp + STALENESS_WINDOW * 10);

        assertEq(adapter.realAssets(), amount);
    }

    function test_realAssets_mixedOrders_sumsOnlyRemainingLive() public {
        uint256 amount = 2_000e6;
        _fundAdapterViaVaultDeposit(amount);

        vm.startPrank(curator);
        uint256 tokenOrder = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        uint256 valueOrder = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.VALUE_RETURN);
        vm.stopPrank();

        vm.startPrank(allocator);
        adapter.executeBuy(tokenOrder);
        adapter.executeBuy(valueOrder);
        adapter.clearDealValue(tokenOrder);
        vm.stopPrank();

        vm.prank(dataProvider);
        adapter.updateDealData(valueOrder, 1_200e6);

        assertEq(adapter.realAssets(), 1_200e6);
    }

    // -----------------------------------------------------------------------
    // setStalenessWindow — Curator-direct while CONFIGURING (Timelock-gated after)
    // -----------------------------------------------------------------------

    function test_setStalenessWindow_onlyCurator() public {
        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotCurator.selector);
        adapter.setStalenessWindow(1 hours);

        vm.prank(curator);
        adapter.setStalenessWindow(1 hours);
        assertEq(adapter.defaultStalenessWindow(), 1 hours);
    }

    // -----------------------------------------------------------------------
    // cancel*
    // -----------------------------------------------------------------------

    function test_cancelBuyOrder_byCuratorOrGuardian() public {
        vm.prank(curator);
        uint256 orderId1 = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(curator);
        adapter.cancelBuyOrder(orderId1);

        vm.prank(curator);
        uint256 orderId2 = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(guardian);
        adapter.cancelBuyOrder(orderId2);
    }

    function test_cancelBuyOrder_nonAuthorized_reverts() public {
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);

        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotCuratorOrGuardian.selector);
        adapter.cancelBuyOrder(orderId);
    }

    function test_cancelBuyOrder_alreadyExecuted_reverts() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.OrderAlreadyExecuted.selector, orderId));
        adapter.cancelBuyOrder(orderId);
    }

    function test_cancelBuyOrder_alreadyCancelled_reverts() public {
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(curator);
        adapter.cancelBuyOrder(orderId);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.OrderAlreadyCancelled.selector, orderId));
        adapter.cancelBuyOrder(orderId);
    }

    // -----------------------------------------------------------------------
    // freezeAllocator / unfreezeAllocator (GUARDIAN_ROLE emergency freeze;
    // unfreezeAllocator is now Curator-gated, not Governor-gated)
    // -----------------------------------------------------------------------

    function test_freezeAllocator_onlyGuardian() public {
        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotGuardian.selector);
        adapter.freezeAllocator();
    }

    function test_freezeAllocator_setsFlagAndEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IAdapter.AllocatorFrozen(guardian, block.timestamp);
        vm.prank(guardian);
        adapter.freezeAllocator();

        assertTrue(adapter.allocatorFrozen());
    }

    function test_frozen_executeBuy_reverts() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);

        vm.prank(guardian);
        adapter.freezeAllocator();

        vm.prank(allocator);
        vm.expectRevert(IAdapter.AllocatorIsFrozen.selector);
        adapter.executeBuy(orderId);
    }

    function test_frozen_curatorCanStillCreateAndCancelOrders() public {
        vm.prank(guardian);
        adapter.freezeAllocator();

        vm.startPrank(curator);
        uint256 orderId = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        adapter.cancelBuyOrder(orderId);
        vm.stopPrank();
    }

    function test_unfreezeAllocator_onlyCurator() public {
        vm.prank(guardian);
        adapter.freezeAllocator();

        vm.prank(guardian);
        vm.expectRevert(IAdapter.NotCurator.selector);
        adapter.unfreezeAllocator();
    }

    // -----------------------------------------------------------------------
    // createSellOrder / cancelSellOrder
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // setDataProvider — Curator-class, direct while the Vault is CONFIGURING
    // -----------------------------------------------------------------------

    function test_setDataProvider_onlyCurator() public {
        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotCurator.selector);
        adapter.setDataProvider(attacker);
    }

    function test_setDataProvider_emitsEventAndRebinds() public {
        address newProvider = makeAddr("newProvider");
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IAdapter.DataProviderSet(newProvider, block.timestamp);
        vm.prank(curator);
        adapter.setDataProvider(newProvider);

        assertEq(adapter.dataProvider(), newProvider);

        // The previous provider loses the ability to write deal data.
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.prank(dataProvider); // the old one
        vm.expectRevert(IAdapter.NotDataProvider.selector);
        adapter.updateDealData(orderId, 1);

        vm.prank(newProvider);
        adapter.updateDealData(orderId, 1_500e6);
        assertEq(adapter.realAssets(), 1_500e6);
    }

    /// @dev Once the Vault leaves CONFIGURING these Curator-class setters are VaultTimelock-only.
    ///      Everything above runs against an unregistered Vault (permanently CONFIGURING), so this
    ///      is the only place the `else` branch of `_onlyCuratorDirectOrTimelock` is reached.
    function test_curatorClassSetters_areTimelockOnlyOnceOutOfConfiguring() public {
        (FirstPeriodAdapter liveAdapter, address liveTimelock, address liveCurator) = _adapterOnALiveVault();

        vm.prank(liveCurator);
        vm.expectRevert(IAdapter.NotCurator.selector);
        liveAdapter.setStalenessWindow(1 hours);

        vm.prank(liveCurator);
        vm.expectRevert(IAdapter.NotCurator.selector);
        liveAdapter.setDataProvider(makeAddr("dp"));

        // The Timelock is the only accepted caller now.
        vm.prank(liveTimelock);
        liveAdapter.setStalenessWindow(1 hours);
        assertEq(liveAdapter.defaultStalenessWindow(), 1 hours);

        vm.prank(liveTimelock);
        liveAdapter.setDataProvider(makeAddr("dp"));
        assertEq(liveAdapter.dataProvider(), makeAddr("dp"));
    }

    /// @dev Builds a Vault that is registered with StateManager and pushed past CONFIGURING, plus
    ///      an Adapter bound to it. `vaultTimelock` is a plain address so the test can prank it.
    function _adapterOnALiveVault()
        internal
        returns (FirstPeriodAdapter liveAdapter, address liveTimelock, address liveCurator)
    {
        liveTimelock = makeAddr("liveTimelock");
        liveCurator = makeAddr("liveCurator");
        address liveOwner = makeAddr("liveOwner");
        address liveKeeper = makeAddr("liveKeeper");

        // VaultFactory is already wired to this contract in setUp.
        EarnVault liveVault =
            new EarnVault("Live", "LIVE", address(usdt), address(sm), address(queue), liveOwner, address(0));
        liveVault.bindGovernance(liveTimelock);
        sm.registerVault(address(liveVault));

        vm.startPrank(liveOwner);
        liveVault.setCurator(liveCurator);
        liveVault.setKeeper(liveKeeper, true);
        vm.stopPrank();

        ProductParams memory p;
        p.subscriptionStart = block.timestamp;
        p.subscriptionEnd = block.timestamp + 7 days;
        p.cycleDuration = 7 days;
        p.maturityTimestamp = block.timestamp + 365 days;
        p.claimingStart = block.timestamp + 370 days;
        p.claimingEnd = block.timestamp + 400 days;
        vm.prank(liveCurator);
        sm.setProductParams(address(liveVault), p);

        vm.prank(liveKeeper);
        sm.openSubscription(address(liveVault)); // CONFIGURING -> SUBSCRIBING

        liveAdapter = new FirstPeriodAdapter(usdt, address(liveVault), STALENESS_WINDOW);
    }

    function test_unfreezeAllocator_restoresExecution() public {
        uint256 amount = 1_000e6;
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);

        vm.prank(guardian);
        adapter.freezeAllocator();

        vm.expectEmit(true, false, false, true);
        emit IAdapter.AllocatorUnfrozen(curator, block.timestamp);
        vm.prank(curator);
        adapter.unfreezeAllocator();

        assertFalse(adapter.allocatorFrozen());

        vm.prank(allocator);
        adapter.executeBuy(orderId);
        assertEq(usdt.balanceOf(destination), amount);
    }

    // -----------------------------------------------------------------------
    // Guardian pause blocks Adapter order creation/execution
    // -----------------------------------------------------------------------

    function test_pausedVault_blocksOrderCreationAndExecution() public {
        address token = _withExitToken(1_000e18);
        uint256 existingSellOrderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(existingSellOrderId, 1_000e6);

        vm.prank(guardian);
        sm.pause(vaultAddr, PauseState.PAUSED_BY_GUARDIAN);

        vm.prank(curator);
        vm.expectRevert();
        adapter.createSellOrder(token, 100e18, 100e6, payer, assetRecipient, 0, false, 0, block.timestamp + 1 days);

        vm.prank(allocator);
        vm.expectRevert();
        adapter.executeSell(existingSellOrderId);
    }

    function test_pausedVault_stillAllowsCancelAndFreeze() public {
        address token = _withExitToken(1_000e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);

        vm.prank(guardian);
        sm.pause(vaultAddr, PauseState.PAUSED_BY_GUARDIAN);

        // Cancellation goes through _onlyCuratorOrGuardian, which stays available while paused
        // — cancelling an unexecuted order during an incident reduces exposure.
        vm.prank(curator);
        adapter.cancelSellOrder(orderId);

        // Guardian freezing the Allocator must also stay available.
        vm.prank(guardian);
        adapter.freezeAllocator();
    }

    function test_pausedVault_blocksUnfreezeAllocator() public {
        vm.prank(guardian);
        adapter.freezeAllocator();

        vm.prank(guardian);
        sm.pause(vaultAddr, PauseState.PAUSED_BY_GUARDIAN);

        // unfreezeAllocator goes through _onlyCurator, so it is blocked along with order
        // creation — the Allocator should not come back online while paused.
        vm.prank(curator);
        vm.expectRevert();
        adapter.unfreezeAllocator();
    }

    // -----------------------------------------------------------------------
    // Generic Sell Order
    //
    // The order this replaces never sold anything: it pulled USDT out of the Allocator's own
    // wallet, so a human role sat in the custody path and had to hold and approve the money;
    // it recorded neither what was exited nor from which position, so `dealValue` never fell and
    // the returned cash could be counted on top of the original valuation. Every test below
    // pins one of the properties that fixes.
    // -----------------------------------------------------------------------

    MockExitToken internal exitToken;
    address internal payer = makeAddr("payer");
    address internal assetRecipient = makeAddr("assetRecipient");

    /// @dev Gives the Adapter a sellable token position and allows it as an exit asset.
    function _withExitToken(uint256 amount) internal returns (address token) {
        if (address(exitToken) == address(0)) exitToken = new MockExitToken();
        token = address(exitToken);
        exitToken.mint(address(adapter), amount);
        vm.prank(curator);
        adapter.setExitableAsset(token, true);
    }

    /// @dev An executed TOKEN_RETURN buy, so there is a live Deal to unwind.
    function _liveDeal(uint256 amount) internal returns (uint256 dealKey) {
        _fundAdapterViaVaultDeposit(amount);
        vm.prank(curator);
        dealKey = adapter.createBuyOrder(amount, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(dealKey);
    }

    function _createSell(
        address token,
        uint256 exitAmount,
        uint256 proceeds,
        uint256 dealKey,
        bool hasDeal,
        uint256 reduction
    ) internal returns (uint256 orderId) {
        vm.prank(curator);
        orderId = adapter.createSellOrder(
            token, exitAmount, proceeds, payer, assetRecipient, dealKey, hasDeal, reduction, block.timestamp + 7 days
        );
    }

    function _fund(uint256 orderId, uint256 proceeds) internal {
        usdt.mint(payer, proceeds);
        vm.startPrank(payer);
        usdt.approve(address(adapter), proceeds);
        adapter.fundSellOrder(orderId);
        vm.stopPrank();
    }

    /// @notice The whole point: the counterparty pays the Adapter, the Allocator never touches the
    ///         money, and delivery happens only after the payment has landed.
    function test_sellOrder_counterpartyPaysAdapterDirectly_allocatorNeverHoldsProceeds() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(orderId, 1_000e6);

        assertEq(usdt.balanceOf(address(adapter)), 1_000e6, "proceeds are in the Adapter, not a wallet");
        assertEq(usdt.balanceOf(allocator), 0, "the Allocator is not in the custody path at all");

        vm.prank(allocator);
        adapter.executeSell(orderId);

        assertEq(exitToken.balanceOf(assetRecipient), 500e18, "exit asset delivered");
        assertEq(exitToken.balanceOf(address(adapter)), 0);
        assertEq(usdt.balanceOf(address(adapter)), 1_000e6, "proceeds stay as Adapter working capital");
    }

    function test_executeSell_beforePayment_reverts() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);

        vm.prank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAdapter.WrongSellOrderStatus.selector,
                orderId,
                uint8(IAdapter.SellOrderStatus.FUNDED),
                uint8(IAdapter.SellOrderStatus.CREATED)
            )
        );
        adapter.executeSell(orderId);
    }

    function test_fundSellOrder_onlyDeclaredPayer() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);

        usdt.mint(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdt.approve(address(adapter), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.NotOrderPayer.selector, orderId));
        adapter.fundSellOrder(orderId);
        vm.stopPrank();
    }

    /// @notice Exiting a Deal-priced position writes the deal down in the same call that delivers,
    ///         so the proceeds and the original valuation are never both counted.
    function test_executeSell_reducesDealValue_noDoubleCounting() public {
        uint256 dealKey = _liveDeal(1_000e6);
        assertEq(adapter.realAssets(), 1_000e6, "deal value only; the cash has left");

        uint256 orderId = _createSell(address(0), 0, 900e6, dealKey, true, 1_000e6);
        _fund(orderId, 900e6);

        // While FUNDED the Adapter holds both the position and the payment for it. Counting both
        // would value the same thing twice, so the locked proceeds stay out of realAssets().
        assertEq(adapter.realAssets(), 1_000e6, "locked proceeds are not counted yet");
        assertEq(adapter.lockedProceeds(), 900e6);

        vm.prank(allocator);
        adapter.executeSell(orderId);

        // Deal closed at 1_000e6 of book value, sold for 900e6 — the 100e6 shortfall is the loss,
        // and it shows up exactly once.
        assertEq(adapter.lockedProceeds(), 0);
        assertEq(adapter.realAssets(), 900e6, "position retired, proceeds now count");
    }

    function test_createSellOrder_rejectsReductionBeyondRemainingDealValue() public {
        uint256 dealKey = _liveDeal(1_000e6);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.InsufficientDealValue.selector, dealKey, 1_500e6, 1_000e6));
        adapter.createSellOrder(
            address(0), 0, 900e6, payer, assetRecipient, dealKey, true, 1_500e6, block.timestamp + 1 days
        );
    }

    /// @notice Two orders cannot promise the same Deal, so it can never be exited twice.
    function test_createSellOrder_dealReservationBlocksASecondFullExit() public {
        uint256 dealKey = _liveDeal(1_000e6);
        _createSell(address(0), 0, 900e6, dealKey, true, 1_000e6);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.InsufficientDealValue.selector, dealKey, 1, 0));
        adapter.createSellOrder(address(0), 0, 1, payer, assetRecipient, dealKey, true, 1, block.timestamp + 1 days);
    }

    /// @notice And cannot promise the same tokens — otherwise a funded order could find its asset
    ///         already gone when the Allocator came to deliver it.
    function test_createSellOrder_tokenReservationBlocksOverselling() public {
        address token = _withExitToken(500e18);
        _createSell(token, 400e18, 800e6, 0, false, 0);

        assertEq(adapter.reservedExitAmount(token), 400e18);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.InsufficientExitAsset.selector, token, 200e18, 100e18));
        adapter.createSellOrder(token, 200e18, 400e6, payer, assetRecipient, 0, false, 0, block.timestamp + 1 days);
    }

    function test_cancelSellOrder_releasesReservations() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 400e18, 800e6, 0, false, 0);

        vm.prank(curator);
        adapter.cancelSellOrder(orderId);

        assertEq(adapter.reservedExitAmount(token), 0, "reservation freed for the next order");
        _createSell(token, 500e18, 1_000e6, 0, false, 0);
    }

    /// @notice A paid order can never be cancelled while keeping the counterparty's money.
    function test_cancelSellOrder_whenFunded_refundsThePayer() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(orderId, 1_000e6);

        vm.prank(guardian);
        adapter.cancelSellOrder(orderId);

        assertEq(usdt.balanceOf(payer), 1_000e6, "money went back to whoever paid it");
        assertEq(adapter.lockedProceeds(), 0);
        assertEq(adapter.reservedExitAmount(token), 0);
        assertEq(exitToken.balanceOf(address(adapter)), 500e18, "nothing was delivered");
    }

    /// @notice A counterparty who paid must be able to get their money back without depending on
    ///         the party that failed to deliver.
    function test_refundSellOrder_afterExpiry_byPayerAlone() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(orderId, 1_000e6);

        vm.warp(block.timestamp + 8 days);

        vm.prank(payer);
        adapter.refundSellOrder(orderId);

        assertEq(usdt.balanceOf(payer), 1_000e6);
        assertEq(adapter.lockedProceeds(), 0);
    }

    function test_refundSellOrder_beforeExpiry_reverts() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(orderId, 1_000e6);
        uint256 expiry = block.timestamp + 7 days;

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.SellOrderNotExpired.selector, orderId, expiry));
        adapter.refundSellOrder(orderId);
    }

    function test_executeSell_afterExpiry_reverts() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(orderId, 1_000e6);
        uint256 expiry = block.timestamp + 7 days;

        vm.warp(expiry + 1);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.SellOrderExpired.selector, orderId, expiry));
        adapter.executeSell(orderId);
    }

    /// @notice Refunds and risk-reducing cancels must still work while the Vault is paused —
    ///         a halt must not trap a counterparty's payment.
    function test_pausedVault_stillAllowsSellRefundAndCancel() public {
        address token = _withExitToken(500e18);
        uint256 cancelId = _createSell(token, 250e18, 500e6, 0, false, 0);
        uint256 refundId = _createSell(token, 250e18, 500e6, 0, false, 0);
        _fund(refundId, 500e6);

        vm.warp(block.timestamp + 8 days);
        vm.prank(guardian);
        sm.pause(vaultAddr, PauseState.PAUSED_BY_GUARDIAN);

        vm.prank(guardian);
        adapter.cancelSellOrder(cancelId);

        vm.prank(payer);
        adapter.refundSellOrder(refundId);

        assertEq(usdt.balanceOf(payer), 500e6);
        assertEq(adapter.reservedExitAmount(token), 0);
    }

    function test_frozenAllocator_blocksExecuteSell() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(orderId, 1_000e6);

        vm.prank(guardian);
        adapter.freezeAllocator();

        vm.prank(allocator);
        vm.expectRevert(IAdapter.AllocatorIsFrozen.selector);
        adapter.executeSell(orderId);
    }

    function test_createSellOrder_onlyCurator() public {
        address token = _withExitToken(500e18);
        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotCurator.selector);
        adapter.createSellOrder(token, 1, 1, payer, assetRecipient, 0, false, 0, block.timestamp + 1 days);
    }

    function test_executeSell_onlyAllocator() public {
        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(orderId, 1_000e6);

        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotAllocator.selector);
        adapter.executeSell(orderId);
    }

    function test_createSellOrder_expiryInThePast_reverts() public {
        address token = _withExitToken(500e18);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.ExpiryNotInFuture.selector, block.timestamp));
        adapter.createSellOrder(token, 1e18, 1e6, payer, assetRecipient, 0, false, 0, block.timestamp);
    }

    /// @notice An order that neither hands over a token nor retires a deal exits nothing, yet
    ///         would still take a counterparty's money.
    function test_createSellOrder_neitherTokenNorDeal_reverts() public {
        vm.prank(curator);
        vm.expectRevert(IAdapter.ZeroAmount.selector);
        adapter.createSellOrder(address(0), 0, 1_000e6, payer, assetRecipient, 0, false, 0, block.timestamp + 1 days);
    }

    /// @notice The rule that keeps a Sell Order from becoming a way to walk an arbitrary token
    ///         out of an Adapter: nothing is sellable until the Curator says so.
    function test_createSellOrder_unlistedToken_reverts() public {
        MockExitToken stranger = new MockExitToken();
        stranger.mint(address(adapter), 1_000e18);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.ExitAssetNotSupported.selector, address(stranger)));
        adapter.createSellOrder(
            address(stranger), 1e18, 1e6, payer, assetRecipient, 0, false, 0, block.timestamp + 1 days
        );
    }

    /// @notice `asset()` is the proceeds currency and the Vault's own capital — letting it out
    ///         through an exit would be an unauthorised transfer wearing a Sell Order's clothes.
    function test_setExitableAsset_cannotListTheAccountingAsset() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.ExitAssetNotSupported.selector, address(usdt)));
        adapter.setExitableAsset(address(usdt), true);
    }

    function test_setExitableAsset_onlyCurator() public {
        MockExitToken token = new MockExitToken();
        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotCurator.selector);
        adapter.setExitableAsset(address(token), true);
    }

    /// @notice Locked proceeds must not be recallable to the Vault before the exit has happened --
    ///         that money is the counterparty's until delivery.
    /// @dev    The live deal is what makes this bite: it keeps the Adapter's share value at
    ///         1_500e6 while its spendable cash is only 500e6, so the withdrawal clears the
    ///         inherited `maxWithdraw` ceiling and still has to be stopped on liquidity grounds.
    function test_recall_cannotTakeLockedProceeds() public {
        _fundAdapterViaVaultDeposit(1_500e6);
        vm.prank(curator);
        uint256 buyId = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(buyId);

        address token = _withExitToken(500e18);
        uint256 orderId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(orderId, 1_000e6);

        // 1_500e6 of USDT sits here, but 1_000e6 of it belongs to the counterparty.
        assertEq(usdt.balanceOf(address(adapter)), 1_500e6);
        assertEq(adapter.realAssets(), 1_500e6, "500e6 free cash + the 1_000e6 deal");

        vm.prank(vaultAddr);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.ProceedsLocked.selector, 600e6, 500e6));
        adapter.withdraw(600e6, vaultAddr, vaultAddr);

        vm.prank(vaultAddr);
        adapter.withdraw(500e6, vaultAddr, vaultAddr);

        // After delivery the proceeds are ordinary Adapter capital and can be recalled.
        vm.prank(allocator);
        adapter.executeSell(orderId);
        vm.prank(vaultAddr);
        adapter.withdraw(1_000e6, vaultAddr, vaultAddr);
        assertEq(usdt.balanceOf(address(adapter)), 0);
    }

    /// @notice Rebalancing is now Sell-then-Buy inside one Adapter, with the old position actually
    ///         retired — the thing the deleted Rebalance order never did.
    function test_rebalanceViaSellThenBuy_retiresOldDealAndOpensNew() public {
        uint256 oldDeal = _liveDeal(1_000e6);

        uint256 sellId = _createSell(address(0), 0, 1_000e6, oldDeal, true, 1_000e6);
        _fund(sellId, 1_000e6);
        vm.prank(allocator);
        adapter.executeSell(sellId);

        address newTarget = makeAddr("newTarget");
        vm.prank(curator);
        uint256 buyId = adapter.createBuyOrder(1_000e6, newTarget, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(buyId);

        assertEq(usdt.balanceOf(newTarget), 1_000e6, "proceeds redeployed without leaving the Adapter first");
        assertEq(adapter.realAssets(), 1_000e6, "one position, not two -- the old deal is gone");
        (uint256 oldValue,,) = adapter.pendingDeposits(oldDeal);
        assertEq(oldValue, 0);
    }

    // -----------------------------------------------------------------------
    // The ERC-4626 surface is the Vault's capital line, not a public product
    // -----------------------------------------------------------------------

    /// @dev Left open, the four entry points priced off `realAssets()` let an outsider mint before
    ///      a deal is marked up and redeem after, taking value that belongs to the Vault's own
    ///      depositors. Worse, `BaseVault.removeAdapter` requires `realAssets() == 0`, so a single
    ///      un-redeemed outside share would freeze the Vault's wind-down permanently.
    function test_erc4626_entryPoints_rejectEveryoneButTheVault() public {
        usdt.mint(attacker, 1_000e6);

        vm.startPrank(attacker);
        usdt.approve(address(adapter), 1_000e6);

        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.deposit(1_000e6, attacker);

        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.mint(1_000e6, attacker);

        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.withdraw(1, attacker, attacker);

        vm.expectRevert(IAdapter.NotVault.selector);
        adapter.redeem(1, attacker, attacker);
        vm.stopPrank();

        assertEq(adapter.balanceOf(attacker), 0);
        assertEq(adapter.totalSupply(), 0, "no outside share may exist to block removeAdapter");
    }

    /// @dev The counterpart: closing the surface must not close the Vault's own line into it.
    function test_erc4626_entryPoints_stillOpenToTheVault() public {
        _fundAdapterViaVaultDeposit(1_000e6);
        assertEq(usdt.balanceOf(address(adapter)), 1_000e6);

        uint256 shares = adapter.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        adapter.redeem(shares, vaultAddr, vaultAddr);

        assertEq(adapter.balanceOf(vaultAddr), 0);
        assertEq(adapter.realAssets(), 0, "wind-down is reachable again");
    }

    // -----------------------------------------------------------------------
    // executeBuy may not spend escrowed counterparty money
    // -----------------------------------------------------------------------

    /// @dev While a Sell Order sits FUNDED the Adapter holds both the position being sold and the
    ///      buyer's payment for it. Deploying that payment on a Buy Order double-counts it and
    ///      breaks the "paid before delivered" custody promise the counterparty funded against.
    function test_executeBuy_cannotDeployEscrowedSellProceeds() public {
        address token = _withExitToken(500e18);
        uint256 sellId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(sellId, 1_000e6);

        // Every USDT the Adapter holds is the buyer's.
        assertEq(usdt.balanceOf(address(adapter)), 1_000e6);
        assertEq(adapter.lockedProceeds(), 1_000e6);

        vm.prank(curator);
        uint256 buyId = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.ProceedsLocked.selector, 1_000e6, 0));
        adapter.executeBuy(buyId);

        assertEq(usdt.balanceOf(destination), 0, "not one unit of the buyer's money left");
    }

    /// @dev The ceiling is the free balance, not the whole balance: free capital deploys normally
    ///      alongside escrowed proceeds, and only the overshoot is rejected.
    function test_executeBuy_ceilingIsFreeBalanceNotWholeBalance() public {
        _fundAdapterViaVaultDeposit(400e6);
        address token = _withExitToken(500e18);
        uint256 sellId = _createSell(token, 500e18, 1_000e6, 0, false, 0);
        _fund(sellId, 1_000e6);

        assertEq(usdt.balanceOf(address(adapter)), 1_400e6);
        assertEq(adapter.lockedProceeds(), 1_000e6);

        // One unit past the free 400e6 is refused...
        vm.prank(curator);
        uint256 tooBig = adapter.createBuyOrder(400e6 + 1, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.ProceedsLocked.selector, 400e6 + 1, 400e6));
        adapter.executeBuy(tooBig);

        // ...and the free balance itself goes through.
        vm.prank(curator);
        uint256 ok = adapter.createBuyOrder(400e6, destination, IAdapter.SettlementMode.TOKEN_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(ok);

        assertEq(usdt.balanceOf(destination), 400e6);
        assertEq(usdt.balanceOf(address(adapter)), 1_000e6, "the escrow is untouched");
    }

    // -----------------------------------------------------------------------
    // A funded Sell Order must never be stranded by a deal revaluation
    // -----------------------------------------------------------------------

    /// @dev `clearDealValue` retires the deal outright; the position is priced off its delivered
    ///      token balance from then on, so there is nothing left for the Sell Order to write off.
    ///      A checked subtraction in `executeSell` would underflow here and leave a counterparty
    ///      who has already paid with no exit but expiry and refund.
    function test_executeSell_survivesTheDealBeingRetiredFirst() public {
        uint256 dealKey = _liveDeal(1_000e6);
        address token = _withExitToken(500e18);
        uint256 sellId = _createSell(token, 500e18, 900e6, dealKey, true, 1_000e6);
        _fund(sellId, 900e6);

        // The Data Provider's TOKEN_RETURN delivery lands and the deal is retired mid-flight.
        vm.prank(allocator);
        adapter.clearDealValue(dealKey);
        (uint256 clearedValue,,) = adapter.pendingDeposits(dealKey);
        assertEq(clearedValue, 0);

        vm.prank(allocator);
        adapter.executeSell(sellId); // must not underflow

        assertEq(uint8(_sellStatus(sellId)), uint8(IAdapter.SellOrderStatus.EXECUTED));
        assertEq(exitToken.balanceOf(assetRecipient), 500e18, "the counterparty got what it paid for");
        assertEq(adapter.lockedProceeds(), 0);
    }

    /// @dev The other writer is guarded at source instead. A live Sell Order has already quoted a
    ///      price to its counterparty; revaluing the deal underneath it would either strand the
    ///      order or let it settle at the stale price and push the markdown onto the Vault.
    function test_updateDealData_cannotRevalueBelowAReservedSellOrder() public {
        _fundAdapterViaVaultDeposit(1_000e6);
        vm.prank(curator);
        uint256 dealKey = adapter.createBuyOrder(1_000e6, destination, IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(dealKey);

        // A Sell Order promises to write off 600e6 of this deal.
        uint256 sellId = _createSell(address(0), 0, 550e6, dealKey, true, 600e6);
        _fund(sellId, 550e6);
        assertEq(adapter.reservedDealValue(dealKey), 600e6);

        vm.prank(dataProvider);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.DealValueBelowReserved.selector, dealKey, 400e6, 600e6));
        adapter.updateDealData(dealKey, 400e6);

        // Down to the reservation is fine, and so is up.
        vm.startPrank(dataProvider);
        adapter.updateDealData(dealKey, 600e6);
        adapter.updateDealData(dealKey, 1_200e6);
        vm.stopPrank();

        // Retiring the order releases the reservation and the guard with it.
        vm.prank(curator);
        adapter.cancelSellOrder(sellId);
        assertEq(adapter.reservedDealValue(dealKey), 0);
        vm.prank(dataProvider);
        adapter.updateDealData(dealKey, 1);
    }

    function _sellStatus(uint256 orderId) internal view returns (IAdapter.SellOrderStatus status) {
        (,,,,,,,,, status) = adapter.sellOrders(orderId);
    }
}
