from brownie import (
    network,
    config,
    accounts,
    EthUsdMockV3Aggregator,
    LinkEthMockV3Aggregator,
    VRFCoordinatorV2Mock,
)
import json
from web3 import Web3
import time
import os  # used to get current working directory, which ultimately gives us VRFCoordinator ABI path

LOCAL_ENV = ["development"]
# Price and decimals for MockV3Aggregator 'LatestRoundData' to return ETH/USD price and LINK/ETH price
ETH_PRICE_USD = 125200000000
ETH_USD_DECIMALS = 8
LINK_PRICE_ETH = 5190508900000000
LINK_ETH_DECIMALS = 18

# if deploying on a dev chain can use account[0], otherwise pull from config
# get error for account[0] if not dev chain because no default account[0]
def get_account():
    if network.show_active() in LOCAL_ENV:
        return accounts[0]
    else:
        return accounts.add(config["wallets"]["from_key"])


# deploy mock pricefeed, VRF coordinator, and VRF consumer
def deploy_mocks():
    account = get_account()
    print("Deploying Mocks")
    print("Deploy ETH/USD MockV3Aggregator for mock ETH/USD price")
    if len(EthUsdMockV3Aggregator) <= 0:
        EthUsdMockV3Aggregator.deploy(ETH_USD_DECIMALS, ETH_PRICE_USD, {"from": account})
    print("Deploy LINK/ETH MockV3Aggregator for mock LINK/ETH price")
    if len(LinkEthMockV3Aggregator) <= 0:
        LinkEthMockV3Aggregator.deploy(LINK_ETH_DECIMALS, LINK_PRICE_ETH, {"from": account})
    # VRFCoordinatorV2Mock.deploy(_baseFee, _gasPriceLink, {from: account})
    # can see more about _baseFee and _gasPriceLink in the chainlink docs
    print("Deploy Mock VRF Coordinator")
    if len(VRFCoordinatorV2Mock) <= 0:
        VRFCoordinatorV2Mock.deploy(25 * 1e16, 1e10, {"from": account})
    time.sleep(5)


# listen to VRF coordinator events to see if our Random # has been fulfilled
def listen_for_vrf(vrf_request_id, wait_interval, total_wait_time):
    active_network = network.show_active()
    infura_key = config["other"]["infura_key"]
    infura_url = f"https://goerli.infura.io/v3/{infura_key}"
    web3 = Web3(Web3.HTTPProvider(infura_url))

    # Trying to dynamically get the file path of ABI file of the VRFCoordinator.sol contract
    remove_path = "\\scripts"
    abi_partial_path = "\\build\\contracts\\VRFCoordinatorV2.json"
    project_path = os.getcwd().split(remove_path)[0]
    abi_path = project_path + abi_partial_path
    print(abi_path)
    # abi_path = "C:/Users/Gavin/solidity_demos/test_vrf2/build/contracts/VRFCoordinatorV2.json"
    with open(abi_path) as f:
        info_json = json.load(f)
    coordinator_abi = info_json["abi"]

    # set VRF Coordinator contract variable so that we know which contract to filter events for
    coordinator_address = config["networks"][active_network]["vrf_coordinator_address"]
    coordinator_contract = web3.eth.contract(address=coordinator_address, abi=coordinator_abi)

    # filter for the coordinator contract, 'RandomWordsFulfilled' event, and where the requestId matches ours
    event_filter = coordinator_contract.events.RandomWordsFulfilled.createFilter(
        fromBlock="latest",
        argument_filters={"requestId": vrf_request_id},
    )

    # rounds down to whole number
    # 'total_wait_time' ignores computation time
    max_re_checks = int(total_wait_time / wait_interval)
    check_event_count = 0
    event_fulfilled = False

    while event_fulfilled == False and check_event_count < max_re_checks:
        # if no events then just pass, add to event count, and wait to re-check
        if event_filter.get_all_entries() == []:
            pass
        else:
            # 'get_all_entries()' returns a list matching request, so want cycle through them to see if any have the UID of request ID we're looking for
            # ... this shouldn't be an issue since we're already filtered for our requestId in the 'event_filter' but want to experiment with 'while' loops
            # could make more efficient by only checking the new entries everytime
            # ... to my understanding, to do this need to call get_all_entries() on the first go round, then get_new_entries() on the proceeding
            for event in event_filter.get_all_entries():
                # convert from 'AttributeDict' to 'Dict' and then grab requestId
                event_request_id = dict(event)["args"]["requestId"]
                # if we found our request Id then the random # has been fulfilled
                if event_request_id == vrf_request_id:
                    event_fulfilled = True
                else:
                    pass

        check_event_count += 1
        time.sleep(wait_interval)

    if event_fulfilled == True:
        return print("Random # Fulfilled")
    else:
        return print(
            "Random # hasn't been fulfilled. Either need more LINK in subscription, or just taking longer than expected."
        )
