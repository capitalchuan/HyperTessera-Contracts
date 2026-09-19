// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IProtocolFeeConfig} from "../interfaces/IProtocolFeeConfig.sol";
import {IHyperAccessControl} from "../interfaces/IHyperAccessControl.sol";
import {CreationFeeAction, FeePaymentKind} from "../libs/Types.sol";

/// @title ProtocolFeeConfig
/// @notice Governor-controlled fee table for AssetRegistry/VaultFactory creation fees. See
///         IProtocolFeeConfig for the custody model (none — pure config).
contract ProtocolFeeConfig is IProtocolFeeConfig {
    IHyperAccessControl public immutable ac;

    mapping(CreationFeeAction => mapping(FeePaymentKind => uint256)) private _fees;
    mapping(FeePaymentKind => address) private _paymentTokens; // Native unused (always address(0))
    address public override revenuePool;

    constructor(address ac_, address revenuePool_) {
        if (ac_ == address(0) || revenuePool_ == address(0)) revert ZeroAddress();
        ac = IHyperAccessControl(ac_);
        revenuePool = revenuePool_;
    }

    function _onlyGovernor() internal view {
        if (!ac.hasRole(ac.GOVERNOR_ROLE(), msg.sender)) revert NotGovernor();
    }

    function setFee(CreationFeeAction action, FeePaymentKind kind, uint256 amount) external override {
        _onlyGovernor();
        _fees[action][kind] = amount;
        emit FeeSet(action, kind, amount, block.timestamp);
    }

    function setPaymentToken(FeePaymentKind kind, address token) external override {
        _onlyGovernor();
        if (kind == FeePaymentKind.Native) revert NativeKindHasNoToken();
        if (token == address(0)) revert ZeroAddress();
        _paymentTokens[kind] = token;
        emit PaymentTokenSet(kind, token, block.timestamp);
    }

    function setRevenuePool(address pool) external override {
        _onlyGovernor();
        if (pool == address(0)) revert ZeroAddress();
        address old = revenuePool;
        revenuePool = pool;
        emit RevenuePoolSet(old, pool, block.timestamp);
    }

    function feeOf(CreationFeeAction action, FeePaymentKind kind) external view override returns (uint256) {
        return _fees[action][kind];
    }

    function paymentTokenOf(FeePaymentKind kind) external view override returns (address) {
        return _paymentTokens[kind];
    }
}
