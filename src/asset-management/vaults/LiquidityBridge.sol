// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidityBridge} from "../../interfaces/ILiquidityBridge.sol";
import {IVaultRoles} from "../../interfaces/IVaultRoles.sol";
import {IEarnVault} from "../../interfaces/IEarnVault.sol";
import {IStateManager} from "../../interfaces/IStateManager.sol";
import {IHyperAccessControl} from "../../interfaces/IHyperAccessControl.sol";

/// @title LiquidityBridge
/// @notice Stateless bridge — deposits USDT from `fromVault` into `toVault` using the
///         synchronous ERC-4626 deposit surface and returns resulting shares directly to
///         `fromVault`. Does NOT custody shares.
///         Access: `fromVault`'s own Allocator, or `fromVault` itself.
contract LiquidityBridge is ILiquidityBridge {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    address public usdt;

    /// @notice Registry consulted to confirm both sides of a bridge are real protocol vaults.
    IStateManager public immutable sm;

    /// @notice Protocol-global role registry; source of GOVERNOR_ROLE for the whitelist below.
    IHyperAccessControl public immutable ac;

    /// @notice Governor admission control for the bridge. `registeredVaults` only
    ///         says an address was built by the wired VaultFactory, and `deployVault` is
    ///         permissionless by design — so registration is not trust, and
    ///         anyone could stand up their own Vault, pass the `fromVault` self-call check, and
    ///         mint shares synchronously inside a real `toVault`, bypassing the async
    ///         `requestDeposit` flow entirely. Both ends must be named here by a Governor: the
    ///         source, because its authority is read off itself, and the destination, because
    ///         accepting a synchronous mint is a property of that Vault's own design.
    ///         Mirrors `UnifiedPool.vaultWhitelisted`.
    mapping(address vault => bool) public bridgeWhitelisted;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(address usdt_, address stateManager_, address accessControl_) {
        if (usdt_ == address(0) || stateManager_ == address(0) || accessControl_ == address(0)) {
            revert ZeroAddress();
        }
        usdt = usdt_;
        sm = IStateManager(stateManager_);
        ac = IHyperAccessControl(accessControl_);
    }

    // -----------------------------------------------------------------------
    // Governor admission control
    // -----------------------------------------------------------------------

    /// @inheritdoc ILiquidityBridge
    function setBridgeWhitelisted(address vault, bool allowed) external {
        if (!ac.hasRole(ac.GOVERNOR_ROLE(), msg.sender)) revert NotGovernor();
        if (vault == address(0)) revert ZeroAddress();
        bridgeWhitelisted[vault] = allowed;
        emit BridgeWhitelistUpdated(vault, allowed, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Bridge
    // -----------------------------------------------------------------------

    /// @inheritdoc ILiquidityBridge
    function bridgeDeposit(uint256 assets, address fromVault, address toVault) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        if (fromVault == address(0) || toVault == address(0)) revert ZeroAddress();

        // Access: fromVault itself (called from within LiquidityEarnVault.settle) or fromVault's own
        // Allocator. Short-circuited: the allocator() external call only runs when the cheaper
        // self-call check fails, so a non-vault fromVault doesn't break the self-call path.
        // Both sides must be protocol-registered AND named by a Governor. Authority here is read
        // off `fromVault` itself, so without this an attacker supplies a contract they control as
        // `fromVault`, passes the self-call check trivially, and reaches
        // `IEarnVault(toVault).deposit` — minting shares in a real vault synchronously, outside
        // the async request flow entirely.
        // Registration alone does not close that: `deployVault` is permissionless, so the
        // attacker's own Vault is registered too. The registry check is kept
        // alongside as the cheaper, factually narrower statement of the same invariant.
        if (!sm.registeredVaults(fromVault)) revert UnregisteredVault(fromVault);
        if (!sm.registeredVaults(toVault)) revert UnregisteredVault(toVault);
        if (!bridgeWhitelisted[fromVault]) revert VaultNotWhitelisted(fromVault);
        if (!bridgeWhitelisted[toVault]) revert VaultNotWhitelisted(toVault);

        if (msg.sender != fromVault && IVaultRoles(fromVault).allocator() != msg.sender) {
            revert CallerNotAuthorized(msg.sender);
        }

        // Pull USDT from fromVault
        IERC20(usdt).safeTransferFrom(fromVault, address(this), assets);

        // Approve toVault to spend USDT
        IERC20(usdt).forceApprove(toVault, assets);

        // Sync deposit into toVault; shares go directly to fromVault
        shares = IEarnVault(toVault).deposit(assets, fromVault);

        emit DepositBridged(fromVault, toVault, assets, shares, block.timestamp);
    }
}
