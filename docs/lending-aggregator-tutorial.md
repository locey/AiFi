# 从 0 到 1 搭建可扩展的 DeFi Lending Aggregator

> 目标：优先完成 Compound 与 MakerDAO 接入，后续拓展 Aave / Spark / Morpho。聚合器需支持仓位存取、借贷、跨协议迁移与闪电贷路由，链下服务负责策略调度与风控。
>
> 推荐配套文档：`docs/contract-interface-reference.md`（接口详细说明）、`docs/project-structure.md`（目录结构建议）。

---

## 0. 教程导航

- **适用读者**：准备从零搭建聚合器的链上/后端工程师，或需要对齐团队协作流程的 Tech Lead。
- **阅读建议**：先通读第 0~2 章形成全局认识，再根据当前阶段跳转到对应里程碑。若只关注接口，可直接查阅 `docs/contract-interface-reference.md`。
- **章节速查**：
  - 第 0 章——先决条件、核心资源索引。
  - 第 1 章——环境准备与仓库结构。
  - 第 2 章——合约/后端接口速览与参考实现。
  - 第 3 章及以后——按里程碑拆分的落地步骤、代码片段与测试指引。
- **附录导航**：
  - `附录：闪电贷路由设计纲要`——闪电贷调用流程与容错策略。
  - `附录：Aggregator / Adapter 伪代码`——完整伪代码模板，可直接对照实现。

## 1. 开发前准备

### 1.1 环境依赖
- Foundry (`forge`/`cast`) ≥ 1.0：编译、测试、部署 Solidity 合约。
- Node.js 18+ 与 pnpm（或 yarn）：构建前端脚手架与链下脚本。
- Go 1.21+：后台服务与 `abigen` 绑定生成。
- Docker / docker-compose（可选）：在本地启动 Redis、PostgreSQL、RabbitMQ。
- 多签或 EOA 账户：部署合约与后续治理操作均需签名账户支持。

### 1.2 仓库布局约定

```bash
cd <project-root>/AiFi
```

- `contracts/`：Foundry 项目根目录，包含 `src/`、`test/`、`script/`。
- `backend/`（建议创建）：Go 服务与 Worker 代码。
- `deploy/`：部署与迁移脚本，可区分 `mainnet`、`testnet` 子目录。
- `docs/`：设计与操作文档（当前文件即位于此处）。
- 更详细的目录说明见 `docs/project-structure.md`。

### 1.3 关键接口速览

 - 聚合器接口：参考 `docs/contract-interface-reference.md` 第 2 章，包含 `Position` 结构、`deposit/withdraw/borrow/repay/migrate` 签名以及 `MigrationParams` 组合示例。
 - Adapter 规范：`IAdapter`/`IBorrowingAdapter` 需实现 `deposit`/`withdraw` 及借贷扩展，与文档中的 `adapterData` 约定保持一致。
 - 闪电贷执行器：`FlashLoanExecutor.executeMigration(IAggregator.MigrationParams calldata params)` 为唯一入口，所有闪电贷自定义参数置于 `params.flash.payload`。
 - 治理函数：`Aggregator.setAdapter(address adapter, bool allowed)`、`setFlashExecutor(address newExecutor)`（及可选的 `pause/unpause`）须由多签或 `ADMIN_ROLE` 调用，部署后优先完成。
 - 附录提供完整伪代码，可在实现前对照校验字段、事件与权限处理。

### 1.4 落地顺序建议
- 阅读第 3 章的“里程碑 1/2”，完成仓库初始化与 Foundry 合约骨架。
- 按需跳转到里程碑 4~7，补齐 Go 后端、Redis/RabbitMQ、PostgreSQL 等组件。
- 参考里程碑 8~10 完成测试、CI/CD、安全审计与扩展性规划。
- 若仅需了解链下执行流程，可先阅读 `附录：闪电贷路由设计纲要`。

---

## 2. 合约与服务概览

> 本章用于建立整体概念，对细节函数/参数的定义，请回看 `docs/contract-interface-reference.md`。

### 2.1 核心组件
- **Aggregator 合约**：统一维护仓位与 Adapter 白名单，负责存取、借贷、迁移操作，并通过事件对外同步状态。
- **Adapter 合约**：封装具体协议（Compound、Maker、Aave 等）的交互逻辑，确保上层调用签名统一。
- **FlashLoanExecutor 合约**：在闪电贷回调中协调 `Aggregator.migrate`，结束后偿还借款。
- **Go Worker**：监听链下任务，选择闪电贷路线，构造 `MigrationParams` 并触发链上操作。
- **风控与数据面**：Redis 存储实时利率、RabbitMQ 承担任务分发，PostgreSQL 保存仓位与历史记录。

### 2.2 典型调用顺序
1. 用户在前端发起 `deposit`，后端仅负责参数校验与交易构造。
2. Worker 周期性拉取底层协议利率，若触达策略阈值则写入 RabbitMQ 迁移任务。
3. 任务消费者调用闪电贷提供方，回调中执行 `FlashLoanExecutor.executeMigration(params)`。
4. 迁移完成后，Worker 重新抓取 `Aggregator.getPosition` 校验仓位并更新数据库。
5. 若治理需要新增/禁用 Adapter 或更换闪电贷执行器，多签提案调用 `setAdapter` / `setFlashExecutor`，并同步链下配置以免任务执行失败。

### 2.3 伪代码参考
- 完整伪代码示例详见文档末尾的附录，可作为实现骨架。
- 若需快速对照数据结构，可先阅读附录再回到本章的里程碑部分。

---

## 3. 里程碑详解

### 里程碑 1：初始化仓库 + 本地基础设施

1. **目录布局**
   ```bash
   mkdir -p contracts testnet infra docker scripts
   ```

