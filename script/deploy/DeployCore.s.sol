// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {DeployConfig} from "./DeployConfig.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";
import {AssetRegistry} from "../../src/asset-infrastructure/AssetRegistry.sol";
import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {ProtocolFeeConfig} from "../../src/asset-infrastructure/ProtocolFeeConfig.sol";
import {NAVOracle} from "../../src/asset-infrastructure/NAVOracle.sol";
import {MintBurnController} from "../../src/asset-infrastructure/MintBurnController.sol";
import {PoRRegistry} from "../../src/asset-infrastructure/PoRRegistry.sol";
import {ReservePSM} from "../../src/wrapped-assets/ReservePSM.sol";
import {IReservePSM} from "../../src/interfaces/IReservePSM.sol";
import {Queue} from "../../src/asset-management/settlement/Queue.sol";
import {RevenuePool} from "../../src/asset-management/settlement/RevenuePool.sol";
import {AdapterFactory} from "../../src/asset-management/adaptors/AdapterFactory.sol";
import {IAdapterFactory} from "../../src/interfaces/IAdapterFactory.sol";
import {FeePaymentKind} from "../../src/libs/Types.sol";
import {StubStateManager} from "./testing/StubStateManager.sol";
import {MockUSDT} from "./testing/MockUSDT.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title DeployCore — stage 1 of 4: governance, asset infrastructure, revenue
/// @notice Deploys the contracts that have no dependency on a live Vault: access control, the
///         asset registry and its valuation/attestation surface, the revenue pool, and the
///         wrapped-asset PSM. Under the `demo` profile it additionally deploys Mock USDT, two
///         demo assets and a demo RWA adapter so a testnet has something to exercise.
///
///         Usage:
///           forge script script/deploy/DeployCore.s.sol --tc DeployCore \
///             --rpc-url <rpc> --broadcast [--legacy --slow]
///
///         Inputs (env):
///           DEPLOY_PROFILE   demo (default) | production
///           TEST_PK / PRIVATE_KEY  deployer key; required under `production`
///           USDT             optional under `demo` (reuses an existing Mock USDT across
///                            redeploys so test-wallet balances survive); REQUIRED under
///                            `production`, where it must name the real settlement token
///           TOKEN_AGENT      demo assets' Token Agent (demo profile only)
///           NAV_SIGNER       demo asset's NAV signer (demo profile only)
///
///         Output: deployments/core.json
///
/// @dev    ClaimRegistry, UnifiedPool and the real Queue are deliberately NOT deployed here. Each
///         binds its StateManager once — at construction (ClaimRegistry, Queue) or in
///         `initialize()` (UnifiedPool) — with no setter, so one built against `StubStateManager`
///         would reject every real Vault for the life of the deployment. They belong to the vaults
///         stage, alongside the real StateManager.
contract DeployCore is DeployConfig {
    address internal governor;
    HyperAccessControl internal ac;
    StubStateManager internal stub;
    AssetRegistry internal registry;
    ProtocolFeeConfig internal feeConfig;
    MintBurnController internal mbc;
    NAVOracle internal nav;
    PoRRegistry internal por;
    MockUSDT internal usdt;
    RevenuePool internal revenuePool;
    Queue internal queue;
    ReservePSM internal psm;
    AdapterFactory internal adapterFactory;

    // Demo-profile only.
    address internal sToken;
    address internal jToken;
    address internal rwaAdapter;

    function run() external {
        uint256 pk = _deployerKey();
        governor = vm.addr(pk);
        _logProfile("core");

        vm.startBroadcast(pk);

        ac = new HyperAccessControl(governor);

        // Settlement token. Under `demo`, `USDT` may name an already-deployed Mock USDT to carry
        // across a redeploy: the token is a standalone ERC-20 with an open `mint` and holds no
        // reference to any protocol contract, so reusing one preserves test-wallet balances
        // instead of zeroing them on every redeploy. Unset deploys a fresh one.
        usdt = MockUSDT(_settlementToken());
        revenuePool = new RevenuePool(address(usdt), address(ac));

        feeConfig = new ProtocolFeeConfig(address(ac), address(revenuePool));
        registry = new AssetRegistry(address(feeConfig)); // deploys and owns its MintBurnController
        mbc = MintBurnController(registry.mintBurnController());
        nav = new NAVOracle(governor, 2000);
        por = new PoRRegistry(address(registry));

        // Independent asset wrap/unwrap module (no Vault or Settlement coupling).
        psm = new ReservePSM(address(ac));

        if (_isDemo()) {
            _deployDemoAssets();
        }

        vm.stopBroadcast();

        _writeOutput();
    }

    /// @dev `production` requires a real token; `demo` reuses `USDT` if given, else mints a mock.
    function _settlementToken() internal returns (address) {
        if (!_isDemo()) return _requiredAddr("USDT");
        address existing = vm.envOr("USDT", address(0));
        return existing == address(0) ? address(new MockUSDT()) : existing;
    }

    /// @dev Everything in here exists so a testnet has something to click on. None of it is
    ///      deployed under the `production` profile: each issuer registers its own assets
    ///      through `AssetRegistry`, and `StubStateManager` plus the Queue bound to it are
    ///      superseded by the vaults stage's real StateManager and Queue.
    function _deployDemoAssets() internal {
        stub = new StubStateManager(address(ac));
        queue = new Queue(address(stub));

        IAssetRegistry.ProductInfo memory demoProduct = IAssetRegistry.ProductInfo({
            productName: "Demo Note",
            annualYieldRateBps: 500,
            maturityTimestamp: 1790000000,
            issuer: address(0),
            underlyingAsset: "US Treasury Bill"
        });
        // Each call deploys a dedicated RWAToken ERC-20.
        (, sToken) = registry.registerAsset(
            keccak256("DEMO-S-ASSET"), "S Token", "S-TKN", 6, FeePaymentKind.Native, demoProduct
        ); // id 1
        (, jToken) = registry.registerAsset(
            keccak256("DEMO-J-ASSET"), "J Token", "J-TKN", 6, FeePaymentKind.Native, demoProduct
        ); // id 2

        // Wrapped Asset for demo asset 1 (S Token), Token Custody Mode backed by USDT.
        // TOKEN_CUSTODY wraps 1:1 on the raw amount, so the wrapper must declare the same
        // decimals as its backing token — 6 for the Mock USDT this profile normally mints, 18
        // when `USDT` names an 18-decimal token such as BSC mainnet USDT.
        psm.deployWrappedToken(
            1,
            IReservePSM.AssetMode.TOKEN_CUSTODY,
            address(usdt),
            "Wrapped S Token",
            "wS-TKN",
            IERC20Metadata(address(usdt)).decimals(),
            true
        );

        // Demo of the RWA valuation path: sToken stands in for an externally-issued RWA Token.
        adapterFactory = new AdapterFactory();
        rwaAdapter = adapterFactory.deployRWAAdapter(
            IAdapterFactory.RWAAdapterParams({
                asset: address(usdt),
                vault: governor,
                rwaToken: sToken,
                navOracle: address(nav),
                dealDataStalenessWindow: 36 hours
            })
        );

        // Under the Vault-local RBAC model, Curator/Guardian/Allocator/Keeper/Settlement Operator
        // only exist once a Vault does — they are granted by the vaults and post-config stages.
        // Issuer is simply each asset's AssetRegistry owner (this deployer, which called
        // registerAsset). Only the asset-local Token Agent and NAV signer are wired here.
        address tokenAgent = _roleAddr("TOKEN_AGENT", ANVIL_4, governor);
        address navSigner = _roleAddr("NAV_SIGNER", ANVIL_5, governor);
        mbc.setTokenAgent(1, tokenAgent);
        mbc.setTokenAgent(2, tokenAgent);
        nav.setSigner(sToken, navSigner);
    }

    function _writeOutput() internal {
        string memory a = "addresses";
        vm.serializeAddress(a, "HyperAccessControl", address(ac));
        vm.serializeAddress(a, "AssetRegistry", address(registry));
        vm.serializeAddress(a, "ProtocolFeeConfig", address(feeConfig));
        vm.serializeAddress(a, "MintBurnController", address(mbc));
        vm.serializeAddress(a, "NAVOracle", address(nav));
        vm.serializeAddress(a, "PoRRegistry", address(por));
        vm.serializeAddress(a, "ReservePSM", address(psm));
        vm.serializeAddress(a, "Queue", address(queue));
        vm.serializeAddress(a, "RevenuePool", address(revenuePool));
        vm.serializeAddress(a, "MockUSDT", address(usdt));
        vm.serializeAddress(a, "StubStateManager", address(stub));
        vm.serializeAddress(a, "SToken", sToken);
        vm.serializeAddress(a, "JToken", jToken);
        // RWAToken key kept for backwards-compat — points at the demo S Token.
        vm.serializeAddress(a, "RWAToken", sToken);
        string memory addrs = vm.serializeAddress(a, "RWAAdapter", rwaAdapter);

        string memory r = "roles";
        vm.serializeAddress(r, "GOVERNOR", governor);
        vm.serializeAddress(r, "ISSUER", governor);
        vm.serializeAddress(r, "TOKEN_AGENT", _isDemo() ? _roleAddr("TOKEN_AGENT", ANVIL_4, governor) : address(0));
        string memory roles =
            vm.serializeAddress(r, "NAV_SIGNER", _isDemo() ? _roleAddr("NAV_SIGNER", ANVIL_5, governor) : address(0));

        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "addresses", addrs);
        string memory out = vm.serializeString(root, "roles", roles);

        vm.writeJson(out, "./deployments/core.json");
    }
}
