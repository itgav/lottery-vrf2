from brownie import (
    config,
    interface,
    network,
    Lottery,
    # Mocks
    EthUsdMockV3Aggregator,
    LinkEthMockV3Aggregator,
    VRFCoordinatorV2Mock,
)
from scripts.helpful_scripts import (
    get_account,
    deploy_mocks,
    listen_for_vrf,
    LOCAL_ENV,
)
import time


def main():
    deploy()
    start_lottery(10)  # (_#tickets)
    enter_lottery(get_account(), 1)  # (_accountEntering, _ticketsPurchasing)
    create_and_fund_vrf(11)  # (_LinkTokens)
    try:
        end_lottery()
        returnLink()
    except:
        print(
            "Error: likely due to 'end_lottery()' function, will proceed to 'returnLink()' so that we don't have LINK left in contract/subscription"
        )
        returnLink()


# if deploying mock: use 'MockConsumer.sol' and 'VRFCoordinatorV2Mock.sol' to get the random #, then will use 'Lottery.sol' for remaining lotto functions
# if deploying on testnet: use 'Lottery.sol' to get random # and normal lotto function, and use 'LinkTokenInterface.sol' to help fund lotto with LINK
# deploy Lottery and get relevant variables
def deploy():
    active_network = network.show_active()
    print(f"Active network: {active_network}")
    account = get_account()

    if active_network in LOCAL_ENV:
        deploy_mocks()
        eth_usd_price_feed = EthUsdMockV3Aggregator[-1].address
        link_eth_price_feed = LinkEthMockV3Aggregator[-1].address
        vrf_coord_address = VRFCoordinatorV2Mock[-1].address
    else:
        network.priority_fee("1 gwei")  # optional, raise gas price to reduce delays
        eth_usd_price_feed = config["networks"][active_network]["eth_usd_price_feed"]
        link_eth_price_feed = config["networks"][active_network]["link_eth_price_feed"]
        vrf_coord_address = config["networks"][active_network]["vrf_coordinator_address"]

    link_token_address = config["networks"][active_network]["link_address"]
    vrf_key_hash = config["networks"][active_network]["vrf_key_hash"]
    gwei_for_key_hash = config["networks"][active_network]["gwei_for_key_hash"]

    print("Deploy Lottery")
    # lottery constructor: _priceFeedEthUsd, _priceFeedLinkEth, _linkToken, _vrfCoordinator, _vrfKeyHash, _gweiGasForKeyHash
    lottery_contract = Lottery.deploy(
        eth_usd_price_feed,
        link_eth_price_feed,
        link_token_address,
        vrf_coord_address,
        vrf_key_hash,
        gwei_for_key_hash,
        {"from": account},
    )
    time.sleep(5)


def start_lottery(tickets):
    account = get_account()
    lottery_contract = Lottery[-1]
    print("Start Lottery")
    lottery_contract.startLottery(tickets, {"from": account})
    time.sleep(10)


