// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IMintBurnController
/// @notice Interface for the Issuer + Token Agent mint/burn control contract. Both roles are
///         per-assetId: the Issuer is that asset's AssetRegistry owner directly (no separate
///         issuer grant); the Token Agent is appointed by that same owner via `setTokenAgent`.
///         4-step flow: Issuer initiates → Token Agent approves → contract checks both callers →
///         RWAToken minted/burned. Independent mint and burn nonce sequences.
///         (development-plan §3.2.1; 角色权限与职责修改方案 §11.3)
interface IMintBurnController {
    // -----------------------------------------------------------------------
    // Structs (plan §3.2.1)
    // -----------------------------------------------------------------------

    /// @notice Pending mint request record, keyed by mint nonce.
    struct MintRequest {
        uint256 assetId;
        uint256 amount;
        address to;
        bool approved;
        bool executed;
    }

    /// @notice Pending burn request record, keyed by burn nonce.
    struct BurnRequest {
        uint256 assetId;
        uint256 amount;
        address from;
        bool approved;
        bool executed;
    }

    // -----------------------------------------------------------------------
    // Events (§3.1.2)
    // -----------------------------------------------------------------------

    event MintInitiated(
        uint256 indexed nonce, uint256 indexed assetId, uint256 amount, address indexed to, uint256 timestamp
    );
    event MintApproved(
        uint256 indexed nonce, uint256 indexed assetId, uint256 amount, address indexed to, uint256 timestamp
    );
    event BurnInitiated(
        uint256 indexed nonce, uint256 indexed assetId, uint256 amount, address indexed from, uint256 timestamp
    );
    event BurnApproved(
        uint256 indexed nonce, uint256 indexed assetId, uint256 amount, address indexed from, uint256 timestamp
    );
    event TokenAgentSet(uint256 indexed assetId, address indexed agent, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error NotIssuer(); // caller is not this assetId's AssetRegistry owner
    error NotTokenAgent(); // caller is not this assetId's appointed Token Agent
    error NotAssetRegistry(); // caller is not the wired AssetRegistry
    error ZeroAmount();
    error AssetNotRegistered(); // assetId not active in AssetRegistry
    error RequestNotFound(); // approve called for a nonce that was never initiated
    error AlreadyExecuted(); // approve called for an already-executed request
    error InsufficientBalance();

    // -----------------------------------------------------------------------
    // Mint flow
    // -----------------------------------------------------------------------

    /// @notice Step 1 — that assetId's Issuer (AssetRegistry owner) initiates a mint request.
    /// @return nonce The mint nonce under which the request is stored.
    function initiateMint(uint256 assetId, uint256 amount, address to) external returns (uint256 nonce);

    /// @notice Steps 2–4 — that assetId's Token Agent approves and contract calls RWAToken.mint.
    function approveMint(uint256 nonce) external;

    // -----------------------------------------------------------------------
    // Burn flow
    // -----------------------------------------------------------------------

    /// @notice Step 1 — that assetId's Issuer (AssetRegistry owner) initiates a burn request.
    /// @return nonce The burn nonce under which the request is stored.
    function initiateBurn(uint256 assetId, uint256 amount, address from) external returns (uint256 nonce);

    /// @notice Steps 2–4 — that assetId's Token Agent approves and contract calls RWAToken.burn.
    function approveBurn(uint256 nonce) external;

    /// @notice Appoints (or replaces) the Token Agent for a single assetId.
    /// @dev    Access: that assetId's AssetRegistry owner.
    function setTokenAgent(uint256 assetId, address agent) external;

    // -----------------------------------------------------------------------
    // State accessors (plan §3.2.1)
    // -----------------------------------------------------------------------

    /// @notice Called by AssetRegistry after deploying a new RWAToken; registers the token mapping.
    /// @dev    Access: only the wired AssetRegistry address. (plan §3.2.1, revised 2026-06-25)
    function registerToken(uint256 assetId, address token) external;

    function tokenAgentOf(uint256 assetId) external view returns (address);
    function nextMintNonce() external view returns (uint256);
    function nextBurnNonce() external view returns (uint256);

    function mintRequests(uint256 nonce)
        external
        view
        returns (uint256 assetId, uint256 amount, address to, bool approved, bool executed);

    function burnRequests(uint256 nonce)
        external
        view
        returns (uint256 assetId, uint256 amount, address from, bool approved, bool executed);
}
