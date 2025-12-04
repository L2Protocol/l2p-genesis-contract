const web3 = require('web3')
const RLP = require('rlp');

// Configure
const validators = [
   {
     'consensusAddr': '0xaE11fB1F89C83c3AD49636A283732A3692dE76f9',
     'feeAddr': '0xaE11fB1F89C83c3AD49636A283732A3692dE76f9',
     'l2pFeeAddr': '0xaE11fB1F89C83c3AD49636A283732A3692dE76f9',
     'votingPower': 2001,
   },
   {
     'consensusAddr': '0x98803ED812D591B5dcc319652645036B6ca32d1B',
     'feeAddr': '0x98803ED812D591B5dcc319652645036B6ca32d1B',
     'l2pFeeAddr': '0x98803ED812D591B5dcc319652645036B6ca32d1B',
     'votingPower': 2001,
   },
   {
     'consensusAddr': '0xDa209d1508a1680Be75751d0a9923d74997D90F2',
     'feeAddr': '0xDa209d1508a1680Be75751d0a9923d74997D90F2',
     'l2pFeeAddr': '0xDa209d1508a1680Be75751d0a9923d74997D90F2',
     'votingPower': 2001,
   },
];
const bLSPublicKeys = [
   '0xb990452e4365ee99b1ae0bef9ade1639c45f9560a7e334abad2b802ae3b6ae53d8a613924e3d94716287438e44aef774',
   '0x84a27e33f9a4d177ece0792106c648c1b91937782b119e06aa274485798f60bac26b1363656ecf8ecdabade91b292326',
   '0xab314870c4485be98da76207e4bcbbff0e45506631966e27f9424105351f8a66c44177e1e9f58038878308eee1a3ce77',
];

// ======== Do not edit below ========
function generateExtraData(validators) {
  let extraVanity = Buffer.alloc(32);
  let validatorsBytes = extraDataSerialize(validators);
  let extraSeal = Buffer.alloc(65);
  return Buffer.concat([extraVanity,validatorsBytes, extraSeal]);
}

function extraDataSerialize(validators) {
  let n = validators.length;
  let arr = [];
  for (let i = 0; i < n; i++) {
    let validator = validators[i];
    arr.push(Buffer.from(web3.utils.hexToBytes(validator.consensusAddr)));
  }
  return Buffer.concat(arr);
}

function validatorUpdateRlpEncode(validators, bLSPublicKeys) {
  let n = validators.length;
  let vals = [];
  for (let i = 0; i < n; i++) {
    vals.push([
      validators[i].consensusAddr,
      validators[i].l2pFeeAddr,
      validators[i].feeAddr,
      validators[i].votingPower,
      bLSPublicKeys[i],
    ]);
  }
  let pkg = [0x00, vals];
  return web3.utils.bytesToHex(RLP.encode(pkg));
}

extraValidatorBytes = generateExtraData(validators);
validatorSetBytes = validatorUpdateRlpEncode(validators, bLSPublicKeys);

exports = module.exports = {
  extraValidatorBytes: extraValidatorBytes,
  validatorSetBytes: validatorSetBytes,
};