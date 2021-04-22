const Lottery = artifacts.require("Lottereum");

//minimum deposit, current deposit, change in deposit, game length
module.exports = function (deployer) {
  deployer.deploy(Lottery, 10, 15, 5, 60);
};
