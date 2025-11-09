# Compound Adapter 接入指南

> 目标：帮助合约工程师与后端工程师快速完成 Compound V2 的 Adapter 实现、配置与测试。

---

## 1. 协议概览

- **协议版本**：Compound V2（主网及常见测试网）
- **核心组件**：`Comptroller`、`cToken`（`cDAI`、`cUSDC`、`cETH` 等）、`CompoundLens`
- **资产精度**：与 ERC-20 原生精度一致，利率均以 `1e18` 精度返回
- **权限模型**：每个用户地址需先 `enterMarkets` 才能抵押借款

---

## 2. Adapter 架构

```solidity
interface ICompoundAdapter is IBorrowingAdapter {
    struct MarketConfig {
        address cToken;
        address underlying;
        uint8 decimals;
    }

    function markets(address underlying) external view returns (MarketConfig memory);
}
```

建议在 Adapter 内维护 `underlying` → `MarketConfig` 映射，便于多资产复用同一合约。`IBorrowingAdapter` 继承关系确保 `deposit/withdraw/borrow/repay` 全部具备统一签名。

### 2.1 `adapterParams` / `adapterData` 约定

Aggregator 会将扩展参数透传给 Adapter：

- `IAggregator.DepositExtra.adapterParams` → `deposit`
- `IAggregator.MigrationParams.collateralIn[i].adapterData` → 迁移时的存款
- `IAggregator.MigrationParams.collateralOut[i].adapterData` → 迁移时的赎回
- `DebtLeg.adapterData` → 借款/还款

为避免多端解码不一致，推荐统一使用以下结构体：

```solidity
struct CompoundDepositParams {
  bool ensureEnterMarket;      // 初次存款时调用 enterMarkets
  uint256 minExchangeRateRay;  // 期望的最小兑换率，Ray 精度（1e27），0 表示跳过校验
}

struct CompoundWithdrawParams {
  bool redeemUnderlying;       // true 走 redeemUnderlying，false 走 redeem
  uint256 minAmount;           // 允许的最小取回数量，单位为底层资产精度
}

struct CompoundBorrowParams {
  bool useVariableRate;        // true = Variable，false = Stable（如资产不支持稳定利率将忽略）
  uint256 maxFeeBps;           // 最大可接受费用/滑点，basis points，0 表示跳过
}

struct CompoundRepayParams {
  bool repayAll;               // true 表示使用 MAX_UINT 全额清算
  uint256 expectedDebt;        // 预期剩余债务，单位为底层资产精度，用于防止利率突变
}
```

编码/解码示例：

```solidity
// Aggregator / backend 侧
bytes memory adapterParams = abi.encode(CompoundDepositParams({
  ensureEnterMarket: true,
  minExchangeRateRay: 0
}));

// Adapter 侧
CompoundDepositParams memory params = abi.decode(adapterData, (CompoundDepositParams));
```

迁移场景中请分别在 `collateralOut[i].adapterData` 与 `collateralIn[i].adapterData` 传入 `CompoundWithdrawParams`、`CompoundDepositParams`，以便在闪电贷执行器中复用相同的校验逻辑。

---

## 3. 关键函数实现要点

### 3.1 `deposit`

1. 检查 `isMarketSupported(underlying)`，否则 revert。
2. 调用 `IERC20(underlying).safeApprove(cToken, amount)`；推荐使用 `SafeERC20`。
3. 调用 `CErc20(cToken).mint(amount)` 并检查返回错误码。
4. 更新 Aggregator 内部仓位时使用 `exchangeRateCurrent()` 获得最新余额。

> **注意**：`cETH` 使用 `CEther`，函数签名为 `mint()` 且需携带 `msg.value`，适配时可将 WETH 先 unwrap，再调用。

### 3.2 `withdraw`

1. 若 Aggregator 使用基础资产计量仓位，选择 `cToken.redeemUnderlying(amount)`，否则使用 `redeem`。
2. 检查错误码，必要时转换为自定义 revert（例如 `error CompoundRedeem(uint err)`）。
3. 将赎回的资产 `safeTransfer(recipient, amount)`。

### 3.3 `borrow`

