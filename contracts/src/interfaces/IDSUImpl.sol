// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDSUImpl
/// @notice 外部 DSU 实现（预编译合约 / 运行时）需实现的只读执行接口。
///         `DSURuntime` 在 `DSU.records(dsuId).impl != address(0)` 时经 **staticcall** 委派到该地址，
///         否则使用内建参考实现。
///
///         `impl` 由 `DSU.registerDSU/updateImpl` 设置 —— 而 `DSU` 的登记是 owner 门控，
///         因此"被委派的实现"是治理层显式信任的代码，不是任意第三方。
///
///         契约：
///         - 必须是 `view`（DSURuntime 以 staticcall 调用，禁状态变更）
///         - 返回 `(output, steps)`：output 的 ABI 编码必须与内建同类别一致（单字/数组依类别）
///         - `steps` 由实现自报；`DSURuntime` 仍会强制 `steps <= DSU.maxSteps`
///         - 失败**应带 revert 原因**（会被 DSURuntime 原样冒泡便于排障）；无原因时折为 `ImplFailed`
interface IDSUImpl {
    function execute(bytes calldata input) external view returns (bytes memory output, uint256 steps);
}