2. **环境变量模板 `.env.example`**
   ```dotenv
   POSTGRES_USER=defi
   POSTGRES_PASSWORD=defi
   POSTGRES_DB=aifi
   POSTGRES_HOST=postgres
   POSTGRES_PORT=5432

   REDIS_ADDR=redis:6379
   REDIS_PASSWORD=

   RABBITMQ_USER=guest
   RABBITMQ_PASSWORD=guest
   RABBITMQ_HOST=rabbitmq
   RABBITMQ_PORT=5672

   ANVIL_RPC=http://anvil:8545
   PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
   ```

3. **`docker-compose.yaml`**（位于仓库根目录）
   ```yaml
   version: "3.9"

   services:
     postgres:
       image: postgres:15-alpine
       restart: unless-stopped
       environment:
         POSTGRES_USER: ${POSTGRES_USER}
         POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
         POSTGRES_DB: ${POSTGRES_DB}
       ports:
         - "5432:5432"
       volumes:
         - pgdata:/var/lib/postgresql/data

     redis:
       image: redis:7-alpine
       restart: unless-stopped
       ports:
         - "6379:6379"

     rabbitmq:
       image: rabbitmq:3-management
       restart: unless-stopped
       ports:
         - "5672:5672"
         - "15672:15672"

     anvil:
       image: ghcr.io/foundry-rs/foundry:latest
       command: anvil --host 0.0.0.0 --chain-id 31337 --block-time 2
       ports:
         - "8545:8545"

   volumes:
     pgdata:
   ```

4. **启动服务**
   ```bash
   cp .env.example .env
docker compose up -d
   ```

5. **验证**
   ```bash
docker compose ps
curl http://localhost:8545
psql postgres://defi:defi@localhost:5432/aifi -c "SELECT 1"
redis-cli -h localhost ping
   ```

---

### 里程碑 2：Foundry 项目与合约骨架

1. **初始化 Foundry**
   ```bash
   forge init contracts --no-commit
   cd contracts
   forge config --json
   cd ..
   ```

2. **`foundry.toml`（根目录）**
   ```toml
   [profile.default]
   src = "contracts/src"
   test = "contracts/test"
   out = "contracts/out"
   libs = ["contracts/lib"]
   solc_version = "0.8.24"
   optimizer = true
   optimizer_runs = 200

   [rpc_endpoints]
   localhost = "http://127.0.0.1:8545"
   ```

3. **核心接口**（`contracts/src/IAggregator.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   interface IAggregator {
       struct Position {
           bytes32 id;
           address owner;
           address collateralAsset;
           address adapter;
           uint256 collateralAmount;
           address debtAsset;
           uint256 debtAmount;
           uint256 lastHealthFactor;
       }

       struct DebtLeg {
           address asset;
           uint256 amount;
           bytes adapterData;
       }

       struct CollateralLeg {
           address asset;
           uint256 amount;
           bytes adapterData;
       }

       struct FlashRoute {
           bytes32 provider;
           uint256 feeBps;
           uint256 maxSlippageBps;
           bytes payload;
       }

       struct MigrationParams {
           bytes32 positionId;
           address user;
           address fromAdapter;
           address toAdapter;
           CollateralLeg[] collateralOut;
           CollateralLeg[] collateralIn;
           DebtLeg[] repayLegs;
           DebtLeg[] borrowLegs;
           FlashRoute flash;
           bytes extra;
       }

       event Deposited(bytes32 indexed positionId, address indexed user, address indexed adapter, uint256 amount, bytes extra);
       event Withdrawn(bytes32 indexed positionId, address indexed user, address indexed adapter, uint256 amount, bytes extra);
       event Borrowed(bytes32 indexed positionId, address indexed user, address indexed adapter, address asset, uint256 amount, bytes data);
       event Repaid(bytes32 indexed positionId, address indexed user, address indexed adapter, address asset, uint256 amount, bytes data);
       event Migrated(bytes32 indexed positionId, address indexed user, address fromAdapter, address toAdapter, bytes data);

       function deposit(bytes32 positionId, address collateralAsset, uint256 amount, address adapter, bytes calldata extra) external returns (bytes32);
       function withdraw(bytes32 positionId, uint256 amount, bytes calldata extra) external;
       function borrow(bytes32 positionId, address debtAsset, uint256 amount, bytes calldata data) external;
       function repay(bytes32 positionId, address debtAsset, uint256 amount, bytes calldata data) external;
       function migrate(MigrationParams calldata params) external;
       function getPosition(bytes32 positionId) external view returns (Position memory);
       function derivePositionId(address owner, address collateralAsset, address adapter, bytes32 salt) external pure returns (bytes32);
   }
   ```

4. **Adapter 接口**（`contracts/src/adapters/IAdapter.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   interface IAdapter {
       function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external;
       function withdraw(address asset, uint256 amount, address recipient, bytes calldata data) external;
       function getSupplyRate(address asset) external view returns (uint256);
       function getProtocolName() external view returns (bytes32);
   }

   interface IBorrowingAdapter is IAdapter {
       function borrow(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external;
       function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external;
       function getHealthFactor(address account) external view returns (uint256);
       function getDebt(address account, address asset) external view returns (uint256);
   }
   ```

5. **Flash Loan 执行器接口**（`contracts/src/flash/FlashLoanExecutor.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   import {IAggregator} from "../IAggregator.sol";

   interface FlashLoanExecutor {
       function executeMigration(IAggregator.MigrationParams calldata params) external;
   }
   ```

