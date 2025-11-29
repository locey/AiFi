// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IAggregator} from "./IAggregator.sol";
import {IAdapter, IBorrowingAdapter} from "./IAdapter.sol";
import "./utils/Errors.sol";

contract Aggregator is IAggregator, AccessControl {
    mapping(bytes32 => Position) public positions;
    mapping(address => bool) public isAdapterAllowed;
    bytes32[] public allPositionIds;
    address public flashExecutor;
    bytes32 public constant ADAPTER_ADMIN_ROLE =
        keccak256("ADAPTER_ADMIN_ROLE");

    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    event AdapterPermissionUpdated(address indexed adapter, bool allowed);

    constructor(address _flashExecutor) {
        flashExecutor = _flashExecutor;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADAPTER_ADMIN_ROLE, msg.sender);
    }

    function setAdapter(
        address adapter,
        bool allowed
    ) external onlyRole(ADAPTER_ADMIN_ROLE) {
        isAdapterAllowed[adapter] = allowed;
        emit AdapterPermissionUpdated(adapter, allowed);
    }

    function deposit(
        bytes32 positionId,
        address collateralAsset,
        uint256 amount,
        address adapter,
        bytes calldata extra
    ) external returns (bytes32) {
        if (!isAdapterAllowed[adapter]) revert AdapterNotAllowed();
        if (amount == 0) revert InvalidAmount();

        if (collateralAsset == address(0)) revert ETHNotAccepted();

        if (positionId == bytes32(0)) {
            // 新建仓位
            positionId = derivePositionId(
                msg.sender,
                collateralAsset,
                adapter,
                keccak256(extra)
            );
            if (positions[positionId].owner != address(0))
                revert PositionAlreadyExists();
            // 记录所有仓位 ID
            allPositionIds.push(positionId);
        } else {
            // 已有仓位，校验一致性
            Position storage existingPos = positions[positionId];
            if (existingPos.owner == address(0)) revert InvalidPosition();
            if (existingPos.owner != msg.sender) revert NotPositionOwner();
            if (existingPos.adapter != adapter) revert AdapterMismatch();
            if (existingPos.collateralAsset != collateralAsset)
                revert AssetMismatch();
        }

        Position storage position = positions[positionId];

        // 统一 ERC20 处理逻辑
        SafeERC20.safeTransferFrom(
            IERC20(collateralAsset),
            msg.sender,
            address(this),
            amount
        );
        SafeERC20.forceApprove(IERC20(collateralAsset), adapter, amount);
        IAdapter(adapter).deposit(
            collateralAsset,
            amount,
            msg.sender,
            extra
        );
        if (position.owner == address(0)) {
            // 初始化仓位信息
            position.id = positionId;
            position.owner = msg.sender;
            position.collateralAsset = collateralAsset;
            position.adapter = adapter;
            position.debtAsset = address(0);
            position.debtAmount = 0;
            position.lastHealthFactor = 0;
        }
        position.collateralAmount += amount;
        emit Deposited(
            positionId,
            msg.sender,
            adapter,
            amount,
            extra
        );
        return positionId;
    }

    function withdraw(
        bytes32 positionId,
        uint256 amount,
        bytes calldata extra
    ) external override {
        // 获取仓位信息
        Position storage position = positions[positionId];

        // 只有仓位所有者可以调用
        if (position.owner != msg.sender) revert NotPositionOwner();

        // 参数检查：提现金额必须有效且不超过余额
        if (amount == 0) revert InvalidAmount();
        if (position.collateralAmount < amount) revert InsufficientCollateral();

        // 更新状态
        position.collateralAmount -= amount;

        // 执行提现
        IAdapter(position.adapter).withdraw(
            position.collateralAsset,
            amount,
            msg.sender,
            position.owner,
            extra
        );

        // 健康检查，如果有债务，需要确保健康因子满足要求
        if (position.debtAmount > 0) {
            uint256 healthFactor = IBorrowingAdapter(position.adapter)
                .getHealthFactor(msg.sender);
            if (healthFactor < MIN_HEALTH_FACTOR) revert HealthFactorTooLow();
            position.lastHealthFactor = healthFactor;
        }
        emit Withdrawn(
            positionId,
            msg.sender,
            position.adapter,
            amount,
            extra
        );
    }

    function borrow(
        bytes32 positionId,
        address debtAsset,
        uint256 amount,
        bytes calldata data
    ) external override {
        Position storage position = positions[positionId];

        // 权限与参数检查
        if (position.owner != msg.sender) revert NotPositionOwner();
        if (amount == 0) revert InvalidAmount();

        // 债务资产一致性检查
        // debtAmount 为 0 时，首次借贷，设置债务资产
        if (position.debtAmount == 0) {
            position.debtAsset = debtAsset;
        } else {
            // 非首次借贷，检查债务资产一致性
            if (position.debtAsset != debtAsset) revert AssetMismatch();
        }

        // 执行借贷
        IBorrowingAdapter(position.adapter).borrow(
            debtAsset,
            amount,
            msg.sender, // recipient: 钱给用户
            position.owner, // owner: 债记在用户头上
            data
        );

        // 更新状态
        position.debtAmount += amount;

        // 健康检查
        // 借款会导致健康因子下降，必须确保借款后仍然高于最低阈值
        uint256 healthFactor = IBorrowingAdapter(position.adapter)
            .getHealthFactor(msg.sender);
        if (healthFactor < MIN_HEALTH_FACTOR) revert HealthFactorTooLow();
        position.lastHealthFactor = healthFactor;
        emit Borrowed(
            positionId,
            msg.sender,
            position.adapter,
            debtAsset,
            amount,
            data
        );
    }

    function repay(
        bytes32 positionId,
        address debtAsset,
        uint256 amount,
        bytes calldata data
    ) external override {
        Position storage position = positions[positionId];

        // 权限与参数检查
        if (position.owner != msg.sender) revert NotPositionOwner();
        if (amount == 0) revert InvalidAmount();
        // 必须偿还该仓位记录的债务资产
        if (position.debtAsset != debtAsset) revert AssetMismatch();

        // 自己转移：用户 -> 聚合器
        SafeERC20.safeTransferFrom(
            IERC20(debtAsset),
            msg.sender,
            address(this),
            amount
        );
        // 授权聚合器：聚合器 -> 适配器
        SafeERC20.forceApprove(IERC20(debtAsset), position.adapter, amount);
    
        // 执行偿还
        IBorrowingAdapter(position.adapter).repay(
            debtAsset,
            amount,
            msg.sender,
            data
        );

        // 检查合约里是否有多余的钱（底层协议没收走的钱）
        uint256 remainingBalance = IERC20(debtAsset).balanceOf(address(this));
        if (remainingBalance > 0) {
            // 退还多余的钱给用户
            SafeERC20.safeTransfer(
                IERC20(debtAsset),
                msg.sender,
                remainingBalance
            );
            // 修正：实际还款金额 = 传入金额 - 退回金额
            amount -= remainingBalance;
        }
        // 更新状态
        if (amount > position.debtAmount) {
            position.debtAmount = 0;
        } else {
            position.debtAmount -= amount;
        }

        // 更新健康因子
        if (position.debtAmount == 0) {
            position.lastHealthFactor = type(uint256).max;
        } else {
            // 如果还有剩余债务，更新最新的健康因子
            uint256 healthFactor = IBorrowingAdapter(position.adapter)
                .getHealthFactor(msg.sender);
            position.lastHealthFactor = healthFactor;
        }
        emit Repaid(
            positionId,
            msg.sender,
            position.adapter,
            debtAsset,
            amount,
            data
        );
    }

    function migrate(MigrationParams calldata params) external override {
        // 校验权限
        if (msg.sender != flashExecutor) revert NotFlashExecutor();

        Position storage position = positions[params.positionId];
        if (position.owner == address(0)) revert InvalidPosition();

        // 偿还旧债务
        if (params.repayAmount > 0) {
            SafeERC20.forceApprove(
                IERC20(position.debtAsset),
                position.adapter,
                params.repayAmount
            );
            IBorrowingAdapter(position.adapter).repay(
                position.debtAsset,
                params.repayAmount,
                position.owner,
                params.extra
            );

            if (params.repayAmount > position.debtAmount) {
                position.debtAmount = 0;
            } else {
                position.debtAmount -= params.repayAmount;
            }
        }

        // 提取旧抵押品
        if (params.collateralAmount > 0) {
            IAdapter(position.adapter).withdraw(
                position.collateralAsset,
                params.collateralAmount,
                address(this),
                position.owner,
                params.extra
            );
            position.collateralAmount -= params.collateralAmount;
        }

        // 切换到新 Adapter
        position.adapter = params.toAdapter;

        // 存入新adapter
        if (params.collateralAmount > 0) {
            SafeERC20.forceApprove(
                IERC20(position.collateralAsset),
                params.toAdapter,
                params.collateralAmount
            );
            IAdapter(params.toAdapter).deposit(
                position.collateralAsset,
                params.collateralAmount,
                position.owner,
                params.extra
            );
            position.collateralAmount += params.collateralAmount;
        }

        // 借入新债务
        if (params.borrowAmount > 0) {
            IBorrowingAdapter(params.toAdapter).borrow(
                params.newDebtAsset,
                params.borrowAmount,
                address(this),   // recipient: 钱给合约
                position.owner, // owner: 债记在用户头上
                params.extra
            );

            position.debtAsset = params.newDebtAsset;
            position.debtAmount = params.borrowAmount;

            // 将钱还给 flashExecutor
            SafeERC20.safeTransfer(
                IERC20(params.newDebtAsset),
                flashExecutor,
                params.borrowAmount
            );
        }

        // 健康检查
        uint256 healthFactor = IBorrowingAdapter(position.adapter)
            .getHealthFactor(position.owner);
        if (healthFactor < MIN_HEALTH_FACTOR) revert HealthFactorTooLow();
        position.lastHealthFactor = healthFactor;

        emit Migrated(
            params.positionId,
            position.owner,
            params.fromAdapter,
            params.toAdapter,
            params.extra
        );
    }

    function getPosition(
        bytes32 positionId
    ) external view override returns (Position memory) {
        return positions[positionId];
    }

    // 一次性返回所有仓位详情
    function getAllPositions() external view returns (Position[] memory) {
        uint256 length = allPositionIds.length;
        Position[] memory allPositions = new Position[](length);

        for (uint256 i = 0; i < length; i++) {
            bytes32 id = allPositionIds[i];
            allPositions[i] = positions[id];
        }

        return allPositions;
    }

    // 分页获取仓位（推荐，防止数据量过大）
    function getPositions(
        uint256 start,
        uint256 limit
    ) external view returns (Position[] memory) {
        uint256 total = allPositionIds.length;
        if (start >= total) {
            return new Position[](0);
        }

        uint256 end = start + limit;
        if (end > total) {
            end = total;
        }

        uint256 resultLen = end - start;
        Position[] memory result = new Position[](resultLen);

        for (uint256 i = 0; i < resultLen; i++) {
            bytes32 id = allPositionIds[start + i];
            result[i] = positions[id];
        }

        return result;
    }

    function derivePositionId(
        address owner,
        address collateralAsset,
        address adapter,
        bytes32 salt
    ) public pure override returns (bytes32) {
        return keccak256(abi.encode(owner, collateralAsset, adapter, salt));
    }

    receive() external payable {}
}