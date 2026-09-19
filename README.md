# HyperTessera Contracts

Public Solidity contracts for **HyperTessera Earn**, an on-chain structured-yield product backed
by real-world-asset (RWA) returns. Product tranches are ERC-4626 + ERC-7540 vaults. Off-chain
processes coordinate each cycle, and the contracts in this repository settle it on-chain.

This repository publishes the asset infrastructure, settlement, adapter, wrapped-asset and
governance layers, together with every interface and shared data structure. The Vault
implementations are closed source (see [Closed-source Vault scope](#closed-source-vault-scope)).

> **This repository does not contain `BaseVault`, `EarnVault`, `LiquidityEarnVault`,
> `VaultFactory` or their deployers, so it cannot deploy a complete HyperTessera Vault product on
> its own.**
>
> 本仓库不包含 BaseVault、EarnVault、LiquidityEarnVault、VaultFactory 及其部署器，因此不能独立部署完整的
> HyperTessera Vault 产品。

## Public modules

| Layer | Contracts | Path |
|---|---|---|
| Asset infrastructure | `AssetRegistry`, `RWAToken`, `MintBurnController`, `NAVOracle`, `PoRRegistry`, `ClaimRegistry`, `ProtocolFeeConfig` | `src/asset-infrastructure/` |
| Settlement | `Settlement`, `Queue`, `UnifiedPool`, `RevenuePool` | `src/asset-management/settlement/` |
| Adapters | `BaseAdapter`, `RWAAdapter`, `LiquidityAdapter`, `FirstPeriodAdapter`, `AdapterFactory`, `FirstPeriodAdapterDeployer` | `src/asset-management/adaptors/` |
| Product state | `StateManager` | `src/asset-management/StateManager.sol` |
| Liquidity bridge | `LiquidityBridge` | `src/asset-management/vaults/LiquidityBridge.sol` |
| Wrapped assets | `WrappedAsset`, `ReservePSM` | `src/wrapped-assets/` |
| Governance and permissions | `HyperAccessControl`, `VaultTimelock` | `src/governance/` |
| Interfaces | Every interface, including the Vault interfaces (`IBaseVault`, `IEarnVault`, `IVaultFactory`, `IVaultRoles`) and the deposit gate hook (`IGate`) | `src/interfaces/` |
| Shared data structures | `Types`, `Constants` | `src/libs/` |

A short description of each:

- **AssetRegistry** is a permissionless registry of tokenised RWAs. Each registration deploys a
  dedicated `RWAToken` and registers it with `MintBurnController` in the same transaction.
- **RWAToken** is a per-asset ERC-20 implementing a lightweight ERC-1400 subset (ERC-1594
  controller mint/burn plus transfer restrictions).
- **MintBurnController** enforces the Issuer + Token Agent process for minting and burning, scoped
  per asset.
- **NAVOracle** is a token-keyed price oracle that accepts EIP-712-signed NAV updates.
- **PoRRegistry** is an append-only ledger of Proof of Reserve documents.
- **ClaimRegistry** is an append-only record of vault requests left unclaimed past maturity.
- **ProtocolFeeConfig** is the Governor-controlled table of creation fees.
- **Settlement** turns an off-chain per-cycle FIFO selection into on-chain share and USDT
  movements, behind M-of-N signatures and pool-cash conservation checks.
- **Queue** is the on-chain FIFO anchor for deposit and redeem requests.
- **UnifiedPool** holds per-Vault USDT receivables and the shared cash pool.
- **RevenuePool** is the protocol fee sink.
- **BaseAdapter** and its concrete adapters are a Vault's execution, position-ledger and valuation
  module. `RWAAdapter` values an RWA token through `NAVOracle`.
- **StateManager** is the Product × Cycle × Pause state machine shared by all Vaults.
- **LiquidityBridge** deposits USDT from one Vault into another through the ERC-4626 deposit
  surface and returns the shares to the source Vault. It holds no shares itself.
- **ReservePSM** wraps restricted assets into freely transferable `WrappedAsset` ERC-20s and burns
  them on unwrap.
- **HyperAccessControl** is the protocol-global Governor role registry. **VaultTimelock** delay-
  queues Owner- and Curator-class parameter changes for one Vault.

## Closed-source Vault scope

These contracts stay in a private repository under a proprietary license:

- `BaseVault.sol`
- `EarnVault.sol`
- `LiquidityEarnVault.sol`
- `EarnVaultDeployer.sol`
- `LiquidityEarnVaultDeployer.sol`
- `VaultFactory.sol` (it depends directly on the two Vault deployers)

Also not published: the full Vault production deployment scripts, and all production keys, RPC,
relayer, keeper and multisig configuration.

The Vault interfaces in `src/interfaces/` are public, so integrators can build against the Vault
surface without the implementation.

## Repository layout

```text
src/                     public contracts, interfaces and shared libraries
test/public/             public module tests, run by CI
test-vault-reference/    Vault-related tests, published for reference only (not compiled)
script/                  size check and a deployment example for the non-Vault core
lib/                     forge-std and OpenZeppelin Contracts (git submodules)
```

### Tests

`test/public/` covers every module that can be exercised without a Vault, and CI runs all of it.

`test-vault-reference/` holds the tests that deploy a real `EarnVault`, `LiquidityEarnVault` or
`VaultFactory` as part of their fixture. That includes some suites for public modules
(`Settlement`, the adapters, `LiquidityBridge`, `VaultTimelock`) whose scenarios run through a
live Vault. They are published so the Vault's external behaviour and test requirements can be
read. They cannot compile here because the Vault sources are absent, so they sit outside every
directory Foundry compiles. See [`test-vault-reference/README.md`](test-vault-reference/README.md).

### Deployment example

`script/deploy/DeployCore.s.sol` deploys the contracts that do not depend on a Vault: access
control, the asset registry with its oracle and attestation contracts, the revenue pool and the
wrapped-asset PSM. Under the default `demo` profile it also deploys a mock USDT and demo assets:

```bash
anvil &
forge script script/deploy/DeployCore.s.sol --tc DeployCore --rpc-url http://127.0.0.1:8545 --broadcast --slow
# addresses are written to deployments/core.json
```

Without `TEST_PK` or `PRIVATE_KEY` the script signs with Anvil's first publicly known development
key, and it refuses to do so under `DEPLOY_PROFILE=production`.

## Build and test

Requirements:

| Tool | Version |
|---|---|
| Solidity | `0.8.24`, `via_ir = true`, optimizer 200 runs (see `foundry.toml`) |
| Foundry | `v1.7.1` (the version CI pins) |
| forge-std | `v1.16.1` |
| OpenZeppelin Contracts | `v5.1.0` |

```bash
git clone --recurse-submodules https://github.com/capitalchuan/HyperTessera-Contracts.git
cd HyperTessera-Contracts

forge build
forge test
forge fmt --check
script/check-sizes.sh     # EIP-170 contract size check
```

Run one suite or one test:

```bash
forge test --match-path test/public/UnifiedPool.t.sol -vvv
forge test --match-test test_deployProfileRules -vvv
```

## License

- HyperTessera's original code in this repository (`src/`, `test/`, `test-vault-reference/`,
  `script/`) is licensed under the [PolyForm Shield License 1.0.0](LICENSE). You may use, change
  and distribute it for any purpose except providing a product that competes with HyperTessera.
  Solidity files carry `SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0`. PolyForm
  Shield is not on the SPDX license list, so the identifier uses the `LicenseRef-` form.
- Third-party dependencies under `lib/` keep their own licenses: forge-std is MIT or Apache-2.0,
  and OpenZeppelin Contracts is MIT.
- The closed-source Vault contracts are not covered by this license. They remain proprietary.

## Security

Please do **not** report security vulnerabilities through public issues, discussions or pull
requests. See [SECURITY.md](SECURITY.md) for how to report one privately.
