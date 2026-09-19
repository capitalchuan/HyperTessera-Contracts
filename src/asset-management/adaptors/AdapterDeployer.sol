// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FirstPeriodAdapter} from "./FirstPeriodAdapter.sol";
import {LiquidityAdapter} from "./LiquidityAdapter.sol";
import {RWAAdapter} from "./RWAAdapter.sol";

/// @title FirstPeriodAdapterDeployer
/// @notice Isolates FirstPeriodAdapter's creation bytecode in its own contract so
///         AdapterFactory's own runtime bytecode stays under the EIP-170 size limit.
contract FirstPeriodAdapterDeployer {
    function deploy(address asset_, address vault_, uint256 stalenessWindow_) external returns (address) {
        return address(new FirstPeriodAdapter(IERC20(asset_), vault_, stalenessWindow_));
    }
}

/// @title LiquidityAdapterDeployer
/// @notice Isolates LiquidityAdapter's creation bytecode in its own contract so
///         AdapterFactory's own runtime bytecode stays under the EIP-170 size limit.
contract LiquidityAdapterDeployer {
    function deploy(address asset_, address vault_, uint256 stalenessWindow_) external returns (address) {
        return address(new LiquidityAdapter(IERC20(asset_), vault_, stalenessWindow_));
    }
}

/// @title RWAAdapterDeployer
/// @notice Isolates RWAAdapter's creation bytecode in its own contract so AdapterFactory's own
///         runtime bytecode stays under the EIP-170 size limit.
contract RWAAdapterDeployer {
    function deploy(address asset_, address vault_, address rwaToken_, address navOracle_, uint256 stalenessWindow_)
        external
        returns (address)
    {
        return address(new RWAAdapter(IERC20(asset_), vault_, rwaToken_, navOracle_, stalenessWindow_));
    }
}
