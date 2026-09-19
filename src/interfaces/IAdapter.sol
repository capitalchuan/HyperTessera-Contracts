// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IAdapter
/// @notice Vault's execution + position-ledger + valuation module. Curator authorizes buy/sell
///         intent (amount/destination/settlement mode); Allocator executes exactly as authorized
///         (orderId only — no amount/destination discretion). (development-plan §3.4.1)
///
///         Two order books, not three. The Rebalance book was removed on 2026-08-28: it was only
///         ever `source -> Adapter -> destination` in USDT, needed `source` to have approved this
///         Adapter (impossible for an external counterparty or most contracts), created a new
///         Deal without retiring the old one, and had none of the minimum-output or deadline
///         machinery a real atomic swap requires. A Sell Order followed by a Buy Order does the
///         whole job with the positions correctly retired: within one Adapter directly, across
///         two via `recallAdapter` + `fundAdapter`. An Adapter that genuinely needs an atomic DEX
///         swap should implement a purpose-built one (in/out token, minimum output, deadline,
///         router), not reuse a generic transfer pair.
///
///         The RWA Withdraw book went with it: it could move RWA out with no payment at all,
///         bypassing the Sell Order's pay-first rule, and left two order books competing for the
///         same token balance.
interface IAdapter {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    enum SettlementMode {
        TOKEN_RETURN, // destination eventually delivers an on-chain token; realAssets() falls back to it once resolved
        VALUE_RETURN // destination never tokenizes; permanently reported via updateDealData
    }

    struct Order {
        uint256 amount;
        address destination; // the purchase destination being paid
        address source; // unused since the Rebalance order book was removed; kept for ABI stability
        SettlementMode mode; // Curator-declared
        bool executed;
        bool cancelled;
    }

    /// @notice Lifecycle of a generic Sell Order — the single asset-exit-and-proceeds path.
    /// @dev    Partial payment is deliberately unsupported: it would need per-order running
    ///         balances on top of the reservation bookkeeping for no operational gain. A partial
    ///         exit is expressed as a smaller, separate Sell Order instead.
    enum SellOrderStatus {
        NONE, // never created
        CREATED, // awaiting payment
        FUNDED, // proceeds received in full and locked
        EXECUTED, // exit asset delivered; terminal
        CANCELLED, // unfunded order withdrawn; terminal
        REFUNDED // funded but unexecuted; proceeds returned to the payer; terminal
    }

    /// @notice A generic asset-exit-and-proceeds order: the counterparty pays this Adapter first,
    ///         and only then may the Allocator deliver the position being exited.
    /// @dev    Replaces the old `createSellOrder(amount)`/`executeSell`, which never sold
    ///         anything — it pulled USDT out of the Allocator's own wallet, putting a human role
    ///         in the custody path, requiring the Allocator to hold and approve USDT, and
    ///         recording neither what was exited nor from which position, so `dealValue` never
    ///         fell and the returned cash could be double-counted against the original
    ///         valuation. Also replaces the RWA Withdraw and Rebalance order books outright.
    ///
    ///         Two position shapes are covered:
    ///         - **Deal-priced** (`pendingDeposits`/`dealValue`): `hasDeal` is true, `dealKey`
    ///           names a real live deal, and `dealValueReduction` is written off on execution.
    ///         - **Token-balance-priced** (RWAAdapter's NAV × balance): the position is
    ///           identified by `exitAsset`/`exitAmount`, and the exit shows up on its own as the
    ///           balance falls. `hasDeal` may still be set to clear a stale in-flight Buy deal.
    struct SellOrder {
        address exitAsset; // token delivered out; address(0) = no on-chain token (VALUE_RETURN exit)
        uint256 exitAmount; // in exitAsset's own decimals; 0 when exitAsset is address(0)
        uint256 proceeds; // receivable, denominated in this Adapter's asset()
        address payer; // the only address whose payment this order accepts
        address assetRecipient; // receives exitAsset on execution
        uint256 dealKey; // position being unwound; meaningful only when hasDeal
        bool hasDeal; // dealKey 0 is a real buy key, so validity needs its own flag
        uint256 dealValueReduction; // dealValue written off on execution
        uint256 expiry; // after this, the order can no longer execute and the payer may refund
        SellOrderStatus status;
    }

