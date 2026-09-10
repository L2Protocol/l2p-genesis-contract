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

This walks from a clean checkout to a working `.l2p` registrar that anyone can register names on.
Work through the steps in order. Every step says what you should see before you move on.

|                       |                                              |
|-----------------------|----------------------------------------------|
| ENSRegistry (genesis) | `0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e`  |
| Run as                | `0x1B272dC2635CFBE67116434CdBfD7525f8F5196F` |
| Gas needed            | about 0.02 L2P                               |
| Time                  | about 45 minutes                             |

The `ENSRegistry` is placed in genesis, with the root node (`0x0`) owned by the address passed as
`--ensRegistryOwner`. Everything else is deployed as regular transactions by
`foundry-script/DeployENS.s.sol`, which must be run from that same root-owning account.

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

### Phase 1 — Preparation

Everything in this phase happens on your own machine. Nothing reaches a chain yet, so there is
nothing here you can break.

**Step 1. Check your tooling.** You need Foundry (`forge` and `cast`), Node, and `anvil`, which
ships with Foundry.

```shell script
forge --version
cast --version
node --version
```

You should see forge 1.5.0 or newer (CI pins 1.5.0) and node v18 or newer. If Foundry is missing,
install it with `curl -L https://foundry.paradigm.xyz | bash` followed by `foundryup`.

**Step 2. Go to the repo and install the dependencies.** Every command from here on runs from this
directory.

```shell script
cd ~/Git/l2p-genesis-contract
npm install
```

If `lib/forge-std` is not there, also run `forge install --no-git foundry-rs/forge-std@v1.16.2`.

**Step 3. Compile the contracts.**

```shell script
forge build
```

You should see `Compiler run successful`. Warnings about `modifier-used-only-once` and about
contracts exceeding the EIP-170 limit belong there: those are the existing genesis system contracts,
not the ENS contracts.

**Step 4. Run the tests.** These build the whole ENS stack and register a name, so if they pass, the
wiring is right.

```shell script
forge test --match-path test/ENSDeployment.t.sol
```

You should see `Suite result: ok. 14 passed; 0 failed; 0 skipped`.

Stop here if even one test fails. Do not move on to a real chain; find out why first.

### Phase 2 — Dress rehearsal

You run the real deployment against a throwaway copy of your chain first. That copy boots from the
same `genesis.json`, so whatever works here will work for real. If it goes wrong, close the window
and start over.

**Step 5. Start a local copy of the chain.** This window keeps running, so open a **second terminal**
for the steps after it.

```shell script
anvil --init genesis.json --chain-id 12216 --auto-impersonate
```

You should see `Listening on 127.0.0.1:8545`.

**Step 6. Check that the registry from genesis is there.** The ENSRegistry should already be in
genesis, with your address owning the root node.

```shell script
cast call 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e \
  "owner(bytes32)(address)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  --rpc-url http://127.0.0.1:8545
```

You should see `0x1B272dC2635CFBE67116434CdBfD7525f8F5196F`. If you get `0x0000…0000`, the registry
was not written into genesis correctly; do not continue, check the genesis first.

**Step 7. Deploy the contracts locally.** Locally you do not need the private key: `--unlocked` makes
anvil pretend you have it. On the real chain you will use the key.

```shell script
forge script DeployENS \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast --unlocked \
  --sender 0x1B272dC2635CFBE67116434CdBfD7525f8F5196F
```

You should see the list of deployed addresses, ending in
`ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.`

**Step 8. Stop the rehearsal.** Go to the first terminal and press `Ctrl+C`. The local copy
disappears, which is the point. If step 7 worked, the deployment on the real chain will work too.

### Phase 3 — Deploying for real

From here on, transactions go to the real chain. Read each step through before running it.

**Step 9. Set up your environment.** Create a `.env` in the repo root. It is in `.gitignore`, so it
will not end up in git.

```shell script
RPC_L2P=https://your-rpc-endpoint
DEPLOYER_PRIVATE_KEY=the-key-for-0x1B27...196F
```

The `0x` prefix is allowed but not required; the script accepts both. You do not need to
`source .env` either, because forge reads `.env` from the project root itself.

