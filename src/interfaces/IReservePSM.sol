// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IReservePSM
/// @notice Independent asset wrap/unwrap module. Converts restricted / custodied / document-proof
///         assets into freely-transferable Wrapped Token ERC-20s, and burns them on unwrap to
///         release the underlying token (Token Custody Mode) or trigger an off-chain release
///         request (Document Proof Mode). Fully decoupled from Vault / Settlement / StateManager.
interface IReservePSM {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    enum AssetMode {
        TOKEN_CUSTODY,
        DOCUMENT_PROOF
    }

    struct AssetConfig {
        AssetMode mode;
        address underlyingToken; // TOKEN_CUSTODY only; address(0) for DOCUMENT_PROOF
        address wrappedToken; // deployed WrappedAsset ERC-20
        bool allowPartialUnwrap; // TOKEN_CUSTODY only; DOCUMENT_PROOF is always full-balance-only
        address authorizedSigner; // DOCUMENT_PROOF only
        bool paused; // per-asset pause
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event WrappedTokenDeployed(
        uint256 indexed assetId, AssetMode mode, address wrappedToken, address underlyingToken, uint256 timestamp
    );
    event AuthorizedSignerSet(uint256 indexed assetId, address signer, uint256 timestamp);
    event Wrapped(uint256 indexed assetId, address indexed caller, uint256 amount, address to, uint256 timestamp);
    event MintedWithAuthorization(
        uint256 indexed assetId,
        address indexed to,
        uint256 amount,
        uint256 nonce,
        bytes32 documentId,
        uint256 timestamp
    );
    event Unwrapped(uint256 indexed assetId, address indexed caller, uint256 amount, address to, uint256 timestamp);
    event ReleaseRequested(
        uint256 indexed assetId,
        address indexed caller,
        uint256 amount,
        address to,
        bytes32 documentId,
        uint256 timestamp
    );
    event Paused(uint256 timestamp);
    event Unpaused(uint256 timestamp);
    event AssetPaused(uint256 indexed assetId, uint256 timestamp);
    event AssetUnpaused(uint256 indexed assetId, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error NotGovernor();
    error NotWrapperController(uint256 assetId);
    error AssetNotConfigured(uint256 assetId);
    error AssetAlreadyConfigured(uint256 assetId);
    error WrongAssetMode(uint256 assetId);
    error PartialUnwrapNotAllowed(uint256 assetId);
    error IncompleteUnwrap(uint256 assetId, uint256 amount, uint256 balance);
    error InvalidSigner(address recovered);
    error SignatureExpired(uint256 expiry);
    error NonceAlreadyUsed(uint256 assetId, uint256 nonce);
    error GloballyPaused();
    error AssetIsPaused(uint256 assetId);

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    /// @notice Configure an asset's mode + underlying + partial-unwrap flag and deploy its
    ///         WrappedAsset ERC-20. Callable once per assetId; the caller becomes that assetId's
    ///         Wrapper Controller.
    /// @dev    Access: permissionless (first caller wins per assetId).
    function deployWrappedToken(
        uint256 assetId,
        AssetMode mode,
        address underlyingToken,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        bool allowPartialUnwrap
    ) external;

    /// @notice Set the authorised off-chain signer for a DOCUMENT_PROOF asset.
    /// @dev    Access: that assetId's Wrapper Controller.
    function setAuthorizedSigner(uint256 assetId, address signer) external;

    /// @notice Pause / unpause the whole PSM. Access: GOVERNOR_ROLE.
    function pause() external;
    function unpause() external;

    /// @notice Pause / unpause a single asset.
    /// @dev    Access: that assetId's Wrapper Controller.
    function pauseAsset(uint256 assetId) external;
    function unpauseAsset(uint256 assetId) external;

    /// @notice The Wrapper Controller for a configured assetId (address(0) if unconfigured).
    function controllerOf(uint256 assetId) external view returns (address);

    // -----------------------------------------------------------------------
    // Core flows (permissionless)
    // -----------------------------------------------------------------------

    /// @notice TOKEN_CUSTODY: pull `amount` of the underlying token from the caller and mint
    ///         `amount` of Wrapped Token 1:1 to `to`.
    function wrap(uint256 assetId, uint256 amount, address to) external;

    /// @notice DOCUMENT_PROOF: mint Wrapped Token to `to` against an off-chain signature from the
    ///         asset's authorised signer. The signature covers
    ///         `(assetId, amount, to, nonce, expiry, documentId, address(this), block.chainid)` —
    ///         `documentId` is part of the signed digest, not a caller-supplied side channel, so a
    ///         signer's authorization is bound to the specific document it attests to. `documentId`
    ///         is appended to `to`'s pending list so every document backing a holder's balance is
    ///         echoed (not just the most recent) when that balance is later unwrapped.
    function mintWithAuthorization(
        uint256 assetId,
        uint256 amount,
        address to,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature,
        bytes32 documentId
    ) external;

    /// @notice Unified unwrap entry point. TOKEN_CUSTODY burns and releases the underlying token
    ///         1:1 (full-balance-only unless partial unwrap is allowed). DOCUMENT_PROOF is always
    ///         full-balance-only, burns and emits ReleaseRequested with the stored documentId.
    function unwrap(uint256 assetId, uint256 amount, address to) external;

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function assetConfig(uint256 assetId)
        external
        view
        returns (
            AssetMode mode,
            address underlyingToken,
            address wrappedToken,
            bool allowPartialUnwrap,
            address authorizedSigner,
            bool paused
        );

    function globalPaused() external view returns (bool);
    function usedNonce(uint256 assetId, uint256 nonce) external view returns (bool);
    function documentIdOf(uint256 assetId, address holder) external view returns (bytes32);
    function pendingDocumentIds(uint256 assetId, address holder) external view returns (bytes32[] memory);
    function wrappedTokenOf(uint256 assetId) external view returns (address);
    function assetModeOf(uint256 assetId) external view returns (AssetMode);
}
