const program = require('commander');
const nunjucks = require('nunjucks');
const fs = require('fs');
const web3 = require('web3');

const validators = require('./validators');
const init_holders = require('./init_holders');

const TOTAL_SUPPLY = 105_000_000_000n * 10n ** 18n;
const TEAM_VESTING_AMOUNT = 15_000_000_000n * 10n ** 18n;
const TEAM_VESTING_CLIFF = 365n * 24n * 60n * 60n;
const TEAM_VESTING_DURATION = 4n * TEAM_VESTING_CLIFF;

const word = (value) => value.toString(16).padStart(64, '0');

program.version('0.0.1');
program.option('-c, --chainId <chainId>', 'chain id', '714');
program.option('-e, --ensRegistryOwner <ens-registry-owner-address>', 'ens registry owner address', '0x...');
program.option('-p, --presaleOwner <presale-owner-address>', 'presale owner address', '0x...');
program.option('-v, --teamVestingBeneficiary <team-vesting-beneficiary-address>', 'team vesting beneficiary address', '0x...');
program.option('-o, --output <output-file>', 'Genesis json file', './genesis.json');
program.option('-t, --template <template>', 'Genesis template json', './genesis-template.json');
program.parse(process.argv);

// get byte code from compiled contract
function readByteCode(key, contractFile) {
  return new Promise((resolve, reject) => {
    fs.readFile(`${contractFile}`, 'utf8', (err, data) => {
      if (err) {
        reject(new Error('Error reading file: ' + err.message));
        return;
      }

      try {
        const jsonObj = JSON.parse(data);
        const compiledData = jsonObj['deployedBytecode']['object'];

        resolve({
          key: key,
          compiledData: compiledData,
        });
      } catch (parseError) {
        reject(new Error('Error parsing JSON: ' + parseError.message));
      }
    });
  });
}

// compile files
Promise.all([
  readByteCode('validatorContract', 'out/L2PValidatorSet.sol/L2PValidatorSet.json'),
  readByteCode('systemRewardContract', 'out/SystemReward.sol/SystemReward.json'),
  readByteCode('slashContract', 'out/SlashIndicator.sol/SlashIndicator.json'),
  readByteCode('govHub', 'out/GovHub.sol/GovHub.json'),
  readByteCode('stakeHub', 'out/StakeHub.sol/StakeHub.json'),
  readByteCode('stakeCredit', 'out/StakeCredit.sol/StakeCredit.json'),
  readByteCode('governor', 'out/L2PGovernor.sol/L2PGovernor.json'),
  readByteCode('govToken', 'out/GovToken.sol/GovToken.json'),
  readByteCode('timelock', 'out/L2PTimelock.sol/L2PTimelock.json'),
  readByteCode('ensRegistry', 'out/ENSRegistry.sol/ENSRegistry.json'),
  readByteCode('presale', 'out/L2PPresale.sol/L2PPresale.json'),
  readByteCode('wl2p', 'out/WL2P.sol/WL2P.json'),
  readByteCode('vesting', 'out/L2PVesting.sol/L2PVesting.json')
]).then((result) => {
  const templateString = fs.readFileSync(program.template).toString();
  const genesisTimestamp = BigInt(JSON.parse(templateString.match(/"timestamp": ("0x[0-9a-fA-F]+")/)[1]));

  const data = {
    chainId: program.chainId,
    initHolders: init_holders,
    extraData: web3.utils.bytesToHex(validators.extraValidatorBytes),
    ensRegistryOwner: program.ensRegistryOwner.slice(2).toLowerCase(),
    presaleOwner: program.presaleOwner.slice(2).toLowerCase(),
    teamVestingBeneficiary: program.teamVestingBeneficiary.slice(2).toLowerCase(),
    teamVestingStart: word(genesisTimestamp),
    teamVestingBalance: TEAM_VESTING_AMOUNT.toString(16),
    teamVestingCliff: word(TEAM_VESTING_CLIFF),
    teamVestingDuration: word(TEAM_VESTING_DURATION),
  };

  result.forEach((r) => {
    data[r.key] = r.compiledData;
  });

  const resultString = nunjucks.renderString(templateString, data);

  const alloc = JSON.parse(resultString).alloc;
  const total = Object.values(alloc).reduce((sum, account) => sum + BigInt(account.balance || '0x0'), 0n);
  if (total !== TOTAL_SUPPLY) {
    throw new Error(`genesis allocates ${total} wei, expected exactly ${TOTAL_SUPPLY}`);
  }

  fs.writeFileSync(program.output, resultString);
});
