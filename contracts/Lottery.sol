// SPDX-License-Identifier: MIT

/* WORKFLOW: /////////////////////////////////////////////////////////////////////////
1. deploy contract
2. 'startLottery(uint256 _ticketsTotal)'
3. 'enterLottery(uint256 _numberTickets)'
    - Can use 'entranceFeeWei(uint256 _numberTickets)' and 'ticketsCanPurchase()' to help determine value to input for tickets and tickets you can purchase, respectively
4. 'createNewSubscription()' -> need a subscription to request random # from chainlink VRF
5. see approximate min amount of LINK to fund subscription w/ in order to request a random # -> 'linkForVrfRequest()'
6. fund subscription w/ LINK token using 'topUpSubscription(uint256 amount)'
    - The contract must own the quantity of LINK you are "topping up"
        - So will need to send some to the contract from a wallet first
7. people enter lottery....... can start entering after step #3
8. 'calculateWinner()' -> this will initiate the following steps
    - 'requestRandomWords()' which initiates the random # request
        - If the subscription hasn't been funded with enough LINK the random # will never be fulfilled
            - I've been needing to fund subscription with ~9 LINK, even though the request only takes ~.25 LINK
            - Can check if request is pending 
                - using 'prendingVrfRequest()' but if there are multiple consumers for the subscription, the request could be due to another contract
                - at https://vrf.chain.link/ and looking for your subscription ID
    - set lottery state to 'CALCULATING_WINNER'
    - 'fullfillRandomWords()' which is returned automatically after 'requestRandomWords()' + block_confirmations
    - close lottery, payout winner
9. If no longer need the VRF subscription, 'cancelSubscription()'
    - This sends all the VRF subscription's LINK back to the contract owner
10. If the contract has any remaining LINK (i.e., you didn't 'topUpSubscription()' with all the LINK you sent the Lottery contract), 'fullLinkWithdraw()'
    - This sends any remaining LINK the contract has back to the contract owner
*/

pragma solidity >=0.6.6 <0.9.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol"; // price feed
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol"; // to fund w/ LINK
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol"; // VRF
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol"; // VRF

// variable syntax: {type} {access modifier} {visibility} {variable name};
// modifier syntax: modifier {name}({args}) {}
// function syntax: function {name}({parameter_list}) {visibility} {modifier} returns ({return type}) {}

