// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PrimitiveSelector
/// @notice FCT v2 M4 原语选择器（whitepaper §4.3.4, dev-plan §5.3）。
///         容器/目标链按场景需求选择：逻辑原语函数 / DSU / 混合模式。
///         决策规则表（白皮书 §4.3.4 场景 → 原语）编码为确定性纯函数。
contract PrimitiveSelector {
    enum Primitive { GATE, DSU, HYBRID }

    struct Requirements {
        bool needFormalProof; // 形式化验证 / 极致安全 / 重入免疫
        bool needCrossChainId; // 跨链身份唯一 / 公共函数库
        bool needHighPerf; // AI 推理 / 密码学 / 批量计算 / 小额高频
        bool needGovernedState; // RWA 合规 / AI Agent / 需受管状态
    }

    struct Recommendation {
        Primitive primitive;
        uint16 confidence; // 0..100（匹配到的规则强度）
        bytes32 reason; // 规则标签哈希（off-chain 解析）
    }

    /// @notice 决策规则表（白皮书 §4.3.4）：
    ///   formal || xchain || !high && !gov        → GATE   （极致安全/跨链身份/公共函数库）
    ///   gov && (formal || perf)                  → HYBRID （RWA 合规、AI Agent、混合场景）
    ///   highPerf && gov                          → HYBRID （逻辑原语身份 + DSU 执行）
    ///   highPerf                                 → DSU    （AI 推理/密码学/批量计算/小额高频）
    ///   default                                  → GATE   （安全优先默认）
    function recommend(Requirements memory r) public pure returns (Recommendation memory rec) {
        bool perf = r.needHighPerf;
        bool gov = r.needGovernedState;
        bool formal = r.needFormalProof;
        bool xchain = r.needCrossChainId;

        if (gov && (formal || perf)) {
            // 混合：逻辑原语验证锚 + DSU 执行（whitepaper §4.3.3）
            rec.primitive = Primitive.HYBRID;
            rec.confidence = 100;
            rec.reason = keccak256("RWA-AI-hybrid");
            return rec;
        }
        if (perf && gov) {
            rec.primitive = Primitive.HYBRID;
            rec.confidence = 90;
            rec.reason = keccak256("agent-identity-plus-dsu");
            return rec;
        }
        if (perf && !formal && !xchain) {
            rec.primitive = Primitive.DSU;
            rec.confidence = 100;
            rec.reason = keccak256("high-perf-dsu");
            return rec;
        }
        if (formal || xchain) {
            // 极致安全、跨链身份、形式化验证、公共函数库 → 逻辑原语函数
            rec.primitive = Primitive.GATE;
            rec.confidence = 100;
            rec.reason = keccak256("formal-crosschain-gate");
            return rec;
        }
        // 默认：逻辑原语安全优先
        rec.primitive = Primitive.GATE;
        rec.confidence = 60;
        rec.reason = keccak256("safe-default-gate");
        return rec;
    }

    /// @notice 白皮书 §4.3.4 决策规则表的规范样本（用于 off-chain 对照测试）。
    function ruleTableSample(uint8 idx) external pure returns (Requirements memory r, Primitive expected) {
        if (idx == 0) {
            // AI 推理 → DSU
            r = Requirements({ needFormalProof: false, needCrossChainId: false, needHighPerf: true, needGovernedState: false });
            return (r, Primitive.DSU);
        }
        if (idx == 1) {
            // 极致安全场景 → 逻辑原语函数
            r = Requirements({ needFormalProof: true, needCrossChainId: false, needHighPerf: false, needGovernedState: false });
            return (r, Primitive.GATE);
        }
        if (idx == 2) {
            // RWA 合规检查 → 混合
            r = Requirements({ needFormalProof: true, needCrossChainId: false, needHighPerf: false, needGovernedState: true });
            return (r, Primitive.HYBRID);
        }
        if (idx == 3) {
            // AI Agent 容器 → 混合
            r = Requirements({ needFormalProof: false, needCrossChainId: false, needHighPerf: true, needGovernedState: true });
            return (r, Primitive.HYBRID);
        }
        if (idx == 4) {
            // 公共函数库 → 逻辑原语函数
            r = Requirements({ needFormalProof: false, needCrossChainId: true, needHighPerf: false, needGovernedState: false });
            return (r, Primitive.GATE);
        }
        if (idx == 5) {
            // 批量计算 → DSU
            r = Requirements({ needFormalProof: false, needCrossChainId: false, needHighPerf: true, needGovernedState: false });
            return (r, Primitive.DSU);
        }
        if (idx == 6) {
            // 密码学运算 → DSU
            r = Requirements({ needFormalProof: false, needCrossChainId: false, needHighPerf: true, needGovernedState: false });
            return (r, Primitive.DSU);
        }
        if (idx == 7) {
            // 跨链身份 → 逻辑原语函数
            r = Requirements({ needFormalProof: false, needCrossChainId: true, needHighPerf: false, needGovernedState: false });
            return (r, Primitive.GATE);
        }
        // 兜底：默认逻辑原语
        r = Requirements({ needFormalProof: false, needCrossChainId: false, needHighPerf: false, needGovernedState: false });
        return (r, Primitive.GATE);
    }
}