1. 初次借款前调用 `Comptroller.enterMarkets()` 以注册抵押品。
2. 通过 `CErc20(cToken).borrow(amount)`；失败时 revert。
3. 若 Adapter 需要记录债务指数，可调用 `cToken.borrowBalanceCurrent(onBehalfOf)`。

### 3.4 `repay`

1. 调用 `IERC20(asset).safeApprove(cToken, amount)`。
2. 根据是否全额偿还选择 `CErc20(cToken).repayBorrow(amount)` 或 `repayBorrowBehalf`。
3. 若 `amount == type(uint256).max`，表示偿还全部债务。

### 3.5 利率与健康度

- **供应利率**：`cToken.supplyRatePerBlock()`，建议折算为 Ray（`rate * blocksPerYear * 1e9`）。
- **借款利率**：`cToken.borrowRatePerBlock()`。
- **健康度计算**：
  ```solidity
  (uint collateralFactorMantissa,,) = comptroller.markets(cToken);
  (, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(account);
  ```
  根据 `liquidity` 与 `shortfall` 推导健康度。也可通过 `CompoundLens.getAccountLimits` 获取。

---

## 4. 配置与部署

| 名称 | 主网地址 | Goerli 地址 | 说明 |
|------|----------|-------------|------|
| Comptroller | `0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B` | `0x54188aD3a7f970f476164F6AaCDa5f832c6FfC23` | 风控与市场管理 |
| cDAI | `0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643` | `0x95b4Ef2869eBD94BEb3D8C06bCC86F2475d727A0` | DAI 市场 |
| cUSDC | `0x39AA39c021dfbaE8faC545936693aC917d5E7563` | `0x4a92E71227D294F041BD82dd8f78591B75140d63` | USDC 市场 |
| cETH | `0x4DdC2D193948926d02f9B1fE9e1daa0718270ED5` | `0x41B5844f4680a8C38fBb695b7F9CFd1F64474a72` | ETH 市场 |
| CompoundLens | `0xd513d22422a3062Bd342Ae374b4ba1b7518B7f6c` | `0x6976AFC3785390c7F15787DE1fd96adf6CD240cC` | 读接口 |

- 部署 Adapter 时传入 `Comptroller` 地址以及支持的市场列表。
- 初始化后调用 `Aggregator.setAdapter(adapter, true)` 并在治理多签内登记。

---

## 5. 测试策略（Foundry）

1. **Fork 主网**：
   ```bash
   forge test --fork-url $MAINNET_RPC -vv
   ```
2. **场景覆盖**：
   - 存款/赎回不同 asset 与 decimals。
   - 借款/还款，包含 `MAX_UINT` 全额偿还。
   - 利率读取与健康度计算。
   - `enterMarkets` 前后借款限制。
3. **模拟利率变化**：调用 `vm.roll(block.number + N)` 或 `vm.warp` 触发利率累计。

---

## 6. 常见问题

- **错误码解析**：Compound 返回 `uint` 错误码，需参考官方文档映射；建议写 `require(err == 0, "COMPOUND_ERROR")`。
- **授权重入**：避免在每次 `deposit`/`repay` 中重复 `approve`，可使用无限授权并在部署后一次性设置。
- **Gas 优化**：合约内部缓存 `Comptroller` 与 `MarketConfig`，避免重复查询。

---

## 7. 后续扩展

- 支持 COMP 激励获取（`Comptroller.claimComp`）。
- 扩展 `marketConfig` 以包含激励资产与 APR 计算逻辑。
- 加入清算辅助工具，协助在健康度低时自动迁移或赎回。

## 8. 治理与运维清单

- **Adapter 注册**：部署完成后提交多签提案，调用 `Aggregator.setAdapter(adapter, true)`，并在链下配置文件中登记 `underlying → cToken` 映射。
- **权限校验**：确保 Adapter 拥有 `cToken` 无限授权，且 `Comptroller.enterMarkets` 已对 Aggregator/Adapter 地址执行。
- **参数版本化**：当 `Compound*Params` 结构变更时同时更新链下脚本、前端与文档，避免旧任务解码失败。
- **监控**：订阅 `Comptroller.MarketEntered/Exited` 及 `cToken` 事件，出现异常时可通过多签调用 `setAdapter(adapter, false)` 暂停使用。
