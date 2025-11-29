// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol"; // 引入 Metadata 接口获取 decimals
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Aggregator} from "../src/Aggregator.sol"; 
import {CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {IComet} from "../src/adapters/CompoundV3Adapter.sol";

// 辅助接口用于获取抵押品信息
interface ICometHelper {
    function numAssets() external view returns (uint8);
    function getAssetInfo(uint8 i) external view returns (AssetInfo memory);
    function baseTokenPriceFeed() external view returns (address);
}

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

// Compound V3 updateAsset 需要的结构体
struct AssetConfig {
    address asset;
    address priceFeed;
    uint8 decimals;
    uint64 borrowCollateralFactor;
    uint64 liquidateCollateralFactor;
    uint64 liquidationFactor;
    uint128 supplyCap;
}

contract CompoundV3AdapterTest is Test {
    // --- Sepolia Addresses ---
    // Compound V3 USDC Market (cUSDCv3) on Sepolia
    address constant COMET_USDC = 0xAec1F48e02Cfb822Be958B68C7957156EB3F0b6e;
    // USDC Token on Sepolia
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    Aggregator public aggregator;
    CompoundV3Adapter public adapter;

    address public user;
    address public flashExecutor = address(0x123); // 暂时随便填一个

    address public collateralAsset;
    uint256 public collateralDecimals;

    function setUp() public {
        // fork Sepolia testnet
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        // 强制更新时间戳，防止预言机判定价格过期
        vm.warp(block.timestamp + 100);

        // 部署合约
        aggregator = new Aggregator(flashExecutor);
        adapter = new CompoundV3Adapter(COMET_USDC, address(aggregator));

        // 配置 Aggregator(开启 Adapter)
        aggregator.setAdapter(address(adapter), true);

        // 准备测试用户
        user = makeAddr("user");

        // 给用户 mint 一些 USDC
        vm.deal(user, 10 ether); // 给用户一些 ETH 用于支付Gas手续费
        deal(USDC, user, 1000 * 1e6); // 给用户 mint 1000 USDC (USDC 有 6 位小数)

        // 打印一下余额，确认是否成功
        console.log("User USDC Balance:", IERC20(USDC).balanceOf(user));

        // --- 动态获取一个WBTC抵押品资产 --- 
        uint8 numAssets = ICometHelper(COMET_USDC).numAssets();
        require(numAssets > 0, "No assets in Comet");
        AssetInfo memory info = ICometHelper(COMET_USDC).getAssetInfo(0);
        collateralAsset = info.asset;
        console.log("Collateral Asset for borrowing test:", collateralAsset);
        console.log("Original Borrow Factor:", info.borrowCollateralFactor);

        // --- 动态获取精度 ---
        collateralDecimals = IERC20Metadata(collateralAsset).decimals();
        console.log("Collateral Asset:", collateralAsset);
        console.log("Collateral Decimals:", collateralDecimals);
        console.log("Asset Scale in Comet:", info.scale);

        // --- Mock 价格预言机---
        // 只要 Factor > 0 (日志显示是 0.65)，配合高价格 Mock，就能借款
        address priceFeed = info.priceFeed;
        console.log("Price Feed:", priceFeed);

        // Mock WBTC 价格: $100,000
        int256 mockPrice = 100000 * 1e8; 
        vm.mockCall(
            priceFeed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), mockPrice, block.timestamp, block.timestamp, uint80(1))
        );

        address baseFeed = ICometHelper(COMET_USDC).baseTokenPriceFeed();
        console.log("Base Token Price Feed:", baseFeed);
        
        if (baseFeed != address(0)) {
            int256 mockUsdcPrice = 1 * 1e8; 
            vm.mockCall(
                baseFeed,
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(uint80(1), mockUsdcPrice, block.timestamp, block.timestamp, uint80(1))
            );
        }

        // 给用户发巨量抵押品 (10 WBTC)
        deal(collateralAsset, user, 10 * (10 ** collateralDecimals)); 

        // 打印一下余额，确认是否成功
        console.log("User Collateral Asset Balance:", IERC20(collateralAsset).balanceOf(user));
    }

    function testDeposit() public {
        uint256 amount = 100 * 1e6; // 100 USDC

        vm.startPrank(user);

        // 授权
        IERC20(USDC).approve(address(aggregator), amount);

        // 存款
        bytes32 posId = aggregator.deposit(
            bytes32(0),
            USDC,
            amount,
            address(adapter),
            ""
        );
        
        vm.stopPrank();

        // 验证Aggregator记录
        Aggregator.Position memory pos = aggregator.getPosition(posId);

        assertEq(pos.owner, user);
        assertEq(pos.collateralAsset, USDC);
        assertEq(pos.collateralAmount, amount);

        // 验证 Compound 状态 (cUSDCv3 的 balanceOf 代表存款)
        uint256 cometBalance = IERC20(COMET_USDC).balanceOf(user);
        assertApproxEqAbs(cometBalance, amount, 2);
    }

    function testWithdraw() public {
        uint256 amount = 100 * 1e6; // 100 USDC

        vm.startPrank(user);

        // 先存
        IERC20(USDC).approve(address(aggregator), amount);
        bytes32 posId = aggregator.deposit(
            bytes32(0),
            USDC,
            amount,
            address(adapter),
            ""
        );

        // 再提
        IComet(COMET_USDC).allow(address(adapter), true); // 允许 Adapter 管理资金

        uint256 balanceBefore = IERC20(USDC).balanceOf(user);
        // 提现金额稍微减少一点点，防止因为 Compound 精度损失导致触发“借款”逻辑
        uint256 withdrawAmount = amount - 10;
        aggregator.withdraw(posId, withdrawAmount, "");
        vm.stopPrank();

        // 验证
        Aggregator.Position memory pos = aggregator.getPosition(posId);
        assertEq(pos.collateralAmount, 10);
        assertEq(
            IERC20(USDC).balanceOf(user),
            balanceBefore + withdrawAmount
        );
    }

    function testBorrow() public {
        // 使用巨量抵押品，淹没所有价格精度问题
        uint256 supplyAmount = 1 * (10 ** collateralDecimals); // 1 WBTC
        uint256 borrowAmount = 100 * 1e6;   // 借 100 USDC

        vm.startPrank(user);

        // 抵押 WBTC
        IERC20(collateralAsset).approve(address(aggregator), supplyAmount);
        bytes32 posId = aggregator.deposit(
            bytes32(0),
            collateralAsset,
            supplyAmount,
            address(adapter),
            ""
        );

        // 允许 Adapter 管理资金
        IComet(COMET_USDC).allow(address(adapter), true);

        // 借款 USDC
        aggregator.borrow(
            posId,
            USDC,
            borrowAmount,
            ""
        );
        vm.stopPrank();

        // 验证
        Aggregator.Position memory pos = aggregator.getPosition(posId);
        assertEq(pos.debtAsset, USDC);
        assertEq(pos.debtAmount, borrowAmount);

        // 验证 Compound 链上债务
        uint256 cometDebt = IComet(COMET_USDC).borrowBalanceOf(user);
        assertApproxEqAbs(cometDebt, borrowAmount, 100); // 允许微小利息误差
    }

    function testRepay() public {
        uint256 supplyAmount = 1 * (10 ** collateralDecimals); // 1 WBTC
        uint256 borrowAmount = 100 * 1e6;   // 借 100 USDC

        vm.startPrank(user);

        // 抵押 WBTC
        IERC20(collateralAsset).approve(address(aggregator), supplyAmount);
        bytes32 posId = aggregator.deposit(
            bytes32(0),
            collateralAsset,
            supplyAmount,
            address(adapter),
            ""
        );

        // 允许 Adapter 管理资金
        IComet(COMET_USDC).allow(address(adapter), true);

        // 借款 USDC
        aggregator.borrow(
            posId,
            USDC,
            borrowAmount,
            ""
        );

        // 模拟时间流逝,以产生一些利息
        vm.warp(block.timestamp + 100);

        // 还款
        IERC20(USDC).approve(address(aggregator), borrowAmount);

        console.log("User USDC Balance:", IERC20(USDC).balanceOf(user));
        console.log("Adapter USDC Balance:", IERC20(USDC).balanceOf(address(adapter)));

        aggregator.repay(
            posId,
            USDC,
            borrowAmount,
            ""
        );
        vm.stopPrank();

        // 验证
        Aggregator.Position memory pos = aggregator.getPosition(posId);
        assertEq(pos.debtAmount, 0);

        // 验证 Compound 链上债务
        uint256 cometDebt = IComet(COMET_USDC).borrowBalanceOf(user);
        // 允许极小的误差（因为可能有 100 秒的利息未还，或者精度截断）
        assertApproxEqAbs(cometDebt, 0, 1000); 
    }
}