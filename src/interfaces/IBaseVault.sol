// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {CycleState, ProductState, DepositRequestState, RedeemRequestState, RequestSettlement} from "../libs/Types.sol";
import {IVaultRoles} from "./IVaultRoles.sol";

/// @title IBaseVault
/// @notice Shared ERC-4626 + ERC-7540 async vault surface. Dynamic pricing
///         (totalAssets/totalSupply), Adapter-aggregated assets, Morpho-style performance
///         fee, dual deposit/redeem FIFO, and net-settlement `settle()`.
///         Also implements IVaultRoles — Owner/Curator/Guardian/Allocator/Keeper are Vault-local
///         (角色权限与职责修改方案 §5), not global HyperAccessControl roles.
///         (development-plan §3.3.1, §8 — net settlement conversion — BaseVault)
interface IBaseVault is IVaultRoles {
    // -----------------------------------------------------------------------
    // Structs
    // -----------------------------------------------------------------------

    struct DepositRequest {
        address owner;
        uint256 assets;
        uint256 settledShares;
        uint256 cycleNumber;
        DepositRequestState state;
    }

    /// @notice Read model for a redeem request.
    /// @dev    Added with 审计反馈 V3 #3: a QUEUED request may now hold a claimable balance, so a
    ///         front-end can no longer infer "claimable" from the state alone — it needs
    ///         `settledAssets > 0` alongside `remainingShares` to show the amount claimable now
    ///         and the amount still queued (审计问题 3 回复 §四·前端和 Indexer).
    struct RedeemRequest {
        address owner;
        uint256 shares; // originally requested; immutable
        uint256 remainingShares; // still queued, not yet filled
        uint256 settledAssets; // filled and owed but not yet claimed
        uint256 cycleNumber;
        RedeemRequestState state;
    }

    struct CycleSnapshot {
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 settlementPrice; // settlement-token units per 1e18 shares (parity == 10**usdt.decimals())
        uint256 feeAssets;
        uint256 feeShares;
        uint256 timestamp;
        bool initialized;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event DepositRequested(uint256 indexed requestId, address indexed owner, uint256 assets, uint256 timestamp);
    event DepositClaimed(uint256 indexed requestId, address indexed receiver, uint256 shares, uint256 timestamp);
    event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 shares, uint256 timestamp);
    event RedeemClaimed(uint256 indexed requestId, address indexed receiver, uint256 assets, uint256 timestamp);

    /// @notice A partially-filled redeem was paid out while it stays queued for the remainder.
    /// @dev    Emitted alongside `RedeemClaimed`, never instead of it — the request keeps its
    ///         original FIFO position and may be filled and claimed again (审计反馈 V3 #3). A
    ///         consumer must not read one of these as the whole request being finished.
    event RedeemPartiallyClaimed(
        uint256 indexed requestId, address indexed receiver, uint256 assets, uint256 remainingShares, uint256 timestamp
    );

