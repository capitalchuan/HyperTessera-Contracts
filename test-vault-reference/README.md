# Vault reference tests

These Foundry tests deploy a real `EarnVault`, `LiquidityEarnVault` or `VaultFactory`, or the
closed Vault deployment script, as part of their fixture. The Vault sources are not in this
repository, so **these files do not compile here**. They sit outside every directory Foundry
compiles (`foundry.toml` sets `test = "test/public"`), and CI does not run them.

They are published so readers can see the Vault's external behaviour and the requirements its
implementation is tested against. They are not a runnable suite.

| File | What it covers |
|---|---|
| `EarnVault.t.sol` | Cash / Note Vault lifecycle, settlement, fees, caps, liquidation and final redemption |
| `LiquidityEarnVault.t.sol` | Liquidity Vault and its bridge into the Cash Vault |
| `VaultFactory.t.sol` | Vault creation, fees and registration |
| `VaultAdapterFunding.t.sol` | Moving capital between a Vault and its Adapter |
| `SettlementTokenDecimals.t.sol` | Vault share pricing with 6- and 18-decimal settlement tokens |
| `Settlement.t.sol` | `Settlement` batches executed against a live Vault |
| `SettlementOrdering.t.sol` | Ordering of settlement legs across Cash and Liquidity Vaults |
| `BaseAdapter.t.sol`, `RWAAdapter.t.sol`, `LiquidityAdapter.t.sol` | Adapters bound to a live Vault |
| `LiquidityBridge.t.sol` | `LiquidityBridge` between two live Vaults |
| `VaultTimelock.t.sol` | `VaultTimelock` bound to a live Vault |
| `KYTDepositGateway.t.sol` | `KYTDepositGateway` fronting a live Vault's subscription path |
| `DeployVault.t.sol`, `DeployVaultInputs.t.sol` | Wiring and inputs of the closed Vault deployment stage |

`Settlement`, the adapters, `LiquidityBridge`, `VaultTimelock` and `KYTDepositGateway` are public
contracts, but every scenario in their suites runs through a Vault, so the suites live here.

The imports resolve from this directory as they stand. With the Vault sources in
`src/asset-management/vaults/` and, for the deployment tests, `script/deploy/DeployVault.s.sol`,
`FOUNDRY_TEST=test-vault-reference forge test` runs them unchanged.
