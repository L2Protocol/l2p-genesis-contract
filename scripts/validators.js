const web3 = require('web3');
const RLP = require('rlp');

// Configure
const validators = [
  {
    consensusAddr: '0xae11fb1f89c83c3ad49636a283732a3692de76f9',
    feeAddr: '0xae11fb1f89c83c3ad49636a283732a3692de76f9',
    l2pFeeAddr: '0xae11fb1f89c83c3ad49636a283732a3692de76f9',
    votingPower: 0x0000000000000064,
  },
  {
    consensusAddr: '0x98803ed812d591b5dcc319652645036b6ca32d1b',
    feeAddr: '0x98803ed812d591b5dcc319652645036b6ca32d1b',
    l2pFeeAddr: '0x98803ed812d591b5dcc319652645036b6ca32d1b',
    votingPower: 0x0000000000000064,
  },
  {
    consensusAddr: '0xda209d1508a1680be75751d0a9923d74997d90f2',
    feeAddr: '0xda209d1508a1680be75751d0a9923d74997d90f2',
    l2pFeeAddr: '0xda209d1508a1680be75751d0a9923d74997d90f2',
    votingPower: 0x0000000000000064,
  },  
];
const bLSPublicKeys = [
  '0x804f961443dc8f08658653883fb024d1307b6968433a1b60280e072d85fe247506c983840d55fc8409a9733a7bf94471',
  '0xa6d7f4c2fc5f961d43fcd6bdaa5224b718641134ab0414f8bd60efa3d82fee41a63d19fb843179961d652644d4451ded',
  '0xb5d063d021843a1df55d4a17e2a6e8fd4d8002d179533e31a5c33922f9a725f1771c5ab0223509346dbc8fd27e1360e9'
];

// ======== Do not edit below ========
function generateExtraData(validators) {
  let extraVanity = Buffer.alloc(32);
  let validatorsBytes = extraDataSerialize(validators);
  let extraSeal = Buffer.alloc(65);
  return Buffer.concat([extraVanity, validatorsBytes, extraSeal]);
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
