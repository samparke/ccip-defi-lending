//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Test, console, console2} from "forge-std/Test.sol";
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
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LendingManagerTest is Test {
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

    modifier depositOnSepolia() {
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);
        _;
    }

    modifier depositOnSepoliaAndMintOnArbSepolia() {
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);
        _;
    }

    function testStablecoinMintedEvent() public {
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        // vm.expectEmit();
        // emit LendingManager.StablecoinMinted(user, 2e22);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);
    }

    function testBurnIncreasesUserBurnMappingAndReducesBalanceAndEmitsEvent()
        public
        depositOnSepoliaAndMintOnArbSepolia
    {
        uint256 userBalanceBeforeBurn = lendingManager.getBalance(user);
        // eth price is $2000, hence stablecoin amount will be 10 ether * 2000
        assertEq(userBalanceBeforeBurn, 10 ether * 2000);
        assertEq(lendingManager.getAmountBurned(user), 0);
        vm.prank(user);
        vm.expectEmit();
        emit LendingManager.StablecoinBurned(user, 1 ether * 2000);
        lendingManager.burnStablecoin(1 ether * 2000);
        uint256 userBalanceAfterBurn = lendingManager.getBalance(user);
        assertEq(userBalanceAfterBurn, (userBalanceBeforeBurn) - (1 ether * 2000));
        assertLt(userBalanceAfterBurn, userBalanceBeforeBurn);
        assertEq(lendingManager.getAmountBurned(user), 1 ether * 2000);
    }

    function testGetLastMessageId() public depositOnSepoliaAndMintOnArbSepolia {
        (, bytes memory data) = lendingManager.getLastReceivedMessageDetails();
        (address userAddress, uint256 amount) = abi.decode(data, (address, uint256));
        assertEq(userAddress, user);
        // 10 (1e19) ether into stablecoin ($2000)
        assertEq(amount, 2e22);
    }

    // must burn before requesting revert

    function testMustBurnBeforeRequestingCollateralRevert() public depositOnSepoliaAndMintOnArbSepolia {
        vm.prank(user);
        vm.expectRevert(LendingManager.LendingManager__MustBurnBeforeRequestingCollateral.selector);
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
    }

    // cannot burn more than zero

    function testBurnCannotBeZeroRevert() public depositOnSepoliaAndMintOnArbSepolia {
        vm.prank(user);
        vm.expectRevert(LendingManager.LendingManager__MustBeMoreThanZero.selector);
        lendingManager.burnStablecoin(0);
    }

    // insufficent link

    function testInsufficientLinkRevert() public depositOnSepoliaAndMintOnArbSepolia {
        vm.prank(user);
        lendingManager.burnStablecoin(1 ether);
        vm.prank(user);
        vm.expectRevert(LendingManager.LendingManager__InsufficientLinkBalance.selector);
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
    }

    // invalid receiver

    function testInvalidReceiverRevert() public depositOnSepoliaAndMintOnArbSepolia {
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(lendingManager), 1e21);
        vm.prank(user);
        lendingManager.burnStablecoin(1 ether);
        vm.prank(user);
        vm.expectRevert(LendingManager.LendingManager__InvalidReceiver.selector);
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(0));
    }

    // not allowed destination chain

    function testNotAllowedDestinationChain() public depositOnSepoliaAndMintOnArbSepolia {
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(lendingManager), 1e21);
        vm.prank(owner);
        lendingManager.allowDestinationChain(sepoliaNetworkDetails.chainSelector, false);
        vm.prank(user);
        lendingManager.burnStablecoin(1 ether);
        vm.prank(user);
        vm.expectRevert(LendingManager.LendingManager__DestinationChainNotAllowListed.selector);
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
    }

    function testOnlyOwnerCanNotAllowDestinationChain() public {
        // without ensuring we are on the correct chain, "call didn't revert at a lower depth than cheatcode call depth" error
        vm.selectFork(arbSepoliaFork);
        vm.prank(user);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        lendingManager.allowDestinationChain(sepoliaNetworkDetails.chainSelector, false);
    }

    // not allowed sender

    // function testNotAllowedSourceChain() public {
    //     vm.prank(owner);
    //     lendingManager.allowSourceChain(sepoliaNetworkDetails.chainSelector, false);

    //     vm.prank(user);
    //     weth.approve(address(collateralManager), 10 ether);
    //     vm.prank(user);
    //     collateralManager.deposit(10 ether);

    //     ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
    //     vm.prank(user);
    //     collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
    //     vm.expectRevert(LendingManager.LendingManager__SourceChainNotAllowedList.selector);
    //     ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);
    // }

    function testAllowSender() public {
        vm.selectFork(arbSepoliaFork);
        vm.prank(owner);
        lendingManager.allowSender(address(lendingManager), true);
        assertTrue(lendingManager.getIsAllowedSender(address(lendingManager)));
    }

    function testAllowDestinationChain() public {
        vm.selectFork(arbSepoliaFork);
        vm.prank(owner);
        lendingManager.allowDestinationChain(arbSepoliaNetworkDetails.chainSelector, true);
        assertTrue(lendingManager.getIsAllowedDestinationChain(arbSepoliaNetworkDetails.chainSelector));
    }

    function testAllowSourceChain() public {
        vm.selectFork(arbSepoliaFork);
        vm.prank(owner);
        lendingManager.allowSourceChain(arbSepoliaNetworkDetails.chainSelector, true);
        assertTrue(lendingManager.getIsAllowedSourceChain(arbSepoliaNetworkDetails.chainSelector));
    }

    // request collateral

    function testRequestCollateralAndEventEmits() public depositOnSepoliaAndMintOnArbSepolia {
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(lendingManager), 1e21);
        vm.prank(user);
        lendingManager.burnStablecoin(1 ether);
        vm.prank(user);
        vm.expectEmit(false, true, false, false);
        emit LendingManager.MessageSent(
            bytes32(0), sepoliaNetworkDetails.chainSelector, address(0), bytes(""), address(0), 0
        );
        lendingManager.requestCollateralReturn(sepoliaNetworkDetails.chainSelector, address(collateralManager));
    }

    function testMessageReceivedEvent() public {
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        vm.expectEmit(false, true, false, false);
        emit LendingManager.MessageReceived(
            bytes32(0), sepoliaNetworkDetails.chainSelector, address(collateralManager), bytes("")
        );
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);
    }

    // not allow source chain

    function testNotAllowedSourceChain() public {
        vm.selectFork(arbSepoliaFork);
        vm.prank(owner);
        lendingManager.allowSourceChain(sepoliaNetworkDetails.chainSelector, false);

        vm.selectFork(sepoliaFork);
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        vm.expectRevert();
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);
    }

    // not allow sender

    function testNotAllowedSenderCollateralManager() public {
        vm.selectFork(arbSepoliaFork);
        vm.prank(owner);
        lendingManager.allowSender(address(collateralManager), false);

        vm.selectFork(sepoliaFork);
        vm.prank(user);
        weth.approve(address(collateralManager), 10 ether);
        vm.prank(user);
        collateralManager.deposit(10 ether);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(collateralManager), 1e21);
        vm.prank(user);
        collateralManager.requestAllTokenOnSecondChain(arbSepoliaNetworkDetails.chainSelector, address(lendingManager));
        vm.expectRevert();
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbSepoliaFork);
    }
}
