// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {FeePaymentKind, CreationFeeAction} from "../libs/Types.sol";

/// @title IAssetRegistry
/// @notice Interface for the HyperTessera RWA asset metadata registry.
///         Registration is permissionless — any address may register an asset and becomes its owner.
///         Each asset receives a sequential `uint256` identifier (starting at 1) and a dedicated
///         RWAToken ERC-20 deployed on registration. (development-plan §3.2.1, revised 2026-06-22/25)
interface IAssetRegistry {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    /// @param metadataHash keccak256 of the off-chain deal/legal document.
    /// @param token        Address of the deployed RWAToken ERC-20 contract.
    /// @param active       false after deactivateAsset; record is never deleted.
    /// @param registeredAt block.timestamp at registration; 0 if never registered.
    /// @param owner        Registrant; may update metadata, transfer ownership, and deactivate.
    struct AssetInfo {
        bytes32 metadataHash;
        address token;
        bool active;
        uint256 registeredAt;
        address owner;
    }

    /// @notice On-chain product terms recorded at registration. Kept as its own struct rather
    ///         than appended to AssetInfo so getAsset()'s ABI return shape is unchanged and
    ///         existing front ends keep decoding positionally.
    struct ProductInfo {
        string productName;
        uint16 annualYieldRateBps; // 500 == 5.00% APY
        uint64 maturityTimestamp; // Unix seconds
        address issuer; // always the registrant; ignored on input
        string underlyingAsset;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event AssetRegistered(
        uint256 indexed assetId, address indexed owner, address indexed token, bytes32 metadataHash, uint256 timestamp
    );
    event ProductInfoSet(
        uint256 indexed assetId,
        address indexed issuer,
        string productName,
        uint16 annualYieldRateBps,
        uint64 maturityTimestamp,
        string underlyingAsset,
        uint256 timestamp
    );
    event AssetMetadataUpdated(uint256 indexed assetId, bytes32 oldHash, bytes32 newHash, uint256 timestamp);
    event AssetMetadataURISet(uint256 indexed assetId, string uri, uint256 timestamp);
    event AssetOwnershipTransferred(
        uint256 indexed assetId, address indexed oldOwner, address indexed newOwner, uint256 timestamp
    );
    event AssetDeactivated(uint256 indexed assetId, uint256 timestamp);
    event AssetCreationFeeCollected(
        CreationFeeAction indexed action,
        FeePaymentKind indexed kind,
        uint256 amount,
        address indexed payer,
        uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error NotRegistered();
    error NotActive();
    error NotAssetOwner(uint256 assetId, address caller);
    error IncorrectNativeFee(uint256 expected, uint256 provided);
    error UnexpectedNativeValue();
    error FeeTransferFailed();
    error PaymentTokenNotConfigured(FeePaymentKind kind);

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @notice Register a new RWA asset and deploy its dedicated RWAToken ERC-20.
    /// @dev    Permissionless — msg.sender becomes the asset owner (and that asset's Issuer for
    ///         MintBurnController purposes). Calls MintBurnController.registerToken(assetId, token)
    ///         and wires the controller directly into the deployed RWAToken.
    ///         (plan §3.2.1, revised 2026-06-22/25; 角色权限与职责修改方案 §11.2)
    /// @param metadataHash keccak256 of the off-chain deal/legal document.
    /// @param name         ERC-20 name for the deployed RWAToken.
    /// @param symbol       ERC-20 symbol for the deployed RWAToken.
    /// @param decimals     ERC-20 decimals for the deployed RWAToken.
    /// @param feeKind      Payment kind used to pay the creation fee (see ProtocolFeeConfig).
    /// @param product      Core product terms recorded on-chain at registration; issuer is
    ///                     ignored on input and forced to msg.sender.
    /// @return assetId     The newly allocated sequential identifier (>= 1).
    /// @return token       Address of the deployed RWAToken contract.
    function registerAsset(
        bytes32 metadataHash,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        FeePaymentKind feeKind,
        ProductInfo calldata product
    ) external payable returns (uint256 assetId, address token);

    /// @notice Replace the metadata hash for a registered asset.
    /// @dev    Access: asset owner only. Reverts NotAssetOwner if caller is not the registrant.
    function updateMetadataHash(uint256 assetId, bytes32 newHash) external;

    /// @notice Set (or clear) the off-chain metadata document pointer for a registered asset.
    /// @dev    Access: asset owner only — identical gating to updateMetadataHash. Reverts
    ///         NotRegistered for an unknown assetId, then NotAssetOwner if caller is not the owner.
    ///         Deliberately a standalone setter rather than an extra registerAsset parameter so the
    ///         registerAsset selector never changes, and stored outside AssetInfo so getAsset()'s
    ///         return shape stays byte-for-byte stable for positional decoders.
    ///         Mirrors the hash + pointer pattern already used by PoRRegistry.ReserveProof.
    /// @param uri Document access URL (HTTP or IPFS). Empty string clears the pointer.
    function setMetadataURI(uint256 assetId, string calldata uri) external;

    /// @notice Transfer asset ownership to a new address.
    /// @dev    Access: asset owner only.
    function transferAssetOwnership(uint256 assetId, address newOwner) external;

    /// @notice Deactivate a registered asset without deleting its record.
    /// @dev    Access: asset owner only.
    function deactivateAsset(uint256 assetId) external;

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @notice Returns true if the asset is registered AND active.
    function isActive(uint256 assetId) external view returns (bool);

    /// @notice Returns the RWAToken contract address for a registered asset (address(0) if not registered).
    function tokenOf(uint256 assetId) external view returns (address);

    /// @notice Returns the owner (registrant) of a registered asset (address(0) if not registered).
    function ownerOf(uint256 assetId) external view returns (address);

    /// @notice Returns the off-chain metadata document pointer for an asset
    ///         (empty string if never registered or never set).
    function metadataURIOf(uint256 assetId) external view returns (string memory);

    /// @notice Returns the full record for an asset (zero-valued if never registered).
    function getAsset(uint256 assetId) external view returns (AssetInfo memory);

    /// @notice Returns the on-chain product terms for an asset (zero-valued if never registered).
    function getProductInfo(uint256 assetId) external view returns (ProductInfo memory);

    /// @notice Next asset id to be allocated; starts at 1 (0 reserved).
    function nextAssetId() external view returns (uint256);

    /// @notice Address of the MintBurnController this Registry deployed at construction —
    ///         immutable, always non-zero, no setter. (角色权限与职责修改方案 §11.2, G-06)
    function mintBurnController() external view returns (address);

    /// @notice Address of the wired ProtocolFeeConfig used to gate registerAsset's creation fee.
    function feeConfig() external view returns (address);
}
