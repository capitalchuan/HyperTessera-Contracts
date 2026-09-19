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
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ProductState, CycleState, ProductParams} from "../src/libs/Types.sol";
import {MockUSDT as NonStandardUSDT} from "../test/public/mocks/MockUSDT.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("MockUSDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title VaultAdapterFundingTest
/// @notice Covers the Vault-side capital path into and out of a Strategy Adapter.
///
///         Every test here drives the flow through the Vault's own external functions. Nothing
///         pranks the Vault address: the point of these cases is that a real caller (the
///         Allocator) can make the Vault move its own USDT. Tests that fund an adapter by
///         `vm.prank(vaultAddr)` + `adapter.deposit(...)` prove only that ERC-4626 works — they
///         cannot show that any actor is able to reach that state on-chain.
contract VaultAdapterFundingTest is Test {
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
    address internal timelock = makeAddr("timelock");
    address internal dataProvider = makeAddr("dataProvider");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant STALENESS_WINDOW = 36 hours;
    uint256 internal constant VAULT_USDT = 1_000_000e6;

    function setUp() public {
        vm.warp(NOW);
        ac = new HyperAccessControl(governor);
        sm = new StateManager(address(ac));
        queue = new Queue(address(sm));
        usdt = new MockUSDT();

        vault = new EarnVault("Test Vault", "tVLT", address(usdt), address(sm), address(queue), vaultOwner, address(0));

        // Registered (still CONFIGURING) so requireActive — now consulted by BaseAdapter's
        // _onlyCurator/_onlyAllocator — has a StateContext to read. bindGovernance is gated to
        // the wired VaultFactory, which this test contract stands in for.
        vm.prank(governor);
        sm.setVaultFactory(address(this));
        vault.bindGovernance(timelock);
        sm.registerVault(address(vault));

        vm.startPrank(vaultOwner);
        vault.setCurator(curator);
        vault.setGuardian(guardian);
        vault.setAllocator(allocator);
        vm.stopPrank();

        adapter = new FirstPeriodAdapter(usdt, address(vault), STALENESS_WINDOW);

        vm.prank(curator);
        vault.addAdapter(address(adapter));

        vm.prank(curator);
        adapter.setDataProvider(dataProvider);

        // Vault holds unencumbered USDT: no pending deposits, reserved redeems, or refunds.
        usdt.mint(address(vault), VAULT_USDT);
    }

    // -----------------------------------------------------------------------
    // fundAdapter
    // -----------------------------------------------------------------------

    function test_fundAdapter_movesVaultUSDTAndMintsSharesToVault() public {
        uint256 amount = 250_000e6;

        vm.prank(allocator);
        vault.fundAdapter(address(adapter), amount);

        assertEq(usdt.balanceOf(address(adapter)), amount, "adapter holds the USDT");
        assertEq(usdt.balanceOf(address(vault)), VAULT_USDT - amount, "vault balance drops");
        assertEq(adapter.balanceOf(address(vault)), amount, "vault owns the adapter shares");
        assertEq(adapter.realAssets(), amount, "adapter reports the capital");
    }

    function test_fundAdapter_keepsGrossManagedAssetsFlat() public {
        uint256 before = vault.grossManagedAssets();

        vm.prank(allocator);
        vault.fundAdapter(address(adapter), 250_000e6);

        assertEq(vault.grossManagedAssets(), before, "capital moved, not created or destroyed");
    }

    function test_fundAdapter_emitsAdapterFunded() public {
        uint256 amount = 1_000e6;

        vm.expectEmit(true, false, false, true, address(vault));
        emit IBaseVault.AdapterFunded(address(adapter), amount, NOW);

        vm.prank(allocator);
        vault.fundAdapter(address(adapter), amount);
    }

    function test_fundAdapter_revertsForNonAllocator() public {
        vm.prank(attacker);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.fundAdapter(address(adapter), 1_000e6);

        vm.prank(curator);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.fundAdapter(address(adapter), 1_000e6);
    }

    /// @notice AdapterRegistry has been removed: Curator can add any Adapter without a registry gate.
    function test_addAdapter_noRegistryGate() public {
        // A fresh Adapter, never registered anywhere.
        FirstPeriodAdapter fresh = new FirstPeriodAdapter(usdt, address(vault), STALENESS_WINDOW);

        vm.prank(curator);
        vault.addAdapter(address(fresh));

        assertTrue(vault.isAdapter(address(fresh)));
    }

    function test_fundAdapter_revertsForUnregisteredAdapter() public {
        FirstPeriodAdapter stray = new FirstPeriodAdapter(usdt, address(vault), STALENESS_WINDOW);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.AdapterNotFound.selector, address(stray)));
        vault.fundAdapter(address(stray), 1_000e6);
    }

    function test_fundAdapter_revertsOnZeroAmount() public {
        vm.prank(allocator);
        vm.expectRevert(IBaseVault.ZeroAssets.selector);
        vault.fundAdapter(address(adapter), 0);
    }

    /// @dev Investor-owed USDT is off-limits: only `freeVaultUSDT()` may be deployed.
    function test_fundAdapter_cannotDeployMoreThanFreeUSDT() public {
        uint256 free = vault.freeVaultUSDT();

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.InsufficientFreeUSDT.selector, free + 1, free));
        vault.fundAdapter(address(adapter), free + 1);
    }

    // -----------------------------------------------------------------------
    // recallAdapter
    // -----------------------------------------------------------------------

    function test_recallAdapter_returnsUSDTToVault() public {
        uint256 funded = 400_000e6;
        vm.prank(allocator);
        vault.fundAdapter(address(adapter), funded);

        uint256 recalled = 150_000e6;
        vm.prank(allocator);
        vault.recallAdapter(address(adapter), recalled);

        assertEq(usdt.balanceOf(address(vault)), VAULT_USDT - funded + recalled, "USDT is back in the vault");
        assertEq(usdt.balanceOf(address(adapter)), funded - recalled, "adapter keeps the remainder");
        assertEq(adapter.realAssets(), funded - recalled, "adapter accounting follows");
    }

    function test_recallAdapter_fullRoundTripRestoresBalances() public {
        uint256 amount = 400_000e6;

        vm.startPrank(allocator);
        vault.fundAdapter(address(adapter), amount);
        vault.recallAdapter(address(adapter), amount);
        vm.stopPrank();

        assertEq(usdt.balanceOf(address(vault)), VAULT_USDT, "vault whole again");
        assertEq(adapter.realAssets(), 0, "adapter drained");
        assertEq(adapter.balanceOf(address(vault)), 0, "shares burned");
    }

    function test_recallAdapter_emitsAdapterRecalled() public {
        uint256 amount = 1_000e6;
        vm.prank(allocator);
        vault.fundAdapter(address(adapter), amount);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IBaseVault.AdapterRecalled(address(adapter), amount, NOW);

        vm.prank(allocator);
        vault.recallAdapter(address(adapter), amount);
    }

    function test_recallAdapter_revertsForNonAllocator() public {
        vm.prank(allocator);
        vault.fundAdapter(address(adapter), 1_000e6);

        vm.prank(attacker);
        vm.expectRevert(IBaseVault.Unauthorized.selector);
        vault.recallAdapter(address(adapter), 1_000e6);
    }

    function test_recallAdapter_revertsForUnregisteredAdapter() public {
        FirstPeriodAdapter stray = new FirstPeriodAdapter(usdt, address(vault), STALENESS_WINDOW);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IBaseVault.AdapterNotFound.selector, address(stray)));
        vault.recallAdapter(address(stray), 1_000e6);
    }

    function test_recallAdapter_revertsOnZeroAmount() public {
        vm.prank(allocator);
        vm.expectRevert(IBaseVault.ZeroAssets.selector);
        vault.recallAdapter(address(adapter), 0);
    }

    // -----------------------------------------------------------------------
    // Round trip through a deal
    // -----------------------------------------------------------------------

    /// @dev The accounting seam that used to stay open, now closed. The old
    ///      `createSellOrder(amount)` carried no reference to the buy order it unwound, so
    ///      `executeSell` could only pull USDT in — it never retired that order's `dealValue`.
    ///      Between the sale and the Data Provider writing the position down, the returned cash
    ///      and the dead deal were both counted, and `realAssets()` read double. The generic Sell
    ///      Order names the deal it exits and writes it off in the same call, so there is no
    ///      window at all, and the Data Provider no longer has to mark an exited deal to zero.
    function test_sellRetiresTheDealInTheSameCallAsThePayout() public {
        uint256 amount = 100_000e6;

        vm.prank(allocator);
        vault.fundAdapter(address(adapter), amount);

        address counterparty = makeAddr("counterparty");
        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(amount, counterparty, IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        // Capital is out at the counterparty; only the deal is on the books.
        assertEq(usdt.balanceOf(address(adapter)), 0, "cash left the adapter");
        assertEq(adapter.realAssets(), amount, "deal value stands in for it");

        // The counterparty pays the Adapter directly — the Allocator no longer has to hold the
        // proceeds or approve them, which was the whole custody problem with the old path.
        vm.prank(curator);
        uint256 sellId = adapter.createSellOrder(
            address(0), 0, amount, counterparty, counterparty, orderId, true, amount, block.timestamp + 1 days
        );

        usdt.mint(counterparty, amount);
        vm.startPrank(counterparty);
        usdt.approve(address(adapter), amount);
        adapter.fundSellOrder(sellId);
        vm.stopPrank();

        assertEq(usdt.balanceOf(allocator), 0, "the Allocator never touched the money");
        assertEq(adapter.realAssets(), amount, "locked proceeds do not stack on top of the deal");

        vm.prank(allocator);
        adapter.executeSell(sellId);

        // No overlap and no clean-up call: the deal is gone the instant the proceeds are freed.
        assertEq(adapter.realAssets(), amount, "one position's worth, never two");
        (uint256 dealValue,,) = adapter.pendingDeposits(orderId);
        assertEq(dealValue, 0, "deal retired by the sale itself, not by the Data Provider");

        // And the Vault can pull the proceeds home.
        vm.prank(allocator);
        vault.recallAdapter(address(adapter), amount);
        assertEq(vault.freeVaultUSDT(), VAULT_USDT, "vault made whole");
    }

    /// @dev The regression this whole file exists for: capital that entered an adapter must be
    ///      retrievable. Before `recallAdapter`, the Vault held adapter shares it had no function
    ///      to redeem, so `grossManagedAssets()` counted assets the Vault could never pay out.
    function test_capitalInAnAdapterIsNotStranded() public {
        vm.prank(allocator);
        vault.fundAdapter(address(adapter), VAULT_USDT);
        assertEq(vault.freeVaultUSDT(), 0, "everything is deployed");

        vm.prank(allocator);
        vault.recallAdapter(address(adapter), VAULT_USDT);

        assertEq(vault.freeVaultUSDT(), VAULT_USDT, "and all of it comes back");
    }

    // -----------------------------------------------------------------------
    // realAssets() — the idle-balance leg
    // -----------------------------------------------------------------------

    /// @dev USDT can land in an Adapter before any order exists to spend it (`executeBuy` checks
    ///      the Adapter's own balance). `realAssets()` counts that idle balance, which is what
    ///      makes it visible to `grossManagedAssets()` and withdrawable by the Vault that owns the
    ///      shares. Without the idle leg this money is invisible and stranded.
    function test_realAssets_countsIdleBalanceArrivingOutsideTheOrderBook() public {
        vm.prank(allocator);
        vault.fundAdapter(address(adapter), 100_000e6);
        uint256 grossBefore = vault.grossManagedAssets();

        // An external repayment lands directly in the Adapter — no order, no deal entry.
        usdt.mint(address(adapter), 7_500e6);

        assertEq(adapter.realAssets(), 107_500e6, "idle balance is part of realAssets");
        assertEq(vault.grossManagedAssets(), grossBefore + 7_500e6, "and reaches the Vault's books");

        // And it is genuinely withdrawable, not just countable — up to inherited ERC-4626 share
        // rounding. Donated assets raise the share price, so redeeming the Vault's whole share
        // balance rounds down and leaves a single 1e-6 unit behind; `maxWithdraw` is the exact
        // recallable amount and asking for one unit more reverts. Pinned rather than papered over:
        // an Allocator script that recalls `realAssets()` verbatim will revert on this.
        uint256 recallable = adapter.maxWithdraw(address(vault));
        assertEq(recallable, 107_500e6 - 1, "one unit of donation dust is not redeemable");

        vm.prank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxWithdraw.selector, address(vault), recallable + 1, recallable
            )
        );
        vault.recallAdapter(address(adapter), recallable + 1);

        vm.prank(allocator);
        vault.recallAdapter(address(adapter), recallable);
        assertEq(adapter.realAssets(), 1, "the dust stays in the adapter");
        assertEq(usdt.balanceOf(address(vault)), VAULT_USDT + 7_500e6 - 1);
    }

    /// @dev Idle balance and live deal value are disjoint: `executeBuy` moves the cash out in the
    ///      same call that records the deal, so summing the two legs cannot double count.
    function test_realAssets_idleAndDealLegsDoNotOverlap() public {
        vm.prank(allocator);
        vault.fundAdapter(address(adapter), 100_000e6);

        vm.prank(curator);
        uint256 orderId = adapter.createBuyOrder(60_000e6, makeAddr("cp"), IAdapter.SettlementMode.VALUE_RETURN);
        vm.prank(allocator);
        adapter.executeBuy(orderId);

        assertEq(usdt.balanceOf(address(adapter)), 40_000e6, "idle leg");
        assertEq(adapter.realAssets(), 100_000e6, "40k idle + 60k deal, not 160k");
    }
}

