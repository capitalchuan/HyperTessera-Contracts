// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGate} from "../interfaces/IGate.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";

/// @dev `BaseVault` exposes its settlement token as a public state variable, which `IBaseVault`
///      does not declare. Declaring it there would force an `override` onto the
///      `BaseVault.usdt` storage slot, so the accessor is reached through this minimal
///      interface instead.
interface IVaultSettlementToken {
    function usdt() external view returns (address);
}

/// @title KYTDepositGateway
/// @notice Off-chain address-screening (KYT) front-end for a single Vault's subscription path.
///         Adds pre-deposit KYT without modifying the Vault: the Vault already exposes
///         a `gate` hook (`BaseVault.requestDeposit` → `IGate.isAllowed(owner)`), and this
///         contract is installed there via the existing `BaseVault.setGate()` governance path.
///
///         Flow when KYT is ON (`vault.gate == address(this)`):
///           1. payer calls `requestDeposit(assets, owner)` — nothing is pulled, a PENDING
///              record is written and `ScreeningRequested` is emitted;
///           2. the off-chain listener screens the recorded `payer` and the oracle account
///              calls `fulfill(id, passed, screenedAt)`;
///           3. on `passed`, the same transaction pulls `assets` from `payer`, approves the
///              Vault and calls `vault.requestDeposit(assets, owner)` — "payer wallet →
///              Gateway → Vault" atomically, with the subscription credited to `owner`.
///
///         Flow when KYT is OFF (`vault.gate == address(0)`): callers go straight to
///         `vault.requestDeposit` and this contract is not involved. Switching between the two
///         is `BaseVault.setGate()` only — this contract holds no KYT on/off switch of its own.
///
/// @dev    SCOPE — this gate covers the subscription path only. Redemption, claim, refund and
///         share transfers are deliberately not screened, matching the Vault's own gate
///         placement. A screened-out address can therefore still acquire shares on the
///         secondary path (`claimDeposit(requestId, receiver)` takes an arbitrary `receiver`,
///         and share transfers are unrestricted). That is a compliance-policy decision, not an
///         oversight.
///
/// @dev    `isAllowed` does NOT implement an address allowlist. The Vault calls it with
///         `owner`, while the screened party is `payer`, so an address-based answer would
///         check the wrong account. Instead this contract answers "am I currently executing a
///         fulfilled, screened deposit for this owner?". The practical effect is that while
///         KYT is ON, every direct `vault.requestDeposit` call reverts with `GateBlocked` and
///         the Gateway is the only admissible subscription entry point.
contract KYTDepositGateway is IGate, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    enum RequestState {
        NONE,
        PENDING,
        EXECUTED,
        REJECTED,
        CANCELLED
    }

    struct ScreeningRequest {
        address payer; // screened party; pays the assets on fulfilment
        address owner; // Vault-side subscription owner
        uint256 assets;
        uint64 requestedAt;
        uint64 expiresAt; // snapshotted at request time
        RequestState state;
    }

    // -----------------------------------------------------------------------
    // Custom errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAssets();
    error Unauthorized();
    error RequestNotFound(uint256 id);
    error RequestNotPending(uint256 id, RequestState state);
    error RequestExpired(uint256 id);
    error InvalidScreeningTime(uint64 screenedAt);
    error InvalidValidityPeriod(uint64 validityPeriod);

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event ScreeningRequested(
        uint256 indexed id, address indexed payer, address indexed owner, uint256 assets, uint64 expiresAt
    );
    event ScreeningRejected(uint256 indexed id, address indexed payer, uint64 screenedAt, uint256 timestamp);
    event DepositExecuted(
        uint256 indexed id, uint256 indexed vaultRequestId, address indexed owner, uint256 assets, uint64 screenedAt
    );
    event RequestCancelled(uint256 indexed id, address indexed payer, uint256 timestamp);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle, uint256 timestamp);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin, uint256 timestamp);
    event ValidityPeriodUpdated(uint64 oldPeriod, uint64 newPeriod, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Immutables / storage
    // -----------------------------------------------------------------------

    /// @notice The single Vault this Gateway fronts. One Gateway is deployed per Vault.
    address public immutable vault;

    /// @notice The Vault's settlement token, cached at construction from `vault.usdt()`.
    address public immutable asset;

    /// @notice Configures `oracle` and `validityPeriod`. Expected to be the protocol multi-sig.
    address public admin;

    /// @notice The only account permitted to submit screening results.
    address public oracle;

    /// @notice Validity window stamped onto new requests. Existing requests keep the window
    ///         they were created with.
    uint64 public validityPeriod;

    uint256 public nextRequestId = 1;

    mapping(uint256 => ScreeningRequest) private _requests;

    /// @dev Non-zero only for the duration of the `vault.requestDeposit` call inside `fulfill`.
    ///      This is what `isAllowed` answers from. Held in ordinary storage rather than
    ///      transient storage because the project pins solc 0.8.24 with no `evm_version` set in
    ///      foundry.toml, so a Cancun-only TSTORE cannot be assumed on every target chain.
    address private _inFlightOwner;

    uint64 public constant MIN_VALIDITY_PERIOD = 5 minutes;
    uint64 public constant MAX_VALIDITY_PERIOD = 7 days;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address vault_, address oracle_, address admin_, uint64 validityPeriod_) {
        if (vault_ == address(0) || oracle_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (validityPeriod_ < MIN_VALIDITY_PERIOD || validityPeriod_ > MAX_VALIDITY_PERIOD) {
            revert InvalidValidityPeriod(validityPeriod_);
        }

        vault = vault_;
        asset = IVaultSettlementToken(vault_).usdt();
        oracle = oracle_;
        admin = admin_;
        validityPeriod = validityPeriod_;
    }

    // -----------------------------------------------------------------------
    // IGate
    // -----------------------------------------------------------------------

    /// @inheritdoc IGate
    /// @dev Passes only for the `owner` of the deposit currently being executed by `fulfill`.
    ///      Outside that window `_inFlightOwner` is zero and every account is refused, which is
    ///      what forces subscriptions through this Gateway while KYT is ON.
    function isAllowed(address account) external view returns (bool) {
        return account != address(0) && account == _inFlightOwner;
    }

    // -----------------------------------------------------------------------
    // Subscription flow
    // -----------------------------------------------------------------------

    /// @notice Registers a subscription for screening. Moves no funds.
    /// @dev    The payer is always `msg.sender` — it is never taken from calldata, so a caller
    ///         cannot have a third party screened in their place.
    /// @dev    WARNING: if a refund is later issued for this subscription, the Vault pays
    ///         `owner`, not `payer`. A custodian paying on someone else's behalf will not receive
    ///         the refund; settling that back to the payer is the caller's responsibility. This
    ///         contract deliberately does not modify the Vault's refund path.
    /// @param  assets Settlement-token amount to subscribe.
    /// @param  owner  Account credited with the Vault-side subscription; must be non-zero and
    ///                must have approved this Gateway via `vault.setOperator(gateway, true)`.
    /// @return id     The screening request id.
    function requestDeposit(uint256 assets, address owner) external nonReentrant returns (uint256 id) {
        if (assets == 0) revert ZeroAssets();
        if (owner == address(0)) revert ZeroAddress();

        uint64 expiresAt = uint64(block.timestamp) + validityPeriod;

        id = nextRequestId++;
        _requests[id] = ScreeningRequest({
            payer: msg.sender,
            owner: owner,
            assets: assets,
            requestedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            state: RequestState.PENDING
        });

        emit ScreeningRequested(id, msg.sender, owner, assets, expiresAt);
    }

    /// @notice Submits a screening verdict. On `passed`, executes the subscription immediately
    ///         in this same transaction.
    /// @dev    Reverts if the Vault refuses the deposit (subscription window closed, cap now
    ///         exceeded, payer approval or balance insufficient, vault liquidated). The request
    ///         stays PENDING and the verdict is not recorded, so the off-chain listener must
    ///         implement its own retry and give-up policy. No funds have moved at that point.
    /// @param  id         Screening request id.
    /// @param  passed     Verdict from the off-chain address screening of the recorded payer.
    /// @param  screenedAt Unix time the screening was performed.
    function fulfill(uint256 id, bool passed, uint64 screenedAt) external nonReentrant {
        if (msg.sender != oracle) revert Unauthorized();

        ScreeningRequest storage req = _requests[id];
        if (req.state == RequestState.NONE) revert RequestNotFound(id);
        if (req.state != RequestState.PENDING) revert RequestNotPending(id, req.state);
        if (block.timestamp > req.expiresAt) revert RequestExpired(id);

        // A verdict cannot be dated in the future. There is deliberately NO lower bound: the
        // listener is allowed to submit a screening it performed before the request was made
        // (screening results are commonly cached and reused), and a lower bound would reject
        // that legitimate flow while protecting nothing — an oracle willing to submit an ancient
        // screening is already free to submit `passed = true` outright. How stale a screening may
        // be is the listener's risk policy, not an invariant this contract can enforce.
        // `screenedAt` is recorded for provenance; replay is prevented by the state machine
        // (each request is fulfillable exactly once) and by `expiresAt`.
        if (screenedAt > block.timestamp) revert InvalidScreeningTime(screenedAt);

        if (!passed) {
            req.state = RequestState.REJECTED;
            emit ScreeningRejected(id, req.payer, screenedAt, block.timestamp);
            return;
        }

        // Effects before interactions — the request is closed out before any external call.
        req.state = RequestState.EXECUTED;
        address payer = req.payer;
        address owner = req.owner;
        uint256 assets = req.assets;

        IERC20(asset).safeTransferFrom(payer, address(this), assets);
        IERC20(asset).forceApprove(vault, assets);

        _inFlightOwner = owner;
        uint256 vaultRequestId = IBaseVault(vault).requestDeposit(assets, owner);
        _inFlightOwner = address(0);

        // The Vault pulls exactly `assets`, so this should already be zero; clearing it keeps a
        // non-conforming token from leaving a standing allowance behind.
        IERC20(asset).forceApprove(vault, 0);

        emit DepositExecuted(id, vaultRequestId, owner, assets, screenedAt);
    }

    /// @notice Withdraws a pending request. Only the recorded payer may cancel their own.
    function cancel(uint256 id) external {
        ScreeningRequest storage req = _requests[id];
        if (req.state == RequestState.NONE) revert RequestNotFound(id);
        if (msg.sender != req.payer) revert Unauthorized();
        if (req.state != RequestState.PENDING) revert RequestNotPending(id, req.state);

        req.state = RequestState.CANCELLED;
        emit RequestCancelled(id, msg.sender, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @notice The full screening record for `id`. A request that is still PENDING past its
    ///         `expiresAt` can never execute and needs no cleanup.
    function getRequest(uint256 id) external view returns (ScreeningRequest memory) {
        return _requests[id];
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    /// @notice Rotates the account permitted to call `fulfill`.
    function setOracle(address oracle_) external {
        if (msg.sender != admin) revert Unauthorized();
        if (oracle_ == address(0)) revert ZeroAddress();
        address old = oracle;
        oracle = oracle_;
        emit OracleUpdated(old, oracle_, block.timestamp);
    }

    /// @notice Hands admin authority to `newAdmin`.
    /// @dev    Single-step, matching `IVaultRoles.transferOwnership`. Without this the oracle
    ///         could never be rotated again after an admin key loss, which would strand the
    ///         Gateway: `setGate(address(0))` would be the only remaining remedy.
    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin) revert Unauthorized();
        if (newAdmin == address(0)) revert ZeroAddress();
        address old = admin;
        admin = newAdmin;
        emit AdminTransferred(old, newAdmin, block.timestamp);
    }

    /// @notice Sets the validity window stamped onto subsequent requests. Requests already
    ///         created keep the `expiresAt` they were issued with.
    function setValidityPeriod(uint64 validityPeriod_) external {
        if (msg.sender != admin) revert Unauthorized();
        if (validityPeriod_ < MIN_VALIDITY_PERIOD || validityPeriod_ > MAX_VALIDITY_PERIOD) {
            revert InvalidValidityPeriod(validityPeriod_);
        }
        uint64 old = validityPeriod;
        validityPeriod = validityPeriod_;
        emit ValidityPeriodUpdated(old, validityPeriod_, block.timestamp);
    }
}
