const moment = require('moment');
const Ico = artifacts.require('Ico')

module.exports = function(deployer) {

  const start = moment().unix();
  const end = moment().add(1000, 'minute').unix();

  // first two accounts of mnemonic:
  // `candy maple cake sugar pudding cream honey rich smooth crumble sweet treat`
  const team = [
    '0x627306090abab3a6e1400e9345bc60c78a8bef57',
    '0xf17f52151ebef6c7334fad080c5704d77216b732',
    '0x0d1d4e623D10F9FBA5Db95830F7d3839406C6AF2'
  ];

  // this should be USD/ETH rate
  const tokensPerEth = 400;

  deployer.deploy(Ico, start, end, team, tokensPerEth);
}
