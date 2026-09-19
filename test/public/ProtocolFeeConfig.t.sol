// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";
import {ProtocolFeeConfig} from "../../src/asset-infrastructure/ProtocolFeeConfig.sol";
import {IProtocolFeeConfig} from "../../src/interfaces/IProtocolFeeConfig.sol";
import {CreationFeeAction, FeePaymentKind} from "../../src/libs/Types.sol";

contract ProtocolFeeConfigTest is Test {
    HyperAccessControl internal ac;
    ProtocolFeeConfig internal cfg;

    address internal governor = makeAddr("governor");
    address internal attacker = makeAddr("attacker");
    address internal revPool = makeAddr("revPool");
    address internal govToken = makeAddr("govToken");

    function setUp() public {
        ac = new HyperAccessControl(governor);
        cfg = new ProtocolFeeConfig(address(ac), revPool);
    }

    function test_constructor_setsRevenuePool() public view {
        assertEq(cfg.revenuePool(), revPool);
    }

    function test_defaults_zeroFeeAndUnsetTokens() public view {
        assertEq(cfg.feeOf(CreationFeeAction.RegisterAsset, FeePaymentKind.Native), 0);
        assertEq(cfg.feeOf(CreationFeeAction.DeployVault, FeePaymentKind.Stable), 0);
        assertEq(cfg.paymentTokenOf(FeePaymentKind.Governance), address(0));
        assertEq(cfg.paymentTokenOf(FeePaymentKind.Stable), address(0));
    }

    function test_setFee_governorSucceeds() public {
        vm.prank(governor);
        cfg.setFee(CreationFeeAction.RegisterAsset, FeePaymentKind.Native, 1 ether);
        assertEq(cfg.feeOf(CreationFeeAction.RegisterAsset, FeePaymentKind.Native), 1 ether);
    }

    function test_setFee_nonGovernorReverts() public {
        vm.prank(attacker);
        vm.expectRevert(IProtocolFeeConfig.NotGovernor.selector);
        cfg.setFee(CreationFeeAction.RegisterAsset, FeePaymentKind.Native, 1 ether);
    }

    function test_setPaymentToken_governorSucceeds() public {
        vm.prank(governor);
        cfg.setPaymentToken(FeePaymentKind.Governance, govToken);
        assertEq(cfg.paymentTokenOf(FeePaymentKind.Governance), govToken);
    }

    function test_setPaymentToken_nativeKindReverts() public {
        vm.prank(governor);
        vm.expectRevert(IProtocolFeeConfig.NativeKindHasNoToken.selector);
        cfg.setPaymentToken(FeePaymentKind.Native, govToken);
    }

    function test_setPaymentToken_zeroAddressReverts() public {
        vm.prank(governor);
        vm.expectRevert(IProtocolFeeConfig.ZeroAddress.selector);
        cfg.setPaymentToken(FeePaymentKind.Stable, address(0));
    }

    function test_setPaymentToken_nonGovernorReverts() public {
        vm.prank(attacker);
        vm.expectRevert(IProtocolFeeConfig.NotGovernor.selector);
        cfg.setPaymentToken(FeePaymentKind.Governance, govToken);
    }

    function test_setRevenuePool_governorSucceeds() public {
        address newPool = makeAddr("newPool");
        vm.prank(governor);
        cfg.setRevenuePool(newPool);
        assertEq(cfg.revenuePool(), newPool);
    }

    function test_setRevenuePool_nonGovernorReverts() public {
        vm.prank(attacker);
        vm.expectRevert(IProtocolFeeConfig.NotGovernor.selector);
        cfg.setRevenuePool(makeAddr("newPool"));
    }

    function test_setRevenuePool_zeroAddressReverts() public {
        vm.prank(governor);
        vm.expectRevert(IProtocolFeeConfig.ZeroAddress.selector);
        cfg.setRevenuePool(address(0));
    }

    function test_constructor_revertsOnZeroAccessControl() public {
        vm.expectRevert(IProtocolFeeConfig.ZeroAddress.selector);
        new ProtocolFeeConfig(address(0), revPool);
    }

    function test_constructor_revertsOnZeroRevenuePool() public {
        vm.expectRevert(IProtocolFeeConfig.ZeroAddress.selector);
        new ProtocolFeeConfig(address(ac), address(0));
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    function test_setFee_emitsEvent() public {
        vm.expectEmit(true, true, false, true, address(cfg));
        emit IProtocolFeeConfig.FeeSet(CreationFeeAction.DeployVault, FeePaymentKind.Stable, 42e6, block.timestamp);
        vm.prank(governor);
        cfg.setFee(CreationFeeAction.DeployVault, FeePaymentKind.Stable, 42e6);
    }

    function test_setPaymentToken_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(cfg));
        emit IProtocolFeeConfig.PaymentTokenSet(FeePaymentKind.Stable, govToken, block.timestamp);
        vm.prank(governor);
        cfg.setPaymentToken(FeePaymentKind.Stable, govToken);
    }

    function test_setRevenuePool_emitsEventWithOldAndNew() public {
        address newPool = makeAddr("newPool2");
        vm.expectEmit(false, false, false, true, address(cfg));
        emit IProtocolFeeConfig.RevenuePoolSet(revPool, newPool, block.timestamp);
        vm.prank(governor);
        cfg.setRevenuePool(newPool);
    }

    /// @dev The fee table is keyed on (action, kind) — writing one cell must not touch another.
    function test_setFee_cellsAreIndependent() public {
        vm.startPrank(governor);
        cfg.setFee(CreationFeeAction.RegisterAsset, FeePaymentKind.Native, 1 ether);
        cfg.setFee(CreationFeeAction.DeployVault, FeePaymentKind.Native, 7 ether);
        cfg.setFee(CreationFeeAction.RegisterAsset, FeePaymentKind.Stable, 100e6);
        vm.stopPrank();

        assertEq(cfg.feeOf(CreationFeeAction.RegisterAsset, FeePaymentKind.Native), 1 ether);
        assertEq(cfg.feeOf(CreationFeeAction.DeployVault, FeePaymentKind.Native), 7 ether);
        assertEq(cfg.feeOf(CreationFeeAction.RegisterAsset, FeePaymentKind.Stable), 100e6);
        assertEq(cfg.feeOf(CreationFeeAction.DeployVault, FeePaymentKind.Stable), 0);
    }

    /// @dev Native has no token slot at all, so it must stay address(0) even after every other
    ///      kind has been configured.
    function test_paymentTokenOf_nativeStaysUnset() public {
        vm.startPrank(governor);
        cfg.setPaymentToken(FeePaymentKind.Stable, govToken);
        cfg.setPaymentToken(FeePaymentKind.Governance, makeAddr("gov2"));
        vm.stopPrank();
        assertEq(cfg.paymentTokenOf(FeePaymentKind.Native), address(0));
    }
}
