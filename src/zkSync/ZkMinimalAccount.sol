/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// Era imports
import {
    IAccount,
    ACCOUNT_VALIDATION_SUCCESS_MAGIC
} from "foundry-era-contracts/src/system-contracts/contracts/interfaces/IAccount.sol";
import {
    Transaction,
    MemoryTransactionHelper
} from "foundry-era-contracts/src/system-contracts/contracts/libraries/MemoryTransactionHelper.sol";
import {SystemContractsCaller} from
    "foundry-era-contracts/src/system-contracts/contracts/libraries/SystemContractsCaller.sol";
import {
    NONCE_HOLDER_SYSTEM_CONTRACT,
    BOOTLOADER_FORMAL_ADDRESS,
    DEPLOYER_SYSTEM_CONTRACT
} from "foundry-era-contracts/src/system-contracts/contracts/Constants.sol";
import {INonceHolder} from "foundry-era-contracts/src/system-contracts/contracts/interfaces/INonceHolder.sol";
import {Utils} from "foundry-era-contracts/src/system-contracts/contracts/libraries/Utils.sol";

// OZ Imports
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Lifecycle of a type 113 (0x71) transaction
 * msg.sender is the bootloader system contract
 *
 * Phase 1. Validation
 * 1. The user sends the transaction to the "zkSync API client" (sort of a "light mode")
 * 2. The zkSync API client checls to see, if  the nonce is unique, by quirying the NonceHolder sysem contract
 * 3. The zkSync API client calls validateTransaction, which MUST update the nonce
 * 4. The zkSync API client checks the nonce is updated
 * 5. The zkSync API client calls payGorTransaction, or prepareForPaymaster & validate&AndPayForPaymasterTransaction
 * 6. The zkSync API client verifies that the bottloader gets paid
 *
 * Phase 2. Execution
 * 7. The zkSync API client passes the validated transaction to the main node / sequencee (as of today, they are the same)
 * 8. The main node calls executeTransaction
 * 9. If a paymaster was used, the postTransaction is called
 */
contract ZkMinimalAccount is IAccount, Ownable {
    /*/////////////////////////////////////////////////////////////
                         USING STATEMENTS
    /////////////////////////////////////////////////////////////*/
    using MemoryTransactionHelper for Transaction;

    /*/////////////////////////////////////////////////////////////
                         ERRORS
    /////////////////////////////////////////////////////////////*/
    error ZkMinimalAccount__NotEnoughBalance();
    error ZkMinimalAccount__NotFromBootloader();
    error ZkMinimalAccount__NotFromBootloaderOrOwner();
    error ZkMinimalAccount_ExecutionFailed();
    error ZkMinimalAccount_FailedToPay();

    /*/////////////////////////////////////////////////////////////
                         MODIFIERS
    /////////////////////////////////////////////////////////////*/
    modifier requireFromBootLoader() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            revert ZkMinimalAccount__NotFromBootloader();
        }
        _;
    }

    modifier requireFromBootLoaderOrOwner() {
        if ((msg.sender != BOOTLOADER_FORMAL_ADDRESS) && (msg.sender != owner())) {
            revert ZkMinimalAccount__NotFromBootloaderOrOwner();
        }
        _;
    }

    /*/////////////////////////////////////////////////////////////
                         CONSTRUCTOR
    /////////////////////////////////////////////////////////////*/
    constructor() Ownable(msg.sender) {}

    /*/////////////////////////////////////////////////////////////
                         EXTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    receive() external payable {}

    /**
     * @notice must increase the nonce
     * @notice must validate the transaction (check the owner signed the transaction)
     * @notice also check to see if we have enough money un our account
     * _txHash  The hash of the transaction to be used in the explorer
     * _suggestedSignedHash  The hash of the transaction is signed by EOAs
     * @param _transaction  The transaction itself
     */
    function validateTransaction(bytes32, /*_txHash*/ bytes32, /*_suggestedSignedHash*/ Transaction memory _transaction)
        external
        payable
        returns (bytes4 magic)
    {
        return _validateTransaction(_transaction);
    }

    // only bootloader can call it

    function executeTransaction(bytes32, /*_txHash*/ bytes32, /*_suggestedSignedHash*/ Transaction memory _transaction)
        external
        payable
        requireFromBootLoaderOrOwner
    {
        return _executeTransaction(_transaction);
    }

    // you sign a tx
    // send the sidned tx to yiur friend
    // They can send it by calling this function
    // so, anybody can call it
    function executeTransactionFromOutside(Transaction memory _transaction) external payable {
        _validateTransaction(_transaction);
        _executeTransaction(_transaction);
    }

    function payForTransaction(bytes32, /*_txHash*/ bytes32, /*_suggestedSignedHash*/ Transaction memory _transaction)
        external
        payable
    {
        bool success = _transaction.payToTheBootloader();
        if (!success) {
            revert ZkMinimalAccount_FailedToPay();
        }
    }

    function prepareForPaymaster(bytes32, /*_txHash*/ bytes32, /*_suggestedSignedHash*/ Transaction memory _transaction)
        external
        payable
    {}

    /*/////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////*/

    function _validateTransaction(Transaction memory _transaction) internal returns (bytes4 magic) {
        // Call nonceholder to increase the nonce
        // call (x, y, z) -> system contract call
        SystemContractsCaller.systemCallWithPropagatedRevert(
            uint32(gasleft()),
            address(NONCE_HOLDER_SYSTEM_CONTRACT),
            0,
            abi.encodeCall(INonceHolder.incrementMinNonceIfEquals, (_transaction.nonce))
        );

        // check for fee to pay
        uint256 totalRequiredBalance = _transaction.totalRequiredBalance();
        if (totalRequiredBalance > address(this).balance) {
            revert ZkMinimalAccount__NotEnoughBalance();
        }
        // check the signature & return the "magic" number
        bytes32 txHash = _transaction.encodeHash();
        // (_transaction.signature, txHash)
        bytes32 convertedHash = MessageHashUtils.toEthSignedMessageHash(txHash);
        address signer = ECDSA.recover(convertedHash, _transaction.signature);
        bool isValidSigner = signer == owner();
        if (isValidSigner) {
            magic = ACCOUNT_VALIDATION_SUCCESS_MAGIC;
        } else {
            magic = bytes4(0);
        }
        return magic;
    }

    function _executeTransaction(Transaction memory _transaction) internal {
        address to = address(uint160(_transaction.to));
        uint128 value = Utils.safeCastToU128(_transaction.value);
        bytes memory data = _transaction.data;
        if (to == address(DEPLOYER_SYSTEM_CONTRACT)) {
            uint32 gas = Utils.safeCastToU32(gasleft());
            SystemContractsCaller.systemCallWithPropagatedRevert(gas, to, value, data);
        } else {
            bool success;
            assembly {
                success := call(gas(), to, value, add(data, 0x20), mload(data), 0, 0)
            }
            if (!success) {
                revert ZkMinimalAccount_ExecutionFailed();
            }
        }
    }
}
