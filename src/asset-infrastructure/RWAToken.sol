// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IRWAToken} from "../interfaces/IRWAToken.sol";
import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";

/// @title RWAToken
/// @notice Per-asset ERC-20 implementing a lightweight ERC-1400 subset:
///         ERC-1594 (controller mint/burn) + transfer path restriction.
///
///         No ERC-1644 forced transfer. A `controllerTransfer` entry point existed but was
///         unreachable on-chain — it was gated on the MintBurnController, and that contract
///         exposes no function that would ever call it. The product has no forced
///         transfer requirement, so it was removed rather than completed.
///
///         Transfer path restriction: up to 10 rules; each rule permits transfers from any address
///         in `fromListId` to any address in `toListId`. Whitelist admission (who may hold) and
///         transfer path direction (who may send to whom) are two independent switches, both
///         defaulting to false/open. This asset's Issuer (its AssetRegistry owner) manages paths and lists;
///         the MintBurnController is fixed at deploy time by AssetRegistry — no setter, no
///         Governor involvement.
///
///         One contract is deployed per assetId by AssetRegistry.registerAsset.
contract RWAToken is IRWAToken {
    // -----------------------------------------------------------------------
    // Immutable state
    // -----------------------------------------------------------------------

    IAssetRegistry public immutable assetRegistry;
    uint256 public immutable assetId;

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    // -----------------------------------------------------------------------
    // ERC-20 state
    // -----------------------------------------------------------------------

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // -----------------------------------------------------------------------
    // Controller (ERC-1594)
    // -----------------------------------------------------------------------

    address public immutable override mintBurnController;

    // -----------------------------------------------------------------------
    // Transfer path state
    // -----------------------------------------------------------------------

    /// @dev Fixed-size array avoids dynamic-array storage overhead; up to 10 active paths.
    TransferPath[10] private _transferPaths;
    uint8 public override transferPathCount;

    /// @dev addressLists[listId][account] — max 255 distinct lists (uint8).
    mapping(uint8 listId => mapping(address account => bool)) private _addressLists;

    /// @dev Whitelist (who may hold) and transfer paths (who may send to whom) are two orthogonal
    ///      controls. The whitelist deliberately does NOT reuse a `listId` — sharing storage would
    ///      re-couple the two switches that this design exists to separate. Both default to false,
    ///      preserving the pre-existing open-transfer behaviour.
    bool public override whitelistEnabled;
    bool public override transferPathEnabled;
    mapping(address account => bool) private _whitelisted;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @param assetRegistry_      This asset's AssetRegistry (also this asset's Issuer authority).
    /// @param assetId_            This token's assetId within `assetRegistry_`.
    /// @param _mintBurnController Fixed permanently at deploy time; always non-zero.
    constructor(
        address assetRegistry_,
        uint256 assetId_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address _mintBurnController
    ) {
        if (assetRegistry_ == address(0) || _mintBurnController == address(0)) revert ZeroAddress();
        assetRegistry = IAssetRegistry(assetRegistry_);
        assetId = assetId_;
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        mintBurnController = _mintBurnController;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _onlyIssuer() internal view {
        if (assetRegistry.ownerOf(assetId) != msg.sender) revert NotIssuer();
    }

    function _checkTransfer(address from, address to) internal view {
        if (whitelistEnabled) {
            if (!_whitelisted[from]) revert NotWhitelisted(from);
            if (!_whitelisted[to]) revert NotWhitelisted(to);
        }
        if (!transferPathEnabled) return;

        // Strict mode with no rules must block, not fall open — falling open is precisely the
        // bug this switch was introduced to fix.
        uint8 count = transferPathCount;
        if (count == 0) revert NoTransferPathConfigured();
        for (uint8 i = 0; i < count; ++i) {
            TransferPath storage p = _transferPaths[i];
            if (_addressLists[p.fromListId][from] && _addressLists[p.toListId][to]) return;
        }
        revert TransferRestricted(from, to);
    }

    // -----------------------------------------------------------------------
    // ERC-20 metadata
    // -----------------------------------------------------------------------

    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    // -----------------------------------------------------------------------
    // ERC-20 standard
    // -----------------------------------------------------------------------

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _checkTransfer(msg.sender, to);
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _checkTransfer(from, to);
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                _allowances[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    // -----------------------------------------------------------------------
    // ERC-1594 controller
    // -----------------------------------------------------------------------

    /// @inheritdoc IRWAToken
    function mint(address to, uint256 amount) external override {
        if (msg.sender != mintBurnController) revert NotController();
        _totalSupply += amount;
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    /// @inheritdoc IRWAToken
    function burn(address from, uint256 amount) external override {
        if (msg.sender != mintBurnController) revert NotController();
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // -----------------------------------------------------------------------
    // Transfer path management — COMPLIANCE_ROLE
    // -----------------------------------------------------------------------

    /// @inheritdoc IRWAToken
    function setTransferPaths(uint8[] calldata indexes, uint8[] calldata fromListIds, uint8[] calldata toListIds)
        external
        override
    {
        _onlyIssuer();
        if (indexes.length != fromListIds.length || indexes.length != toListIds.length) {
            revert ArrayLengthMismatch();
        }
        uint8 maxIndex = 0;
        for (uint256 i = 0; i < indexes.length; ++i) {
            uint8 idx = indexes[i];
            if (idx >= 10) revert InvalidPathIndex(idx);
            _transferPaths[idx] = TransferPath({fromListId: fromListIds[i], toListId: toListIds[i]});
            if (idx + 1 > maxIndex) maxIndex = idx + 1;
        }
        // Update transferPathCount to cover all configured indexes.
        if (maxIndex > transferPathCount) transferPathCount = maxIndex;
        emit TransferPathsUpdated(block.timestamp);
    }

    /// @inheritdoc IRWAToken
    function addToAddressList(uint8 listId, address[] calldata accounts) external override {
        _onlyIssuer();
        for (uint256 i = 0; i < accounts.length; ++i) {
            _addressLists[listId][accounts[i]] = true;
        }
        emit AddressListUpdated(listId, true, accounts.length, block.timestamp);
    }

    /// @inheritdoc IRWAToken
    function removeFromAddressList(uint8 listId, address[] calldata accounts) external override {
        _onlyIssuer();
        for (uint256 i = 0; i < accounts.length; ++i) {
            _addressLists[listId][accounts[i]] = false;
        }
        emit AddressListUpdated(listId, false, accounts.length, block.timestamp);
    }

    /// @inheritdoc IRWAToken
    function setWhitelistEnabled(bool enabled) external override {
        _onlyIssuer();
        whitelistEnabled = enabled;
        emit WhitelistEnabledSet(enabled, block.timestamp);
    }

    /// @inheritdoc IRWAToken
    function setTransferPathEnabled(bool enabled) external override {
        _onlyIssuer();
        transferPathEnabled = enabled;
        emit TransferPathEnabledSet(enabled, block.timestamp);
    }

    /// @inheritdoc IRWAToken
    function addToWhitelist(address[] calldata accounts) external override {
        _onlyIssuer();
        for (uint256 i = 0; i < accounts.length; ++i) {
            _whitelisted[accounts[i]] = true;
        }
        emit WhitelistUpdated(true, accounts.length, block.timestamp);
    }

    /// @inheritdoc IRWAToken
    function removeFromWhitelist(address[] calldata accounts) external override {
        _onlyIssuer();
        for (uint256 i = 0; i < accounts.length; ++i) {
            _whitelisted[accounts[i]] = false;
        }
        emit WhitelistUpdated(false, accounts.length, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @inheritdoc IRWAToken
    function transferPaths(uint8 index) external view override returns (TransferPath memory) {
        return _transferPaths[index];
    }

    /// @inheritdoc IRWAToken
    function isInList(uint8 listId, address account) external view override returns (bool) {
        return _addressLists[listId][account];
    }

    /// @inheritdoc IRWAToken
    function isWhitelisted(address account) external view override returns (bool) {
        return _whitelisted[account];
    }
}
