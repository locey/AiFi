// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter, IBorrowingAdapter} from "../IAdapter.sol";

import "../utils/Errors.sol";


struct AssetInfo {
    uint8 offset;
    address asset;
    address priceFeed;
    uint64 scale;
    uint64 borrowCollateralFactor;
    uint64 liquidateCollateralFactor;
    uint64 liquidationFactor;
    uint128 supplyCap;
}

interface IComet {
    function supply(address asset, uint256 amount) external;

    function withdraw(address asset, uint256 amount) external;

    function supplyTo(address dst, address asset, uint256 amount) external;

    function withdrawFrom(address src, address to, address asset, uint256 amount) external;

    function borrow(address asset, uint256 amount) external; // V3 中借款通常也是通过 withdraw 操作基础资产实现，但这里为了清晰先列出

    function allow(address manager, bool isAllowed) external;

    function isAllowed(address owner, address manager) external view returns (bool);

    function userCollateral(address account, address asset) external view returns (uint128 balance, uint128 _reserved);

    function borrowBalanceOf(address account) external view returns (uint256);

    function baseToken() external view returns (address);

    function baseScale() external view returns (uint256);
    function baseTokenPriceFeed() external view returns (address);
    function numAssets() external view returns (uint8);
    function getAssetInfo(uint8 i) external view returns (AssetInfo memory);
    function getPrice(address priceFeed) external view returns (uint256);
    
    function isLiquidatable(address account) external view returns (bool);
    function getSupplyRate(uint256 utilization) external view returns (uint64);
    function getBorrowRate(uint256 utilization) external view returns (uint64);
    function getUtilization() external view returns (uint256);
}

contract CompoundV3Adapter is IAdapter, IBorrowingAdapter {
    using SafeERC20 for IERC20;

    address public immutable comet; // Compound V3 合约地址
    address public immutable aggregator; // Aggregator 合约地址

    modifier onlyAggregator() {
        if (msg.sender != aggregator) revert NotAggregator();
        _;
    }

    constructor(address _comet, address _aggregator) {
        comet = _comet;
        aggregator = _aggregator;
    }

    // 存款
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        bytes calldata /* extra */
    ) external override onlyAggregator {
        // 先把钱从 Aggregator (msg.sender) 拉到 Adapter (address(this))
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // 授权 Compound 合约扣款
        SafeERC20.forceApprove(IERC20(asset), comet, amount);
        // 存入 Compound V3
        IComet(comet).supplyTo(onBehalfOf, asset, amount);
    }

    // 提取
    function withdraw(
        address asset,
        uint256 amount,
        address recipient,
        address owner,
        bytes calldata /* extra */
    ) external override onlyAggregator {
        // Compound V3 需要用户先在链上授权 Adapter (allow manager) 才能操作用户的钱
        // 这里我们假设用户已经授权了 Adapter 合约作为 manager
        // 从 owner 账户提取资产发送给 recipient
        IComet(comet).withdrawFrom(owner, recipient, asset, amount);
    }

    // 借款
    function borrow(
        address asset,
        uint256 amount,
        address recipient,
        address owner,
        bytes calldata /* data */
    ) external override onlyAggregator {
        // 检查：只能借基础资产 (Base Token)
        address baseToken = IComet(comet).baseToken();
        if (asset != baseToken) revert InvalidAsset();
        // 执行借款
        IComet(comet).withdrawFrom(owner, recipient, asset, amount);
    }

    // 还款
    function repay(
        address asset,
        uint256 amount,
        address recipient,
        bytes calldata /* data */
    ) external override onlyAggregator {
        // 只能还基础资产
        address baseToken = IComet(comet).baseToken();
        if (asset != baseToken) revert InvalidAsset();
        // 先把还款资产从 Aggregator (msg.sender) 拉到 Adapter (address(this))
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // 授权Compount扣款
        SafeERC20.forceApprove(IERC20(asset), comet, amount);
        // 执行还款，recipient 是债务所属人
        IComet(comet).supplyTo(recipient, asset, amount);
    }

    // --- 查询视图 ---
    function getHealthFactor(address account) external view override returns (uint256) {
        // 获取债务余额
        uint256 debtBalance = IComet(comet).borrowBalanceOf(account);
        
        // 如果没有债务，健康值无穷大
        if (debtBalance == 0) {
            return type(uint256).max;
        }

        IComet cometContract = IComet(comet);
        uint8 numAssets = cometContract.numAssets();
        uint256 totalCollateralValue = 0;

        // 遍历所有资产计算加权抵押价值
        for (uint8 i=0; i< numAssets; i++) {
            AssetInfo memory info = cometContract.getAssetInfo(i);
            (uint128 balance, ) = cometContract.userCollateral(account, info.asset);

            if (balance > 0) {
                uint256 price = cometContract.getPrice(info.priceFeed);
                // 计算公式: (余额 * 价格 * 清算因子) / 资产精度
                uint256 value = (uint256(balance) * price * info.liquidateCollateralFactor) / info.scale;
                totalCollateralValue += value;
            }
        }

        // 计算债务价值
        address basePriceFeed = cometContract.baseTokenPriceFeed();
        uint256 basePrice = cometContract.getPrice(basePriceFeed);
        uint256 baseScale = cometContract.baseScale();

        // 债务价值 = (债务余额 * 价格) / 资产精度
        uint256 debtValue = (debtBalance * basePrice) / baseScale;
        if (debtValue == 0) {
            return type(uint256).max;
        }

        return totalCollateralValue / debtValue;
    }

    function getDebt(address account, address asset) external view override returns (uint256) {
        // 这里只支持基础资产的债务查询
        address baseToken = IComet(comet).baseToken();
        // 只有基础资产才会有债务
        if (asset == baseToken) {
            return IComet(comet).borrowBalanceOf(account);
        }
        // 如果查询的是抵押品，债务为 0
        return 0;
    }

    function getSupplyRate(address asset) external view override returns (uint256) {
        address baseToken = IComet(comet).baseToken();
        // 只有基础资产才有存款收益
        if (asset != baseToken) {
            return 0;
        }

        // 获取当前利率
        uint256 utilization = IComet(comet).getUtilization();

        // 获取每秒存款利率
        uint64 ratePerSecond = IComet(comet).getSupplyRate(utilization);

        // 转换为年化利率 (APY)
        // 365 days = 31536000 seconds
        return uint256(ratePerSecond) * 365 days;
    }

    function getBorrowRate(address asset) external view returns (uint256) {
        address baseToken = IComet(comet).baseToken();
        if (asset != baseToken) return 0;

        uint256 utilization = IComet(comet).getUtilization();
        uint64 ratePerSecond = IComet(comet).getBorrowRate(utilization);

        return uint256(ratePerSecond) * 365 days;
    }

    function getProtocolName() external pure override returns (bytes32) {
        return "COMPOUND_V3";
    }
}
