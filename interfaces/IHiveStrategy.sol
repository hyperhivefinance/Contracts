// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IHiveStrategy {
    function principal() external view returns (uint256);

    function asset() external view returns (address);

    function market() external view returns (address);

    function pendingRewards() external view returns (uint256);

    function harvest() external;

    function retryDeposit() external;

    function deposit(uint256 assets) external;

    function withdraw(uint256 assets) external;

    function withdrawAll() external;
}
