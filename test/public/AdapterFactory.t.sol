// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AdapterFactory} from "../../src/asset-management/adaptors/AdapterFactory.sol";
import {IAdapterFactory} from "../../src/interfaces/IAdapterFactory.sol";
import {LiquidityAdapter} from "../../src/asset-management/adaptors/LiquidityAdapter.sol";
import {RWAAdapter} from "../../src/asset-management/adaptors/RWAAdapter.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("MockUSDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AdapterFactoryTest is Test {
    MockUSDT internal usdt;
    AdapterFactory internal factory;

    address internal attacker = makeAddr("attacker");
    address internal cashVaultStandIn = makeAddr("cashVault");
    address internal noteVaultStandIn = makeAddr("noteVault");
    address internal lpVaultStandIn = makeAddr("lpVault");
    address internal navOracleStandIn = makeAddr("navOracle");
    address internal rwaTokenStandIn = makeAddr("rwaToken");

    function setUp() public {
        usdt = new MockUSDT();
        factory = new AdapterFactory();
    }

    function _params(address vault) internal view returns (IAdapterFactory.AdapterParams memory) {
        return IAdapterFactory.AdapterParams({asset: address(usdt), vault: vault, stalenessWindow: 36 hours});
    }

    // -----------------------------------------------------------------------
    // deployAdapter — permissionless (the old Governor-only gate and NotGovernor
    // error were removed from IAdapterFactory; deploying grants no Vault authority by itself).
    // -----------------------------------------------------------------------

    function test_deployAdapter_permissionless_anyCallerSucceeds() public {
        vm.prank(attacker);
        address adapter = factory.deployAdapter(_params(cashVaultStandIn));
        assertTrue(factory.isAdapter(adapter));
    }

    function test_deployAdapter_happyPath() public {
        address adapter = factory.deployAdapter(_params(cashVaultStandIn));
        assertTrue(factory.isAdapter(adapter));
    }

    function test_deployAdapter_twoCallsDifferentVaults_produceIndependentAdapters() public {
        address cashAdapter = factory.deployAdapter(_params(cashVaultStandIn));
        address noteAdapter = factory.deployAdapter(_params(noteVaultStandIn));

        assertTrue(cashAdapter != noteAdapter);
        assertTrue(factory.isAdapter(cashAdapter));
        assertTrue(factory.isAdapter(noteAdapter));
    }

    // -----------------------------------------------------------------------
    // deployLiquidityAdapter — permissionless
    // -----------------------------------------------------------------------

    function test_deployLiquidityAdapter_permissionless_anyCallerSucceeds() public {
        vm.prank(attacker);
        address adapter = factory.deployLiquidityAdapter(_params(lpVaultStandIn));
        assertTrue(factory.isAdapter(adapter));
    }

    function test_deployLiquidityAdapter_happyPath_bridgeTargetsZero() public {
        address adapter = factory.deployLiquidityAdapter(_params(lpVaultStandIn));

        assertTrue(factory.isAdapter(adapter));
        assertEq(LiquidityAdapter(adapter).liquidityBridge(), address(0));
        assertEq(LiquidityAdapter(adapter).cashVault(), address(0));
    }

    function test_isAdapter_trueForBothTypes() public {
        address fpa = factory.deployAdapter(_params(cashVaultStandIn));
        address lqa = factory.deployLiquidityAdapter(_params(lpVaultStandIn));

        assertTrue(factory.isAdapter(fpa));
        assertTrue(factory.isAdapter(lqa));
        assertFalse(factory.isAdapter(attacker));
    }

    function test_deployAdapter_invalidParams_reverts() public {
        vm.expectRevert(IAdapterFactory.InvalidAdapterParams.selector);
        factory.deployAdapter(_params(address(0)));
    }

    function _rwaParams(address vault) internal view returns (IAdapterFactory.RWAAdapterParams memory) {
        return IAdapterFactory.RWAAdapterParams({
            asset: address(usdt),
            vault: vault,
            rwaToken: rwaTokenStandIn,
            navOracle: navOracleStandIn,
            dealDataStalenessWindow: 36 hours
        });
    }

    // -----------------------------------------------------------------------
    // deployRWAAdapter — permissionless
    // -----------------------------------------------------------------------

    function test_deployRWAAdapter_permissionless_anyCallerSucceeds() public {
        vm.prank(attacker);
        address adapter = factory.deployRWAAdapter(_rwaParams(cashVaultStandIn));
        assertTrue(factory.isAdapter(adapter));
    }

    function test_deployRWAAdapter_happyPath_setsImmutables() public {
        address adapter = factory.deployRWAAdapter(_rwaParams(cashVaultStandIn));

        assertTrue(factory.isAdapter(adapter));
        assertEq(RWAAdapter(adapter).rwaToken(), rwaTokenStandIn);
        assertEq(RWAAdapter(adapter).navOracle(), navOracleStandIn);
        assertEq(RWAAdapter(adapter).vault(), cashVaultStandIn);
    }

    function test_deployRWAAdapter_zeroRwaToken_reverts() public {
        IAdapterFactory.RWAAdapterParams memory params = _rwaParams(cashVaultStandIn);
        params.rwaToken = address(0);
        vm.expectRevert(IAdapterFactory.InvalidAdapterParams.selector);
        factory.deployRWAAdapter(params);
    }

    function test_deployRWAAdapter_zeroNavOracle_reverts() public {
        IAdapterFactory.RWAAdapterParams memory params = _rwaParams(cashVaultStandIn);
        params.navOracle = address(0);
        vm.expectRevert(IAdapterFactory.InvalidAdapterParams.selector);
        factory.deployRWAAdapter(params);
    }

    function test_isAdapter_trueForAllThreeTypes() public {
        address fpa = factory.deployAdapter(_params(cashVaultStandIn));
        address lqa = factory.deployLiquidityAdapter(_params(lpVaultStandIn));
        address rwa = factory.deployRWAAdapter(_rwaParams(noteVaultStandIn));

        assertTrue(factory.isAdapter(fpa));
        assertTrue(factory.isAdapter(lqa));
        assertTrue(factory.isAdapter(rwa));
    }

    // -----------------------------------------------------------------------
    // Adapter index — enumeration
    // -----------------------------------------------------------------------
    // `isAdapter` answers "did this factory deploy that address?" but cannot answer "what has
    // this factory deployed?". The index below is the enumerable counterpart, so a caller can
    // list every adapter with eth_call alone instead of crawling AdapterDeployed logs over a
    // bounded block window that silently loses anything older than the window.

    function test_adapterCount_isZeroBeforeAnyDeployment() public view {
        assertEq(factory.adapterCount(), 0);
        assertEq(factory.adapterCountForVault(cashVaultStandIn), 0);
    }

    function test_adapterIndex_growsAcrossAllThreeDeployFunctions() public {
        address fpa = factory.deployAdapter(_params(cashVaultStandIn));
        address lqa = factory.deployLiquidityAdapter(_params(lpVaultStandIn));
        address rwa = factory.deployRWAAdapter(_rwaParams(noteVaultStandIn));

        assertEq(factory.adapterCount(), 3);
        assertEq(factory.adapterAt(0), fpa);
        assertEq(factory.adapterAt(1), lqa);
        assertEq(factory.adapterAt(2), rwa);
    }

    function test_adapterAt_revertsPastTheEnd() public {
        factory.deployAdapter(_params(cashVaultStandIn));

        vm.expectRevert();
        factory.adapterAt(1);
    }

    function test_adaptersPaged_returnsTheRequestedWindow() public {
        factory.deployAdapter(_params(cashVaultStandIn));
        address second = factory.deployAdapter(_params(cashVaultStandIn));
        address third = factory.deployLiquidityAdapter(_params(lpVaultStandIn));

        address[] memory page = factory.adaptersPaged(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], second);
        assertEq(page[1], third);
    }

    /// @dev A caller paging blind must not have to know the length to avoid reverting.
    function test_adaptersPaged_clampsALimitThatOverrunsTheEnd() public {
        factory.deployAdapter(_params(cashVaultStandIn));
        address second = factory.deployAdapter(_params(cashVaultStandIn));

        address[] memory page = factory.adaptersPaged(1, type(uint256).max);
        assertEq(page.length, 1);
        assertEq(page[0], second);
    }

    function test_adaptersPaged_returnsEmptyWhenOffsetIsAtOrPastTheEnd() public {
        factory.deployAdapter(_params(cashVaultStandIn));

        assertEq(factory.adaptersPaged(1, 10).length, 0);
        assertEq(factory.adaptersPaged(99, 10).length, 0);
    }

    // -----------------------------------------------------------------------
    // Adapter index — per vault
    // -----------------------------------------------------------------------

    function test_perVaultIndex_segregatesTwoVaults() public {
        address cashOne = factory.deployAdapter(_params(cashVaultStandIn));
        address noteOne = factory.deployAdapter(_params(noteVaultStandIn));
        address cashTwo = factory.deployRWAAdapter(_rwaParams(cashVaultStandIn));

        assertEq(factory.adapterCountForVault(cashVaultStandIn), 2);
        assertEq(factory.adapterCountForVault(noteVaultStandIn), 1);

        address[] memory cash = factory.adaptersForVaultPaged(cashVaultStandIn, 0, 10);
        assertEq(cash.length, 2);
        assertEq(cash[0], cashOne);
        assertEq(cash[1], cashTwo);

        address[] memory note = factory.adaptersForVaultPaged(noteVaultStandIn, 0, 10);
        assertEq(note.length, 1);
        assertEq(note[0], noteOne);

        // The global index still holds all three, in deployment order.
        assertEq(factory.adapterCount(), 3);
    }

    function test_adaptersForVaultPaged_clampsLikeTheGlobalPage() public {
        factory.deployAdapter(_params(cashVaultStandIn));
        address second = factory.deployLiquidityAdapter(_params(cashVaultStandIn));

        address[] memory page = factory.adaptersForVaultPaged(cashVaultStandIn, 1, type(uint256).max);
        assertEq(page.length, 1);
        assertEq(page[0], second);

        assertEq(factory.adaptersForVaultPaged(cashVaultStandIn, 2, 10).length, 0);
        assertEq(factory.adaptersForVaultPaged(cashVaultStandIn, 99, 10).length, 0);
    }

    function test_adaptersForVaultPaged_isEmptyForAVaultWithNoAdapters() public {
        assertEq(factory.adaptersForVaultPaged(makeAddr("neverUsed"), 0, 10).length, 0);
    }
}