This is the key that owns the ENS root node. Do not paste it anywhere else, and do not commit it.

**Step 10. Check chain, key, balance and gas price.** Four checks that stop you from deploying to the
wrong chain or with the wrong key.

```shell script
cast chain-id --rpc-url $RPC_L2P
cast wallet address --private-key $DEPLOYER_PRIVATE_KEY
cast balance --ether \
  $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY) \
  --rpc-url $RPC_L2P
cast gas-price --rpc-url $RPC_L2P
```

You should see `12216`, then `0x1B272dC2635CFBE67116434CdBfD7525f8F5196F`, then a balance of at
least 0.1, then `100000000`.

That last value is the chain's minimum gas price (0.1 gwei), and it is why steps 11 and 12 pass a gas
price explicitly. A different chain id means the wrong RPC; a different address means the wrong key.
In both cases: stop and fix it.

**Step 11. Dry run without broadcasting.** Without `--broadcast`, Foundry simulates everything against
the real chain but sends nothing. This is your last safe moment.

```shell script
forge script DeployENS --rpc-url $RPC_L2P \
  --priority-gas-price 1gwei --with-gas-price 1gwei
```

You should see the full list of addresses and, at the bottom,
`SIMULATION COMPLETE. To broadcast these transactions, add --broadcast`.

**Step 12. Deploy.** The same command with `--broadcast`. This takes a few minutes.

```shell script
forge script DeployENS --rpc-url $RPC_L2P --broadcast \
  --priority-gas-price 1gwei --with-gas-price 1gwei
```

You should see `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.`

The two gas flags are not optional on this chain. It reports a zero base fee, so Foundry's own
estimate comes out at 1 wei, while the chain demands at least 0.1 gwei. Without the flags every
transaction is rejected with `transaction gas price below minimum`, and nothing is sent.

You do this once. Running the script again stops immediately with
`sending as … but the ENS root node is owned by …`. That is not a bug but the safeguard: the root
node has been handed to the Root contract by then. It is also how you can tell the deployment has
already run.

**Step 13. Record the addresses.** Take them from the output of step 12. You need them for the checks
below, and for wallets and block explorers.

| Contract                  | Address | What it is for                |
|---------------------------|---------|-------------------------------|
| `Root`                    |         | Manages the TLDs              |
| `BaseRegistrar`           |         | The `.l2p` names as NFTs      |
| `ReverseRegistrar`        |         | Address to name               |
| `DefaultReverseRegistrar` |         | Reverse across all chains     |
| `L2PPriceOracle`          |         | Fixed prices in L2P           |
| `L2PRegistrarController`  |         | Where people register         |
| `PublicResolver`          |         | Addresses and text records    |
| `BatchGatewayProvider`    |         | CCIP-read gateways            |
| `UniversalResolver`       |         | What wallets call             |

The deployment also writes `broadcast/DeployENS.s.sol/12216/run-latest.json`, which holds every
transaction and address.

### Phase 4 — Verifying

The script already verifies itself at the end, but these two checks confirm it independently.

**Step 14. Is the `.l2p` TLD owned by the registrar?** The long number is the namehash of `l2p`; it is
fixed and never changes.

```shell script
cast call 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e \
  "owner(bytes32)(address)" \
  0x81416bb7c03bc54e8597f6c932543fcd87e0649cd943cb29f71df95a7487f431 \
  --rpc-url $RPC_L2P
```

You should see the BaseRegistrar address from step 13.

**Step 15. Are the prices right?**

```shell script
export CTRL=0x...your-controller...

cast call $CTRL "rentPrice(string,uint256)((uint256,uint256))" \
  l2protocol 31536000 --rpc-url $RPC_L2P
```

You should see `(5000000000000000000, 0)`, which is 5 L2P for a year with no premium.

### Phase 5 — Registering the first name

Registering takes two moves: first a sealed commitment, then the registration itself. That stops
someone from taking your name while your transaction is in flight. At least 60 seconds sit between
the two.

**Step 16. Prepare the registration data.** This block describes one registration. `SECRET` can be any
value, but it must stay exactly the same in steps 17 and 19.

