// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAggregator} from "../IAggregator.sol";

interface FlashLoanExecutor {
    function executeMigration(IAggregator.MigrationParams calldata params) external;
}