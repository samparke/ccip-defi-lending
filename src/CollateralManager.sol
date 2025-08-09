//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract CollateralManager is CCIPReceiver, Ownable {
    error CollateralManager__DepositFailed(address user);
    error CollateralManager__MustBeMoreThanZero();
    error CollateralManager__CannotRedeemMoreThanDeposited();
    error CollateralManager__InvalidReceiver();
    error CollateralManager__InsufficientLinkBalance();
    error CollateralManager__DestinationChainNotAllowListed();
    error CollateralManager__SourceChainNotAllowedList();
    error CollateralManager__SenderNotAllowedList();
    error CollateralManager__InsufficientAmountDeposited();
    error CollateralManager__RedeemFailed();
    error CollateralManager__AddToDepositCannotBeZero();

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);
    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        bytes amountStablecoinMint,
        address feeToken,
        uint256 fees
    );
    event MessageReceived(
        bytes32 indexed messageId, uint64 indexed sourceChainSelector, address sender, uint256 amountStablecoinBurned
    );
    event CollateralAddedToMapping(address _account, uint256 _amount);

    mapping(address user => uint256 deposited) private s_amountDeposited;
    mapping(uint64 => bool) public s_allowListedDestinationChains;
    mapping(uint64 => bool) public s_allowListedSourceChains;
    mapping(address => bool) public s_allowListedSenders;

    uint256 public constant ADDITIONAL_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    IERC20 private s_linkToken;
    bytes32 private s_lastReceivedMessageId;
    bytes private s_lastReceivedData;
    address private wethAddress;
    address private wethPriceFeedAddress;

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert CollateralManager__MustBeMoreThanZero();
        }

        _;
    }

    /**
     * @notice this functions ensures the receiver we are attempting to send a message to is valid
     * @param _receiver the receiver we are attempting to send the data to on the secondary chain
     */
    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) {
            revert CollateralManager__InvalidReceiver();
        }
        _;
    }

    /**
     * @notice this function checks the destination chain we are attempting to send data to is accepted
     * @param _destinationChainSelector the destination chain we are trying to pass data to
     */
    modifier onlyAllowListedDestinationChain(uint64 _destinationChainSelector) {
        if (!s_allowListedDestinationChains[_destinationChainSelector]) {
            revert CollateralManager__DestinationChainNotAllowListed();
        }
        _;
    }

    /**
     * @notice this function checks: the sourceChainSelector the sender entered was ours or acceptable, and the _sender is accepted
     * @param _sourceChainSelector when receiving a message, it checks the sourceChainSelector the user on the other chain entered was ours or accepted
     * @param _sender checking the sender who sent the message on the secondary chain is accepted
     */
    modifier onlyAllowListed(uint64 _sourceChainSelector, address _sender) {
        if (!s_allowListedSourceChains[_sourceChainSelector]) {
            revert CollateralManager__SourceChainNotAllowedList();
        }
        if (!s_allowListedSenders[_sender]) {
            revert CollateralManager__SenderNotAllowedList();
        }
        _;
    }

    constructor(address _wethAddress, address _wethPriceFeed, address _router, address _link)
        CCIPReceiver(_router)
        Ownable(msg.sender)
    {
        wethAddress = _wethAddress;
        wethPriceFeedAddress = _wethPriceFeed;
        s_linkToken = IERC20(_link);
    }

    // allowing source, destination and sender

    function allowDestinationChain(uint64 _destinationChainSelector, bool _allowed) external onlyOwner {
        s_allowListedDestinationChains[_destinationChainSelector] = _allowed;
    }

    function allowSourceChain(uint64 _sourceChainSelector, bool _allowed) external onlyOwner {
        s_allowListedSourceChains[_sourceChainSelector] = _allowed;
    }

    function allowSender(address _sender, bool _allowed) public onlyOwner {
        s_allowListedSenders[_sender] = _allowed;
    }

    /**
     * @notice this function allows the user to deposit collateral in weth
     * @param _amount the amount they want to deposit
     */
    function deposit(uint256 _amount) public moreThanZero(_amount) {
        s_amountDeposited[msg.sender] += _amount;
        // this will be transfering the users weth to this contract as collateral
        bool success = IERC20(wethAddress).transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert CollateralManager__DepositFailed(msg.sender);
        }
        emit Deposit(msg.sender, _amount);
    }

    /**
     * @notice this function is for the user to redeem the collateral they have deposited
     * @param _amount the amount to redeem
     */
    function redeem(uint256 _amount) public moreThanZero(_amount) {
        if (s_amountDeposited[msg.sender] < _amount) {
            revert CollateralManager__CannotRedeemMoreThanDeposited();
        }
        s_amountDeposited[msg.sender] -= _amount;
        bool success = IERC20(wethAddress).transfer(msg.sender, _amount);
        if (!success) {
            revert CollateralManager__RedeemFailed();
        }
        emit Redeem(msg.sender, _amount);
    }

    function _addToUserDepositMapping(address _account, uint256 _amountStableCoin) private {
        if (_amountStableCoin == 0) {
            revert CollateralManager__AddToDepositCannotBeZero();
        }
        uint256 amountWeth = calculateWethTokenAmountFromStablecoin(_amountStableCoin);
        s_amountDeposited[_account] += amountWeth;
        emit CollateralAddedToMapping(_account, amountWeth);
    }

    // weth price calculation

    /**
     * @notice this function fetches the current price for a token
     */
    function _fetchCollateralPrice() internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(wethPriceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // as chainlink returns an 8 decimal value, we scale up to 18 decimals
        return uint256(price) * ADDITIONAL_PRECISION;
    }

    /**
     * @notice this functions calculates the collateral value for the amount requested
     * @param _amount the amount we want to get the price for
     */
    function calculateCollateralValue(uint256 _amount) public view returns (uint256) {
        uint256 ethPrice = _fetchCollateralPrice();
        // we then multiply by _amount (which is also 18 decimals), giving us the price for the amount in 36 decimals
        // we then divide by 18 decimals to bring it back down to 18 decimals
        return (ethPrice * _amount) / PRECISION;
    }

    /**
     * @notice this functon calculates the number of weth equates to the number of stablecoin the user burned
     * @param _amount the amount of stablecoin the user minted on the second chain
     */
    function calculateWethTokenAmountFromStablecoin(uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(wethPriceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (_amount * PRECISION) / (uint256(price) * ADDITIONAL_PRECISION);
    }

    // sending the request

    /**
     * @notice this function is called by the user when they want to convert all their deposited collateral into tokens on the secondary chain
     * @param _destinationChainSelector the destination chain we are sending data to
     * @param _receiver the recevier address on the secondary chain
     */
    function requestAllTokenOnSecondChain(uint64 _destinationChainSelector, address _receiver) public {
        uint256 amountDeposited = getAmountDeposited(msg.sender);
        s_amountDeposited[msg.sender] -= amountDeposited;
        uint256 amountTokenToMint = calculateCollateralValue(amountDeposited);
        bytes memory data = abi.encode(msg.sender, amountTokenToMint);
        sendMessage(_destinationChainSelector, _receiver, data);
    }

    /**
     * @notice this function is called by the user when they want to convert an amount of collateral into stablecoin on the secondary chain
     * @param _destinationChainSelector the destination chain
     * @param _receiver the receiver address on the secondary chain
     * @param _amount the amount of collateral they want to convert into stablecoin
     */
    function requestTokensOnSecondChain(uint64 _destinationChainSelector, address _receiver, uint256 _amount) public {
        uint256 amountDeposited = getAmountDeposited(msg.sender);
        if (amountDeposited < _amount) {
            revert CollateralManager__InsufficientAmountDeposited();
        }
        s_amountDeposited[msg.sender] -= _amount;
        uint256 amountTokenToMint = calculateCollateralValue(_amount);
        bytes memory data = abi.encode(msg.sender, amountTokenToMint);
        sendMessage(_destinationChainSelector, _receiver, data);
    }

    /**
     *
     * @param _destinationChainSelector the destination chain we are sending the message to
     * @param _receiver the recipient address of the message
     * @param data this is the data we are sending, telling the secondary chain how much stablecoin to mint
     */
    function sendMessage(uint64 _destinationChainSelector, address _receiver, bytes memory data)
        public
        onlyAllowListedDestinationChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (bytes32 messageId)
    {
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(_receiver, data, address(s_linkToken));
        IRouterClient router = IRouterClient(this.getRouter());
        uint256 fee = IRouterClient(router).getFee(_destinationChainSelector, message);

        if (fee > s_linkToken.balanceOf(address(this))) {
            revert CollateralManager__InsufficientLinkBalance();
        }

        s_linkToken.approve(address(router), fee);
        messageId = router.ccipSend(_destinationChainSelector, message);

        emit MessageSent(messageId, _destinationChainSelector, _receiver, data, address(s_linkToken), fee);
        return messageId;
    }

    /**
     * @notice this function allows us to construct a message, which will be called when we want to send the message to the secondary chain
     * @param _receiver is the recipient address of the message
     * @param _amountTokenToMint this is the data we are sending, telling the secondary chain how much stablecoin to mint
     * @param _feeTokenAddress the LINK token address
     */
    function _buildCCIPMessage(address _receiver, bytes memory _amountTokenToMint, address _feeTokenAddress)
        private
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        return (
            Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver),
                data: _amountTokenToMint,
                tokenAmounts: new Client.EVMTokenAmount[](0),
                feeToken: _feeTokenAddress,
                extraArgs: ""
            })
        );
    }

    /**
     * @notice this function can accept messages from secondary chains
     * @param message the message sent by the secondary chain
     * @dev this will be called by the ccipReceive function when a user on the secondary chain called ccipSend
     * the message will pass through this function, allowing the contract to receive the message (if the sender and sourceChainSelector is allowed)
     */
    function _ccipReceive(Client.Any2EVMMessage memory message)
        internal
        override
        onlyAllowListed(message.sourceChainSelector, abi.decode(message.sender, (address)))
    {
        s_lastReceivedMessageId = message.messageId;
        s_lastReceivedData = message.data;
        (address user, uint256 amount) = abi.decode(message.data, (address, uint256));
        _addToUserDepositMapping(user, amount);
        emit MessageReceived(
            message.messageId,
            message.sourceChainSelector,
            abi.decode(message.sender, (address)),
            abi.decode(message.data, (uint256))
        );
    }

    // getter functions
    function getAmountDeposited(address _user) public view returns (uint256) {
        return s_amountDeposited[_user];
    }

    function getLastReceivedMessageDetails() public view returns (bytes32 messageId, bytes memory data) {
        return (s_lastReceivedMessageId, s_lastReceivedData);
    }
}