    struct DealData {
        uint256 dealValue; // current value of this order's deployed capital, 6-decimal USDT
        uint256 updatedAt; // block.timestamp when last updated
        uint256 stalenessWindow; // revert if now - updatedAt > stalenessWindow
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event BuyOrderCreated(uint256 indexed orderId, uint256 amount, address destination, uint8 mode, uint256 timestamp);
    event SellOrderCreated(
        uint256 indexed orderId,
        address exitAsset,
        uint256 exitAmount,
        uint256 proceeds,
        address payer,
        address assetRecipient,
        uint256 expiry,
        uint256 timestamp
    );
    event SellOrderFunded(uint256 indexed orderId, address indexed payer, uint256 proceeds, uint256 timestamp);
    event BuyOrderExecuted(uint256 indexed orderId, uint256 timestamp);
    event SellOrderExecuted(
        uint256 indexed orderId,
        address exitAsset,
        uint256 exitAmount,
        address assetRecipient,
        uint256 proceeds,
        uint256 timestamp
    );
    event SellOrderRefunded(uint256 indexed orderId, address indexed payer, uint256 proceeds, uint256 timestamp);
    event OrderCancelled(uint256 indexed orderId, uint8 orderType, uint256 timestamp); // 0=buy, 1=sell
    event DealDataUpdated(uint256 indexed orderId, uint256 newValue, uint256 timestamp);
    event DealValueCleared(uint256 indexed orderId, uint256 timestamp);
    event DealValueReducedBySell(
        uint256 indexed orderId, uint256 dealKey, uint256 reduction, uint256 newValue, uint256 timestamp
    );
    event CapitalDeployed(address indexed destination, uint256 amount, uint256 timestamp);
    event CapitalRecalled(uint256 amount, uint256 timestamp);
    event AllocatorFrozen(address indexed actor, uint256 timestamp);
    event AllocatorUnfrozen(address indexed actor, uint256 timestamp);
    event DataProviderSet(address indexed provider, uint256 timestamp);
    event WoundDownToVault(uint256 assets, uint256 sharesBurned, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error NotCurator();
    error NotAllocator();
    error NotCuratorOrGuardian();
    error NotDataProvider();
    error NotGuardian();
    error OrderDoesNotExist(uint256 orderId);
    error OrderAlreadyExecuted(uint256 orderId);
    error OrderAlreadyCancelled(uint256 orderId);
    error StaleAdapterData(uint256 lastUpdated, uint256 stalenessWindow);
    error WrongSettlementMode(uint256 orderId, uint8 expected, uint8 actual);
    error AllocatorIsFrozen();
    error SelfDestinationNotAllowed();

    // Generic Sell Order
    error ExitAssetNotSupported(address token);
    error InsufficientExitAsset(address token, uint256 requested, uint256 available);
    error InsufficientDealValue(uint256 dealKey, uint256 requested, uint256 available);
    error DealNotLive(uint256 dealKey);
    error ZeroAmount();
    error ExpiryNotInFuture(uint256 expiry);
    error WrongSellOrderStatus(uint256 orderId, uint8 expected, uint8 actual);
    error NotOrderPayer(uint256 orderId);
    error SellOrderExpired(uint256 orderId, uint256 expiry);
    error SellOrderNotExpired(uint256 orderId, uint256 expiry);
    error ProceedsNotReceived(uint256 expected, uint256 received);
    error ProceedsLocked(uint256 requested, uint256 free);
    error NotVault();
    error DealValueBelowReserved(uint256 dealKey, uint256 newValue, uint256 reserved);
    error AdapterNotWoundDown(uint256 liveDeals, uint256 lockedProceeds);

    // -----------------------------------------------------------------------
    // Curator order book
    // -----------------------------------------------------------------------

    function createBuyOrder(uint256 amount, address destination, SettlementMode mode) external returns (uint256 orderId);

    /// @notice Authorise an asset exit and the proceeds expected for it. Access: this Vault's Curator.
    /// @param  exitAsset          Token to deliver out, or `address(0)` for a position with no
    ///                            on-chain token (a VALUE_RETURN deal), where only `dealValue` moves.
    /// @param  exitAmount         Amount of `exitAsset`, in its own decimals. Zero iff `exitAsset` is zero.
    /// @param  proceeds           Receivable in this Adapter's `asset()`. Must be paid in full before execution.
    /// @param  payer              The only address whose payment this order accepts.
    /// @param  assetRecipient     Receives `exitAsset` on execution.
    /// @param  dealKey            Live deal being unwound; ignored unless `hasDeal`.
    /// @param  hasDeal            Whether this exit is tied to a Deal-priced position.
    /// @param  dealValueReduction `dealValue` written off on execution; must not exceed what is
    ///                            left after other outstanding Sell Orders' reservations.
    /// @param  expiry             Must be in the future. Past it the order cannot execute and the
    ///                            payer may reclaim their money without needing anyone's help.
    function createSellOrder(
        address exitAsset,
        uint256 exitAmount,
        uint256 proceeds,
        address payer,
        address assetRecipient,
        uint256 dealKey,
        bool hasDeal,
        uint256 dealValueReduction,
        uint256 expiry
    ) external returns (uint256 orderId);

    /// @notice Pay a Sell Order's proceeds. Access: that order's declared `payer`.
    /// @dev    The counterparty pays this Adapter directly — the Allocator is not in the custody
    ///         path and never has to hold or approve the proceeds asset. A plain ERC-20 transfer
    ///         carries no order id and so cannot be matched automatically; this entry point is the
    ///         only way an order becomes FUNDED.
    function fundSellOrder(uint256 orderId) external;

    function cancelBuyOrder(uint256 orderId) external;

    /// @notice Withdraw a Sell Order. Access: this Vault's Curator or Guardian.
    /// @dev    A CREATED order simply releases its reservations. A FUNDED order can never be
    ///         cancelled while keeping the counterparty's money: it refunds to the payer and ends
    ///         REFUNDED. Available while the Vault is paused — cancelling reduces exposure.
    function cancelSellOrder(uint256 orderId) external;

    /// @notice Reclaim the proceeds of a funded order that expired unexecuted. Access: its payer.
    /// @dev    Deliberately not gated on the Curator or Allocator: a counterparty who has paid
    ///         must be able to get their money back without depending on the party that failed to
    ///         deliver. Available while the Vault is paused.
    function refundSellOrder(uint256 orderId) external;

    // -----------------------------------------------------------------------
    // Allocator execution
    // -----------------------------------------------------------------------

    function executeBuy(uint256 orderId) external;

    /// @notice Deliver the exit asset of a FUNDED, unexpired Sell Order. Access: this Vault's Allocator.
    /// @dev    Reduces the linked `dealValue` (Deal-priced positions) and/or moves the token out
    ///         (balance-priced positions) in the same call, so the exited value can never be
    ///         counted twice. The proceeds stop being locked and become ordinary Adapter assets,
    ///         redeployable via a Buy Order or recallable to the Vault.
    function executeSell(uint256 orderId) external;

    // -----------------------------------------------------------------------
    // Emergency freeze (GUARDIAN_ROLE) — halts Allocator execution only; Curator order
    // creation/cancellation is unaffected.
    // -----------------------------------------------------------------------

    /// @notice Halt `executeBuy`/`executeSell`. Access: this Vault's Guardian.
    function freezeAllocator() external;

    /// @notice Lift an Allocator freeze. Access: this Vault's Curator.
    function unfreezeAllocator() external;

    function allocatorFrozen() external view returns (bool);

    // -----------------------------------------------------------------------
    // Valuation
    // -----------------------------------------------------------------------

    function realAssets() external view returns (uint256);

    /// @notice Hands this Adapter's entire remaining asset balance back to the Vault and burns the
    ///         Vault's shares, driving `realAssets()` to exactly zero. Access: this Vault's Allocator
    ///         — the destination is always the Vault, so this cannot redirect funds.
    /// @dev    The wind-down primitive the ERC-4626 share math cannot express. Redeeming every
    ///         share rounds down (`_convertToAssets` divides by `totalSupply + 10**offset` over
    ///         `totalAssets + 1`), so a profitable Adapter always keeps a residue, and withdrawing
    ///         the full reported balance asks for more shares than exist. Both
    ///         `BaseVault.removeAdapter` and `_requireAssetsWoundDown` compare `realAssets()`
    ///         against exact zero, so without this an Adapter that ever made a gain could never be
    ///         removed and its Vault could never price a final cycle. Moves value rather than
    ///         abandoning it: `grossManagedAssets()` is unchanged, the balance simply stops being
    ///         the Adapter's and becomes the Vault's.
    ///
    ///         Refuses while anything real is still outstanding — a live deal is an un-retired
    ///         position, and locked proceeds are a counterparty's escrowed money, neither of which
    ///         this may walk out.
    function windDownToVault() external;
    /// @notice Refresh / retire a **buy** order's tracked deal value.
    function updateDealData(uint256 orderId, uint256 newValue) external;
    function clearDealValue(uint256 orderId) external;

    function setStalenessWindow(uint256 window) external;

    /// @notice Sets this Adapter's off-chain valuation data provider. Access: this Vault's Curator.
    function setDataProvider(address provider) external;

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function buyOrders(uint256 orderId)
        external
        view
        returns (
            uint256 amount,
            address destination,
            address source,
            SettlementMode mode,
            bool executed,
            bool cancelled
        );
    function sellOrders(uint256 orderId)
        external
        view
        returns (
            address exitAsset,
            uint256 exitAmount,
            uint256 proceeds,
            address payer,
            address assetRecipient,
            uint256 dealKey,
            bool hasDeal,
            uint256 dealValueReduction,
            uint256 expiry,
            SellOrderStatus status
        );
    function pendingDeposits(uint256 orderId)
        external
        view
        returns (uint256 dealValue, uint256 updatedAt, uint256 stalenessWindow);

    /// @notice Exit-asset amount spoken for by Sell Orders that have not settled yet.
    function reservedExitAmount(address token) external view returns (uint256);

    /// @notice `dealValue` spoken for by Sell Orders that have not settled yet.
    function reservedDealValue(uint256 dealKey) external view returns (uint256);

    /// @notice Proceeds received and held for FUNDED orders. Excluded from `realAssets()` and
    ///         from what `recallAdapter` may take — the counterparty's money is not the Vault's
    ///         until the exit asset has actually been delivered.
    function lockedProceeds() external view returns (uint256);

    function vault() external view returns (address);
}
