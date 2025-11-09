# Aave Adapter 接入指南

> 适用于 Aave V3 主网（Ethereum、Polygon、Optimism 等）。重点关注存取款、借还款、闪电贷和风险参数同步。

---

## 1. 协议概览

- **核心组件**：`Pool`（主入口）、`PoolAddressesProvider`、`Oracle`、`RewardsController`
- **资产单位**：存款凭证为 aToken（18 位精度），债务凭证为 `StableDebtToken` / `VariableDebtToken`
- **权限模型**：`Pool` 提供授权控制，Adapter 需在部署时设定操作角色

---

## 2. Adapter 接口设计

```solidity
interface IAaveAdapter is IBorrowingAdapter {
    struct ReserveConfig {
        address aToken;
        address stableDebtToken;
        address variableDebtToken;
        uint16 reserveFactor;
        uint256 ltv;
        uint256 liquidationThreshold;
    }

    function pool() external view returns (IPool);
    function reserve(address asset) external view returns (ReserveConfig memory);
}
```

- 在构造函数中注入 `PoolAddressesProvider`，通过其获取当前 `Pool` 地址，便于协议升级。
- `reserve` 映射存储资产对应的 aToken/债务 Token 地址及风控参数。

---

## 3. 核心函数实现

### 3.1 `deposit`

1. 使用 `IPool.supply(asset, amount, address(this), 0)` 存入资产。
2. 通过 `IERC20(asset).safeApprove(address(pool), amount)` 完成授权。
3. 存款后 aToken 会自动铸造到 Adapter 地址；Aggregator 可按 aToken 余额记录仓位。

### 3.2 `withdraw`

1. 调用 `IPool.withdraw(asset, amount, recipient)`，返回实际取出数量。
2. 若请求 `amount == type(uint256).max`，表示全部赎回。

### 3.3 `borrow`

1. 选择借款模式：稳定利率或浮动利率，参数 `uint256 interestRateMode` 分别为 `1` 与 `2`。
2. 调用 `IPool.borrow(asset, amount, interestRateMode, referralCode, onBehalfOf)`。
3. Aave 会将债务记在 `onBehalfOf` 地址，Adapter 可读取 `StableDebtToken.balanceOf` 或 `VariableDebtToken.balanceOf`。

### 3.4 `repay`

1. 调用 `IPool.repay(asset, amount, interestRateMode, onBehalfOf)`。
2. 若 `amount == type(uint256).max`，表示全部偿还。

### 3.5 `getHealthFactor`

- 使用 `IPool.getUserAccountData(user)` 返回：
  ```solidity
  (uint256 totalCollateralBase,
   uint256 totalDebtBase,
   uint256 availableBorrowBase,
   uint256 currentLiquidationThreshold,
   uint256 ltv,
   uint256 healthFactor) = pool.getUserAccountData(user);
  ```
- `healthFactor` 精度为 `1e18`，直接返回即可。

---

## 4. 闪电贷支持

- Aave V3 `IPool.flashLoanSimple(receiver, asset, amount, params, referralCode)` 可用于单资产闪电贷。
- Adapter 通常不直接提供闪电贷功能，而是由 `FlashLoanExecutor` 集成。
- 若需多资产闪电贷，使用 `flashLoan(receivers[], assets[], amounts[], interestRateModes[], onBehalfOf, params, referralCode)`。
- 在回调中确保 `Pool` 的 `approve`/`repay` 调用正确，并校验 `premium`。

---

## 5. 部署配置

| 网络 | PoolAddressesProvider | Oracle |
|------|----------------------|--------|
| Ethereum Mainnet | `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` | `0x54586bE62E3c3580375aE3723C145253060Ca0C2` |
| Polygon | `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` | `0x8a753747A1Fa494EC906cE90E9f37563A8AF630e` |
| Optimism | `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` | `0xbC267C0813d219c5cbC89f237f5BC43A9a55Ab43` |

- Adapter 需在部署时调用 `pool.getReserveData(asset)` 初始化 `reserve` 映射。
- 治理多签完成 Adapter 注册后，确保 `Aggregator` 开启对应的 LTV 限制与风险参数。

---

## 6. 测试策略

1. 使用 Foundry fork 网络，预置用户资产与 aToken。
2. 测试场景：
   - 存取款（含全部赎回）。
   - 借还款，覆盖稳定/浮动利率模式。
   - 健康度读取与 LTV 限制校验。
   - 闪电贷回调流程（如与迁移执行器联调）。
3. 断言 Aave `Pool` 事件（`Supply`, `Withdraw`, `Borrow`, `Repay`）。

---

## 7. 常见问题

- **授权**：确保 Adapter 持续对 `Pool` 保持额度，或使用无限授权。
- **利率模式**：Aave 可能限制部分资产仅支持浮动利率，需通过 `ReserveConfig` 提前检查。
- **隔离模式**：若资产处于隔离模式或 E-mode，需额外处理 `eModeCategoryId`。
- **奖励分发**：可通过 `RewardsController` 领取激励代币，将来可拓展收益策略。

---

## 8. 扩展方向

- 集成 `eMode` 和隔离资产逻辑，自动切换 LTV 限制。
- 在 Adapter 中暴露 `claimRewards`，统一处理激励资产。
- 支持跨链部署（通过 CCIP/LayerZero）时的 Adapter 同步与治理配置。