6. **Aggregator 合约骨架**（`contracts/src/Aggregator.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   import {IAggregator} from "./IAggregator.sol";
   import {IAdapter} from "./adapters/IAdapter.sol";

   contract Aggregator is IAggregator {
       mapping(bytes32 => Position) private positions;
       mapping(address => bool) public isAdapterAllowed;
       address public flashExecutor;

       constructor(address flashExecutor_) {
           flashExecutor = flashExecutor_;
       }

       function setAdapter(address adapter, bool allowed) external {
           // TODO: 结合 Ownable/AccessControl 做访问控制
           isAdapterAllowed[adapter] = allowed;
       }

       function deposit(
           bytes32 positionId,
           address collateralAsset,
           uint256 amount,
           address adapter,
           bytes calldata extra
       ) external override returns (bytes32 newPositionId) {
           // TODO: 生成/校验 positionId、校验授权、调用 Adapter.deposit 并记录事件
       }

       function withdraw(
           bytes32 positionId,
           uint256 amount,
           bytes calldata extra
       ) external override {
           // TODO: 校验健康度/债务余额，调用 Adapter.withdraw 并返还资产
       }

       function borrow(
           bytes32 positionId,
           address debtAsset,
           uint256 amount,
           bytes calldata data
       ) external override {
           // TODO: 仅允许仓位所有者调用，调用 IBorrowingAdapter.borrow，更新 debtAmount 与 healthFactor
       }

       function repay(
           bytes32 positionId,
           address debtAsset,
           uint256 amount,
           bytes calldata data
       ) external override {
           // TODO: 拉取用户资金、调用 IBorrowingAdapter.repay，更新 debtAmount 与 healthFactor
       }

       function migrate(MigrationParams calldata params) external override {
           // TODO: 仅允许 flashExecutor 调用，执行多资产迁移并偿还/重建债务
       }

       function getPosition(bytes32 positionId) external view override returns (Position memory) {
           // TODO: 返回 positions[positionId]
       }

       function derivePositionId(
           address owner,
           address collateralAsset,
           address adapter,
           bytes32 salt
       ) public pure override returns (bytes32) {
           return keccak256(abi.encode(owner, collateralAsset, adapter, salt));
       }
   }
   ```

7. **Adapter Skeleton**
   - `contracts/src/adapters/CompoundAdapter.sol`
   - `contracts/src/adapters/MakerAdapter.sol`

   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   import {IAdapter} from "./IAdapter.sol";

   contract CompoundAdapter is IAdapter {
       address public immutable cToken;

       constructor(address _cToken) {
           cToken = _cToken;
       }

       function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
           // TODO: approve + mint
       }

       function withdraw(address asset, uint256 amount, address recipient, bytes calldata data) external override {
           // TODO: redeem
       }

       function getSupplyRate(address asset) external view override returns (uint256) {
           asset; // silence warning
           // TODO: call Compound lens
           return 0;
       }

       function getProtocolName() external pure override returns (bytes32) {
           return "COMPOUND";
       }
   }
   ```

   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   import {IAdapter} from "./IAdapter.sol";

   contract MakerAdapter is IAdapter {
       bytes32 public immutable ilk;

       constructor(bytes32 _ilk) {
           ilk = _ilk;
       }

       function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
           asset; amount; onBehalfOf; data; // TODO: join + lock
       }

       function withdraw(address asset, uint256 amount, address recipient, bytes calldata data) external override {
           asset; amount; recipient; data; // TODO: free
       }

       function getSupplyRate(address asset) external view override returns (uint256) {
           asset; // TODO: read stability fee
           return 0;
       }

       function getProtocolName() external pure override returns (bytes32) {
           return "MAKER";
       }
   }
   ```

8. **Flash Loan Executor Stub**（`contracts/src/flash/MockFlashExecutor.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   import {FlashLoanExecutor} from "./FlashLoanExecutor.sol";
   import {IAggregator} from "../IAggregator.sol";

   contract MockFlashExecutor is FlashLoanExecutor {
       address public immutable aggregator;

       constructor(address _aggregator) {
           aggregator = _aggregator;
       }

       function executeMigration(IAggregator.MigrationParams calldata params) external override {
           aggregator; params;
           // TODO: integrate with aggregator.migrate
       }
   }
   ```

---

### 里程碑 3：Foundry 单元测试骨架

