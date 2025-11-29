// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAdapter {
    function deposit(address asset, uint256 amount, address recipient, bytes calldata data) external;
    function withdraw(address asset, uint256 amount, address recipient, address owner, bytes calldata data) external;
    function getSupplyRate(address asset) external view returns (uint256);
    function getProtocolName() external view returns (bytes32);
}

interface IBorrowingAdapter is IAdapter {
    function borrow(address asset, uint256 amount, address recipient, address owner, bytes calldata data) external;
    function repay(address asset, uint256 amount, address recipient, bytes calldata data) external;
    function getHealthFactor(address account) external view returns (uint256);
    function getDebt(address account, address asset) external view returns (uint256);
    function getBorrowRate(address asset) external view returns (uint256);
}