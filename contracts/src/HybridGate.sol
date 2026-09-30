// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { NandGateLib } from "./lib/NandGateLib.sol";

/// @title HybridGate
/// @notice FCT v2 M6 混合模式编排（whitepaper §4.3.3, dev-plan §5.4）。
///         证明链：DSU 执行 → 生成证明 → 逻辑原语验证函数验证证明 → 状态管理器更新容器。
///         - DSU 作为"执行引擎"（高性能计算，步骤数由 DSU.consumeSteps 计量）
///         - 逻辑原语函数作为"验证锚"（NAND 网络链上重放，模块级验证粒度）
///         - 验证通过 → 更新容器状态（interfaceId → value + 逻辑原语锚记）
///         - 验证失败 → 罚没证明者质押（混合模式相对纯 DSU 的安全增益演示）
contract HybridGate {
    using NandGateLib for uint256;

    /* ===================== 常量：逻辑原语验证模块 ===================== */
    uint8 public constant MODULE_ADD4 = 1; // 4-bit 加法器：60 门 / 深度 19
    uint8 public constant MODULE_CMP4 = 2; // 4-bit 比较器：58 门 / 深度 20

    /* ===================== 混合执行请求 ===================== */
    enum Status { REQUESTED, DSU_EXECUTED, VERIFIED, REJECTED }

    struct ExecRequest {
        bytes32 gateId; // 逻辑原语验证函数身份（IdentityRegistry 登记的网络哈希）
        bytes32 dsuId; // DSU 执行引擎身份
        uint8 module; // 逻辑原语模块（MODULE_ADD4 / MODULE_CMP4）
        uint16 inputA; // 执行输入
        uint16 inputB;
        uint16 dsuResult; // DSU 输出
        uint64 dsuSteps; // DSU 消耗步骤
        uint96 stake; // 证明者质押（wei）
        uint32 timestamp;
        address prover; // 质押者（createRequest 的 msg.sender）：成功退款与 DSU 提交权归属
        Status status;
    }

    /* ===================== 状态管理器（容器接口） ===================== */
    struct ContainerSlot {
        uint16 value; // 最新已验证值
        bytes32 gateId; // 逻辑原语验证锚
        uint32 verifiedAt;
    }

    mapping(uint64 => ExecRequest) public requests; // reqId -> 请求
    mapping(bytes32 => ContainerSlot) public container; // interfaceId -> 状态槽
    uint64 public nextReqId;

    // 逻辑原语验证函数登记（门模块 -> 是否启用 + 登记身份）
    mapping(uint8 => bool) public gateModules;
    mapping(uint8 => bytes32) public moduleGateId;

    address public immutable owner;
    uint96 public constant SLASH_BPS = 5000; // 验证失败罚没 50%

    event RequestCreated(uint64 indexed reqId, bytes32 gateId, bytes32 dsuId, uint8 module, uint16 inputA, uint16 inputB, uint96 stake);
    event DsuOutputSubmitted(uint64 indexed reqId, uint16 dsuResult, uint64 dsuSteps);
    event GateVerified(uint64 indexed reqId, bytes32 indexed interfaceId, uint16 value);
    event GateRejected(uint64 indexed reqId, bytes32 indexed interfaceId, uint16 gateValue, uint16 dsuResult);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /* ===================== 逻辑原语模块登记 ===================== */

    /// @notice 登记逻辑原语验证模块（门模块 → 身份锚）。owner 校验模块门数与白皮书/gatelang 一致。
    function registerModule(uint8 module, bytes32 gateId, uint32 expectedGates, uint32 expectedDepth) external onlyOwner {
        require(module == MODULE_ADD4 || module == MODULE_CMP4, "bad module");
        require(gateId != bytes32(0), "gateId 0");
        if (module == MODULE_ADD4) {
            require(expectedGates == 60 && expectedDepth == 19, "add4 spec");
        } else {
            require(expectedGates == 58 && expectedDepth == 20, "cmp4 spec");
        }
        require(!gateModules[module], "dup module");
        gateModules[module] = true;
        moduleGateId[module] = gateId;
    }

    /* ===================== 混合证明链 ===================== */

    /// @notice 阶段 1：创建混合执行请求（证明者质押，委托 DSU 执行）。
    function createRequest(bytes32 gateId, bytes32 dsuId, uint8 module, uint16 inputA, uint16 inputB)
        external payable returns (uint64 reqId)
    {
        require(msg.value > 0, "stake 0");
        require(gateModules[module], "module off");
        require(moduleGateId[module] == gateId, "gate mismatch");
        reqId = nextReqId++;
        requests[reqId] = ExecRequest({
            gateId: gateId,
            dsuId: dsuId,
            module: module,
            inputA: inputA,
            inputB: inputB,
            dsuResult: 0,
            dsuSteps: 0,
            stake: uint96(msg.value),
            timestamp: uint32(block.timestamp),
            prover: msg.sender,
            status: Status.REQUESTED
        });
        emit RequestCreated(reqId, gateId, dsuId, module, inputA, inputB, uint96(msg.value));
    }

    /// @notice 阶段 2：DSU 执行输出 + 步骤（独立于外部 DSU 合约的轻量计量；
    ///         完整流程中步骤数由 DSU.consumeSteps 在运行时记录）。
    function submitDsuOutputV2(uint64 reqId, uint16 result, uint64 steps) external {
        ExecRequest storage r = requests[reqId];
        require(r.status == Status.REQUESTED, "not requested");
        require(r.gateId != bytes32(0), "no req");
        // 仅质押者（DSU/证明者）可提交输出；否则任何人对竞态可伪造错误输出触发罚没
        require(msg.sender == r.prover, "not prover");
        r.dsuResult = result;
        r.dsuSteps = steps;
        r.status = Status.DSU_EXECUTED;
        emit DsuOutputSubmitted(reqId, result, steps);
    }

    /// @notice 阶段 3：逻辑原语验证锚重放 → 通过则更新容器状态，失败则罚没。
    ///         逻辑原语重放为模块级验证（whitepaper §4.3.3：验证粒度是模块级，而非逐逻辑原语）。    
    function verifyByGate(uint64 reqId) external {
        ExecRequest storage r = requests[reqId];
        require(r.status == Status.DSU_EXECUTED, "not executed");

        (uint16 gateValue, uint16 extra) = _moduleEval(r.module, r.inputA, r.inputB);
        bytes32 interfaceId = keccak256(abi.encode(r.module, r.inputA, r.inputB));
        bytes32 gid = r.gateId;
        uint16 dResult = r.dsuResult;
        uint96 stake = r.stake;
        address proverAddr = r.prover;

        if (gateValue == dResult) {
            // 验证通过：状态管理器更新容器
            r.status = Status.VERIFIED;
            r.stake = 0;
            container[interfaceId] = ContainerSlot({
                value: dResult,
                gateId: gid,
                verifiedAt: uint32(block.timestamp)
            });
            // 返还质押给**质押者**（而非任意调用者，否则可被抢跑窃取）
            (bool ok, ) = payable(proverAddr).call{ value: stake }("");
            require(ok, "refund");
            emit GateVerified(reqId, interfaceId, dResult);
        } else {
            // 验证失败：罚没 50% 给触发验证者，余款归 owner
            r.status = Status.REJECTED;
            r.stake = 0;
            uint96 slash = (stake * SLASH_BPS) / 10000;
            uint96 remain = stake - slash;
            (bool ok, ) = msg.sender.call{ value: slash }("");
            require(ok, "slash pay");
            (bool ok2, ) = payable(owner).call{ value: remain }("");
            require(ok2, "remain pay");
            emit GateRejected(reqId, interfaceId, gateValue, dResult);
        }
    }

    /// @notice 逻辑原语模块求值：返回 (主值, 附加)。ADD4: (sum, cout)；CMP4: (eq, gt)。
    function _moduleEval(uint8 module, uint16 a, uint16 b) internal pure returns (uint16, uint16) {
        if (module == MODULE_ADD4) {
            (uint256 sum, uint256 cout) = NandGateLib.add4(a, b);
            return (uint16(sum), uint16(cout));
        } else {
            (uint256 eq, uint256 gt) = NandGateLib.cmp4(a, b);
            return (uint16(gt), uint16(eq));
        }
    }

    /// @notice 公开逻辑原语直查（无状态变更）：对给定输入算逻辑原语模块结果，供链上复核。
    function gateEval(uint8 module, uint16 a, uint16 b) external pure returns (uint16 main, uint16 extra) {
        return _moduleEval(module, a, b);
    }

    /* ===================== 查询 ===================== */

    function requestStatus(uint64 reqId) external view returns (Status) {
        return requests[reqId].status;
    }

    function containerValue(bytes32 interfaceId) external view returns (uint16) {
        return container[interfaceId].value;
    }

    /// @notice 逻辑原语资源说明（与 GateLang 逻辑原语 IR 对照）。
    function gateNotes(uint8 module) external pure returns (uint32 gates_, uint32 depth_) {
        if (module == MODULE_ADD4) return (60, 19);
        return (58, 20);
    }
}