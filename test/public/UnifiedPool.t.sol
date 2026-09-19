// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {UnifiedPool} from "../../src/asset-management/settlement/UnifiedPool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {RevenuePool} from "../../src/asset-management/settlement/RevenuePool.sol";
import {IUnifiedPool} from "../../src/interfaces/IUnifiedPool.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";

// Reuse mock from RevenuePool test.
contract MockUSDT2 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// Mock StateManager: whitelists specific vaults.
contract MockSM2 {
    mapping(address => bool) public registeredVaults;

    function registerVault(address v) external {
        registeredVaults[v] = true;
    }
}

// Minimal mock vault exposing the IVaultRoles.owner() / IBaseVault.settlement() surface that
// UnifiedPool now depends on (owner-gated registration, settlement-gated distribute).
contract MockVault3 {
    address public owner;
    address public settlement;
    address public vaultTimelock;
    mapping(address => bool) public isAdapter;

    constructor(address owner_) {
        owner = owner_;
    }

    function setVaultTimelock(address t) external {
        vaultTimelock = t;
    }

    function setAdapter(address a, bool on) external {
        isAdapter[a] = on;
    }

    function setSettlement(address settlement_) external {
        settlement = settlement_;
    }
}

// Minimal mock Settlement exposing isOperator(vault, account), consumed via
// ISettlement(vault.settlement()).isOperator(...) for the Settlement-Operator-gated functions.
contract MockSettlement3 {
    mapping(address => mapping(address => bool)) public isOperator;

    function setOperator(address vault, address account, bool approved) external {
        isOperator[vault][account] = approved;
    }
}

/// @notice Trivial "next implementation" used to exercise UUPS upgrade authorization end to end
///         (governor-gated `upgradeToAndCall`, storage preserved across the swap) and to confirm
///         the reentrancy guard's storage slot survives an upgrade unmoved.
contract UnifiedPoolV2Mock is UnifiedPool {
    function version() external pure returns (string memory) {
        return "v2-mock";
    }

    function reenterRepayInterest(uint256 amount) external nonReentrant {
        this.repayInterest(amount);
    }
}

