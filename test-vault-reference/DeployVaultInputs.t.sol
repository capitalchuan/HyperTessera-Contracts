// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployVault} from "../script/deploy/DeployVault.s.sol";

/// @dev Exposes DeployVault's input resolution without running a broadcast.
contract DeployVaultHarness is DeployVault {
    function sharedFor(string memory kindName) external returns (Shared memory) {
        vm.setEnv("VAULT_KIND", kindName);
        kind = _kind();
        return _shared();
    }
}

/// @title DeployVaultInputsTest
/// @notice Each Vault kind must validate only the shared addresses it actually uses. A Note vault
///         blocked on a LiquidityBridge it never touches, or an LP vault that silently deploys
///         with no Cash vault to bridge into, are both deployment-time failures this pins down.
///
/// @dev    One test function, for the same `vm.setEnv` reason as DeployConfigTest (test/public/DeployConfig.t.sol).
contract DeployVaultInputsTest is Test {
    DeployVaultHarness internal h;

    address internal shared = makeAddr("shared");
    address internal bridge = makeAddr("bridge");
    address internal cash = makeAddr("cash");

    function setUp() public {
        h = new DeployVaultHarness();
        vm.setEnv("DEPLOY_PROFILE", "demo");
        // Everything every kind needs.
        for (uint256 i = 0; i < 8; i++) {
            vm.setEnv(_alwaysRequired(i), vm.toString(shared));
        }
        vm.setEnv("LIQUIDITY_BRIDGE", "");
        vm.setEnv("CASH_VAULT", "");
    }

    function _alwaysRequired(uint256 i) internal pure returns (string memory) {
        string[8] memory names = [
            "STATE_MANAGER",
            "QUEUE",
            "UNIFIED_POOL",
            "SETTLEMENT",
            "ADAPTER_FACTORY",
            "VAULT_FACTORY",
            "CLAIM_REGISTRY",
            "USDT"
        ];
        return names[i];
    }

    function test_perKindRequiredInputs() public {
        // --- note: needs neither the bridge nor a cash vault ---------------------------------
        DeployVault.Shared memory n = h.sharedFor("note");
        assertEq(n.stateManager, shared);
        assertEq(n.liquidityBridge, address(0), "a note vault must not demand a LiquidityBridge");
        assertEq(n.cashVault, address(0), "a note vault must not demand a CashVault");

        // --- cash: needs the bridge, not a cash vault ----------------------------------------
        vm.expectRevert("deploy: missing required env var LIQUIDITY_BRIDGE");
        h.sharedFor("cash");

        vm.setEnv("LIQUIDITY_BRIDGE", vm.toString(bridge));
        DeployVault.Shared memory c = h.sharedFor("cash");
        assertEq(c.liquidityBridge, bridge);
        assertEq(c.cashVault, address(0), "a cash vault must not demand another CashVault");

        // --- lp: needs both -------------------------------------------------------------------
        vm.expectRevert("deploy: missing required env var CASH_VAULT");
        h.sharedFor("lp");

        vm.setEnv("CASH_VAULT", vm.toString(cash));
        DeployVault.Shared memory l = h.sharedFor("lp");
        assertEq(l.liquidityBridge, bridge);
        assertEq(l.cashVault, cash, "an lp vault bridges into a named cash vault");

        // --- an unknown kind is refused, not silently treated as one of the three -------------
        vm.expectRevert("deploy: VAULT_KIND must be 'cash', 'note' or 'lp'");
        h.sharedFor("senior");
    }
}
