// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IReservePSM} from "../interfaces/IReservePSM.sol";
import {IHyperAccessControl} from "../interfaces/IHyperAccessControl.sol";
import {WrappedAsset} from "./WrappedAsset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title ReservePSM
/// @notice Independent asset wrap/unwrap module. Converts restricted assets into freely-transferable
///         Wrapped Token ERC-20s in one of two independent modes, and burns them on unwrap.
///
///         Token Custody Mode: the underlying is an on-chain ERC-20 held in custody by this PSM.
///         `wrap` pulls it 1:1 and mints wrapped; `unwrap` burns wrapped and returns it 1:1.
///
///         Document Proof Mode: there is no on-chain custody. Minting requires an off-chain
///         signature from the asset's authorised signer; `unwrap` burns the full balance and emits
///         `ReleaseRequested` as the on-chain trigger for an off-chain release.
///
///         Fully decoupled from Vault / Settlement / StateManager / USDT settlement.
///
///         Mint authorisations are checked with `SignatureChecker`, so an asset's authorised signer
///         may be either an EOA (ECDSA) or a contract wallet implementing EIP-1271 (e.g. Safe).
contract ReservePSM is IReservePSM {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    IHyperAccessControl public immutable ac;

    /// @inheritdoc IReservePSM
    mapping(uint256 assetId => AssetConfig) public override assetConfig;

    /// @inheritdoc IReservePSM
    mapping(uint256 assetId => address) public override controllerOf;

    /// @inheritdoc IReservePSM
    bool public override globalPaused;

    /// @inheritdoc IReservePSM
    mapping(uint256 assetId => mapping(uint256 nonce => bool)) public override usedNonce;

    /// @inheritdoc IReservePSM
    mapping(uint256 assetId => mapping(address holder => bytes32)) public override documentIdOf;

    /// @dev All document IDs minted to a holder since their last full unwrap, oldest first.
    mapping(uint256 assetId => mapping(address holder => bytes32[])) internal _pendingDocumentIds;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address accessControl_) {
        if (accessControl_ == address(0)) revert ZeroAddress();
        ac = IHyperAccessControl(accessControl_);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _onlyGovernor() internal view {
        if (!ac.hasRole(ac.GOVERNOR_ROLE(), msg.sender)) revert NotGovernor();
    }

    function _onlyWrapperController(uint256 assetId) internal view {
        if (controllerOf[assetId] != msg.sender) revert NotWrapperController(assetId);
    }

    function _requireConfigured(uint256 assetId) internal view returns (AssetConfig storage cfg) {
        cfg = assetConfig[assetId];
        if (cfg.wrappedToken == address(0)) revert AssetNotConfigured(assetId);
    }

    function _requireNotPaused(AssetConfig storage cfg, uint256 assetId) internal view {
        if (globalPaused) revert GloballyPaused();
        if (cfg.paused) revert AssetIsPaused(assetId);
    }

    // -----------------------------------------------------------------------
    // Configuration (permissionless deploy; per-asset Wrapper Controller thereafter)
    // -----------------------------------------------------------------------

    /// @inheritdoc IReservePSM
    function deployWrappedToken(
        uint256 assetId,
        AssetMode mode,
        address underlyingToken,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        bool allowPartialUnwrap
    ) external override {
        // Was permissionless, which let anyone front-run an expected assetId, deploy its wrapped
        // token first and install themselves as its controller — without the assetId even having
        // to exist in AssetRegistry (Audit Feedback V2 #8).
        _onlyGovernor();
        AssetConfig storage cfg = assetConfig[assetId];
        if (cfg.wrappedToken != address(0)) revert AssetAlreadyConfigured(assetId);

        if (mode == AssetMode.TOKEN_CUSTODY) {
            if (underlyingToken == address(0)) revert ZeroAddress();
        } else {
            // DOCUMENT_PROOF has no on-chain underlying and never allows partial unwrap.
            if (underlyingToken != address(0)) revert WrongAssetMode(assetId);
            allowPartialUnwrap = false;
        }

        WrappedAsset wa = new WrappedAsset(address(this), name, symbol, decimals);

        cfg.mode = mode;
        cfg.underlyingToken = underlyingToken;
        cfg.wrappedToken = address(wa);
        cfg.allowPartialUnwrap = allowPartialUnwrap;
        controllerOf[assetId] = msg.sender;

        emit WrappedTokenDeployed(assetId, mode, address(wa), underlyingToken, block.timestamp);
    }

    /// @inheritdoc IReservePSM
    function setAuthorizedSigner(uint256 assetId, address signer) external override {
        _onlyWrapperController(assetId);
        if (signer == address(0)) revert ZeroAddress();
        AssetConfig storage cfg = _requireConfigured(assetId);
        if (cfg.mode != AssetMode.DOCUMENT_PROOF) revert WrongAssetMode(assetId);

        cfg.authorizedSigner = signer;
        emit AuthorizedSignerSet(assetId, signer, block.timestamp);
    }

    /// @inheritdoc IReservePSM
    function pause() external override {
        _onlyGovernor();
        globalPaused = true;
        emit Paused(block.timestamp);
    }

    /// @inheritdoc IReservePSM
    function unpause() external override {
        _onlyGovernor();
        globalPaused = false;
        emit Unpaused(block.timestamp);
    }

    /// @inheritdoc IReservePSM
    function pauseAsset(uint256 assetId) external override {
        _onlyWrapperController(assetId);
        AssetConfig storage cfg = _requireConfigured(assetId);
        cfg.paused = true;
        emit AssetPaused(assetId, block.timestamp);
    }

    /// @inheritdoc IReservePSM
    function unpauseAsset(uint256 assetId) external override {
        _onlyWrapperController(assetId);
        AssetConfig storage cfg = _requireConfigured(assetId);
        cfg.paused = false;
        emit AssetUnpaused(assetId, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Core flows (permissionless)
    // -----------------------------------------------------------------------

    /// @inheritdoc IReservePSM
    function wrap(uint256 assetId, uint256 amount, address to) external override {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        AssetConfig storage cfg = _requireConfigured(assetId);
        if (cfg.mode != AssetMode.TOKEN_CUSTODY) revert WrongAssetMode(assetId);
        _requireNotPaused(cfg, assetId);

        // CEI: external token pull, then mint. Measure the actual balance delta rather than
        // trusting `amount` so fee-on-transfer/rebasing underlyings can't over-mint wrapped supply.
        IERC20 underlying = IERC20(cfg.underlyingToken);
        uint256 balanceBefore = underlying.balanceOf(address(this));
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = underlying.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();

        WrappedAsset(cfg.wrappedToken).mint(to, received);

        emit Wrapped(assetId, msg.sender, received, to, block.timestamp);
    }

    /// @inheritdoc IReservePSM
    function mintWithAuthorization(
        uint256 assetId,
        uint256 amount,
        address to,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature,
        bytes32 documentId
    ) external override {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        AssetConfig storage cfg = _requireConfigured(assetId);
        if (cfg.mode != AssetMode.DOCUMENT_PROOF) revert WrongAssetMode(assetId);
        _requireNotPaused(cfg, assetId);

        if (block.timestamp > expiry) revert SignatureExpired(expiry);
        if (usedNonce[assetId][nonce]) revert NonceAlreadyUsed(assetId, nonce);

        bytes32 digest =
            keccak256(abi.encode(assetId, amount, to, nonce, expiry, documentId, address(this), block.chainid));
        address expectedSigner = cfg.authorizedSigner;
        if (
            expectedSigner == address(0)
                || !SignatureChecker.isValidSignatureNow(
                    expectedSigner, MessageHashUtils.toEthSignedMessageHash(digest), signature
                )
        ) revert InvalidSigner(expectedSigner);

        usedNonce[assetId][nonce] = true;
        documentIdOf[assetId][to] = documentId;
        _pendingDocumentIds[assetId][to].push(documentId);
        WrappedAsset(cfg.wrappedToken).mint(to, amount);

        emit MintedWithAuthorization(assetId, to, amount, nonce, documentId, block.timestamp);
    }

    /// @inheritdoc IReservePSM
    function unwrap(uint256 assetId, uint256 amount, address to) external override {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        AssetConfig storage cfg = _requireConfigured(assetId);
        _requireNotPaused(cfg, assetId);

        WrappedAsset wa = WrappedAsset(cfg.wrappedToken);
        uint256 balance = wa.balanceOf(msg.sender);

        if (cfg.mode == AssetMode.TOKEN_CUSTODY) {
            if (!cfg.allowPartialUnwrap && amount != balance) revert PartialUnwrapNotAllowed(assetId);
            if (amount > balance) revert IncompleteUnwrap(assetId, amount, balance);
            // Burn from holder (PSM-gated burn), then release underlying 1:1.
            wa.burn(msg.sender, amount);
            IERC20(cfg.underlyingToken).safeTransfer(to, amount);
            emit Unwrapped(assetId, msg.sender, amount, to, block.timestamp);
        } else {
            // DOCUMENT_PROOF: always full-balance-only; no on-chain underlying release.
            if (amount != balance) revert IncompleteUnwrap(assetId, amount, balance);
            bytes32[] memory docIds = _pendingDocumentIds[assetId][msg.sender];
            delete _pendingDocumentIds[assetId][msg.sender];
            delete documentIdOf[assetId][msg.sender];
            wa.burn(msg.sender, amount);
            if (docIds.length == 0) {
                emit ReleaseRequested(assetId, msg.sender, amount, to, bytes32(0), block.timestamp);
            } else {
                for (uint256 i = 0; i < docIds.length; i++) {
                    emit ReleaseRequested(assetId, msg.sender, amount, to, docIds[i], block.timestamp);
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @inheritdoc IReservePSM
    function pendingDocumentIds(uint256 assetId, address holder) external view override returns (bytes32[] memory) {
        return _pendingDocumentIds[assetId][holder];
    }

    /// @inheritdoc IReservePSM
    function wrappedTokenOf(uint256 assetId) external view override returns (address) {
        return assetConfig[assetId].wrappedToken;
    }

    /// @inheritdoc IReservePSM
    function assetModeOf(uint256 assetId) external view override returns (AssetMode) {
        _requireConfigured(assetId);
        return assetConfig[assetId].mode;
    }
}
