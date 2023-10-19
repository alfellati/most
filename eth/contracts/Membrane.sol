// SPDX-License-Identifier: MIT

pragma solidity ^0.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Membrane {
    uint256 public requestNonce;
    uint256 public signatureThreshold;

    struct Request {
        uint256 signatureCount;
        mapping(address => bool) signatures;
    }

    // from -> to mapping
    mapping(bytes32 => bytes32) public supportedPairs;

    mapping(bytes32 => Request) public pendingRequests;

    mapping(bytes32 => bool) public processedRequests;

    mapping(address => bool) private guardians;

    event CrosschainTransferRequest(
        bytes32 indexed destTokenAddress,
        uint256 amount,
        bytes32 destReceiverAddress,
        uint256 requestNonce
    );

    event RequestSigned(bytes32 requestHash, address signer);

    event RequestProcessed(bytes32 requestHash);

    modifier onlyGuardian() {
        require(isGuardian(msg.sender), "Can only be called by a signer");
        _;
    }

    constructor(
                address[] memory _guardians,
                uint256 _signatureThreshold
                ) {
        require(_guardians.length >= _signatureThreshold, "Not enough guardians specified");
        signatureThreshold = _signatureThreshold;
        for (uint256 i = 0; i < _guardians.length; i++) {
            guardians[_guardians[i]] = true;
        }
    }

    function isGuardian(address sender) public view returns (bool) {
        return guardians[sender];
    }

    function addPair(bytes32 from, bytes32 to) public {
         supportedPairs[from] = to;
    }

    // TODO: remove pair

    function bytes32ToAddress(bytes32 data) internal pure returns (address) {
        return address(uint160(uint256(data)));
    }

    function addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    // Invoke this tx to transfer funds to the destination chain.
    // Account needs to approve the Membrane contract to spend the srcTokenAmount
    // on their behalf before executing the tx.
    //
    // Tx emits a CrosschainTransferRequest event that the relayers listen to
    // & forward to the destination chain.
    function sendRequest(
        bytes32 srcTokenAddress,
        uint256 amount,
        bytes32 destReceiverAddress
    ) external {
        address sender = msg.sender;

        IERC20 token = IERC20(bytes32ToAddress(srcTokenAddress));
        // lock tokens in this contract
        // message sender needs to give approval else this tx will revert
        token.transferFrom(sender, address(this), amount);

        bytes32 destTokenAddress = supportedPairs[srcTokenAddress];
        require(destTokenAddress != 0x0, "Unsupported pair");

        emit CrosschainTransferRequest(
            destTokenAddress,
            amount,
            destReceiverAddress,
            requestNonce
        );

        requestNonce++;
    }

    // aggregates relayer signatures and burns/mints the token
    function receiveRequest(
        bytes32 _requestHash,
        bytes32 destTokenAddress,
        uint256 amount,
        bytes32 destReceiverAddress,
        uint256 _requestNonce
    ) external onlyGuardian {
        require(
            !processedRequests[_requestHash],
            "This request has already been processed"
        );

        bytes32 requestHash = keccak256(abi.encodePacked(destTokenAddress,
                                                         amount,
                                                         destReceiverAddress,
                                                         _requestNonce));

        require(
            _requestHash == requestHash,
            "Hash does not match the data"
        );
        
        Request storage request = pendingRequests[requestHash];

        require(!request.signatures[msg.sender], "Already signed this request");

        request.signatures[msg.sender] = true;
        request.signatureCount++;

        emit RequestSigned(requestHash, msg.sender);

        if (request.signatureCount >= signatureThreshold) {
            processedRequests[requestHash] = true;
            delete pendingRequests[requestHash];

            // returns the locked tokens
            IERC20 token = IERC20(bytes32ToAddress(destTokenAddress));

            token.transfer(bytes32ToAddress(destReceiverAddress), amount);
            emit RequestProcessed(requestHash);
        }
    }

    function addGuardian() external onlyGuardian {
        // TODO
    }

    function removeGuardian() external onlyGuardian {
        // TODO
    }
}