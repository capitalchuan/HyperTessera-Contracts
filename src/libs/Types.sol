// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title Types — HyperTessera Earn shared enums and structs
/// @notice All types are declared at file scope per project convention.

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// @notice High-level product lifecycle phases. (development-plan §3.3.1)
enum ProductState {
    CONFIGURING, // Initial setup; Curator sets params; before subscription opens
    SUBSCRIBING, // Fundraising window open; investors submit requestDeposit
    FUNDING_FAILED, // subscriptionEnd passed with totalSubscribed < minRaiseAmount; refunds enabled
    OPERATING, // Live; accepts deposit/redeem requests; NAV accrues
    SETTLING, // Final settlement window; new subscriptions closed
    MATURING, // Off-chain repayment pending
    CLAIMING, // Repayment complete; investors may redeem
    CLOSED // Terminal state
}

/// @notice Per-cycle micro-state. (development-plan §3.3.1)
enum CycleState {
    ACCEPTING, // Accepting user deposit/redeem requests
    CALCULATING, // Settlement batch being computed; chain waiting
    FULFILLING, // Batch submitted and validated; distributions in progress
    COMPLETED // Cycle done; rolls over to ACCEPTING
}

/// @notice Emergency circuit-breaker state. (development-plan §3.3.1)
enum PauseState {
    ACTIVE, // Normal operation
    PAUSED_BY_GUARDIAN, // Immediate halt by Guardian multi-sig
    PAUSED_BY_GOVERNOR // Governance-initiated pause
}

/// @notice Per-module pause identifiers.
enum ModuleId {
    CASH_VAULT,
    NOTE_VAULT,
    LP_VAULT,
    SETTLEMENT,
    PSM_POOL,
    TOKENIZATION,
    REWARD,
    CLAIM_REGISTRY
}

/// @notice Bit positions of the vault-local roles in the mask returned by
///         `StateManager.vaultsWithRole`. Mirrors the `IVaultRoles` surface: a mask has
///         bit `1 << uint8(VaultRole.X)` set when the queried account holds role X on
///         that vault. (角色权限与职责修改方案 §2, §3)
enum VaultRole {
    OWNER,
    CURATOR,
    GUARDIAN,
    ALLOCATOR,
    KEEPER
}

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------

/// @notice Combined three-layer state stored per vault in StateManager.
struct StateContext {
    ProductState product;
    CycleState cycle;
    PauseState pause;
    uint256 currentCycleNumber;
}

/// @notice Product lifecycle and fee parameters stored per vault in StateManager.
struct ProductParams {
    uint256 subscriptionStart;
    uint256 subscriptionEnd;
    uint256 walletSubscriptionCap; // per-wallet cap in USDT (6-dec)
    uint256 minRaiseAmount;
    uint256 subscriptionCapShare; // vault share-supply cap after settlement; 0 = unlimited
    uint256 cycleDuration; // seconds; e.g. 7 days or 365 days
    uint256 maturityTimestamp;
    uint256 claimingStart;
    uint256 claimingEnd; // closeProduct() may only be called once block.timestamp >= this
    uint256 feeParams; // encoded fee parameters (reserved)
}

/// @notice One request's per-cycle settlement instruction. `settleAmount` is in assets (USDT)
///         for a deposit, in shares for a redeem. A request may be settled for less than its
///         full remaining amount — see BaseVault.settle() (development-plan §8, partial
///         settlement extension 2026-08-05).
struct RequestSettlement {
    uint256 requestId;
    uint256 settleAmount;
}

/// @notice Deposit request lifecycle states. Canonical definition — IBaseVault.sol imports
///         this rather than re-declaring (see net-settlement conversion, development-plan §8).
enum DepositRequestState {
    NONE, // does not exist
    PENDING, // USDT locked; awaiting settlement
    SETTLED, // shares minted; awaiting claimDeposit
    CLAIMED, // shares transferred to receiver; terminal
    REFUNDABLE, // marked refundable in FUNDING_FAILED; awaiting claimRefund
    REFUNDED, // refund paid in FUNDING_FAILED; terminal
    CANCELLED // cancelled by user in ACCEPTING window; terminal
}

/// @notice Redeem request lifecycle states. Canonical definition — IBaseVault.sol imports
///         this rather than re-declaring (see net-settlement conversion, development-plan §8).
enum RedeemRequestState {
    NONE, // does not exist
    QUEUED, // shares locked; in FIFO queue
    CANCELLED, // cancelled by user in ACCEPTING window; terminal
    SETTLED, // USDT reserved; awaiting claimRedeem
    CLAIMED // USDT transferred; terminal
}

/// @notice Which FIFO queue a request belongs to, in Queue.sol's dual-FIFO model.
enum QueueType {
    DEPOSIT,
    REDEEM
}

/// @notice Protocol creation-fee gate: which action is being paid for.
enum CreationFeeAction {
    RegisterAsset,
    DeployVault
}

/// @notice Protocol creation-fee gate: which rail the creator pays with. `Native` is the
///         chain's native currency (BNB/ETH); `Governance`/`Stable` are Governor-configured
///         ERC-20 addresses (see ProtocolFeeConfig).
enum FeePaymentKind {
    Native,
    Governance,
    Stable
}