```shell script
# fill in these four yourself
export CTRL=0x...controller...
export RESOLVER=0x...publicresolver...
export ME=0x1B272dC2635CFBE67116434CdBfD7525f8F5196F
export LABEL=l2protocol

export SECRET=$(cast keccak "something-only-you-know")
export ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
export REG="($LABEL,$ME,31536000,$SECRET,$RESOLVER,[],0,$ZERO)"
```

`31536000` is one year in seconds. Labels shorter than 3 characters are rejected.

**Step 17. Record your commitment.**

```shell script
export SIG="(string,address,uint256,bytes32,address,bytes[],uint8,bytes32)"

export COMMITMENT=$(cast call $CTRL \
  "makeCommitment($SIG)(bytes32)" "$REG" --rpc-url $RPC_L2P)

cast send $CTRL "commit(bytes32)" $COMMITMENT \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_L2P
```

You should see `status 1 (success)`.

**Step 18. Wait at least 60 seconds.** Literally wait. Registering too early gives
`CommitmentTooNew`.

```shell script
sleep 70
```

After that you have 24 hours. Past that the commitment expires and you start again at step 17 with a
new `SECRET`.

**Step 19. Register the name.** You read the price from the controller and send it along in the same
transaction.

```shell script
export PRICE=$(cast call $CTRL \
  "rentPrice(string,uint256)((uint256,uint256))" \
  $LABEL 31536000 --rpc-url $RPC_L2P \
  | tr -d '()' | cut -d, -f1 | awk '{print $1}')

cast send $CTRL "register($SIG)" "$REG" --value $PRICE \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_L2P
```

You should see `status 1 (success)`. Confirm the result:

```shell script
cast call 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e \
  "owner(bytes32)(address)" \
  $(cast namehash $LABEL.l2p) --rpc-url $RPC_L2P
```

That returns your address.

Reverse resolution additionally requires the forward record to point back at the same address,
otherwise the UniversalResolver reverts with `ReverseAddressMismatch`.

### If something goes wrong

| Message | What is happening | What to do |
|---|---|---|
| `transaction gas price below minimum` | Foundry offered a lower gas price than the chain accepts. | Add `--priority-gas-price 1gwei --with-gas-price 1gwei`. Nothing was sent, so just run it again. |
| `sending as 0x1804c8Ab… but the ENS root node is owned by …` | Forge did not see your key and is using its own test address. | Check that `DEPLOYER_PRIVATE_KEY` is in `.env` in the project root. Forge reads that file itself; `source` is not needed. |
| `sending as <your address> but the ENS root node is owned by 0x…` | The deployment already ran, or you are using the key of a different address. | The message names the real owner. If that is a contract with code, the deployment has already happened. |
| `CommitmentTooNew` | You registered within 60 seconds of your commit. | Wait and retry step 19. Your commitment stays valid. |
| `UnexpiredCommitmentExists` | You already have a commitment with exactly this `SECRET` and label. | Go straight to step 19, or start over with a different `SECRET`. |
| `CommitmentTooOld` | Your commitment is more than 24 hours old. | Make a new `SECRET` and go back to step 17. |
| `NameNotAvailable` | The name is taken, or shorter than 3 characters. | Pick another name. |
| `InsufficientValue` | You sent too little L2P. | Read the price again; an expired name carries a premium on top. |
| `ReverseAddressMismatch` | You set a reverse record, but the name points at a different address. | Set `setAddr` to the same address first. ENS requires the round trip to match. |
| `Compiler run failed` | Dependencies are missing. | Run `npm install`, and `forge install` from step 2 if needed. |

### Settings you can pass

All optional; without them the script uses the defaults. Put them in `.env` before step 12.

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

### Fixed values

These never change and can be filled in anywhere with confidence.

| What | Value |
|---|---|
| ENSRegistry | `0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e` |
| Root node owner | `0x1B272dC2635CFBE67116434CdBfD7525f8F5196F` |
| namehash `l2p` | `0x81416bb7c03bc54e8597f6c932543fcd87e0649cd943cb29f71df95a7487f431` |
| labelhash `l2p` | `0xb267707bcf4448b9c88ae0b1ba8a5c7257a3b7a87148716c4a5119da716d666b` |
| chainId | `12216` |
| Grace period after expiry | 90 days |

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
