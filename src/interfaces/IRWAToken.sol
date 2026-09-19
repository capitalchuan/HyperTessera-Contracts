// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IRWAToken
/// @notice Interface for a per-asset ERC-20 RWA token with ERC-1400 lightweight subset:
///         ERC-1594 (controller mint/burn) + transfer path restriction.
///         ERC-1644 forced transfer is deliberately not supported (removed 2026-08-17: the
///         entry point was unreachable and the client flow spec requires no forced transfer).
///         One contract is deployed per assetId by AssetRegistry.registerAsset. (development-plan §3.2.1)
interface IRWAToken {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    /// @notice A permitted transfer rule: addresses in `fromListId` may send to addresses in `toListId`.
    struct TransferPath {
        uint8 fromListId;
        uint8 toListId;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Emitted when transfer paths are reconfigured (batch).
    event TransferPathsUpdated(uint256 timestamp);

    /// @notice Emitted when addresses are added to a list.
    event AddressListUpdated(uint8 indexed listId, bool added, uint256 count, uint256 timestamp);

    /// @notice Emitted when the whitelist admission switch is toggled.
    event WhitelistEnabledSet(bool enabled, uint256 timestamp);

    /// @notice Emitted when the transfer path direction switch is toggled.
    event TransferPathEnabledSet(bool enabled, uint256 timestamp);

    /// @notice Emitted when addresses are added to or removed from the whitelist.
    event WhitelistUpdated(bool added, uint256 count, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error NotIssuer();
    error NotController();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    /// @notice Transfer violates all configured transfer paths.
    error TransferRestricted(address from, address to);
    /// @notice Index is out of range for the TransferPath[10] array.
    error InvalidPathIndex(uint8 index);
    /// @notice Arrays passed to setTransferPaths have unequal lengths.
    error ArrayLengthMismatch();
    /// @notice `from` or `to` is not on the whitelist while whitelistEnabled is true.
    error NotWhitelisted(address account);
    /// @notice transferPathEnabled is true but no transfer paths are configured.
    error NoTransferPathConfigured();

    // -----------------------------------------------------------------------
    // ERC-20 standard
    // -----------------------------------------------------------------------

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);

    // -----------------------------------------------------------------------
    // ERC-1594 controller mint/burn
    // -----------------------------------------------------------------------

    /// @notice Mints `amount` tokens to `to`. Controller only.
    function mint(address to, uint256 amount) external;

    /// @notice Burns `amount` tokens from `from`. Controller only.
    function burn(address from, uint256 amount) external;

    // -----------------------------------------------------------------------
    // Transfer path management (this asset's Issuer — AssetRegistry owner)
    // -----------------------------------------------------------------------

    /// @notice Batch-set transfer path rules. Each entry at `indexes[i]` is set to
    ///         (fromListIds[i], toListIds[i]). Arrays must have equal length.
    function setTransferPaths(uint8[] calldata indexes, uint8[] calldata fromListIds, uint8[] calldata toListIds)
        external;

    /// @notice Batch-add `accounts` to address list `listId`.
    function addToAddressList(uint8 listId, address[] calldata accounts) external;

    /// @notice Batch-remove `accounts` from address list `listId`.
    function removeFromAddressList(uint8 listId, address[] calldata accounts) external;

    /// @notice Toggle whitelist admission checks. Default false (open).
    function setWhitelistEnabled(bool enabled) external;

    /// @notice Toggle transfer path direction checks. Default false (open).
    function setTransferPathEnabled(bool enabled) external;

    /// @notice Batch-add `accounts` to the whitelist.
    function addToWhitelist(address[] calldata accounts) external;

    /// @notice Batch-remove `accounts` from the whitelist.
    function removeFromWhitelist(address[] calldata accounts) external;

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function mintBurnController() external view returns (address);
    function transferPathCount() external view returns (uint8);
    function transferPaths(uint8 index) external view returns (TransferPath memory);
    function isInList(uint8 listId, address account) external view returns (bool);
    function whitelistEnabled() external view returns (bool);
    function transferPathEnabled() external view returns (bool);
    function isWhitelisted(address account) external view returns (bool);
}
