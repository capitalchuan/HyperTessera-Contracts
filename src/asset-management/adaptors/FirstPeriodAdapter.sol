// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";

/// @title FirstPeriodAdapter
/// @notice Concrete BaseAdapter for the Cash and Note EarnVaults — realAssets() uses BaseAdapter's
///         default (idle balance plus the sum of live pendingDeposits). (development-plan §3.4.1)
contract FirstPeriodAdapter is BaseAdapter {
    using SafeERC20 for IERC20;

    /// @notice Tokens this Adapter may deliver out through a Sell Order.
    /// @dev    Unlike RWAAdapter, which is bound to exactly one token at construction, this
    ///         Adapter's investments are whatever the Curator has bought into, so the sellable set
    ///         has to be configurable. It is still an explicit allowlist rather than "any token":
    ///         BaseAdapter must never let a Sell Order become a way to move an arbitrary token out
    ///         of an Adapter (Adapter 方案 §五).
    ///
    ///         A VALUE_RETURN investment has no on-chain token at all. Those exit with
    ///         `exitAsset == address(0)`, which touches nothing here — only the linked Deal value
    ///         moves — so the Data Provider no longer has to separately mark an exited Deal down
    ///         to zero.
    mapping(address token => bool) public exitableAssets;

    event ExitableAssetSet(address indexed token, bool allowed, uint256 timestamp);

    constructor(IERC20 asset_, address vault_, uint256 stalenessWindow_)
        BaseAdapter(asset_, vault_, stalenessWindow_, "FirstPeriod Adapter Share", "fpaShare")
    {}

    /// @notice Allow or disallow `token` as a Sell Order exit asset.
    /// @dev    Access: this Vault's Curator directly while CONFIGURING, its VaultTimelock after —
    ///         the same Curator-class gate as `setStalenessWindow` / `setDataProvider`, since
    ///         widening what the Adapter may part with is a risk-parameter change.
    function setExitableAsset(address token, bool allowed) external {
        _onlyCuratorDirectOrTimelock();
        if (token == address(0)) revert ZeroAddress();
        // `asset()` is the proceeds currency and the Vault's own capital; letting it out through
        // an exit would just be an unauthorised transfer wearing a Sell Order's clothes.
        if (token == asset()) revert ExitAssetNotSupported(token);
        exitableAssets[token] = allowed;
        emit ExitableAssetSet(token, allowed, block.timestamp);
    }

    function _validateExitAsset(address token, uint256 amount) internal view override {
        amount;
        if (!exitableAssets[token]) revert ExitAssetNotSupported(token);
    }

    function _deliverExitAsset(address token, uint256 amount, address to) internal override {
        if (!exitableAssets[token]) revert ExitAssetNotSupported(token);
        IERC20(token).safeTransfer(to, amount);
    }
}