1. **Test Utilities**
   - `contracts/test/utils/MockERC20.sol`
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   import {ERC20} from "solmate/tokens/ERC20.sol";

   contract MockERC20 is ERC20("Mock Token", "MOCK", 18) {
       function mint(address to, uint256 amount) external {
           _mint(to, amount);
       }
   }
   ```

2. **Mock Oracle**（`contracts/test/utils/MockOracle.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   contract MockOracle {
       uint256 private rate;

       function setRate(uint256 _rate) external {
           rate = _rate;
       }

       function getRate(address) external view returns (uint256) {
           return rate;
       }
   }
   ```

3. **Basic Tests**（`contracts/test/Aggregator.t.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   import {Test} from "forge-std/Test.sol";
   import {Aggregator} from "../src/Aggregator.sol";
   import {MockERC20} from "./utils/MockERC20.sol";

   contract AggregatorTest is Test {
       Aggregator aggregator;
       MockERC20 token;

       function setUp() public {
           token = new MockERC20();
           aggregator = new Aggregator(address(0));
           token.mint(address(this), 1_000 ether);
       }

       function testDeposit() public {
           token.approve(address(aggregator), 100 ether);
           bytes32 positionId = aggregator.deposit(bytes32(0), address(token), 100 ether, address(this), bytes(""));

           IAggregator.Position memory p = aggregator.getPosition(positionId);
           assertEq(p.collateralAmount, 100 ether);
       }

       function testWithdrawRevertsWhenInsufficient() public {
           vm.expectRevert();
           aggregator.withdraw(bytes32(uint256(1)), 1 ether, bytes(""));
       }
   }
   ```

4. **运行测试**
   ```bash
   forge test
   ```

---

### 里程碑 4：Go 后端骨架

1. **目录结构**
   ```bash
   mkdir -p backend/cmd/{api,worker} backend/internal/{api,service,worker,db,config,adapter}
   cd backend
   go mod init github.com/locey/aifi
   ```

2. **共享配置结构**（`backend/internal/config/config.go`）
   ```go
   package config

   import (
       "log"
       "os"

       "github.com/joho/godotenv"
   )

   type Config struct {
       PostgresURL string
       RedisAddr   string
       RabbitURL   string
       AnvilRPC    string
       PrivateKey  string
   }

   func Load() Config {
       _ = godotenv.Load()
       cfg := Config{
           PostgresURL: os.Getenv("DATABASE_URL"),
           RedisAddr:   os.Getenv("REDIS_ADDR"),
           RabbitURL:   os.Getenv("RABBITMQ_URL"),
           AnvilRPC:    os.Getenv("ANVIL_RPC"),
           PrivateKey:  os.Getenv("PRIVATE_KEY"),
       }
       if cfg.PostgresURL == "" {
           log.Fatal("missing DATABASE_URL")
       }
       return cfg
   }
   ```

3. **数据库连接**（`backend/internal/db/postgres.go`）
   ```go
   package db

   import (
       "database/sql"

       _ "github.com/jackc/pgx/v5/stdlib"
   )

   func Connect(url string) (*sql.DB, error) {
       db, err := sql.Open("pgx", url)
       if err != nil {
           return nil, err
       }
       return db, db.Ping()
   }
   ```

4. **API Server**（`backend/cmd/api/main.go`）
   ```go
   package main

   import (
       "log"
       "net/http"

       "github.com/go-chi/chi/v5"
       "github.com/locey/aifi/internal/api"
       "github.com/locey/aifi/internal/config"
       "github.com/locey/aifi/internal/db"
   )

   func main() {
       cfg := config.Load()
       pg, err := db.Connect(cfg.PostgresURL)
       if err != nil {
           log.Fatalf("db connect: %v", err)
       }
       defer pg.Close()

       r := chi.NewRouter()
       api.RegisterRoutes(r, pg)

       log.Println("api listening on :8080")
       log.Fatal(http.ListenAndServe(":8080", r))
   }
   ```

5. **API Handler 骨架**（`backend/internal/api/routes.go`）
   ```go
   package api

   import (
       "database/sql"
       "net/http"

       "github.com/go-chi/chi/v5"
   )

   func RegisterRoutes(r chi.Router, db *sql.DB) {
       r.Post("/deposit", depositHandler(db))
       r.Post("/withdraw", withdrawHandler(db))
        r.Post("/borrow", borrowHandler(db))
        r.Post("/repay", repayHandler(db))
       r.Get("/status/{user}", statusHandler(db))
   }

   func depositHandler(db *sql.DB) http.HandlerFunc {
       return func(w http.ResponseWriter, r *http.Request) {
           _ = db
           w.WriteHeader(http.StatusCreated)
       }
   }

   func withdrawHandler(db *sql.DB) http.HandlerFunc {
       return func(w http.ResponseWriter, r *http.Request) {
           _ = db
           w.WriteHeader(http.StatusAccepted)
       }
   }

    func borrowHandler(db *sql.DB) http.HandlerFunc {
        return func(w http.ResponseWriter, r *http.Request) {
            _ = db
            w.WriteHeader(http.StatusAccepted)
        }
    }

    func repayHandler(db *sql.DB) http.HandlerFunc {
        return func(w http.ResponseWriter, r *http.Request) {
            _ = db
            w.WriteHeader(http.StatusAccepted)
        }
    }

   func statusHandler(db *sql.DB) http.HandlerFunc {
       return func(w http.ResponseWriter, r *http.Request) {
           _ = db
           w.WriteHeader(http.StatusOK)
       }
   }
   ```

6. **Service 层接口**（`backend/internal/service/rate_fetcher.go`）
   ```go
   package service

   import "context"

   type RateFetcher interface {
       Fetch(ctx context.Context) error
   }
   ```

7. **Eth 客户端**（`backend/internal/adapter/ethclient.go`）
   ```go
   package adapter

   import (
       "context"

       "github.com/ethereum/go-ethereum/ethclient"
   )

   func NewClient(ctx context.Context, rpc string) (*ethclient.Client, error) {
       return ethclient.DialContext(ctx, rpc)
   }
   ```

8. **Worker 主程序**（`backend/cmd/worker/main.go`）
   ```go
   package main

   import (
       "context"
       "log"

       "github.com/locey/aifi/internal/config"
       "github.com/locey/aifi/internal/worker"
   )

   func main() {
       cfg := config.Load()
       ctx := context.Background()

       if err := worker.Run(ctx, cfg); err != nil {
           log.Fatal(err)
       }
   }
   ```

9. **Worker Stub**（`backend/internal/worker/runner.go`）
   ```go
   package worker

   import (
       "context"

       "github.com/locey/aifi/internal/config"
   )

   func Run(ctx context.Context, cfg config.Config) error {
       _ = ctx
       _ = cfg
       return nil
   }
   ```

10. **构建与运行**
    ```bash
    cd backend
    go test ./...
    go run ./cmd/api
    ```

---

### 里程碑 5：Redis / RabbitMQ Schema 与消息流

1. **Redis Key 约定**
   - `rate:<asset>:<protocol>` → JSON `{rate: <uint256>, updated_at: <unix>}`
   - `threshold:<asset>` → 利差阈值（bps）
   - `position:<user>:<asset>` → 镜像仓位缓存

2. **RabbitMQ 交换器/队列**
   - Exchange：`migration.exchange`（类型 `topic`）
   - Routing Key：`migration.request`
   - Queue：`migration.queue`（绑定 `migration.request`）
   - Dead-letter Queue：`migration.dead`

3. **消息体 Schema**
   ```json
   {
     "id": "uuid",
    "user": "0x...",
    "collateral_asset": "0x...",
    "from_adapter": "0x...",
    "to_adapter": "0x...",
    "collateral_amount": "1000000000000000000",
     "rate_diff_bps": 120,
            "debt_asset": "0x...",
            "debt_amount": "500000000000000000",
            "debt_plan": {"mode": "rebuild", "target_hf": "1200000000000000000000000000"},
     "strategy": "flashloan",
     "created_at": "2025-05-01T12:00:00Z"
   }
   ```

4. **消息流**
   - rateFetcher 更新 Redis，发布 `rate.update`（可选 fan-out）
   - Strategy 读取 Redis，满足条件时写入 RabbitMQ
   - Worker 消费 `migration.queue`，调用 Go 服务执行链上迁移

5. **Go 中的队列接口**（`backend/internal/service/queue.go`）
   ```go
   package service

    import "encoding/json"

   type MigrationTask struct {
       ID              string          `json:"id"`
       User            string          `json:"user"`
       CollateralAsset string          `json:"collateral_asset"`
       FromAdapter     string          `json:"from_adapter"`
       ToAdapter       string          `json:"to_adapter"`
    CollateralAmount string         `json:"collateral_amount"`
       RateDiffBps     int             `json:"rate_diff_bps"`
       DebtAsset   string `json:"debt_asset,omitempty"`
       DebtAmount  string `json:"debt_amount,omitempty"`
       DebtPlan    json.RawMessage `json:"debt_plan,omitempty"`
   }

   type Queue interface {
       PublishMigration(task MigrationTask) error
       ConsumeMigration(handler func(MigrationTask) error) error
   }
   ```

---

### 里程碑 6：Postgres 表结构与 SQL

1. **迁移工具建议**：`golang-migrate` 或 `dbmate`

2. **SQL 模板**（`infra/migrations/001_init.sql`）
   ```sql
   CREATE TABLE users (
       id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       wallet_address TEXT UNIQUE NOT NULL,
       created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );

   CREATE TABLE positions (
       id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       user_id UUID NOT NULL REFERENCES users(id),
       collateral_asset_address TEXT NOT NULL,
       collateral_amount NUMERIC(78, 0) NOT NULL,
       adapter_address TEXT NOT NULL,
       debt_asset_address TEXT,
       debt_amount NUMERIC(78, 0) NOT NULL DEFAULT 0,
       last_health_factor_ray NUMERIC(78, 0) NOT NULL DEFAULT 0,
       created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       UNIQUE (user_id, collateral_asset_address)
   );

   CREATE TABLE migration_task (
       id UUID PRIMARY KEY,
       user_id UUID NOT NULL REFERENCES users(id),
       collateral_asset_address TEXT NOT NULL,
       from_adapter TEXT NOT NULL,
       to_adapter TEXT NOT NULL,
       collateral_amount NUMERIC(78, 0) NOT NULL,
       debt_asset_address TEXT,
       debt_amount NUMERIC(78, 0) NOT NULL DEFAULT 0,
       debt_plan JSONB,
       rate_diff_bps INT NOT NULL,
       status TEXT NOT NULL DEFAULT 'pending',
       created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );

   CREATE TABLE rate_history (
       id SERIAL PRIMARY KEY,
       asset_address TEXT NOT NULL,
       protocol TEXT NOT NULL,
       rate NUMERIC(38, 0) NOT NULL,
       collected_at TIMESTAMPTZ NOT NULL
   );
   ```

3. **索引建议**
   ```sql
    CREATE INDEX positions_user_collateral_idx ON positions(user_id, collateral_asset_address);
   CREATE INDEX rate_history_asset_protocol_idx ON rate_history(asset_address, protocol);
   CREATE INDEX migration_task_status_idx ON migration_task(status);
   ```

4. **连接字符串**
   ```dotenv
   DATABASE_URL=postgres://defi:defi@localhost:5432/aifi?sslmode=disable
   ```

---

### 里程碑 7：端到端集成流程

1. **启动本地基础设施**
   ```bash
   docker compose up -d
   anvil --fork-url <mainnet or rpc> --fork-block-number <block>
   ```

2. **部署合约（示例）**
   - 在 `contracts/script/Deploy.s.sol`
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   import {Script} from "forge-std/Script.sol";
   import {Aggregator} from "../src/Aggregator.sol";

   contract DeployScript is Script {
       function run() external {
           vm.startBroadcast();
           Aggregator agg = new Aggregator(address(0));
           console2.logAddress(address(agg));
           vm.stopBroadcast();
       }
   }
   ```
   - 执行 `forge script script/Deploy.s.sol:DeployScript --rpc-url http://127.0.0.1:8545 --broadcast`

