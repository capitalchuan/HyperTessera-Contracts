// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IUnifiedPool
/// @notice Per-Vault USDT receivable ledger and real-cash pool. Manages vault registration
///         (by each Vault's own Owner), real USDT inflows (interest/principal/
///         note-routing — permissionless, any real payer), Settlement-driven distribution (each
///         Vault's own bound Settlement contract only), and Governor-directed third-party
///         transfers. Attribution, distribution and note-routing additionally require the Vault
///         and its bound Settlement to sit on the Governor whitelists (审计反馈 V3 #1/#2).
///         No fee computation, no PSM coupling, no
///         accounting-only credit. (development-plan §3.2.1, §8 — net settlement conversion —
///         UnifiedPool; 角色权限与职责修改方案 §9.2, §12.5)
interface IUnifiedPool {
    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event VaultAdded(address indexed vault, uint256 timestamp);
    event VaultDeactivated(address indexed vault, uint256 timestamp);
    event VaultReactivated(address indexed vault, uint256 timestamp);
    event InterestDeposited(address indexed payer, uint256 amount, uint256 timestamp);
    event PrincipalDeposited(address indexed payer, uint256 amount, uint256 timestamp);
    event InterestRepaid(address indexed vault, uint256 amount, uint256 timestamp);
    event PrincipalRepaid(address indexed vault, uint256 amount, uint256 timestamp);
    event VaultPrincipalReceived(address indexed vault, uint256 amount, uint256 timestamp);
    event Distributed(address indexed vault, uint256 amount, uint256 timestamp);
    event ThirdPartyTransferExecuted(
        address indexed vault,
        address indexed operator,
        address recipient,
        uint256 amount,
        bytes32 referenceId,
        uint256 timestamp
    );
    event StateManagerUpdated(address indexed previous, address indexed current, uint256 timestamp);
    event VaultWhitelistUpdated(address indexed vault, bool allowed, uint256 timestamp);
    event SettlementWhitelistUpdated(address indexed settlement, bool allowed, uint256 timestamp);
    event PendingWrittenDown(
        address indexed vault, uint256 amount, uint256 newPending, bytes32 referenceId, uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error NotGovernor(); // UUPS upgrade gate only — protocol-level, unrelated to Vault-local roles
    error NotVaultOwner();
    error NotSettlementOperator(address vault);
    error NotVaultSettlement(address vault);
    error InsufficientPending(address vault, uint256 pending, uint256 required);
    error InsufficientCash(uint256 cashBalance, uint256 required);
    error UnregisteredVault(address caller);
    error VaultAlreadyConfigured(address vault);
    error VaultNotConfigured(address vault);
    error VaultInactive(address vault);
    error InvalidRecipient();
    error InsufficientUnattributedInterest(uint256 available, uint256 requested);
    error InsufficientUnattributedPrincipal(uint256 available, uint256 requested);
    error NotVaultTimelock(address vault);
    error RecipientIsVaultAdapter(address vault, address recipient);
    error VaultNotWhitelisted(address vault);
    error SettlementNotWhitelisted(address settlement);

    // -----------------------------------------------------------------------
    // Governor admission control (审计反馈 V3 #1/#2)
    // -----------------------------------------------------------------------

    /// @notice Grant or revoke `vault`'s admission to this pool.
    /// @dev    Access: GOVERNOR_ROLE. `VaultFactory.deployVault` stays permissionless — creating
    ///         a Vault from the standard contracts is not protocol endorsement and must not by
    ///         itself confer the right to touch shared pool funds. Governance controls admission
    ///         to the shared pool instead of controlling who may create a Vault
    ///         (审计问题 1/2 回复 §2, §3.1).
    function setVaultWhitelisted(address vault, bool allowed) external;

    /// @notice Grant or revoke a Settlement contract's trust for pool operations.
    /// @dev    Access: GOVERNOR_ROLE. Several addresses may be whitelisted at once so different
    ///         Settlement implementations and later version migrations can coexist
    ///         (审计问题 1/2 回复 §3.1).
    function setSettlementWhitelisted(address settlement, bool allowed) external;

    // -----------------------------------------------------------------------
    // Vault registration (that Vault's Owner)
    // -----------------------------------------------------------------------

    /// @notice Configure `vault` so it can receive attributions and distributions.
    /// @dev    Access: `vault`'s own Owner. Tranche classification was removed on 2026-08-25 —
    ///         everything here keys on the vault address alone (合约修复20260825 §1).
    function addVault(address vault) external;

    /// @notice Stop `vault` from receiving new interest/principal/note-routing inflows. Does
    ///         NOT clear its pending — Settlement may still `distribute` against it.
    /// @dev    Access: `vault`'s own Owner.
    function deactivateVault(address vault) external;

    /// @notice Re-allow new inflows to a previously deactivated vault.
    /// @dev    Access: `vault`'s own Owner.
    function reactivateVault(address vault) external;

    /// @notice Recognises a permanent loss on pool-managed assets by reducing `pending[vault]`.
    /// @dev    Access: that Vault's own VaultTimelock. `distribute` is otherwise the only path
    ///         that reduces `pending`, which would leave an unrecoverable investment counted in
    ///         the Vault's NAV forever (审计报告一反馈 §1).
    function writeDownPending(address vault, uint256 amount, bytes32 referenceId) external;

    // -----------------------------------------------------------------------
    // Real USDT inflows (permissionless — any real payer; NOT attributed to any Vault yet)
    // -----------------------------------------------------------------------

    /// @notice Deposits `amount` USDT of interest into the unattributed interest pool. Does NOT
    ///         credit any Vault's pending — attribution to a specific Vault happens later, via
    ///         `attributeInterest`, decided by that Vault's own Settlement Operator.
    ///         (角色权限与职责修改方案 §13.5 SET-06)
    function repayInterest(uint256 amount) external;

    /// @notice Deposits `amount` USDT of principal into the unattributed principal pool. Does NOT
    ///         credit any Vault's pending — attribution to a specific Vault happens later, via
    ///         `attributePrincipal`, decided by that Vault's own Settlement Operator.
    function repayPrincipal(uint256 amount) external;

    /// @notice Attributes `amount` from the unattributed interest pool to `vault`'s pending.
    /// @dev    Access: `vault`'s Settlement Operator (per `vault`'s bound Settlement contract),
    ///         with `vault` on the Governor Vault whitelist and its bound Settlement on the
    ///         Governor Settlement whitelist (审计问题 1/2 回复 §3.3).
    function attributeInterest(address vault, uint256 amount) external;

    /// @notice Attributes `amount` from the unattributed principal pool to `vault`'s pending.
    /// @dev    Access: as `attributeInterest`. This is the gate that stops a rogue Vault from
    ///         inflating its own `pending` — and therefore its `totalAssets()` and share price —
    ///         out of the permissionless inflow pool (审计反馈 V3 #2).
    function attributePrincipal(address vault, uint256 amount) external;

    /// @notice Caller must be a registered, active, whitelisted, UnifiedPool-configured vault; routes the
    ///         caller's own USDT into its own pending. Unlike repayInterest/repayPrincipal this
    ///         attributes immediately — any Vault can return
    ///         its own free USDT to the pool for later re-distribution via `distribute`.
    function receiveVaultPrincipal(uint256 amount) external;

    // -----------------------------------------------------------------------
    // Distribution (that Vault's own bound Settlement contract only)
    // -----------------------------------------------------------------------

    /// @notice Deduct from pending[vault] and totalPending, transfer USDT to vault. `amount` may
    ///         be zero. Does not require `amount` to equal any redeem total or gap — Settlement
    ///         decides the amount; this only enforces it's <= pending[vault] and <= cash on hand.
    /// @dev    Access: `vault`'s own bound Settlement contract (`IBaseVault(vault).settlement()`),
    ///         which must additionally be Settlement-whitelisted, with `vault` Vault-whitelisted
    ///         (审计问题 1/2 回复 §3.4). The pending/cash arithmetic itself is unchanged.
    function distribute(address vault, uint256 amount) external;

    // -----------------------------------------------------------------------
    // Governor third-party transfers
    // -----------------------------------------------------------------------

    /// @notice Transfer `amount` USDT to an arbitrary `recipient`. Does not touch pending/totalPending —
    ///         this does not represent repayment of any Vault's receivable.
    /// @dev    Access: GOVERNOR_ROLE. Was the Vault's Settlement Operator until 审计反馈 V3 #1:
    ///         moving pool cash to a third party, RWA venue, Adapter or arbitrary address is the
    ///         one path that removes value without a matching ledger entry, so a single stolen
    ///         Operator key must not reach it (审计问题 1/2 回复 §3.5). `vault` is retained as the
    ///         accounting reference the transfer is booked against.
    function operatorTransfer(address vault, address recipient, uint256 amount, bytes32 referenceId) external;

    /// @notice Transfer `amount` USDT to `revenuePool` and call `IRevenuePool.receiveFee(amount)`.
    /// @dev    Access: GOVERNOR_ROLE (审计反馈 V3 #1).
    function operatorTransferToRevenuePool(address vault, address revenuePool, uint256 amount, bytes32 referenceId)
        external;

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    function usdt() external view returns (IERC20);
    function unattributedInterest() external view returns (uint256);
    function unattributedPrincipal() external view returns (uint256);
    function pending(address vault) external view returns (uint256);
    function totalPending() external view returns (uint256);
    function vaultConfigured(address vault) external view returns (bool);
    function vaultActive(address vault) external view returns (bool);
    function vaultWhitelisted(address vault) external view returns (bool);
    function settlementWhitelisted(address settlement) external view returns (bool);

    /// @notice min(pending[vault], current USDT balance of this pool). Not a reservation —
    ///         purely informational for off-chain batch planning.
    function availableToDistribute(address vault) external view returns (uint256);
}
