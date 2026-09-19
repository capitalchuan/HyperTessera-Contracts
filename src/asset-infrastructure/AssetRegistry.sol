// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IMintBurnController} from "../interfaces/IMintBurnController.sol";
import {RWAToken} from "./RWAToken.sol";
import {MintBurnController} from "./MintBurnController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProtocolFeeConfig} from "../interfaces/IProtocolFeeConfig.sol";
import {CreationFeeAction, FeePaymentKind} from "../libs/Types.sol";

/// @title AssetRegistry
/// @notice Permissionless on-chain registry of tokenised real-world assets. Any address may
///         register an asset — the registrant becomes the asset owner (and that asset's Issuer
///         for MintBurnController purposes). Each registration deploys a dedicated RWAToken ERC-20
///         and registers the token with MintBurnController in the same transaction. Fully
///         decoupled from HyperAccessControl / StateManager / Vault registration — asset-local
///         authority lives entirely on this Registry.
contract AssetRegistry is IAssetRegistry {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    mapping(uint256 assetId => AssetInfo) private _assets;

    /// @dev Kept outside AssetInfo on purpose: appending to the struct would change getAsset()'s
    ///      ABI return shape and silently break positional decoding on existing front ends.
    /// @inheritdoc IAssetRegistry
    mapping(uint256 assetId => string) public override metadataURIOf;

    mapping(uint256 assetId => ProductInfo) private _productInfo;

    uint256 public override nextAssetId;

    /// @notice Deployed by this Registry's own constructor — immutable, no setter, never zero.
    address public immutable override mintBurnController;

    IProtocolFeeConfig internal immutable _feeConfig;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address feeConfig_) {
        if (feeConfig_ == address(0)) revert ZeroAddress();
        _feeConfig = IProtocolFeeConfig(feeConfig_);
        nextAssetId = 1;
        // Deployed internally (rather than wired post-deploy) so mintBurnController is truly
        // immutable and there is no setter/wiring window at all.
        mintBurnController = address(new MintBurnController(address(this)));
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _onlyOwner(uint256 assetId) internal view {
        if (_assets[assetId].owner != msg.sender) revert NotAssetOwner(assetId, msg.sender);
    }

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @inheritdoc IAssetRegistry
    function registerAsset(
        bytes32 metadataHash,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        FeePaymentKind feeKind,
        ProductInfo calldata product
    ) external payable override returns (uint256 assetId, address token) {
        // Permissionless — no role check; msg.sender becomes owner.
        _collectCreationFee(CreationFeeAction.RegisterAsset, feeKind);

        assetId = nextAssetId;
        nextAssetId = assetId + 1;

        RWAToken rwaToken = new RWAToken(address(this), assetId, name, symbol, decimals, mintBurnController);
        token = address(rwaToken);

        _assets[assetId] = AssetInfo({
            metadataHash: metadataHash, token: token, active: true, registeredAt: block.timestamp, owner: msg.sender
        });

        IMintBurnController(mintBurnController).registerToken(assetId, token);

        ProductInfo memory p = product;
        p.issuer = msg.sender; // forced — a caller must not be able to name someone else as issuer
        _productInfo[assetId] = p;

        emit ProductInfoSet(
            assetId,
            msg.sender,
            p.productName,
            p.annualYieldRateBps,
            p.maturityTimestamp,
            p.underlyingAsset,
            block.timestamp
        );

        emit AssetRegistered(assetId, msg.sender, token, metadataHash, block.timestamp);
    }

    function _collectCreationFee(CreationFeeAction action, FeePaymentKind kind) internal {
        uint256 fee = _feeConfig.feeOf(action, kind);
        if (kind == FeePaymentKind.Native) {
            if (msg.value != fee) revert IncorrectNativeFee(fee, msg.value);
            if (fee > 0) {
                (bool ok,) = _feeConfig.revenuePool().call{value: fee}("");
                if (!ok) revert FeeTransferFailed();
            }
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            if (fee > 0) {
                address token = _feeConfig.paymentTokenOf(kind);
                if (token == address(0)) revert PaymentTokenNotConfigured(kind);
                IERC20(token).safeTransferFrom(msg.sender, _feeConfig.revenuePool(), fee);
            }
        }
        emit AssetCreationFeeCollected(action, kind, fee, msg.sender, block.timestamp);
    }

    /// @inheritdoc IAssetRegistry
    function feeConfig() external view override returns (address) {
        return address(_feeConfig);
    }

    /// @inheritdoc IAssetRegistry
    function updateMetadataHash(uint256 assetId, bytes32 newHash) external override {
        if (_assets[assetId].registeredAt == 0) revert NotRegistered();
        _onlyOwner(assetId);

        bytes32 oldHash = _assets[assetId].metadataHash;
        _assets[assetId].metadataHash = newHash;

        emit AssetMetadataUpdated(assetId, oldHash, newHash, block.timestamp);
    }

    /// @inheritdoc IAssetRegistry
    function setMetadataURI(uint256 assetId, string calldata uri) external override {
        if (_assets[assetId].registeredAt == 0) revert NotRegistered();
        _onlyOwner(assetId);

        metadataURIOf[assetId] = uri;

        emit AssetMetadataURISet(assetId, uri, block.timestamp);
    }

    /// @inheritdoc IAssetRegistry
    function transferAssetOwnership(uint256 assetId, address newOwner) external override {
        _onlyOwner(assetId);
        if (newOwner == address(0)) revert ZeroAddress();

        address old = _assets[assetId].owner;
        _assets[assetId].owner = newOwner;

        emit AssetOwnershipTransferred(assetId, old, newOwner, block.timestamp);
    }

    /// @inheritdoc IAssetRegistry
    function deactivateAsset(uint256 assetId) external override {
        _onlyOwner(assetId);
        if (!_assets[assetId].active) revert NotActive();

        _assets[assetId].active = false;

        emit AssetDeactivated(assetId, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @inheritdoc IAssetRegistry
    function isActive(uint256 assetId) external view override returns (bool) {
        return _assets[assetId].active;
    }

    /// @inheritdoc IAssetRegistry
    function tokenOf(uint256 assetId) external view override returns (address) {
        return _assets[assetId].token;
    }

    /// @inheritdoc IAssetRegistry
    function ownerOf(uint256 assetId) external view override returns (address) {
        return _assets[assetId].owner;
    }

    /// @inheritdoc IAssetRegistry
    function getAsset(uint256 assetId) external view override returns (AssetInfo memory) {
        return _assets[assetId];
    }

    /// @inheritdoc IAssetRegistry
    function getProductInfo(uint256 assetId) external view override returns (ProductInfo memory) {
        return _productInfo[assetId];
    }
}
