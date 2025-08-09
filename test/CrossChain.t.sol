//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {LendingManager} from "../src/LendingManager.sol";
import {IStablecoin} from "../src/interfaces/IStablecoin.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

contract CrossChainTest is Test {
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
    uint256 private constant ALICE_STARTING_WETH_BALANCE = 100 ether;

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
        weth.mint(alice, ALICE_STARTING_WETH_BALANCE);
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
        lendingManager.allowSender(address(collateralManager), true);
        lendingManager.allowSourceChain(sepoliaNetworkDetails.chainSelector, true);
        vm.stopPrank();

        vm.selectFork(sepoliaFork);
        vm.startPrank(owner);
        collateralManager.allowDestinationChain(arbSepoliaNetworkDetails.chainSelector, true);
        collateralManager.allowSender(address(lendingManager), true);
        collateralManager.allowSourceChain(arbSepoliaNetworkDetails.chainSelector, true);
        vm.stopPrank();
    }

    function testAliceInitialWethBalanceOnSepoliaFork() public view {
        assertEq(vm.activeFork(), sepoliaFork);
        assertEq(weth.balanceOf(alice), 100 ether);
    }

    function testDepositWethOnSepoliaAndMintAllStablecoinOnArbSepolia() public {
        vm.startPrank(alice);
        ERC20Mock(weth).approve(address(collateralManager), 10 ether);
        collateralManager.deposit(10 ether);
        vm.stopPrank();

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(alice);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));

        vm.selectFork(arbSepoliaFork);
        uint256 aliceStablecoinBalanceBefore = stablecoin.balanceOf(alice);

        vm.selectFork(sepoliaFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

        vm.selectFork(arbSepoliaFork);
        vm.warp(block.timestamp + 20 minutes);
        (, bytes memory data) = lendingManager.getLastReceivedMessageDetails();
        (address user, uint256 amount) = abi.decode(data, (address, uint256));
        console.log("last received message details:", user, amount);
        assertGt(stablecoin.balanceOf(alice), aliceStablecoinBalanceBefore);
    }

    function testDepositWethOnSepoliaAndMintStablecoinOnArbSepolia() public {
        vm.startPrank(alice);
        IERC20(address(weth)).approve(address(collateralManager), 10 ether);
        collateralManager.deposit(10 ether);
        vm.stopPrank();

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(alice);
        collateralManager.requestTokensOnSecondChain(
            arbSepoliaNetworkDetails.chainSelector, address(lendingManager), 5 ether
        );

        vm.selectFork(arbSepoliaFork);
        uint256 aliceBalanceBefore = stablecoin.balanceOf(alice);

        vm.selectFork(sepoliaFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

        vm.selectFork(arbSepoliaFork);
        vm.warp(block.timestamp + 20 minutes);
        (, bytes memory data) = lendingManager.getLastReceivedMessageDetails();
        (address user, uint256 amount) = abi.decode(data, (address, uint256));
        console.log("data received:", user, amount);
        assertGt(stablecoin.balanceOf(alice), aliceBalanceBefore);
    }

    function testAliceDepositsWethAndBurnsStablecoinAndRedeemsWeth() public {
        vm.startPrank(alice);
        ERC20Mock(weth).approve(address(collateralManager), 10 ether);
        collateralManager.deposit(10 ether);
        vm.stopPrank();
        assertEq(collateralManager.getAmountDeposited(alice), 10 ether);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(alice);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

        vm.selectFork(sepoliaFork);
        assertEq(collateralManager.getAmountDeposited(alice), 0);

        vm.selectFork(arbSepoliaFork);
        vm.warp(block.timestamp + 20 minutes);
        assertGt(stablecoin.balanceOf(alice), 0);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(lendingManager), 1e21);
        vm.startPrank(alice);
        lendingManager.burnStablecoin(alice, stablecoin.balanceOf(alice));
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
        vm.stopPrank();
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sepoliaFork);

        vm.selectFork(arbSepoliaFork);
        assertEq(stablecoin.balanceOf(alice), 0);

        vm.selectFork(sepoliaFork);
        assertEq(collateralManager.getAmountDeposited(alice), 10 ether);

        vm.prank(alice);
        collateralManager.redeem(10 ether);
        assertEq(weth.balanceOf(alice), ALICE_STARTING_WETH_BALANCE);
    }

    function testNotAllowedSourceChainRevert() public {
        vm.prank(owner);
        collateralManager.allowSourceChain(arbSepoliaNetworkDetails.chainSelector, false);

        vm.startPrank(alice);
        ERC20Mock(weth).approve(address(collateralManager), 10 ether);
        collateralManager.deposit(10 ether);
        vm.stopPrank();
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(alice);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

        vm.selectFork(arbSepoliaFork);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(lendingManager), 1e21);
        vm.startPrank(alice);
        lendingManager.burnStablecoin(alice, stablecoin.balanceOf(alice));
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
        vm.stopPrank();
        vm.expectRevert();
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sepoliaFork);
    }
}
