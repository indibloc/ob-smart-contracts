pragma solidity 0.4.24;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";

import "../token/ITokenContract.sol";


/**
* @dev Supports ERC20 tokens
* The escrow smart contract for the OpenBazaar trades in Ethereum
* The smart contract is designed keeping in mind the current wallet interface of OB-core
* https://github.com/OpenBazaar/wallet-interface/blob/master/wallet.go
* Current wallet interface strictly adheres to UTXO(bitcoin) model
* Please read below mentioned link for detailed specs
* https://github.com/OpenBazaar/smart-contracts/blob/master/contracts/escrow/EscrowSpec.md
*/
contract Escrow_v1_0 {

    using SafeMath for uint256;

    enum Status {FUNDED, RELEASED}

    enum TransactionType {ETHER, TOKEN}

    event Executed(
        bytes32 indexed scriptHash,
        address[] destinations,
        uint256[] amounts
    );

    event FundAdded(
        bytes32 indexed scriptHash,
        address indexed from,
        uint256 valueAdded
    );

    event Funded(
        bytes32 indexed scriptHash,
        address indexed from,
        uint256 value
    );

    struct Transaction {
        uint256 value;
        uint256 lastModified;//Time at which tx was last modified in seconds
        Status status;
        TransactionType transactionType;
        uint8 threshold;
        uint32 timeoutHours;
        address buyer;
        address seller;
        address tokenAddress;//Token address in case of token transfer
        address moderator;
        mapping(address => bool) isOwner;//to keep track of owners.
        mapping(address => bool) voted;//to keep track of who all voted
        mapping(address => bool) beneficiaries;//Benefeciaries of execution
    }

    mapping(bytes32 => Transaction) public transactions;

    uint256 public transactionCount = 0;

    //Contains mapping between each party and all of their transactions
    mapping(address => bytes32[]) private partyVsTransaction;

    modifier transactionExist(bytes32 scriptHash) {
        require(
            transactions[scriptHash].value != 0, "Transaction does not exist"
        );
        _;
    }

    modifier transactionDoesNotExist(bytes32 scriptHash) {
        require(transactions[scriptHash].value == 0, "Transaction exist");
        _;
    }

    modifier inFundedState(bytes32 scriptHash) {
        require(
            transactions[scriptHash].status == Status.FUNDED, "Transaction is not in FUNDED state"
        );
        _;
    }

    modifier nonZeroAddress(address addressToCheck) {
        require(addressToCheck != address(0), "Zero address passed");
        _;
    }

    modifier checkTransactionType(
        bytes32 scriptHash,
        TransactionType transactionType
    )
    {
        require(
            transactions[scriptHash].transactionType == transactionType, "Transaction type does not match"
        );
        _;
    }

    modifier onlyBuyer(bytes32 scriptHash) {
        require(
            msg.sender == transactions[scriptHash].buyer, "The initiator of the transaction is not buyer"
        );
        _;
    }

    /**
    * @dev Add new transaction in the contract
    * @param buyer The buyer of the transaction
    * @param seller The seller of the listing associated with the transaction
    * @param moderator Moderator for this transaction
    * @param threshold Minimum number of signatures required to released funds
    * @param timeoutHours Hours after which seller can release funds into his favour by signing transaction unilaterally
    * @param scriptHash keccak256 hash of the redeem script
    * @param uniqueId bytes20 unique id for the transaction, generated by ETH wallet
    * Redeem Script format will be following
      <uniqueId: 20><threshold:1><timeoutHours:4><buyer:20><seller:20><moderator:20><multisigAddress:20>
    * Pass amount of the ethers to be put in escrow
    */
    function addTransaction(
        address buyer,
        address seller,
        address moderator,
        uint8 threshold,
        uint32 timeoutHours,
        bytes32 scriptHash,
        bytes20 uniqueId
    )
        external
        payable
        transactionDoesNotExist(scriptHash)
        nonZeroAddress(buyer)
        nonZeroAddress(seller)
    {
        _addTransaction(
            buyer,
            seller,
            moderator,
            threshold,
            timeoutHours,
            scriptHash,
            msg.value,
            uniqueId,
            TransactionType.ETHER,
            address(0)
        );

        emit Funded(scriptHash, msg.sender, msg.value);

    }

    /**
    * @dev Add new transaction in the contract
    * @param buyer The buyer of the transaction
    * @param seller The seller of the listing associated with the transaction
    * @param moderator Moderator for this transaction
    * @param threshold Minimum number of signatures required to released funds
    * @param timeoutHours Hours after which seller can release funds into his favour by signing transaction unilaterally
    * @param scriptHash keccak256 hash of the redeem script
    * @param value Amount of tokens to be put in escrow
    * @param uniqueId bytes20 unique id for the transaction, generated by ETH wallet
    * @param tokenAddress Address of the token to be used
    * Redeem Script format will be following
      <uniqueId: 20><threshold:1><timeoutHours:4><buyer:20><seller:20><moderator:20><multisigAddress:20><tokenAddress:20>
    * Approve escrow contract to spend amount of token on sender's behalf
    */
    function addTokenTransaction(
        address buyer,
        address seller,
        address moderator,
        uint8 threshold,
        uint32 timeoutHours,
        bytes32 scriptHash,
        uint256 value,
        bytes20 uniqueId,
        address tokenAddress
    )
        external
        transactionDoesNotExist(scriptHash)
        nonZeroAddress(buyer)
        nonZeroAddress(seller)
        nonZeroAddress(tokenAddress)
    {

        _addTransaction(
            buyer,
            seller,
            moderator,
            threshold,
            timeoutHours,
            scriptHash,
            value,
            uniqueId,
            TransactionType.TOKEN,
            tokenAddress
        );

        ITokenContract token = ITokenContract(tokenAddress);

        require(
            token.transferFrom(msg.sender, address(this), value),
            "Token transfer failed, maybe you did not approve escrow contract to spend on behalf of sender"
        );
        emit Funded(scriptHash, msg.sender, value);
    }

    /**
    * @dev This method will check whether given address was a beneficiary of transaction execution or not
    * @param scriptHash script hash of the transaction
    * @param beneficiary Beneficiary address to be checked
    */
    function checkBeneficiary(
        bytes32 scriptHash,
        address beneficiary
    )
        external
        view
        returns (bool)
    {
        return transactions[scriptHash].beneficiaries[beneficiary];
    }

    /**
    * @dev This method will check whether given party has voted or not
    * @param scriptHash script hash of the transaction
    * @param party Address of the party whose vote has to be checked
    * @return bool vote
    */
    function checkVote(
        bytes32 scriptHash,
        address party
    )
        external
        view
        returns (bool)
    {
        return transactions[scriptHash].voted[party];
    }

    /**
    * @dev Allows buyer of the transaction to add more funds(ether) in the transaction.
    * This will help to cater scenarios wherein initially buyer missed to fund transaction as required
    * @param scriptHash script hash of the transaction
    * Only buyer of the transaction can invoke this method
    */
    function addFundsToTransaction(
        bytes32 scriptHash
    )
        external
        payable
        transactionExist(scriptHash)
        inFundedState(scriptHash)
        checkTransactionType(scriptHash, TransactionType.ETHER)
        onlyBuyer(scriptHash)

    {

        require(msg.value > 0, "Value must be greater than zero.");

        transactions[scriptHash].value = transactions[scriptHash].value
            .add(msg.value);

        emit FundAdded(scriptHash, msg.sender, msg.value);
    }

    /**
    * @dev Allows buyer of the transaction to add more funds(Tokens) in the transaction.
    * This will help to cater scenarios wherein initially buyer missed to fund transaction as required
    * @param scriptHash script hash of the transaction
    * Only buyer of the transaction can invoke this method
    */
    function addTokensToTransaction(
        bytes32 scriptHash,
        uint256 value
    )
        external
        transactionExist(scriptHash)
        inFundedState(scriptHash)
        checkTransactionType(scriptHash, TransactionType.TOKEN)
        onlyBuyer(scriptHash)
    {

        require(value > 0, "Value must be greater than zero.");

        ITokenContract token = ITokenContract(
            transactions[scriptHash].tokenAddress
        );

        require(
            token.transferFrom(msg.sender, address(this), value),
            "Token transfer failed, maybe you did not approve escrow contract to spend on behalf of buyer"
        );

        transactions[scriptHash].value = transactions[scriptHash].value
            .add(value);

        emit FundAdded(scriptHash, msg.sender, value);
    }

    /**
    *@dev Returns all transaction ids for a party
    *@param partyAddress Address of the party
    */
    function getAllTransactionsForParty(
        address partyAddress
    )
        external
        view
        returns (bytes32[])
    {
        return partyVsTransaction[partyAddress];
    }

    /**
    *@dev This method will be used to release funds associated with the transaction
    * Please see specs https://github.com/OpenBazaar/smart-contracts/blob/master/contracts/escrow/EscrowSpec.md
    *@param sigV Array containing V component of all the signatures
    *@param sigR Array containing R component of all the signatures
    *@param signS Array containing S component of all the signatures
    *@param scriptHash script hash of the transaction
    *@param destinations List of addresses who will receive funds
    *@param amounts amount released to each destination
    */
    function execute(
        uint8[] sigV,
        bytes32[] sigR,
        bytes32[] sigS,
        bytes32 scriptHash,
        address[] destinations,
        uint256[] amounts
    )
        external
        transactionExist(scriptHash)
        inFundedState(scriptHash)
    {

        require(
            destinations.length > 0,
            "Number of destinations must be greater than 0"
        );
        require(
            destinations.length == amounts.length,
            "Number of destinations must match number of values sent"
        );

        _verifyTransaction(
            sigV,
            sigR,
            sigS,
            scriptHash,
            destinations,
            amounts
        );

        transactions[scriptHash].status = Status.RELEASED;
        //Last modified timestamp modified, which will be used by rewards
        transactions[scriptHash].lastModified = block.timestamp;
        require(
            _transferFunds(scriptHash, destinations, amounts) == transactions[scriptHash].value,
            "Total value to be released must be equal to the transaction escrow value"
        );

        emit Executed(scriptHash, destinations, amounts);
    }


    /**
    *@dev Method for calculating script hash. Calculation will depend upon the type of transaction
    * ETHER Type transaction-:
    * Script Hash- keccak256(uniqueId, threshold, timeoutHours, buyer, seller, moderator, multiSigContractAddress)
    * TOKEN Type transaction
    * Script Hash- keccak256(uniqueId, threshold, timeoutHours, buyer, seller, moderator, multiSigContractAddress, tokenAddress)
    * Client can use this method to verify whether it has calculated correct script hash or not
    */
    function calculateRedeemScriptHash(
        bytes20 uniqueId,
        uint8 threshold,
        uint32 timeoutHours,
        address buyer,
        address seller,
        address moderator,
        address tokenAddress
    )
        public
        view
        returns (bytes32)
    {
        if (tokenAddress == address(0)) {
            return keccak256(
                abi.encodePacked(
                    uniqueId,
                    threshold,
                    timeoutHours,
                    buyer,
                    seller,
                    moderator,
                    address(this)
                )
            );
        } else {
            return keccak256(
                abi.encodePacked(
                    uniqueId,
                    threshold,
                    timeoutHours,
                    buyer,
                    seller,
                    moderator,
                    address(this),
                    tokenAddress
                )
            );
        }
    }

    /**
    * @dev This methods checks validity of transaction
    * 1. Verify Signatures
    * 2. Check if minimum number of signatures has been acquired
    * 3. If above condition is false, check if time lock is expired and the execution is signed by seller
    */
    function _verifyTransaction(
        uint8[] sigV,
        bytes32[] sigR,
        bytes32[] sigS,
        bytes32 scriptHash,
        address[] destinations,
        uint256[] amounts
    )
        private
    {
        _verifySignatures(
            sigV,
            sigR,
            sigS,
            scriptHash,
            destinations,
            amounts
        );

        bool timeLockExpired = _isTimeLockExpired(
            transactions[scriptHash].timeoutHours,
            transactions[scriptHash].lastModified
        );

        //if Minimum number of signatures are not gathered and timelock has not expired or transaction was not signed by seller then revert
        if (
                sigV.length < transactions[scriptHash].threshold && (
                    !timeLockExpired || !transactions[scriptHash].voted[transactions[scriptHash].seller]
                )
            )
        {
            revert("Minimum number of signatures are not collected and time lock expiry conditions not met!!");
        }

    }

    /**
    *@dev Private method to transfer funds to the destination addresses on the basis of transaction type
    */
    function _transferFunds(
        bytes32 scriptHash,
        address[]destinations,
        uint256[]amounts
    )
        private
        returns (uint256)
    {
        Transaction storage t = transactions[scriptHash];

        uint256 valueTransferred = 0;

        if (t.transactionType == TransactionType.ETHER) {
            for (uint256 i = 0; i < destinations.length; i++) {

                require(destinations[i] != address(0), "zero address is not allowed as destination address");

                require(t.isOwner[destinations[i]], "Destination address is not one of the owners");

                require(amounts[i] > 0, "Amount to be sent should be greater than 0");

                valueTransferred = valueTransferred.add(amounts[i]);

                t.beneficiaries[destinations[i]] = true;//add receiver as beneficiary
                destinations[i].transfer(amounts[i]);
            }

        } else if (t.transactionType == TransactionType.TOKEN) {

            ITokenContract token = ITokenContract(t.tokenAddress);

            for (uint256 j = 0; j<destinations.length; j++) {

                require(destinations[j] != address(0), "zero address is not allowed as destination address");

                require(t.isOwner[destinations[j]], "Destination address is not one of the owners");

                require(amounts[j] > 0, "Amount to be sent should be greater than 0");

                valueTransferred = valueTransferred.add(amounts[j]);
                t.beneficiaries[destinations[j]] = true;//add receiver as beneficiary

                require(token.transfer(destinations[j], amounts[j]), "Token transfer failed.");
            }
        }
        return valueTransferred;
    }

    //to check whether the signatures are valid or not and if consensus was reached
    //returns the last address recovered, in case of timeout this must be the sender's address
    function _verifySignatures(
        uint8[] sigV,
        bytes32[] sigR,
        bytes32[] sigS,
        bytes32 scriptHash,
        address[] destinations,
        uint256[]amounts
    )
        private
    {

        require(
            sigR.length == sigS.length && sigR.length == sigV.length,
            "R,S,V length mismatch."
        );

        // Follows ERC191 signature scheme: https://github.com/ethereum/EIPs/issues/191
        bytes32 txHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encodePacked(
                        byte(0x19),
                        byte(0),
                        address(this),
                        destinations,
                        amounts,
                        scriptHash
                    )
                )
            )
        );

        for (uint i = 0; i < sigR.length; i++) {

            address recovered = ecrecover(
                txHash,
                sigV[i],
                sigR[i],
                sigS[i]
            );

            require(
                transactions[scriptHash].isOwner[recovered],
                "Invalid signature"
            );
            require(
                !transactions[scriptHash].voted[recovered],
                "Same signature sent twice"
            );
            transactions[scriptHash].voted[recovered] = true;
        }
    }

    function _isTimeLockExpired(
        uint32 timeoutHours,
        uint256 lastModified
    )
        private
        view
        returns (bool)
    {
        uint256 timeSince = now.sub(lastModified);
        return (
            timeoutHours == 0 ? false : timeSince > uint256(timeoutHours).mul(3600)
        );
    }

    /**
    * Private method to add transaction to reduce code redundancy
    */
    function _addTransaction(
        address buyer,
        address seller,
        address moderator,
        uint8 threshold,
        uint32 timeoutHours,
        bytes32 scriptHash,
        uint256 value,
        bytes20 uniqueId,
        TransactionType transactionType,
        address tokenAddress
    )
        private
    {
        require(buyer != seller, "Buyer and seller are same");

        //value passed should be greater than 0
        require(value > 0, "Value passed is 0");

        // For now allowing 0 moderator to support 1-2 multisig wallet
        require(
            threshold > 0 && threshold <= 3,
            "Threshold cannot be greater than 3 and must be greater than 0"
        );

        //if threshold is 1 then moderator can be passed as zero address or any other address
        //(it won't matter apart from scripthash since we wont add moderator as one of the owner),
        //otherwise moderator should be a valid address
        require(
            threshold == 1 || moderator != address(0),
            "Either threshold should be 1 or valid moderator address should be passed"
        );

        require(
            scriptHash == calculateRedeemScriptHash(
                uniqueId,
                threshold,
                timeoutHours,
                buyer,
                seller,
                moderator,
                tokenAddress
            ),
            "Calculated script hash does not match passed script hash."
        );

        transactions[scriptHash] = Transaction({
            buyer: buyer,
            seller: seller,
            moderator: moderator,
            value: value,
            status: Status.FUNDED,
            lastModified: block.timestamp,
            threshold: threshold,
            timeoutHours: timeoutHours,
            transactionType:transactionType,
            tokenAddress:tokenAddress
        });

        transactions[scriptHash].isOwner[seller] = true;
        transactions[scriptHash].isOwner[buyer] = true;

        //Check if buyer or seller are not passed as moderator
        require(
            !transactions[scriptHash].isOwner[moderator],
            "Either buyer or seller is passed as moderator"
        );

        //set moderator as one of the owners only if threshold is greater than 1 otherwise only buyer and seller should be able to release funds
        if (threshold > 1) {
            transactions[scriptHash].isOwner[moderator] = true;
        }


        transactionCount++;

        partyVsTransaction[buyer].push(scriptHash);
        partyVsTransaction[seller].push(scriptHash);
    }
}
