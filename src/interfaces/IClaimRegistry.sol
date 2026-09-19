// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IClaimRegistry
/// @notice Phase 1 scope: pure on-chain record of vault requests that went unclaimed past their
///         maturity grace period — `recordClaim`/`getClaim`/`getClaimsByVault` only. No
///         PENDING→APPROVED→PAID state machine, off-chain KYC gate, or payout path; those are
///         Phase 2 (development-plan §4.2). Recording does not move funds — it is a bookkeeping
///         entry for whichever off-chain/Keeper process sweeps unclaimed positions after grace
///         period expiry.
interface IClaimRegistry {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    /// @notice Which BaseVault claim function the owner failed to call before grace period expiry.
    enum ClaimKind {
        DEPOSIT_REFUND, // claimDeposit / claimRefund left unclaimed
        REDEEM_PAYOUT // claimRedeem left unclaimed
    }

    struct ClaimRecord {
        address vault;
        address owner;
        uint256 requestId;
        uint256 assets;
        ClaimKind kind;
        uint256 recordedAt;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event ClaimRecorded(
        uint256 indexed claimId,
        address indexed vault,
        address indexed owner,
        uint256 requestId,
        uint256 assets,
        ClaimKind kind,
        uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error UnauthorizedClaimRecorder();
    error ClaimDoesNotExist(uint256 claimId);
    error UnregisteredVault(address vault);

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @notice Record that `owner`'s request went unclaimed past its maturity grace period.
    ///         Append-only — records cannot be modified or deleted. Does not move funds.
    /// @dev    Access: `vault`'s own Curator, or `vault` itself. Reverts if `vault` isn't a
    ///         StateManager-registered vault.
    function recordClaim(address vault, address owner, uint256 requestId, uint256 assets, ClaimKind kind)
        external
        returns (uint256 claimId);

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @notice Returns the claim record at `claimId`.
    function getClaim(uint256 claimId) external view returns (ClaimRecord memory);

    /// @notice Returns every claimId recorded for `vault`, in recording order.
    function getClaimsByVault(address vault) external view returns (uint256[] memory claimIds);

    /// @notice Returns the total number of claims recorded across all vaults.
    function getClaimCount() external view returns (uint256);
}
