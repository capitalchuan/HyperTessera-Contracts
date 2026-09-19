// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployConfig
/// @notice Shared environment handling for the four deploy stages.
///
///         Every stage script inherits this so that the deployer key, the deploy profile and the
///         "this address is required" rule are resolved identically everywhere. Stage scripts
///         differ only in what they deploy, never in how they read their inputs.
///
/// @dev    `DEPLOY_PROFILE` selects between two behaviours:
///
///           demo (default) — local Anvil and public testnets. Mock USDT, the two demo assets and
///             the demo RWA adapter are deployed, and any role address left unset falls back to
///             the deployer (or, on chain 31337, to the matching deterministic Anvil account).
///
///           production — a real deployment. No mocks and no demo assets are deployed, `USDT`
///             must name a real token, and every role address must be supplied explicitly: an
///             unset one aborts the stage instead of silently pointing at the deploy wallet.
abstract contract DeployConfig is Script {
    /// @dev Anvil's first account (mnemonic "test test … junk"), used only when no key is given.
    uint256 internal constant ANVIL_PK0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Deterministic Anvil accounts, used as demo-profile role fallbacks on chain 31337 only.
    address internal constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // curator
    address internal constant ANVIL_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // guardian
    address internal constant ANVIL_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // issuer
    address internal constant ANVIL_4 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65; // tokenAgent
    address internal constant ANVIL_5 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc; // nav signer
    address internal constant ANVIL_6 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9; // data provider
    address internal constant ANVIL_7 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955; // compliance

    uint256 internal constant ANVIL_CHAIN_ID = 31337;

    enum Profile {
        Demo,
        Production
    }

    /// @notice The deploy wallet's private key: `TEST_PK`, else `PRIVATE_KEY`, else Anvil account 0.
    /// @dev    The Anvil fallback is refused outside the demo profile — a production deployment
    ///         signed by a publicly known key would hand the protocol to anyone.
    function _deployerKey() internal view returns (uint256 pk) {
        pk = vm.envOr("TEST_PK", vm.envOr("PRIVATE_KEY", uint256(0)));
        if (pk == 0) {
            require(
                _profile() == Profile.Demo,
                "deploy: production profile requires TEST_PK or PRIVATE_KEY (no Anvil fallback)"
            );
            pk = ANVIL_PK0;
        }
    }

    function _profile() internal view returns (Profile) {
        string memory raw = vm.envOr("DEPLOY_PROFILE", string("demo"));
        bytes32 h = keccak256(bytes(raw));
        // An empty value is an unset one: a network file may legitimately carry a bare
        // `DEPLOY_PROFILE=` line, and that must not be louder than the default.
        if (bytes(raw).length == 0 || h == keccak256("demo")) return Profile.Demo;
        if (h == keccak256("production")) return Profile.Production;
        revert("deploy: DEPLOY_PROFILE must be 'demo' or 'production'");
    }

    function _isDemo() internal view returns (bool) {
        return _profile() == Profile.Demo;
    }

    /// @notice Reads a mandatory address, failing with the variable's name rather than forge's
    ///         generic "environment variable not found".
    function _requiredAddr(string memory name) internal view returns (address a) {
        a = vm.envOr(name, address(0));
        require(a != address(0), string.concat("deploy: missing required env var ", name));
    }

    function _requiredUint(string memory name) internal view returns (uint256 v) {
        require(vm.envExists(name), string.concat("deploy: missing required env var ", name));
        v = vm.envUint(name);
    }

    /// @notice Resolves a role address.
    /// @dev    Production: `name` must be set. Demo: `name` if set, otherwise `anvilAcct` on chain
    ///         31337 and the deployer everywhere else — which is what keeps a single-wallet testnet
    ///         bring-up working without a dozen exported variables.
    function _roleAddr(string memory name, address anvilAcct, address deployer) internal view returns (address) {
        if (!_isDemo()) return _requiredAddr(name);
        address configured = vm.envOr(name, address(0));
        if (configured != address(0)) return configured;
        return block.chainid == ANVIL_CHAIN_ID ? anvilAcct : deployer;
    }

    /// @dev Demo-profile role resolution with no distinct Anvil account — falls back to the deployer.
    function _roleAddr(string memory name, address deployer) internal view returns (address) {
        return _roleAddr(name, deployer, deployer);
    }

    function _logProfile(string memory stage) internal view {
        console2.log(
            string.concat(
                "[", stage, "] profile=", _isDemo() ? "demo" : "production", " chainId=", vm.toString(block.chainid)
            )
        );
    }
}
