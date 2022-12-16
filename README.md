# Lottery Contract using Chainlink VRF 2
- Loosely inspired by Patrick Collins' Solidity in Python tutorial, so may see some similar layouts
    - I did all lessons prior to the Lottery one and then decided to figure out the Lottery on my own to help w/ the learning.

## Basic Lottery Workflow
- Basic workflow to deploy the Lottery, buy tickets, end Lottery, and payout the winner
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