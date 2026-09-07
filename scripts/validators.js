const web3 = require('web3')
const RLP = require('rlp');

// Configure
const validators = [
   {
     'consensusAddr': '0xaE11fB1F89C83c3AD49636A283732A3692dE76f9',
     'feeAddr': '0xaE11fB1F89C83c3AD49636A283732A3692dE76f9',
     'l2pFeeAddr': '0xaE11fB1F89C83c3AD49636A283732A3692dE76f9',
     'votingPower': 7000000,
   },
   {
     'consensusAddr': '0x98803ED812D591B5dcc319652645036B6ca32d1B',
     'feeAddr': '0x98803ED812D591B5dcc319652645036B6ca32d1B',
     'l2pFeeAddr': '0x98803ED812D591B5dcc319652645036B6ca32d1B',
     'votingPower': 7000000,
   },
   {
     'consensusAddr': '0xDa209d1508a1680Be75751d0a9923d74997D90F2',
     'feeAddr': '0xDa209d1508a1680Be75751d0a9923d74997D90F2',
     'l2pFeeAddr': '0xDa209d1508a1680Be75751d0a9923d74997D90F2',
     'votingPower': 7000000,
   },
];
const bLSPublicKeys = [
   '0xa39d3eb3d0c1b4e1ebc7d4276df1dcdce06afcf7594994190684c91f530d7befd18f72764bb723cc06a0909aee609785',
   '0xad7f731c46b87a685cfafd99e50b01bfc9f0bee49187349b19a4fd933da9fbfce48516edb8764f6834944d8edcee37b4',
   '0xb1304d403ea1709527ad01b8abbda1720e15532ee22c89f5dcaa3a5b6611c646acee1c22ea9e000f14830a860eab55af',
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