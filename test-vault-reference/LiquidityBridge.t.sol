// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HyperAccessControl} from "../src/governance/HyperAccessControl.sol";
import {StateManager} from "../src/asset-management/StateManager.sol";
import {EarnVault} from "../src/asset-management/vaults/EarnVault.sol";
import {LiquidityBridge} from "../src/asset-management/vaults/LiquidityBridge.sol";
import {Queue} from "../src/asset-management/settlement/Queue.sol";
import {ILiquidityBridge} from "../src/interfaces/ILiquidityBridge.sol";
import {IEarnVault} from "../src/interfaces/IEarnVault.sol";
import {ProductState, CycleState} from "../src/libs/Types.sol";

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

/// @notice Minimal IVaultRoles-shaped stand-in exposing only `allocator()`, used as `fromVault`
///         in bridgeDeposit tests: LiquidityBridge checks `IVaultRoles(fromVault).allocator()`,
///         and that call reverts if `fromVault` is a plain EOA with no code.
contract MockAllocatorVault {
    address public allocator;

    constructor(address allocator_) {
        allocator = allocator_;
    }
}

contract LiquidityBridgeTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    MockUSDT internal usdt;
    LiquidityBridge internal bridge;
    EarnVault internal cashVault;

    address internal governor = makeAddr("governor");
    address internal factory = makeAddr("factory");
    address internal allocator = makeAddr("allocator");
    address internal alice = makeAddr("alice");

    uint256 internal constant NOW = 1_000_000;

    function setUp() public {
        vm.warp(NOW);

        ac = new HyperAccessControl(governor);
        sm = new StateManager(address(ac));
        usdt = new MockUSDT();

        vm.prank(governor);
        sm.setVaultFactory(factory);

        queue = new Queue(address(sm));
        bridge = new LiquidityBridge(address(usdt), address(sm), address(ac));

        cashVault = new EarnVault(
            "Cash Earn",
            "htCASH",
            address(usdt),
            address(sm),
            address(queue),
            governor,
            address(bridge) // liquidityBridge
        );

        vm.prank(factory);
        sm.registerVault(address(cashVault));

        _admit(address(cashVault));
    }

    /// @dev Governor admission to the bridge. Separate from `registerVault` on purpose: the two
    ///      say different things now, and every test that expects a bridge to go through has to
    ///      make both statements (审计反馈 V4 #2).
    function _admit(address vault) internal {
        vm.prank(governor);
        bridge.setBridgeWhitelisted(vault, true);
    }

    // -----------------------------------------------------------------------
    // bridgeDeposit — access control
    // -----------------------------------------------------------------------

    function test_bridgeDeposit_by_fromVaults_allocator() public {
        // fromVault must be a real IVaultRoles-shaped contract now — bridgeDeposit checks
        // IVaultRoles(fromVault).allocator(), which reverts against a plain EOA with no code.
        MockAllocatorVault fromVault = new MockAllocatorVault(allocator);
        vm.prank(factory);
        sm.registerVault(address(fromVault)); // both sides must be protocol-registered (Audit V2 #3)
        _admit(address(fromVault));
        uint256 assets = 1_000e6;
        usdt.mint(address(fromVault), assets);

        // fromVault must approve bridge to pull USDT
        vm.prank(address(fromVault));
        usdt.approve(address(bridge), assets);

        // allocator calls bridgeDeposit on behalf of fromVault
        vm.prank(allocator);
        uint256 shares = bridge.bridgeDeposit(assets, address(fromVault), address(cashVault));
        assertGt(shares, 0);
        // Shares landed in fromVault
        assertEq(cashVault.balanceOf(address(fromVault)), shares);
    }

    /// @dev fromVault calling bridgeDeposit on itself. The auth check is short-circuited —
    ///      `msg.sender != fromVault && IVaultRoles(fromVault).allocator() != msg.sender` never
    ///      makes the external `allocator()` call once the self-check passes — so a `fromVault`
    ///      with no code at all must still be accepted. Using a codeless address here is the
    ///      whole point: a contract stand-in would answer `allocator()` and the test would pass
    ///      even if the short-circuit were removed.
    function test_bridgeDeposit_by_fromVault_codelessSenderIsAccepted() public {
        address fromVault = makeAddr("codelessFromVault");
        vm.prank(factory);
        sm.registerVault(fromVault);
        _admit(address(fromVault));
        assertEq(fromVault.code.length, 0, "fromVault must have no code for this to prove anything");

        uint256 assets = 500e6;
        usdt.mint(fromVault, assets);

        vm.startPrank(fromVault);
        usdt.approve(address(bridge), assets);
        uint256 shares = bridge.bridgeDeposit(assets, fromVault, address(cashVault));
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(cashVault.balanceOf(fromVault), shares);
    }

    /// @dev The counterpart: a codeless `fromVault` with a non-self caller has no `allocator()`
    ///      to consult, so the auth call reverts rather than silently authorising.
    function test_bridgeDeposit_codelessFromVault_nonSelfCaller_reverts() public {
        address fromVault = makeAddr("codelessFromVault2");
        usdt.mint(fromVault, 1_000e6);
        vm.prank(fromVault);
        usdt.approve(address(bridge), 1_000e6);

        vm.prank(alice);
        // The registration check now fires first: an unregistered `fromVault` is rejected before
        // the auth question is even asked (Audit Feedback V2 #3).
        vm.expectRevert(abi.encodeWithSelector(ILiquidityBridge.UnregisteredVault.selector, fromVault));
        bridge.bridgeDeposit(1_000e6, fromVault, address(cashVault));
    }

    function test_bridgeDeposit_unauthorized_reverts() public {
        MockAllocatorVault fromVault = new MockAllocatorVault(allocator);
        vm.prank(factory);
        sm.registerVault(address(fromVault)); // both sides must be protocol-registered (Audit V2 #3)
        _admit(address(fromVault));
        usdt.mint(address(fromVault), 1_000e6);
        vm.prank(address(fromVault));
        usdt.approve(address(bridge), 1_000e6);

        vm.prank(alice); // alice is neither fromVault's allocator nor fromVault itself
        vm.expectRevert(abi.encodeWithSelector(ILiquidityBridge.CallerNotAuthorized.selector, alice));
        bridge.bridgeDeposit(1_000e6, address(fromVault), address(cashVault));
    }

    // -----------------------------------------------------------------------
    // bridgeDeposit — validation
    // -----------------------------------------------------------------------

    function test_bridgeDeposit_zero_assets_reverts() public {
        vm.prank(allocator);
        vm.expectRevert(ILiquidityBridge.ZeroAssets.selector);
        bridge.bridgeDeposit(0, alice, address(cashVault));
    }

    function test_bridgeDeposit_emits_DepositBridged() public {
        MockAllocatorVault fromVault = new MockAllocatorVault(allocator);
        vm.prank(factory);
        sm.registerVault(address(fromVault)); // both sides must be protocol-registered (Audit V2 #3)
        _admit(address(fromVault));
        uint256 assets = 1_000e6;
        usdt.mint(address(fromVault), assets);
        vm.prank(address(fromVault));
        usdt.approve(address(bridge), assets);

        uint256 expectedShares = cashVault.convertToShares(assets);
        vm.prank(allocator);
        vm.expectEmit(true, true, false, true);
        emit ILiquidityBridge.DepositBridged(address(fromVault), address(cashVault), assets, expectedShares, NOW);
        bridge.bridgeDeposit(assets, address(fromVault), address(cashVault));
    }

    // -----------------------------------------------------------------------
    // EarnVault sync deposit guard
    // -----------------------------------------------------------------------

    function test_earnVault_sync_deposit_only_bridge() public {
        // Calling cashVault.deposit directly (not via bridge) reverts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEarnVault.OnlyLiquidityBridge.selector, alice));
        cashVault.deposit(1_000e6, alice);
    }

    function test_earnVault_sync_deposit_via_bridge_increases_balance() public {
        MockAllocatorVault fromVault = new MockAllocatorVault(allocator);
        vm.prank(factory);
        sm.registerVault(address(fromVault)); // both sides must be protocol-registered (Audit V2 #3)
        _admit(address(fromVault));
        uint256 assets = 2_000e6;
        usdt.mint(address(fromVault), assets);
        vm.prank(address(fromVault));
        usdt.approve(address(bridge), assets);

        vm.prank(allocator);
        uint256 shares = bridge.bridgeDeposit(assets, address(fromVault), address(cashVault));
        assertEq(cashVault.balanceOf(address(fromVault)), shares);
        // Bridge holds no shares
        assertEq(cashVault.balanceOf(address(bridge)), 0);
        // Bridge holds no USDT
        assertEq(usdt.balanceOf(address(bridge)), 0);
    }

    // -----------------------------------------------------------------------
    // No bridgeRedeem (spec: removed in redesign)
    // -----------------------------------------------------------------------

    /// @dev A raw call to the removed selector must find no implementation. LiquidityBridge has
    ///      no fallback, so the call reverts with empty returndata. The previous version of this
    ///      test asserted `address(bridge) != address(0)`, which no change to src could break.
    function test_no_bridgeRedeem_function() public {
        (bool ok, bytes memory ret) = address(bridge)
            .call(
                abi.encodeWithSignature("bridgeRedeem(uint256,address,address)", uint256(1), alice, address(cashVault))
            );
        assertFalse(ok, "bridgeRedeem must not be dispatchable");
        assertEq(ret.length, 0, "no function body should have been reached");

        // Sanity: the same raw-call harness DOES reach a selector the bridge really has, so a
        // false negative above cannot come from a malformed call.
        (bool okReal,) = address(bridge).staticcall(abi.encodeWithSignature("usdt()"));
        assertTrue(okReal, "control selector must dispatch");
    }

    // -----------------------------------------------------------------------
    // 审计反馈 V4 #2 — registration is not trust; the bridge needs Governor admission
    // -----------------------------------------------------------------------

    /// @dev `deployVault` is permissionless (审计反馈 V3 #1/#2), so an attacker's own Vault is
    ///      registered with StateManager exactly like a real one. It would then pass the
    ///      `fromVault` self-call check trivially and reach `IEarnVault(toVault).deposit` —
    ///      minting shares synchronously inside a real Vault, outside the async `requestDeposit`
    ///      flow entirely. Registration alone never closed that; the whitelist does.
    function test_bridgeDeposit_registeredButUnadmittedFromVault_reverts() public {
        address rogue = makeAddr("rogueVault");
        vm.prank(factory);
        sm.registerVault(rogue); // permissionless deployment gets this for free
        assertTrue(sm.registeredVaults(rogue), "registered...");
        assertFalse(bridge.bridgeWhitelisted(rogue), "...but not admitted");

        usdt.mint(rogue, 1_000e6);
        vm.startPrank(rogue);
        usdt.approve(address(bridge), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityBridge.VaultNotWhitelisted.selector, rogue));
        bridge.bridgeDeposit(1_000e6, rogue, address(cashVault));
        vm.stopPrank();

        assertEq(cashVault.balanceOf(rogue), 0);
    }

    /// @dev The destination is gated too: accepting a synchronous mint is a property of that
    ///      Vault's own design, not something any registered source may impose on it.
    function test_bridgeDeposit_unadmittedToVault_reverts() public {
        MockAllocatorVault fromVault = new MockAllocatorVault(allocator);
        vm.prank(factory);
        sm.registerVault(address(fromVault));
        _admit(address(fromVault));

        EarnVault otherVault = new EarnVault(
            "Other Earn", "htOTHER", address(usdt), address(sm), address(queue), governor, address(bridge)
        );
        vm.prank(factory);
        sm.registerVault(address(otherVault)); // registered, never admitted

        usdt.mint(address(fromVault), 1_000e6);
        vm.prank(address(fromVault));
        usdt.approve(address(bridge), 1_000e6);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityBridge.VaultNotWhitelisted.selector, address(otherVault)));
        bridge.bridgeDeposit(1_000e6, address(fromVault), address(otherVault));
    }

    function test_setBridgeWhitelisted_onlyGovernor() public {
        vm.prank(alice);
        vm.expectRevert(ILiquidityBridge.NotGovernor.selector);
        bridge.setBridgeWhitelisted(address(cashVault), true);
    }

    function test_setBridgeWhitelisted_zeroAddress_reverts() public {
        vm.prank(governor);
        vm.expectRevert(ILiquidityBridge.ZeroAddress.selector);
        bridge.setBridgeWhitelisted(address(0), true);
    }

    function test_setBridgeWhitelisted_emitsAndIsRevocable() public {
        MockAllocatorVault fromVault = new MockAllocatorVault(allocator);
        vm.prank(factory);
        sm.registerVault(address(fromVault));

        vm.expectEmit(true, false, false, true);
        emit ILiquidityBridge.BridgeWhitelistUpdated(address(fromVault), true, block.timestamp);
        _admit(address(fromVault));
        assertTrue(bridge.bridgeWhitelisted(address(fromVault)));

        usdt.mint(address(fromVault), 2_000e6);
        vm.prank(address(fromVault));
        usdt.approve(address(bridge), 2_000e6);
        vm.prank(allocator);
        bridge.bridgeDeposit(1_000e6, address(fromVault), address(cashVault));

        // Revoking shuts the same route it opened.
        vm.prank(governor);
        bridge.setBridgeWhitelisted(address(fromVault), false);
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityBridge.VaultNotWhitelisted.selector, address(fromVault)));
        bridge.bridgeDeposit(1_000e6, address(fromVault), address(cashVault));
    }

    function test_constructor_rejectsZeroAccessControl() public {
        vm.expectRevert(ILiquidityBridge.ZeroAddress.selector);
        new LiquidityBridge(address(usdt), address(sm), address(0));
    }
}
