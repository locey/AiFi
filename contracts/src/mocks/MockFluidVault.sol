// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockFluidVault {
    using SafeERC20 for IERC20;

    address public immutable supplyToken;
    address public immutable borrowToken;

    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    // 模拟存储: NFT ID => Position
    mapping(uint256 => Position) public positions;
    uint256 public nextNftId = 1000; // 从 1000 开始，方便区分

    // 模拟参数
    uint256 public supplyPrice = 1e12; // 假设抵押资产汇率为 1e12
    uint256 public borrowPrice = 1e12; // 假设借贷资产汇率为 1e12
    uint256 public threshold = 8000; // 80%

    uint256 public supplyRate = 0; // 模拟供应利率
    uint256 public borrowRate = 0; // 模拟借款利率

    constructor(address _supplyToken, address _borrowToken) {
        supplyToken = _supplyToken;
        borrowToken = _borrowToken;
    }

    // --- Fluid 核心接口实现 ---
    function operate(
        uint256 nftId,
        int256 newCol,
        int256 newDebt,
        address to
    ) external payable returns (uint256, uint256, uint256) {
        // 简化逻辑: 仅处理存取款和借还款
        if (nftId == 0) {
            nftId = nextNftId++;
        }
        Position storage pos = positions[nftId];

        if (newCol > 0) {
            // 存入抵押品
            uint256 amount = uint256(newCol);
            IERC20(supplyToken).safeTransferFrom(msg.sender, address(this), amount);
            pos.collateral += amount;
        } else if (newCol < 0) {
            // 取出抵押品
            uint256 amount = uint256(-newCol);
            require(pos.collateral >= amount, "Insufficient collateral");
            pos.collateral -= amount;
            IERC20(supplyToken).safeTransfer(to, amount);
        }

        if (newDebt > 0) {
            // 借款
            uint256 amount = uint256(newDebt);
            pos.debt += amount;
            IERC20(borrowToken).safeTransfer(to, amount);
        } else if (newDebt < 0) {
            // 还款
            uint256 amount = uint256(-newDebt);
            IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);
            if (pos.debt >= amount) {
                pos.debt -= amount;
            } else {
                pos.debt = 0;
            }
        }

        return (nftId, pos.collateral, pos.debt);
    }

    function constantsView() external view returns (address, address) {
        return (supplyToken, borrowToken);
    }

    function fetchPositionData(uint256 nftId) external view returns (uint256, uint256) {
        return (positions[nftId].collateral, positions[nftId].debt);
    }

    function exchangePricesAndRates() external view returns (uint256, uint256, uint256, uint256) {
        return (supplyPrice, borrowPrice, 0, 0);
    }

    function liquidationThreshold() external view returns (uint256) {
        return threshold;
    }

    // --- 测试专用 Helper 函数 ---
    // 允许我们在测试中随意修改汇率，模拟暴跌
    function setExchangePrices(uint256 _supply, uint256 _borrow) external {
        supplyPrice = _supply;
        borrowPrice = _borrow;
    }

    function setRates(uint256 _supplyRate, uint256 _borrowRate) external {
        supplyRate = _supplyRate;
        borrowRate = _borrowRate;
    }
}