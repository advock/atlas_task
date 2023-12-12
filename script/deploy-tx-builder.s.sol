// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import { DeployBaseScript } from "script/base/deploy-base.s.sol";

import { Atlas } from "src/contracts/atlas/Atlas.sol";
import { AtlasVerification } from "src/contracts/atlas/AtlasVerification.sol";
import { GasAccountingLib } from "src/contracts/atlas/GasAccountingLib.sol";
import { SafetyLocksLib } from "src/contracts/atlas/SafetyLocksLib.sol";
import { SwapIntentController } from "src/contracts/examples/intents-example/SwapIntent.sol";
import { TxBuilder } from "src/contracts/helpers/TxBuilder.sol";
import { Simulator } from "src/contracts/helpers/Simulator.sol";

contract DeployTxBuilderScript is DeployBaseScript {
    function run() external {
        console.log("\n=== DEPLOYING Tx Builder ===\n");
        console.log("And configuring with the currernt SwapIntent DAppControl deployment...");

        console.log("Deploying to chain: ", _getDeployChain());

        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address: \t\t\t\t", deployer);

        address atlasAddress = _getAddressFromDeploymentsJson("ATLAS");
        address atlasVerificationAddress = _getAddressFromDeploymentsJson("ATLAS_VERIFICATION");
        address swapIntentControlAddress = _getAddressFromDeploymentsJson("SWAP_INTENT_DAPP_CONTROL");

        vm.startBroadcast(deployerPrivateKey);

        txBuilder = new TxBuilder({
            controller: swapIntentControlAddress,
            atlasAddress: atlasAddress,
            _verification: atlasVerificationAddress
        });

        vm.stopBroadcast();

        _writeAddressToDeploymentsJson("TX_BUILDER", address(txBuilder));

        console.log("\n");
        console.log("Tx Builder deployed at: \t\t\t", address(txBuilder));
        console.log("\n");
        console.log("You can find a list of contract addresses from the latest deployment in deployments.json");
    }
}
