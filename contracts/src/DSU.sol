// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DSU
/// @notice FCT v2 M4 领域专用执行单元（DSU）登记与管理（whitepaper §3.2, dev-plan §5.2）。
///         DSU 身份 = 类别 + 版本哈希 + 参数哈希 + 模型 CID。
///         只读执行、终止性由最大步数保证、成本按类别计量。
contract DSU {
    /* ===================== 类别 ===================== */
    enum DSUType { HASH, SIGN, ARITH, STATE_MACHINE, ML }

    struct DSURecord {
        DSUType dsuType; // 类别：哈希/签名/算术/状态机/ML 推理
        bytes32 versionHash; // 实现版本哈希（语义标识）
        bytes32 paramsHash; // 参数哈希（固定精度、域参数、量化位数）
        bytes32 modelCID; // ML 模型内容标识（非 ML 为 0）
        address impl; // 可选实现地址（预编译 / 运行时）
        uint256 maxSteps; // 终止性保证：单次执行步数上界
        bool registered;
    }

    mapping(bytes32 => DSURecord) public records; // dsuId -> 记录
    address public immutable owner;

    event DSURegistered(bytes32 indexed dsuId, DSUType indexed dsuType, bytes32 versionHash);
    event DSUImplUpdated(bytes32 indexed dsuId, address impl);
    event StepsConsumed(bytes32 indexed dsuId, address indexed caller, uint256 steps);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /* ===================== 登记 ===================== */

    function registerDSU(
        DSUType dsuType,
        bytes32 versionHash,
        bytes32 paramsHash,
        bytes32 modelCID,
        address impl,
        uint256 maxSteps
    ) external onlyOwner returns (bytes32 dsuId) {
        require(versionHash != bytes32(0), "vhash 0");
        require(maxSteps > 0, "steps 0");
        // 身份 = 类别 + 版本 + 参数 + 模型（四个维度全部纳入，换任一维度即新身份）
        dsuId = keccak256(abi.encode(dsuType, versionHash, paramsHash, modelCID));
        require(!records[dsuId].registered, "dup");
        records[dsuId] = DSURecord({
            dsuType: dsuType,
            versionHash: versionHash,
            paramsHash: paramsHash,
            modelCID: modelCID,
            impl: impl,
            maxSteps: maxSteps,
            registered: true
        });
        emit DSURegistered(dsuId, dsuType, versionHash);
    }

    function updateImpl(bytes32 dsuId, address impl) external onlyOwner {
        require(records[dsuId].registered, "unknown");
        records[dsuId].impl = impl;
        emit DSUImplUpdated(dsuId, impl);
    }

    /* ===================== 成本与终止性 ===================== */

    /// @notice 断言一次执行在预算内（原型：步数计量；实际运行时按类别换算 gas/周期）。
    function consumeSteps(bytes32 dsuId, uint256 steps) external returns (bool ok) {
        require(records[dsuId].registered, "unknown");
        require(steps <= records[dsuId].maxSteps, "budget exceeded");
        emit StepsConsumed(dsuId, msg.sender, steps);
        return true;
    }

    function getBudget(bytes32 dsuId) external view returns (uint256 maxSteps) {
        require(records[dsuId].registered, "unknown");
        return records[dsuId].maxSteps;
    }

    function classify(bytes32 dsuId) external view returns (DSUType) {
        require(records[dsuId].registered, "unknown");
        return records[dsuId].dsuType;
    }

    /// @notice 类别对应的典型成本模型（白皮书 §3.2：类别相关，而非统一操作码）。
    function costModelNote(DSUType t) external pure returns (bytes32 note) {
        if (t == DSUType.HASH) return keccak256("per-hash + per-byte");
        if (t == DSUType.SIGN) return keccak256("per-signature + batch discount");
        if (t == DSUType.ARITH) return keccak256("per-field-op");
        if (t == DSUType.STATE_MACHINE) return keccak256("per-step");
        return keccak256("per-layer FLOPs (quantized)");
    }
}