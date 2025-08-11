//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";
import {LendingManager} from "../../src/LendingManager.sol";
import {IStablecoin} from "../../src/interfaces/IStablecoin.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/src/ccip/CCIPLocalSimulatorFork.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20MockFailTransferFrom} from "../mocks/ERC20MockFailTransferFrom.sol";
import {ERC20MockFailTransfer} from "../mocks/ERC20MockFailTransfer.sol";

contract CollateralManagerTest is Test {
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
    address user = makeAddr("user");
    address owner = makeAddr("owner");
    uint256 private constant USER_STARTING_WETH_BALANCE = 100 ether;

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
        weth.mint(user, USER_STARTING_WETH_BALANCE);
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

    modifier deposit() {
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);
        _;
    }

    function testDepositZeroRevert() public {
        vm.expectRevert(CollateralManager.CollateralManager__MustBeMoreThanZero.selector);
        collateralManager.deposit(0);
    }

    function testDepositTransfersFromUserToContract() public {
        uint256 userBalanceBefore = weth.balanceOf(user);
        assertEq(userBalanceBefore, USER_STARTING_WETH_BALANCE);
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);
        uint256 userBalanceAfter = weth.balanceOf(user);
        assertEq(userBalanceAfter, 90 ether);
        assertEq(weth.balanceOf(address(collateralManager)), 10 ether);
    }

    function testDepositUserMappingIncreases() public {
        uint256 userDepositedBefore = collateralManager.getAmountDeposited(user);
        assertEq(userDepositedBefore, 0);
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);
        uint256 userDepositedAfter = collateralManager.getAmountDeposited(user);
        assertEq(userDepositedAfter, 10 ether);
    }

    function testDepositEventEmits() public {
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        vm.expectEmit();
        emit CollateralManager.Deposit(user, 10 ether);
        collateralManager.deposit(10 ether);
    }

    function testDepositFail() public {
        vm.startPrank(owner);
        ERC20MockFailTransferFrom mockWeth = new ERC20MockFailTransferFrom("WETH", "WETH", msg.sender, 100e8);
        mockWeth.mint(user, USER_STARTING_WETH_BALANCE);
        collateralManager = new CollateralManager(
            address(mockWeth),
            address(wethPriceFeed),
            sepoliaNetworkDetails.routerAddress,
            sepoliaNetworkDetails.linkAddress
        );
        vm.stopPrank();

        vm.prank(user);
        mockWeth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CollateralManager.CollateralManager__DepositFailed.selector, user));
        collateralManager.deposit(1 ether);
    }

    // redeem

    function testRedeemUserWethBalanceIncreases() public deposit {
        uint256 wethBalanceBefore = weth.balanceOf(user);
        assertEq(wethBalanceBefore, 90 ether);
        vm.prank(user);
        collateralManager.redeem(10 ether);
        uint256 wethBalanceAfter = weth.balanceOf(user);
        assertEq(wethBalanceAfter, USER_STARTING_WETH_BALANCE);
    }

    function testRedeemAttemptMoreThanDeposited() public deposit {
        vm.prank(user);
        vm.expectRevert(CollateralManager.CollateralManager__CannotRedeemMoreThanDeposited.selector);
        collateralManager.redeem(USER_STARTING_WETH_BALANCE + 1);
    }

    function testRedeemEventEmits() public deposit {
        vm.prank(user);
        vm.expectEmit();
        emit CollateralManager.Redeem(user, 10 ether);
        collateralManager.redeem(10 ether);
    }

    function testRedeemFail() public {
        vm.startPrank(owner);
        ERC20MockFailTransfer mockWeth = new ERC20MockFailTransfer("WETH", "WETH", msg.sender, 100e8);
        mockWeth.mint(user, USER_STARTING_WETH_BALANCE);
        collateralManager = new CollateralManager(
            address(mockWeth),
            address(wethPriceFeed),
            sepoliaNetworkDetails.routerAddress,
            sepoliaNetworkDetails.linkAddress
        );
        vm.stopPrank();

        vm.prank(user);
        mockWeth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CollateralManager.CollateralManager__RedeemFailed.selector, user));
        collateralManager.redeem(1 ether);
    }

    // request tokens

    function testRequestTokensInsufficientBalanceRevert() public deposit {
        vm.prank(user);
        vm.expectRevert(CollateralManager.CollateralManager__InsufficientAmountDeposited.selector);
        collateralManager.requestTokensOnSecondChain(
            arbSepoliaNetworkDetails.chainSelector, address(lendingManager), 11 ether
        );
    }

    // calculate

    function testCorrectTokenAmountFromStablecoin() public view {
        // for $2000 (2000e18 in ether decimals), it should equal 1 ether
        assertEq(collateralManager.calculateWethTokenAmountFromStablecoin(2000e18), 1 ether);
    }

    function testCorrectCalculateCollateralValue() public view {
        assertEq(collateralManager.calculateCollateralValue(1 ether), 2000e18);
    }

    // insuffcient link revert

    function testInsufficientLinkRevert() public deposit {
        vm.prank(user);
        vm.expectRevert(CollateralManager.CollateralManager__InsufficientLinkBalance.selector);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
    }

    // invalid receiver revert

    function testInvalidReceiverRevert() public deposit {
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        vm.expectRevert(CollateralManager.CollateralManager__InvalidReceiver.selector);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(0));
    }

    // not allowed destination chain

    function testNotAllowedDestinationChainRevert() public deposit {
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(owner);
        collateralManager.allowDestinationChain(arbSepoliaNetworkDetails.chainSelector, false);
        vm.prank(user);
        vm.expectRevert(CollateralManager.CollateralManager__DestinationChainNotAllowListed.selector);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
    }

    function testOnlyOwnerCanNotAllowDestinationChainRevert() public {
        vm.prank(user);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        collateralManager.allowDestinationChain(arbSepoliaNetworkDetails.chainSelector, false);
    }

    // not allowed source chain

    function testNotAllowedSourceChainArbSepolia() public {
        vm.selectFork(sepoliaFork);
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

        vm.selectFork(sepoliaFork);
        vm.prank(owner);
        collateralManager.allowSourceChain(arbSepoliaNetworkDetails.chainSelector, false);

        vm.selectFork(arbSepoliaFork);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(lendingManager), 1e21);
        vm.prank(user);
        lendingManager.burnStablecoin(1 ether);
        vm.prank(user);
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
        vm.expectRevert();
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sepoliaFork);
    }

    // not allowed sender

    function testNotAllowedSenderLendingManager() public {
        vm.selectFork(sepoliaFork);
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

        vm.selectFork(sepoliaFork);
        vm.prank(owner);
        collateralManager.allowSender(address(lendingManager), false);

        vm.selectFork(arbSepoliaFork);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(lendingManager), 1e21);
        vm.prank(user);
        lendingManager.burnStablecoin(1 ether);
        vm.prank(user);
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
        vm.expectRevert();
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sepoliaFork);
    }

    // collateral added to mapping event

    function testAddCollateralEvent() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(collateralManager), 10 ether);
        collateralManager.deposit(10 ether);
        vm.stopPrank();

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(lendingManager), 1e21);
        vm.startPrank(user);
        lendingManager.burnStablecoin(stablecoin.balanceOf(user));
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
        vm.stopPrank();
        vm.expectEmit();
        emit CollateralManager.CollateralAddedToMapping(user, 10 ether);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sepoliaFork);
    }

    function testGetLastMessageDetailsAfterReceivingCollateralReturn() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(collateralManager), 10 ether);
        collateralManager.deposit(10 ether);
        vm.stopPrank();

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(lendingManager), 1e21);
        vm.startPrank(user);
        lendingManager.burnStablecoin(stablecoin.balanceOf(user));
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
        vm.stopPrank();
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sepoliaFork);

        (, bytes memory data) = collateralManager.getLastReceivedMessageDetails();
        (address account, uint256 amount) = abi.decode(data, (address, uint256));

        assertEq(account, user);
        // the data within the last message will be the raw message data from the lending manager, meaning it will be in
        // stablecoin units, without conversion
        assertEq(amount, (10 ether) * 2000);
    }
}
