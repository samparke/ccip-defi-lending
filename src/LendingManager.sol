//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {CCIPReceiver} from "@ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Stablecoin} from "./Stablecoin.sol";
import {IStablecoin} from "./interfaces/IStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";

contract LendingManager {
    error LendingManager__InvalidReceiver();
    error LendingManager__SourceChainNotAllowedList();
    error LendingManager__SenderNotAllowedList();

    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        bytes data,
        address feeToken,
        uint256 fees
    );
    event MessageReceived(bytes32 indexed messageId, uint64 indexed sourceChainSelector, address sender, bytes data);

    mapping(uint64 => bool) public s_allowedListedDestinationChains;
    mapping(uint64 => bool) public s_allowedListedSourceChains;
    mapping(address => bool) public s_allowedListedSenders;

    bytes32 private s_lastReceivedMessageId;
    bytes private s_lastReceivedData;

    IStablecoin private immutable i_stablecoin;

    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) {
            revert LendingManager__InvalidReceiver();
            _;
        }
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

    constructor(IStablecoin _stablecoin) {
        i_stablecoin = _stablecoin;
    }

    function mintStablecoin(address _account, uint256 _amount) public {
        i_stablecoin.mint(_account, _amount);
    }

    function burnStablecoin(address _account, uint256 _amount) public {
        i_stablecoin.burn(_account, _amount);
    }

    function _ccipReceive(Client.Any2EVMMessage memory message)
        internal
        onlyAllowedList(message.sourceChainSelector, abi.decode(message.sender, (address)))
    {
        s_lastReceivedMessageId = message.messageId;
        s_lastReceivedData = message.data;

        emit MessageReceived(
            message.messageId, message.sourceChainSelector, abi.decode(message.sender, (address)), message.data
        );
    }

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
}
