// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {MintBurnController} from "../../src/asset-infrastructure/MintBurnController.sol";
import {IMintBurnController} from "../../src/interfaces/IMintBurnController.sol";
import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {IRWAToken} from "../../src/interfaces/IRWAToken.sol";
import {AssetRegistry} from "../../src/asset-infrastructure/AssetRegistry.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";
import {ProtocolFeeConfig} from "../../src/asset-infrastructure/ProtocolFeeConfig.sol";
import {FeePaymentKind} from "../../src/libs/Types.sol";

/// @title MintBurnControllerTest
/// @notice Suite for MintBurnController. Issuer and Token Agent are now resolved per-assetId from
///         AssetRegistry (Issuer == AssetRegistry owner; Token Agent == whoever the Issuer appoints
///         via setTokenAgent) instead of global HyperAccessControl roles.
contract MintBurnControllerTest is Test {
    address internal issuer = makeAddr("issuer");
    address internal tokenAgent = makeAddr("tokenAgent");
    address internal attacker = makeAddr("attacker");
    address internal alice = makeAddr("alice");

    AssetRegistry internal assetRegistry;
    MintBurnController internal ctrl;
    HyperAccessControl internal ac;
    ProtocolFeeConfig internal feeConfig;

    uint256 internal S_ASSET_ID = 1;
    uint256 internal J_ASSET_ID = 2;

    bytes32 internal constant META_HASH = keccak256("metadata");

    // Token references resolved after registration.
    IRWAToken internal sToken;
    IRWAToken internal jToken;

    function setUp() public {
        ac = new HyperAccessControl(makeAddr("governor"));
        feeConfig = new ProtocolFeeConfig(address(ac), makeAddr("revPool"));
        assetRegistry = new AssetRegistry(address(feeConfig));
        // AssetRegistry deploys and owns its own MintBurnController internally.
        ctrl = MintBurnController(assetRegistry.mintBurnController());

        // Register S (id=1) and J (id=2) assets as `issuer`; issuer becomes the AssetRegistry
        // owner for both, which is this MintBurnController's notion of "Issuer" for each assetId.
        vm.prank(issuer);
        (, address sAddr) =
            assetRegistry.registerAsset(META_HASH, "S Token", "S-TKN", 6, FeePaymentKind.Native, _sampleProduct());
        vm.prank(issuer);
        (, address jAddr) =
            assetRegistry.registerAsset(META_HASH, "J Token", "J-TKN", 6, FeePaymentKind.Native, _sampleProduct());

        sToken = IRWAToken(sAddr);
        jToken = IRWAToken(jAddr);

        // Issuer appoints the Token Agent for both assets.
        vm.startPrank(issuer);
        ctrl.setTokenAgent(S_ASSET_ID, tokenAgent);
        ctrl.setTokenAgent(J_ASSET_ID, tokenAgent);
        vm.stopPrank();
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

    // Helper: full mint via the initiate/approve flow.
    function _mint(uint256 assetId, uint256 amount, address to) internal returns (uint256 nonce) {
        vm.prank(issuer);
        nonce = ctrl.initiateMint(assetId, amount, to);
        vm.prank(tokenAgent);
        ctrl.approveMint(nonce);
    }

    function _tokenFor(uint256 assetId) internal view returns (IRWAToken) {
        return IRWAToken(assetRegistry.tokenOf(assetId));
    }

    // -----------------------------------------------------------------------
    // registerToken
    // -----------------------------------------------------------------------

    function test_registerToken_storedByAssetRegistry() public view {
        // Tokens were registered automatically via assetRegistry.registerAsset.
        assertEq(ctrl.rwaTokens(S_ASSET_ID), address(sToken));
        assertEq(ctrl.rwaTokens(J_ASSET_ID), address(jToken));
    }

    function test_registerToken_revertsForNonAssetRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(IMintBurnController.NotAssetRegistry.selector);
        ctrl.registerToken(99, makeAddr("token"));
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_setsImmutables() public view {
        assertEq(address(ctrl.assetRegistry()), address(assetRegistry));
    }

    function test_constructor_noncesStartAtZero() public view {
        assertEq(ctrl.nextMintNonce(), 0);
        assertEq(ctrl.nextBurnNonce(), 0);
    }

    function test_constructor_revertsOnZeroAssetRegistry() public {
        vm.expectRevert(IMintBurnController.ZeroAddress.selector);
        new MintBurnController(address(0));
    }

    // -----------------------------------------------------------------------
    // setTokenAgent — Issuer (AssetRegistry owner) only
    // -----------------------------------------------------------------------

    function test_setTokenAgent_issuerSucceeds() public {
        address newAgent = makeAddr("newAgent");
        vm.prank(issuer);
        ctrl.setTokenAgent(S_ASSET_ID, newAgent);
        assertEq(ctrl.tokenAgentOf(S_ASSET_ID), newAgent);
    }

    function test_setTokenAgent_revertsForNonIssuer() public {
        vm.prank(attacker);
        vm.expectRevert(IMintBurnController.NotIssuer.selector);
        ctrl.setTokenAgent(S_ASSET_ID, attacker);
    }

    function test_setTokenAgent_revertsOnZeroAddress() public {
        vm.prank(issuer);
        vm.expectRevert(IMintBurnController.ZeroAddress.selector);
        ctrl.setTokenAgent(S_ASSET_ID, address(0));
    }

    // -----------------------------------------------------------------------
    // initiateMint
    // -----------------------------------------------------------------------

    function test_initiateMint_revertsIfNotIssuer() public {
        vm.prank(attacker);
        vm.expectRevert(IMintBurnController.NotIssuer.selector);
        ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);
    }

    function test_initiateMint_revertsIfZeroAmount() public {
        vm.prank(issuer);
        vm.expectRevert(IMintBurnController.ZeroAmount.selector);
        ctrl.initiateMint(S_ASSET_ID, 0, alice);
    }

    function test_initiateMint_revertsIfAssetNotRegistered() public {
        // assetId 99 has no owner, so it fails the Issuer check before reaching the
        // asset-active check.
        vm.prank(attacker);
        vm.expectRevert(IMintBurnController.NotIssuer.selector);
        ctrl.initiateMint(99, 1_000e6, alice);
    }

    function test_initiateMint_revertsIfAssetDeactivated() public {
        vm.prank(issuer);
        assetRegistry.deactivateAsset(S_ASSET_ID);

        vm.prank(issuer);
        vm.expectRevert(IMintBurnController.AssetNotRegistered.selector);
        ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);
    }

    function test_initiateMint_succeedsAndReturnsNonce() public {
        vm.prank(issuer);
        uint256 n = ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);
        assertEq(n, 0);
    }

    function test_initiateMint_storesRequest() public {
        uint256 amount = 1_000e6;
        vm.prank(issuer);
        ctrl.initiateMint(S_ASSET_ID, amount, alice);

        (uint256 assetId, uint256 amt, address to, bool approved, bool executed) = ctrl.mintRequests(0);
        assertEq(assetId, S_ASSET_ID);
        assertEq(amt, amount);
        assertEq(to, alice);
        assertFalse(approved);
        assertFalse(executed);
    }

    function test_initiateMint_incrementsNextMintNonce() public {
        vm.prank(issuer);
        ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);
        assertEq(ctrl.nextMintNonce(), 1);
    }

    function test_initiateMint_emitsMintInitiated() public {
        uint256 amount = 1_000e6;
        vm.expectEmit(true, true, true, true);
        emit IMintBurnController.MintInitiated(0, S_ASSET_ID, amount, alice, block.timestamp);

        vm.prank(issuer);
        ctrl.initiateMint(S_ASSET_ID, amount, alice);
    }

    function test_initiateMint_twoRequestsDistinctNonces() public {
        vm.startPrank(issuer);
        uint256 n0 = ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);
        uint256 n1 = ctrl.initiateMint(J_ASSET_ID, 2_000e6, alice);
        vm.stopPrank();

        assertEq(n0, 0);
        assertEq(n1, 1);
        assertEq(ctrl.nextMintNonce(), 2);
    }

    // -----------------------------------------------------------------------
    // approveMint
    // -----------------------------------------------------------------------

    function test_approveMint_revertsIfNotTokenAgent() public {
        vm.prank(issuer);
        ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);

        vm.prank(attacker);
        vm.expectRevert(IMintBurnController.NotTokenAgent.selector);
        ctrl.approveMint(0);
    }

    function test_approveMint_revertsIfNeverInitiated() public {
        vm.prank(tokenAgent);
        vm.expectRevert(IMintBurnController.RequestNotFound.selector);
        ctrl.approveMint(0);
    }

    function test_approveMint_revertsIfAlreadyExecuted() public {
        vm.prank(issuer);
        ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);
        vm.prank(tokenAgent);
        ctrl.approveMint(0);

        vm.prank(tokenAgent);
        vm.expectRevert(IMintBurnController.AlreadyExecuted.selector);
        ctrl.approveMint(0);
    }

    function test_approveMint_mintsTokensToRecipient() public {
        uint256 amount = 1_000e6;
        vm.prank(issuer);
        ctrl.initiateMint(S_ASSET_ID, amount, alice);
        vm.prank(tokenAgent);
        ctrl.approveMint(0);

        assertEq(_tokenFor(S_ASSET_ID).balanceOf(alice), amount);
    }

    function test_approveMint_marksApprovedAndExecuted() public {
        vm.prank(issuer);
        ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);
        vm.prank(tokenAgent);
        ctrl.approveMint(0);

        (,,, bool approved, bool executed) = ctrl.mintRequests(0);
        assertTrue(approved);
        assertTrue(executed);
    }

    function test_approveMint_emitsMintApproved() public {
        uint256 amount = 1_000e6;
        vm.prank(issuer);
        ctrl.initiateMint(S_ASSET_ID, amount, alice);

        vm.expectEmit(true, true, true, true);
        emit IMintBurnController.MintApproved(0, S_ASSET_ID, amount, alice, block.timestamp);

        vm.prank(tokenAgent);
        ctrl.approveMint(0);
    }

    function test_fullMintFlow_sToken() public {
        uint256 amount = 5_000e6;
        uint256 n = _mint(S_ASSET_ID, amount, alice);
        assertEq(n, 0);
        assertEq(_tokenFor(S_ASSET_ID).balanceOf(alice), amount);
    }

    function test_fullMintFlow_jToken() public {
        uint256 amount = 3_000e6;
        _mint(J_ASSET_ID, amount, alice);
        assertEq(_tokenFor(J_ASSET_ID).balanceOf(alice), amount);
    }

    // -----------------------------------------------------------------------
    // initiateBurn
    // -----------------------------------------------------------------------

    function test_initiateBurn_revertsIfNotIssuer() public {
        _mint(S_ASSET_ID, 1_000e6, alice);

        vm.prank(attacker);
        vm.expectRevert(IMintBurnController.NotIssuer.selector);
        ctrl.initiateBurn(S_ASSET_ID, 1_000e6, alice);
    }

    function test_initiateBurn_revertsIfZeroAmount() public {
        _mint(S_ASSET_ID, 1_000e6, alice);

        vm.prank(issuer);
        vm.expectRevert(IMintBurnController.ZeroAmount.selector);
        ctrl.initiateBurn(S_ASSET_ID, 0, alice);
    }

    function test_initiateBurn_revertsIfInsufficientBalance() public {
        vm.prank(issuer);
        vm.expectRevert(IMintBurnController.InsufficientBalance.selector);
        ctrl.initiateBurn(S_ASSET_ID, 1, alice);
    }

    function test_initiateBurn_succeedsAndReturnsBurnNonceZero() public {
        _mint(S_ASSET_ID, 1_000e6, alice);

        vm.prank(issuer);
        uint256 n = ctrl.initiateBurn(S_ASSET_ID, 1_000e6, alice);
        assertEq(n, 0);
    }

    function test_initiateBurn_storesRequest() public {
        uint256 amount = 1_000e6;
        _mint(S_ASSET_ID, amount, alice);

        vm.prank(issuer);
        ctrl.initiateBurn(S_ASSET_ID, amount, alice);

        (uint256 assetId, uint256 amt, address from, bool approved, bool executed) = ctrl.burnRequests(0);
        assertEq(assetId, S_ASSET_ID);
        assertEq(amt, amount);
        assertEq(from, alice);
        assertFalse(approved);
        assertFalse(executed);
    }

    // -----------------------------------------------------------------------
    // approveBurn
    // -----------------------------------------------------------------------

    function test_approveBurn_burnsTokensFromAddress() public {
        uint256 amount = 1_000e6;
        _mint(S_ASSET_ID, amount, alice);

        vm.prank(issuer);
        ctrl.initiateBurn(S_ASSET_ID, amount, alice);
        vm.prank(tokenAgent);
        ctrl.approveBurn(0);

        assertEq(_tokenFor(S_ASSET_ID).balanceOf(alice), 0);
    }

    function test_approveBurn_revertsIfNotTokenAgent() public {
        _mint(S_ASSET_ID, 1_000e6, alice);
        vm.prank(issuer);
        ctrl.initiateBurn(S_ASSET_ID, 1_000e6, alice);

        vm.prank(attacker);
        vm.expectRevert(IMintBurnController.NotTokenAgent.selector);
        ctrl.approveBurn(0);
    }

    function test_approveBurn_revertsIfAlreadyExecuted() public {
        _mint(S_ASSET_ID, 1_000e6, alice);
        vm.prank(issuer);
        ctrl.initiateBurn(S_ASSET_ID, 1_000e6, alice);
        vm.prank(tokenAgent);
        ctrl.approveBurn(0);

        vm.prank(tokenAgent);
        vm.expectRevert(IMintBurnController.AlreadyExecuted.selector);
        ctrl.approveBurn(0);
    }

    function test_approveBurn_emitsBurnApproved() public {
        uint256 amount = 1_000e6;
        _mint(S_ASSET_ID, amount, alice);
        vm.prank(issuer);
        ctrl.initiateBurn(S_ASSET_ID, amount, alice);

        vm.expectEmit(true, true, true, true);
        emit IMintBurnController.BurnApproved(0, S_ASSET_ID, amount, alice, block.timestamp);

        vm.prank(tokenAgent);
        ctrl.approveBurn(0);
    }

    function test_fullBurnFlow_sToken() public {
        uint256 amount = 2_000e6;
        _mint(S_ASSET_ID, amount, alice);

        vm.prank(issuer);
        uint256 n = ctrl.initiateBurn(S_ASSET_ID, amount, alice);
        assertEq(n, 0);

        vm.prank(tokenAgent);
        ctrl.approveBurn(0);

        assertEq(_tokenFor(S_ASSET_ID).balanceOf(alice), 0);
    }

    // -----------------------------------------------------------------------
    // Issuer/Token-Agent isolation
    // -----------------------------------------------------------------------

    function test_issuerAloneCannotMint() public {
        vm.prank(issuer);
        ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);

        vm.prank(issuer);
        vm.expectRevert(IMintBurnController.NotTokenAgent.selector);
        ctrl.approveMint(0);

        assertEq(_tokenFor(S_ASSET_ID).balanceOf(alice), 0);
    }

    function test_issuerAloneCannotBurn() public {
        _mint(S_ASSET_ID, 1_000e6, alice);

        vm.prank(issuer);
        ctrl.initiateBurn(S_ASSET_ID, 1_000e6, alice);

        vm.prank(issuer);
        vm.expectRevert(IMintBurnController.NotTokenAgent.selector);
        ctrl.approveBurn(0);

        assertEq(_tokenFor(S_ASSET_ID).balanceOf(alice), 1_000e6);
    }

    // -----------------------------------------------------------------------
    // Independent nonce sequences
    // -----------------------------------------------------------------------

    function test_mintAndBurnNoncesAreIndependent() public {
        vm.startPrank(issuer);
        uint256 m0 = ctrl.initiateMint(S_ASSET_ID, 1_000e6, alice);
        uint256 m1 = ctrl.initiateMint(J_ASSET_ID, 2_000e6, alice);
        vm.stopPrank();
        assertEq(m0, 0);
        assertEq(m1, 1);

        vm.prank(tokenAgent);
        ctrl.approveMint(0);

        vm.prank(issuer);
        uint256 b0 = ctrl.initiateBurn(S_ASSET_ID, 500e6, alice);
        assertEq(b0, 0);

        assertEq(ctrl.nextMintNonce(), 2);
        assertEq(ctrl.nextBurnNonce(), 1);
    }

    // -----------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------

    function testFuzz_fullMintFlow_sToken(uint128 amount) public {
        vm.assume(amount > 0);
        _mint(S_ASSET_ID, uint256(amount), alice);
        assertEq(_tokenFor(S_ASSET_ID).balanceOf(alice), uint256(amount));
    }

    function testFuzz_fullBurnFlow_sToken(uint128 mintAmt, uint128 burnAmt) public {
        vm.assume(mintAmt > 0 && burnAmt > 0 && burnAmt <= mintAmt);
        _mint(S_ASSET_ID, uint256(mintAmt), alice);

        vm.prank(issuer);
        ctrl.initiateBurn(S_ASSET_ID, uint256(burnAmt), alice);
        vm.prank(tokenAgent);
        ctrl.approveBurn(0);

        assertEq(_tokenFor(S_ASSET_ID).balanceOf(alice), uint256(mintAmt) - uint256(burnAmt));
    }
}