3. **后端连通性测试**
   - `backend/internal/service/chain.go`
   ```go
   package service

   import (
       "context"
       "log"

       "github.com/ethereum/go-ethereum/common"
       "github.com/ethereum/go-ethereum/ethclient"
   )

   func CheckAggregator(ctx context.Context, rpc string, aggregator string) {
       client, err := ethclient.DialContext(ctx, rpc)
       if err != nil {
           log.Fatalf("dial: %v", err)
       }
       defer client.Close()

       bytecode, err := client.CodeAt(ctx, common.HexToAddress(aggregator), nil)
       if err != nil {
           log.Fatalf("code: %v", err)
       }
       if len(bytecode) == 0 {
           log.Fatal("aggregator not deployed")
       }
   }
   ```

4. **RateFetcher 周期任务**
   - 使用 `time.Ticker` 每 30 秒 fetch
   - 拉取 Compound cToken `supplyRatePerBlock`、Maker `stability fee`
   - 更新 Redis + 插入 `rate_history`

5. **策略判断**
   - 从 Redis 拉取当前协议利率
   - 比较差值大于 `threshold:<asset>`
   - 构建 `MigrationTask`：选择 `flashloan` 路径
   - 写入 Postgres（`migration_task`），发布 RabbitMQ

6. **Worker 流程（含闪电贷聚合）**
    - 消费任务 → 校验仓位 → 读取源/目标 Adapter 配置
    - 若目标协议支持闪电贷：
         - 查询候选闪电贷提供方（Balancer、Uniswap V3、Aave 等）的费用与可用流动性（可缓存于 Redis）
         - 选择成本最低、流动性充足的路线，构造携带 `flashRoute` 参数的 `migrate` 调用
         - 通过 `ethclient` 调用 Aggregator `migrate`，由 FlashLoanExecutor 完成借款与偿还
    - 若不支持闪电贷或全部路线不足：回退为多笔交易（先赎回→暂存→存入）或使用自有流动性
    - 成功后更新 Postgres `status = 'completed'`

