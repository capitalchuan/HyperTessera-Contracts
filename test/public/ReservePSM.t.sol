// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReservePSM} from "../../src/wrapped-assets/ReservePSM.sol";
import {IReservePSM} from "../../src/interfaces/IReservePSM.sol";
import {WrappedAsset} from "../../src/wrapped-assets/WrappedAsset.sol";
import {HyperAccessControl} from "../../src/governance/HyperAccessControl.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MockERC1271Wallet, BadMagicERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";

// Minimal ERC-20 used as the TOKEN_CUSTODY underlying.
contract MockToken {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// Deducts a flat fee on every transfer, crediting only `amount - fee` to the recipient.
contract FeeOnTransferToken {
    string public name = "Fee";
    string public symbol = "FEE";
    uint8 public decimals = 6;
    uint256 public constant FEE_BPS = 100; // 1%
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        uint256 fee = amount * FEE_BPS / 10_000;
        balanceOf[to] += amount - fee;
        return true;
    }
}

contract ReservePSMTest is Test {
    HyperAccessControl internal ac;
    ReservePSM internal psm;
    MockToken internal underlying;

    address internal governor = makeAddr("governor");
    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");
    address internal attacker = makeAddr("attacker");

    address internal signer;
    uint256 internal signerKey;

    uint256 internal constant CUSTODY_ID = 1; // partial unwrap allowed
    uint256 internal constant CUSTODY_FULL_ID = 2; // full-only
    uint256 internal constant DOC_ID = 3; // document proof

    function setUp() public {
        ac = new HyperAccessControl(governor);
        psm = new ReservePSM(address(ac));
        underlying = new MockToken();
        (signer, signerKey) = makeAddrAndKey("signer");

        vm.startPrank(governor);
        psm.deployWrappedToken(
            CUSTODY_ID, IReservePSM.AssetMode.TOKEN_CUSTODY, address(underlying), "wCustody", "wC", 6, true
        );
        psm.deployWrappedToken(
            CUSTODY_FULL_ID, IReservePSM.AssetMode.TOKEN_CUSTODY, address(underlying), "wFull", "wF", 6, false
        );
        psm.deployWrappedToken(DOC_ID, IReservePSM.AssetMode.DOCUMENT_PROOF, address(0), "wDoc", "wD", 6, false);
        psm.setAuthorizedSigner(DOC_ID, signer);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _wrapped(uint256 assetId) internal view returns (WrappedAsset) {
        return WrappedAsset(psm.wrappedTokenOf(assetId));
    }

    function _sign(uint256 assetId, uint256 amount, address to, uint256 nonce, uint256 expiry, bytes32 documentId)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest =
            keccak256(abi.encode(assetId, amount, to, nonce, expiry, documentId, address(psm), block.chainid));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(digest);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _wrapForUser(uint256 assetId, uint256 amount) internal {
        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(address(psm), amount);
        psm.wrap(assetId, amount, user);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroAccessControl() public {
        vm.expectRevert(IReservePSM.ZeroAddress.selector);
        new ReservePSM(address(0));
    }

    // -----------------------------------------------------------------------
    // deployWrappedToken
    // -----------------------------------------------------------------------

    function test_deployWrappedToken_custodyConfigured() public view {
        (IReservePSM.AssetMode mode, address ut, address wt, bool allowPartial, address authSigner, bool paused) =
            psm.assetConfig(CUSTODY_ID);
        assertEq(uint256(mode), uint256(IReservePSM.AssetMode.TOKEN_CUSTODY));
        assertEq(ut, address(underlying));
        assertTrue(wt != address(0));
        assertTrue(allowPartial);
        assertEq(authSigner, address(0));
        assertFalse(paused);
        assertEq(WrappedAsset(wt).decimals(), 6);
    }

    function test_deployWrappedToken_documentProofForcesNoPartial() public {
        vm.prank(governor);
        psm.deployWrappedToken(99, IReservePSM.AssetMode.DOCUMENT_PROOF, address(0), "x", "x", 6, true);
        (,,, bool allowPartial,,) = psm.assetConfig(99);
        assertFalse(allowPartial);
    }

    /// @dev Was permissionless, which let anyone front-run an expected assetId, deploy its
    ///      wrapped token first and install themselves as its controller (Audit Feedback V2 #8).
    function test_deployWrappedToken_revertsForNonGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(IReservePSM.NotGovernor.selector);
        psm.deployWrappedToken(99, IReservePSM.AssetMode.TOKEN_CUSTODY, address(underlying), "x", "x", 6, true);
    }

    function test_deployWrappedToken_governorBecomesController() public {
        vm.prank(governor);
        psm.deployWrappedToken(99, IReservePSM.AssetMode.TOKEN_CUSTODY, address(underlying), "x", "x", 6, true);
        assertEq(psm.controllerOf(99), governor);
    }

    function test_deployWrappedToken_revertsIfAlreadyConfigured() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.AssetAlreadyConfigured.selector, CUSTODY_ID));
        psm.deployWrappedToken(CUSTODY_ID, IReservePSM.AssetMode.TOKEN_CUSTODY, address(underlying), "x", "x", 6, true);
    }

    function test_deployWrappedToken_revertsCustodyZeroUnderlying() public {
        vm.prank(governor);
        vm.expectRevert(IReservePSM.ZeroAddress.selector);
        psm.deployWrappedToken(99, IReservePSM.AssetMode.TOKEN_CUSTODY, address(0), "x", "x", 6, true);
    }

    function test_deployWrappedToken_revertsDocProofWithUnderlying() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.WrongAssetMode.selector, 99));
        psm.deployWrappedToken(99, IReservePSM.AssetMode.DOCUMENT_PROOF, address(underlying), "x", "x", 6, false);
    }

    // -----------------------------------------------------------------------
    // setAuthorizedSigner
    // -----------------------------------------------------------------------

    function test_setAuthorizedSigner_succeeds() public {
        (,,,, address authSigner,) = psm.assetConfig(DOC_ID);
        assertEq(authSigner, signer);
    }

    function test_setAuthorizedSigner_revertsForNonController() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.NotWrapperController.selector, DOC_ID));
        psm.setAuthorizedSigner(DOC_ID, signer);
    }

    function test_setAuthorizedSigner_revertsZeroSigner() public {
        vm.prank(governor);
        vm.expectRevert(IReservePSM.ZeroAddress.selector);
        psm.setAuthorizedSigner(DOC_ID, address(0));
    }

    function test_setAuthorizedSigner_revertsWrongMode() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.WrongAssetMode.selector, CUSTODY_ID));
        psm.setAuthorizedSigner(CUSTODY_ID, signer);
    }

    function test_setAuthorizedSigner_revertsNotConfigured() public {
        // controllerOf[99] defaults to address(0) since it was never deployed, so the
        // Wrapper-Controller gate (asset-local now, not global Governor) fires before the
        // configuration check for any non-zero caller.
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.NotWrapperController.selector, 99));
        psm.setAuthorizedSigner(99, signer);
    }

    // -----------------------------------------------------------------------
    // wrap
    // -----------------------------------------------------------------------

    function test_wrap_mintsWrappedAndPullsUnderlying() public {
        underlying.mint(user, 1_000e6);
        vm.startPrank(user);
        underlying.approve(address(psm), 1_000e6);
        vm.expectEmit(true, true, false, true, address(psm));
        emit IReservePSM.Wrapped(CUSTODY_ID, user, 1_000e6, recipient, block.timestamp);
        psm.wrap(CUSTODY_ID, 1_000e6, recipient);
        vm.stopPrank();

        assertEq(_wrapped(CUSTODY_ID).balanceOf(recipient), 1_000e6);
        assertEq(underlying.balanceOf(address(psm)), 1_000e6);
        assertEq(underlying.balanceOf(user), 0);
    }

    function test_wrap_feeOnTransferUnderlying_mintsOnlyReceivedAmount() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        uint256 feeAssetId = 100;
        vm.prank(governor);
        psm.deployWrappedToken(
            feeAssetId, IReservePSM.AssetMode.TOKEN_CUSTODY, address(feeToken), "wFee", "wF2", 6, true
        );

        feeToken.mint(user, 1_000e6);
        vm.startPrank(user);
        feeToken.approve(address(psm), 1_000e6);
        uint256 expectedReceived = 1_000e6 - (1_000e6 * FeeOnTransferToken(feeToken).FEE_BPS() / 10_000);

        vm.expectEmit(true, true, false, true, address(psm));
        emit IReservePSM.Wrapped(feeAssetId, user, expectedReceived, recipient, block.timestamp);
        psm.wrap(feeAssetId, 1_000e6, recipient);
        vm.stopPrank();

        // Wrapped supply and PSM's custodied balance match what was actually received, not the
        // pre-fee `amount` argument — otherwise unwrap() would be able to drain more than the
        // PSM actually holds.
        assertEq(_wrapped(feeAssetId).balanceOf(recipient), expectedReceived);
        assertEq(feeToken.balanceOf(address(psm)), expectedReceived);
    }

    function test_wrap_revertsWrongMode() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.WrongAssetMode.selector, DOC_ID));
        psm.wrap(DOC_ID, 1e6, user);
    }

    function test_wrap_revertsZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(IReservePSM.ZeroAmount.selector);
        psm.wrap(CUSTODY_ID, 0, user);
    }

    function test_wrap_revertsZeroTo() public {
        vm.prank(user);
        vm.expectRevert(IReservePSM.ZeroAddress.selector);
        psm.wrap(CUSTODY_ID, 1e6, address(0));
    }

    function test_wrap_revertsNotConfigured() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.AssetNotConfigured.selector, 99));
        psm.wrap(99, 1e6, user);
    }

    function test_wrap_revertsGloballyPaused() public {
        vm.prank(governor);
        psm.pause();
        underlying.mint(user, 1e6);
        vm.startPrank(user);
        underlying.approve(address(psm), 1e6);
        vm.expectRevert(IReservePSM.GloballyPaused.selector);
        psm.wrap(CUSTODY_ID, 1e6, user);
        vm.stopPrank();
    }

    function test_wrap_revertsAssetPaused() public {
        vm.prank(governor);
        psm.pauseAsset(CUSTODY_ID);
        underlying.mint(user, 1e6);
        vm.startPrank(user);
        underlying.approve(address(psm), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.AssetIsPaused.selector, CUSTODY_ID));
        psm.wrap(CUSTODY_ID, 1e6, user);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // mintWithAuthorization
    // -----------------------------------------------------------------------

    function test_mintWithAuthorization_succeedsAndStoresDocumentId() public {
        bytes32 docId = keccak256("doc-1");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, recipient, 1, expiry, docId);

        vm.expectEmit(true, true, false, true, address(psm));
        emit IReservePSM.MintedWithAuthorization(DOC_ID, recipient, 500e6, 1, docId, block.timestamp);
        vm.prank(user);
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, sig, docId);

        assertEq(_wrapped(DOC_ID).balanceOf(recipient), 500e6);
        assertEq(psm.documentIdOf(DOC_ID, recipient), docId);
        assertTrue(psm.usedNonce(DOC_ID, 1));
    }

    function test_mintWithAuthorization_revertsIfDocumentIdDoesNotMatchSignature() public {
        // Signed for docId1, but submitted claiming docId2 — the digest must bind documentId, so
        // this must not be accepted as a valid authorization for docId2.
        bytes32 docId1 = keccak256("doc-1");
        bytes32 docId2 = keccak256("doc-2");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, recipient, 1, expiry, docId1);

        vm.prank(user);
        // The digest binds documentId, so the recovered signer no longer matches the authorised
        // one — assert that exact error rather than "reverts somehow".
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.InvalidSigner.selector, signer));
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, sig, docId2);
    }

    function test_mintWithAuthorization_revertsWrongMode() public {
        bytes memory sig = _sign(CUSTODY_ID, 1e6, user, 1, block.timestamp + 1 hours, bytes32(0));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.WrongAssetMode.selector, CUSTODY_ID));
        psm.mintWithAuthorization(CUSTODY_ID, 1e6, user, 1, block.timestamp + 1 hours, sig, bytes32(0));
    }

    function test_mintWithAuthorization_revertsInvalidSigner() public {
        // Sign with a non-authorized key.
        (, uint256 badKey) = makeAddrAndKey("bad");
        bytes32 digest = keccak256(
            abi.encode(
                DOC_ID,
                uint256(1e6),
                user,
                uint256(1),
                block.timestamp + 1 hours,
                bytes32(0),
                address(psm),
                block.chainid
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badKey, MessageHashUtils.toEthSignedMessageHash(digest));
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        // The error carries the *expected* authorised signer (SignatureChecker yields no recovered address).
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.InvalidSigner.selector, signer));
        psm.mintWithAuthorization(DOC_ID, 1e6, user, 1, block.timestamp + 1 hours, sig, bytes32(0));
    }

    function test_mintWithAuthorization_revertsTamperedAmount() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, recipient, 1, expiry, bytes32(0));
        // Submit with a different amount than signed → recovered signer won't match.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.InvalidSigner.selector, signer));
        psm.mintWithAuthorization(DOC_ID, 999e6, recipient, 1, expiry, sig, bytes32(0));
    }

    function test_mintWithAuthorization_revertsExpired() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, recipient, 1, expiry, bytes32(0));
        vm.warp(expiry + 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.SignatureExpired.selector, expiry));
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, sig, bytes32(0));
    }

    function test_mintWithAuthorization_revertsReplayedNonce() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, recipient, 1, expiry, bytes32(0));
        vm.prank(user);
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, sig, bytes32(0));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.NonceAlreadyUsed.selector, DOC_ID, 1));
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, sig, bytes32(0));
    }

    function test_mintWithAuthorization_revertsZeroAmount() public {
        bytes memory sig = _sign(DOC_ID, 0, recipient, 1, block.timestamp + 1 hours, bytes32(0));
        vm.prank(user);
        vm.expectRevert(IReservePSM.ZeroAmount.selector);
        psm.mintWithAuthorization(DOC_ID, 0, recipient, 1, block.timestamp + 1 hours, sig, bytes32(0));
    }

    function test_mintWithAuthorization_revertsWhenPaused() public {
        vm.prank(governor);
        psm.pauseAsset(DOC_ID);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, recipient, 1, expiry, bytes32(0));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.AssetIsPaused.selector, DOC_ID));
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, sig, bytes32(0));
    }

    // -----------------------------------------------------------------------
    // unwrap — TOKEN_CUSTODY
    // -----------------------------------------------------------------------

    function test_unwrap_custody_partialAllowed() public {
        _wrapForUser(CUSTODY_ID, 1_000e6);

        vm.expectEmit(true, true, false, true, address(psm));
        emit IReservePSM.Unwrapped(CUSTODY_ID, user, 400e6, recipient, block.timestamp);
        vm.prank(user);
        psm.unwrap(CUSTODY_ID, 400e6, recipient);

        assertEq(_wrapped(CUSTODY_ID).balanceOf(user), 600e6);
        assertEq(underlying.balanceOf(recipient), 400e6);
        assertEq(underlying.balanceOf(address(psm)), 600e6);
    }

    function test_unwrap_custody_fullSucceeds() public {
        _wrapForUser(CUSTODY_ID, 1_000e6);
        vm.prank(user);
        psm.unwrap(CUSTODY_ID, 1_000e6, recipient);
        assertEq(_wrapped(CUSTODY_ID).balanceOf(user), 0);
        assertEq(underlying.balanceOf(recipient), 1_000e6);
    }

    function test_unwrap_custody_fullOnlyRejectsPartial() public {
        _wrapForUser(CUSTODY_FULL_ID, 1_000e6);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.PartialUnwrapNotAllowed.selector, CUSTODY_FULL_ID));
        psm.unwrap(CUSTODY_FULL_ID, 400e6, recipient);
    }

    function test_unwrap_custody_fullOnlyAcceptsFull() public {
        _wrapForUser(CUSTODY_FULL_ID, 1_000e6);
        vm.prank(user);
        psm.unwrap(CUSTODY_FULL_ID, 1_000e6, recipient);
        assertEq(_wrapped(CUSTODY_FULL_ID).balanceOf(user), 0);
        assertEq(underlying.balanceOf(recipient), 1_000e6);
    }

    function test_unwrap_custody_revertsWhenPaused() public {
        _wrapForUser(CUSTODY_ID, 1_000e6);
        vm.prank(governor);
        psm.pause();
        vm.prank(user);
        vm.expectRevert(IReservePSM.GloballyPaused.selector);
        psm.unwrap(CUSTODY_ID, 100e6, recipient);
    }

    // -----------------------------------------------------------------------
    // unwrap — DOCUMENT_PROOF
    // -----------------------------------------------------------------------

    function test_unwrap_docProof_fullEmitsReleaseWithStoredDocumentId() public {
        bytes32 docId = keccak256("doc-xyz");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, user, 1, expiry, docId);
        vm.prank(user);
        psm.mintWithAuthorization(DOC_ID, 500e6, user, 1, expiry, sig, docId);

        vm.expectEmit(true, true, false, true, address(psm));
        emit IReservePSM.ReleaseRequested(DOC_ID, user, 500e6, recipient, docId, block.timestamp);
        vm.prank(user);
        psm.unwrap(DOC_ID, 500e6, recipient);

        assertEq(_wrapped(DOC_ID).balanceOf(user), 0);
        // No on-chain underlying release for document proof.
        assertEq(underlying.balanceOf(recipient), 0);
    }

    function test_unwrap_docProof_accumulatesDocumentIdsAcrossMints() public {
        bytes32 docId1 = keccak256("doc-1");
        bytes32 docId2 = keccak256("doc-2");
        uint256 expiry = block.timestamp + 1 hours;

        vm.prank(user);
        psm.mintWithAuthorization(DOC_ID, 300e6, user, 1, expiry, _sign(DOC_ID, 300e6, user, 1, expiry, docId1), docId1);
        vm.prank(user);
        psm.mintWithAuthorization(DOC_ID, 200e6, user, 2, expiry, _sign(DOC_ID, 200e6, user, 2, expiry, docId2), docId2);

        // A second mint no longer clobbers the first document's reference.
        bytes32[] memory pending = psm.pendingDocumentIds(DOC_ID, user);
        assertEq(pending.length, 2);
        assertEq(pending[0], docId1);
        assertEq(pending[1], docId2);
        // documentIdOf still exposes the latest mint for simple single-mint callers.
        assertEq(psm.documentIdOf(DOC_ID, user), docId2);

        vm.expectEmit(true, true, false, true, address(psm));
        emit IReservePSM.ReleaseRequested(DOC_ID, user, 500e6, recipient, docId1, block.timestamp);
        vm.expectEmit(true, true, false, true, address(psm));
        emit IReservePSM.ReleaseRequested(DOC_ID, user, 500e6, recipient, docId2, block.timestamp);
        vm.prank(user);
        psm.unwrap(DOC_ID, 500e6, recipient);

        // Cleared after the full-balance unwrap that released them.
        assertEq(psm.pendingDocumentIds(DOC_ID, user).length, 0);
        assertEq(psm.documentIdOf(DOC_ID, user), bytes32(0));
    }

    function test_unwrap_docProof_rejectsPartial() public {
        bytes32 docId = keccak256("doc-xyz");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, user, 1, expiry, docId);
        vm.prank(user);
        psm.mintWithAuthorization(DOC_ID, 500e6, user, 1, expiry, sig, docId);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.IncompleteUnwrap.selector, DOC_ID, 200e6, 500e6));
        psm.unwrap(DOC_ID, 200e6, recipient);
    }

    // -----------------------------------------------------------------------
    // pause / unpause
    // -----------------------------------------------------------------------

    function test_pause_unpause_global() public {
        vm.prank(governor);
        psm.pause();
        assertTrue(psm.globalPaused());
        vm.prank(governor);
        psm.unpause();
        assertFalse(psm.globalPaused());
    }

    function test_pause_revertsForNonGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(IReservePSM.NotGovernor.selector);
        psm.pause();
    }

    function test_pauseAsset_unpauseAsset() public {
        vm.prank(governor);
        psm.pauseAsset(CUSTODY_ID);
        (,,,,, bool paused) = psm.assetConfig(CUSTODY_ID);
        assertTrue(paused);

        vm.prank(governor);
        psm.unpauseAsset(CUSTODY_ID);
        (,,,,, bool paused2) = psm.assetConfig(CUSTODY_ID);
        assertFalse(paused2);
    }

    function test_pauseAsset_revertsForNonController() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.NotWrapperController.selector, CUSTODY_ID));
        psm.pauseAsset(CUSTODY_ID);
    }

    function test_pauseAsset_revertsNotConfigured() public {
        // Same reasoning as test_setAuthorizedSigner_revertsNotConfigured: the asset-local
        // Wrapper-Controller gate fires before the configuration check.
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.NotWrapperController.selector, 99));
        psm.pauseAsset(99);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function test_wrappedTokenOf_returnsDeployedToken() public view {
        assertEq(psm.wrappedTokenOf(CUSTODY_ID), address(_wrapped(CUSTODY_ID)));
        assertEq(psm.wrappedTokenOf(99), address(0));
    }

    function test_assetModeOf_returnsMode() public view {
        assertEq(uint256(psm.assetModeOf(CUSTODY_ID)), uint256(IReservePSM.AssetMode.TOKEN_CUSTODY));
        assertEq(uint256(psm.assetModeOf(DOC_ID)), uint256(IReservePSM.AssetMode.DOCUMENT_PROOF));
    }

    function test_assetModeOf_revertsNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.AssetNotConfigured.selector, 99));
        psm.assetModeOf(99);
    }

    // -----------------------------------------------------------------------
    // mintWithAuthorization: EIP-1271 contract-wallet signers
    // -----------------------------------------------------------------------

    /// @dev Signs the same payload as `_sign` but with an arbitrary key.
    function _signWith(uint256 key, uint256 assetId, uint256 amount, address to, uint256 nonce, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest =
            keccak256(abi.encode(assetId, amount, to, nonce, expiry, bytes32(0), address(psm), block.chainid));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v);
    }

    function test_mintWithAuthorization_erc1271WalletSignerSucceeds() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(signer);
        vm.prank(governor);
        psm.setAuthorizedSigner(DOC_ID, address(wallet));

        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, recipient, 1, expiry, bytes32(0));

        vm.prank(user);
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, sig, bytes32(0));

        assertEq(_wrapped(DOC_ID).balanceOf(recipient), 500e6);
        assertTrue(psm.usedNonce(DOC_ID, 1));
    }

    /// @dev The wallet only accepts its own owner's signature; a foreign key must be rejected.
    function test_mintWithAuthorization_erc1271WalletRejectsForeignKey() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(signer);
        vm.prank(governor);
        psm.setAuthorizedSigner(DOC_ID, address(wallet));

        (, uint256 badKey) = makeAddrAndKey("bad");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signWith(badKey, DOC_ID, 500e6, recipient, 1, expiry);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.InvalidSigner.selector, address(wallet)));
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, sig, bytes32(0));
    }

    /// @dev A contract signer returning a non-magic value must never be accepted.
    function test_mintWithAuthorization_erc1271BadMagicValueReverts() public {
        BadMagicERC1271Wallet wallet = new BadMagicERC1271Wallet();
        vm.prank(governor);
        psm.setAuthorizedSigner(DOC_ID, address(wallet));

        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _sign(DOC_ID, 500e6, recipient, 1, expiry, bytes32(0));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.InvalidSigner.selector, address(wallet)));
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, sig, bytes32(0));
    }

    /// @dev An EOA signer must still be rejected when the signature bytes are unrecoverable garbage.
    function test_mintWithAuthorization_malformedSignatureReverts() public {
        uint256 expiry = block.timestamp + 1 hours;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IReservePSM.InvalidSigner.selector, signer));
        psm.mintWithAuthorization(DOC_ID, 500e6, recipient, 1, expiry, hex"1234", bytes32(0));
    }
}
