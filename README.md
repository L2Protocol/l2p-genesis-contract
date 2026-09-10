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

## How to deploy ENS and the .l2p TLD

The `ENSRegistry` is placed in genesis at `0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e`, with the
root node (`0x0`) owned by the address passed as `--ensRegistryOwner`. Everything else is deployed
as regular transactions by `foundry-script/DeployENS.s.sol`, which must be run from that same
root-owning account.

The ENS sources under `contracts/ens/` are vendored from
[ens-contracts](https://github.com/ensdomains/ens-contracts) v1.7.0. Two files are not upstream:

- `ethregistrar/L2PRegistrarController.sol` is `ETHRegistrarController.sol` with the hardcoded
  `.eth` TLD replaced by `.l2p` (`L2P_NODE` = `namehash("l2p")` and the reverse-record suffix).
  Upstream hardcodes the TLD, so a copy is unavoidable; keep the diff to those lines so it stays
  easy to rebase.
- `ethregistrar/L2PPriceOracle.sol` replaces upstream's `StablePriceOracle` /
  `ExponentialPremiumPriceOracle` pair. Those price names in USD and divide by a Chainlink feed,
  which this chain does not have. This one holds fixed yearly prices in L2P and skips the
  conversion; the premium decay for expired names is upstream's, unchanged. Upstream's
  `DummyOracle` is not vendored at all, because its price setter is unauthenticated.

`NameWrapper` is deliberately not deployed: it hardcodes `.eth` in more places and the v1.7
controller talks to `BaseRegistrarImplementation` directly.

### Deploying

```shell script
export RPC_L2P=https://...
export DEPLOYER_PRIVATE_KEY=...       # must own the ENS root node, 0x prefix optional
forge script DeployENS --rpc-url $RPC_L2P --broadcast \
  --priority-gas-price 1gwei --with-gas-price 1gwei
```

Run without `--broadcast` first for a dry run. The script reverts up front if the sender does not
own the root node, and asserts the full wiring at the end.

The gas price flags are needed because the chain enforces a minimum gas price (`cast gas-price`
reports `100000000`, i.e. 0.1 gwei) while reporting a zero base fee, so Foundry's own estimate comes
out at 1 wei and every transaction is rejected with `transaction gas price below minimum`. Nothing is
sent when that happens, so it is safe to simply retry with the flags.

Optional settings, all with defaults:

| Variable | Default | Meaning |
|---|---|---|
| `ENS_REGISTRY` | `0x0000…2e1e` | The registry from genesis |
| `ENS_OWNER` | the deployer | Receives ownership of every contract at the end |
| `RENT_L2P_3_LETTER` | `640` | Yearly price for 3-character names, in whole L2P |
| `RENT_L2P_4_LETTER` | `160` | Yearly price for 4-character names, in whole L2P |
| `RENT_L2P_5_LETTER` | `5` | Yearly price for names of 5 characters and up, in whole L2P |
| `MIN_COMMITMENT_AGE` | `60` | Seconds between `commit` and `register` |
| `MAX_COMMITMENT_AGE` | `86400` | Seconds after which a commitment expires |
| `START_PREMIUM_L2P` | `100000` | Starting premium of the expiry auction, in whole L2P |
| `PREMIUM_TOTAL_DAYS` | `21` | Days over which that premium decays to zero |
| `BATCH_GATEWAY_URLS` | empty | Comma-separated CCIP-read gateways for the UniversalResolver |

Prices are fixed amounts of L2P per year, with no price feed involved. A shorter or longer
registration is charged pro rata: `yearlyPrice * duration / 365 days`, so a full year costs the
listed amount exactly.

Names that expire become cheaper over time rather than being claimable instantly: for
`PREMIUM_TOTAL_DAYS` after the 90-day grace period, a name carries a premium that starts at
`START_PREMIUM_L2P` and halves each day down to zero.

Both the oracle's prices and the controller's reference to it are immutable, which is how upstream
ENS works. Changing prices therefore means deploying a new `L2PPriceOracle` and a new
`L2PRegistrarController`, then calling `addController` on the base registrar for the new one and
`removeController` for the old. If you would rather be able to adjust prices in place, the oracle
can be made `Ownable` with a setter instead.

### Registering a name

Registration is commit-reveal, and labels shorter than 3 characters are rejected:

```shell script
CTRL=<L2PRegistrarController>
REG="(mynames,$OWNER,31536000,$SECRET,$RESOLVER,[],0,0x00...00)"
cast call  $CTRL "makeCommitment((string,address,uint256,bytes32,address,bytes[],uint8,bytes32))(bytes32)" "$REG"
cast send  $CTRL "commit(bytes32)" $COMMITMENT
# wait MIN_COMMITMENT_AGE seconds
cast send  $CTRL "register((string,address,uint256,bytes32,address,bytes[],uint8,bytes32))" "$REG" --value $PRICE
```

Reverse resolution requires the forward record to point back at the same address, otherwise the
UniversalResolver reverts with `ReverseAddressMismatch`.

### Tests

```shell script
forge test --match-path test/ENSDeployment.t.sol
```

These run against a fresh registry, no fork needed. They drive the deploy script's own steps, so
the tested wiring is the deployed wiring.

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
