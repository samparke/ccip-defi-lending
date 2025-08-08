//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";

contract HelperConfig {
    struct NetworkConfig {
        address wethAddress;
        address wethPriceFeed;
    }

    uint256 private constant DECIMALS = 8;
    uint256 private constant ETH_USD_PRICE = 2000e8;
    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            activeNetworkConfig = getAnvilConfig();
        }
    }

    function getSepoliaConfig() public returns (NetworkConfig memory){
        return (NetworkConfig({
            wethAddress: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wethPriceFeed:0x694AA1769357215DE4FAC081bf1f309aDC325306
        }))
    }

    function getAnvilConfig() public returns (NetworkConfig memory) {
        vm.startBroadcast();
        ERC20Mock wethMock = new ERC20Mock("WETH", "WETH", msg.sender, 100e8);
        MockV3Aggregator wethPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        vm.stopBroadcast();
        return (NetworkConfig({wethAddress: wethMock, wethPriceFeed: wethPriceFeed}));
    }
}
