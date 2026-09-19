// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

interface INAVOracle {
    struct PriceData {
        uint256 price; // 1e18-scale: value of 1 whole rwaToken, denominated in 1 whole asset unit
        uint256 dataTimestamp; // off-chain source timestamp (not block.timestamp)
        uint256 updatedAt; // block.timestamp of last on-chain write
    }

    event NAVUpdated(
        address indexed rwaToken, uint256 price, uint256 dataTimestamp, uint256 updatedAt, address indexed signer
    );
    event SignerSet(address indexed rwaToken, address indexed signer);
    event SignerRemoved(address indexed rwaToken);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event NAVDeviationMaxBpsUpdated(uint256 newBps);

    error ZeroAddress();
    error Unauthorized();
    error UnauthorizedSigner(address recovered);
    error InvalidNAV();
    error FutureData(uint256 dataTimestamp);
    error NonMonotonicTimestamp(uint256 dataTimestamp, uint256 previous);
    error DeviationTooHigh(uint256 price, uint256 previousPrice);
    error ZeroDeviationBps();

    function updateNAV(address rwaToken, uint256 price, uint256 dataTimestamp, bytes calldata signature) external;

    function setSigner(address rwaToken, address signer) external;
    function removeSigner(address rwaToken) external;
    function transferOwnership(address newOwner) external;
    function setNAVDeviationMaxBps(uint256 newBps) external;

    function getNAV(address rwaToken) external view returns (uint256 price, uint256 updatedAt);
    function getPriceData(address rwaToken) external view returns (PriceData memory);
    function signerOf(address rwaToken) external view returns (address);
    function owner() external view returns (address);
    function navDeviationMaxBps() external view returns (uint256);
}
