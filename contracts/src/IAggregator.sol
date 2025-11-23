// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAggregator {
    struct Position {
        bytes32 id;
        address owner; // 仓位所有者地址
        address collateralAsset; // 抵押资产地址，address(0) 表示 ETH
        address adapter; // 关联的 Adapter 地址
        uint256 collateralAmount; // 抵押资产数量
        address debtAsset; // 债务资产地址，address(0) 表示无债务
        uint256 debtAmount; // 债务数量
        uint256 lastHealthFactor; // 上次操作后的健康因子
    }

    struct DepositExtra {
        bytes permit;          // EIP-2612 或 Permit2 数据，可为空
        uint256 minShares;     // 允许的最小份额，避免滑点
        bytes adapterParams;   // 直接透传给 Adapter 的自定义字段
    }

    struct DebtLeg {
        address asset;
        uint256 amount;
        bytes adapterData;             // 比如利率模式、杠杆倍数
    }

    struct CollateralLeg {
        address asset;
        uint256 amount;
        bytes adapterData;           // 提供分腿赎回/存款的补充信息
    }

    struct FlashRoute {
        bytes32 provider;           // 如 "AAVE", 
        uint256 feeBps;
        uint256 maxSlippageBps;
        bytes payload;              // 供执行器解码的自定义数据
    }

    struct MigrationParams {
        bytes32 positionId;
        
        // 来源信息
        address fromAdapter;
        uint256 repayAmount;      // 需要偿还的旧债务金额
        uint256 collateralAmount; // 需要提取的旧抵押品金额

        // 目标信息
        address toAdapter;
        address newDebtAsset;     // 新债务资产地址 (通常与旧债务一致，但允许变动)
        uint256 borrowAmount;     // 需要借入的新债务金额

        // 闪电贷路由 (保留，因为迁移通常需要闪电贷)
        FlashRoute[] flash;
        
        // 额外数据 (透传给 Adapter)
        bytes extra;
    }

    event Deposited(bytes32 indexed positionId, address indexed user, address indexed adapter, uint256 amount, bytes extra);
    event Withdrawn(bytes32 indexed positionId, address indexed user, address indexed adapter, uint256 amount, bytes extra);
    event Borrowed(bytes32 indexed positionId, address indexed user, address indexed adapter, address assert, uint256 amount, bytes data);
    event Repaid(bytes32 indexed positionId, address indexed user, address indexed adapter, address asset, uint256 amount, bytes data);
    event Migrated(bytes32 indexed positionId, address indexed user, address fromAdapter, address toAdapter, bytes data);
    event AdapterStatusChanged(address indexed adapter, bool allowed);

    function deposit(bytes32 positionId, address collateralAsset, uint256 amount, address adapter, bytes calldata extra) external returns(bytes32);
    function withdraw(bytes32 positionId, uint256 amount, bytes calldata extra) external;
    function borrow(bytes32 positionId, address debtAsset, uint256 amount, bytes calldata data) external;
    function repay(bytes32 positionId, address debtAsset, uint256 amount, bytes calldata data) external;
    function migrate(MigrationParams calldata params) external;
    function getPosition(bytes32 positionId) external view returns (Position memory);
    function getAllPositions() external view returns (Position[] memory);
    function getPositions(uint256 start, uint256 limit) external view returns (Position[] memory);
    function derivePositionId(address owner, address collateralAsset, address adapter, bytes32 salt) external pure returns (bytes32);
}