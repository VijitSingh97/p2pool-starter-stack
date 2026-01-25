#!/usr/bin/env bash

# load values we need to configure
monero_node_username=$(jq -r .monero.node_username config.json)
monero_node_password=$(jq -r .monero.node_password config.json)
monero_wallet_address=$(jq -r .monero.wallet_address config.json)
monero_onion_address=$(docker exec tor cat /var/lib/tor/monero/hostname)

tari_wallet_address=$(jq -r .tari.wallet_address config.json)
tari_onion_address=$(docker exec tor cat /var/lib/tor/tari/hostname)

p2pool_onion_address=$(docker exec tor cat /var/lib/tor/p2pool/hostname)

# configure monero config
sed -i "s/<your_monero_node_username>/$monero_node_username/g" build/monero/bitmonero.conf
sed -i "s/<your_monero_node_password>/$monero_node_password/g" build/monero/bitmonero.conf
sed -i "s/<your_monero_onion_address>/$monero_onion_address/g" build/monero/bitmonero.conf

# configure tari config
tari_onion_address_no_extension=$(echo "$tari_onion_address" | cut -d'.' -f1)
sed -i "s/<your_tari_onion_address_no_extension>/$tari_onion_address_no_extension/g" build/tari/config.toml

# configure p2pool config
sed -i "s/<your_monero_node_username>/$monero_node_username/g" docker-compose.yml
sed -i "s/<your_monero_node_password>/$monero_node_password/g" docker-compose.yml
sed -i "s/<your_monero_wallet_address>/$monero_wallet_address/g" docker-compose.yml
sed -i "s/<your_tari_wallet_address>/$tari_wallet_address/g" docker-compose.yml
sed -i "s/<your_p2pool_onion_address>/$p2pool_onion_address/g" docker-compose.yml

# make data directories for stack
mkdir -p data/monero
mkdir -p data/p2pool
mkdir -p data/tari