7. **模拟最终流程**
   ```bash
   curl -X POST http://localhost:8080/deposit -d '{"user":"0xabc...","asset":"0xdef...","amount":"1000000000000000000"}'
   ```
   - 手动调用 rateFetcher 脚本更新利率
   - 检查 Redis：`redis-cli GET rate:0xdef...:COMPOUND`
   - RabbitMQ 管理界面：确认 `migration.queue` 有消息
   - Worker 日志：显示执行闪电贷迁移

---

### 里程碑 8：安全检查清单与测试用例

- **Reentrancy**：
  - Aggregator 使用 `ReentrancyGuard`
  - Adapter 调用前后更新状态
  - 测试：恶意合约在 `withdraw` 期间重入，期望 revert

- **Flashloan Failure**：
  - 在执行器中使用 try/catch（Solidity 0.8）
  - 回滚迁移任务状态，重试次数限制
  - 测试：模拟闪电贷失败，确保仓位未更新
    - 额外验证：当所有闪电贷路线不可用时，应回退至分步迁移并成功完成

- **Oracle Manipulation**：
  - 使用均值过滤（TWAP）
  - 限制单次变动阈值
  - 测试：喂价跳变超阈值，策略拒绝

- **权限控制**：
  - 仅授权 Worker 地址可触发 `migrate`
  - FlashExecutor 验证调用者

- **测试覆盖**：
  - Foundry：`testReentrancy`, `testFlashloanFail`
  - Go：模拟消息队列异常、Redis 连接中断、DB 事务回滚

---

### 里程碑 9：CI / 部署建议

1. **GitHub Actions Workflow (`.github/workflows/ci.yml`)**
   ```yaml
   name: CI

   on:
     push:
       branches: [main]
     pull_request:
       branches: [main]

   jobs:
     build:
       runs-on: ubuntu-latest

       services:
         postgres:
           image: postgres:15-alpine
           env:
             POSTGRES_USER: defi
             POSTGRES_PASSWORD: defi
             POSTGRES_DB: aifi
           ports: ["5432:5432"]
           options: >-
             --health-cmd "pg_isready -U defi"
             --health-interval 10s
             --health-timeout 5s
             --health-retries 5

         redis:
           image: redis:7-alpine
           ports: ["6379:6379"]

       steps:
         - uses: actions/checkout@v4
         - uses: foundry-rs/foundry-toolchain@v1
           with:
             version: nightly
         - name: Run Foundry tests
           run: forge test
         - name: Set up Go
           uses: actions/setup-go@v5
           with:
             go-version: "1.22"
         - name: Go tests
           run: go test ./...
         - name: Lint (可选)
           run: go vet ./...
   ```

2. **部署建议**
   - 合约：使用 Foundry 部署脚本，记录 `broadcast/` 交易
   - 后端：Docker 镜像 + Kubernetes 部署（api、worker 分离）
   - 数据库迁移：CI/CD 流程中执行 `golang-migrate` 或 `atlas`
   - 监控：Prometheus（Go metrics）、Grafana、Sentry

---

### 里程碑 10：可扩展性指南

- **添加新 Adapter（Aave/Spark/Morpho）**
  1. 新建 `contracts/src/adapters/AaveAdapter.sol`
  2. 实现 `IAdapter` 接口
  3. 更新后端 `adapter registry`（Go 中维护映射）
  4. rateFetcher 添加抓取逻辑
  5. 在 Redis 中记录新的 rate key
  6. Foundry 测试新增协议的 deposit/withdraw/migrate

- **动态加载 Adapter**
  - Aggregator 合约存储 `mapping(bytes32 => address)`
  - 管理员函数 `setAdapter(bytes32 name, address adapter)`
  - 前端 / 后端通过 GraphQL 或 REST 拉取支持列表

- **跨链扩展**
  - 引入跨链消息层（LayerZero、Hyperlane）
  - 资产托管在各链的 Aggregator 分支
  - Worker 在单链内执行迁移，跨链任务通过统一任务路由
  - 考虑使用 CCIP 或自建 bridging

- **闪电贷扩展**
    - 接入 Aave V3、Balancer Vault、Uniswap V3 Flash Swap 等多家提供方
    - 统一 `FlashLoanProvider` 接口，允许后端策略根据费用与流动性动态选择路线（Flash Loan Routing，类似 1inch Swap 聚合）
    - Aggregator 作为策略执行引擎，接受 `flashRoute` 参数以指示最佳提供方
    - 对不支持闪电贷或流动性不足场景自动回退至多笔迁移，提高兼容性

---

## 4. 建议的开发顺序

