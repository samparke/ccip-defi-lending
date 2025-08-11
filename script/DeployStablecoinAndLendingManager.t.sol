//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {LendingManager} from "../src/LendingManager.sol";
import {IStablecoin} from "../src/interfaces/IStablecoin.sol";

contract DeployStablecoinAndLendingManager is Script {
    function run() external returns (Stablecoin, LendingManager, HelperConfig) {
        HelperConfig config = new HelperConfig();
        (,, address router, address linkAddress) = config.activeNetworkConfig();

        vm.startBroadcast();
        Stablecoin stablecoin = new Stablecoin();
        LendingManager lendingManager = new LendingManager(IStablecoin(address(stablecoin)), router, linkAddress);
        stablecoin.transferOwnership(address(lendingManager));
        vm.stopBroadcast();
        return (stablecoin, lendingManager, config);
    }
}
