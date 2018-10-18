pragma solidity ^0.4.24;
import "./Forwarder.sol";

/**
*
* SimpleWallet
* ============
*
* Basic multi-signer wallet designed for use in a co-signing environment where 2 signatures are required to move funds.
* Typically used in a 2-of-3 signing configuration, this configuration is 2-of-4, 2 hot accounts (allowed and verified) and 2 cold accounts (allowed). 
* Uses ecrecover to allow for 2 signatures in a single transaction.
* If either (or both) of the hot accounts are compromised (or have lost their private keys) one (or both) of the cold accounts 
*   can be verified (made hot) and used to TransferSignership away from the old compromised accounts to fresh cold accounts.
*
* The first signature is created on the operation hash (see Data Formats) and passed to sendMultiSig/sendMultiSigToken
* The signer is determined by verifyMultiSig().
*
* The second signature is created by the submitter of the transaction and determined by msg.signer.
*
* Data Formats
* ============
*
* The signature is created with ethereumjs-util.ecsign(operationHash).
* Like the eth_sign RPC call, it packs the values as a 65-byte array of [r, s, v].
* Unlike eth_sign, the message is not prefixed.
*
* The operationHash for ether transactions is the result of keccak256(abi.encode(prefix, toAddress, value, data, expireTime, sequenceId)).
* For ether transactions, `prefix` is "TRANSACT".
* The operationHash for transfer signership transactions is the result of keccak256(abi.encode(prefix, oldSigner, newSigner, expireTime, sequenceId)).
* For Signer transfer transaction, `prefix` is "XFERSIGN".
*
*
*/

