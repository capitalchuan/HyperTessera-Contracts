// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IClaimRegistry} from "../interfaces/IClaimRegistry.sol";
import {IStateManager} from "../interfaces/IStateManager.sol";
import {IVaultRoles} from "../interfaces/IVaultRoles.sol";

/// @title ClaimRegistry
/// @notice Append-only on-chain record of vault requests left unclaimed past their maturity
///         grace period. Phase 1 scope only (development-plan §4.2): recording is bookkeeping,
///         not payout — it does not read or move any BaseVault/UnifiedPool funds. Phase 2 adds
///         the PENDING→APPROVED→PAID state machine and the off-chain KYC/payout path.
contract ClaimRegistry is IClaimRegistry {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /// @notice StateManager used to validate `recordClaim`'s `vault` argument. Fixed at
    ///         construction — ClaimRegistry has no runtime configuration role at all
    ///         (角色权限与职责修改方案 G-08). Deployed after StateManager for this reason.
    IStateManager public immutable stateManager;

    ClaimRecord[] private _claims;
    mapping(address vault => uint256[] claimIds) private _claimsByVault;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address stateManager_) {
        if (stateManager_ == address(0)) revert ZeroAddress();
        stateManager = IStateManager(stateManager_);
    }

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @inheritdoc IClaimRegistry
    function recordClaim(address vault, address owner, uint256 requestId, uint256 assets, ClaimKind kind)
        external
        override
        returns (uint256 claimId)
    {
        if (vault == address(0) || owner == address(0)) revert ZeroAddress();
        if (msg.sender != vault && IVaultRoles(vault).curator() != msg.sender) revert UnauthorizedClaimRecorder();
        if (!stateManager.registeredVaults(vault)) revert UnregisteredVault(vault);

        claimId = _claims.length;
        _claims.push(
            ClaimRecord({
                vault: vault,
                owner: owner,
                requestId: requestId,
                assets: assets,
                kind: kind,
                recordedAt: block.timestamp
            })
        );
        _claimsByVault[vault].push(claimId);

        emit ClaimRecorded(claimId, vault, owner, requestId, assets, kind, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @inheritdoc IClaimRegistry
    function getClaim(uint256 claimId) external view override returns (ClaimRecord memory) {
        if (claimId >= _claims.length) revert ClaimDoesNotExist(claimId);
        return _claims[claimId];
    }

    /// @inheritdoc IClaimRegistry
    function getClaimsByVault(address vault) external view override returns (uint256[] memory) {
        return _claimsByVault[vault];
    }

    /// @inheritdoc IClaimRegistry
    function getClaimCount() external view override returns (uint256) {
        return _claims.length;
    }
}
