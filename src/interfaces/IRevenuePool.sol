// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

/// @title IRevenuePool
/// @notice Protocol fee sink. Authorized sources deposit fees; GOVERNOR sweeps to a recipient.
///         (development-plan §3.2.1)
interface IRevenuePool {
    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event FeeReceived(address indexed source, uint256 amount, uint256 timestamp);
    event FeeWithdrawn(address indexed recipient, uint256 amount, uint256 timestamp);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount, uint256 timestamp);
    event SourceAuthorized(address indexed source, uint256 timestamp);
    event SourceRevoked(address indexed source, uint256 timestamp);
    event YieldStrategySet(address indexed strategy, uint256 timestamp);
    event NativeWithdrawn(address indexed to, uint256 amount, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error NotGovernor();
    error UnauthorizedFeeSource(address caller);
    error InsufficientBalance(uint256 balance, uint256 requested);
    error NativeTransferFailed();

    // -----------------------------------------------------------------------
    // Mutating functions
    // -----------------------------------------------------------------------

    /// @notice Record an incoming fee from an authorized source.
    ///         Caller must have pre-transferred `amount` USDT to this contract.
    /// @dev    Access: authorizedSources[msg.sender] == true.
    function receiveFee(uint256 amount) external;

    /// @notice Transfer `amount` USDT to `recipient`. Access: GOVERNOR_ROLE.
    function withdraw(address recipient, uint256 amount) external;

    /// @notice Transfer `amount` of `token` to `to`. For sweeping Vault Shares (minted here as
    ///         protocol performance fee) or any other ERC-20 the pool holds — distinct from
    ///         `withdraw`, which is USDT-specific. Access: GOVERNOR_ROLE.
    function withdrawToken(address token, address to, uint256 amount) external;

    /// @notice Transfer `amount` of native currency to `to`. Access: GOVERNOR_ROLE.
    function withdrawNative(address to, uint256 amount) external;

    /// @notice Add an address to the authorized fee-source set. Access: GOVERNOR_ROLE.
    function addAuthorizedSource(address source) external;

    /// @notice Remove an address from the authorized fee-source set. Access: GOVERNOR_ROLE.
    function removeAuthorizedSource(address source) external;

    /// @notice Phase 1 interface reservation only (development-plan §7): records the address of
    ///         a future yield-deployment strategy for idle funds. No-op — this contract does not
    ///         call into `strategy` or move funds to it. Phase 2 implements the actual
    ///         deploy/recall/currentValue adapter pattern. Access: GOVERNOR_ROLE.
    function setYieldStrategy(address strategy) external;

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    function authorizedSources(address source) external view returns (bool);

    // -----------------------------------------------------------------------
    // Authorized source index
    // -----------------------------------------------------------------------
    // `authorizedSources` answers "may this address deposit fees?"; the two below answer "who
    // may deposit fees?", which is otherwise only recoverable by replaying SourceAuthorized and
    // SourceRevoked logs and reconstructing the set by hand.

    /// @notice Number of sources currently authorized.
    function authorizedSourceCount() external view returns (uint256);

    /// @notice Up to `limit` currently-authorized sources starting at `offset`.
    /// @dev    Clamped, not checked: an offset at or past the end yields an empty array and an
    ///         overlong limit yields a short page, so a caller can page without reading
    ///         `authorizedSourceCount` first.
    ///         This is the exact live set, not an "ever authorized" history — a revoked source
    ///         leaves the list. Ordering is therefore NOT stable: `removeAuthorizedSource` swaps
    ///         the last entry into the freed slot and pops. Pin a single `blockTag` across the
    ///         count and the pages that follow it.
    function authorizedSourcesPaged(uint256 offset, uint256 limit) external view returns (address[] memory);
    function totalFeesReceived() external view returns (uint256);
    function yieldStrategy() external view returns (address);
}
