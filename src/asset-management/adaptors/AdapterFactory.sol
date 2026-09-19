// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IAdapterFactory} from "../../interfaces/IAdapterFactory.sol";
import {FirstPeriodAdapterDeployer, LiquidityAdapterDeployer, RWAAdapterDeployer} from "./AdapterDeployer.sol";

contract AdapterFactory is IAdapterFactory {
    mapping(address adapter => bool) public override isAdapter;

    /// @dev Enumerable counterpart to `isAdapter`. The mapping answers "did this factory deploy
    ///      that address?"; this answers "what has this factory deployed?" — so a third party can
    ///      list every adapter with eth_call alone instead of crawling AdapterDeployed logs over a
    ///      bounded block window. Append-only: deployment is the only writer and adapters are never
    ///      removed, so an index, once assigned, is stable forever.
    address[] private _adapterList;

    /// @dev The same list sliced by the vault each adapter was deployed for, so "which adapters
    ///      exist for this vault?" needs no log filtering. Append-only on the same terms.
    mapping(address vault => address[]) private _adaptersByVault;

    FirstPeriodAdapterDeployer public immutable fpaDeployer;
    LiquidityAdapterDeployer public immutable lqaDeployer;
    RWAAdapterDeployer public immutable rwaDeployer;

    constructor() {
        fpaDeployer = new FirstPeriodAdapterDeployer();
        lqaDeployer = new LiquidityAdapterDeployer();
        rwaDeployer = new RWAAdapterDeployer();
    }

    function _validateParams(AdapterParams calldata params) internal pure {
        if (params.asset == address(0) || params.vault == address(0)) {
            revert InvalidAdapterParams();
        }
    }

    function _validateRWAParams(RWAAdapterParams calldata params) internal pure {
        if (
            params.asset == address(0) || params.vault == address(0) || params.rwaToken == address(0)
                || params.navOracle == address(0)
        ) {
            revert InvalidAdapterParams();
        }
    }

    function deployAdapter(AdapterParams calldata params) external override returns (address adapter) {
        _validateParams(params);
        adapter = fpaDeployer.deploy(params.asset, params.vault, params.stalenessWindow);
        isAdapter[adapter] = true;
        _index(adapter, params.vault);
        emit AdapterDeployed(adapter, params.vault, block.timestamp);
    }

    function deployLiquidityAdapter(AdapterParams calldata params) external override returns (address adapter) {
        _validateParams(params);
        adapter = lqaDeployer.deploy(params.asset, params.vault, params.stalenessWindow);
        isAdapter[adapter] = true;
        _index(adapter, params.vault);
        emit AdapterDeployed(adapter, params.vault, block.timestamp);
    }

    function deployRWAAdapter(RWAAdapterParams calldata params) external override returns (address adapter) {
        _validateRWAParams(params);
        adapter = rwaDeployer.deploy(
            params.asset, params.vault, params.rwaToken, params.navOracle, params.dealDataStalenessWindow
        );
        isAdapter[adapter] = true;
        _index(adapter, params.vault);
        emit AdapterDeployed(adapter, params.vault, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Adapter index
    // -----------------------------------------------------------------------

    /// @dev Appended in the same transaction that writes `isAdapter`, so an adapter is indexed
    ///      atomically with its deployment — there is no second call that could fail to fire and
    ///      leave the index disagreeing with the mapping.
    function _index(address adapter, address vault) internal {
        _adapterList.push(adapter);
        _adaptersByVault[vault].push(adapter);
    }

    /// @inheritdoc IAdapterFactory
    function adapterCount() external view returns (uint256) {
        return _adapterList.length;
    }

    /// @inheritdoc IAdapterFactory
    function adapterAt(uint256 index) external view returns (address) {
        return _adapterList[index];
    }

    /// @inheritdoc IAdapterFactory
    function adaptersPaged(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _paged(_adapterList, offset, limit);
    }

    /// @inheritdoc IAdapterFactory
    function adapterCountForVault(address vault) external view returns (uint256) {
        return _adaptersByVault[vault].length;
    }

    /// @inheritdoc IAdapterFactory
    function adaptersForVaultPaged(address vault, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        return _paged(_adaptersByVault[vault], offset, limit);
    }

    /// @dev Clamps `limit` against the remaining length instead of computing `offset + limit`,
    ///      so a caller paging blind with a huge limit gets a short page rather than an
    ///      arithmetic-overflow revert.
    function _paged(address[] storage list, uint256 offset, uint256 limit)
        internal
        view
        returns (address[] memory page)
    {
        uint256 len = list.length;
        if (offset >= len) return new address[](0);

        uint256 count = len - offset;
        if (limit < count) count = limit;

        page = new address[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = list[offset + i];
        }
    }
}
