// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IMintBurnController} from "../interfaces/IMintBurnController.sol";
import {IRWAToken} from "../interfaces/IRWAToken.sol";
import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

/// @title MintBurnController
/// @notice Enforces the Issuer + Token Agent process for minting and burning RWA tokens, both
///         scoped per assetId: the Issuer for an assetId is simply that asset's AssetRegistry
///         owner (no separate global role); the Token Agent is appointed by that same owner via
///         `setTokenAgent`. Resolves the target RWAToken contract per-assetId from AssetRegistry,
///         supporting the one-contract-per-asset design.
///         (development-plan §3.2.1, v3.2 §5.4, §3.1 #15; 角色权限与职责修改方案 §11.3)
///
///         Flow: (1) Issuer calls initiate{Mint,Burn} → stores un-approved request;
///         (2) Token Agent calls approve{Mint,Burn} → marks approved+executed and calls
///         rwaToken.{mint,burn} on the asset-specific contract.
///
///         Mint/burn is not gated by StateManager; only Vault lifecycle state is.
contract MintBurnController is IMintBurnController {
    // -----------------------------------------------------------------------
    // Immutable state
    // -----------------------------------------------------------------------

    IAssetRegistry public immutable assetRegistry;

    // -----------------------------------------------------------------------
    // Mutable state
    // -----------------------------------------------------------------------

    uint256 public override nextMintNonce;
    uint256 public override nextBurnNonce;

    mapping(uint256 nonce => MintRequest) public override mintRequests;
    mapping(uint256 nonce => BurnRequest) public override burnRequests;

    /// @inheritdoc IMintBurnController
    mapping(uint256 assetId => address) public override tokenAgentOf;

    /// @notice Internal token registry; populated via registerToken (called by AssetRegistry).
    mapping(uint256 assetId => address) public rwaTokens;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address _assetRegistry) {
        if (_assetRegistry == address(0)) revert ZeroAddress();
        assetRegistry = IAssetRegistry(_assetRegistry);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _onlyIssuer(uint256 assetId) internal view {
        if (assetRegistry.ownerOf(assetId) != msg.sender) revert NotIssuer();
    }

    function _onlyTokenAgent(uint256 assetId) internal view {
        if (tokenAgentOf[assetId] != msg.sender) revert NotTokenAgent();
    }

    function _tokenForAsset(uint256 assetId) internal view returns (IRWAToken) {
        // Prefer internal registry (populated by registerToken); fall back to AssetRegistry lookup.
        address t = rwaTokens[assetId];
        if (t == address(0)) t = assetRegistry.tokenOf(assetId);
        if (t == address(0)) revert AssetNotRegistered();
        return IRWAToken(t);
    }

    // -----------------------------------------------------------------------
    // Token registration (called by AssetRegistry)
    // -----------------------------------------------------------------------

    /// @inheritdoc IMintBurnController
    function registerToken(uint256 assetId, address token) external override {
        if (msg.sender != address(assetRegistry)) revert NotAssetRegistry();
        rwaTokens[assetId] = token;
    }

    // -----------------------------------------------------------------------
    // Mint flow
    // -----------------------------------------------------------------------

    /// @inheritdoc IMintBurnController
    function initiateMint(uint256 assetId, uint256 amount, address to) external override returns (uint256 nonce) {
        _onlyIssuer(assetId);
        if (amount == 0) revert ZeroAmount();
        if (!assetRegistry.isActive(assetId)) revert AssetNotRegistered();

        nonce = nextMintNonce;
        mintRequests[nonce] = MintRequest({assetId: assetId, amount: amount, to: to, approved: false, executed: false});
        nextMintNonce = nonce + 1;

        emit MintInitiated(nonce, assetId, amount, to, block.timestamp);
    }

    /// @inheritdoc IMintBurnController
    function approveMint(uint256 nonce) external override {
        MintRequest storage req = mintRequests[nonce];
        if (req.amount == 0) revert RequestNotFound();
        _onlyTokenAgent(req.assetId);
        if (req.executed) revert AlreadyExecuted();

        req.approved = true;
        req.executed = true;

        _tokenForAsset(req.assetId).mint(req.to, req.amount);

        emit MintApproved(nonce, req.assetId, req.amount, req.to, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Burn flow
    // -----------------------------------------------------------------------

    /// @inheritdoc IMintBurnController
    function initiateBurn(uint256 assetId, uint256 amount, address from) external override returns (uint256 nonce) {
        _onlyIssuer(assetId);
        if (amount == 0) revert ZeroAmount();
        if (_tokenForAsset(assetId).balanceOf(from) < amount) revert InsufficientBalance();

        nonce = nextBurnNonce;
        burnRequests[nonce] =
            BurnRequest({assetId: assetId, amount: amount, from: from, approved: false, executed: false});
        nextBurnNonce = nonce + 1;

        emit BurnInitiated(nonce, assetId, amount, from, block.timestamp);
    }

    /// @inheritdoc IMintBurnController
    function approveBurn(uint256 nonce) external override {
        BurnRequest storage req = burnRequests[nonce];
        if (req.amount == 0) revert RequestNotFound();
        _onlyTokenAgent(req.assetId);
        if (req.executed) revert AlreadyExecuted();

        req.approved = true;
        req.executed = true;

        _tokenForAsset(req.assetId).burn(req.from, req.amount);

        emit BurnApproved(nonce, req.assetId, req.amount, req.from, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Token Agent appointment
    // -----------------------------------------------------------------------

    /// @inheritdoc IMintBurnController
    function setTokenAgent(uint256 assetId, address agent) external override {
        if (assetRegistry.ownerOf(assetId) != msg.sender) revert NotIssuer();
        if (agent == address(0)) revert ZeroAddress();
        tokenAgentOf[assetId] = agent;
        emit TokenAgentSet(assetId, agent, block.timestamp);
    }
}
