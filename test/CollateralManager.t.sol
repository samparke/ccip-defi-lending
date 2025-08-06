//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CollateralManager} from "../src/CollateralManager.sol";

contract CollateralManagerTest is Test {
    CollateralManager collateralManager;
    address user = makeAddr("user");

    function setUp() public {
        collateralManager = new CollateralManager();
    }
}