contract SimpleWallet {
    // Events
    event ForwarderCreate(address forwardContract, uint256 addressSeq, uint256 currentBlock, address parentAddress);
    event Deposited(address from, uint256 value, bytes data);
    event Verified(address msgSender);
    event SafeModeActivated(address msgSender);
    event SignershipTransfer(address oldSigner, address newSigner);
    event Transacted(
      address indexed msgSender, // Address of the sender of the message initiating the transaction
      address indexed otherSigner, // Address of the signer (second signature) used to initiate the transaction
      string operationCode, // the code of the operation transacted
      bytes32 operation, // Operation hash (see Data Formats)
      address toAddress, // The address the transaction was sent to
      uint256 value, // Amount of Wei sent to the address
      bytes data // Data sent when invoking the transaction
    );

    // Public fields
    mapping(address => Signer) public signers; // The addresses that can co-sign transactions on the wallet
    struct Signer {
        bool allowed; // flag to set when the signing address is allowed
        bool verified; // flag to set when the signing address has verified itself to prove ownership of the account
    }
    
    mapping(address => bool) public forwarders; // A map to check if an address is a Forwarder address. A full list of forwarders can be derived from a ForwardContract event log search
    uint256 public addressId; // this keeps tracks of the number of address created for Forwarder contract
    
    bool public safeMode = false; // when active, wallet may only send to signer addresses
    
    // Private fields
    uint256 private sequenceId; // the current sequence ID of all transactions on this contract (counts up for every new transaction)

    /**
    * A simple multi-sig wallet by specifying the signers allowed to be used on this wallet.
    * 2 signers will be required to send a transaction from this wallet.
    * Note: The contract deployer is NOT automatically added to the list of signers.
    *
    * @param _allowedSigners An array of signers on the wallet
    */
    constructor(address[] _allowedSigners) public {
        // 4 signers, 2 hot and 2 cold, if one or both of the hot signers are compromised (or priv keys are lost) use cold signers to transfer signership
        require(_allowedSigners.length == 4, "only 4 signers allowed");

        for (uint i = 0; i < _allowedSigners.length; i++) {
            require(signers[_allowedSigners[i]].allowed != true, "each signer address must be unique");
            signers[_allowedSigners[i]].allowed = true;
        }
    }

    /**
    * Modifier that will execute internal code block only if the sender is an authorized signer on this wallet
    */
    modifier onlySigner {
        require(signers[msg.sender].allowed && signers[msg.sender].verified, "msg.sender is not allowed or not verfied");
        _;
    }

    /**
    * Gets called when a transaction is received without calling a method
    */
    function() public payable {
        if (msg.value > 0) {
            // Fire deposited event if we are receiving funds
            emit Deposited(msg.sender, msg.value, msg.data);
        }
    }

    /**
    * @dev public function for signers to verify themselves
    */
    function verifySigner() public {
        require(signers[msg.sender].allowed, "Only allowed signer can verify themselves");
        signers[msg.sender].verified = true;
        emit Verified(msg.sender);
    }
    /**
    * @dev functionality to replace an old signer with a new signer
    * @param _oldSigner signer addresss of the old signer
    * @param _newSigner signer addresss of the new signer
    * @param _expireTime the number of seconds since 1970 for which this transaction is valid
    * @param _sequenceId the unique sequence id obtainable from getNextSequenceId
    * @param _signature see Data Formats
    */
    function transferSignership(
        address _oldSigner,
        address _newSigner,
        uint256 _expireTime,
        uint256 _sequenceId,
        bytes _signature
    ) public onlySigner {
        
        require(signers[_newSigner].allowed != true, "_newSigner cannot be an exsisting signer");
        
        // Verify the other signer
        bytes32 operationHash = keccak256(abi.encodePacked("XFERSIGN", _oldSigner, _newSigner, _expireTime, _sequenceId));
        verifyMultiSig(address(this), operationHash, _expireTime, _sequenceId, _signature);

        _transferSignership(_oldSigner, _newSigner);
    }

    /**
    * @dev Transfers control of the contract to a newOwner.
    * @param _oldSigner is the address of the existing signer
    * @param _newSigner The address to include in the signer list.
    */
    function _transferSignership(address _oldSigner, address _newSigner) internal {
        // disallow old signer
        signers[_oldSigner].allowed = false;
        signers[_oldSigner].verified = false;

        // allow new signer
        signers[_newSigner].allowed = true;
        sequenceId += 1;
        emit SignershipTransfer(_oldSigner, _newSigner);
    }

    /**
    * Create a new contract  (and also address) that forwards funds to this contract
    * returns address of newly created forwarder address
    */
    function createForwarder() public {
        Forwarder forwarder = new Forwarder();
        forwarders[forwarder] = true;
        addressId += 1;
        emit ForwarderCreate(forwarder, addressId, block.number, msg.sender);
    }

    /**
    * Execute a multi-signature transaction from this wallet using 2 signers: one from msg.sender and the other from ecrecover.
    *
    * @param _toAddress the destination address to send an outgoing transaction
    * @param _value the amount in Wei to be sent
    * @param _data the data to send to the toAddress when invoking the transaction
    * @param _expireTime the block number until which this transaction is valid
    * @param _sequenceId the unique sequence id obtainable from getNextSequenceId
    * @param _signature see Data Formats
    */
    function sendMultiSig (
        address _toAddress,
        uint _value,
        bytes _data,
        uint _expireTime,
        uint _sequenceId,
        bytes _signature
    ) public onlySigner {
        // Verify the other signer
        bytes32 operationHash = keccak256(abi.encodePacked("TRANSACT", _toAddress, _value, _data, _expireTime, _sequenceId));
        verifyMultiSig(_toAddress, operationHash, _expireTime, _sequenceId, _signature);

        // Success, send the transaction
        // .call.value()() is fine here since only signers can call this function and presumably we trust them from re-entrancy
        require(_toAddress.call.value(_value)(_data), "Transaction send failed");
        sequenceId += 1;
        // Transacted(msg.sender, otherSigner, operationHash, _toAddress, _value, _data);
    }


    /**
    * Do common verification for all multisig txns
    *
    * @param _toAddress the destination address to send an outgoing transaction
    * @param _operationHash see Data Formats
    * @param _signature see Data Formats
    * @param _expireTime the number of seconds since 1970 for which this transaction is valid
    * @param _sequenceId the unique sequence id obtainable from getNextSequenceId
    * returns address that has created the signature
    */
    function verifyMultiSig(
        address _toAddress,
        bytes32 _operationHash,
        uint256 _expireTime,
        uint256 _sequenceId,
        bytes _signature
    ) private view {

        // Verify that the transaction has not expired
        require(_expireTime <= block.number, "Transaction expired");
        require(_sequenceId == sequenceId + 1, "Invalid sequence ID");
        address otherSigner = recoverAddressFromSignature(_operationHash, _signature);
        require(signers[otherSigner].allowed, "otherSigner not allowed");
        require(signers[otherSigner].verified, "otherSigner not verified");
        
        // Check if we are in safe mode. In safe mode, the wallet can only send to current signers or this contract
        if(safeMode && _toAddress != address(this)){
            // We are in safe mode and if the _toAddress is not a signer or not verified. Disallow!
            require(signers[_toAddress].allowed, "toAddress not allowed");
            require(signers[_toAddress].verified, "toAddress not verified");
            // Furthermore to be as safe as possible only the msg.sender or the otherSigner can receive the transaction (because they have proven they still hold their private keys to sign)
            require(_toAddress == msg.sender || _toAddress == otherSigner, "toAddress was not msg.sender or otherSigner");
        }

        require(otherSigner != msg.sender, "msg.sender cannot double sign");
    }

    /**
    * Irrevocably puts contract into safe mode. When in this mode, transactions may only be sent to signing addresses.
    */
    function activateSafeMode() public onlySigner {
        safeMode = true;
        emit SafeModeActivated(msg.sender);
    }

    /**
    * Gets signer's address using ecrecover
    * @param _operationHash see Data Formats
    * @param _signature see Data Formats
    * returns address recovered from the signature
    */
    function recoverAddressFromSignature(
        bytes32 _operationHash,
        bytes _signature
      ) private pure returns (address) {
        if (_signature.length != 65) {
            revert();
        }
        // We need to unpack the signature, which is given as an array of 65 bytes (like eth.sign)
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
          r := mload(add(_signature, 32))
          s := mload(add(_signature, 64))
          v := and(mload(add(_signature, 65)), 255)
        }
        if (v < 27) {
            v += 27; // Ethereum versions are 27 or 28 as opposed to 0 or 1 which is submitted by some signing libs
        }
        return ecrecover(_operationHash, v, r, s);
    }

    /**
    * @dev functionality to get the sequenceId for the next transaction
    * @return the current sequenceId plus one
    */
    function getSequenceId() public view returns (uint256){
        return sequenceId + 1;
    }

}