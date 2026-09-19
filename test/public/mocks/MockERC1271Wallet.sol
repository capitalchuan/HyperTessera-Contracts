// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Minimal EIP-1271 contract wallet stand-in (Safe-like): a signature is valid when it is an
///         ECDSA signature over the same hash produced by the wallet's `walletOwner`.
contract MockERC1271Wallet {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e; // IERC1271.isValidSignature.selector

    address public walletOwner;

    constructor(address walletOwner_) {
        walletOwner = walletOwner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == walletOwner) {
            return MAGIC_VALUE;
        }
        return 0xffffffff;
    }
}

/// @notice EIP-1271 wallet that always answers with a wrong magic value — every signature must be rejected.
contract BadMagicERC1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}
