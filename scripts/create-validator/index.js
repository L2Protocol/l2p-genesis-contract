// Create a validator on L2P chain by signing locally with a private key.
//
//   node scripts/create-validator --dry-run    # validate + simulate, sends nothing
//   node scripts/create-validator              # sign and broadcast
//
// The key never leaves this process: the transaction is signed locally and sent
// as a raw transaction, so the node needs no unlocked account and no personal API.
//
// All settings come from the .env next to this file; copy .env.example to .env
// and fill it in. Nothing in this file needs to be edited. Any variable can also
// be overridden per run:
//   VALIDATOR_MONIKER=Val02 node scripts/create-validator --dry-run

const fs = require('fs');
const path = require('path');
const dotenv = require('dotenv');
const { ethers } = require('ethers');

const ROOT = path.join(__dirname, '..', '..');

// The .env next to this script wins; the one at the repo root (shared with
// foundry.toml) is a fallback, since dotenv never overwrites what is already set.
dotenv.config({ path: path.join(__dirname, '.env') });
dotenv.config({ path: path.join(ROOT, '.env') });

// ========================= CONFIGURATION =============================

const envErrors = [];

function envStr(name, fallback = '') {
  const raw = process.env[name];
  return raw === undefined || raw.trim() === '' ? fallback : raw.trim();
}

function envInt(name, fallback) {
  const raw = envStr(name);
  if (raw === '') {
    return fallback;
  }
  if (!/^\d+$/.test(raw)) {
    envErrors.push(`${name} must be a whole number, got '${raw}'`);
    return fallback;
  }
  return Number(raw);
}

// Amounts stay strings so ethers parses the decimals without float rounding.
function envAmount(name) {
  const raw = envStr(name);
  if (raw === '') {
    return null;
  }
  if (!/^\d+(\.\d+)?$/.test(raw)) {
    envErrors.push(`${name} must be a decimal number, got '${raw}'`);
    return null;
  }
  return raw;
}

const CONFIG = {
  // RPC endpoint of the node to broadcast through.
  rpc: envStr('RPC_L2P', 'https://rpc01.l2protocol.com'),

  // Operator private key. The operator address is derived from it and becomes
  // the owner of the validator.
  privateKey: envStr('OPERATOR_PRIVATE_KEY'),

  // Chain id the BLS proof was generated for. The transaction is refused if the
  // node reports a different chain id, because the proof would not verify.
  chainId: envInt('CHAIN_ID', 12216),

  // Consensus (block sealing) address of the node. May equal the operator,
  // but a separate key is strongly recommended.
  consensusAddress: envStr('VALIDATOR_CONSENSUS_ADDRESS'),

  // BLS vote address: 48-byte public key.
  //   geth bls account new  --datadir ./bls --blspassword ./bls-password.txt
  //   geth bls account list --datadir ./bls --blspassword ./bls-password.txt
  voteAddress: envStr('VALIDATOR_VOTE_ADDRESS'),

  // BLS ownership proof: 96-byte signature over
  // keccak256(operator ++ voteAddress ++ chainId).
  //   geth bls account generate-proof --datadir ./bls --blspassword ./bls-password.txt \
  //        --chain-id 12216 <operator address> <BLS pubkey>
  blsProof: envStr('VALIDATOR_BLS_PROOF'),

  // Commission in basis points (10000 = 100%).
  // Rules: maxRate <= 5000, rate <= maxRate, maxChangeRate <= maxRate.
  commission: {
    rate: envInt('VALIDATOR_COMMISSION_RATE', 500),
    maxRate: envInt('VALIDATOR_COMMISSION_MAX_RATE', 3000),
    maxChangeRate: envInt('VALIDATOR_COMMISSION_MAX_CHANGE_RATE', 500),
  },

  // Moniker: 3-9 chars, first char A-Z, rest alphanumeric only, must be unique.
  description: {
    moniker: envStr('VALIDATOR_MONIKER'),
    identity: envStr('VALIDATOR_IDENTITY'),
    website: envStr('VALIDATOR_WEBSITE'),
    details: envStr('VALIDATOR_DETAILS'),
  },

  // Self delegation in whole L2P. Unset = read minSelfDelegationL2P() from the
  // chain and use exactly that minimum. The 3500 L2P lock amount is added
  // automatically on top of this.
  selfDelegation: envAmount('VALIDATOR_SELF_DELEGATION'),

  // Unset = use the gas estimate (with a 25% margin) and the node's fee suggestion.
  gasLimit: envInt('GAS_LIMIT', null),
  maxFeePerGas: envAmount('MAX_FEE_PER_GAS'),
  maxPriorityFeePerGas: envAmount('MAX_PRIORITY_FEE_PER_GAS'),
};

// ========================== IMPLEMENTATION ===========================

const STAKE_HUB_ADDR = '0x0000000000000000000000000000000000002002';

