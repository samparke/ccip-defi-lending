//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployCollateralManager is Script {
    address weth;
    address wethPriceFeed;
    address router;
    address linkAddress;

    function run() external returns (CollateralManager, HelperConfig) {
        HelperConfig config = new HelperConfig();
        (weth, wethPriceFeed, router, linkAddress) = config.activeNetworkConfig();

        vm.startBroadcast();
        CollateralManager collateralManager = new CollateralManager(weth, wethPriceFeed, router, linkAddress);
        vm.stopBroadcast();
        return (collateralManager, config);
    }
}
