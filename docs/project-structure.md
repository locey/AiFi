# 项目目录结构设计提案

> 以下为建议的仓库目录布局，覆盖智能合约、后端、基础设施、文档及 CI 配置，便于团队协作与模块化开发。

```
AiFi/
├── contracts/                     # Foundry 智能合约工程
│   ├── src/
│   │   ├── Aggregator.sol
│   │   ├── IAggregator.sol
│   │   ├── adapters/
│   │   │   ├── IAdapter.sol
│   │   │   ├── CompoundAdapter.sol
│   │   │   ├── MakerAdapter.sol
│   │   │   └── ... (Aave/Spark/Morpho)
│   │   └── flash/
│   │       ├── FlashLoanExecutor.sol
│   │       └── providers/
│   │           ├── BalancerProvider.sol
│   │           ├── UniswapV3Provider.sol
│   │           └── AaveProvider.sol
│   ├── test/
│   │   ├── Aggregator.t.sol
│   │   ├── adapters/
│   │   └── utils/
│   ├── script/
│   │   ├── Deploy.s.sol
│   │   └── Verify.s.sol
│   ├── lib/
│   ├── foundry.toml
│   └── README.md
│
├── backend/                       # Go 服务
│   ├── cmd/
│   │   ├── api/
│   │   │   └── main.go
│   │   └── worker/
│   │       └── main.go
│   ├── internal/
│   │   ├── api/            # HTTP handler / Router
│   │   ├── config/
│   │   ├── service/
│   │   │   ├── ratefetcher/
│   │   │   ├── strategy/
│   │   │   └── flashrouter/
│   │   ├── worker/
│   │   ├── db/
│   │   ├── cache/
│   │   └── mq/
│   ├── pkg/
│   │   ├── clients/        # 链上客户端、ABI 绑定
│   │   └── logger/
│   ├── migrations/         # SQL or embed
│   ├── go.mod
│   └── README.md
│
├── infra/
│   ├── docker/
│   │   ├── docker-compose.yaml
│   │   └── Dockerfile.backend
│   ├── migrations/         # database schema scripts
│   ├── k8s/                # Kubernetes manifests (可选)
│   └── README.md
│
├── docs/
│   ├── lending-aggregator-tutorial.md
│   ├── contract-interface-reference.md
│   ├── project-structure.md
│   ├── adapters/
│   │   ├── compound.md
│   │   ├── maker.md
│   │   └── aave.md
│   ├── governance/             # 可选：多签提案模板、参数变更记录
│   └── README.md               # 可选：文档索引或贡献指南
│
├── scripts/                     # 辅助脚本 (bash / python)
│   ├── generate-abi.sh
│   ├── seed-db.sh
│   └── run-tests.sh
│
├── .github/
│   └── workflows/
│       ├── ci.yml
│       ├── contracts.yml
│       └── backend.yml
│
├── .env.example
├── README.md                    # 项目说明 (总览)
└── LICENSE
```

## 说明

- **contracts/**：以 Foundry 为基础，模块化区分核心 Aggregator、Adapter、Flash Loan Provider，每个子模块可独立扩展。
- **backend/**：Go 服务按照 `cmd` / `internal` / `pkg` 规范组织，支持模块化业务逻辑与重用组件；`service/flashrouter` 专门处理闪电贷路线选择。
- **infra/**：统一存放容器配置、数据库迁移、Kubernetes 文件，方便 DevOps 管理。
- **docs/**：核心文档仓库，当前包含聚合器教程、接口说明及 `adapters/` 下的协议接入指南。建议增加 `governance/` 记录多签提案与参数变更，以及文档索引 README 便于团队导航。
- **governance/**（可选）：记录多签配置、Timelock 提案、参数变更 Runbook，与 `docs/SECURITY.md` 联动管理权限更新历史。
- **scripts/**：常用自动化脚本（生成 ABI、数据库初始化、运行测试），便于项目启动与 CI 集成。
- **.github/workflows/**： CI/CD 配置拆分为通用 CI、合约测试、后端测试，可根据需要加上部署流程。

团队可在此基础上增删目录，例如加入 `frontend/`（若有 Dashboard）、`terraform/`（基础设施即代码）或 `monitoring/`（Prometheus 配置）。
