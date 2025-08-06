//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

contract CollateralManager is CCIPReceiver {
    error CollateralManager__DepositFailed(address user);
    error CollateralManager__MustBeMoreThanZero();
    error CollateralManager__CannotRedeemMoreThanDeposited();
    error CollateralManager__InvalidReceiver();
    error CollateralManager__InsufficientLinkBalance();

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

    mapping(address user => uint256 deposited) private s_amountDeposited;

    uint256 public constant ADDITIONAL_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    IERC20 private s_linkToken;

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

    constructor(address _router, address _link) CCIPReceiver(_router) {
        s_linkToken = IERC20(_link);
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

    function sendMessage(uint64 _destinationChainSelector, address _receiver, string calldata _text)
        public
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

    // getter functions
    function getAmountDeposited(address _user) public view returns (uint256) {
        return s_amountDeposited[_user];
    }
}
