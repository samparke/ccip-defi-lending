//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

interface IStablecoin {
    function mint(address _account, uint256 _amount) external;
    function burn(address _account, uint256 _amount) external;
    function grantMintAndBurnRole(address _account) external;
    function balanceOf(address _account) external view returns (uint256);
}
