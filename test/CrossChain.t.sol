//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CollateralManager} from "../src/CollateralManager.sol";
import {LendingManager} from "../src/LendingManager.sol";
import {IStablecoin} from "../src/interfaces/IStablecoin.sol";
import {Stablecoin} from "../src/Stablecoin.sol";

contract CrossChain is Test {}
