// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HyperAccessControl} from "../src/governance/HyperAccessControl.sol";
import {StateManager} from "../src/asset-management/StateManager.sol";
import {Queue} from "../src/asset-management/settlement/Queue.sol";
import {EarnVault} from "../src/asset-management/vaults/EarnVault.sol";
import {LiquidityBridge} from "../src/asset-management/vaults/LiquidityBridge.sol";
import {LiquidityEarnVault} from "../src/asset-management/vaults/LiquidityEarnVault.sol";
import {LiquidityAdapter} from "../src/asset-management/adaptors/LiquidityAdapter.sol";
import {ILiquidityAdapter} from "../src/interfaces/ILiquidityAdapter.sol";
import {IAdapter} from "../src/interfaces/IAdapter.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {ProductState, CycleState} from "../src/libs/Types.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("MockUSDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LiquidityAdapterTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    MockUSDT internal usdt;
    LiquidityBridge internal bridge;
    EarnVault internal cashVault;
    LiquidityEarnVault internal lpVaultContract;
    LiquidityAdapter internal adapter;

    address internal governor = makeAddr("governor");
    address internal cashVaultOwner = makeAddr("cashVaultOwner");
    address internal lpVaultOwner = makeAddr("lpVaultOwner");
    address internal curator = makeAddr("curator");
    address internal lpVault; // = address(lpVaultContract) — the LiquidityAdapter's bound vault
    address internal attacker = makeAddr("attacker");

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant STALENESS_WINDOW = 36 hours;

    function setUp() public {
        vm.warp(NOW);

        ac = new HyperAccessControl(governor);
        sm = new StateManager(address(ac));
        usdt = new MockUSDT();
        queue = new Queue(address(sm));
        bridge = new LiquidityBridge(address(usdt), address(sm), address(ac));

        cashVault = new EarnVault(
            "Cash Earn", "htCASH", address(usdt), address(sm), address(queue), cashVaultOwner, address(bridge)
        );
        // registerVault is now gated to the one-time-wired VaultFactory, not directly to Governor.
        vm.prank(governor);
        sm.setVaultFactory(governor);
        vm.prank(governor);
        sm.registerVault(address(cashVault));

        // The LP vault this adapter serves must itself implement IVaultRoles (curator/allocator/
        // stateManager/etc.) — a plain mock address no longer works since BaseAdapter's role
        // checks now read directly from `vault`. Use a real LiquidityEarnVault, kept in
        // ProductState.CONFIGURING so Curator-class setters (setBridgeTarget) can still be
        // called directly, but registered with `sm` so requireActive — now consulted by
        // _onlyCurator/_onlyAllocator — has a StateContext to read.
        lpVaultContract = new LiquidityEarnVault(
            "LP Earn",
            "htLP",
            address(usdt),
            address(sm),
            address(queue),
            lpVaultOwner,
            address(bridge),
            address(cashVault)
        );
        lpVault = address(lpVaultContract);
        vm.prank(governor);
        sm.registerVault(lpVault);

        vm.prank(lpVaultOwner);
        lpVaultContract.setCurator(curator);

        adapter = new LiquidityAdapter(usdt, lpVault, STALENESS_WINDOW);

        usdt.mint(lpVault, 1_000_000e6);
    }

    // -----------------------------------------------------------------------
    // setBridgeTarget
    // -----------------------------------------------------------------------

    function test_setBridgeTarget_onlyCurator() public {
        vm.prank(attacker);
        vm.expectRevert(IAdapter.NotCurator.selector);
        adapter.setBridgeTarget(address(bridge), address(cashVault));
    }

    function test_setBridgeTarget_happyPath() public {
        vm.expectEmit(false, false, false, true);
        emit ILiquidityAdapter.BridgeTargetSet(address(bridge), address(cashVault), block.timestamp);
        vm.prank(curator);
        adapter.setBridgeTarget(address(bridge), address(cashVault));

        assertEq(adapter.liquidityBridge(), address(bridge));
        assertEq(adapter.cashVault(), address(cashVault));
    }

    // setBridgeTarget now validates its params: ZeroAddress on either arg, and InvalidCashVault
    // if newCashVault isn't registered in this vault's StateManager. New coverage below.
    function test_setBridgeTarget_zeroLiquidityBridge_reverts() public {
        vm.prank(curator);
        vm.expectRevert(IAdapter.ZeroAddress.selector);
        adapter.setBridgeTarget(address(0), address(cashVault));
    }

    function test_setBridgeTarget_zeroCashVault_reverts() public {
        vm.prank(curator);
        vm.expectRevert(IAdapter.ZeroAddress.selector);
        adapter.setBridgeTarget(address(bridge), address(0));
    }

    function test_setBridgeTarget_unregisteredCashVault_reverts() public {
        address unregisteredCashVault = makeAddr("unregisteredCashVault");
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityAdapter.InvalidCashVault.selector, unregisteredCashVault));
        adapter.setBridgeTarget(address(bridge), unregisteredCashVault);
    }

    // -----------------------------------------------------------------------
    // realAssets
    // -----------------------------------------------------------------------

    function test_realAssets_rwaOrder() public {
        // Fund the adapter for an RWA buy order via the inherited ERC-4626 deposit path.
        address allocator = makeAddr("allocator");
        address dest = makeAddr("dest");
        vm.prank(lpVaultOwner);
        lpVaultContract.setAllocator(allocator);

        usdt.mint(lpVault, 500e6);
        vm.startPrank(lpVault);
        usdt.approve(address(adapter), 500e6);
        adapter.deposit(500e6, lpVault);
        vm.stopPrank();

        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(500e6, dest, IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        assertEq(adapter.realAssets(), 500e6);
    }

    function test_realAssets_staleRwaOrder_reverts() public {
        address allocator = makeAddr("allocator");
        address dest = makeAddr("dest");
        vm.prank(lpVaultOwner);
        lpVaultContract.setAllocator(allocator);

        usdt.mint(lpVault, 500e6);
        vm.startPrank(lpVault);
        usdt.approve(address(adapter), 500e6);
        adapter.deposit(500e6, lpVault);
        vm.stopPrank();

        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(500e6, dest, IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        vm.warp(block.timestamp + STALENESS_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IAdapter.StaleAdapterData.selector, NOW, STALENESS_WINDOW));
        adapter.realAssets();
    }

    // -----------------------------------------------------------------------
    // LiquidityEarnVault.adapter wiring — setAdapter is now Curator-gated (direct while
    // CONFIGURING) via the inherited addAdapter(), not Governor-gated.
    // -----------------------------------------------------------------------

    function test_liquidityEarnVault_setAdapter_onlyCurator_andOnce() public {
        address otherOwner = makeAddr("otherLpVaultOwner");
        LiquidityEarnVault lpEarnVault = new LiquidityEarnVault(
            "LP Earn",
            "htLP",
            address(usdt),
            address(sm),
            address(queue),
            otherOwner,
            address(bridge),
            address(cashVault)
        );

        address otherCurator = makeAddr("otherCurator");
        vm.prank(otherOwner);
        lpEarnVault.setCurator(otherCurator);

        address vaultTimelockStandIn = makeAddr("vaultTimelockStandIn");
        vm.prank(governor); // the VaultFactory wired into StateManager in setUp
        lpEarnVault.bindGovernance(vaultTimelockStandIn);

        // addAdapter() requires the adapter be bound to the calling vault — the shared
        // `adapter` fixture is bound to `lpVault`, so this test needs its own adapter bound to
        // `lpEarnVault`.
        LiquidityAdapter lpAdapter = new LiquidityAdapter(usdt, address(lpEarnVault), STALENESS_WINDOW);

        vm.prank(attacker);
        vm.expectRevert(IBaseVault.Unauthorized.selector); // not this vault's Curator
        lpEarnVault.setAdapter(address(lpAdapter));

        vm.prank(otherCurator);
        lpEarnVault.setAdapter(address(lpAdapter));
        assertEq(lpEarnVault.adapter(), address(lpAdapter));

        LiquidityAdapter otherAdapter = new LiquidityAdapter(usdt, address(lpEarnVault), STALENESS_WINDOW);
        vm.prank(otherCurator);
        vm.expectRevert(LiquidityEarnVault.AdapterAlreadySet.selector);
        lpEarnVault.setAdapter(address(otherAdapter));
    }

    /// @dev The single-adapter guard reads `adapter`, which only `setAdapter`
    ///      used to write. Coming in through the inherited `addAdapter` therefore left the guard
    ///      unarmed, and adapters could be appended one after another — each one's `realAssets()`
    ///      feeding `grossManagedAssets()` — right up until someone got round to `setAdapter`.
    ///      `addAdapter` now writes `adapter` itself, so the first admission through either entry
    ///      point closes both.
    function test_liquidityEarnVault_addAdapter_armsTheSingleAdapterGuard() public {
        address otherOwner = makeAddr("guardVaultOwner");
        LiquidityEarnVault lpEarnVault = new LiquidityEarnVault(
            "LP Earn Guard",
            "htLPG",
            address(usdt),
            address(sm),
            address(queue),
            otherOwner,
            address(bridge),
            address(cashVault)
        );

        address otherCurator = makeAddr("guardCurator");
        vm.prank(otherOwner);
        lpEarnVault.setCurator(otherCurator);
        vm.prank(governor);
        lpEarnVault.bindGovernance(makeAddr("guardTimelockStandIn"));

        LiquidityAdapter first = new LiquidityAdapter(usdt, address(lpEarnVault), STALENESS_WINDOW);
        LiquidityAdapter second = new LiquidityAdapter(usdt, address(lpEarnVault), STALENESS_WINDOW);

        vm.prank(otherCurator);
        lpEarnVault.addAdapter(address(first));
        assertEq(lpEarnVault.adapter(), address(first), "addAdapter writes the field it guards on");

        vm.prank(otherCurator);
        vm.expectRevert(LiquidityEarnVault.AdapterAlreadySet.selector);
        lpEarnVault.addAdapter(address(second));

        // And the named entry point is closed by the same write.
        vm.prank(otherCurator);
        vm.expectRevert(LiquidityEarnVault.AdapterAlreadySet.selector);
        lpEarnVault.setAdapter(address(second));

        assertEq(lpEarnVault.adapterCount(), 1);
    }
}
