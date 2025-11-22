// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

error AdapterNotAllowed();  // 不在白名单
error InvalidAsset();      // 无效的资产地址
error InvalidAmount();     // 无效的数量
error NotPositionOwner(); // 非仓位所有者
error InsufficientCollateral(); // 抵押不足
error InsufficientDebt();       // 债务不足
error PositionAlreadyExists(); // 仓位已存在
error AdapterMismatch();       // Adapter 不匹配
error AssetMismatch();         // 资产不匹配
error InvalidPosition();      // 无效的仓位
error InvalidETHAmount();    // ETH 数量不匹配
error ETHNotAccepted();      // 不接受 ETH
error HealthFactorTooLow();    // 健康因子过低
error NotFlashExecutor();    // 非 Flash Executor