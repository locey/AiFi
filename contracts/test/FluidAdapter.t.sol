// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFluidVault} from "../src/adapters/FluidAdapter.sol";
import {FluidAdapter} from "../src/adapters/FluidAdapter.sol";
import {Aggregator} from "../src/Aggregator.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFluidVault} from "../src/mocks/MockFluidVault.sol";

contract FluidAdapterTest is Test {
    Aggregator public aggregator;
    FluidAdapter public adapter;
    MockFluidVault public vault;

    MockERC20 public collateralToken;
    MockERC20 public debtToken;

    address user = makeAddr("user");
    address flashExecutor = makeAddr("flashExecutor");

    function setUp() public {
        // 部署 Mock 代币
        collateralToken = new MockERC20("Wrapped Ether", "WETH");
        debtToken = new MockERC20("USD Coin", "USDC");

        // 部署 Mock Fluid Vault
        vault = new MockFluidVault(address(collateralToken), address(debtToken));
        // 设置初始汇率，模拟 ETH = $3000
        // supplyPrice = 3000 * 1e12 (Fluid 精度)
        // borrowPrice = 1 * 1e12
        vault.setExchangePrices(3000 * 1e12, 1e12);

        // 给Vault充值USDC
        debtToken.mint(address(vault), 100000 * 1e18); // 充值 100,000 USDC

        // 部署 Aggregator
        aggregator = new Aggregator(address(flashExecutor));

        // 部署 Fluid Adapter
        adapter = new FluidAdapter(address(vault), address(aggregator));

        // 在 Aggregator 中注册 Adapter
        aggregator.setAdapter(address(adapter), true);

        // 给测试用户发钱
        collateralToken.mint(user, 1000 * 1e18); // 用户有 1000 WETH
    }

    function testDepositIntegration() public {
        uint256 amount = 10 ether;

        vm.startPrank(user);
        collateralToken.approve(address(aggregator), amount);

        // 用户调用 Aggregator 存款
        bytes32 posId = aggregator.deposit(
            bytes32(0), // 新仓位
            address(collateralToken),
            amount,
            address(adapter),
            ""
        );
        vm.stopPrank();

        // 验证Aggregator 记录了仓位
        Aggregator.Position memory pos = aggregator.getPosition(posId);
        assertEq(pos.owner, user, "Position owner should be user");
        assertEq(pos.collateralAmount, amount, "Collateral amount should match deposited amount");

        // 验证Adapter 内部记录了用户的 NFT ID
        uint256 nftId = adapter.userNftIds(user);
        assertTrue(nftId != 0, "User should have an associated NFT ID");

        // 验证Vault收到钱
        (uint256 col, uint256 debt) = vault.fetchPositionData(nftId);
        assertEq(col, amount, "Vault should record correct collateral amount");
        assertEq(debt, 0, "Vault debt should be zero after deposit");
    }

    function testBorrowIntegration() public {
        uint256 supplyAmount = 10 ether;
        uint256 borrowAmount = 500 * 1e18; // 借 500 USDC

        vm.startPrank(user);

        // 先存款
        collateralToken.approve(address(aggregator), supplyAmount);
        bytes32 posId = aggregator.deposit(
            bytes32(0),
            address(collateralToken),
            supplyAmount,
            address(adapter),
            ""
        );

        uint256 healFactor = adapter.getHealthFactor(user);
        console.log("Health Factor after deposit:", healFactor);

        // 然后借款
        aggregator.borrow(
            posId,
            address(debtToken),
            borrowAmount,
            ""
        );
        vm.stopPrank();

        // 验证用户收到借款
        uint256 userDebtBalance = debtToken.balanceOf(user);
        assertEq(userDebtBalance, borrowAmount, "User should receive borrowed amount");

        // 验证Aggregator 记录的债务
        Aggregator.Position memory pos = aggregator.getPosition(posId);
        assertEq(pos.debtAmount, borrowAmount, "Debt amount should match borrowed amount");

        // 验证Vault 记录的债务
        uint256 nftId = adapter.userNftIds(user);
        (, uint256 debt) = vault.fetchPositionData(nftId);
        assertEq(debt, borrowAmount, "Vault should record correct debt amount");
    }

    function testHealthFactorIntegration() public {
        testBorrowIntegration(); // 先造一个有债的仓位
        // Col=10 ETH, Debt=500 USDC. Price=1. HF 很高
        uint256 initialHF = adapter.getHealthFactor(user);
        console.log("Initial Health Factor:", initialHF);

        // 模拟市场暴跌：ETH 价格跌了一半 (Supply Price 变成 0.5)
        vault.setExchangePrices(1500 * 1e12, 1e12);

        uint256 newHF = adapter.getHealthFactor(user);
        console.log("New Health Factor after price drop:", newHF);

        assertTrue(newHF < initialHF, "Health factor should decrease after price drop");
    }
}