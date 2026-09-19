// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseAdapter} from "./BaseAdapter.sol";
import {ILiquidityAdapter} from "../../interfaces/ILiquidityAdapter.sol";
import {IVaultRoles} from "../../interfaces/IVaultRoles.sol";
import {IStateManager} from "../../interfaces/IStateManager.sol";

/// @title LiquidityAdapter
/// @notice Concrete BaseAdapter for the LP EarnVault. Holds the Curator-configured LP→Cash bridge
///         target (`liquidityBridge`/`cashVault`) on top of the inherited Curator/Allocator order
///         book; the LP Vault performs the actual bridging itself. (development-plan §3.4.1)
///
///         Deliberately declares no exit assets: the LP→Cash bridge is unchanged and is not a Sell
///         Order, and this Adapter holds no sellable position of its own. It therefore inherits
///         BaseAdapter's refuse-everything policy, so a token-bearing Sell Order cannot be created
///         against it at all (Adapter 方案 §五). Should it ever hold one, override
///         `_validateExitAsset`/`_deliverExitAsset` for exactly that asset — Deal-only exits
///         (`exitAsset == address(0)`) already work today.
contract LiquidityAdapter is BaseAdapter, ILiquidityAdapter {
    address public override liquidityBridge;
    address public override cashVault;

    constructor(IERC20 asset_, address vault_, uint256 stalenessWindow_)
        BaseAdapter(asset_, vault_, stalenessWindow_, "Liquidity Adapter Share", "lqaShare")
    {}

    // -----------------------------------------------------------------------
    // Bridge target configuration
    // -----------------------------------------------------------------------

    /// @inheritdoc ILiquidityAdapter
    function setBridgeTarget(address newLiquidityBridge, address newCashVault) external override {
        _onlyCuratorDirectOrTimelock();
        if (newLiquidityBridge == address(0) || newCashVault == address(0)) revert ZeroAddress();
        if (!IStateManager(IVaultRoles(vault).stateManager()).isVaultRegistered(newCashVault)) {
            revert InvalidCashVault(newCashVault);
        }
        liquidityBridge = newLiquidityBridge;
        cashVault = newCashVault;
        emit BridgeTargetSet(newLiquidityBridge, newCashVault, block.timestamp);
    }
}