// ---------------------------------------------------------------------------
// Non-standard (real-world) USDT
// ---------------------------------------------------------------------------

/// @title NonStandardUSDTFundingTest
/// @notice `test/mocks/MockUSDT.sol` deliberately omits the bool return from `transfer` /
///         `transferFrom`, mirroring the deployed USDT contract — which is the whole reason the
///         protocol uses SafeERC20. It was not imported by a single test: every suite defines its
///         own OZ-ERC20-based `MockUSDT`, which *does* return bool, so the non-compliant path
///         SafeERC20 exists to absorb was never exercised. This runs the Vault↔Adapter capital
///         path and the deposit/cancel path against it.
contract NonStandardUSDTFundingTest is Test {
    HyperAccessControl internal ac;
    StateManager internal sm;
    Queue internal queue;
    EarnVault internal vault;
    NonStandardUSDT internal usdt;
    FirstPeriodAdapter internal adapter;

    address internal governor = makeAddr("governor");
    address internal vaultOwner = makeAddr("vaultOwner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal timelock = makeAddr("timelock");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant STALENESS_WINDOW = 36 hours;

    function setUp() public {
        vm.warp(NOW);
        ac = new HyperAccessControl(governor);
        sm = new StateManager(address(ac));
        queue = new Queue(address(sm));
        usdt = new NonStandardUSDT();

        vm.prank(governor);
        sm.setVaultFactory(address(this));

        vault = new EarnVault("NS Vault", "nsVLT", address(usdt), address(sm), address(queue), vaultOwner, address(0));
        vault.bindGovernance(timelock);
        sm.registerVault(address(vault));

        vm.startPrank(vaultOwner);
        vault.setCurator(curator);
        vault.setAllocator(allocator);
        vault.setKeeper(keeper, true);
        vm.stopPrank();

        adapter = new FirstPeriodAdapter(IERC20(address(usdt)), address(vault), STALENESS_WINDOW);
        vm.prank(curator);
        vault.addAdapter(address(adapter));

        vm.prank(curator);
        sm.setProductParams(address(vault), _params());
        vm.prank(keeper);
        sm.openSubscription(address(vault));
    }

    function _params() internal pure returns (ProductParams memory p) {
        p.subscriptionStart = NOW;
        p.subscriptionEnd = NOW + 7 days;
        p.walletSubscriptionCap = 1_000_000e6;
        p.minRaiseAmount = 0;
        p.cycleDuration = 7 days;
        p.maturityTimestamp = NOW + 365 days;
        p.claimingStart = NOW + 370 days;
        p.claimingEnd = NOW + 400 days;
    }

    /// @dev A plain `IERC20(usdt).transfer(...)` would revert here on the ABI decode; only
    ///      SafeERC20's empty-returndata tolerance makes fundAdapter/recallAdapter work.
    function test_fundAndRecallAdapter_workWithNoBoolReturnUSDT() public {
        usdt.mint(address(vault), 500_000e6);

        vm.prank(allocator);
        vault.fundAdapter(address(adapter), 200_000e6);
        assertEq(usdt.balanceOf(address(adapter)), 200_000e6);
        assertEq(adapter.balanceOf(address(vault)), 200_000e6);

        vm.prank(allocator);
        vault.recallAdapter(address(adapter), 200_000e6);
        assertEq(usdt.balanceOf(address(vault)), 500_000e6);
        assertEq(adapter.realAssets(), 0);
    }

    /// @dev The investor-facing legs use safeTransferFrom (pull) and safeTransfer (refund) — both
    ///      against the same non-compliant token.
    function test_requestDepositAndCancel_workWithNoBoolReturnUSDT() public {
        usdt.mint(alice, 10_000e6);

        vm.startPrank(alice);
        usdt.approve(address(vault), 10_000e6);
        uint256 rid = vault.requestDeposit(10_000e6, alice);
        vm.stopPrank();

        assertEq(usdt.balanceOf(address(vault)), 10_000e6);
        assertEq(usdt.balanceOf(alice), 0);

        vm.prank(alice);
        vault.cancelRequest(rid);

        assertEq(usdt.balanceOf(alice), 10_000e6, "principal returned through safeTransfer");
        assertEq(vault.pendingDepositLiability(), 0);
    }

    /// @dev `forceApprove` is what lets the Vault re-approve an Adapter that still has a nonzero
    ///      allowance — the approve-race guard real USDT enforces. Two fundings back to back.
    function test_fundAdapter_twiceInARowReApprovesCleanly() public {
        usdt.mint(address(vault), 300_000e6);

        vm.startPrank(allocator);
        vault.fundAdapter(address(adapter), 100_000e6);
        vault.fundAdapter(address(adapter), 100_000e6);
        vm.stopPrank();

        assertEq(usdt.balanceOf(address(adapter)), 200_000e6);
        assertEq(vault.grossManagedAssets(), 300_000e6);
    }
}
