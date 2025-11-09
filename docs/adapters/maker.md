# Maker Adapter 接入指南

> 本文描述如何基于 MakerDAO 主网（DSS 系统）实现 Aggregator 的 Maker Adapter，包括仓位管理、稳定费计算与测试要点。

---

## 1. 协议概览

- **核心组件**：`Vat`、`GemJoin`、`DaiJoin`、`Jug`、`Spot`
- **仓位单位**：`ilk` 表示抵押类型（如 `ETH-A`），`urn` 表示仓位地址
- **数值精度**：`WAD`=1e18、`RAY`=1e27、`RAD`=1e45
- **权限模型**：`Vat` 需 `hope` 授权才能代表仓位执行操作

---

## 2. Adapter 架构

```solidity
interface IMakerAdapter is IBorrowingAdapter {
    struct IlkConfig {
        bytes32 ilk;
        address gemJoin;
        address daiJoin;
        address jug;
        address vow;
        uint256 debtCeiling;
    }

    function config() external view returns (IlkConfig memory);
}
```

- 建议 Adapter 内部绑定单一 `ilk`，并在构造函数中传入对应 `GemJoin`、`DaiJoin` 等地址。
- 若需要支持多个 `ilk`，可改为工厂模式，每个 `ilk` 部署一个 Adapter。

### 2.1 `adapterParams` / `adapterData` 约定

Maker 相关操作需要携带额外参数以处理 `drip`、`frob` 精度等细节。建议统一使用以下结构体：

```solidity
struct MakerDepositParams {
  bool callDrip;        // 是否在存款前调用 Jug.drip 以更新稳定费
  uint256 minInkWad;    // 存款后仓位最小 ink，单位 WAD，0 表示跳过检查
}

struct MakerWithdrawParams {
  uint256 maxDebtAfter; // 赎回后允许的最大债务，单位 RAD，0 表示必须清零
  bool exitAll;         // true 表示一次性释放全部抵押
}

struct MakerBorrowParams {
  bool callDrip;            // 借款前是否强制更新稳定费
  uint256 maxRateDeviation; // rate 允许的最大偏差，Ray 精度
}

struct MakerRepayParams {
  bool repayAll;            // true 使用 MAX_UINT 偿还全部 DAI
  uint256 targetDebtRad;    // 目标剩余债务，RAD 精度，用于校验
}
```

对应关系：

| Aggregator 字段 | 结构体 | 说明 |
|-----------------|--------|------|
| `DepositExtra.adapterParams` | `MakerDepositParams` | 普通存款或迁移时的抵押增加 |
| `MigrationParams.collateralOut[i].adapterData` | `MakerWithdrawParams` | 迁移或赎回时使用 |
| `DebtLeg.adapterData`（借） | `MakerBorrowParams` | 控制 `drip` 与利率偏差 |
| `DebtLeg.adapterData`（还） | `MakerRepayParams` | 标记是否全额偿还 |

示例代码：

```solidity
// 后端打包
bytes memory params = abi.encode(MakerBorrowParams({
  callDrip: true,
  maxRateDeviation: 5e24 // 0.5% Ray 精度
}));

// Adapter 解码
MakerBorrowParams memory borrowParams = abi.decode(adapterData, (MakerBorrowParams));
```

在迁移流程中，`collateralOut` 与 `collateralIn` 的 `adapterData` 应分别传入 `MakerWithdrawParams` 与 `MakerDepositParams`，以确保闪电贷路径中的 Maker 操作具备一致的风控阈值。

---

## 3. 关键函数实现

### 3.1 `deposit`

1. 将用户资产（例如 WETH）从 Aggregator 转入 Adapter，并 `approve` 给 `GemJoin`。
2. 调用 `GemJoin.join(urn, amount)` 将资产存入 Maker。
3. 调用 `Vat.frob(ilk, urn, urn, urn, int(dink), 0)` 增加抵押量。`dink` 需要根据资产精度转换为 `WAD`。
4. 根据需要调用 `Jug.drip(ilk)` 以更新稳定费。

### 3.2 `withdraw`

1. 若存在债务，需要先偿还对应 DAI 并执行 `frob` 释放抵押：`Vat.frob(ilk, urn, urn, urn, -int(dink), 0)`。
2. 调用 `GemJoin.exit(recipient, amount)` 将资产取出。
3. 若资产为 ETH，需要在 Adapter 末尾 unwrap 并转给用户。

### 3.3 `borrow`

