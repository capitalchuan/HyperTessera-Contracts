# Contributing

Thank you for your interest in HyperTessera Contracts.

## How changes reach this repository

`src/`, `test/`, `test-vault-reference/` and `script/` are exported from HyperTessera's internal
development repository, which also holds the closed-source Vault contracts. A pull request that
touches these directories is reviewed here. If it is accepted, the change is applied upstream
and arrives here in the next export, and the pull request is closed with a link to that commit.
Changes to the other files (README, CI and so on) are merged here directly.

## Before opening a pull request

Run the same checks as CI:

```bash
forge fmt --check src test script test-vault-reference
forge build
script/check-sizes.sh
forge test
```

- Tests for public modules go in `test/public/` and must compile without the Vault sources.
- A test that needs a real Vault goes in `test-vault-reference/`. Nothing there is compiled.
- New Solidity files carry `// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0`.
- Never commit private keys, mnemonics, `.env` files, RPC URLs with API keys, or production
  addresses.

## Review

Every pull request into `main` needs passing CI and an approving review from a code owner
(see `CODEOWNERS`).

## License

Contributions are accepted under the repository's license (see `LICENSE`).

Report security issues privately as described in `SECURITY.md`, not in a pull request.
