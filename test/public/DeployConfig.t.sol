// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployConfig} from "../../script/deploy/DeployConfig.sol";

/// @dev Exposes DeployConfig's internal helpers so the env-handling rules can be asserted
///      directly. The four stage scripts differ only in what they deploy — every one of them
///      reads its inputs through these helpers, so covering them covers all four.
contract DeployConfigHarness is DeployConfig {
    function profileIsDemo() external view returns (bool) {
        return _isDemo();
    }

    function deployerKey() external view returns (uint256) {
        return _deployerKey();
    }

    function requiredAddr(string memory n) external view returns (address) {
        return _requiredAddr(n);
    }

    function requiredUint(string memory n) external view returns (uint256) {
        return _requiredUint(n);
    }

    function roleAddr(string memory n, address anvilAcct, address deployer) external view returns (address) {
        return _roleAddr(n, anvilAcct, deployer);
    }
}

/// @title DeployConfigTest
/// @notice The deploy profile is what keeps a production deployment from silently pointing every
///         role at the deploy wallet, so it is asserted rather than assumed.
///
/// @dev    Deliberately ONE test function. `vm.setEnv` mutates the forge process's environment,
///         which is shared by every test in the run — split across several functions these
///         assertions race each other and fail at random. Kept sequential instead.
contract DeployConfigTest is Test {
    uint256 internal constant ANVIL_PK0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    DeployConfigHarness internal cfg;

    address internal deployer = makeAddr("deployer");
    address internal anvilAcct = makeAddr("anvilAcct");
    address internal named = makeAddr("named");

    function setUp() public {
        cfg = new DeployConfigHarness();
    }

    function test_deployProfileRules() public {
        // --- Profile parsing -------------------------------------------------------------
        // An unset or empty DEPLOY_PROFILE must mean demo, never production: the local and
        // testnet flows never set it, and the whole fallback behaviour hangs off this.
        vm.setEnv("DEPLOY_PROFILE", "");
        assertTrue(cfg.profileIsDemo(), "empty profile should be demo");

        vm.setEnv("DEPLOY_PROFILE", "demo");
        assertTrue(cfg.profileIsDemo(), "demo profile");

        vm.setEnv("DEPLOY_PROFILE", "staging");
        vm.expectRevert("deploy: DEPLOY_PROFILE must be 'demo' or 'production'");
        cfg.profileIsDemo();

        // --- Missing variables name themselves -------------------------------------------
        vm.setEnv("DEPLOY_PROFILE", "demo");
        vm.expectRevert("deploy: missing required env var HT_TEST_ABSENT_ADDR");
        cfg.requiredAddr("HT_TEST_ABSENT_ADDR");

        vm.expectRevert("deploy: missing required env var HT_TEST_ABSENT_UINT");
        cfg.requiredUint("HT_TEST_ABSENT_UINT");

        // --- Demo profile: roles fall back -------------------------------------------------
        vm.chainId(97);
        assertEq(cfg.roleAddr("HT_TEST_ROLE_A", anvilAcct, deployer), deployer, "off-Anvil fallback is the deployer");

        vm.chainId(31337);
        assertEq(cfg.roleAddr("HT_TEST_ROLE_A", anvilAcct, deployer), anvilAcct, "on Anvil, the Anvil account");

        vm.setEnv("HT_TEST_ROLE_A", vm.toString(named));
        assertEq(cfg.roleAddr("HT_TEST_ROLE_A", anvilAcct, deployer), named, "an explicit address always wins");

        // --- Production profile: nothing falls back ----------------------------------------
        // This is the reason the profile exists. A forgotten variable must abort the deploy, not
        // quietly hand the role to the deploy wallet.
        vm.setEnv("DEPLOY_PROFILE", "production");
        vm.expectRevert("deploy: missing required env var HT_TEST_ROLE_B");
        cfg.roleAddr("HT_TEST_ROLE_B", anvilAcct, deployer);

        assertEq(cfg.roleAddr("HT_TEST_ROLE_A", anvilAcct, deployer), named, "an explicit address is accepted");

        // Anvil's account 0 is a publicly known key; falling back to it on a real network would
        // hand the protocol to whoever noticed.
        vm.setEnv("TEST_PK", "0");
        vm.setEnv("PRIVATE_KEY", "0");
        vm.expectRevert("deploy: production profile requires TEST_PK or PRIVATE_KEY (no Anvil fallback)");
        cfg.deployerKey();

        vm.setEnv("DEPLOY_PROFILE", "demo");
        assertEq(cfg.deployerKey(), ANVIL_PK0, "demo still bootstraps off Anvil account 0");
    }
}
