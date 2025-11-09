# 从 0 到 1 搭建可扩展的 DeFi Lending Aggregator

> 目标：Compound + MakerDAO 优先接入，后续支持 Aave / Spark / Morpho，可动态扩展 Adapter，具备自动迁移与闪电贷路径优化能力。
>
> 相关文档：`docs/contract-interface-reference.md`（接口参考指南）、`docs/project-structure.md`（目录结构建议）。

}
```

> 其他协议（如 Aave、Spark、Morpho）可基于 `BaseAdapter` 独立实现各自的存取逻辑与附属接口。

````
- **目录约定**：仓库根目录 `<project-root>/AiFi`

```bash
cd <project-root>/AiFi
git init
git checkout -b main
```

---

## 2. 系统概览

- **智能合约层**：Aggregator 合约持有用户资金，Adapter 模式接入具体协议（Compound、Maker）。
- **Foundry**：
  - `src/`：Solidity 合约
  - `test/`：单元测试
  - `script/`：部署脚本
- **Go 后端**：Module 架构
  - `cmd/api`：HTTP API（deposit、withdraw、status）
  - `cmd/worker`：消费迁移任务
  - `internal/service`：业务逻辑（rateFetcher、strategy、taskBuilder）
  - `pkg/adapter/client`：与链交互的统一接口
- **缓存与消息队列**：
  - Redis 存储最新利率、阈值
  - RabbitMQ 处理迁移任务队列
- **Postgres**：记录用户、仓位、迁移任务、利率历史
- **流程**：
  1. 用户通过 API `deposit` 请求
  2. API 写入 Postgres（user、position），触发策略
  3. rateFetcher 周期性抓取链上利率，更新 Redis + Postgres
  4. Strategy 对比利率，若满足阈值，向 RabbitMQ 推送 `migration_task`
 5. Worker 消费任务，执行 Solidity Aggregator 的迁移：优先使用闪电贷，若目标协议不支持则回退为分步操作

### 2.1 合约接口清单与调用说明

> 这一节专门汇总链上需要交互的核心接口，便于后端或脚本模块统一封装调用逻辑。

- **Aggregator（`IAggregator`）**
    - `function deposit(address asset, uint256 amount, address adapter)`
        - **用途**：用户入金，Aggregator 托管资产并调用指定 Adapter 完成协议层存款。
        - **调用方**：后端 API（代表用户签名发送交易）或前端直接发起；需要在调用前完成 ERC20 授权。
        - **关键参数**：`asset` ERC20 地址；`amount` 存入数量（精度与 token decimals 对齐）；`adapter` 目标协议适配器。
        - **返回值**：无；通过事件 `Deposited` 提供链上追踪。
        - **注意事项**：应在调用前校验 Adapter 是否已在 Aggregator 注册，防止任意地址。
    - `function withdraw(address asset, uint256 amount, address adapter)`
        - **用途**：用户赎回；Aggregator 执行 Adapter 的取款，将资产返还给调用者。
        - **调用方**：用户地址；后端不能代替执行 unless 代理执行器。
        - **关键参数**：必须与仓位记录一致的 `asset` 与 `adapter`；`amount` <= 当前仓位。
        - **事件**：`Withdrawn(user, adapter, amount)` 用于同步 DB。
    - `function migrate(address user, address fromAdapter, address toAdapter, uint256 amount, bytes data)`
        - **用途**：在策略触发时将仓位从协议 A 迁移到 B，可结合闪电贷执行器降低资金成本。
        - **调用方**：受信任的闪电贷执行合约（`flashExecutor`）。
        - **参数说明**：
            - `user`：仓位所属钱包，便于更新存储映射。
            - `fromAdapter` / `toAdapter`：迁移前后协议适配器地址。
            - `amount`：迁移的基础资产数量。
            - `data`：Encoded payload（包含 asset 地址、flashRoute 信息等，可用 `abi.encode` 扩展）。
        - **安全重点**：仅允许闪电贷执行器调用；应在执行器侧完成实际借贷与偿还流程。
    - `function getPosition(address user, address asset) external view returns (Position memory)`
        - **用途**：查询仓位，后端可以在链上校验 DB 记录或构建合并视图。
        - **场景**：API `status`、Worker 校验迁移前仓位。

- **Adapter（`IAdapter`）**
    - `function deposit(address asset, uint256 amount)`
        - **职责**：封装协议特定的存款逻辑，例如 Compound `Mint`、Maker `join`。
        - **调用顺序**：Aggregator `deposit` 内部调用；需要事先在 Adapter 内部持有对目标协议的授权。
        - **实现要点**：处理资产授权、转换以及协议返回状态码。
    - `function withdraw(address asset, uint256 amount, address recipient)`
        - **职责**：从协议中取出资产并发送至指定地址。
        - **调用方**：Aggregator `withdraw` / `migrate` 过程。
        - **安全**：应验证 `recipient` 为 Aggregator 或调用者，避免资产被盗。
    - `function getSupplyRate(address asset) external view returns (uint256)`
        - **用途**：提供协议利率（APY 或 APR），用于 rateFetcher 刷新。
        - **返回值统一**：推荐以 Ray（`1e27`）或 BPS（`1e4`）标准化，便于跨协议对比。
    - `function getProtocolName() external view returns (bytes32)`
        - **用途**：标识适配器协议名称，便于后端动态映射。

- **FlashLoanExecutor（`FlashLoanExecutor` 接口）**
    - `function executeMigration(address user, address asset, uint256 amount, bytes calldata data)`
        - **职责**：统筹闪电贷调用；借入资金 → 调用 Aggregator `migrate` → 偿还闪电贷。
        - **调用方**：后端 Worker 触发的闪电贷提供方（Aave、Balancer 等）回调。
        - **可扩展字段**：`data` 可携带迁移路径、fee 配置、最小收益等参数。
        - **错误处理**：需捕获任何外部调用失败，并在失败时回滚整笔交易。

- **辅助接口**
    - `MockERC20.mint(address to, uint256 amount)`（仅测试环境）：快速铸造测试资产。
    - 未来接入闪电贷提供方时的 `IFlashLoanProvider`（建议定义）：
        - `flashLoan(address receiver, address asset, uint256 amount, bytes calldata params)`
        - 统一封装 Aave、Balancer、Uniswap 闪电贷差异，便于策略选择最低成本路径。

> 建议在 Go 后端中为上述接口生成 ABI 绑定（使用 `abigen`）或使用 `go-ethereum` 的 `bind` 工具生成类型安全客户端，以减少参数编码错误。

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
           address owner;
           address asset;
           uint256 amount;
           address adapter;
       }

       event Deposited(address indexed user, address indexed adapter, uint256 amount);
       event Withdrawn(address indexed user, address indexed adapter, uint256 amount);
       event Migrated(address indexed user, address fromAdapter, address toAdapter, uint256 amount);

       function deposit(address asset, uint256 amount, address adapter) external;
       function withdraw(address asset, uint256 amount, address adapter) external;
       function migrate(address user, address fromAdapter, address toAdapter, uint256 amount, bytes calldata data) external;
       function getPosition(address user, address asset) external view returns (Position memory);
   }
   ```

