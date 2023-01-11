// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract CommitBargain {
    using SafeMath for uint;

    uint public state = 0; // 0: Registration, 1: Encrypted commitment, 2: Commitment, 3: Proposal, 4: Evaluation
    uint constant M = 10**40; // Used to allow more ways of commiting to the same amount
    uint public numberAgents;
    mapping (address => bool) private hasAccess;
    mapping (address => uint) private userIndex;
    uint[] private accountBalance;
    bool[] private activeInState;
    uint numberActiveInState = 0;
    bytes32[] private encryptedCommitment;
    uint[] private actualCommitment;
    uint[] public evaluationOrder;
    int256[] public proposal;
    uint public currentPosition = 0;

    modifier inState (uint _state) { // Checks that the contract is in the correct state to run the desired function
        require(state == _state, "Action not available in the current state.");
        _;
    }

    modifier onlyUsers { // Checks that the user is registered 
        require(hasAccess[msg.sender], "User not registered.");
        _;
    }

    modifier onlycurrentUser { 
        require(userIndex[msg.sender] == evaluationOrder[currentPosition], "Action not available to the current user.");
        _;
    }

    function registerAddresses (address[] memory _addresses) public inState(0) {
        numberAgents = _addresses.length;
        accountBalance = new uint[](numberAgents); // Initially 0 for each
        activeInState = new bool[](numberAgents); // Initially false for each
        encryptedCommitment = new bytes32[](numberAgents);
        actualCommitment = new uint[](numberAgents);
        evaluationOrder = new uint[](numberAgents);
        for (uint i = 0; i < numberAgents; i++) {
            hasAccess[_addresses[i]] = true;
            userIndex[_addresses[i]] = i;
        }
        state ++;
    }

    function submitEncryptedCommitment (bytes32 _encryptedCommitment) public inState(1) onlyUsers {
        /*
            To compute the encrypted version of 200 = 0xe71fac6fb785942cc6c6...:
            1) Convert 200 to hexadecimal, base 16: 200_{10} = c8_{16}
            2) Pad with zeros at the start to make it 64 digits long: 000...000c8 (here, 62 zeros added)
            3) Compute Keccak-256 of this, keccak-256(000...000c8) = e71fac6fb785942cc6c6...
            4) Add 0x at the start: 0xe71fac6fb785942cc6c6...
        */
        uint i = userIndex[msg.sender];
        encryptedCommitment[i] = _encryptedCommitment;
        registerActivity(i);
    }

    function submitActualCommitment (uint _actualCommitment) public payable inState(2) onlyUsers { 
        /*
            Say the user has submitted encrypted commitment H, and now submits C with deposit D.
            First, check that the hash of C matches H.
            Thereafter, compute C' = C modulo M, and check that D >= C'.

            For instance, if the user wants to commit to C' = 5 and M = 10, they can achieve this in many ways:
            C = 15, C = 25, and C = 105 would for instance all work.
            In this way, there are many encrypted commitments (e.g. hash(15), hash(25), hash(105)) 
            that correspond to the actual commitment C' = 5.
        */
        uint i = userIndex[msg.sender];
        require(encryptedCommitment[i] == keccak256(abi.encode(_actualCommitment)), "Commitment does not match encrypted commitment.");
        uint c = _actualCommitment.mod(M); 
        require(msg.value >= c, "Insufficient deposit.");
        accountBalance[i].add(msg.value);
        actualCommitment[i] = c;
        registerActivity(i);
    }

    function submitProposal (int256[] memory _proposal) public payable inState(3) onlyUsers onlycurrentUser {
        /*
            The proposer is at position 0 in the order.
            If the proposal is such that the proposer has to transfer funds,
            then sufficient deposits have to be provided from the outset.
        */
        uint i = evaluationOrder[0];
        require(int256(msg.value) >= - _proposal[i], "Insufficient deposit.");
        require(addsToZero(_proposal), "Proposal must add to zero.");
        accountBalance[i].add(msg.value);
        proposal = _proposal;
        state ++;
        currentPosition ++;
    }

    function evaluateProposal (bool _accept) public payable inState(4) onlyUsers onlycurrentUser {
        uint i = evaluationOrder[currentPosition];
        
        // Rejection---revert to state 3 and select a new order
        if (!_accept) {
            state = 3;
            randomizeOrder();
            currentPosition = 0;
        }

        // Insufficient funds
        require(int256(msg.value) >= - proposal[i], "Insufficient deposit."); 
        
        // Acceptance
        accountBalance[i].add(msg.value);
        currentPosition ++;

        // All have accepted
        if (currentPosition == numberAgents) {
            state ++;
            /*
                This is the end of the mechanism.
                The funds committed can now be used to purchase the corresponding abatement technology, e.g.
                    accountBalance[i].sub(actualCommitment[i]);
                    purchaseTechnology(i, actualCommitment[i]);
                Once the technology has been activated through a smart contract, the remaining funds are transferred, e.g.
                    if (activatedTechnology(i)) {
                        uint amount = accountBalance[i];
                        accountBalance[i] = 0;
                        payable(msg.sender).transfer(amount);
                    }
            */
        }
    }

    function randomizeOrder () internal { 
        /*
            Use the Fischer-Yates shuffle to create a random permutation of [0, ..., n-1].
        */
        for (uint i = 0; i < numberAgents; i++) {
            evaluationOrder[i] = i;
        }
        uint j;
        for (uint i = 0; i < numberAgents; i++) { 
            j = random(i, numberAgents);
            (evaluationOrder[i], evaluationOrder[j]) = (evaluationOrder[j], evaluationOrder[i]);
        }
    }

    function random (uint _low, uint _high) view internal returns (uint) { 
        /*
            Creates a "random" number blockHash that is rescaled to return 
                _low + blockHash % (_high - _low),
            which is an integer in [_low, _high)
        */
        uint range = _high.sub(_low);
        uint blockHash = uint(keccak256(abi.encodePacked(_low, _high, block.difficulty, block.number)));
        return _low.add(blockHash.mod(range));
    }

    function addsToZero (int[] memory _array) view internal returns (bool) { 
        int256 total = 0;
        for (uint i = 0; i < numberAgents; i++) {
            total += _array[i];
        }
        return (total == 0); // Returns true if the proposal is valid (adds to zero)
    }

    function registerActivity (uint i) internal {
        if (!activeInState[i]) {
            activeInState[i] = true;
            numberActiveInState ++;
            if (numberActiveInState == numberAgents) {
                numberActiveInState = 0;
                bool[] memory resetActions = new bool[](numberAgents);
                activeInState = resetActions;
                state ++;
                if (state == 3) {
                    randomizeOrder();
                }
            }
        }
    }
}
