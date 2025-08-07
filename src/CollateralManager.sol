//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CollateralManager is CCIPReceiver, Ownable {
    error CollateralManager__DepositFailed(address user);
    error CollateralManager__MustBeMoreThanZero();
    error CollateralManager__CannotRedeemMoreThanDeposited();
    error CollateralManager__InvalidReceiver();
    error CollateralManager__InsufficientLinkBalance();
    error CollateralManager__DestinationChainNotAllowListed();
    error CollateralManager__SourceChainNotAllowedList();
    error CollateralManager__SenderNotAllowedList();

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed redeemedFor, address indexed redeemedBy, uint256 amount);
    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        string text,
        address feeToken,
        uint256 fees
    );
    event MessageReceived(bytes32 indexed messageId, uint64 indexed sourceChainSelector, address sender, string text);

    mapping(address user => uint256 deposited) private s_amountDeposited;
    mapping(uint64 => bool) public s_allowListedDestinationChains;
    mapping(uint64 => bool) public s_allowListedSourceChains;
    mapping(address => bool) public s_allowListedSenders;

    uint256 public constant ADDITIONAL_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    IERC20 private s_linkToken;
    bytes32 private s_lastReceivedMessageId;
    string private s_lastReceivedText;

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert CollateralManager__MustBeMoreThanZero();
        }

        _;
    }

    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) {
            revert CollateralManager__InvalidReceiver();
        }
        _;
    }

    modifier onlyAllowListedDestinationChain(uint64 _destinationChainSelector) {
        if (!s_allowListedDestinationChains[_destinationChainSelector]) {
            revert CollateralManager__DestinationChainNotAllowListed();
        }
        _;
    }

    modifier onlyAllowListed(uint64 _sourceChainSelector, address _sender) {
        if (!s_allowListedSourceChains[_sourceChainSelector]) {
            revert CollateralManager__SourceChainNotAllowedList();
        }
        if (!s_allowListedSenders[_sender]) {
            revert CollateralManager__SenderNotAllowedList();
        }
        _;
    }

    constructor(address _router, address _link) CCIPReceiver(_router) Ownable(msg.sender) {
        s_linkToken = IERC20(_link);
    }

    // allowing source, destination and sender

    function allowDestinationChain(uint64 _destinationChainSelector, bool _allowed) external onlyOwner {
        s_allowListedDestinationChains[_destinationChainSelector] = _allowed;
    }

    function allowSourceChain(uint64 _sourceChainSelector, bool _allowed) external onlyOwner {
        s_allowListedSourceChains[_sourceChainSelector] = _allowed;
    }

    function allowSender(address _sender, bool _allowed) external onlyOwner {
        s_allowListedSenders[_sender] = _allowed;
    }

    /**
     * @notice this function allows the user to deposit collateral in weth
     * @param _tokenCollateralAddress the collateral token address. for this protocol, we are only using weth
     * @param _amount the amount they want to deposit
     */
    function deposit(address _tokenCollateralAddress, uint256 _amount) public moreThanZero(_amount) {
        s_amountDeposited[msg.sender] += _amount;
        // this will be transfering the users weth to this contract as collateral
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert CollateralManager__DepositFailed(msg.sender);
        }
        emit Deposit(msg.sender, _amount);
    }

    function depositAndRequestToken(address _tokenCollateral, uint256 _amount) external moreThanZero(_amount) {
        s_amountDeposited[msg.sender] += _amount;
        bool success = IERC20(_tokenCollateral).transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert CollateralManager__DepositFailed(msg.sender);
        }
        emit Deposit(msg.sender, _amount);
        // then functionality to send ccip request ...
    }

    /**
     * @notice this function is for the user to redeem the collateral they have deposited
     * @param _tokenCollateralAddress the collateral token to redeem
     * @param _amount the amount to redeem
     */
    function redeem(address _tokenCollateralAddress, uint256 _amount) public moreThanZero(_amount) {
        if (s_amountDeposited[msg.sender] < _amount) {
            revert CollateralManager__CannotRedeemMoreThanDeposited();
        }
        s_amountDeposited[msg.sender] -= _amount;
        IERC20(_tokenCollateralAddress).transfer(msg.sender, _amount);
        emit Redeem(msg.sender, msg.sender, _amount);
    }

    function redeemForUser(address _tokenCollateralAddress, address _user, uint256 _amount) external {
        if (s_amountDeposited[msg.sender] < _amount) {
            revert CollateralManager__CannotRedeemMoreThanDeposited();
        }
        s_amountDeposited[_user] -= _amount;
        IERC20(_tokenCollateralAddress).transferFrom(address(this), _user, _amount);
        emit Redeem(_user, msg.sender, _amount);
    }

    // weth price calculation

    /**
     * @notice this function fetches the current price for a token
     * @param _tokenCollateralAddress the token collateral we want to retreive the price for
     */
    function _fetchCollateralPrice(address _tokenCollateralAddress) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_tokenCollateralAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // as chainlink returns an 8 decimal value, we scale up to 18 decimals
        return uint256(price) * ADDITIONAL_PRECISION;
    }

    /**
     * @notice this functions calculates the collateral value for the amount requested
     * @param _tokenCollateralAddress the token collateral address
     * @param _amount the amount we want to get the price for
     */
    function calculateCollateralValue(address _tokenCollateralAddress, uint256 _amount) public view returns (uint256) {
        uint256 ethPrice = _fetchCollateralPrice(_tokenCollateralAddress);
        // we then multiply by _amount (which is also 18 decimals), giving us the price for the amount in 36 decimals
        // we then divide by 18 decimals to bring it back down to 18 decimals
        return (ethPrice * _amount) / PRECISION;
    }

    // sending the request

    function requestTokenOnSecondChain(address _tokenCollateralAddress) public {
        uint256 amountTokenToMint = calculateCollateralValue(_tokenCollateralAddress, getAmountDeposited(msg.sender));
    }

    /**
     *
     * @param _destinationChainSelector the destination chain we are sending the message to
     * @param _receiver the recipient address of the message
     * @param _text this is the text we are sending, telling the secondary chain how much stablecoin to mint
     */
    function sendMessage(uint64 _destinationChainSelector, address _receiver, string calldata _text)
        public
        onlyAllowListedDestinationChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (bytes32 messageId)
    {
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(_receiver, _text, address(s_linkToken));
        IRouterClient router = IRouterClient(this.getRouter());
        uint256 fee = IRouterClient(router).getFee(_destinationChainSelector, message);

        if (fee > s_linkToken.balanceOf(address(this))) {
            revert CollateralManager__InsufficientLinkBalance();
        }

        messageId = router.ccipSend(_destinationChainSelector, message);
        emit MessageSent(messageId, _destinationChainSelector, _receiver, _text, address(s_linkToken), fee);
        return messageId;
    }

    /**
     * @notice this function allows us to construct a message, which will be called when we want to send the message to the secondary chain
     * @param _receiver is the recipient address of the message
     * @param _text this is the text we are sending, telling the secondary chain how much stablecoin to mint
     * @param _feeTokenAddress the LINK token address
     */
    function _buildCCIPMessage(address _receiver, string calldata _text, address _feeTokenAddress)
        private
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        return (
            Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver),
                data: abi.encode(_text),
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
        s_lastReceivedText = abi.decode(message.data, (string));

        emit MessageReceived(
            message.messageId,
            message.sourceChainSelector,
            abi.decode(message.sender, (address)),
            abi.decode(message.data, (string))
        );
    }

    // getter functions
    function getAmountDeposited(address _user) public view returns (uint256) {
        return s_amountDeposited[_user];
    }

    function getLastReceivedMessageDetails() public view returns (bytes32 messageId, string memory text) {
        return (s_lastReceivedMessageId, s_lastReceivedText);
    }
}
