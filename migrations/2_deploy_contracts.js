const BorrowLowb = artifacts.require("BorrowLowb");

module.exports = function(deployer) {
  const lpAddress = '0x28118A66Ae5F6b5DCC2AFAa764689081F279aCE0'; //testnet
  const routerAddress = '0x67A637E7bb250eb33BDf4407a51B58e8b479B498'; //testnet
  //const lpAddress = '0x3642b52519ba81fD8a204b306D2369A0cc1BC612'; //mainnet
  //const routerAddress = '0x10ED43C718714eb63d5aA57B78B54704E256024E'; //mainnet
  deployer.deploy(BorrowLowb, lpAddress, routerAddress);
};