function loadAbi(name) {
  return JSON.parse(fs.readFileSync(path.join(ROOT, 'abi', name), 'utf8'));
}

const ABI = loadAbi('stakehub.abi');

// createValidator reverts through StakeCredit and GovToken as well, so their
// custom errors have to be decodable too.
const ERROR_ABI = ['stakehub.abi', 'stakecredit.abi', 'govtoken.abi'].reduce(
  (acc, name) => acc.concat(loadAbi(name).filter((entry) => entry.type === 'error')),
  []
);
const ERROR_INTERFACE = new ethers.Interface(ERROR_ABI);

function checkMoniker(moniker) {
  if (moniker.length < 3 || moniker.length > 9) {
    return `must be 3-9 characters, got ${moniker.length}`;
  }
  const first = moniker.charCodeAt(0);
  if (first < 65 || first > 90) {
    return 'must start with an uppercase letter A-Z';
  }
  for (let i = 1; i < moniker.length; i++) {
    const c = moniker.charCodeAt(i);
    const alnum = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
    if (!alnum) {
      return `may only contain alphanumeric characters, found '${moniker[i]}'`;
    }
  }
  return null;
}

function checkBytes(name, value, want, errs) {
  if (!value) {
    errs.push(`${name} is not set`);
  } else if (!ethers.isHexString(value)) {
    errs.push(`${name} must be a 0x-prefixed hex string, got '${value}'`);
  } else if ((value.length - 2) / 2 !== want) {
    errs.push(`${name} must be ${want} bytes, got ${(value.length - 2) / 2}`);
  }
}

function validate(cfg) {
  const errs = envErrors.slice();

  if (!cfg.privateKey) {
    errs.push('OPERATOR_PRIVATE_KEY is not set');
  } else if (!/^0x[0-9a-fA-F]{64}$/.test(cfg.privateKey)) {
    errs.push('OPERATOR_PRIVATE_KEY must be a 0x-prefixed 32-byte hex string');
  }

  if (!cfg.consensusAddress) {
    errs.push('VALIDATOR_CONSENSUS_ADDRESS is not set');
  } else if (!ethers.isAddress(cfg.consensusAddress) || cfg.consensusAddress === ethers.ZeroAddress) {
    errs.push(`VALIDATOR_CONSENSUS_ADDRESS is not a valid non-zero address: '${cfg.consensusAddress}'`);
  }

  checkBytes('VALIDATOR_VOTE_ADDRESS', cfg.voteAddress, 48, errs);
  checkBytes('VALIDATOR_BLS_PROOF', cfg.blsProof, 96, errs);

  const c = cfg.commission;
  if (c.maxRate > 5000) {
    errs.push('VALIDATOR_COMMISSION_MAX_RATE may not exceed 5000 (50%)');
  }
  if (c.rate > c.maxRate) {
    errs.push('VALIDATOR_COMMISSION_RATE may not exceed VALIDATOR_COMMISSION_MAX_RATE');
  }
  if (c.maxChangeRate > c.maxRate) {
    errs.push('VALIDATOR_COMMISSION_MAX_CHANGE_RATE may not exceed VALIDATOR_COMMISSION_MAX_RATE');
  }

  if (!cfg.description.moniker) {
    errs.push('VALIDATOR_MONIKER is not set');
  } else {
    const monikerErr = checkMoniker(cfg.description.moniker);
    if (monikerErr) {
      errs.push(`VALIDATOR_MONIKER ${monikerErr}`);
    }
  }

  return errs;
}

