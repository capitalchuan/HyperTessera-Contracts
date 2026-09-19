// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IPoRRegistry} from "../interfaces/IPoRRegistry.sol";
import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

/// @title PoRRegistry
/// @notice Append-only on-chain ledger for Proof of Reserve documents.
///         Each proof is permanently stored; records cannot be modified or deleted.
///         Publishing is asset-local — that asset's AssetRegistry owner, or a Proof Publisher
///         address they designate; anyone may read.
contract PoRRegistry is IPoRRegistry {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    IAssetRegistry public immutable assetRegistry;

    /// @dev proofs[assetId] is the append-only list of proofs for that asset.
    mapping(uint256 assetId => ReserveProof[]) private _proofs;

    /// @inheritdoc IPoRRegistry
    mapping(uint256 assetId => address) public override proofPublisherOf;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address _assetRegistry) {
        if (_assetRegistry == address(0)) revert ZeroAddress();
        assetRegistry = IAssetRegistry(_assetRegistry);
    }

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @inheritdoc IPoRRegistry
    function publishReserveProof(uint256 assetId, bytes32 documentHash, string calldata uri) external override {
        if (!assetRegistry.isActive(assetId)) revert AssetNotActive(assetId);
        address owner_ = assetRegistry.ownerOf(assetId);
        if (msg.sender != owner_ && msg.sender != proofPublisherOf[assetId]) revert NotAuthorizedPublisher();

        _proofs[assetId].push(
            ReserveProof({documentHash: documentHash, uri: uri, publishedAt: block.timestamp, publisher: msg.sender})
        );

        emit ReserveProofPublished(assetId, documentHash, uri, msg.sender, block.timestamp);
    }

    /// @inheritdoc IPoRRegistry
    function setProofPublisher(uint256 assetId, address publisher) external override {
        if (assetRegistry.ownerOf(assetId) != msg.sender) revert NotAssetOwner();
        proofPublisherOf[assetId] = publisher;
        emit ProofPublisherSet(assetId, publisher, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @inheritdoc IPoRRegistry
    function getProof(uint256 assetId, uint256 index) external view override returns (ReserveProof memory) {
        uint256 len = _proofs[assetId].length;
        if (len == 0) revert NoProofExists(assetId);
        if (index >= len) revert IndexOutOfRange(assetId, index, len);
        return _proofs[assetId][index];
    }

    /// @inheritdoc IPoRRegistry
    function getLatestProof(uint256 assetId) external view override returns (ReserveProof memory) {
        uint256 len = _proofs[assetId].length;
        if (len == 0) revert NoProofExists(assetId);
        return _proofs[assetId][len - 1];
    }

    /// @inheritdoc IPoRRegistry
    function getProofCount(uint256 assetId) external view override returns (uint256) {
        return _proofs[assetId].length;
    }
}
