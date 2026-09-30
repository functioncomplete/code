// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GateEngine} from "./GateEngine.sol";
import {DSURuntime} from "./DSURuntime.sol";

/// @title HybridChain
/// @notice FCT v2 混合模式**信任闭合**集成（whitepaper v1.4 §4.3.3）——逻辑原语引擎 + DSU 运行时的合流。
///
///         M6 的 `HybridGate` 让证明者**提交** DSU 输出（乐观模型，靠罚没博弈约束）；
///         本合约把证明链收进合约内部：
///           ① 合约调用 `DSURuntime.execute` 真跑 DSU（参考实现，步数计量）
///           ② 合约调用 `GateEngine.eval` 做逻辑原语 IR 重放
///           ③ 两者一致 → 更新状态槽；不一致 → 记为 REJECTED，不写状态
///         因此**无需信任任何外部提交者**：DSU 结果不是"谁说"的，而是合约算出来的。
///
///         适用面：DSU 类别与逻辑原语 IR 在语义上重合的场景（如 4 位加法：ARITH mod 16
///         对照 ADD4 的 60 门 NAND 逻辑原语 IR）。不可逻辑原语展开的 DSU（哈希/ML）仍走 M6 的
///         乐观/ZK/TEE 证明路径 —— 本合约演示的是"可逻辑原语展开部分"的零信任收口。
///
///         状态槽键绑定**完整语句**（fnId, dsuId, inBits, stateBits, keccak(dsuInput), mask）：
///         否则第三方可用 `mask=0` + 退化的 dsuInput 令 `0==0`，为任意 inBits 写入伪造的
///         "已验证"槽并覆盖合法值。键确定后值也确定（两端都是确定性函数），故写入为**单调**：
///         首个 VERIFIED 之后不再改写。
///
///         已知限制（非缺陷）：
///         - DSU 输出必须是**恰好 32 字节的单字**（ARITH/STATE_MACHINE/HASH/SIGN）。
///           多字输出（如 `ML` 的 `int256[]`）被显式拒绝（require(dsuOut.length == 32)）；
///           否则 `abi.decode` 会把 ABI 偏移量当成结果、静默产出无意义数值。
///         - `DSURuntime` 只按类别用内建参考实现执行，不路由 `DSU.impl`（见其 natspec）。
///
///         无外部调用、无可重入面（engine/runtime 为不可变且只读）。
contract HybridChain {
    enum Status {
        NONE,
        VERIFIED,
        REJECTED
    }

    struct Slot {
        uint256 value;
        bytes32 fnId;
        uint48 at;
        bool set;
    }

    GateEngine public immutable engine;
    DSURuntime public immutable runtime;

    mapping(bytes32 => Slot) public slots; // statementId -> 已验证状态
    uint64 public nextReq;

    event Executed(
        uint64 indexed reqId,
        bytes32 indexed interfaceId,
        Status status,
        uint256 dsuResult,
        uint256 gateResult,
        uint256 steps
    );

    constructor(GateEngine _engine, DSURuntime _runtime) {
        engine = _engine;
        runtime = _runtime;
    }

    /// @notice 执行一次混合证明链。
    /// @param fnId      逻辑原语验证锚（GateEngine 登记的逻辑原语 IR）
    /// @param dsuId     DSU 执行引擎（DSURuntime/DSU 登记）
    /// @param inBits    逻辑原语输入位域（ADD4: a | b<<4）
    /// @param stateBits LATCH 当前状态位域（无时序则 0）
    /// @param dsuInput  DSU 输入字节（ARITH: [op:1][a:32][b:32][mod:32]）
    /// @param mask      逻辑原语输出按位比较掩码（ADD4 取和 → 0x0F）
    function execute(
        bytes32 fnId,
        bytes32 dsuId,
        uint256 inBits,
        uint256 stateBits,
        bytes calldata dsuInput,
        uint256 mask
    ) external returns (uint64 reqId, Status status, uint256 dsuResult, uint256 gateResult) {
        reqId = nextReq++;

        // ① 合约内执行 DSU（真实步数计量，超预算则 revert）
        (bytes memory dsuOut, uint256 steps) = runtime.execute(dsuId, dsuInput);
        require(dsuOut.length == 32, "non-word output");
        dsuResult = abi.decode(dsuOut, (uint256));

        // ② 合约内逻辑原语重放
        (uint256 gateOut,) = engine.eval(fnId, inBits, stateBits);
        gateResult = gateOut & mask;

        // ③ 比对 → 状态槽（键绑定完整语句，写入单调）
        bytes32 interfaceId = interfaceIdOf(fnId, dsuId, inBits, stateBits, dsuInput, mask);
        if (dsuResult == gateResult) {
            status = Status.VERIFIED;
            if (!slots[interfaceId].set) {
                slots[interfaceId] = Slot({value: gateResult, fnId: fnId, at: uint48(block.timestamp), set: true});
            }
        } else {
            status = Status.REJECTED;
        }

        emit Executed(reqId, interfaceId, status, dsuResult, gateResult, steps);
    }

    /// @notice 状态槽键：绑定完整语句（含 dsuInput 的内容哈希与 mask）。
    function interfaceIdOf(
        bytes32 fnId,
        bytes32 dsuId,
        uint256 inBits,
        uint256 stateBits,
        bytes calldata dsuInput,
        uint256 mask
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(fnId, dsuId, inBits, stateBits, keccak256(dsuInput), mask));
    }

    /// @notice 查询某状态槽（未验证过则 set=false）。
    function slotOf(
        bytes32 fnId,
        bytes32 dsuId,
        uint256 inBits,
        uint256 stateBits,
        bytes calldata dsuInput,
        uint256 mask
    ) external view returns (Slot memory) {
        return slots[interfaceIdOf(fnId, dsuId, inBits, stateBits, dsuInput, mask)];
    }

    /// @notice 只读预演：不写状态，返回两者结果与是否一致。
    function preview(
        bytes32 fnId,
        bytes32 dsuId,
        uint256 inBits,
        uint256 stateBits,
        bytes calldata dsuInput,
        uint256 mask
    ) external view returns (bool agree, uint256 dsuResult, uint256 gateResult, uint256 steps) {
        (bytes memory dsuOut, uint256 s) = runtime.execute(dsuId, dsuInput);
        require(dsuOut.length == 32, "non-word output");
        dsuResult = abi.decode(dsuOut, (uint256));
        (uint256 gateOut,) = engine.eval(fnId, inBits, stateBits);
        gateResult = gateOut & mask;
        steps = s;
        agree = dsuResult == gateResult;
    }
}