1. 调用 `Jug.drip(ilk)` 确保稳定费最新。
2. 计算可用债务：`daiOut = dart * rate`，其中 `rate` 来自 `Vat.ilks(ilk).rate`。
3. 调用 `Vat.frob(ilk, urn, urn, urn, 0, int(dart))` 增加债务，再通过 `DaiJoin.exit(onBehalfOf, daiOut)` 提现 DAI。

### 3.4 `repay`

1. 用户需先授权 Aggregator 使用 DAI。
2. Adapter 将 DAI `join` 回 Maker：`DaiJoin.join(urn, amount)`。
3. 调用 `Vat.frob(ilk, urn, urn, urn, 0, -int(dart))` 减少债务，确保 `dart` 与 Maker 内部 `art` 一致。

### 3.5 `getHealthFactor`

- Maker 不直接提供健康度，可根据 `ink`、`art`、`rate`、`spot` 计算：
  ```solidity
  (uint Art, uint rate,,,) = vat.ilks(ilk);
  (uint ink, uint art) = vat.urns(ilk, urn);
  uint collateralValue = ink * spot; // RAD
  uint debtValue = art * rate;       // RAD
  hf = collateralValue / (debtValue * liquidationRatio)
  ```
- `spot` 来自 `Vat.ilks(ilk).spot`，需结合 `Spotter.ilks(ilk).mat`（抵押比率）。

---

## 4. 部署配置

| 组件 | 主网地址 | 说明 |
|------|----------|------|
| Vat | `0x35D1b3F3D7966A1DFe207aa4514C12a259A0492B` | Maker 核心账本 |
| GemJoin (ETH-A) | `0x2F0b23f53734252Bda2277357e97e1517d6B042A` | WETH 抵押入口 |
| DaiJoin | `0x9759A6Ac90977b93B58547b4A71c78317f391A28` | DAI 入口 |
| Jug | `0x19c0976f590D67707E62397C87829d896Dc0f1F1` | 稳定费模块 |
| Spotter | `0x65C79FCB50Ca1594b025960e539eD7A9a2eC2b7f` | 价格模块 |
| DSProxyFactory | `0xA26e15C895EFc0616177B7c1e7270A4C7D51C997` | 推荐使用 DSProxy 作为 `urn` |

部署步骤：
1. 通过工厂创建 `DSProxy`，并对 `Vat` 调用 `hope(adapter)` 授权。
2. 部署 Adapter，设置 `urn`（可为 Aggregator 控制的 Proxy）。
3. 调用 `Aggregator.setAdapter(adapter, true)`。

---

## 5. 测试策略

1. 使用 Foundry 主网 fork，预先向 `DSProxy` 注入 WETH/DAI。
2. 编写场景：
   - 存入抵押、增加债务、偿还债务、赎回抵押。
   - `Jug.drip` 前后比较稳定费。
   - 校验 `healthFactor` 计算结果与 Maker 前端数据一致。
3. 对异常流程（如超过债务上限、抵押不足）进行 revert 测试。

---

## 6. 常见问题

- **单位转换**：确保 `dink`、`dart` 在转换为 `int256` 时不会溢出，且与 `GemJoin.dec()` 一致。
- **授权管理**：`Vat.hope` 对应地址即拥有全部权限，务必限定为 Adapter 或治理合约。
- **稳定费更新**：若长期未调用 `Jug.drip`，`rate` 将滞后导致债务计算错误，建议在借款/还款前强制调用。

---

## 7. 扩展计划

- 集成 `Clipper` 或 `Dog` 合约以监控清算风险。
- 支持 DSProxy 批量调用，减少多步交易的 Gas 开销。
- 在 Adapter 中加入抵押品多样化配置，实现跨 `ilk` 调度。

## 8. 治理与运维清单

- **授权检查**：部署后通过多签执行 `Vat.hope(adapter)`、`DaiJoin.rely(adapter)` 等必要授权，并记录在治理日志中。
- **Adapter 白名单**：使用 `Aggregator.setAdapter(adapter, true)` 激活 Maker Adapter，如需停用则设置为 `false` 并同步链下配置。
- **参数同步**：当稳定费或抵押品参数调整时，更新链下脚本生成的 `Maker*Params` 默认值，避免旧任务违反最新阈值。
- **监控指标**：关注 `Vat.ilks` 中的 `line/dust` 以及 `Jug.base`，一旦超出策略范围，可通过应急提案暂停 Adapter。