4. **Adapter 接口**（`contracts/src/adapters/IAdapter.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   interface IAdapter {
       function deposit(address asset, uint256 amount) external;
       function withdraw(address asset, uint256 amount, address recipient) external;
       function getSupplyRate(address asset) external view returns (uint256);
       function getProtocolName() external view returns (bytes32);
   }
   ```

5. **Flash Loan 执行器接口**（`contracts/src/flash/FlashLoanExecutor.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   interface FlashLoanExecutor {
       function executeMigration(address user, address asset, uint256 amount, bytes calldata data) external;
   }
   ```

6. **Aggregator 合约骨架**（`contracts/src/Aggregator.sol`）
   ```solidity
   // SPDX-License-Identifier: MIT
   pragma solidity ^0.8.24;

   import {IAggregator} from "./IAggregator.sol";
   import {IAdapter} from "./adapters/IAdapter.sol";

   contract Aggregator is IAggregator {
       mapping(address => mapping(address => Position)) private positions;
       address public flashExecutor;

       constructor(address flashExecutor_) {
           flashExecutor = flashExecutor_;
       }

       function deposit(address asset, uint256 amount, address adapter) external override {
           // TODO: 校验 amount、更新仓位映射、调用 Adapter.deposit 并发出事件
       }

       function withdraw(address asset, uint256 amount, address adapter) external override {
           // TODO: 校验仓位余额、调用 Adapter.withdraw；失败需 revert
       }

       function migrate(
           address user,
           address fromAdapter,
           address toAdapter,
           uint256 amount,
           bytes calldata data
       ) external override {
           // TODO: 仅允许 flashExecutor 调用，切换仓位 adapter，结合 data 解码 flashRoute
       }

       function getPosition(address user, address asset) external view override returns (Position memory) {
           // TODO: 返回 positions[user][asset]
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

       function deposit(address asset, uint256 amount) external override {
           // TODO: approve + mint
       }

       function withdraw(address asset, uint256 amount, address recipient) external override {
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

       function deposit(address asset, uint256 amount) external override {
           asset; amount; // TODO: join + lock
       }

       function withdraw(address asset, uint256 amount, address recipient) external override {
           asset; amount; recipient; // TODO: free
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

   contract MockFlashExecutor is FlashLoanExecutor {
       address public immutable aggregator;

       constructor(address _aggregator) {
           aggregator = _aggregator;
       }

       function executeMigration(address user, address asset, uint256 amount, bytes calldata data) external override {
           aggregator; user; asset; amount; data;
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
           aggregator.deposit(address(token), 100 ether, address(this));

           IAggregator.Position memory p = aggregator.getPosition(address(this), address(token));
           assertEq(p.amount, 100 ether);
       }

       function testWithdrawRevertsWhenInsufficient() public {
           vm.expectRevert();
           aggregator.withdraw(address(token), 1 ether, address(this));
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
     "asset": "0x...",
     "from_adapter": "0x...",
     "to_adapter": "0x...",
     "amount": "1000000000000000000",
     "rate_diff_bps": 120,
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

   type MigrationTask struct {
       ID          string `json:"id"`
       User        string `json:"user"`
       Asset       string `json:"asset"`
       FromAdapter string `json:"from_adapter"`
       ToAdapter   string `json:"to_adapter"`
       Amount      string `json:"amount"`
       RateDiffBps int    `json:"rate_diff_bps"`
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
       asset_address TEXT NOT NULL,
       adapter_address TEXT NOT NULL,
       amount NUMERIC(78, 0) NOT NULL,
       created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );

   CREATE TABLE migration_task (
       id UUID PRIMARY KEY,
       user_id UUID NOT NULL REFERENCES users(id),
       asset_address TEXT NOT NULL,
       from_adapter TEXT NOT NULL,
       to_adapter TEXT NOT NULL,
       amount NUMERIC(78, 0) NOT NULL,
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
   CREATE INDEX positions_user_asset_idx ON positions(user_id, asset_address);
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

interface IAdapterLike {
    function deposit(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount, address recipient) external;
}

contract AggregatorPseudo {
    struct Position {
        address owner;
        address asset;
        uint256 amount;
        address adapter;
    }

    mapping(address => mapping(address => Position)) internal positions;
    mapping(address => bool) public isAdapterAllowed;
    address public immutable flashExecutor;

    constructor(address flashExecutor_) {
        flashExecutor = flashExecutor_;
    }

    function setAdapter(address adapter, bool allowed) external {
        // 真实实现应加上访问控制（如 Ownable）
        isAdapterAllowed[adapter] = allowed;
    }

    function deposit(address asset, uint256 amount, address adapter) external {
        require(amount > 0, "amount=0");
        require(isAdapterAllowed[adapter], "adapter not allowed");

        Position storage position = positions[msg.sender][asset];
        if (position.owner == address(0)) {
            position.owner = msg.sender;
            position.asset = asset;
        }
        position.adapter = adapter;
        position.amount += amount;

        require(IERC20Minimal(asset).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        require(IERC20Minimal(asset).approve(adapter, amount), "approve failed");
        IAdapterLike(adapter).deposit(asset, amount);
    }

    function withdraw(address asset, uint256 amount, address adapter) external {
        Position storage position = positions[msg.sender][asset];
        require(position.amount >= amount, "insufficient");
        require(position.adapter == adapter, "adapter mismatch");

        position.amount -= amount;
        IAdapterLike(adapter).withdraw(asset, amount, address(this));
        require(IERC20Minimal(asset).transfer(msg.sender, amount), "transfer failed");
    }

    function migrate(
        address user,
        address fromAdapter,
        address toAdapter,
        uint256 amount,
        bytes calldata payload
    ) external {
        require(msg.sender == flashExecutor, "only flash");

        (address asset, bytes32 provider,) = abi.decode(payload, (address, bytes32, bytes));
        Position storage position = positions[user][asset];
        require(position.adapter == fromAdapter, "from mismatch");

        IAdapterLike(fromAdapter).withdraw(asset, amount, address(this));
        require(IERC20Minimal(asset).approve(toAdapter, amount), "approve dest failed");
        IAdapterLike(toAdapter).deposit(asset, amount);

        position.adapter = toAdapter;
        provider; // 在真实实现中根据 provider 选择闪电贷路线
    }

    function getPosition(address user, address asset) external view returns (Position memory) {
        return positions[user][asset];
    }
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

    function deposit(address asset, uint256 amount) external onlyAggregator {
        _deposit(asset, amount);
    }

    function withdraw(address asset, uint256 amount, address recipient) external onlyAggregator {
        _withdraw(asset, amount, recipient);
    }

    function _deposit(address asset, uint256 amount) internal virtual;
    function _withdraw(address asset, uint256 amount, address recipient) internal virtual;
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
}

contract CompoundAdapterPseudo is BaseAdapter {
    address public immutable asset;
    address public immutable cToken;

    constructor(address aggregator_, address asset_, address cToken_) BaseAdapter(aggregator_) {
        asset = asset_;
        cToken = cToken_;
    }

    function _deposit(address, uint256 amount) internal override {
        require(IERC20Minimal(asset).approve(cToken, amount), "approve failed");
        require(ICTokenLike(cToken).mint(amount) == 0, "mint failed");
    }

    function _withdraw(address, uint256 amount, address recipient) internal override {
        require(ICTokenLike(cToken).redeemUnderlying(amount) == 0, "redeem failed");
        require(IERC20Minimal(asset).transfer(recipient, amount), "transfer failed");
    }
}
```

