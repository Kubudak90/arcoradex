// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { Safe } from "@safe-global/safe-contracts/contracts/Safe.sol";
import { Enum } from "@safe-global/safe-contracts/contracts/common/Enum.sol";

/// @notice Helpers for constructing + signing + packing Safe v1.4 transactions
/// in Foundry scripts and tests. Avoids the need to write the signature-encoding
/// boilerplate at every call site.
library SafeSigHelpers {
    /// @dev Forge's deterministic Vm address.
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct SafeTxParams {
        address to;
        uint256 value;
        bytes   data;
        Enum.Operation operation;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address payable refundReceiver;
    }

    /// @notice Sign + pack signatures from `signerKeys` (sorted by signer address ASC)
    /// and call `safe.execTransaction(...)`.
    /// @param safe         The Safe contract to execute against.
    /// @param p            Transaction parameters.
    /// @param signerKeys   Private keys of the signers (must be >= threshold).
    function signAndExec(Safe safe, SafeTxParams memory p, uint256[] memory signerKeys)
        internal
        returns (bool success)
    {
        uint256 nonce = safe.nonce();
        bytes32 safeTxHash = safe.getTransactionHash(
            p.to, p.value, p.data, p.operation,
            p.safeTxGas, p.baseGas, p.gasPrice, p.gasToken, p.refundReceiver,
            nonce
        );

        // Derive addresses + signatures
        uint256 n = signerKeys.length;
        address[] memory signers = new address[](n);
        bytes[]   memory sigs    = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            signers[i] = vm.addr(signerKeys[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], safeTxHash);
            sigs[i] = abi.encodePacked(r, s, v);
        }

        // Sort by address ascending (Safe requires this for the packed sig blob)
        for (uint256 i = 1; i < n; i++) {
            for (uint256 j = i; j > 0 && signers[j - 1] > signers[j]; j--) {
                (signers[j - 1], signers[j]) = (signers[j], signers[j - 1]);
                (sigs[j - 1],   sigs[j])   = (sigs[j],   sigs[j - 1]);
            }
        }

        bytes memory packed;
        for (uint256 i = 0; i < n; i++) {
            packed = bytes.concat(packed, sigs[i]);
        }

        success = safe.execTransaction(
            p.to, p.value, p.data, p.operation,
            p.safeTxGas, p.baseGas, p.gasPrice, p.gasToken, p.refundReceiver,
            packed
        );
    }

    /// @notice Convenience wrapper for simple call (Operation.Call, zero gas refunds).
    function execCall(Safe safe, address to, bytes memory data, uint256[] memory signerKeys)
        internal
        returns (bool)
    {
        SafeTxParams memory p = SafeTxParams({
            to: to,
            value: 0,
            data: data,
            operation: Enum.Operation.Call,
            safeTxGas: 0,
            baseGas: 0,
            gasPrice: 0,
            gasToken: address(0),
            refundReceiver: payable(address(0))
        });
        return signAndExec(safe, p, signerKeys);
    }
}