1. 先完成里程碑 1 和 2，确保合约层可编译
2. 玩转 Foundry 测试（里程碑 3），打通基本流程
3. 同步搭建 Go 后端骨架（里程碑 4）
4. 实现 Redis/RabbitMQ 通信（里程碑 5），Postgres schema（里程碑 6）
5. 完成端到端集成（里程碑 7），编写安全测试（里程碑 8）
6. 设置 CI（里程碑 9），逐步扩展 Adapter（里程碑 10）

---

## 5. 后续步骤

- 在本地实现 Compound/Maker 实际交互逻辑（调用 cToken、Maker DSProxy）
- 引入真实价格预言机（Chainlink）
- 编写策略模拟器，评估迁移收益
- 准备前端 Dashboard（React + Tailwind）展示仓位与利率

---

## 附录：闪电贷路由设计纲要

- **目标**：将 Aggregator 打造成策略执行引擎，迁移时自动选择费用最低、流动性充足的闪电贷来源，类似 1inch 对 Swap 做的聚合。
- **步骤**：
    1. Worker 根据资产与金额从 `FlashLoanRegistry` 或配置中心获取候选提供方（Balancer、Uniswap V3、Aave、Maker PSM 等）。
    2. 结合 Redis 中缓存的 `fee_bps`、可用流动性、历史成功率，对路线打分。
    3. 选择最佳路线，将 `flashRoute`（包含 provider、fee、slippage guard 等）编码传给 Aggregator `migrate`。
    4. FlashLoanExecutor 根据 `flashRoute.provider` 调用对应适配器，实现真正的借款与偿还。
    5. 若所有候选失败，则回退为多交易模式：先赎回旧协议 → 临时存放（可用 Safe 多签抵押）→ 存入新协议。
- **接口建议**：
    - `struct FlashRoute { bytes32 provider; uint256 feeBps; uint256 maxLiquidity; bytes extra; }`
    - `function migrate(..., bytes calldata flashRoute)`：Aggregator 接收路由信息。
    - `interface IFlashLoanProvider { function execute(FlashRoute calldata route, bytes calldata payload) external; }`
- **后端任务**：
    - rateFetcher/worker 定时同步闪电贷流动性，写入 Redis（如 `flash:balancer:USDC`）。
    - 迁移任务中附带 `supportsFlashLoan` 与 `fallbackPlan` 字段，方便 Worker 决策。
- **测试覆盖**：
    - 多提供方费用对比选择测试。
    - 提供方流动性不足时自动切换。
    - 完整回退路径（无闪电贷）验证。

---

## 附录：Aggregator / Adapter 伪代码

### Aggregator 合约伪代码

```solidity
pragma solidity ^0.8.24;

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

```

### Adapter 合约伪代码（示例）

```solidity
pragma solidity ^0.8.24;

abstract contract BaseAdapter {
    address public immutable aggregator;

    modifier onlyAggregator() {
        require(msg.sender == aggregator, "only aggregator");
        _;
    }

    constructor(address aggregator_) {
        aggregator = aggregator_;
    }

    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        bytes calldata data
    ) external onlyAggregator {
        _deposit(asset, amount, onBehalfOf, data);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external onlyAggregator {
        _withdraw(asset, amount, recipient, data);
    }

    function _deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) internal virtual;
    function _withdraw(address asset, uint256 amount, address recipient, bytes calldata data) internal virtual;
}
```

#### Compound Adapter 示例

```solidity
pragma solidity ^0.8.24;

interface IERC20Minimal {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface ICTokenLike {
    function mint(uint256 amount) external returns (uint256);
    function redeemUnderlying(uint256 amount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
}

interface IComptrollerLike {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function getAccountLiquidity(address account) external view returns (uint256 error, uint256 liquidity, uint256 shortfall);
}

contract CompoundAdapterPseudo is BaseAdapter, IBorrowingAdapterLike {
    address public immutable collateralAsset;
    address public immutable debtAsset;
    address public immutable supplyMarket; // cToken for collateral
    address public immutable debtMarket;   // cToken for borrow asset
    address public immutable comptroller;

    constructor(
        address aggregator_,
        address collateralAsset_,
        address debtAsset_,
        address supplyMarket_,
        address debtMarket_,
        address comptroller_
    ) BaseAdapter(aggregator_) {
        collateralAsset = collateralAsset_;
        debtAsset = debtAsset_;
        supplyMarket = supplyMarket_;
        debtMarket = debtMarket_;
        comptroller = comptroller_;

        address[] memory markets = new address[](2);
        markets[0] = supplyMarket;
        markets[1] = debtMarket;
        IComptrollerLike(comptroller).enterMarkets(markets);
    }

    function _deposit(address, uint256 amount) internal override {
        require(IERC20Minimal(collateralAsset).approve(supplyMarket, amount), "approve failed");
        require(ICTokenLike(supplyMarket).mint(amount) == 0, "mint failed");
    }

    function _withdraw(address, uint256 amount, address recipient) internal override {
        require(ICTokenLike(supplyMarket).redeemUnderlying(amount) == 0, "redeem failed");
        require(IERC20Minimal(collateralAsset).transfer(recipient, amount), "transfer failed");
    }

    // --- IBorrowingAdapterLike ---

    function borrow(address asset, uint256 amount, address onBehalfOf, bytes calldata) external override onlyAggregator {
        require(asset == debtAsset, "asset mismatch");
        require(ICTokenLike(debtMarket).borrow(amount) == 0, "borrow failed");
        require(IERC20Minimal(debtAsset).transfer(onBehalfOf, amount), "transfer failed");
    }

    function repay(address asset, uint256 amount, address, bytes calldata) external override onlyAggregator {
        require(asset == debtAsset, "asset mismatch");
        require(IERC20Minimal(debtAsset).approve(debtMarket, amount), "approve failed");
        require(ICTokenLike(debtMarket).repayBorrow(amount) == 0, "repay failed");
    }

    function getHealthFactor(address account) external view override returns (uint256) {
        (uint256 error, uint256 liquidity, uint256 shortfall) = IComptrollerLike(comptroller).getAccountLiquidity(account);
        if (error != 0 || shortfall > 0) {
            return 0;
        }
        // 健康度近似：将可用流动性放大到 Ray 精度；Compound 没有原生 HF，示例中使用 1e27 基准
        return liquidity * 1e9; // 近似映射，实际实现需结合价格预言机
    }
}
```

