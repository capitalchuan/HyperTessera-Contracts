// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IPoRRegistry
/// @notice Append-only on-chain ledger for Proof of Reserve documents.
///         Records are keyed by assetId and indexed within each asset. Publishing rights are
///         asset-local: that asset's AssetRegistry owner, or a Proof Publisher address they
///         designate — no protocol-global DATA_PROVIDER_ROLE.
///         (development-plan §3.2.1; 角色权限与职责修改方案 §11.5)
interface IPoRRegistry {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    struct ReserveProof {
        bytes32 documentHash; // keccak256 of document content (integrity anchor)
        string uri; // HTTP URL or IPFS URI
        uint256 publishedAt; // block.timestamp
        address publisher; // who called publishReserveProof
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event ReserveProofPublished(
        uint256 indexed assetId, bytes32 documentHash, string uri, address indexed publisher, uint256 timestamp
    );
    event ProofPublisherSet(uint256 indexed assetId, address indexed publisher, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error NotAuthorizedPublisher();
    error NotAssetOwner();
    error ZeroAddress();
    error AssetNotActive(uint256 assetId);
    error NoProofExists(uint256 assetId);
    error IndexOutOfRange(uint256 assetId, uint256 index, uint256 length);

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @notice Publish a new reserve proof. Append-only — records cannot be modified or deleted.
    /// @dev    Access: that assetId's AssetRegistry owner, or their designated proofPublisherOf.
    /// @param assetId      Asset the proof corresponds to; must exist and be active.
    /// @param documentHash keccak256 of the document content.
    /// @param uri          Document access URL (HTTP or IPFS).
    function publishReserveProof(uint256 assetId, bytes32 documentHash, string calldata uri) external;

    /// @notice Delegates publishing rights for a single assetId to `publisher` (or clears
    ///         delegation with address(0), reverting to owner-only).
    /// @dev    Access: that assetId's AssetRegistry owner.
    function setProofPublisher(uint256 assetId, address publisher) external;

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    function proofPublisherOf(uint256 assetId) external view returns (address);

    /// @notice Returns the proof at `index` for `assetId`.
    function getProof(uint256 assetId, uint256 index) external view returns (ReserveProof memory);

    /// @notice Returns the most recently published proof for `assetId`.
    function getLatestProof(uint256 assetId) external view returns (ReserveProof memory);

    /// @notice Returns the total number of proofs published for `assetId`.
    function getProofCount(uint256 assetId) external view returns (uint256);
}
