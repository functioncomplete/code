// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DSU} from "./DSU.sol";
import {IDSUImpl} from "./interfaces/IDSUImpl.sol";

/// @title DSURuntime
/// @notice FCT v2 DSU 执行引擎（whitepaper v1.3 §4.2 / dev-plan §5.3）——DSU 交付。
///
///         `DSU.sol` 承载**身份与预算**（类别 + 版本 + 参数 + 模型 → dsuId，maxSteps）；
///         本合约承载**执行**：按类别运行参考实现，并做**真实步数计量**
///         （替换此前无许可 no-op 的 `DSU.consumeSteps` 占位：执行超出 maxSteps 直接 revert）。
///
///         只读执行（view）：不写外部状态；除 keccak/sha256/ecrecover 原语外，仅在 DSU 登记了
///         `impl` 时经 **staticcall** 委派到该实现（治理登记，见 IDSUImpl）、
///         无重入面。状态修改仍由容器层根据输出统一执行（§4.2「只读执行」）。
///
///         输入编码（`bytes input`，首字节为类别内选择子）：
///         - HASH   : [algo:1][data:*]                algo 0=keccak256 1=sha256
///         - SIGN   : [hash:32][v:1][r:32][s:32]      → 恢复出的地址（失败 revert）
///         - ARITH  : [op:1][a:32][b:32][mod:32]      op 0=add 1=mul 2=sub（mod ≠ 0）
///         - STATE_MACHINE: [n:1][seed:32]            迭代 n 步（n ≤ 预算，防无界循环）
///         - ML     : [m:1][k:1][W:m*k int8][x:k int8][b:m int8]  → int256[m] 量化前向
contract DSURuntime {
    DSU public immutable dsu;

    error BudgetExceeded(uint256 steps, uint256 maxSteps);
    error UnknownDSU(bytes32 dsuId);
    error BadInput();
    error ImplFailed(address impl);

    constructor(DSU _dsu) {
        dsu = _dsu;
    }

    /* ============================ 执行入口 ============================ */

    /// @notice 按 dsuId 的类别执行参考实现，返回输出与消耗步数。
    ///         步数超过 `DSU.maxSteps` 时 revert（终止性保证真正链上强制）。
    function execute(bytes32 dsuId, bytes calldata input)
        external
        view
        returns (bytes memory output, uint256 steps)
    {
        (bool ok, uint256 maxSteps, DSU.DSUType t, address impl) = _load(dsuId);
        if (!ok) revert UnknownDSU(dsuId);

        // 治理登记的显式实现（预编译/运行时）优先；staticcall 保证只读
        if (impl != address(0)) {
            return _callImpl(impl, input, maxSteps);
        }

        if (t == DSU.DSUType.HASH) {
            (output, steps) = _hash(input, maxSteps);
        } else if (t == DSU.DSUType.SIGN) {
            (output, steps) = _sign(input, maxSteps);
        } else if (t == DSU.DSUType.ARITH) {
            (output, steps) = _arith(input, maxSteps);
        } else if (t == DSU.DSUType.STATE_MACHINE) {
            (output, steps) = _stateMachine(input, maxSteps);
        } else if (t == DSU.DSUType.ML) {
            (output, steps) = _ml(input, maxSteps);
        } else {
            revert UnknownDSU(dsuId); // 枚举穷尽：未来新增类别必须显式接入
        }
    }

    /// @notice 只查询步数预算与类别（不执行）。
    function budgetOf(bytes32 dsuId) external view returns (uint256 maxSteps, DSU.DSUType t, bool registered) {
        (bool ok, uint256 ms, DSU.DSUType ty,) = _load(dsuId);
        return (ms, ty, ok);
    }

    /* ============================ 类别实现 ============================ */

    /// HASH: [algo:1][data:*]
    /// 预算**先于**工作校验：超预算直接 revert，不会先对巨大输入做哈希再回滚。
    function _hash(bytes calldata input, uint256 maxSteps) private pure returns (bytes memory output, uint256 steps) {
        if (input.length < 1) revert BadInput();
        uint8 algo = uint8(input[0]);
        if (algo > 1) revert BadInput();
        bytes calldata data = input[1:];
        // 成本模型：per-hash + per-byte（按 32 字节字计）
        steps = 1 + (data.length + 31) / 32;
        if (steps > maxSteps) revert BudgetExceeded(steps, maxSteps);
        if (algo == 0) {
            output = abi.encode(keccak256(data));
        } else {
            output = abi.encode(sha256(data));
        }
    }

    /// SIGN: [hash:32][v:1][r:32][s:32] → secp256k1 恢复地址
    /// 要求 low-s（s ≤ n/2）：排除 (r, n−s) 的可延展等价签名。
    function _sign(bytes calldata input, uint256 maxSteps) private pure returns (bytes memory output, uint256 steps) {
        steps = 1;
        if (steps > maxSteps) revert BudgetExceeded(steps, maxSteps);
        if (input.length != 97) revert BadInput();
        bytes32 h = bytes32(input[0:32]);
        uint8 v = uint8(input[32]);
        bytes32 r = bytes32(input[33:65]);
        bytes32 s = bytes32(input[65:97]);
        if (v != 27 && v != 28) revert BadInput();
        // secp256k1 n/2（EIP-2 low-s 上界）
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) revert BadInput();
        address signer = ecrecover(h, v, r, s);
        if (signer == address(0)) revert BadInput();
        output = abi.encode(signer);
    }

    /// ARITH: [op:1][a:32][b:32][mod:32]，op 0=add 1=mul 2=sub
    function _arith(bytes calldata input, uint256 maxSteps) private pure returns (bytes memory output, uint256 steps) {
        steps = 1; // per-field-op
        if (steps > maxSteps) revert BudgetExceeded(steps, maxSteps);
        if (input.length != 97) revert BadInput();
        uint8 op = uint8(input[0]);
        uint256 a = uint256(bytes32(input[1:33]));
        uint256 b = uint256(bytes32(input[33:65]));
        uint256 m = uint256(bytes32(input[65:97]));
        if (m == 0) revert BadInput();
        uint256 res;
        if (op == 0) {
            res = addmod(a % m, b % m, m);
        } else if (op == 1) {
            res = mulmod(a % m, b % m, m);
        } else if (op == 2) {
            res = addmod(a % m, m - (b % m), m);
        } else {
            revert BadInput();
        }
        output = abi.encode(res);
    }

    /// STATE_MACHINE: [n:1][seed:32]，确定性迭代 n 步
    function _stateMachine(bytes calldata input, uint256 maxSteps)
        private
        pure
        returns (bytes memory output, uint256 steps)
    {
        if (input.length != 33) revert BadInput();
        uint256 n = uint256(uint8(input[0]));
        uint256 x = uint256(bytes32(input[1:33]));
        // n 受 maxSteps 约束（fail-closed：无界循环不可能发生）
        if (n > maxSteps) revert BudgetExceeded(n, maxSteps);
        for (uint256 i = 0; i < n; i++) {
            x = uint256(keccak256(abi.encode(x, i)));
        }
        output = abi.encode(x);
        steps = n;
    }

    /// ML: [m:1][k:1][W:m*k int8][x:k int8][b:m int8] → int256[m]
    function _ml(bytes calldata input, uint256 maxSteps) private pure returns (bytes memory output, uint256 steps) {
        if (input.length < 2) revert BadInput();
        uint256 m = uint256(uint8(input[0]));
        uint256 k = uint256(uint8(input[1]));
        if (m == 0 || k == 0) revert BadInput();
        steps = m * k; // per-MAC
        if (steps > maxSteps) revert BudgetExceeded(steps, maxSteps);
        if (input.length != 2 + m * k + k + m) revert BadInput();

        int256[] memory y = new int256[](m);
        uint256 off = 2;
        for (uint256 i = 0; i < m; i++) {
            int256 acc = 0;
            for (uint256 j = 0; j < k; j++) {
                int8 w = int8(uint8(input[off + i * k + j]));
                int8 xv = int8(uint8(input[2 + m * k + j]));
                acc += int256(w) * int256(xv);
            }
            int8 bias = int8(uint8(input[2 + m * k + k + i]));
            y[i] = acc + int256(bias);
        }
        output = abi.encode(y);
    }

    /* ============================ 内部 ============================ */

    function _load(bytes32 dsuId)
        private
        view
        returns (bool ok, uint256 maxSteps, DSU.DSUType t, address impl)
    {
        (DSU.DSUType dsuType,,,, address im, uint256 ms, bool registered) = dsu.records(dsuId);
        return (registered, ms, dsuType, im);
    }

    /// @notice 委派到治理登记的 DSU 实现（staticcall，失败/超预算均 fail-closed）。
    function _callImpl(address impl, bytes calldata input, uint256 maxSteps)
        private
        view
        returns (bytes memory output, uint256 steps)
    {
        (bool ok, bytes memory ret) =
            impl.staticcall(abi.encodeWithSelector(IDSUImpl.execute.selector, input));
        if (!ok) {
            // 冒泡实现自身的原因（便于排障）；无原因时回落到 ImplFailed
            if (ret.length == 0) revert ImplFailed(impl);
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        (output, steps) = abi.decode(ret, (bytes, uint256));
        if (steps > maxSteps) revert BudgetExceeded(steps, maxSteps);
    }
}