function describeError(err) {
  if (err.revert) {
    return `${err.revert.name}(${err.revert.args.join(', ')})`;
  }
  const data = err.data || (err.info && err.info.error && err.info.error.data);
  if (ethers.isHexString(data) && data.length >= 10) {
    const decoded = ERROR_INTERFACE.parseError(data);
    if (decoded) {
      return `${decoded.name}(${decoded.args.join(', ')})`;
    }
    return `${err.shortMessage || err.message} (undecodable error ${data.slice(0, 10)})`;
  }
  return err.shortMessage || err.reason || err.message;
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  const cfg = CONFIG;

  const errs = validate(cfg);
  if (errs.length > 0) {
    console.error('Configuration is invalid:');
    errs.forEach((e) => console.error(`  - ${e}`));
    process.exitCode = 1;
    return;
  }

  const provider = new ethers.JsonRpcProvider(cfg.rpc);
  const wallet = new ethers.Wallet(cfg.privateKey, provider);
  const stakeHub = new ethers.Contract(STAKE_HUB_ADDR, ABI, wallet);

  const network = await provider.getNetwork();
  if (Number(network.chainId) !== cfg.chainId) {
    console.error(
      `chain id mismatch: node reports ${network.chainId}, but the BLS proof was generated ` +
        `for ${cfg.chainId}. Regenerate the proof or fix CHAIN_ID.`
    );
    process.exitCode = 1;
    return;
  }

  const owner = await stakeHub.consensusToOperator(cfg.consensusAddress);
  if (owner !== ethers.ZeroAddress) {
    console.error(`consensusAddress ${cfg.consensusAddress} is already taken by operator ${owner}`);
    process.exitCode = 1;
    return;
  }

  const existing = await stakeHub.getValidatorBasicInfo(wallet.address);
  if (existing[0] > 0n) {
    console.error(`operator ${wallet.address} is already a validator`);
    process.exitCode = 1;
    return;
  }

  const lockAmount = await stakeHub.LOCK_AMOUNT();
  const minSelfDelegation = await stakeHub.minSelfDelegationL2P();

  let selfDelegation = minSelfDelegation;
  if (cfg.selfDelegation !== null && cfg.selfDelegation !== undefined) {
    selfDelegation = ethers.parseEther(String(cfg.selfDelegation));
    if (selfDelegation < minSelfDelegation) {
      console.error(
        `VALIDATOR_SELF_DELEGATION ${ethers.formatEther(selfDelegation)} L2P is below the minimum of ` +
          `${ethers.formatEther(minSelfDelegation)} L2P`
      );
      process.exitCode = 1;
      return;
    }
  }
  const value = lockAmount + selfDelegation;

  const balance = await provider.getBalance(wallet.address);
  if (balance < value) {
    console.error(
      `insufficient balance: have ${ethers.formatEther(balance)} L2P, need at least ` +
        `${ethers.formatEther(value)} L2P plus gas`
    );
    process.exitCode = 1;
    return;
  }

  const args = [
    cfg.consensusAddress,
    cfg.voteAddress,
    cfg.blsProof,
    [cfg.commission.rate, cfg.commission.maxRate, cfg.commission.maxChangeRate],
    [cfg.description.moniker, cfg.description.identity, cfg.description.website, cfg.description.details],
  ];

  console.log(`rpc               : ${cfg.rpc} (chain id ${network.chainId})`);
  console.log(`operator          : ${wallet.address}`);
  console.log(`consensus address : ${cfg.consensusAddress}`);
  console.log(`vote address      : ${cfg.voteAddress}`);
  console.log(`moniker           : ${cfg.description.moniker}`);
  console.log(
    `commission        : rate ${cfg.commission.rate}, max ${cfg.commission.maxRate}, ` +
      `maxChange ${cfg.commission.maxChangeRate} (bps)`
  );
  console.log(`self delegation   : ${ethers.formatEther(selfDelegation)} L2P`);
  console.log(`locked amount     : ${ethers.formatEther(lockAmount)} L2P`);
  console.log(`tx value          : ${ethers.formatEther(value)} L2P`);
  console.log(`balance           : ${ethers.formatEther(balance)} L2P`);

  try {
    await stakeHub.createValidator.staticCall(...args, { value });
  } catch (err) {
    console.error(`\nthe transaction would revert: ${describeError(err)}`);
    process.exitCode = 1;
    return;
  }

  let gasLimit = cfg.gasLimit;
  if (gasLimit === null || gasLimit === undefined) {
    const estimate = await stakeHub.createValidator.estimateGas(...args, { value });
    gasLimit = (estimate * 125n) / 100n;
    console.log(`estimated gas     : ${estimate} (using ${gasLimit})`);
  } else {
    console.log(`gas limit         : ${gasLimit}`);
  }

  if (dryRun) {
    const data = stakeHub.interface.encodeFunctionData('createValidator', args);
    console.log(`calldata          : ${data.length / 2 - 1} bytes`);
    console.log('\nDry run, nothing was sent. Drop --dry-run to broadcast.');
    return;
  }

  const overrides = { value, gasLimit };
  if (cfg.maxFeePerGas !== null && cfg.maxFeePerGas !== undefined) {
    overrides.maxFeePerGas = ethers.parseUnits(String(cfg.maxFeePerGas), 'gwei');
  }
  if (cfg.maxPriorityFeePerGas !== null && cfg.maxPriorityFeePerGas !== undefined) {
    overrides.maxPriorityFeePerGas = ethers.parseUnits(String(cfg.maxPriorityFeePerGas), 'gwei');
  }

  const tx = await stakeHub.createValidator(...args, overrides);
  console.log(`\nsent: ${tx.hash}`);

  const receipt = await tx.wait();
  if (receipt.status === 1) {
    const info = await stakeHub.getValidatorBasicInfo(wallet.address);
    console.log(`mined in block ${receipt.blockNumber}, gas used ${receipt.gasUsed}`);
    console.log(`validator created at ${new Date(Number(info[0]) * 1000).toISOString()}`);
  } else {
    console.error(`reverted in block ${receipt.blockNumber}, gas used ${receipt.gasUsed}`);
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(describeError(err));
  process.exitCode = 1;
});
