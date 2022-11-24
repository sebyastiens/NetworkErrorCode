const Flashloan = artifacts.require("Flashloan");
const  {mainnet : addresses} = require('../addresses'); // same as ../addresses/index.js

module.exports = function (deployer, _network,[beneficiaryAddress,_]) { //[beneficiaryAddress,_] ça veut dire que la 1ère addresse correspond à celle du beneficiary. C'est la liste d'adresse qu'on a entré dans truffle-config.php mais dans notre cas il y en a qu'une seule (celle de la private key)
  deployer.deploy(
    Flashloan,
    addresses.kyber.kyberNetworkProxy,
    addresses.uniswap.router,
    addresses.tokens.weth,
    addresses.tokens.dai,
    beneficiaryAddress
    );
};