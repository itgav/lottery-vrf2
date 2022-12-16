# private key from metamask wallet, will use to pay for transactions
# !!! make sure to append a '0x' to start of private key if not already there
export PRIVATE_KEY=
# !!!! needs to be named 'WEB3_INFURA_PROJECT_ID'
# now called 'API Key' on Infura --> need this for brownie to deploy on a blockchain
# can see list of networks for infura by typing in 'brownie networks list' after inputting below
export WEB3_INFURA_PROJECT_ID=
# brownie will pick up the 'ETHERSCAN_TOKEN' name automatically and use it when 'publish_source=True'
export ETHERSCAN_TOKEN=