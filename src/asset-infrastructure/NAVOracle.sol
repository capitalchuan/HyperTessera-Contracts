// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {INAVOracle} from "../interfaces/INAVOracle.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title NAVOracle
/// @notice Standalone, token-keyed price oracle. Anyone may relay an `updateNAV` write as long as
///         it carries the registered signer's EIP-712 signature for that `rwaToken`. No Vault,
///         StateManager, or AssetRegistry dependency — RWAAdapter reads this by `rwaToken` address
///         only (NAVOracle/RWAAdapter redesign spec).
/// @dev    Downward price moves of any magnitude are accepted; only upward moves are capped at
///         `navDeviationMaxBps`. No on-chain staleness check — freshness is an off-chain concern.
/// @dev    Signatures are checked with `SignatureChecker`, so a registered signer may be either an
///         EOA (ECDSA) or a contract wallet implementing EIP-1271 (e.g. Safe).
contract NAVOracle is INAVOracle, EIP712 {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    bytes32 internal constant NAV_UPDATE_TYPEHASH =
        keccak256("NAVUpdate(address rwaToken,uint256 price,uint256 dataTimestamp)");

    address public owner;
    uint256 public navDeviationMaxBps;
    mapping(address rwaToken => PriceData) private _priceData;
    mapping(address rwaToken => address) private _signer;

    constructor(address owner_, uint256 navDeviationMaxBps_) EIP712("NAVOracle", "1") {
        if (owner_ == address(0)) revert ZeroAddress();
        if (navDeviationMaxBps_ == 0) revert ZeroDeviationBps();
        owner = owner_;
        navDeviationMaxBps = navDeviationMaxBps_;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    /// @dev The monotonic-timestamp check treats `dataTimestamp == 0` as "no prior write yet" —
    ///      a signer must never submit `dataTimestamp == 0` as an actual reading, or every
    ///      subsequent write would be treated as the first write again.
    function updateNAV(address rwaToken, uint256 price, uint256 dataTimestamp, bytes calldata signature)
        external
        override
    {
        if (rwaToken == address(0)) revert ZeroAddress();

        PriceData storage data = _priceData[rwaToken];

        address signer = _signer[rwaToken];
        bytes32 structHash = keccak256(abi.encode(NAV_UPDATE_TYPEHASH, rwaToken, price, dataTimestamp));
        if (
            signer == address(0)
                || !SignatureChecker.isValidSignatureNow(signer, _hashTypedDataV4(structHash), signature)
        ) {
            revert UnauthorizedSigner(signer);
        }

        if (price == 0) revert InvalidNAV();
        if (dataTimestamp > block.timestamp) revert FutureData(dataTimestamp);

        if (data.dataTimestamp != 0 && dataTimestamp <= data.dataTimestamp) {
            revert NonMonotonicTimestamp(dataTimestamp, data.dataTimestamp);
        }

        if (data.price != 0 && price > data.price) {
            uint256 maxPrice = data.price * (BPS_DENOMINATOR + navDeviationMaxBps) / BPS_DENOMINATOR;
            if (price > maxPrice) revert DeviationTooHigh(price, data.price);
        }

        data.price = price;
        data.dataTimestamp = dataTimestamp;
        data.updatedAt = block.timestamp;

        emit NAVUpdated(rwaToken, price, dataTimestamp, block.timestamp, signer);
    }

    function setSigner(address rwaToken, address signer) external override {
        _onlyOwner();
        if (rwaToken == address(0) || signer == address(0)) revert ZeroAddress();
        _signer[rwaToken] = signer;
        emit SignerSet(rwaToken, signer);
    }

    function removeSigner(address rwaToken) external override {
        _onlyOwner();
        _signer[rwaToken] = address(0);
        emit SignerRemoved(rwaToken);
    }

    function setNAVDeviationMaxBps(uint256 newBps) external override {
        _onlyOwner();
        if (newBps == 0) revert ZeroDeviationBps();
        navDeviationMaxBps = newBps;
        emit NAVDeviationMaxBpsUpdated(newBps);
    }

    function transferOwnership(address newOwner) external override {
        _onlyOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    function getNAV(address rwaToken) external view override returns (uint256 price, uint256 updatedAt) {
        PriceData storage d = _priceData[rwaToken];
        return (d.price, d.updatedAt);
    }

    function getPriceData(address rwaToken) external view override returns (PriceData memory) {
        return _priceData[rwaToken];
    }

    function signerOf(address rwaToken) external view override returns (address) {
        return _signer[rwaToken];
    }
}