contract UnifiedPoolTest is Test {
    HyperAccessControl internal ac;
    MockUSDT2 internal usdt;
    MockSM2 internal sm;
    RevenuePool internal revPool;
    UnifiedPool internal pool;
    MockSettlement3 internal mockSettlement;
    MockVault3 internal vaultMock;

    address internal governor = makeAddr("governor");
    address internal vaultOwner = makeAddr("vaultOwner");
    address internal operator = makeAddr("operator");
    address internal payer = makeAddr("payer");
    address internal vault;
    address internal settlement;
    address internal attacker = makeAddr("attacker");
    address internal timelock = makeAddr("vaultTimelock");

    function setUp() public {
        ac = new HyperAccessControl(governor);
        usdt = new MockUSDT2();
        sm = new MockSM2();
        revPool = new RevenuePool(address(usdt), address(ac));

        UnifiedPool poolImpl = new UnifiedPool();
        bytes memory poolInitData = abi.encodeCall(UnifiedPool.initialize, (address(usdt), address(sm), address(ac)));
        pool = UnifiedPool(address(new ERC1967Proxy(address(poolImpl), poolInitData)));

        vm.prank(governor);
        revPool.addAuthorizedSource(address(pool));

        mockSettlement = new MockSettlement3();
        settlement = address(mockSettlement);

        vaultMock = new MockVault3(vaultOwner);
        vaultMock.setSettlement(settlement);
        vaultMock.setVaultTimelock(timelock);
        vault = address(vaultMock);

        sm.registerVault(vault);
        mockSettlement.setOperator(vault, operator, true);

        vm.prank(vaultOwner);
        pool.addVault(vault);

        // Governor admission (审计反馈 V3 #1/#2): `addVault` is the Vault opting in, these two are
        // the protocol admitting it and trusting the Settlement it points at. Attribution,
        // distribution and note-routing all check both.
        vm.startPrank(governor);
        pool.setVaultWhitelisted(vault, true);
        pool.setSettlementWhitelisted(settlement, true);
        vm.stopPrank();
    }

    /// @dev Registers the mock in the StateManager stand-in too: every UnifiedPool entry point
    ///      that takes a `vault` argument now requires it to be a protocol-registered vault
    ///      (审计反馈 2026-08-17 #1).
    /// @dev Repays `amount` into the pool and attributes it all to `v`.
    function _fund(address v, uint256 amount) internal {
        usdt.mint(payer, amount);
        vm.prank(payer);
        usdt.approve(address(pool), amount);
        vm.prank(payer);
        pool.repayPrincipal(amount);
        vm.prank(operator);
        pool.attributePrincipal(v, amount);
    }

    function _makeVault(address owner_) internal returns (address v, MockVault3 mock) {
        mock = new MockVault3(owner_);
        mock.setSettlement(settlement);
        v = address(mock);
        sm.registerVault(v);
    }

    // -----------------------------------------------------------------------
    // Constructor / initialize
    // -----------------------------------------------------------------------

    function test_initialize_revertsOnZeroAddresses() public {
        UnifiedPool poolImpl = new UnifiedPool();
        bytes memory badInitData = abi.encodeCall(UnifiedPool.initialize, (address(0), address(sm), address(ac)));
        vm.expectRevert(IUnifiedPool.ZeroAddress.selector);
        new ERC1967Proxy(address(poolImpl), badInitData);
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pool.initialize(address(usdt), address(sm), address(ac));
    }

    // -----------------------------------------------------------------------
    // UUPS upgrade authorization
    // -----------------------------------------------------------------------

    function test_upgradeToAndCall_byGovernor_succeeds() public {
        UnifiedPoolV2Mock newImpl = new UnifiedPoolV2Mock();

        vm.prank(governor);
        pool.upgradeToAndCall(address(newImpl), "");

        // State survives the upgrade (proxy storage, not implementation, holds it).
        assertTrue(pool.vaultConfigured(vault));
        assertEq(UnifiedPoolV2Mock(address(pool)).version(), "v2-mock");
    }

    function test_upgradeToAndCall_byNonGovernor_reverts() public {
        UnifiedPoolV2Mock newImpl = new UnifiedPoolV2Mock();

        vm.prank(attacker);
        vm.expectRevert(IUnifiedPool.NotGovernor.selector);
        pool.upgradeToAndCall(address(newImpl), "");
    }

    // -----------------------------------------------------------------------
    // reinitializeStateManager
    // -----------------------------------------------------------------------

    /// @dev Rebuilds the v3 BSC-Testnet defect: the proxy was initialized with the W1/W2
    ///      `StubStateManager`, which registers no vaults. `MockSM2` with no `registerVault`
    ///      call is behaviourally identical for the one function that matters here.
    /// @dev The stale StateManager knows this vault (otherwise nothing could be configured into
    ///      the pool at all — see the vault-whitelist tests), but it is the wrong instance: the
    ///      re-pointing path is still what moves the pool onto the real one.
    function _poolBoundToStaleSm() internal returns (UnifiedPool stalePool) {
        MockSM2 staleSm = new MockSM2();
        staleSm.registerVault(vault);
        UnifiedPool impl = new UnifiedPool();
        stalePool = UnifiedPool(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(UnifiedPool.initialize, (address(usdt), address(staleSm), address(ac)))
                )
            )
        );
        vm.prank(vaultOwner);
        stalePool.addVault(vault);
        vm.startPrank(governor);
        stalePool.setVaultWhitelisted(vault, true);
        stalePool.setSettlementWhitelisted(settlement, true);
        vm.stopPrank();
    }

    /// @notice Characterises the defect this `reinitializer` exists for: a pool bound to a
    ///         StateManager that does not know a vault rejects that vault's
    ///         `receiveVaultPrincipal` — and therefore `BaseVault.returnPrincipalToPool` —
    ///         permanently, because `sm` has no setter.
    function test_receiveVaultPrincipal_revertsWhileBoundToStaleStateManager() public {
        MockSM2 emptySm = new MockSM2();
        UnifiedPool impl = new UnifiedPool();
        UnifiedPool stalePool = UnifiedPool(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(UnifiedPool.initialize, (address(usdt), address(emptySm), address(ac)))
                )
            )
        );
        usdt.mint(vault, 1_000e6);

        vm.startPrank(vault);
        usdt.approve(address(stalePool), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.UnregisteredVault.selector, vault));
        stalePool.receiveVaultPrincipal(1_000e6);
        vm.stopPrank();
    }

    function test_reinitializeStateManager_unblocksReceiveVaultPrincipal() public {
        UnifiedPool stalePool = _poolBoundToStaleSm();
        // Hoisted: a `new` in the argument list would consume the prank as its CREATE caller.
        address nextImpl = address(new UnifiedPool());

        vm.prank(governor);
        stalePool.upgradeToAndCall(nextImpl, abi.encodeCall(UnifiedPool.reinitializeStateManager, (address(sm))));
        assertEq(address(stalePool.sm()), address(sm));

        usdt.mint(vault, 1_000e6);
        vm.startPrank(vault);
        usdt.approve(address(stalePool), 1_000e6);
        stalePool.receiveVaultPrincipal(1_000e6);
        vm.stopPrank();

        assertEq(stalePool.pending(vault), 1_000e6);
        assertEq(stalePool.totalPending(), 1_000e6);
        assertEq(usdt.balanceOf(address(stalePool)), 1_000e6);
    }

    function test_reinitializeStateManager_preservesExistingLedger() public {
        UnifiedPool stalePool = _poolBoundToStaleSm();

        usdt.mint(payer, 500e6);
        vm.startPrank(payer);
        usdt.approve(address(stalePool), 500e6);
        stalePool.repayPrincipal(500e6);
        vm.stopPrank();
        vm.prank(operator);
        stalePool.attributePrincipal(vault, 500e6);
        assertEq(stalePool.pending(vault), 500e6);

        address nextImpl = address(new UnifiedPool());
        vm.prank(governor);
        stalePool.upgradeToAndCall(nextImpl, abi.encodeCall(UnifiedPool.reinitializeStateManager, (address(sm))));

        assertEq(stalePool.pending(vault), 500e6);
        assertEq(stalePool.totalPending(), 500e6);
        assertEq(address(stalePool.usdt()), address(usdt));
        assertEq(address(stalePool.ac()), address(ac));
        assertTrue(stalePool.vaultConfigured(vault));
        assertEq(usdt.balanceOf(address(stalePool)), 500e6);
    }

    function test_reinitializeStateManager_byNonGovernor_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IUnifiedPool.NotGovernor.selector);
        pool.reinitializeStateManager(address(sm));
    }

    function test_reinitializeStateManager_revertsOnZeroAddress() public {
        vm.prank(governor);
        vm.expectRevert(IUnifiedPool.ZeroAddress.selector);
        pool.reinitializeStateManager(address(0));
    }

    function test_reinitializeStateManager_cannotRunTwice() public {
        MockSM2 firstSm = new MockSM2();
        vm.prank(governor);
        pool.reinitializeStateManager(address(firstSm));
        assertEq(address(pool.sm()), address(firstSm));

        vm.prank(governor);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pool.reinitializeStateManager(address(sm));
    }

    /// @notice Guards against a state-variable insertion between the reentrancy-guard fields and
    ///         `__gap` silently corrupting the storage layout on a future upgrade.
    function test_reentrancyGuard_stillGatesReentrancy_afterUpgrade() public {
        UnifiedPoolV2Mock newImpl = new UnifiedPoolV2Mock();
        vm.prank(governor);
        pool.upgradeToAndCall(address(newImpl), "");

        vm.prank(payer);
        vm.expectRevert(UnifiedPool.ReentrancyGuardReentrantCall.selector);
        UnifiedPoolV2Mock(address(pool)).reenterRepayInterest(1);
    }

    // -----------------------------------------------------------------------
    // addVault / deactivate / reactivate
    // -----------------------------------------------------------------------

    function test_addVault_setsConfiguredAndActive() public {
        assertTrue(pool.vaultConfigured(vault));
        assertTrue(pool.vaultActive(vault));
    }

    /// @dev Tranche classification is gone: registration keys on the vault address alone, and
    ///      any number of vaults can be configured (合约修复20260825 §1).
    function test_addVault_manyVaults() public {
        (address vault2,) = _makeVault(vaultOwner);
        vm.prank(vaultOwner);
        pool.addVault(vault2);

        assertTrue(pool.vaultConfigured(vault));
        assertTrue(pool.vaultConfigured(vault2));
    }

    function test_addVault_revertsIfAlreadyConfigured() public {
        vm.prank(vaultOwner);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.VaultAlreadyConfigured.selector, vault));
        pool.addVault(vault);
    }

    function test_addVault_revertsForNonOwner() public {
        (address vault2,) = _makeVault(vaultOwner);
        vm.prank(attacker);
        vm.expectRevert(IUnifiedPool.NotVaultOwner.selector);
        pool.addVault(vault2);
    }

    function test_addVault_revertsOnZeroAddress() public {
        vm.prank(vaultOwner);
        vm.expectRevert(IUnifiedPool.ZeroAddress.selector);
        pool.addVault(address(0));
    }

    function test_deactivateVault_setsInactive() public {
        vm.prank(vaultOwner);
        pool.deactivateVault(vault);
        assertFalse(pool.vaultActive(vault));
    }

    function test_deactivateVault_revertsForNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(IUnifiedPool.NotVaultOwner.selector);
        pool.deactivateVault(vault);
    }

    function test_reactivateVault_restoresActive() public {
        vm.startPrank(vaultOwner);
        pool.deactivateVault(vault);
        pool.reactivateVault(vault);
        vm.stopPrank();
        assertTrue(pool.vaultActive(vault));
    }

    function test_deactivatedVault_stillDistributable() public {
        // Fund pending, then deactivate — distribute must still work against historical pending.
        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);
        vm.prank(payer);
        pool.repayPrincipal(1_000e6);

        vm.prank(operator);
        pool.attributePrincipal(vault, 1_000e6);

        vm.prank(vaultOwner);
        pool.deactivateVault(vault);

        vm.prank(settlement);
        pool.distribute(vault, 500e6);
        assertEq(pool.pending(vault), 500e6);
    }

    // -----------------------------------------------------------------------
    // repayInterest / repayPrincipal — permissionless deposits into the unattributed pools
    // (SET-06: no longer credit any vault's pending directly; repayInterestBatch was removed
    // entirely since attribution is now a separate, per-vault Settlement-Operator-gated step).
    // -----------------------------------------------------------------------

    function test_repayInterest_creditsUnattributedPool_noVaultAttribution() public {
        uint256 amount = 1_000e6;
        usdt.mint(payer, amount);
        vm.prank(payer);
        usdt.approve(address(pool), amount);

        vm.prank(payer);
        pool.repayInterest(amount);

        assertEq(pool.unattributedInterest(), amount);
        assertEq(pool.pending(vault), 0);
        assertEq(pool.totalPending(), 0);
    }

    function test_repayInterest_isPermissionless() public {
        // No role/authorization required — any real payer may deposit.
        usdt.mint(attacker, 1_000e6);
        vm.prank(attacker);
        usdt.approve(address(pool), 1_000e6);

        vm.prank(attacker);
        pool.repayInterest(1_000e6);

        assertEq(pool.unattributedInterest(), 1_000e6);
    }

    function test_repayInterest_revertsForZeroAmount() public {
        vm.prank(payer);
        vm.expectRevert(IUnifiedPool.ZeroAmount.selector);
        pool.repayInterest(0);
    }

    function test_repayInterest_emitsInterestDeposited() public {
        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IUnifiedPool.InterestDeposited(payer, 1_000e6, block.timestamp);

        vm.prank(payer);
        pool.repayInterest(1_000e6);
    }

    function test_repayPrincipal_creditsUnattributedPool() public {
        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);

        vm.prank(payer);
        pool.repayPrincipal(1_000e6);

        assertEq(pool.unattributedPrincipal(), 1_000e6);
        assertEq(pool.pending(vault), 0);
        assertEq(pool.totalPending(), 0);
    }

    function test_repayPrincipal_revertsForZeroAmount() public {
        vm.prank(payer);
        vm.expectRevert(IUnifiedPool.ZeroAmount.selector);
        pool.repayPrincipal(0);
    }

    // -----------------------------------------------------------------------
    // attributeInterest / attributePrincipal — that vault's Settlement Operator moves funds
    // from the unattributed pool into pending[vault]. New surface replacing the old
    // vault-scoped repayInterest/repayInterestBatch/repayPrincipal.
    // -----------------------------------------------------------------------

    function test_attributeInterest_movesFromUnattributedToPending() public {
        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);
        vm.prank(payer);
        pool.repayInterest(1_000e6);

        vm.prank(operator);
        pool.attributeInterest(vault, 600e6);

        assertEq(pool.unattributedInterest(), 400e6);
        assertEq(pool.pending(vault), 600e6);
        assertEq(pool.totalPending(), 600e6);
    }

    function test_attributeInterest_emitsInterestRepaid() public {
        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);
        vm.prank(payer);
        pool.repayInterest(1_000e6);

        vm.expectEmit(true, true, false, true, address(pool));
        emit IUnifiedPool.InterestRepaid(vault, 600e6, block.timestamp);

        vm.prank(operator);
        pool.attributeInterest(vault, 600e6);
    }

    function test_attributeInterest_revertsForNonSettlementOperator() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.NotSettlementOperator.selector, vault));
        pool.attributeInterest(vault, 1);
    }

    function test_attributeInterest_revertsForZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(IUnifiedPool.ZeroAmount.selector);
        pool.attributeInterest(vault, 0);
    }

    function test_attributeInterest_revertsForUnconfiguredVault() public {
        (address unknown,) = _makeVault(vaultOwner);
        mockSettlement.setOperator(unknown, operator, true);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.VaultNotConfigured.selector, unknown));
        pool.attributeInterest(unknown, 1);
    }

    function test_attributeInterest_revertsForInactiveVault() public {
        vm.prank(vaultOwner);
        pool.deactivateVault(vault);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.VaultInactive.selector, vault));
        pool.attributeInterest(vault, 1);
    }

    function test_attributeInterest_revertsIfExceedsUnattributedPool() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.InsufficientUnattributedInterest.selector, 0, 1));
        pool.attributeInterest(vault, 1);
    }

    function test_attributePrincipal_movesFromUnattributedToPending() public {
        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);
        vm.prank(payer);
        pool.repayPrincipal(1_000e6);

        vm.prank(operator);
        pool.attributePrincipal(vault, 700e6);

        assertEq(pool.unattributedPrincipal(), 300e6);
        assertEq(pool.pending(vault), 700e6);
        assertEq(pool.totalPending(), 700e6);
    }

    function test_attributePrincipal_revertsForNonSettlementOperator() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.NotSettlementOperator.selector, vault));
        pool.attributePrincipal(vault, 1);
    }

    function test_attributePrincipal_revertsIfExceedsUnattributedPool() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.InsufficientUnattributedPrincipal.selector, 0, 1));
        pool.attributePrincipal(vault, 1);
    }

    // -----------------------------------------------------------------------
    // receiveVaultPrincipal
    // -----------------------------------------------------------------------

    function test_receiveVaultPrincipal_pullsUSDTAndCreditsCallingVault() public {
        // `vault` is already StateManager-registered and UnifiedPool-configured (Cash tranche)
        // from setUp().
        usdt.mint(vault, 800e6);
        vm.prank(vault);
        usdt.approve(address(pool), 800e6);

        vm.prank(vault);
        pool.receiveVaultPrincipal(800e6);

        assertEq(pool.pending(vault), 800e6);
        assertEq(pool.totalPending(), 800e6);
        assertEq(usdt.balanceOf(address(pool)), 800e6);
        // Does not touch the unattributed pool — this is direct attribution, not a permissionless deposit.
        assertEq(pool.unattributedPrincipal(), 0);
    }

    function test_receiveVaultPrincipal_revertsForUnregisteredCaller() public {
        address unregistered = makeAddr("unregistered");
        vm.prank(unregistered);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.UnregisteredVault.selector, unregistered));
        pool.receiveVaultPrincipal(100e6);
    }

    function test_receiveVaultPrincipal_revertsIfCallerNotConfiguredInPool() public {
        // Registered in StateManager but never added as a tranche vault in UnifiedPool.
        address registeredOnly = makeAddr("registeredOnly");
        sm.registerVault(registeredOnly);

        vm.prank(registeredOnly);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.VaultNotConfigured.selector, registeredOnly));
        pool.receiveVaultPrincipal(100e6);
    }

    function test_receiveVaultPrincipal_emitsEvent() public {
        usdt.mint(vault, 800e6);
        vm.prank(vault);
        usdt.approve(address(pool), 800e6);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IUnifiedPool.VaultPrincipalReceived(vault, 800e6, block.timestamp);

        vm.prank(vault);
        pool.receiveVaultPrincipal(800e6);
    }

    // -----------------------------------------------------------------------
    // distribute / availableToDistribute
    // -----------------------------------------------------------------------

    function test_distribute_transfersUSDT() public {
        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);
        vm.prank(payer);
        pool.repayPrincipal(1_000e6);
        vm.prank(operator);
        pool.attributePrincipal(vault, 1_000e6);

        vm.prank(settlement);
        pool.distribute(vault, 600e6);

        assertEq(pool.pending(vault), 400e6);
        assertEq(pool.totalPending(), 400e6);
        assertEq(usdt.balanceOf(vault), 600e6);
    }

    function test_distribute_revertsIfInsufficientPending() public {
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.InsufficientPending.selector, vault, 0, 1));
        pool.distribute(vault, 1);
    }

    /// @dev `pending[vault]` is a book claim on pool-MANAGED assets, not on the pool's instant
    ///      cash: `operatorTransfer` moving idle cash into an authorised external position
    ///      changes the asset's form without extinguishing the claim, so a cash balance below
    ///      `totalPending` is expected liquidity waiting (审计报告（一）回复 §1).
    function test_operatorTransfer_leavesPendingIntact() public {
        _fund(vault, 1_000e6);

        vm.prank(governor);
        pool.operatorTransfer(vault, makeAddr("sink"), 700e6, bytes32(0));

        assertEq(pool.pending(vault), 1_000e6, "claim on managed assets survives the transfer");
        assertEq(usdt.balanceOf(address(pool)), 300e6, "cash is legitimately below the ledger");
    }

    /// @dev The gap that leaves: `distribute` used to be the only path that could reduce
    ///      `pending`, so a permanently lost external position stayed in the vault's NAV forever.
    ///      Impairment is recognised explicitly instead (审计报告一反馈 §1).
    function test_writeDownPending_recognisesPermanentLoss() public {
        _fund(vault, 1_000e6);

        vm.prank(timelock);
        pool.writeDownPending(vault, 400e6, bytes32("loss-1"));

        assertEq(pool.pending(vault), 600e6);
        assertEq(pool.totalPending(), 600e6);
    }

    function test_writeDownPending_onlyVaultTimelock() public {
        _fund(vault, 1_000e6);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.NotVaultTimelock.selector, vault));
        pool.writeDownPending(vault, 1, bytes32(0));
    }

    function test_writeDownPending_cannotExceedPending() public {
        _fund(vault, 100e6);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.InsufficientPending.selector, vault, 100e6, 101e6));
        pool.writeDownPending(vault, 101e6, bytes32(0));
    }

    /// @dev Pool cash must not be routed into one of the vault's own Adapters: the Adapter's
    ///      `realAssets()` and the vault's `pending` would both count it, double-counting it in
    ///      `grossManagedAssets()` (审计报告一反馈 §1).
    function test_operatorTransfer_rejectsVaultAdapterRecipient() public {
        _fund(vault, 1_000e6);
        address adapter = makeAddr("adapter");
        vaultMock.setAdapter(adapter, true);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.RecipientIsVaultAdapter.selector, vault, adapter));
        pool.operatorTransfer(vault, adapter, 100e6, bytes32(0));
    }

    function test_distribute_revertsForNonSettlement() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.NotVaultSettlement.selector, vault));
        pool.distribute(vault, 1);
    }

    function test_availableToDistribute_boundedByCash() public {
        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);
        vm.prank(payer);
        pool.repayPrincipal(1_000e6);
        vm.prank(operator);
        pool.attributePrincipal(vault, 1_000e6);

        vm.prank(governor);
        pool.operatorTransfer(vault, makeAddr("sink"), 600e6, bytes32(0));

        // pending stays 1_000e6; the view is bounded by the 400e6 of cash actually on hand.
        assertEq(pool.availableToDistribute(vault), 400e6);
    }

    // -----------------------------------------------------------------------
    // operatorTransfer / operatorTransferToRevenuePool — GOVERNOR only (审计反馈 V3 #1)
    // -----------------------------------------------------------------------

    /// @dev These two are the only paths that move cash out of the pool without a matching ledger
    ///      movement, so whoever can call them can drain the shared cash backing every Vault. An
    ///      Operator key is an online per-Vault signing key; a stolen one must not reach here
    ///      (审计问题 1/2 回复 §3.5).
    function test_operatorTransfer_revertsForSettlementOperator() public {
        _fund(vault, 1_000e6);
        vm.prank(operator);
        vm.expectRevert(IUnifiedPool.NotGovernor.selector);
        pool.operatorTransfer(vault, makeAddr("recipient"), 1, bytes32(0));
    }

    function test_operatorTransferToRevenuePool_revertsForSettlementOperator() public {
        _fund(vault, 1_000e6);
        vm.prank(operator);
        vm.expectRevert(IUnifiedPool.NotGovernor.selector);
        pool.operatorTransferToRevenuePool(vault, address(revPool), 1, bytes32(0));
    }

    function test_operatorTransfer_revertsForNonGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(IUnifiedPool.NotGovernor.selector);
        pool.operatorTransfer(vault, makeAddr("recipient"), 1, bytes32(0));
    }

    function test_operatorTransfer_revertsOnZeroRecipient() public {
        vm.prank(governor);
        vm.expectRevert(IUnifiedPool.InvalidRecipient.selector);
        pool.operatorTransfer(vault, address(0), 1, bytes32(0));
    }

    function test_operatorTransferToRevenuePool_callsReceiveFee() public {
        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);
        vm.prank(payer);
        pool.repayPrincipal(1_000e6);
        vm.prank(operator);
        pool.attributePrincipal(vault, 1_000e6);

        vm.prank(governor);
        pool.operatorTransferToRevenuePool(vault, address(revPool), 250e6, bytes32("ref2"));

        assertEq(usdt.balanceOf(address(revPool)), 250e6);
        assertEq(revPool.totalFeesReceived(), 250e6);
        // Same accounting rule as operatorTransfer: the ledger is a claim on managed assets and
        // is not debited here (审计报告（一）回复 §1).
        assertEq(pool.pending(vault), 1_000e6);
    }

    // -----------------------------------------------------------------------
    // Vault whitelist (审计反馈 2026-08-17 #1)
    // -----------------------------------------------------------------------

    /// @dev The attack the whitelist closes: a contract that self-reports `owner == attacker` and
    ///      `settlement == the real Settlement` would otherwise register itself here, let the
    ///      attacker appoint themselves its Settlement Operator, and drain the pool's shared cash
    ///      — leaving every real vault's `pending` untouched but unbacked.
    function test_addVault_revertsForUnregisteredVault() public {
        MockVault3 fake = new MockVault3(attacker);
        fake.setSettlement(settlement);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.UnregisteredVault.selector, address(fake)));
        pool.addVault(address(fake));
    }

    function test_operatorTransfer_revertsForUnregisteredVault() public {
        MockVault3 fake = new MockVault3(attacker);
        fake.setSettlement(settlement);

        // Even the Governor cannot book a transfer against a vault that is not a real one — the
        // `vault` argument is the accounting reference the transfer is recorded under.
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.UnregisteredVault.selector, address(fake)));
        pool.operatorTransfer(address(fake), attacker, 1, bytes32(0));
    }

    function test_attributePrincipal_revertsForUnregisteredVault() public {
        MockVault3 fake = new MockVault3(attacker);
        fake.setSettlement(settlement);
        mockSettlement.setOperator(address(fake), attacker, true);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.UnregisteredVault.selector, address(fake)));
        pool.attributePrincipal(address(fake), 1);
    }

    // -----------------------------------------------------------------------
    // Governor admission whitelists (审计反馈 V3 #1/#2)
    // -----------------------------------------------------------------------

    /// @dev The attack: `VaultFactory.deployVault` is permissionless by design, and being built
    ///      from the standard contracts made a Vault `sm.registeredVaults` — which was the whole
    ///      of the check. An attacker could register a Vault, point it at a Settlement that named
    ///      them Operator, and from there both drain the shared pool and mint `pending` out of the
    ///      permissionless inflow pool to fake a high-NAV Vault. Creation stays open; admission to
    ///      the shared pool is what governance now controls (审计问题 1/2 回复 §2).
    function test_attributePrincipal_revertsForNonWhitelistedVault() public {
        (address rogue, MockVault3 rogueMock) = _makeVault(attacker);
        rogueMock.setSettlement(settlement);
        mockSettlement.setOperator(rogue, attacker, true);
        vm.prank(attacker);
        pool.addVault(rogue);

        usdt.mint(payer, 1_000e6);
        vm.prank(payer);
        usdt.approve(address(pool), 1_000e6);
        vm.prank(payer);
        pool.repayPrincipal(1_000e6);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.VaultNotWhitelisted.selector, rogue));
        pool.attributePrincipal(rogue, 1_000e6);

        assertEq(pool.pending(rogue), 0, "no pending, so no inflated totalAssets()");
    }

    function test_attributeInterest_revertsForNonWhitelistedVault() public {
        vm.prank(governor);
        pool.setVaultWhitelisted(vault, false);

        usdt.mint(payer, 100e6);
        vm.prank(payer);
        usdt.approve(address(pool), 100e6);
        vm.prank(payer);
        pool.repayInterest(100e6);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.VaultNotWhitelisted.selector, vault));
        pool.attributeInterest(vault, 100e6);
    }

    /// @dev A whitelisted Vault may re-point `settlement()` at any time, so checking the Vault
    ///      alone would let it swap in an attacker-controlled Settlement and appoint arbitrary
    ///      Operators. Both halves are checked on every attribution (审计问题 1/2 回复 §3.3).
    function test_attributePrincipal_revertsWhenSettlementNotWhitelisted() public {
        MockSettlement3 rogueSettlement = new MockSettlement3();
        rogueSettlement.setOperator(vault, attacker, true);
        vaultMock.setSettlement(address(rogueSettlement));

        usdt.mint(payer, 500e6);
        vm.prank(payer);
        usdt.approve(address(pool), 500e6);
        vm.prank(payer);
        pool.repayPrincipal(500e6);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IUnifiedPool.SettlementNotWhitelisted.selector, address(rogueSettlement))
        );
        pool.attributePrincipal(vault, 500e6);
    }

    function test_distribute_revertsForNonWhitelistedVault() public {
        _fund(vault, 1_000e6);

        vm.prank(governor);
        pool.setVaultWhitelisted(vault, false);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.VaultNotWhitelisted.selector, vault));
        pool.distribute(vault, 100e6);
    }

    function test_distribute_revertsWhenSettlementDeWhitelisted() public {
        _fund(vault, 1_000e6);

        vm.prank(governor);
        pool.setSettlementWhitelisted(settlement, false);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IUnifiedPool.SettlementNotWhitelisted.selector, settlement));
        pool.distribute(vault, 100e6);
    }

    /// @dev Inflows stay permissionless: they only add real cash plus an unattributed record, and
    ///      credit no Vault's pending. The control sits on attribution and outflow instead
    ///      (审计问题 1/2 回复 §3.2).
    function test_repayPrincipal_staysPermissionlessForNonWhitelistedPayer() public {
        vm.prank(governor);
        pool.setVaultWhitelisted(vault, false);

        usdt.mint(attacker, 100e6);
        vm.prank(attacker);
        usdt.approve(address(pool), 100e6);
        vm.prank(attacker);
        pool.repayPrincipal(100e6);

        assertEq(pool.unattributedPrincipal(), 100e6);
        assertEq(pool.totalPending(), 0);
    }

    function test_setVaultWhitelisted_onlyGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(IUnifiedPool.NotGovernor.selector);
        pool.setVaultWhitelisted(vault, true);
    }

    function test_setSettlementWhitelisted_onlyGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(IUnifiedPool.NotGovernor.selector);
        pool.setSettlementWhitelisted(settlement, true);
    }

    /// @dev Several Settlement addresses may be trusted at once, so a new implementation can be
    ///      rolled out alongside the old one rather than in a flag-day cutover
    ///      (审计问题 1/2 回复 §3.1).
    function test_settlementWhitelist_holdsMultipleAddresses() public {
        MockSettlement3 next = new MockSettlement3();
        vm.prank(governor);
        pool.setSettlementWhitelisted(address(next), true);

        assertTrue(pool.settlementWhitelisted(settlement));
        assertTrue(pool.settlementWhitelisted(address(next)));
    }
}
