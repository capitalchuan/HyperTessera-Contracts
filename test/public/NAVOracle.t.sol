// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {NAVOracle} from "../../src/asset-infrastructure/NAVOracle.sol";
import {INAVOracle} from "../../src/interfaces/INAVOracle.sol";
import {MockERC1271Wallet, BadMagicERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";

/// @title NAVOracle Tests
/// @notice Standalone, token-keyed oracle: single Owner manages per-rwaToken signers; updateNAV
///         is permissionless-relay, EIP-712-signed, validated for non-zero/future/monotonic/
///         upward-deviation-cap. No staleness/freshness surface, no Vault/StateManager coupling.
contract NAVOracleTest is Test {
    NAVOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal relayer = makeAddr("relayer"); // permissionless relay caller
    address internal alice = makeAddr("alice"); // unprivileged
    address internal rwaToken = makeAddr("rwaToken");
    address internal rwaTokenB = makeAddr("rwaTokenB");

    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    uint256 internal badPk = 0xBAD;
    address internal badSigner;

    uint256 internal constant ONE = 1e18; // price unity (1.0 asset per 1.0 rwaToken)

    bytes32 internal constant NAV_UPDATE_TYPEHASH =
        keccak256("NAVUpdate(address rwaToken,uint256 price,uint256 dataTimestamp)");

    function setUp() public {
        signer = vm.addr(signerPk);
        badSigner = vm.addr(badPk);

        oracle = new NAVOracle(owner, 2000);

        vm.prank(owner);
        oracle.setSigner(rwaToken, signer);

        vm.warp(400 days); // Ensure sufficient timestamp headroom for test_updateNAV_oldButMonotonicTimestampSucceeds
    }

    // -----------------------------------------------------------------------
    // Signing helpers — real EIP-712 domain matching NAVOracle's own.
    // -----------------------------------------------------------------------

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NAVOracle")),
                keccak256(bytes("1")),
                block.chainid,
                address(oracle)
            )
        );
    }

    function _sign(uint256 pk, address token, uint256 price, uint256 dataTimestamp)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(NAV_UPDATE_TYPEHASH, token, price, dataTimestamp));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _push(uint256 pk, uint256 price, uint256 dataTimestamp) internal {
        bytes memory sig = _sign(pk, rwaToken, price, dataTimestamp);
        vm.prank(relayer);
        oracle.updateNAV(rwaToken, price, dataTimestamp, sig);
    }

    function _maxUp(uint256 base) internal view returns (uint256) {
        return base * (10_000 + oracle.navDeviationMaxBps()) / 10_000;
    }

    // -----------------------------------------------------------------------
    // navDeviationMaxBps — configurable deviation cap
    // -----------------------------------------------------------------------

    function test_navDeviationMaxBps_defaultsToConstructorValue() public view {
        assertEq(oracle.navDeviationMaxBps(), 2000); // matches setUp's `new NAVOracle(owner, 2000)`
    }

    function test_setNAVDeviationMaxBps_updatesValue() public {
        vm.prank(owner);
        oracle.setNAVDeviationMaxBps(5000);
        assertEq(oracle.navDeviationMaxBps(), 5000);
    }

    function test_setNAVDeviationMaxBps_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(INAVOracle.Unauthorized.selector);
        oracle.setNAVDeviationMaxBps(5000);
    }

    function test_setNAVDeviationMaxBps_revertsForZero() public {
        vm.prank(owner);
        vm.expectRevert(INAVOracle.ZeroDeviationBps.selector);
        oracle.setNAVDeviationMaxBps(0);
    }

    function test_setNAVDeviationMaxBps_allowsAboveOldTwentyPercentCeiling() public {
        // The old hardcoded 2000 bps (20%) ceiling is gone — any nonzero value is accepted.
        vm.prank(owner);
        oracle.setNAVDeviationMaxBps(50_000); // 500% — no longer capped
        assertEq(oracle.navDeviationMaxBps(), 50_000);
    }

    function test_setNAVDeviationMaxBps_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(oracle));
        emit INAVOracle.NAVDeviationMaxBpsUpdated(5000);
        vm.prank(owner);
        oracle.setNAVDeviationMaxBps(5000);
    }

    function test_updateNAV_usesUpdatedDeviationCap() public {
        vm.prank(owner);
        oracle.setNAVDeviationMaxBps(100); // 1% — tighter than the old 20% default

        _push(signerPk, ONE, 1);
        uint256 allowed = _maxUp(ONE); // now ONE * 10_100 / 10_000
        _push(signerPk, allowed, 2); // succeeds at the new, tighter cap

        // data.price is now `allowed` — the next cap is relative to that, not to ONE.
        uint256 tooHigh = _maxUp(allowed) + 1;
        bytes memory sig = _sign(signerPk, rwaToken, tooHigh, 3);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(INAVOracle.DeviationTooHigh.selector, tooHigh, allowed));
        oracle.updateNAV(rwaToken, tooHigh, 3, sig);
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_setsOwner() public view {
        assertEq(oracle.owner(), owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(INAVOracle.ZeroAddress.selector);
        new NAVOracle(address(0), 2000);
    }

    // -----------------------------------------------------------------------
    // Signer administration (single Oracle owner, per-token)
    // -----------------------------------------------------------------------

    function test_setSigner_ownerSucceeds() public {
        address newSigner = makeAddr("newSigner");
        vm.prank(owner);
        oracle.setSigner(rwaTokenB, newSigner);
        assertEq(oracle.signerOf(rwaTokenB), newSigner);
    }

    function test_setSigner_nonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(INAVOracle.Unauthorized.selector);
        oracle.setSigner(rwaToken, makeAddr("x"));
    }

    function test_setSigner_zeroSignerReverts() public {
        vm.prank(owner);
        vm.expectRevert(INAVOracle.ZeroAddress.selector);
        oracle.setSigner(rwaToken, address(0));
    }

    function test_setSigner_zeroTokenReverts() public {
        vm.prank(owner);
        vm.expectRevert(INAVOracle.ZeroAddress.selector);
        oracle.setSigner(address(0), signer);
    }

    function test_removeSigner_ownerSucceeds() public {
        vm.prank(owner);
        oracle.removeSigner(rwaToken);
        assertEq(oracle.signerOf(rwaToken), address(0));
    }

    function test_removeSigner_nonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(INAVOracle.Unauthorized.selector);
        oracle.removeSigner(rwaToken);
    }

    function test_removeSigner_thenUpdateReverts() public {
        vm.prank(owner);
        oracle.removeSigner(rwaToken);

        uint256 ts = block.timestamp;
        bytes memory sig = _sign(signerPk, rwaToken, ONE, ts);
        vm.prank(relayer);
        vm.expectPartialRevert(INAVOracle.UnauthorizedSigner.selector);
        oracle.updateNAV(rwaToken, ONE, ts, sig);
    }

    function test_signerIsPerToken() public {
        // `signer` is authorised for `rwaToken`, not for `rwaTokenB`.
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(signerPk, rwaTokenB, ONE, ts);
        vm.prank(relayer);
        vm.expectPartialRevert(INAVOracle.UnauthorizedSigner.selector);
        oracle.updateNAV(rwaTokenB, ONE, ts, sig);
    }

    // -----------------------------------------------------------------------
    // transferOwnership
    // -----------------------------------------------------------------------

    function test_transferOwnership_ownerSucceeds() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        oracle.transferOwnership(newOwner);
        assertEq(oracle.owner(), newOwner);
    }

    function test_transferOwnership_nonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(INAVOracle.Unauthorized.selector);
        oracle.transferOwnership(alice);
    }

    function test_transferOwnership_zeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(INAVOracle.ZeroAddress.selector);
        oracle.transferOwnership(address(0));
    }

    // -----------------------------------------------------------------------
    // updateNAV: happy path
    // -----------------------------------------------------------------------

    function test_updateNAV_authorizedPushUpdatesPrice() public {
        uint256 price = ONE;
        uint256 ts = block.timestamp;

        bytes memory sig = _sign(signerPk, rwaToken, price, ts);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit INAVOracle.NAVUpdated(rwaToken, price, ts, block.timestamp, signer);
        vm.prank(relayer);
        oracle.updateNAV(rwaToken, price, ts, sig);

        (uint256 gotPrice, uint256 gotUpdatedAt) = oracle.getNAV(rwaToken);
        assertEq(gotPrice, price);
        assertEq(gotUpdatedAt, block.timestamp);
    }

    function test_getPriceData_returnsFullRecord() public {
        uint256 ts = block.timestamp;
        _push(signerPk, ONE, ts);

        INAVOracle.PriceData memory d = oracle.getPriceData(rwaToken);
        assertEq(d.price, ONE);
        assertEq(d.dataTimestamp, ts);
        assertEq(d.updatedAt, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // updateNAV: signer / payload / replay
    // -----------------------------------------------------------------------

    function test_updateNAV_unauthorizedSignerReverts() public {
        uint256 price = ONE;
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(badPk, rwaToken, price, ts);

        vm.prank(relayer);
        vm.expectPartialRevert(INAVOracle.UnauthorizedSigner.selector);
        oracle.updateNAV(rwaToken, price, ts, sig);
    }

    function test_updateNAV_tamperedPayloadReverts() public {
        uint256 price = ONE;
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(signerPk, rwaToken, price, ts);

        vm.prank(relayer);
        vm.expectPartialRevert(INAVOracle.UnauthorizedSigner.selector);
        oracle.updateNAV(rwaToken, price + 1, ts, sig);
    }

    /// @dev A signature valid on a different NAVOracle instance (different verifyingContract) must
    ///      not be replayable here — proves the EIP-712 domain binds to `address(oracle)`.
    function test_updateNAV_signatureFromDifferentOracleReverts() public {
        NAVOracle otherOracle = new NAVOracle(owner, 2000);
        vm.prank(owner);
        otherOracle.setSigner(rwaToken, signer);

        uint256 ts = block.timestamp;
        bytes32 structHash = keccak256(abi.encode(NAV_UPDATE_TYPEHASH, rwaToken, ONE, ts));
        bytes32 otherDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NAVOracle")),
                keccak256(bytes("1")),
                block.chainid,
                address(otherOracle)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", otherDomain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        vm.expectPartialRevert(INAVOracle.UnauthorizedSigner.selector);
        oracle.updateNAV(rwaToken, ONE, ts, sig);
    }

    // -----------------------------------------------------------------------
    // updateNAV: deviation cap (upward only)
    // -----------------------------------------------------------------------

    function test_updateNAV_upwardDeviationBeyondCapReverts() public {
        _push(signerPk, ONE, block.timestamp);

        uint256 maxPrice = _maxUp(ONE);
        vm.warp(block.timestamp + 1);
        uint256 ts2 = block.timestamp; // monotonic, not in the future
        bytes memory sig = _sign(signerPk, rwaToken, maxPrice + 1, ts2);

        vm.prank(relayer);
        vm.expectPartialRevert(INAVOracle.DeviationTooHigh.selector);
        oracle.updateNAV(rwaToken, maxPrice + 1, ts2, sig);
    }

    function test_updateNAV_upwardAtCapSucceeds() public {
        _push(signerPk, ONE, block.timestamp);
        vm.warp(block.timestamp + 1);
        uint256 maxPrice = _maxUp(ONE);
        _push(signerPk, maxPrice, block.timestamp);
        (uint256 gotPrice,) = oracle.getNAV(rwaToken);
        assertEq(gotPrice, maxPrice);
    }

    function test_updateNAV_downwardCorrectionSucceeds() public {
        _push(signerPk, 1.01e18, block.timestamp);
        vm.warp(block.timestamp + 1);
        _push(signerPk, 1.0001e18, block.timestamp);
        (uint256 gotPrice,) = oracle.getNAV(rwaToken);
        assertEq(gotPrice, 1.0001e18);
    }

    function test_updateNAV_largeDownwardDefaultLossSucceeds() public {
        _push(signerPk, 2e18, block.timestamp);
        vm.warp(block.timestamp + 1);
        _push(signerPk, 1, block.timestamp);
        (uint256 gotPrice,) = oracle.getNAV(rwaToken);
        assertEq(gotPrice, 1, "any-magnitude downward accepted");
    }

    function test_updateNAV_firstWriteSkipsDeviationCheck() public {
        // No previous price recorded yet — any magnitude is accepted on the first write.
        _push(signerPk, 1_000_000e18, block.timestamp);
        (uint256 gotPrice,) = oracle.getNAV(rwaToken);
        assertEq(gotPrice, 1_000_000e18);
    }

    // -----------------------------------------------------------------------
    // updateNAV: sanity / timestamp
    // -----------------------------------------------------------------------

    function test_updateNAV_zeroPriceReverts() public {
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(signerPk, rwaToken, 0, ts);
        vm.prank(relayer);
        vm.expectRevert(INAVOracle.InvalidNAV.selector);
        oracle.updateNAV(rwaToken, 0, ts, sig);
    }

    function test_updateNAV_futureTimestampReverts() public {
        uint256 ts = block.timestamp + 1;
        bytes memory sig = _sign(signerPk, rwaToken, ONE, ts);
        vm.prank(relayer);
        vm.expectPartialRevert(INAVOracle.FutureData.selector);
        oracle.updateNAV(rwaToken, ONE, ts, sig);
    }

    function test_updateNAV_nonMonotonicTimestampReverts() public {
        uint256 ts = block.timestamp;
        _push(signerPk, ONE, ts);
        bytes memory sig = _sign(signerPk, rwaToken, ONE, ts);
        vm.prank(relayer);
        vm.expectPartialRevert(INAVOracle.NonMonotonicTimestamp.selector);
        oracle.updateNAV(rwaToken, ONE, ts, sig);
    }

    function test_updateNAV_oldButMonotonicTimestampSucceeds() public {
        // No on-chain staleness check — an old-but-monotonic, non-future timestamp is accepted.
        uint256 ts = block.timestamp - 365 days;
        _push(signerPk, ONE, ts);
        (uint256 gotPrice,) = oracle.getNAV(rwaToken);
        assertEq(gotPrice, ONE);
    }

    function test_updateNAV_zeroTokenReverts() public {
        uint256 ts = block.timestamp;
        bytes memory sig = _sign(signerPk, address(0), ONE, ts);
        vm.prank(relayer);
        vm.expectRevert(INAVOracle.ZeroAddress.selector);
        oracle.updateNAV(address(0), ONE, ts, sig);
    }

    // -----------------------------------------------------------------------
    // updateNAV: EIP-1271 contract-wallet signers
    // -----------------------------------------------------------------------

    function test_updateNAV_erc1271WalletSignerSucceeds() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(signer);
        vm.prank(owner);
        oracle.setSigner(rwaTokenB, address(wallet));

        uint256 ts = block.timestamp;
        bytes memory sig = _sign(signerPk, rwaTokenB, ONE, ts);

        // The event reports the registered signer — for a contract wallet that is the wallet itself.
        vm.expectEmit(true, true, false, true, address(oracle));
        emit INAVOracle.NAVUpdated(rwaTokenB, ONE, ts, block.timestamp, address(wallet));
        vm.prank(relayer);
        oracle.updateNAV(rwaTokenB, ONE, ts, sig);

        (uint256 gotPrice,) = oracle.getNAV(rwaTokenB);
        assertEq(gotPrice, ONE);
    }

    /// @dev The wallet only accepts its own owner's signature; a foreign key must be rejected.
    function test_updateNAV_erc1271WalletRejectsForeignKey() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(signer);
        vm.prank(owner);
        oracle.setSigner(rwaTokenB, address(wallet));

        uint256 ts = block.timestamp;
        bytes memory sig = _sign(badPk, rwaTokenB, ONE, ts);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(INAVOracle.UnauthorizedSigner.selector, address(wallet)));
        oracle.updateNAV(rwaTokenB, ONE, ts, sig);
    }

    /// @dev A contract signer returning a non-magic value must never be accepted.
    function test_updateNAV_erc1271BadMagicValueReverts() public {
        BadMagicERC1271Wallet wallet = new BadMagicERC1271Wallet();
        vm.prank(owner);
        oracle.setSigner(rwaTokenB, address(wallet));

        uint256 ts = block.timestamp;
        bytes memory sig = _sign(signerPk, rwaTokenB, ONE, ts);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(INAVOracle.UnauthorizedSigner.selector, address(wallet)));
        oracle.updateNAV(rwaTokenB, ONE, ts, sig);
    }

    /// @dev An EOA signer must still be rejected when the signature bytes are unrecoverable garbage
    ///      (SignatureChecker's ECDSA path must not silently pass).
    function test_updateNAV_malformedSignatureReverts() public {
        uint256 ts = block.timestamp;
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(INAVOracle.UnauthorizedSigner.selector, signer));
        oracle.updateNAV(rwaToken, ONE, ts, hex"1234");
    }
}
