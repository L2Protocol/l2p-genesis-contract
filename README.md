# l2p-genesis-contracts

This repo hold all the genesis contracts on L2 Protocol Chain. More details in [doc-site](https://docs.bnbchain.org/docs/learn/system-contract).

## Prepare

Install node.js dependency:
```shell script
npm install
```

Install foundry:
```shell script
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge install --no-git foundry-rs/forge-std@v1.16.2
```

Install poetry:
```shell script
curl -sSL https://install.python-poetry.org | python3 -
poetry install
```

Tips: You can manage multi version of Node:
```Shell
## Install nvm and node
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/refs/tags/v0.40.5/install.sh | bash
nvm install 18.17.0 && nvm use 18.17.0
```

## Unit test

You can get a free archive node endpoint from https://nodereal.io/.

Run forge test:
```shell script
forge test --fork-url ${archive_node_rpc}
```

## Flatten all system contracts

```shell script
bash scripts/flatten.sh
```

All system contracts will be flattened and output into `${workspace}/contracts/flattened/`.

## How to generate genesis file

1. Edit `init_holders.js` file to alloc the initial L2P holder.
2. Edit `validators.js` file to alloc the initial validator set.
3. Edit system contracts setting as needed.
4. Run `node scripts/generate-genesis.js` will generate genesis.json

## How to generate mainnet/testnet/dev genesis file

```shell 
# build mainnet genesis file & clean
npm run generate:mainnet && poetry run python -m scripts.generate recover

# build testnet genesis file & clean
npm run generate:testnet && poetry run python -m scripts.generate recover

# build local dev-net genesis file & clean
npm run generate:dev && poetry run python -m scripts.generate recover
```
Check the `genesis.json` file, and you can get the exact compiled bytecode for different network.
(`poetry run python -m scripts.generate --help ` for more details)
```
# you can verify the bytecode in genesis.json with solc, take ./contracts/StakeHub.sol for example:
solc-select use 0.8.17
solc --optimize --optimize-runs 200 --abi --metadata-hash none --bin-runtime ./contracts/StakeHub.sol --base-path . --include-path ./node_modules/ -o output
```

You can refer to `generate:dev` in `package.json` for more details about how to custom params for local dev-net.

## How to create a validator

`scripts/create-validator` calls `StakeHub.createValidator`. It signs locally with ethers
and broadcasts a raw transaction, so the node needs no unlocked account and no `personal`
API. Everything is configured through its own `.env`, so the script itself is not edited.

1. Create a BLS key and generate the ownership proof:
```shell script
geth bls account new  --datadir ./bls --blspassword ./bls-password.txt
geth bls account list --datadir ./bls --blspassword ./bls-password.txt
geth bls account generate-proof --datadir ./bls --blspassword ./bls-password.txt \
     --chain-id 12216 <operator address> <BLS pubkey>
```

2. Fill in the settings:
```shell script
cp scripts/create-validator/.env.example scripts/create-validator/.env
```
`.env.example` documents every variable. The operator address is derived from
`OPERATOR_PRIVATE_KEY` and must match the address the BLS proof was generated for.
`RPC_L2P` falls back to the repo root `.env` if it is not set there.

3. Run it:
```shell script
node scripts/create-validator --dry-run   # validate + simulate, sends nothing
node scripts/create-validator             # sign and broadcast
```

Any variable can be overridden for a single run:
```shell script
VALIDATOR_MONIKER=Val02 node scripts/create-validator --dry-run
```

The script refuses to send if the node's chain id differs from `CHAIN_ID`, because the BLS
proof is bound to the chain id. Reverts are decoded against the StakeHub, StakeCredit and
GovToken ABIs, so a failed simulation reports the actual custom error.

The transaction value is `minSelfDelegationL2P + LOCK_AMOUNT` (7,000,000 + 3,500 L2P with
the current genesis settings), both read from the chain, unless `VALIDATOR_SELF_DELEGATION`
is set to a higher amount.

## update ABI files

```bash
forge inspect {{contract}} abi > abi/{{contract}}.abi
```

## How to update contract interface for test

```shell script
// get metadata
forge build

// generate interface
cast interface ${workspace}/out/{contract_name}.sol/${contract_name}.json -p ^0.8.0 -n ${contract_name} > ${workspace}/test/utils/interface/I${contract_name}.sol
```

## License

The library is licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0),
also included in our repository in the [LICENSE](LICENSE) file.