    /// @notice A queued redeem took its written-down cash and left the queue after liquidation.
    /// @dev    Emitted alongside `RedeemClaimed`. `sharesReturned` went back to the owner to
    ///         unlock them and clear the request, not because they still carry payout value —
    ///         `claimFinal` stays disabled after liquidation (审计问题 3 回复 §三.3).
    event RedeemLiquidationExit(
        uint256 indexed requestId, address indexed receiver, uint256 assets, uint256 sharesReturned, uint256 timestamp
    );
    event RequestCancelled(uint256 indexed requestId, address actor, uint256 timestamp);
    event SettlementProcessed(
        uint256 depositCount, uint256 redeemCount, uint256 poolDistributedAssets, uint256 timestamp
    );
    event GateUpdated(address oldGate, address newGate, uint256 timestamp);
    event SettlementSet(address settlement, uint256 timestamp);
    event RefundClaimed(uint256 indexed requestId, address indexed owner, uint256 assets, uint256 timestamp);
    event UnifiedPoolSet(address pool, uint256 timestamp);
    event ClaimRegistrySet(address registry, uint256 gracePeriod, uint256 timestamp);
    event AdapterAdded(address indexed adapter, uint256 timestamp);
    event AdapterRemoved(address indexed adapter, uint256 timestamp);
    event AdapterFunded(address indexed adapter, uint256 assets, uint256 timestamp);
    event AdapterRecalled(address indexed adapter, uint256 assets, uint256 timestamp);
    event SubscriptionCapShareUpdated(uint256 oldCap, uint256 newCap, uint256 timestamp);
    event FinalPriceFrozen(
        uint256 indexed cycleNumber,
        uint256 settlementPrice,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 timestamp
    );
    event FinalClaimed(
        address indexed owner, address indexed receiver, uint256 shares, uint256 assets, uint256 timestamp
    );
    event PerformanceFeeUpdated(uint16 bps, uint256 timestamp);
    event PerformanceFeeRecipientUpdated(address recipient, uint256 timestamp);
    event PerformanceFeeAccrued(uint256 indexed cycleNumber, uint256 feeAssets, uint256 feeShares, uint256 timestamp);
    event PerformanceFeeSkipped(uint256 indexed cycleNumber, uint256 feeAssets, uint256 timestamp);
    event ProtocolFeeConfigSet(
        address oldRevenuePool, address newRevenuePool, uint16 protocolFeeShareBps, uint256 timestamp
    );
    event PerformanceFeeDistributed(
        uint256 indexed cycleNumber,
        uint256 feeAssets,
        uint256 feeShares,
        uint256 protocolFeeShares,
        uint256 recipientFeeShares,
        address revenuePool,
        address performanceFeeRecipient
    );
    event SettlementPriceSnapshotted(
        uint256 indexed cycleNumber,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 settlementPrice,
        uint256 timestamp
    );
    event CycleNetFlow(
        uint256 indexed cycleNumber, uint256 acceptedDepositTotal, uint256 acceptedRedeemTotal, int256 netFlow
    );
    event RequestWrittenDown(uint256 indexed requestId, uint256 haircut, uint256 newAmount, uint256 timestamp);
    event DepositMarkedRefundable(uint256 indexed requestId, address indexed owner, uint256 assets, uint256 timestamp);
    event InsolvencyWrittenDown(
        uint256 grossAssets, uint256 liabilitiesBefore, uint256 liabilitiesAfter, uint256 timestamp
    );
    event DepositSettled(
        uint256 indexed requestId,
        uint256 originalAssets,
        uint256 settledAssets,
        uint256 refundedAssets,
        uint256 indexed cycleNumber,
        uint256 timestamp
    );
    event RedeemSettled(
        uint256 indexed requestId,
        uint256 originalShares,
        uint256 settledSharesThisCycle,
        uint256 remainingShares,
        uint256 settledAssetsThisCycle,
        uint256 indexed cycleNumber,
        uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error GateBlocked(address owner);
    error RequestNotSettled(uint256 requestId);
    error RequestAlreadyClaimed(uint256 requestId);
    error RequestAlreadySettled(uint256 requestId);
    error OnlySettlement(address caller);
    error InsufficientShares(address owner, uint256 available, uint256 requested);
    error CancelNotAllowed(uint256 requestId, ProductState currentProduct, CycleState currentCycle);
    error SettlementAlreadySet();
    error NotRefundable(uint256 requestId);
    error RequestNotFound(uint256 requestId);
    error NotOwnerOrOperator(address caller, address owner);
    error ZeroAssets();
    error ZeroShares();
    error ZeroAddress();
    error TransferFailed();
    error AccountingInsolvent();
    error AdapterAlreadyAdded(address adapter);
    error AdapterNotFound(address adapter);
    error AdapterLimitExceeded();
    error AdapterStillHasAssets(address adapter);
    error FeeTooHigh(uint16 bps);
    error InvalidFeeRecipient();
    error SnapshotAlreadyInitialized(uint256 cycleNumber);
    error SnapshotNotInitialized(uint256 cycleNumber);
    /// @dev Units follow the call site: AUM for `settle()`'s end-of-cycle check, share supply
    ///      for `EarnVault.deposit()`'s guard, which has no settlement price to convert with.
    error SupplyCapExceeded(uint256 limit, uint256 actual);
    error InsufficientSettlementLiquidity(uint256 acceptedRedeemTotal, uint256 available);
    error NotInsolvent();
    error LengthMismatch();
    error WriteDownIncreasesLiability(uint256 requestId);
    error InvalidSettleAmount(uint256 requestId);
    error PartialFillMustBeLast(uint256 requestId);
    error InsufficientWriteDown(uint256 grossAssets, uint256 liabilitiesAfter);
    error Unauthorized();
    error GovernanceAlreadyBound();
    error SettlementChangeDuringActiveCycle(CycleState current);
    error UnifiedPoolNotSet();
    error InsufficientFreeUSDT(uint256 requested, uint256 available);
    error AssetsNotWoundDown(address holder, uint256 remaining);
    error FinalPriceNotSet();
    error AlreadyLiquidated();
    error VaultLiquidated();
    error IdsNotStrictlyAscending(uint256 requestId);
    error IncompleteWriteDown(uint256 submitted, uint256 outstanding);
    error ProtectedLiabilitiesUnbacked(uint256 required, uint256 cash);
    error OldPoolPendingNotDrained(address oldPool, uint256 pending);
    error ClaimRegistryNotConfigured();
    error ClaimGracePeriodNotElapsed(uint256 dueFrom);

    // -----------------------------------------------------------------------
    // ERC-4626 read surface
    // -----------------------------------------------------------------------

    function getDepositRequest(uint256 requestId) external view returns (DepositRequest memory);
    function getRedeemRequest(uint256 requestId) external view returns (RedeemRequest memory);
    function totalAssets() external view returns (uint256);
    function grossManagedAssets() external view returns (uint256);
    function freeVaultUSDT() external view returns (uint256);
    function unifiedPool() external view returns (address);
    function settlement() external view returns (address);
    function isAdapter(address adapter) external view returns (bool);

    /// @notice Adapter at `index` in the vault's active adapter list.
    /// @dev    Ordering is NOT stable: `removeAdapter` swaps the last entry into the removed
    ///         slot and pops, so a removal moves an unrelated adapter's index. Pin a single
    ///         `blockTag` across `adapterCount` and every `adapters(i)` call to read a
    ///         consistent snapshot. Contrast `IAdapterFactory`'s adapter index, which is
    ///         append-only and whose indices are stable forever.
    function adapters(uint256 index) external view returns (address);

    /// @notice Number of adapters currently attached to this vault (at most `MAX_ADAPTERS`).
    /// @dev    Solidity's generated getter for the public `adapters` array exposes no `.length`,
    ///         so without this a caller has to probe indices until one reverts. Same
    ///         snapshot caveat as `adapters`.
    function adapterCount() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function totalSupply() external view returns (uint256);

    // -----------------------------------------------------------------------
    // ERC-7540 lifecycle
    // -----------------------------------------------------------------------

    function requestDeposit(uint256 assets, address owner) external returns (uint256 requestId);
    function claimDeposit(uint256 requestId, address receiver) external returns (uint256 shares);
    function requestRedeem(uint256 shares, address owner) external returns (uint256 requestId);
    /// @notice Withdraw an unsettled request; a partially-filled redeem gets back only its
    ///         `remainingShares` and stays claimable for the part already filled.
    /// @dev    Normally restricted to the ACCEPTING window outside SETTLING. Once
    ///         `insolvencyLiquidated` that restriction is dropped: nothing can settle any more,
    ///         so it would only lock the request in permanently (审计问题 3 回复 §三.4).
    function cancelRequest(uint256 requestId) external;

    /// @notice Pays out everything this redeem has been filled for and not yet claimed.
    /// @dev    Accepts a fully-filled SETTLED request and a partially-filled QUEUED one alike
    ///         (审计反馈 V3 #3). A solvent partial claim leaves the request QUEUED in its original
    ///         FIFO position, so the same request may be filled and claimed repeatedly; after
    ///         liquidation the payout also releases the queue slot and returns `remainingShares`.
    function claimRedeem(uint256 requestId, address receiver) external returns (uint256 assets);
    function claimRefund(uint256 requestId) external;

    // -----------------------------------------------------------------------
    // Settlement
    // -----------------------------------------------------------------------

    function snapshotSettlementPrice(uint256 cycleNumber) external;

    /// @dev FIFO constraint: `redeems` is dequeued strict FIFO-from-head (Queue.dequeue). If a
    ///      redeem request is only partially filled (its settleAmount < remainingShares), it
    ///      must be the LAST redeem entry in this batch — nothing queued after it can also be
    ///      included, even if fully cleared, or this call reverts with Queue's
    ///      OutOfOrderDequeue.
    function settle(
        uint256 cycleNumber,
        RequestSettlement[] calldata deposits,
        RequestSettlement[] calldata redeems,
        uint256 poolDistributedAssets
    ) external returns (uint256[] memory fullyClearedRedeemIds);

    /// @notice One-shot insolvency liquidation. PENDING and REFUNDABLE are protected in full;
    ///         every outstanding settled redemption is haircut by one on-chain-computed ratio.
    /// @param  settledRedeemIds EVERY unclaimed redemption still carrying `settledAssets`, in
    ///         strictly ascending order. Ids only — the caller cannot supply amounts.
    function writeDownInsolvency(uint256[] calldata settledRedeemIds) external;

    // -----------------------------------------------------------------------
    // ERC-7540 operator
    // -----------------------------------------------------------------------

    function setOperator(address operator, bool approved) external;
    function isOperator(address owner, address operator) external view returns (bool);

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    /// @notice One-time wiring of this Vault's VaultTimelock, called by VaultFactory in the same
    ///         transaction that constructs this Vault.
    function bindGovernance(address vaultTimelock_) external;

    function setSettlement(address settlement_) external;
    function setGate(address gate_) external;
    function setUnifiedPool(address pool) external;

    /// @notice Wires the ClaimRegistry and post-maturity grace period used by
    ///         `recordOverdueClaims`. `registry == address(0)` disables registration.
    function configureClaimRegistry(address registry, uint256 gracePeriod) external;

    /// @notice Records requests still unclaimed past `maturityTimestamp + claimGracePeriod`
    ///         into this Vault's ClaimRegistry. Permissionless; de-duplicated per request.
    function recordOverdueClaims(uint256[] calldata requestIds) external;
    function addAdapter(address adapter) external;
    function removeAdapter(address adapter) external;
    /// @notice One-shot initialisation of `subscriptionCapShare`, pushed in by this Vault's
    ///         StateManager as part of `setProductParams`.
    /// @dev    Access: this Vault's StateManager, while the product is CONFIGURING only.
    /// @notice Burns `shares` at the frozen final price and pays the proceeds to `receiver`.
    /// @dev    Callable from CLAIMING onward, including after CLOSED. Partial claims allowed.
    function claimFinal(uint256 shares, address owner, address receiver) external returns (uint256 assets);

    function initSubscriptionCapShare(uint256 capShare) external;

    /// @notice Change `subscriptionCapShare` after configuration.
    /// @dev    Access: this Vault's VaultTimelock only.
    function setSubscriptionCapShare(uint256 capShare) external;
    function setPerformanceFeeBps(uint16 bps) external;
    function setPerformanceFeeRecipient(address recipient) external;
    function returnPrincipalToPool(uint256 amount) external;
    function revenuePool() external view returns (address);
    function protocolFeeShareBps() external view returns (uint16);
    function setProtocolFeeConfig(address revenuePool_, uint16 protocolFeeShareBps_) external;

    // -----------------------------------------------------------------------
    // ERC-20 share token
    // -----------------------------------------------------------------------

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}
