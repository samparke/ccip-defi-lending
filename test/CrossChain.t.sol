//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {LendingManager} from "../src/LendingManager.sol";
import {IStablecoin} from "../src/interfaces/IStablecoin.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";

contract CrossChain is Test {
    CCIPLocalSimulatorFork ccipLocalSimulatorFork;
    Stablecoin stablecoin;
    CollateralManager collateralManager;
    LendingManager lendingManager;
    ERC20Mock weth;
    MockV3Aggregator wethPriceFeed;
    uint8 private constant DECIMALS = 8;
    int256 private constant ETH_USD_PRICE = 2000e8;
    uint256 sepoliaFork;
    uint256 arbSepoliaFork;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address owner = makeAddr("owner");

    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails arbSepoliaNetworkDetails;

    function setUp() public {
        sepoliaFork = vm.createSelectFork("sepolia-eth");
        arbSepoliaFork = vm.createFork("arb-sepolia");
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        vm.makePersistent(sepoliaNetworkDetails.rmnProxyAddress);
        vm.makePersistent(sepoliaNetworkDetails.routerAddress);

        vm.startPrank(owner);
        weth = new ERC20Mock("WETH", "WETH", msg.sender, 100e8);
        wethPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        weth.mint(alice, 100 ether);
        collateralManager = new CollateralManager(
            address(weth),
            address(wethPriceFeed),
            sepoliaNetworkDetails.routerAddress,
            sepoliaNetworkDetails.linkAddress
        );
        vm.stopPrank();

        vm.selectFork(arbSepoliaFork);
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        vm.makePersistent(arbSepoliaNetworkDetails.rmnProxyAddress);
        vm.makePersistent(arbSepoliaNetworkDetails.routerAddress);

        vm.startPrank(owner);
        stablecoin = new Stablecoin();
        lendingManager = new LendingManager(
            IStablecoin(address(stablecoin)),
            arbSepoliaNetworkDetails.routerAddress,
            arbSepoliaNetworkDetails.linkAddress
        );
        stablecoin.grantMintAndBurnRole(address(lendingManager));
        lendingManager.allowDestinationChain(sepoliaNetworkDetails.chainSelector, true);
        lendingManager.allowSender(alice, true);
        lendingManager.allowSourceChain(arbSepoliaNetworkDetails.chainSelector, true);
        vm.stopPrank();

        vm.selectFork(sepoliaFork);
        vm.startPrank(owner);
        collateralManager.allowDestinationChain(arbSepoliaNetworkDetails.chainSelector, true);
        collateralManager.allowSender(alice, true);
        collateralManager.allowSourceChain(sepoliaNetworkDetails.chainSelector, true);
        vm.stopPrank();
    }

    function testAliceInitialWethBalanceOnSepoliaFork() public view {
        assertEq(vm.activeFork(), sepoliaFork);
        assertEq(weth.balanceOf(alice), 100 ether);
    }
}
