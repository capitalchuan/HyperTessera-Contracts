// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetRegistry} from "../../src/asset-infrastructure/AssetRegistry.sol";
import {MintBurnController} from "../../src/asset-infrastructure/MintBurnController.sol";
import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {IRWAToken} from "../../src/interfaces/IRWAToken.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProtocolFeeConfig} from "../../src/asset-infrastructure/ProtocolFeeConfig.sol";
import {IProtocolFeeConfig} from "../../src/interfaces/IProtocolFeeConfig.sol";
import {CreationFeeAction, FeePaymentKind} from "../../src/libs/Types.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MockERC20Fee is ERC20 {
    constructor() ERC20("MockFeeToken", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title AssetRegistry Tests
/// @notice Suite for AssetRegistry per development-plan §3.2.1 (revised 2026-06-22/25).
/// @dev    registerAsset is permissionless: any address may register an RWA asset; the registrant
///         becomes the asset owner. Owner may update metadata, transfer ownership, and deactivate.
///         Deactivation is owner-only — the old Governor override was removed.
contract AssetRegistryTest is Test {
    AssetRegistry internal registry;
    HyperAccessControl internal ac;
    ProtocolFeeConfig internal feeConfig;

    address internal governor = makeAddr("governor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant META_HASH_1 = keccak256("META_1");
    bytes32 internal constant META_HASH_2 = keccak256("META_2");
    bytes32 internal constant META_HASH_3 = keccak256("META_3");

    string internal constant NAME = "S Token";
    string internal constant SYMBOL = "S-TKN";
    uint8 internal constant DECIMALS = 6;

    function setUp() public {
        ac = new HyperAccessControl(governor);
        feeConfig = new ProtocolFeeConfig(address(ac), makeAddr("revPool"));
        registry = new AssetRegistry(address(feeConfig));
    }

    // Helper: register one asset as alice (owner), returns (assetId, tokenAddr).
    function _registerOne() internal returns (uint256 id, address token) {
        vm.prank(alice);
        (id, token) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
    }

    function _sampleProduct() internal pure returns (IAssetRegistry.ProductInfo memory) {
        return IAssetRegistry.ProductInfo({
            productName: "30-day T-Bill Note",
            annualYieldRateBps: 500, // 5.00% APY
            maturityTimestamp: 1790000000,
            issuer: address(0), // forced to msg.sender by the contract
            underlyingAsset: "US Treasury Bill"
        });
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_nextAssetIdStartsAtOne() public view {
        assertEq(registry.nextAssetId(), 1);
    }

    function test_constructor_deploysOwnMintBurnController() public view {
        address mbc = registry.mintBurnController();
        assertTrue(mbc != address(0));
        assertEq(address(MintBurnController(mbc).assetRegistry()), address(registry));
    }

    // -----------------------------------------------------------------------
    // registerAsset — permissionless (any address may register)
    // -----------------------------------------------------------------------

    function test_registerAsset_byAnyAddressSucceeds() public {
        vm.prank(alice);
        (uint256 id, address token) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(id, 1);
        assertTrue(token != address(0));
    }

    function test_registerAsset_byGovernorSucceeds() public {
        vm.prank(governor);
        (uint256 id,) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(id, 1);
    }

    function test_registerAsset_byAttackerSucceeds() public {
        vm.prank(attacker);
        (uint256 id,) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(id, 1);
    }

    function test_registerAsset_callerBecomesOwner() public {
        vm.prank(alice);
        (uint256 id,) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(registry.ownerOf(id), alice);
    }

    function test_registerAsset_returnsSequentialIdStartingAtOne() public {
        vm.prank(alice);
        (uint256 id1,) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(id1, 1);

        vm.prank(bob);
        (uint256 id2,) =
            registry.registerAsset(META_HASH_2, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(id2, 2);
    }

    function test_registerAsset_multipleCallerssGetDistinctIds() public {
        vm.prank(alice);
        (uint256 id1, address t1) =
            registry.registerAsset(META_HASH_1, "S Token", "S-TKN", 6, FeePaymentKind.Native, _sampleProduct());
        vm.prank(bob);
        (uint256 id2, address t2) =
            registry.registerAsset(META_HASH_2, "J Token", "J-TKN", 6, FeePaymentKind.Native, _sampleProduct());

        assertTrue(id1 != id2);
        assertTrue(t1 != t2);
        assertEq(registry.ownerOf(id1), alice);
        assertEq(registry.ownerOf(id2), bob);
    }

    function test_registerAsset_deployedTokenHasCorrectMetadata() public {
        (, address token) = _registerOne();
        IRWAToken t = IRWAToken(token);
        assertEq(t.name(), NAME);
        assertEq(t.symbol(), SYMBOL);
        assertEq(t.decimals(), DECIMALS);
    }

    function test_registerAsset_deployedTokenWiredToRegistryMintBurnController() public {
        (, address token) = _registerOne();
        assertEq(IRWAToken(token).mintBurnController(), registry.mintBurnController());
    }

    function test_registerAsset_incrementsNextAssetId() public {
        vm.prank(alice);
        registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(registry.nextAssetId(), 2);
    }

    function test_registerAsset_storesRecord() public {
        (uint256 id, address token) = _registerOne();

        IAssetRegistry.AssetInfo memory info = registry.getAsset(id);
        assertEq(info.metadataHash, META_HASH_1);
        assertEq(info.token, token);
        assertTrue(info.active);
        assertEq(info.registeredAt, block.timestamp);
        assertEq(info.owner, alice);
    }

    function test_registerAsset_tokenOfReturnsDeployedAddress() public {
        (uint256 id, address token) = _registerOne();
        assertEq(registry.tokenOf(id), token);
    }

    function test_registerAsset_isActiveReturnsTrue() public {
        (uint256 id,) = _registerOne();
        assertTrue(registry.isActive(id));
    }

    // -----------------------------------------------------------------------
    // ProductInfo
    // -----------------------------------------------------------------------

    function test_registerAsset_storesProductInfo() public {
        vm.prank(alice);
        (uint256 id,) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());

        IAssetRegistry.ProductInfo memory p = registry.getProductInfo(id);
        assertEq(p.productName, "30-day T-Bill Note");
        assertEq(p.annualYieldRateBps, 500);
        assertEq(p.maturityTimestamp, 1790000000);
        assertEq(p.underlyingAsset, "US Treasury Bill");
    }

    /// @notice issuer must always be the msg.sender of the registration tx, so a caller cannot
    ///         name someone else as issuer.
    function test_registerAsset_issuerForcedToSender() public {
        IAssetRegistry.ProductInfo memory p = _sampleProduct();
        p.issuer = bob; // attempt to impersonate

        vm.prank(alice);
        (uint256 id,) = registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, p);

        assertEq(registry.getProductInfo(id).issuer, alice);
    }

    /// @notice The existing AssetRegistered event must not be widened, or existing indexers
    ///         will fail to decode it.
    function test_registerAsset_emitsBothEvents() public {
        vm.expectEmit(true, true, false, false);
        emit IAssetRegistry.ProductInfoSet(1, alice, "", 0, 0, "", 0);
        vm.prank(alice);
        registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
    }

    // -----------------------------------------------------------------------
    // ownerOf
    // -----------------------------------------------------------------------

    function test_ownerOf_returnsZeroForUnknownAsset() public view {
        assertEq(registry.ownerOf(999), address(0));
    }

    // -----------------------------------------------------------------------
    // updateMetadataHash — owner only
    // -----------------------------------------------------------------------

    function test_updateMetadataHash_ownerSucceeds() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.updateMetadataHash(id, META_HASH_3);

        assertEq(registry.getAsset(id).metadataHash, META_HASH_3);
    }

    function test_updateMetadataHash_emitsEvent() public {
        (uint256 id,) = _registerOne();

        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetRegistry.AssetMetadataUpdated(id, META_HASH_1, META_HASH_3, block.timestamp);

        vm.prank(alice);
        registry.updateMetadataHash(id, META_HASH_3);
    }

    function test_updateMetadataHash_doesNotAffectActiveStatus() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.updateMetadataHash(id, META_HASH_3);

        assertTrue(registry.isActive(id));
    }

    function test_updateMetadataHash_revertsForNonOwner() public {
        (uint256 id,) = _registerOne();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.NotAssetOwner.selector, id, attacker));
        registry.updateMetadataHash(id, META_HASH_3);
    }

    function test_updateMetadataHash_governorRevertsIfNotOwner() public {
        (uint256 id,) = _registerOne();

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.NotAssetOwner.selector, id, governor));
        registry.updateMetadataHash(id, META_HASH_3);
    }

    function test_updateMetadataHash_revertsWhenNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(IAssetRegistry.NotRegistered.selector);
        registry.updateMetadataHash(999, META_HASH_3);
    }

    // -----------------------------------------------------------------------
    // setMetadataURI / metadataURIOf — owner only, mirrors PoRRegistry's hash + pointer pattern
    // -----------------------------------------------------------------------

    string internal constant URI_1 = "ipfs://QmDealDoc1";
    string internal constant URI_2 = "https://docs.example.com/asset/1.json";

    function test_setMetadataURI_ownerSucceeds() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.setMetadataURI(id, URI_1);

        assertEq(registry.metadataURIOf(id), URI_1);
    }

    function test_setMetadataURI_emitsEvent() public {
        (uint256 id,) = _registerOne();

        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetRegistry.AssetMetadataURISet(id, URI_1, block.timestamp);

        vm.prank(alice);
        registry.setMetadataURI(id, URI_1);
    }

    function test_setMetadataURI_overwritesPreviousValue() public {
        (uint256 id,) = _registerOne();

        vm.startPrank(alice);
        registry.setMetadataURI(id, URI_1);
        registry.setMetadataURI(id, URI_2);
        vm.stopPrank();

        assertEq(registry.metadataURIOf(id), URI_2);
    }

    function test_setMetadataURI_emptyStringClearsPointer() public {
        (uint256 id,) = _registerOne();

        vm.startPrank(alice);
        registry.setMetadataURI(id, URI_1);
        registry.setMetadataURI(id, "");
        vm.stopPrank();

        assertEq(registry.metadataURIOf(id), "");
    }

    function test_setMetadataURI_revertsForNonOwner() public {
        (uint256 id,) = _registerOne();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.NotAssetOwner.selector, id, attacker));
        registry.setMetadataURI(id, URI_1);
    }

    function test_setMetadataURI_governorRevertsIfNotOwner() public {
        (uint256 id,) = _registerOne();

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.NotAssetOwner.selector, id, governor));
        registry.setMetadataURI(id, URI_1);
    }

    // Gating is copied verbatim from updateMetadataHash: the NotRegistered check runs first, so an
    // unknown assetId reverts NotRegistered rather than NotAssetOwner, for any caller.
    function test_setMetadataURI_revertsWhenNotRegistered() public {
        vm.prank(alice);
        vm.expectRevert(IAssetRegistry.NotRegistered.selector);
        registry.setMetadataURI(999, URI_1);
    }

    function test_setMetadataURI_newOwnerCanSetAfterTransfer() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.transferAssetOwnership(id, bob);

        vm.prank(bob);
        registry.setMetadataURI(id, URI_2);

        assertEq(registry.metadataURIOf(id), URI_2);
    }

    function test_metadataURIOf_emptyForRegisteredButNeverSet() public {
        (uint256 id,) = _registerOne();
        assertEq(registry.metadataURIOf(id), "");
    }

    function test_metadataURIOf_emptyForUnknownAsset() public view {
        assertEq(registry.metadataURIOf(999), "");
    }

    // Guards the whole point of the standalone-mapping design: AssetInfo is untouched.
    function test_setMetadataURI_doesNotAffectAssetInfo() public {
        (uint256 id, address token) = _registerOne();

        vm.prank(alice);
        registry.setMetadataURI(id, URI_1);

        IAssetRegistry.AssetInfo memory info = registry.getAsset(id);
        assertEq(info.metadataHash, META_HASH_1);
        assertEq(info.token, token);
        assertTrue(info.active);
        assertEq(info.owner, alice);
    }

    // -----------------------------------------------------------------------
    // transferAssetOwnership — owner only
    // -----------------------------------------------------------------------

    function test_transferAssetOwnership_ownerSucceeds() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.transferAssetOwnership(id, bob);

        assertEq(registry.ownerOf(id), bob);
    }

    function test_transferAssetOwnership_emitsEvent() public {
        (uint256 id,) = _registerOne();

        vm.expectEmit(true, true, true, true, address(registry));
        emit IAssetRegistry.AssetOwnershipTransferred(id, alice, bob, block.timestamp);

        vm.prank(alice);
        registry.transferAssetOwnership(id, bob);
    }

    function test_transferAssetOwnership_previousOwnerLosesRights() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.transferAssetOwnership(id, bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.NotAssetOwner.selector, id, alice));
        registry.updateMetadataHash(id, META_HASH_2);
    }

    function test_transferAssetOwnership_newOwnerCanUpdate() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.transferAssetOwnership(id, bob);

        vm.prank(bob);
        registry.updateMetadataHash(id, META_HASH_2);

        assertEq(registry.getAsset(id).metadataHash, META_HASH_2);
    }

    function test_transferAssetOwnership_revertsForNonOwner() public {
        (uint256 id,) = _registerOne();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.NotAssetOwner.selector, id, attacker));
        registry.transferAssetOwnership(id, attacker);
    }

    function test_transferAssetOwnership_revertsOnZeroNewOwner() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        vm.expectRevert(IAssetRegistry.ZeroAddress.selector);
        registry.transferAssetOwnership(id, address(0));
    }

    // -----------------------------------------------------------------------
    // deactivateAsset — owner ONLY (Governor override removed in this migration)
    // -----------------------------------------------------------------------

    function test_deactivateAsset_ownerSucceeds() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.deactivateAsset(id);

        assertFalse(registry.isActive(id));
    }

    // NOTE: "Governor can deactivate any asset" no longer exists — deactivateAsset is now
    // Owner-only. Flipped to assert the now-expected revert.
    function test_deactivateAsset_governorNoLongerHasOverride() public {
        (uint256 id,) = _registerOne();

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.NotAssetOwner.selector, id, governor));
        registry.deactivateAsset(id);
    }

    function test_deactivateAsset_setsActiveFalse() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.deactivateAsset(id);

        IAssetRegistry.AssetInfo memory info = registry.getAsset(id);
        assertTrue(info.registeredAt != 0);
        assertFalse(info.active);
    }

    function test_deactivateAsset_emitsEvent() public {
        (uint256 id,) = _registerOne();

        vm.expectEmit(true, false, false, true, address(registry));
        emit IAssetRegistry.AssetDeactivated(id, block.timestamp);

        vm.prank(alice);
        registry.deactivateAsset(id);
    }

    function test_deactivateAsset_revertsForNonOwner() public {
        (uint256 id,) = _registerOne();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.NotAssetOwner.selector, id, attacker));
        registry.deactivateAsset(id);
    }

    function test_deactivateAsset_revertsWhenAlreadyInactive() public {
        (uint256 id,) = _registerOne();

        vm.prank(alice);
        registry.deactivateAsset(id);

        vm.prank(alice);
        vm.expectRevert(IAssetRegistry.NotActive.selector);
        registry.deactivateAsset(id);
    }

    // Owner check now runs before the active check, so an unregistered asset (owner == address(0))
    // reverts NotAssetOwner rather than NotActive for any non-zero caller.
    function test_deactivateAsset_revertsWhenNeverRegistered() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.NotAssetOwner.selector, 999, attacker));
        registry.deactivateAsset(999);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function test_isActive_falseForUnknownAsset() public view {
        assertFalse(registry.isActive(999));
    }

    function test_tokenOf_zeroForUnknownAsset() public view {
        assertEq(registry.tokenOf(999), address(0));
    }

    function test_getAsset_zeroValuedForUnknownAsset() public view {
        IAssetRegistry.AssetInfo memory info = registry.getAsset(999);
        assertEq(info.metadataHash, bytes32(0));
        assertEq(info.token, address(0));
        assertFalse(info.active);
        assertEq(info.registeredAt, 0);
        assertEq(info.owner, address(0));
    }

    // -----------------------------------------------------------------------
    // Integration: full lifecycle
    // -----------------------------------------------------------------------

    function test_lifecycle_registerUpdateTransferDeactivate() public {
        vm.prank(alice);
        (uint256 id, address token) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertTrue(registry.isActive(id));
        assertEq(registry.tokenOf(id), token);
        assertEq(registry.ownerOf(id), alice);

        vm.prank(alice);
        registry.updateMetadataHash(id, META_HASH_2);
        assertEq(registry.getAsset(id).metadataHash, META_HASH_2);

        vm.prank(alice);
        registry.transferAssetOwnership(id, bob);
        assertEq(registry.ownerOf(id), bob);

        vm.prank(bob);
        registry.deactivateAsset(id);
        assertFalse(registry.isActive(id));
        assertTrue(registry.getAsset(id).registeredAt != 0);
        // Token address is preserved even after deactivation.
        assertEq(registry.tokenOf(id), token);
    }

    // -----------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------

    function testFuzz_registerAsset_anyCallerSucceeds(address caller) public {
        vm.assume(caller != address(0));

        vm.prank(caller);
        (uint256 id, address token) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(id, 1);
        assertTrue(token != address(0));
        assertEq(registry.ownerOf(id), caller);
    }

    // -----------------------------------------------------------------------
    // Creation fee gate
    // -----------------------------------------------------------------------

    function test_registerAsset_zeroFee_native_succeeds() public {
        vm.prank(alice);
        (uint256 id,) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(id, 1);
    }

    function test_registerAsset_nativeFee_exactValue_succeeds() public {
        vm.prank(governor);
        feeConfig.setFee(CreationFeeAction.RegisterAsset, FeePaymentKind.Native, 1 ether);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        registry.registerAsset{value: 1 ether}(
            META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct()
        );
        assertEq(feeConfig.revenuePool().balance, 1 ether);
    }

    function test_registerAsset_nativeFee_wrongValue_reverts() public {
        vm.prank(governor);
        feeConfig.setFee(CreationFeeAction.RegisterAsset, FeePaymentKind.Native, 1 ether);

        vm.deal(alice, 2 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.IncorrectNativeFee.selector, 1 ether, 0.5 ether));
        registry.registerAsset{value: 0.5 ether}(
            META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct()
        );
    }

    function test_registerAsset_stableFee_pullsExactAmount() public {
        MockERC20Fee stable = new MockERC20Fee();
        vm.startPrank(governor);
        feeConfig.setPaymentToken(FeePaymentKind.Stable, address(stable));
        feeConfig.setFee(CreationFeeAction.RegisterAsset, FeePaymentKind.Stable, 100e6);
        vm.stopPrank();

        stable.mint(alice, 100e6);
        vm.startPrank(alice);
        stable.approve(address(registry), 100e6);
        registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Stable, _sampleProduct());
        vm.stopPrank();

        assertEq(stable.balanceOf(feeConfig.revenuePool()), 100e6);
        assertEq(stable.balanceOf(alice), 0);
    }

    function test_registerAsset_stableFee_insufficientAllowance_revertsWholeTx() public {
        MockERC20Fee stable = new MockERC20Fee();
        vm.startPrank(governor);
        feeConfig.setPaymentToken(FeePaymentKind.Stable, address(stable));
        feeConfig.setFee(CreationFeeAction.RegisterAsset, FeePaymentKind.Stable, 100e6);
        vm.stopPrank();

        stable.mint(alice, 100e6); // no approve
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(registry), uint256(0), uint256(100e6)
            )
        );
        registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Stable, _sampleProduct());

        assertEq(registry.nextAssetId(), 1); // nothing was created
    }

    function test_registerAsset_unconfiguredGovernanceToken_reverts() public {
        vm.prank(governor);
        feeConfig.setFee(CreationFeeAction.RegisterAsset, FeePaymentKind.Governance, 1);
        // paymentTokenOf(Governance) still address(0) — never configured.

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetRegistry.PaymentTokenNotConfigured.selector, FeePaymentKind.Governance)
        );
        registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Governance, _sampleProduct());
    }

    function test_registerAsset_stillPermissionless_withZeroFee() public {
        // No allowlist added by the fee gate — any address can still register at zero fee.
        vm.prank(attacker);
        (uint256 id,) =
            registry.registerAsset(META_HASH_1, NAME, SYMBOL, DECIMALS, FeePaymentKind.Native, _sampleProduct());
        assertEq(id, 1);
    }

    /// @dev Same reasoning as VaultFactory.feeConfig: constructor-immutable, getter-only.
    function test_feeConfig_exposesTheBoundConfig() public view {
        assertEq(registry.feeConfig(), address(feeConfig));
    }
}