#### Maker Adapter 示例

```solidity
pragma solidity ^0.8.24;

interface IVatLike {
    function frob(bytes32 ilk, int256 dink, int256 dart) external;
}

interface IGemJoinLike {
    function join(address usr, uint256 wad) external;
    function exit(address usr, uint256 wad) external;
}

contract MakerAdapterPseudo is BaseAdapter {
    address public immutable asset;
    bytes32 public immutable ilk;
    address public immutable vat;
    address public immutable gemJoin;

    constructor(
        address aggregator_,
        address asset_,
        bytes32 ilk_,
        address vat_,
        address gemJoin_
    ) BaseAdapter(aggregator_) {
        asset = asset_;
        ilk = ilk_;
        vat = vat_;
        gemJoin = gemJoin_;
    }

    function _deposit(address, uint256 amount) internal override {
        require(IERC20Minimal(asset).approve(gemJoin, amount), "approve failed");
        IGemJoinLike(gemJoin).join(address(this), amount);
        IVatLike(vat).frob(ilk, int256(uint256(amount)), 0);
    }

    function _withdraw(address, uint256 amount, address recipient) internal override {
        IVatLike(vat).frob(ilk, -int256(uint256(amount)), 0);
        IGemJoinLike(gemJoin).exit(recipient, amount);
    }
}
```

> 其他协议（如 Aave、Spark、Morpho）可基于 `BaseAdapter` 独立实现各自的存取逻辑与附属接口。
