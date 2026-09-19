// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IAdapter} from "../../interfaces/IAdapter.sol";
import {IVaultRoles} from "../../interfaces/IVaultRoles.sol";
import {IStateManager} from "../../interfaces/IStateManager.sol";
import {ProductState} from "../../libs/Types.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BaseAdapter
/// @notice Vault's execution + position-ledger + valuation module.
///         Standard OZ ERC-4626 for capital sourcing from the Vault; a Curator/Allocator order
///         book for buy and sell; off-chain-fed valuation via `realAssets()` (virtual).
///
///         The Sell Order here is the protocol's ONE asset-exit path, shared by every Adapter.
///         It carries the counterparty payment, the reservation bookkeeping, the
///         refund rules and the Deal retirement; a subclass supplies only which tokens it will
///         part with and how to move them, through `_validateExitAsset`/`_deliverExitAsset`.
///         BaseAdapter itself will not release any token — a subclass that stays silent can only
///         run token-free (Deal-only) exits, which is what stops a Sell Order being used to walk
///         unrelated tokens out of an Adapter.
abstract contract BaseAdapter is ERC4626, IAdapter {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    address public immutable vault;

    /// @notice This Adapter's off-chain valuation data provider, set by the Vault's Curator.
    address public dataProvider;

    mapping(uint256 orderId => Order) public buyOrders;
    mapping(uint256 orderId => SellOrder) public sellOrders;
    uint256 public nextBuyOrderId;
    uint256 public nextSellOrderId;

    /// @notice Live deal ledger. The key is the Buy order id: with the Rebalance book gone
    ///         there is only one id sequence writing here, so the disjoint-keyspace
    ///         offset used before is no longer needed to keep two books from
    ///         colliding. Sell Orders reduce entries but never create them, so the lifecycle is
    ///         now simply: Buy creates a Deal -> it is valued -> Sell reduces or closes it.
    mapping(uint256 dealKey => DealData) public pendingDeposits;
    uint256[] public liveDealOrderIds;

    // -----------------------------------------------------------------------
    // Sell Order reservations
    //
    // Every outstanding Sell Order books what it intends to hand over, so two orders can never
    // promise the same RWA tokens or unwind the same Deal twice, and an order cannot be funded
    // only to find its asset already gone. Reservations are taken at creation and released on
    // execution, cancellation or refund.
    // -----------------------------------------------------------------------

    /// @inheritdoc IAdapter
    mapping(address token => uint256) public override reservedExitAmount;

    /// @inheritdoc IAdapter
    mapping(uint256 dealKey => uint256) public override reservedDealValue;

    /// @inheritdoc IAdapter
    /// @dev Counterparty money held for FUNDED orders. While an order sits FUNDED this Adapter
    ///      holds BOTH the original position and the payment for it, so counting the payment
    ///      would value the same economic thing twice. It is excluded from `realAssets()` and
    ///      from what `_withdraw` will let the Vault recall, and starts counting only once
    ///      `executeSell` has actually delivered the exit asset.
    uint256 public override lockedProceeds;

    uint256 public defaultStalenessWindow;

    bool public override allocatorFrozen;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(
        IERC20 asset_,
        address vault_,
        uint256 defaultStalenessWindow_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        if (address(asset_) == address(0) || vault_ == address(0)) {
            revert ZeroAddress();
        }
        vault = vault_;
        defaultStalenessWindow = defaultStalenessWindow_;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// @dev Also blocks while the Vault is paused: a Guardian halt must stop the adapter from
    ///      operating. Covers createBuyOrder/createSellOrder and unfreezeAllocator. Cancellation
    ///      goes through _onlyCuratorOrGuardian and stays available on purpose — cancelling an
    ///      unexecuted order during an incident reduces exposure rather than adding to it, and a
    ///      paused Vault must not trap a counterparty's payment.
    function _onlyCurator() internal view {
        if (IVaultRoles(vault).curator() != msg.sender) revert NotCurator();
        IStateManager(IVaultRoles(vault).stateManager()).requireActive(vault);
    }

    /// @dev Same pause gate as _onlyCurator; covers executeBuy/executeSell and clearDealValue.
    function _onlyAllocator() internal view {
        if (IVaultRoles(vault).allocator() != msg.sender) revert NotAllocator();
        if (allocatorFrozen) revert AllocatorIsFrozen();
        IStateManager(IVaultRoles(vault).stateManager()).requireActive(vault);
    }

    function _onlyCuratorOrGuardian() internal view {
        IVaultRoles roles = IVaultRoles(vault);
        if (roles.curator() != msg.sender && roles.guardian() != msg.sender) {
            revert NotCuratorOrGuardian();
        }
    }

    function _onlyDataProvider() internal view {
        if (dataProvider != msg.sender) revert NotDataProvider();
    }

    /// @dev Direct Curator call while this Adapter's Vault is CONFIGURING (initial setup);
    ///      VaultTimelock-only afterward — matches the pattern used for BaseVault's other
    ///      Curator-class parameters (staleness window / data provider are both Curator-class
    ///      Timelock operations).
    function _onlyCuratorDirectOrTimelock() internal view {
        address sm = IVaultRoles(vault).stateManager();
        bool isConfiguring = IStateManager(sm).getProductState(vault) == ProductState.CONFIGURING;
        if (isConfiguring) {
            if (IVaultRoles(vault).curator() != msg.sender) revert NotCurator();
        } else {
            if (IVaultRoles(vault).vaultTimelock() != msg.sender) revert NotCurator();
        }
    }

    function _onlyGuardian() internal view {
        if (IVaultRoles(vault).guardian() != msg.sender) revert NotGuardian();
    }

    /// @dev Locked proceeds are off limits to deployment exactly as they are to `_withdraw`.
    ///      While a Sell Order sits FUNDED this Adapter holds both the position
    ///      being sold and the buyer's money for it; spending that money on a Buy Order would
    ///      both double-count it and break the "paid before delivered" custody promise the
    ///      counterparty funded against. The ceiling is the free balance, not the whole balance.
    function _deployCapital(uint256 amount, address destination) internal {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 locked = lockedProceeds;
        uint256 free = balance > locked ? balance - locked : 0;
        if (amount > free) revert ProceedsLocked(amount, free);
        IERC20(asset()).safeTransfer(destination, amount);
        emit CapitalDeployed(destination, amount, block.timestamp);
    }

    /// @dev The Curator-declared settlement mode behind a live deal.
    function _dealSettlementMode(uint256 dealKey) internal view returns (SettlementMode) {
        return buyOrders[dealKey].mode;
    }

    function _removeLiveDeal(uint256 orderId) internal {
        uint256 len = liveDealOrderIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (liveDealOrderIds[i] == orderId) {
                liveDealOrderIds[i] = liveDealOrderIds[len - 1];
                liveDealOrderIds.pop();
                break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // ERC-4626
    // -----------------------------------------------------------------------

    function totalAssets() public view override returns (uint256) {
        return realAssets();
    }

    /// @dev The share surface is the Vault's capital line into this Adapter, not a public
    ///      product — every one of the four ERC-4626 entry points is closed to everyone else.
    ///      Left open, an outsider could mint shares priced off `realAssets()`
    ///      and redeem them after a deal is revalued upward, taking value that belongs to the
    ///      Vault's own depositors; and a single un-redeemed outside share keeps `realAssets()`
    ///      above zero, which `BaseVault.removeAdapter` requires to be zero — one dust deposit in
    ///      every Adapter would freeze the Vault's ability to wind down for good.
    function _onlyVault() internal view {
        if (msg.sender != vault) revert NotVault();
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _onlyVault();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _onlyVault();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        _onlyVault();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _onlyVault();
        return super.redeem(shares, receiver, owner);
    }

    // -----------------------------------------------------------------------
    // Curator order book
    // -----------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function createBuyOrder(uint256 amount, address destination, SettlementMode mode)
        external
        override
        returns (uint256 orderId)
    {
        _onlyCurator();
        // `destination` is the counterparty being paid. Paying ourselves would leave the USDT
        // in the Adapter while still recording a live deal value, double-counting realAssets().
        if (destination == address(this)) revert SelfDestinationNotAllowed();
        // The zero address would burn the capital on executeBuy while still recording a deal.
        if (destination == address(0)) revert ZeroAddress();
        orderId = nextBuyOrderId++;
        buyOrders[orderId] = Order({
            amount: amount, destination: destination, source: address(0), mode: mode, executed: false, cancelled: false
        });
        emit BuyOrderCreated(orderId, amount, destination, uint8(mode), block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Generic Sell Order — the one asset-exit path
    // -----------------------------------------------------------------------

    /// @inheritdoc IAdapter
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
    ) external override returns (uint256 orderId) {
        _onlyCurator();
        if (payer == address(0) || assetRecipient == address(0)) revert ZeroAddress();
        if (proceeds == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert ExpiryNotInFuture(expiry);
        // An order that neither hands over a token nor retires a deal exits nothing, yet would
        // still take a counterparty's money.
        if (exitAsset == address(0) && !hasDeal) revert ZeroAmount();

        if (exitAsset != address(0)) {
            if (exitAmount == 0) revert ZeroAmount();
            // The subclass decides what this Adapter is willing to part with; BaseAdapter refuses
            // everything, so a Sell Order can never be used to walk an unrelated token out.
            _validateExitAsset(exitAsset, exitAmount);

            uint256 held = _exitAssetBalance(exitAsset);
            uint256 reserved = reservedExitAmount[exitAsset];
            // Availability is measured net of what other unsettled orders already promised, so
            // the same tokens cannot be sold twice and a funded order always finds its asset.
            uint256 free = held > reserved ? held - reserved : 0;
            if (exitAmount > free) revert InsufficientExitAsset(exitAsset, exitAmount, free);
            reservedExitAmount[exitAsset] = reserved + exitAmount;
        } else if (exitAmount != 0) {
            revert ZeroAmount();
        }

        if (hasDeal) {
            DealData storage d = pendingDeposits[dealKey];
            if (d.updatedAt == 0) revert DealNotLive(dealKey);
            uint256 reservedValue = reservedDealValue[dealKey];
            uint256 freeValue = d.dealValue > reservedValue ? d.dealValue - reservedValue : 0;
            if (dealValueReduction > freeValue) {
                revert InsufficientDealValue(dealKey, dealValueReduction, freeValue);
            }
            reservedDealValue[dealKey] = reservedValue + dealValueReduction;
        }

        orderId = nextSellOrderId++;
        sellOrders[orderId] = SellOrder({
            exitAsset: exitAsset,
            exitAmount: exitAmount,
            proceeds: proceeds,
            payer: payer,
            assetRecipient: assetRecipient,
            dealKey: dealKey,
            hasDeal: hasDeal,
            dealValueReduction: dealValueReduction,
            expiry: expiry,
            status: SellOrderStatus.CREATED
        });

        emit SellOrderCreated(orderId, exitAsset, exitAmount, proceeds, payer, assetRecipient, expiry, block.timestamp);
    }

    /// @inheritdoc IAdapter
    /// @dev Permissionless except for the payer check: the counterparty pays this contract
    ///      directly, so the Allocator never holds or approves the proceeds asset and is out of
    ///      the custody path entirely — the defect that made the old `executeSell` pull USDT from
    ///      the Allocator's own wallet. The balance delta is measured rather than trusted so a
    ///      fee-on-transfer token cannot under-deliver and still mark the order FUNDED.
    function fundSellOrder(uint256 orderId) external override {
        SellOrder storage o = _sellOrder(orderId);
        if (o.status != SellOrderStatus.CREATED) {
            revert WrongSellOrderStatus(orderId, uint8(SellOrderStatus.CREATED), uint8(o.status));
        }
        if (msg.sender != o.payer) revert NotOrderPayer(orderId);
        if (block.timestamp > o.expiry) revert SellOrderExpired(orderId, o.expiry);

        uint256 before = IERC20(asset()).balanceOf(address(this));
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), o.proceeds);
        uint256 received = IERC20(asset()).balanceOf(address(this)) - before;
        if (received != o.proceeds) revert ProceedsNotReceived(o.proceeds, received);

        o.status = SellOrderStatus.FUNDED;
        lockedProceeds += o.proceeds;

        emit SellOrderFunded(orderId, msg.sender, o.proceeds, block.timestamp);
    }

    /// @inheritdoc IAdapter
    function cancelSellOrder(uint256 orderId) external override {
        _onlyCuratorOrGuardian();
        SellOrder storage o = _sellOrder(orderId);
        if (o.status == SellOrderStatus.CREATED) {
            _releaseSellReservations(o);
            o.status = SellOrderStatus.CANCELLED;
            emit OrderCancelled(orderId, 1, block.timestamp);
            return;
        }
        if (o.status == SellOrderStatus.FUNDED) {
            // Cancelling a paid order while keeping the payment is not an option at any price.
            _refundSellOrder(orderId, o);
            return;
        }
        revert WrongSellOrderStatus(orderId, uint8(SellOrderStatus.CREATED), uint8(o.status));
    }

    /// @inheritdoc IAdapter
    function refundSellOrder(uint256 orderId) external override {
        SellOrder storage o = _sellOrder(orderId);
        if (o.status != SellOrderStatus.FUNDED) {
            revert WrongSellOrderStatus(orderId, uint8(SellOrderStatus.FUNDED), uint8(o.status));
        }
        if (msg.sender != o.payer) revert NotOrderPayer(orderId);
        // Only once the delivery window has closed — before that the Allocator may still execute.
        if (block.timestamp <= o.expiry) revert SellOrderNotExpired(orderId, o.expiry);
        _refundSellOrder(orderId, o);
    }

    /// @dev Returns the locked proceeds to the payer and frees everything the order held. No pause
    ///      gate on either caller path: returning a counterparty's money and standing down a
    ///      reservation both reduce exposure, and a paused Vault must not trap a payment.
    function _refundSellOrder(uint256 orderId, SellOrder storage o) internal {
        uint256 amount = o.proceeds;
        o.status = SellOrderStatus.REFUNDED;
        lockedProceeds -= amount;
        _releaseSellReservations(o);
        IERC20(asset()).safeTransfer(o.payer, amount);
        emit SellOrderRefunded(orderId, o.payer, amount, block.timestamp);
    }

    function _releaseSellReservations(SellOrder storage o) internal {
        if (o.exitAsset != address(0)) reservedExitAmount[o.exitAsset] -= o.exitAmount;
        if (o.hasDeal) reservedDealValue[o.dealKey] -= o.dealValueReduction;
    }

    function _sellOrder(uint256 orderId) internal view returns (SellOrder storage o) {
        if (orderId >= nextSellOrderId) revert OrderDoesNotExist(orderId);
        o = sellOrders[orderId];
    }

    /// @inheritdoc IAdapter
    function cancelBuyOrder(uint256 orderId) external override {
        _onlyCuratorOrGuardian();
        Order storage o = buyOrders[orderId];
        if (o.executed) revert OrderAlreadyExecuted(orderId);
        if (o.cancelled) revert OrderAlreadyCancelled(orderId);
        o.cancelled = true;
        emit OrderCancelled(orderId, 0, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Emergency freeze — Guardian can halt Allocator execution without cancelling every
    // individually pending order (GUARDIAN_ROLE "freeze Allocator").
    // -----------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function freezeAllocator() external override {
        _onlyGuardian();
        allocatorFrozen = true;
        emit AllocatorFrozen(msg.sender, block.timestamp);
    }

    /// @inheritdoc IAdapter
    function unfreezeAllocator() external override {
        _onlyCurator();
        allocatorFrozen = false;
        emit AllocatorUnfrozen(msg.sender, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Allocator execution
    // -----------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function executeBuy(uint256 orderId) external override {
        _onlyAllocator();
        if (orderId >= nextBuyOrderId) revert OrderDoesNotExist(orderId);
        Order storage o = buyOrders[orderId];
        if (o.cancelled) revert OrderAlreadyCancelled(orderId);
        if (o.executed) revert OrderAlreadyExecuted(orderId);

        o.executed = true;
        _deployCapital(o.amount, o.destination);

        pendingDeposits[orderId] =
            DealData({dealValue: o.amount, updatedAt: block.timestamp, stalenessWindow: defaultStalenessWindow});
        liveDealOrderIds.push(orderId);

        emit BuyOrderExecuted(orderId, block.timestamp);
    }

    /// @inheritdoc IAdapter
    function executeSell(uint256 orderId) external override {
        _onlyAllocator();
        SellOrder storage o = _sellOrder(orderId);
        if (o.status != SellOrderStatus.FUNDED) {
            revert WrongSellOrderStatus(orderId, uint8(SellOrderStatus.FUNDED), uint8(o.status));
        }
        if (block.timestamp > o.expiry) revert SellOrderExpired(orderId, o.expiry);

        o.status = SellOrderStatus.EXECUTED;
        lockedProceeds -= o.proceeds;
        _releaseSellReservations(o);

        // Retire the position in the SAME call that hands it over, in whichever way this Adapter
        // prices it. A Deal-priced position loses `dealValue`; a balance-priced one loses the
        // tokens and re-prices itself off the smaller balance. Either way the exited value stops
        // being counted the instant the counterparty receives it, which is what the old
        // Sell/Rebalance pair never did.
        if (o.hasDeal && o.dealValueReduction > 0) {
            DealData storage d = pendingDeposits[o.dealKey];
            // Saturating, not checked: `clearDealValue` may have retired the deal between this
            // order's creation and its execution, and that retirement is a fact — the position is
            // priced off the delivered token balance from then on, so there is simply nothing left
            // to write off here. A checked subtraction would underflow and strand a Sell Order
            // whose counterparty has already paid, with no way out but expiry and refund.
            // `updateDealData` is the other writer and is guarded at source.
            uint256 applied = d.dealValue < o.dealValueReduction ? d.dealValue : o.dealValueReduction;
            uint256 newValue = d.dealValue - applied;
            d.dealValue = newValue;
            if (newValue == 0) _removeLiveDeal(o.dealKey);
            emit DealValueReducedBySell(orderId, o.dealKey, applied, newValue, block.timestamp);
        }

        if (o.exitAsset != address(0)) {
            _deliverExitAsset(o.exitAsset, o.exitAmount, o.assetRecipient);
        }

        emit SellOrderExecuted(orderId, o.exitAsset, o.exitAmount, o.assetRecipient, o.proceeds, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Exit-asset policy — each subclass names what it will part with
    // -----------------------------------------------------------------------

    /// @dev Reverts unless this Adapter is willing to sell `amount` of `token`. The default
    ///      refuses everything: a Sell Order must never become a way to move an arbitrary token
    ///      out of an Adapter, so an Adapter with no sellable position (LiquidityAdapter today)
    ///      inherits exactly that. Subclasses narrow it to the positions they actually hold.
    function _validateExitAsset(address token, uint256 amount) internal view virtual {
        amount; // silence unused-parameter warning in the default policy
        revert ExitAssetNotSupported(token);
    }

    /// @dev Moves the exit asset out. Only ever reached for a token `_validateExitAsset` accepted.
    function _deliverExitAsset(address token, uint256 amount, address to) internal virtual {
        amount;
        to;
        revert ExitAssetNotSupported(token);
    }

    /// @dev How much of `token` this Adapter holds, for reservation accounting. Overridable so an
    ///      Adapter whose position is not a plain balance can report the right figure.
    function _exitAssetBalance(address token) internal view virtual returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // -----------------------------------------------------------------------
    // ERC-4626 withdrawal guard
    // -----------------------------------------------------------------------

    /// @dev `BaseVault.recallAdapter` withdraws through ERC-4626, so without this the Vault could
    ///      pull out cash a counterparty has paid for an exit that has not happened yet. Locked
    ///      proceeds are off limits until `executeSell` delivers or a refund returns them.
    ///
    ///      The inherited `maxWithdraw` ceiling does not subsume this. That one is share value —
    ///      `convertToAssets(balanceOf(owner))`, driven by `totalAssets()` — whereas this is
    ///      liquidity. An Adapter holding a live deal has share value well above the cash it can
    ///      actually part with, so a withdrawal can sit under `maxWithdraw` and still be reaching
    ///      into locked proceeds. Both checks run; whichever binds first reports.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 locked = lockedProceeds;
        uint256 free = balance > locked ? balance - locked : 0;
        if (assets > free) revert ProceedsLocked(assets, free);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // -----------------------------------------------------------------------
    // Valuation
    // -----------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function windDownToVault() external override {
        // Allocator, matching `BaseVault.recallAdapter` — this is the last recall, not a
        // governance act. It cannot be used to redirect anything: the destination is always
        // `vault`, never the caller.
        _onlyAllocator();

        // Both preconditions guard something real rather than an accounting nicety: a live deal is
        // a position that has not been retired (its value would silently vanish from
        // `grossManagedAssets()` the moment this Adapter is removed), and `lockedProceeds` is a
        // buyer's escrowed payment for a Sell Order this Adapter has not yet delivered against.
        uint256 liveDeals = liveDealOrderIds.length;
        uint256 locked = lockedProceeds;
        if (liveDeals != 0 || locked != 0) revert AdapterNotWoundDown(liveDeals, locked);

        // With no deals and nothing locked, `realAssets()` is exactly this balance, so moving all
        // of it is what takes the Adapter to zero. Deliberately not `_withdraw`: the ERC-4626
        // conversion is the thing that cannot reach zero here.
        uint256 assets = IERC20(asset()).balanceOf(address(this));
        uint256 shares = balanceOf(vault);
        if (shares > 0) _burn(vault, shares);
        if (assets > 0) IERC20(asset()).safeTransfer(vault, assets);

        emit WoundDownToVault(assets, shares, block.timestamp);
    }

    /// @inheritdoc IAdapter
    /// @dev Two disjoint legs: capital still sitting here undeployed, plus the value of every live
    ///      deal it has been deployed into. They never overlap — `_deployCapital` moves the balance
    ///      out in the same call that records the deal — so summing them cannot double count.
    ///
    ///      The idle leg matters because capital arrives here before the order that spends it
    ///      exists (`executeBuy` checks this Adapter's balance). Without it, USDT parked here is
    ///      invisible to `BaseVault.grossManagedAssets()` and, because `totalAssets()` feeds the
    ///      inherited ERC-4626 share math, un-withdrawable by the Vault that owns the shares.
    function realAssets() public view virtual override returns (uint256) {
        // Proceeds locked against a FUNDED Sell Order are not counted: until the exit asset is
        // delivered this Adapter holds both the original position and the payment for it, and
        // counting both would value the same economic thing twice. The original position keeps
        // its valuation; the payment starts counting the moment `executeSell` retires it.
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 locked = lockedProceeds;
        uint256 sum = balance > locked ? balance - locked : 0;
        uint256 len = liveDealOrderIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 dealKey = liveDealOrderIds[i];
            DealData storage d = pendingDeposits[dealKey];
            // Staleness only binds VALUE_RETURN deals: they are knowable *only* from
            // `updateDealData`, so a stale one means the reported value is genuinely unbacked.
            // A TOKEN_RETURN deal has no refresh path at all — `updateDealData` rejects it by
            // design, and `clearDealValue` cannot run until the token is actually delivered — so
            // applying the check to it froze `realAssets()`, and with it pricing, settlement and
            // `removeAdapter`, for any delivery slower than the window.
            if (
                _dealSettlementMode(dealKey) == SettlementMode.VALUE_RETURN
                    && block.timestamp - d.updatedAt > d.stalenessWindow
            ) {
                revert StaleAdapterData(d.updatedAt, d.stalenessWindow);
            }
            sum += d.dealValue;
        }
        return sum;
    }

    /// @notice Sum of live deal values belonging to executed TOKEN_RETURN buy orders — i.e. the
    ///         in-flight order cost that a real, on-chain-readable token balance is expected to
    ///         supersede once the asset is delivered. VALUE_RETURN deals are excluded: their value
    ///         is only ever knowable from `updateDealData`, never from a balance.
    /// @dev    Every term is also a term of `realAssets()`'s sum, so this can never exceed it.
    ///         Skips the staleness check `realAssets()` already performs on the same entries.
    function _liveTokenReturnDealValue() internal view returns (uint256 sum) {
        uint256 len = liveDealOrderIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 dealKey = liveDealOrderIds[i];
            Order storage o = buyOrders[dealKey];
            if (o.executed && o.mode == SettlementMode.TOKEN_RETURN) {
                sum += pendingDeposits[dealKey].dealValue;
            }
        }
    }

    /// @inheritdoc IAdapter
    function updateDealData(uint256 orderId, uint256 newValue) external override {
        _onlyDataProvider();
        Order storage o = buyOrders[orderId];
        if (!o.executed) revert OrderDoesNotExist(orderId);
        if (o.mode != SettlementMode.VALUE_RETURN) {
            revert WrongSettlementMode(orderId, uint8(SettlementMode.VALUE_RETURN), uint8(o.mode));
        }
        // A live Sell Order has already promised to write off `reserved` of this deal at a price
        // its counterparty has been quoted. Revaluing the deal below that promise would either
        // strand the order (nothing left to write off) or, worse, let it settle at the stale
        // higher price and push the markdown onto the Vault. The Data Provider must retire the
        // order first.
        uint256 reserved = reservedDealValue[orderId];
        if (newValue < reserved) revert DealValueBelowReserved(orderId, newValue, reserved);
        pendingDeposits[orderId] =
            DealData({dealValue: newValue, updatedAt: block.timestamp, stalenessWindow: defaultStalenessWindow});
        emit DealDataUpdated(orderId, newValue, block.timestamp);
    }

    /// @inheritdoc IAdapter
    function clearDealValue(uint256 orderId) external override {
        _onlyAllocator();
        Order storage o = buyOrders[orderId];
        if (!o.executed) revert OrderDoesNotExist(orderId);
        if (o.mode != SettlementMode.TOKEN_RETURN) {
            revert WrongSettlementMode(orderId, uint8(SettlementMode.TOKEN_RETURN), uint8(o.mode));
        }
        pendingDeposits[orderId].dealValue = 0;
        _removeLiveDeal(orderId);
        emit DealValueCleared(orderId, block.timestamp);
    }

    /// @inheritdoc IAdapter
    function setStalenessWindow(uint256 window) external override {
        _onlyCuratorDirectOrTimelock();
        defaultStalenessWindow = window;
    }

    /// @inheritdoc IAdapter
    function setDataProvider(address provider) external override {
        _onlyCuratorDirectOrTimelock();
        dataProvider = provider;
        emit DataProviderSet(provider, block.timestamp);
    }
}