contract Lottery is VRFConsumerBaseV2 {
    address public contract_owner;

    /////////////////////////////////////////////////
    // Lottery - variables, enums
    ///////////////////////////////////////////////
    uint256 public entranceFeeUsd = 10; // $ to enter lottery
    uint256 public ticketsTotal;
    uint256 public ticketsRemaining;
    uint256 public ticketsSold;
    address[] public participants;
    uint256 public winnerIndex;
    address public winner;

    // represent lottery states in readable ways but with reference to their index (0, 1, 2) respectively
    enum LOTTERY_STATE {
        OPEN,
        CALCULATING_WINNER,
        CLOSED
    }
    LOTTERY_STATE lotteryState;

    /////////////////////////////////////////////////
    // VRF - variables
    /////////////////////////////////////////////////
    bytes32 keyHash; // determines "gas lane"
    // the gwei gas indicated by key hash (see chainlink docs), use this value to estimate LINK required in "max gas" formula
    // there may be a way to decode "gwei gas" from the "keyHash" but I'm not sure.
    uint256 gweiGasForKeyHash;

    // A reasonable default is 100000, but this value could be different -> higher value will increase LINK requirement
    uint32 callbackGasLimit = 100000;
    // Not sure where this number is in documentation but can back into number using formula and
    // ...the "Max Cost" for your request on https://vrf.chain.link
    uint32 verificationGas = 200000;

    // Can set higher, more confirmations = more costly for random # manipulation by validator
    uint16 requestConfirmations = 3;
    uint32 numWords = 1; // only need 1 in this instance

    // VRF storage parameters
    uint256[] public s_randomWords;
    uint256 public s_requestId;
    uint64 public s_subscriptionId;

    /////////////////////////////////////////////////
    // Interfaces
    ///////////////////////////////////////////////
    AggregatorV3Interface PRICEFEED_ETHUSD;
    AggregatorV3Interface PRICEFEED_LINKETH;
    LinkTokenInterface LINKTOKEN;
    VRFCoordinatorV2Interface COORDINATOR;

    /////////////////////////////////////////////////
    // Events
    ///////////////////////////////////////////////

    event ReturnedRandomness(uint256[] randomWords);

    constructor(
        address _priceFeedEthUsd,
        address _priceFeedLinkEth,
        address _linkToken,
        address _vrfCoordinator,
        bytes32 _vrfKeyHash,
        uint256 _gweiGasForKeyHash
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        PRICEFEED_ETHUSD = AggregatorV3Interface(_priceFeedEthUsd);
        PRICEFEED_LINKETH = AggregatorV3Interface(_priceFeedLinkEth);
        LINKTOKEN = LinkTokenInterface(_linkToken);
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _vrfKeyHash;
        gweiGasForKeyHash = _gweiGasForKeyHash;
        contract_owner = msg.sender;
        lotteryState = LOTTERY_STATE.CLOSED;
        // If testnet/mainnet is used can create subscription w/ constructor
        // createNewSubscription();
    }

    /////////////////////////////////////////////////
    // Lottery user - functions
    /////////////////////////////////////////////////

    // Use to easily determine what value of Wei to input for desired ticket quantity
    function entranceFeeWei(uint256 _numberTickets)
        public
        view
        returns (uint256)
    {
        uint256 entryFeeUsd = entranceFeeUsd * _numberTickets;
        uint256 entryFeeWeiDecimal = entryFeeUsd * 1e18;
        // Could return zero if entry fee is so small that numerator < denominator
        uint256 entryFeeWei = (entryFeeWeiDecimal * 1e18) / ethPriceUsd();
        return entryFeeWei;
    }

    // Lesser of 'remainingTickets' and tickets can buy with ETH balance
    function ticketsCanPurchase() public view returns (uint256) {
        // rounds down to whole number
        uint256 maxTickets = msg.sender.balance / entranceFeeWei(1);
        if (ticketsRemaining <= maxTickets) {
            return ticketsRemaining;
        } else {
            return maxTickets;
        }
    }

    function enterLottery(uint256 _numberTickets) public payable {
        require(
            lotteryState == LOTTERY_STATE.OPEN,
            "Lottery isn't currently open."
        );
        require(
            _numberTickets <= ticketsCanPurchase(),
            "Can't purchase that many tickets. Check 'ticketsCanPurchase' to see max tickets you can purchase based on balance and remaining tickets."
        );
        uint256 neededCost = entranceFeeWei(_numberTickets);
        require(
            msg.value == neededCost,
            "Incorrect amount of ETH, check 'entranceFeeWei' to determine correct amount."
        );
        // add address to participants array for each ticket purchased
        for (
            uint256 ticketsPurchased = 0;
            ticketsPurchased < _numberTickets;
            ticketsPurchased++
        ) {
            participants.push(msg.sender);
            ticketsRemaining -= 1;
            ticketsSold += 1;
        }
    }

    // lottery balance in ETH -> the potential winnings
    function lotteryBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /////////////////////////////////////////////////
    // Lottery state - functions
    /////////////////////////////////////////////////

    // start new lottery and reset variables from previous lottery if there was one
    function startLottery(uint256 _ticketsTotal) public onlyOwner {
        require(
            lotteryState == LOTTERY_STATE.CLOSED,
            "Current lottery must end before starting a new one."
        );
        lotteryState = LOTTERY_STATE.OPEN;
        ticketsTotal = _ticketsTotal;
        ticketsRemaining = _ticketsTotal;
        ticketsSold = 0;
        winner = address(0);
        winnerIndex = 0;
        participants = new address[](0);
        s_randomWords = new uint256[](0);
        s_requestId = 0;
    }

    // Calculates winner, uses VRF Coordinator requestRandomWords to initiate retrieval of random #
    // Lottery will automatically be closed and paid out once random # is retrieved -> automatic due to 'fulfillRandomWords'
    function calculateWinner() public onlyOwner {
        lotteryState = LOTTERY_STATE.CALCULATING_WINNER;
        // Assumes the subscription is funded sufficiently.
        // Will revert if subscription is not set and funded.
        s_requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
    }

    // Returns the Random #, ends lottery, and pays out winner
    // Will automatically be fulfilled after 'requestRandomWords' + block confirmations
    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] memory randomWords
    ) internal override {
        s_randomWords = randomWords;
        winnerIndex = randomWords[0] % ticketsSold;
        winner = participants[winnerIndex];
        payable(winner).transfer(address(this).balance);
        lotteryState = LOTTERY_STATE.CLOSED;
        emit ReturnedRandomness(randomWords);
    }

    /////////////////////////////////////////////////
    // VRF Subscription Mgmt & Funding - functions
    /////////////////////////////////////////////////

    function createNewSubscription() public onlyOwner {
        s_subscriptionId = COORDINATOR.createSubscription();
        // Add this contract as a consumer of its own subscription.
        COORDINATOR.addConsumer(s_subscriptionId, address(this));
    }

    // Cancel the subscription and send the remaining LINK to the owner
    function cancelSubscription() external onlyOwner {
        COORDINATOR.cancelSubscription(s_subscriptionId, contract_owner);
        s_subscriptionId = 0;
    }

    // Need to fund subscription to "request random words"
    // Contract needs to own LINK to use this function
    // 1000000000000000000 = 1 LINK
    function topUpSubscription(uint256 amount) external onlyOwner {
        LINKTOKEN.transferAndCall(
            address(COORDINATOR),
            amount,
            abi.encode(s_subscriptionId)
        );
    }

    // Transfer this contract's LINK tokens to the owner
    function fullLinkWithdraw() external onlyOwner {
        uint256 contractBalance = LINKTOKEN.balanceOf(address(this));
        LINKTOKEN.transfer(contract_owner, contractBalance);
    }

    // returns LINK balance of the subscription in juels (18 decimal, aka the wei of LINK)
    function subscriptionBalance() external view onlyOwner returns (uint256) {
        (uint96 sub_balance, , , ) = COORDINATOR.getSubscription(
            s_subscriptionId
        );
        return sub_balance;
    }

    // returns approximate LINK needed to fund subscription and make a VRF request (18 decimal format)
    // this is just max cost, actual cost tends to be MUCH lower
    // however, the request will stay pending for 24hrs if the subscription is not funded with the potential "max cost"
    function linkForVrfRequest() public view onlyOwner returns (uint256) {
        // max gas = (gas lane in gwei * (callback gas limit + max verification gas)) + 0.25LINK premium
        // have to convert some of the gas costs from ETH to LINK to get max gas in LINK terms
        uint256 gas_wei = (gweiGasForKeyHash *
            (callbackGasLimit + verificationGas)) * 1e9;
        uint256 link_needed = (gas_wei * 1e18) / linkPriceEth();
        return link_needed;
    }

    // returns true/false if there is pending request for random words
    // if pending for multiple minutes is likely due to insufficient LINK funded to subscription -> will timeout after 24hr
    function prendingVrfRequest() external view returns (bool) {
        return COORDINATOR.pendingRequestExists(s_subscriptionId);
    }

    /////////////////////////////////////////////////
    // Chainlink price feed - functions
    /////////////////////////////////////////////////

    // returns cost of 1 ETH in USD (18 decimal format)
    // before decimal adjust = 125216035738
    // after decimal adjust = 1252160357380000000000
    function ethPriceUsd() public view returns (uint256) {
        uint8 price_decimals = PRICEFEED_ETHUSD.decimals();
        (, int256 price, , , ) = PRICEFEED_ETHUSD.latestRoundData();
        // return in 18 decimal format
        return uint256(price) * (10**(18 - price_decimals));
    }

    // returns cost of 1 LINK in ETH (18 decimal format)
    function linkPriceEth() public view returns (uint256) {
        uint8 price_decimals = PRICEFEED_LINKETH.decimals();
        (, int256 price, , , ) = PRICEFEED_LINKETH.latestRoundData();
        // return in 18 decimal format
        return uint256(price) * (10**(18 - price_decimals));
    }

    /////////////////////////////////////////////////
    // Modifiers
    /////////////////////////////////////////////////

    modifier onlyOwner() {
        require(msg.sender == contract_owner);
        _;
    }
}