#### Maker Adapter 示例

```solidity
pragma solidity ^0.8.24;

interface IVatLike {
    function frob(bytes32 ilk, int256 dink, int256 dart) external;
    function urns(bytes32 ilk, address usr) external view returns (uint256 ink, uint256 art);
}

interface IGemJoinLike {
    function join(address usr, uint256 wad) external;
    function exit(address usr, uint256 wad) external;
}

interface IDaiJoinLike {
    function join(address usr, uint256 wad) external;
    function exit(address usr, uint256 wad) external;
}

contract MakerAdapterPseudo is BaseAdapter, IBorrowingAdapterLike {
    address public immutable collateralAsset; // e.g. WETH
    address public immutable dai;
    bytes32 public immutable ilk;
    address public immutable vat;
    address public immutable gemJoin;
    address public immutable daiJoin;

    constructor(
        address aggregator_,
        address collateralAsset_,
        address dai_,
        bytes32 ilk_,
        address vat_,
        address gemJoin_,
        address daiJoin_
    ) BaseAdapter(aggregator_) {
        collateralAsset = collateralAsset_;
        dai = dai_;
        ilk = ilk_;
        vat = vat_;
        gemJoin = gemJoin_;
        daiJoin = daiJoin_;
    }

    function _deposit(address, uint256 amount) internal override {
        require(IERC20Minimal(collateralAsset).approve(gemJoin, amount), "approve failed");
        IGemJoinLike(gemJoin).join(address(this), amount);
        IVatLike(vat).frob(ilk, int256(uint256(amount)), 0); // 简化：假设已按 WAD 对齐
    }

    function _withdraw(address, uint256 amount, address recipient) internal override {
        IVatLike(vat).frob(ilk, -int256(uint256(amount)), 0);
        IGemJoinLike(gemJoin).exit(recipient, amount);
    }

    // --- IBorrowingAdapterLike ---

    function borrow(address asset, uint256 amount, address onBehalfOf, bytes calldata) external override onlyAggregator {
        require(asset == dai, "asset mismatch");
        IVatLike(vat).frob(ilk, 0, int256(uint256(amount))); // 借出等量 DAI，实际实现需换算 `dart`
        IDaiJoinLike(daiJoin).exit(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, address, bytes calldata) external override onlyAggregator {
        require(asset == dai, "asset mismatch");
        require(IERC20Minimal(dai).approve(daiJoin, amount), "approve failed");
        IDaiJoinLike(daiJoin).join(address(this), amount);
        IVatLike(vat).frob(ilk, 0, -int256(uint256(amount)));
    }

    function getHealthFactor(address account) external view override returns (uint256) {
        (uint256 ink, uint256 art) = IVatLike(vat).urns(ilk, account);
        if (art == 0) {
            return type(uint256).max;
        }
        // 近似：用抵押/债务比率映射为 Ray；真实实现需结合 Spot/Oracle 价格
        return (ink * 1e27) / art;
    }
}
```

#### Aave Adapter 示例（含借贷）

```solidity
pragma solidity ^0.8.24;

interface IAavePoolLike {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint8 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint8 interestRateMode, address onBehalfOf) external returns (uint256);
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}

contract AaveAdapterPseudo is BaseAdapter, IBorrowingAdapterLike {
    address public immutable asset;
    address public immutable pool;
    uint8 public immutable variableRateMode = 2; // 1=stable,2=variable

    constructor(address aggregator_, address asset_, address pool_) BaseAdapter(aggregator_) {
        asset = asset_;
        pool = pool_;
    }

    function _deposit(address, uint256 amount) internal override {
        require(IERC20Minimal(asset).approve(pool, amount), "approve failed");
        IAavePoolLike(pool).supply(asset, amount, address(this), 0);
    }

    function _withdraw(address, uint256 amount, address recipient) internal override {
        IAavePoolLike(pool).withdraw(asset, amount, recipient);
    }

    // --- IBorrowingAdapterLike ---

    function borrow(address debtAsset, uint256 amount, address onBehalfOf, bytes calldata data) external override onlyAggregator {
        uint8 rateMode = data.length > 0 ? abi.decode(data, (uint8)) : variableRateMode;
        IAavePoolLike(pool).borrow(debtAsset, amount, rateMode, 0, address(this));
        require(IERC20Minimal(debtAsset).transfer(onBehalfOf, amount), "transfer out failed");
    }

    function repay(address debtAsset, uint256 amount, address onBehalfOf, bytes calldata data) external override onlyAggregator {
        uint8 rateMode = data.length > 0 ? abi.decode(data, (uint8)) : variableRateMode;
        require(IERC20Minimal(debtAsset).approve(pool, amount), "approve failed");
        IAavePoolLike(pool).repay(debtAsset, amount, rateMode, address(this));
        onBehalfOf; // aggregator 代表账户，不额外使用
    }

    function getHealthFactor(address account) external view override returns (uint256) {
        (, , , , , uint256 hf) = IAavePoolLike(pool).getUserAccountData(account);
        return hf;
    }
}
```

> Spark、Morpho 等其他协议可仿照以上模式，分别继承 `BaseAdapter` 或 `IBorrowingAdapter`，在 `_deposit/_withdraw/borrow/repay` 中填入协议特定逻辑即可。
