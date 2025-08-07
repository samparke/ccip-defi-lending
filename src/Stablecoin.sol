//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Stablecoin is ERC20, ERC20Burnable, Ownable, AccessControl {
    bytes32 private constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");

    constructor() ERC20("Stablecoin", "SBL") Ownable(msg.sender) {}

    function grantMintAndBurnRole(address _user) public onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _user);
    }

    function mint(address _account, uint256 _amount) public onlyRole(MINT_AND_BURN_ROLE) {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) public onlyRole(MINT_AND_BURN_ROLE) {
        _burn(_account, _amount);
    }
}
