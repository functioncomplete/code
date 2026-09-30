// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DSU} from "./DSU.sol";

/// @title IdentityRegistry
/// @notice FCT v2 M4 双原语身份登记（whitepaper v1.4 §8.2, dev-plan §5.3, ARCHITECTURE §4）。
///         逻辑原语函数身份 = NAND 网络哈希（跨链天然唯一）；DSU 身份 = 版本+参数+模型。
///         显式依赖图登记（结构性组合 + 组合版税按引用关系分配）。
contract IdentityRegistry {
    /* ===================== 逻辑原语函数身份 ===================== */
    struct GateIdentity {
        bytes32 networkHash; // NAND 网络完整哈希（跨链身份锚）
        bytes32 ioSpec; // 输入/输出接口哈希
        bytes32 proofHash; // 形式化验证证明哈希（GateLang spec/gateproof，v1.4 §3.4/§6.4）
        uint32 gateCount; // 资源：门数
        uint32 depth; // 资源：逻辑深度
        uint16 royaltyBps; // 版税参数（0..10000）
        address owner;
        bool active;
    }

    /* ===================== DSU 身份 ===================== */
    struct DSUIdentity {
        DSU.DSUType dsuType; // 类别（与 DSU.sol 身份派生同源）
        bytes32 versionHash; // 实现版本
        bytes32 paramsHash; // 参数（固定精度/域参数）
        bytes32 modelCID; // 模型 CID（非 ML 为 0）
        bytes32 proofHash; // 形式化验证证明哈希（spec/gateproof，v1.4 §6.4）
        uint16 royaltyBps;
        address owner;
        bool active;
    }

    /* ===================== 依赖图 ===================== */
    // 双原语统一依赖图：identityHash -> 依赖的 identityHash 列表 + 分成
    struct Dependency {
        bytes32 childId; // 被引用身份
        uint16 shareBps; // 组合版税分成（parent 收入中拨给 child 的部分）
        bool active;
    }

    mapping(bytes32 => GateIdentity) public gates; // networkHash -> 逻辑原语身份
    mapping(bytes32 => DSUIdentity) public dsus; // dsuId -> DSU 身份
    mapping(bytes32 => Dependency[]) public deps; // 依赖方 identityHash -> 依赖列表
    address public immutable owner;
    /// @notice 单一身份的依赖数上限（防 royaltySchedule 无界循环 gas DoS）。
    uint256 public constant MAX_DEPS = 64;

    event GateRegistered(bytes32 indexed networkHash, address indexed owner, uint32 gateCount);
    event DSURegistered(bytes32 indexed dsuId, address indexed owner);
    event DependencyLinked(bytes32 indexed parentId, bytes32 childId, uint16 shareBps);
    event RoyaltyUpdated(bytes32 indexed id, uint16 royaltyBps);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /* ===================== 逻辑原语函数登记 ===================== */

    function registerGate(
        bytes32 networkHash,
        bytes32 ioSpec,
        uint32 gateCount,
        uint32 depth,
        uint16 royaltyBps,
        address fnOwner,
        bytes32 proofHash
    ) external onlyOwner returns (bytes32 id) {
        require(networkHash != bytes32(0), "net 0");
        require(ioSpec != bytes32(0), "io 0");
        require(!gates[networkHash].active, "dup gate");
        require(gateCount > 0 && royaltyBps <= 10000, "bad params");
        // v1.4 §3.4：注册身份必须携带形式化验证证明（区别于"未验证"）
        require(proofHash != bytes32(0), "proof 0");
        gates[networkHash] = GateIdentity({
            networkHash: networkHash,
            ioSpec: ioSpec,
            proofHash: proofHash,
            gateCount: gateCount,
            depth: depth,
            royaltyBps: royaltyBps,
            owner: fnOwner,
            active: true
        });
        emit GateRegistered(networkHash, fnOwner, gateCount);
        return networkHash;
    }

    /* ===================== DSU 身份登记 ===================== */

    function registerDSU(
        DSU.DSUType dsuType,
        bytes32 versionHash,
        bytes32 paramsHash,
        bytes32 modelCID,
        uint16 royaltyBps,
        address dsuOwner,
        bytes32 proofHash
    ) external onlyOwner returns (bytes32 dsuId) {
        require(versionHash != bytes32(0), "vh 0");
        require(royaltyBps <= 10000, "royalty");
        require(proofHash != bytes32(0), "proof 0");
        // 与 DSU.sol 完全同源的派生：类别 + 版本 + 参数 + 模型（换任一维度即新身份）
        dsuId = keccak256(abi.encode(dsuType, versionHash, paramsHash, modelCID));
        require(!dsus[dsuId].active, "dup dsu");
        dsus[dsuId] = DSUIdentity({
            dsuType: dsuType,
            versionHash: versionHash,
            paramsHash: paramsHash,
            modelCID: modelCID,
            proofHash: proofHash,
            royaltyBps: royaltyBps,
            owner: dsuOwner,
            active: true
        });
        emit DSURegistered(dsuId, dsuOwner);
        return dsuId;
    }

    /* ===================== 依赖图（结构性组合） ===================== */

    /// @notice 登记 parent 依赖 child 的引用关系（任意逻辑原语函数 <-> DSU，支持混合依赖）。
    function linkDependency(bytes32 parentId, bytes32 childId, uint16 shareBps) external onlyOwner {
        require(_known(parentId), "unknown parent");
        require(_known(childId), "unknown child");
        require(shareBps <= 10000, "share");
        // 防止自环
        require(parentId != childId, "self dep");
        require(deps[parentId].length < MAX_DEPS, "too many deps");
        deps[parentId].push(Dependency({ childId: childId, shareBps: shareBps, active: true }));
        emit DependencyLinked(parentId, childId, shareBps);
    }

    function disableDependency(bytes32 parentId, uint256 idx) external onlyOwner {
        require(idx < deps[parentId].length, "idx");
        deps[parentId][idx].active = false;
    }

    /// @notice 组合版税：给定 identity 与链式依赖图，返回应结算的 (childId, shareBps) 列表。
    ///         原型：一层依赖直接分配；后续版本按图拓扑传递结算。
    function royaltySchedule(bytes32 id) external view returns (bytes32[] memory childIds, uint16[] memory shares) {
        Dependency[] memory d = deps[id];
        uint256 activeLen = 0;
        for (uint256 i = 0; i < d.length; i++) {
            if (d[i].active) activeLen++;
        }
        childIds = new bytes32[](activeLen);
        shares = new uint16[](activeLen);
        uint256 j = 0;
        for (uint256 i = 0; i < d.length; i++) {
            if (d[i].active) {
                childIds[j] = d[i].childId;
                shares[j] = d[i].shareBps;
                j++;
            }
        }
    }

    /* ===================== 查询 ===================== */

    function checkGate(bytes32 networkHash) external view returns (bool ok, address identityOwner, uint32 gates_, uint16 royaltyBps) {
        GateIdentity memory g = gates[networkHash];
        return (g.active, g.owner, g.gateCount, g.royaltyBps);
    }

    function checkDSU(bytes32 dsuId) external view returns (bool ok, address identityOwner, uint16 royaltyBps) {
        DSUIdentity memory d = dsus[dsuId];
        return (d.active, d.owner, d.royaltyBps);
    }

    /// @notice 形式化验证证明哈希（v1.4 §3.4/§6.4）：调用者可在调用前校验。
    ///         未知身份 revert（区别于"已注册但证明为 0"）。
    function gateProofOf(bytes32 networkHash) external view returns (bytes32) {
        require(gates[networkHash].active, "unknown gate");
        return gates[networkHash].proofHash;
    }

    function dsuProofOf(bytes32 dsuId) external view returns (bytes32) {
        require(dsus[dsuId].active, "unknown dsu");
        return dsus[dsuId].proofHash;
    }

    /// @notice 返回该身份**自身**的版税参数（bps）。组合版税（含直连依赖）的分摊需链下按依赖图结算（原型）。
    function combinedRoyaltyBps(bytes32 id) external view returns (uint16 selfBps) {
        return _selfRoyalty(id);
    }

    function _selfRoyalty(bytes32 id) private view returns (uint16) {
        GateIdentity memory g = gates[id];
        if (g.active) return g.royaltyBps;
        DSUIdentity memory d = dsus[id];
        if (d.active) return d.royaltyBps;
        return 0;
    }

    function _known(bytes32 id) private view returns (bool) {
        return gates[id].active || dsus[id].active;
    }

    /// @notice 跨链身份锚（whitepaper v1.4 §8.2）：逻辑原语网络哈希可直接跨链一致解析；
    ///         DSU 需版本+参数+模型共同锚定。返回身份类型编码 1=gate 2=dsu 0=unknown。
    function identityKind(bytes32 id) external view returns (uint8) {
        if (gates[id].active) return 1;
        if (dsus[id].active) return 2;
        return 0;
    }
}