def end_lottery():
    active_network = network.show_active()
    account = get_account()
    lottery_contract = Lottery[-1]
    if active_network in LOCAL_ENV:
        mock_coordinator = VRFCoordinatorV2Mock[-1]
        print("Get Subscription ID")
        sub_id = mock_coordinator.getCurrentSubId({"from": account})
        # sub_id.wait(1)
        print("Request Random #")
        # goerli key_hash, can use any for development
        key_hash = config["networks"]["goerli"]["vrf_key_hash"]
        gas_lim = 1e5  # 1e5 is recommended
        # requestRandomWords(_keyHash, _subId, _minimumRequestConfirmations, _callbackGasLimit, _numWords)
        request_tx = mock_coordinator.requestRandomWords(key_hash, sub_id, 3, gas_lim, 1, {"from": account})
        request_tx.wait(1)
        request_id = request_tx.events["RandomWordsRequested"]["requestId"]
        print("Fulfill Random #")
        fulfill_tx = mock_coordinator.fulfillRandomWords(request_id, lottery_contract.address, {"from": account})
        fulfill_tx.wait(1)
        random_number = lottery_contract.s_randomWords(0)
        tickets_sold = lottery_contract.ticketsSold()
        winner = lottery_contract.winner()
        print(f"Random number is {random_number}")
        print(f"Tickets sold: {tickets_sold}")
        print(f"Winner: {winner}")
    else:
        print("Calculate winner / request random # / fulfill random # / payout winner")
        lottery_contract.calculateWinner({"from": account})
        print("Wait for random # to come back")
        request_id = lottery_contract.s_requestId({"from": account})
        # listen_for_vrf(vrf_request_id, wait_interval, total_wait_time)
        listen_for_vrf(request_id, 15, 300)
        print("Return Random #")
        try:
            random_number = lottery_contract.s_randomWords(0)
            tickets_sold = lottery_contract.ticketsSold()
            winner = lottery_contract.winner()
            print(f"Random number is {random_number}")
            print(f"Tickets sold: {tickets_sold}")
            print(f"Winner: {winner}")
        except:
            print("Error: likely due to calling the random #, probably hasn't been fulfilled yet.")
            print(
                "If random # not fulfilled: either need to wait longer, or subscription hasn't been funded w/ enough LINK"
            )

    time.sleep(5)


def enter_lottery(account, tickets):
    lottery_contract = Lottery[-1]
    ticket_cost = lottery_contract.entranceFeeWei(tickets, {"from": account})
    print("Enter Lottery")
    lottery_contract.enterLottery(tickets, {"from": account, "value": ticket_cost})
    time.sleep(5)


def create_and_fund_vrf(link_quantity):
    active_network = network.show_active()
    account = get_account()
    lottery_contract = Lottery[-1]
    # 1000000000000000000 (1e18) = 1 LINK
    # for mock, must be greater than _baseFee -> so I read
    adj_link_quantity = link_quantity * 1e18
    time.sleep(5)

    if active_network in LOCAL_ENV:
        mock_coordinator = VRFCoordinatorV2Mock[-1]
        print("Create VRF Subscription")
        sub_id_tx = mock_coordinator.createSubscription({"from": account})
        sub_id = sub_id_tx.events["SubscriptionCreated"]["subId"]
        print(f"Subscription ID: {sub_id}")
        print("Fund VRF subscription")
        mock_coordinator.fundSubscription(sub_id, adj_link_quantity, {"from": account})
    else:
        print("Create VRF Subscription")
        lottery_contract.createNewSubscription({"from": account})
        print("Fund Lottery Contract")
        # transfer LINK from account to lottery_contract
        fund_lottery = interface.LinkTokenInterface(config["networks"][active_network]["link_address"]).transfer(
            lottery_contract.address, adj_link_quantity, {"from": account}
        )
        print("Fund VRF Subscription")
        # lottery_contract funds VRF subscription w/ LINK
        lottery_contract.topUpSubscription(adj_link_quantity, {"from": account})

    time.sleep(5)


def returnLink():
    active_network = network.show_active()
    account = get_account()
    lottery_contract = Lottery[-1]
    if active_network in LOCAL_ENV:
        print("Cancel VRF Subscription")
        mock_coordinator = VRFCoordinatorV2Mock[-1]
        sub_id = mock_coordinator.getCurrentSubId({"from": account})
        mock_coordinator.cancelSubscription(sub_id, account)

    else:
        print("Cancel VRF Subscription")
        lottery_contract.cancelSubscription({"from": account})
        time.sleep(5)
        lottery_link_balance = interface.LinkTokenInterface(
            config["networks"][active_network]["link_address"]
        ).balanceOf(lottery_contract.address, {"from": account})
        if lottery_link_balance > 0:
            print(f"LINK still in Lottery contract: {lottery_link_balance}")
            print("Withdraw remaining LINK from contract")
            lottery_contract.fullWithdraw({"from": account})
        else:
            print("No LINK remain in Lottery contract")

    time.sleep(5)
