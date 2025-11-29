// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter, IBorrowingAdapter} from "../IAdapter.sol";
import "../utils/Errors.sol";

interface IFluidVault {
    // nftId: 0 表示新开仓，否则传入现有 ID
    // newCol: 抵押品变动 (正存负取)
    // newDebt: 债务变动 (正借负还)
    // to: 接收资金或 NFT 的地址
    function operate(uint256 nftId, int256 newCol, int256 newDebt, address to) external payable returns (uint256, uint256, uint256);

    // 查看常量配置 (获取抵押资产和借贷资产地址)
    function constantsView() external view returns (address supplyToken, address borrowToken);

    // 获取汇率 (用于计算含利息的真实价值)
    // Fluid 内部存储的是 Raw Amount，需要乘以 Exchange Price 才是真实金额
    function updateExchangePrice() external returns (uint256 supplyExchangePrice, uint256 borrowExchangePrice);
    function exchangePricesAndRates() external view returns (uint256 supplyExchangePrice, uint256 borrowExchangePrice, uint256, uint256);
    // 获取仓位 Raw 数据 (collateral, debt)
    function fetchPositionData(uint256 nftId) external view returns (uint256, uint256);
    // 获取清算阈值 (精度通常是 1e4, 即 10000 = 100%)
    function liquidationThreshold() external view returns (uint256);

}

contract FluidAdapter is IAdapter, IBorrowingAdapter {
    using SafeERC20 for IERC20;

    address public immutable vault; // Fluid Vault 地址 (例如 ETH/USDC Vault)
    address public immutable aggregator;

    address public immutable collateralToken; // 抵押资产 (Supply Token)
    address public immutable debtToken;       // 债务资产 (Borrow Token)

    // 记录用户对应的 Fluid 仓位 ID
    // Adapter 代持有 NFT，但逻辑上归属于用户
    mapping(address => uint256) public userBftIds;

    modifier onlyAggregator() {
        if (msg.sender != aggregator) revert NotAggregator();
        _;
    }

    constructor(address _vault, address _aggregator) {
        vault = _vault;
        aggregator = _aggregator;
         // 自动读取该 Vault 支持的资产
        (collateralToken, debtToken) = IFluidVault(_vault).constantsView();
    }

    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        bytes calldata /* extra */
    ) external override onlyAggregator{
        if (asset != collateralToken) revert InvalidAsset();
        // 先把钱从 Aggregator (msg.sender) 拉到 Adapter (address(this))
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // 授权 Vault 扣款
        SafeERC20.forceApprove(IERC20(asset), vault, amount);
        // 获取用户现有的 NFT ID (如果是新用户则是 0)
        uint256 nftId = userBftIds[onBehalfOf];

        // 调用 Vault 进行存款操作
        // newCol: +amount (存入)
        // newDebt: 0
        // to: address(this) -> NFT 必须留在 Adapter 合约里，我们才能继续操作它
        (uint256 newNftId, , ) = IFluidVault(vault).operate(
            nftId,
            int256(amount),
            0,
            address(this)
        );
        // 如果是新开仓，记录下 NFT ID
        if (nftId == 0) {
            userBftIds[onBehalfOf] = newNftId;
        }
    }
    function withdraw(
        address asset,
        uint256 amount,
        address recipient,
        address owner,
        bytes calldata /* extra */
    ) external override onlyAggregator {
        if (asset != collateralToken) revert InvalidAsset();

        uint256 nftId = userBftIds[owner];
        if (nftId == 0) revert InvalidPosition();

        // newCol: -amount (取出，注意负号)
        // newDebt: 0
        // to: recipient (资金接收者)
        IFluidVault(vault).operate(
            nftId,
            -int256(amount),
            0,
            recipient
        );
    }
    function borrow(
        address asset,
        uint256 amount,
        address recipient,
        address owner,
        bytes calldata /* data */
    ) external override onlyAggregator {
        if (asset != debtToken) revert InvalidAsset();

        uint256 nftId = userBftIds[owner];
        // 必须先存款才能借款
        if (nftId == 0) revert InvalidPosition();

        // newCol: 0
        // newDebt: +amount (借出)
        // to: recipient (资金接收者)
        IFluidVault(vault).operate(
            nftId,
            0,
            int256(amount),
            recipient
        );
    }
    function repay(
        address asset,
        uint256 amount,
        address recipient,
        bytes calldata /* data */
    ) external override onlyAggregator {
        if (asset != debtToken) revert InvalidAsset();

        // 拉资产
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // 授权 Vault 扣款
        SafeERC20.forceApprove(IERC20(asset), vault, amount);
        uint256 nftId = userBftIds[recipient];
        if (nftId == 0) revert InvalidPosition();

        // newCol: 0
        // newDebt: -amount (还款，注意负号)
        // to: address(this) (资金来源是我们自己)
        IFluidVault(vault).operate(
            nftId,
            0,
            -int256(amount),
            address(this)
        );
    }
    function getHealthFactor(address account) external view override returns (uint256) {
        uint256 nftId = userBftIds[account];
        // 如果没有仓位，健康值无穷大
        if (nftId == 0) return type(uint256).max;
        // 获取 Raw Amounts （不含利息底层份额）
        (uint256 colRaw, uint256 debtRaw) = IFluidVault(vault).fetchPositionData(nftId);

        // 如果没有债务，健康值无穷大
        if (debtRaw == 0) return type(uint256).max;

        // 获取汇率
        // Fluid 的 Exchange Price 包含了利息累积
        (uint256 supplyExPrice, uint256 borrowExPrice, , ) = IFluidVault(vault).exchangePricesAndRates();

        // 获取清算阈值
        uint256 threshold = IFluidVault(vault).liquidationThreshold();

        // 计算健康因子 (全精度计算)
        // 公式: HF = (CollateralValue * Threshold) / DebtValue
        // 展开: HF = ((colRaw * supplyExPrice) * (threshold / 10000)) / (debtRaw * borrowExPrice)
        
        // 为了保持最大精度并返回 1e18 格式：
        // 分子 = colRaw * supplyExPrice * threshold * 1e18
        // 分母 = debtRaw * borrowExPrice * 10000 (threshold的精度)
        
        // 注意：Fluid 的 ExchangePrice 精度通常是 1e12，但因为分子分母都有，
        // 所以 ExchangePrice 的精度在除法中会自动抵消，我们不需要手动除以 1e12。
        uint256 numerator = colRaw * supplyExPrice * threshold * 1e18;
        uint256 denominator = debtRaw * borrowExPrice * 10000;
        return numerator / denominator;
    }
    function getDebt(address account, address asset) external view override returns (uint256) {
        if (asset != debtToken) revert InvalidAsset();
        uint256 nftId = userBftIds[account];
        if (nftId == 0) return 0;
        // 获取 Raw Amount
        (, uint256 debtRaw) = IFluidVault(vault).fetchPositionData(nftId);
        if (debtRaw == 0) return 0;
        // 获取借款汇率
        ( , uint256 borrowExPrice, , ) = IFluidVault(vault).exchangePricesAndRates();

        // Fluid 真实债务 = Raw * ExchangePrice / 1e12
        // Fluid 的 ExchangePrice 精度通常是 1e12
        return (debtRaw * borrowExPrice) / 1e12;
    }
    function getSupplyRate(address) external view override returns (uint256) { return 0; }
    function getBorrowRate(address) external view override returns (uint256) { return 0; }
    function getProtocolName() external pure override returns (bytes32) {
        return "FLUID";
    }
}