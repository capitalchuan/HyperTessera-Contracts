// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoRRegistry} from "../../src/asset-infrastructure/PoRRegistry.sol";
import {IPoRRegistry} from "../../src/interfaces/IPoRRegistry.sol";
import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {AssetRegistry} from "../../src/asset-infrastructure/AssetRegistry.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";
import {ProtocolFeeConfig} from "../../src/asset-infrastructure/ProtocolFeeConfig.sol";
import {FeePaymentKind} from "../../src/libs/Types.sol";

/// @title PoRRegistry Tests
/// @notice Publishing authority is now asset-local: that asset's AssetRegistry owner (the
///         "Issuer"), or an address they designate via setProofPublisher — no global
///         DATA_PROVIDER_ROLE. Publishing also now requires the asset to be active.
contract PoRRegistryTest is Test {
    AssetRegistry internal assetRegistry;
    PoRRegistry internal registry;
    HyperAccessControl internal ac;
    ProtocolFeeConfig internal feeConfig;

    address internal owner = makeAddr("owner"); // AssetRegistry owner (Issuer) for `assetId`
    address internal dataProvider = makeAddr("dataProvider"); // delegated proof publisher
    address internal attacker = makeAddr("attacker");

    uint256 internal assetId;

    bytes32 internal constant DOC_HASH_1 = keccak256("doc1");
    bytes32 internal constant DOC_HASH_2 = keccak256("doc2");
    string internal constant URI_1 = "ipfs://QmABC";
    string internal constant URI_2 = "https://example.com/proof2";

    function setUp() public {
        ac = new HyperAccessControl(makeAddr("governor"));
        feeConfig = new ProtocolFeeConfig(address(ac), makeAddr("revPool"));
        assetRegistry = new AssetRegistry(address(feeConfig));
        registry = new PoRRegistry(address(assetRegistry));

        vm.prank(owner);
        (uint256 id,) = assetRegistry.registerAsset(
            keccak256("meta"), "S Token", "S-TKN", 6, FeePaymentKind.Native, _sampleProduct()
        );
        assetId = id;

        vm.prank(owner);
        registry.setProofPublisher(assetId, dataProvider);
    }

    function _sampleProduct() internal pure returns (IAssetRegistry.ProductInfo memory) {
        return IAssetRegistry.ProductInfo({
            productName: "Test Note",
            annualYieldRateBps: 500,
            maturityTimestamp: 1790000000,
            issuer: address(0),
            underlyingAsset: "US Treasury Bill"
        });
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroAssetRegistry() public {
        vm.expectRevert(IPoRRegistry.ZeroAddress.selector);
        new PoRRegistry(address(0));
    }

    // -----------------------------------------------------------------------
    // setProofPublisher — asset owner only
    // -----------------------------------------------------------------------

    function test_setProofPublisher_ownerSucceeds() public {
        address newPublisher = makeAddr("newPublisher");
        vm.prank(owner);
        registry.setProofPublisher(assetId, newPublisher);
        assertEq(registry.proofPublisherOf(assetId), newPublisher);
    }

    function test_setProofPublisher_revertsForNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(IPoRRegistry.NotAssetOwner.selector);
        registry.setProofPublisher(assetId, attacker);
    }

    // -----------------------------------------------------------------------
    // publishReserveProof — access control
    // -----------------------------------------------------------------------

    function test_publishReserveProof_revertsForUnauthorizedPublisher() public {
        vm.prank(attacker);
        vm.expectRevert(IPoRRegistry.NotAuthorizedPublisher.selector);
        registry.publishReserveProof(assetId, DOC_HASH_1, URI_1);
    }

    function test_publishReserveProof_revertsIfAssetNotActive() public {
        vm.prank(dataProvider);
        vm.expectRevert(abi.encodeWithSelector(IPoRRegistry.AssetNotActive.selector, 999));
        registry.publishReserveProof(999, DOC_HASH_1, URI_1);
    }

    function test_publishReserveProof_delegatedPublisherSucceeds() public {
        vm.prank(dataProvider);
        registry.publishReserveProof(assetId, DOC_HASH_1, URI_1);

        assertEq(registry.getProofCount(assetId), 1);
    }

    function test_publishReserveProof_ownerCanPublishWithoutDelegation() public {
        vm.prank(owner);
        registry.publishReserveProof(assetId, DOC_HASH_1, URI_1);

        assertEq(registry.getProofCount(assetId), 1);
    }

    function test_publishReserveProof_emitsEvent() public {
        vm.expectEmit(true, false, true, true, address(registry));
        emit IPoRRegistry.ReserveProofPublished(assetId, DOC_HASH_1, URI_1, dataProvider, block.timestamp);

        vm.prank(dataProvider);
        registry.publishReserveProof(assetId, DOC_HASH_1, URI_1);
    }

    function test_publishReserveProof_storesFields() public {
        vm.prank(dataProvider);
        registry.publishReserveProof(assetId, DOC_HASH_1, URI_1);

        IPoRRegistry.ReserveProof memory p = registry.getLatestProof(assetId);
        assertEq(p.documentHash, DOC_HASH_1);
        assertEq(p.uri, URI_1);
        assertEq(p.publisher, dataProvider);
        assertEq(p.publishedAt, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Append-only: multiple proofs per asset
    // -----------------------------------------------------------------------

    function test_multipleProofs_appendedInOrder() public {
        vm.prank(dataProvider);
        registry.publishReserveProof(assetId, DOC_HASH_1, URI_1);

        vm.warp(block.timestamp + 1 days);
        vm.prank(dataProvider);
        registry.publishReserveProof(assetId, DOC_HASH_2, URI_2);

        assertEq(registry.getProofCount(assetId), 2);

        IPoRRegistry.ReserveProof memory first = registry.getProof(assetId, 0);
        assertEq(first.documentHash, DOC_HASH_1);

        IPoRRegistry.ReserveProof memory latest = registry.getLatestProof(assetId);
        assertEq(latest.documentHash, DOC_HASH_2);
    }

    // -----------------------------------------------------------------------
    // Views — error cases
    // -----------------------------------------------------------------------

    function test_getLatestProof_revertsIfNoProofs() public {
        vm.expectRevert(abi.encodeWithSelector(IPoRRegistry.NoProofExists.selector, 42));
        registry.getLatestProof(42);
    }

    function test_getProof_revertsIfIndexOutOfRange() public {
        vm.prank(dataProvider);
        registry.publishReserveProof(assetId, DOC_HASH_1, URI_1);

        vm.expectRevert(abi.encodeWithSelector(IPoRRegistry.IndexOutOfRange.selector, assetId, 5, 1));
        registry.getProof(assetId, 5);
    }

    function test_getProofCount_zeroForUnknownAsset() public view {
        assertEq(registry.getProofCount(999), 0);
    }

    // -----------------------------------------------------------------------
    // Independent per-asset ledgers
    // -----------------------------------------------------------------------

    function test_proofsArePerAsset() public {
        vm.prank(owner);
        (uint256 assetId2,) = assetRegistry.registerAsset(
            keccak256("meta2"), "J Token", "J-TKN", 6, FeePaymentKind.Native, _sampleProduct()
        );
        vm.prank(owner);
        registry.setProofPublisher(assetId2, dataProvider);

        vm.prank(dataProvider);
        registry.publishReserveProof(assetId, DOC_HASH_1, URI_1);

        vm.prank(dataProvider);
        registry.publishReserveProof(assetId2, DOC_HASH_2, URI_2);

        assertEq(registry.getProofCount(assetId), 1);
        assertEq(registry.getProofCount(assetId2), 1);
        assertEq(registry.getLatestProof(assetId).documentHash, DOC_HASH_1);
        assertEq(registry.getLatestProof(assetId2).documentHash, DOC_HASH_2);
    }
}
