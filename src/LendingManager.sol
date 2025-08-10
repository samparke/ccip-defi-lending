//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {CCIPReceiver} from "@ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Stablecoin} from "./Stablecoin.sol";
import {IStablecoin} from "./interfaces/IStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LendingManager is CCIPReceiver, Ownable {
    error LendingManager__InvalidReceiver();
    error LendingManager__SourceChainNotAllowedList();
    error LendingManager__SenderNotAllowedList();
    error LendingManager__InsufficientLinkBalance();
    error LendingManager__MustBeMoreThanZero();
    error LendingManager__MustBurnBeforeRequestingCollateral();
    error LendingManager__DestinationChainNotAllowListed();
    error LendingManager__CanOnlyBurnYourOwnTokens();

    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        bytes data,
        address feeToken,
        uint256 fees
    );
    event MessageReceived(bytes32 indexed messageId, uint64 indexed sourceChainSelector, address sender, bytes data);
    event StablecoinBurned(address user, uint256 amount);
    event StablecoinMinted(address user, uint256 amount);

    mapping(uint64 => bool) public s_allowedListedDestinationChains;
    mapping(uint64 => bool) public s_allowedListedSourceChains;
    mapping(address => bool) public s_allowedListedSenders;
    mapping(address user => uint256) private s_stablecoinBurned;

    bytes32 private s_lastReceivedMessageId;
    bytes private s_lastReceivedData;
    IERC20 private s_linkToken;
    IStablecoin private immutable i_stablecoin;

    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) {
            revert LendingManager__InvalidReceiver();
        }
        _;
    }

    modifier onlyAllowListedDestinationChain(uint64 _destinationChainSelector) {
        if (!s_allowedListedDestinationChains[_destinationChainSelector]) {
            revert LendingManager__DestinationChainNotAllowListed();
        }
        _;
    }

    modifier onlyAllowedList(uint64 _sourceChainSelector, address _sender) {
        if (!s_allowedListedSourceChains[_sourceChainSelector]) {
            revert LendingManager__SourceChainNotAllowedList();
        }
        if (!s_allowedListedSenders[_sender]) {
            revert LendingManager__SenderNotAllowedList();
        }
        _;
    }

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert LendingManager__MustBeMoreThanZero();
        }
        _;
    }

    constructor(IStablecoin _stablecoin, address _router, address _link) CCIPReceiver(_router) Ownable(msg.sender) {
        i_stablecoin = _stablecoin;
        s_linkToken = IERC20(_link);
    }

    function allowDestinationChain(uint64 _destinationChainSelector, bool _allowed) external onlyOwner {
        s_allowedListedDestinationChains[_destinationChainSelector] = _allowed;
    }

    function allowSourceChain(uint64 _sourceChainSelector, bool _allowed) external onlyOwner {
        s_allowedListedSourceChains[_sourceChainSelector] = _allowed;
    }

    function allowSender(address _sender, bool _allowed) public onlyOwner {
        s_allowedListedSenders[_sender] = _allowed;
    }

    /**
     * @notice mints stablecoin to user
     * @param _account the account we are minting stablecoin to
     * @param _amount the amount of stablecoin we are minting
     */
    function _mintStablecoin(address _account, uint256 _amount) internal moreThanZero(_amount) {
        i_stablecoin.mint(_account, _amount);
        emit StablecoinMinted(_account, _amount);
    }

    /**
     * @notice burns stablecoin from user
     * @param _amount thw amount of stablecoin we are burning
     */
    function burnStablecoin(uint256 _amount) external moreThanZero(_amount) {
        s_stablecoinBurned[msg.sender] += _amount;
        i_stablecoin.burn(msg.sender, _amount);
        emit StablecoinBurned(msg.sender, _amount);
    }

    /**
     * @notice requests collateral to be returned on the destination chain
     * @param _destinationChainSelector the destination chain we are sending the data to
     * @param _receiver the receiver on the destination chain
     * @dev first we get the amount the user has burned, then, we encode this (along with their address), reduce the burned
     * mapping, and send the encode message
     */
    function requestCollateralReturn(uint64 _destinationChainSelector, address _receiver) public {
        uint256 amountBurned = getAmountBurned(msg.sender);
        if (amountBurned == 0) {
            revert LendingManager__MustBurnBeforeRequestingCollateral();
        }
        s_stablecoinBurned[msg.sender] -= amountBurned;
        bytes memory accountBurned = abi.encode(msg.sender, amountBurned);
        sendMessage(_destinationChainSelector, _receiver, accountBurned);
    }

    /**
     * @notice sends the message to the destination chain
     * @param _destinationChainSelector the destination chain we are sending data to
     * @param _receiver the receiver on the destination chain
     * @param _amountStablecoinBurned the amount of stablecoin the user burned, and want to be converted into collateral on other chain
     */
    function sendMessage(uint64 _destinationChainSelector, address _receiver, bytes memory _amountStablecoinBurned)
        public
        onlyAllowListedDestinationChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (bytes32 messageId)
    {
        Client.EVM2AnyMessage memory message =
            _buildCCIPMessage(_receiver, _amountStablecoinBurned, address(s_linkToken));
        IRouterClient router = IRouterClient(this.getRouter());
        uint256 fee = IRouterClient(router).getFee(_destinationChainSelector, message);

        if (fee > s_linkToken.balanceOf(address(this))) {
            revert LendingManager__InsufficientLinkBalance();
        }
        s_linkToken.approve(address(router), fee);
        messageId = router.ccipSend(_destinationChainSelector, message);
        emit MessageSent(
            messageId, _destinationChainSelector, _receiver, _amountStablecoinBurned, address(s_linkToken), fee
        );
        return messageId;
    }

    /**
     * @notice allows the contract to receive messages, such as how much stablecoin to mint
     * @param message the data being passed to the destination chain
     */
    function _ccipReceive(Client.Any2EVMMessage memory message)
        internal
        override
        onlyAllowedList(message.sourceChainSelector, abi.decode(message.sender, (address)))
    {
        s_lastReceivedMessageId = message.messageId;
        s_lastReceivedData = message.data;
        emit MessageReceived(
            message.messageId, message.sourceChainSelector, abi.decode(message.sender, (address)), message.data
        );
        (address user, uint256 amount) = abi.decode(message.data, (address, uint256));
        i_stablecoin.mint(user, amount);
    }

    /**
     * @notice builds the structured message to be passed in the sendMessage function
     * @param _receiver the receiver on the destination chain
     * @param _data the data we are sending, such as how much stablecoin the user burned
     * @param _feeTokenAddress the link token address
     */
    function _buildCCIPMessage(address _receiver, bytes memory _data, address _feeTokenAddress)
        private
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        return (
            Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver),
                data: _data,
                tokenAmounts: new Client.EVMTokenAmount[](0),
                feeToken: _feeTokenAddress,
                extraArgs: ""
            })
        );
    }

    // getter

    function getAmountBurned(address _user) public view returns (uint256) {
        return s_stablecoinBurned[_user];
    }

    function getBalance(address _user) public view returns (uint256) {
        return i_stablecoin.balanceOf(_user);
    }

    function getLastReceivedMessageDetails() public view returns (bytes32 messageId, bytes memory data) {
        return (s_lastReceivedMessageId, s_lastReceivedData);
    }

    function getIsAllowedSender(address _sender) public view returns (bool) {
        return s_allowedListedSenders[_sender];
    }

    function getIsAllowedDestinationChain(uint64 _destinationChain) public view returns (bool) {
        return s_allowedListedDestinationChains[_destinationChain];
    }

    function getIsAllowedSourceChain(uint64 _sourceChain) public view returns (bool) {
        return s_allowedListedSourceChains[_sourceChain];
    }
}
