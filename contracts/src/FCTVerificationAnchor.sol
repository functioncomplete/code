// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FCTVerificationAnchor
/// @notice 锚定 FCT / GateLang 形式化验证结果的摘要哈希，供**第三方独立核验**。
///
/// @dev 设计原则：链上只存「哈希 + 计数 + 指针」，完整验证清单放链下（GitHub / IPFS）。
///      链的存储很贵，而形式化验证的完整证明（义务、CNF 规模、反例）体积大且可重建，
///      因此上链的是**可校验的承诺**，不是数据本身。
///
///      第三方核验流程：
///        1. 按 `uri` 取回验证清单 JSON
///        2. 重算 `keccak256(JSON)`，与链上 `manifestHash` 比对
///        3. 用 `gatelang <file>.gat --prove --json` 重跑，确认清单内容可复现
///        4. 比对清单里的 `sourceSha256` 与 .gat 源码
///
///      任何一步不符，即可判定该验证声明不成立。
contract FCTVerificationAnchor {
    /// @notice 一条验证结果记录。
    struct Record {
        bytes32 manifestHash; // keccak256(验证清单 JSON) —— 内容身份锚
        bytes32 sourceHash;   // sha256(.gat 源码)         —— 被验证对象
        bytes32 networkHash;  // 逻辑原语 IR 身份（可 0）   —— 关联链上函数身份
        uint32 obligations;   // 义务总数
        uint32 proven;        // 已证明
        uint32 refuted;       // 被驳倒（反例已给出）
        uint32 unknown;       // 未定（触及资源上限）
        uint64 anchoredAt;    // 区块时间
        address submitter;    // 提交者（不代表可信，可信来自可复现）
        string uri;           // 清单全文位置（https / ipfs）
    }

    Record[] private _records;
    /// @dev manifestHash => index + 1（0 表示未登记）
    mapping(bytes32 => uint256) public indexOf;

    /// @notice 锚定一条验证结果。幂等：同一 manifestHash 只能登记一次。
    /// @dev 无访问控制：任何人都可提交，可信性来自「哈希 + 可复现」，而非提交者身份。
    event Anchored(
        uint256 indexed idx,
        bytes32 indexed manifestHash,
        bytes32 sourceHash,
        bytes32 networkHash,
        uint32 obligations,
        uint32 proven,
        uint32 refuted,
        uint32 unknown,
        string uri
    );

    function anchor(
        bytes32 manifestHash,
        bytes32 sourceHash,
        bytes32 networkHash,
        uint32 obligations,
        uint32 proven,
        uint32 refuted,
        uint32 unknown,
        string calldata uri
    ) external returns (uint256 idx) {
        require(manifestHash != bytes32(0), "anchor: manifest 0");
        require(indexOf[manifestHash] == 0, "anchor: already anchored");
        require(
            obligations == proven + refuted + unknown,
            "anchor: count mismatch"
        );
        require(proven + refuted + unknown > 0, "anchor: empty");

        _records.push(
            Record({
                manifestHash: manifestHash,
                sourceHash: sourceHash,
                networkHash: networkHash,
                obligations: obligations,
                proven: proven,
                refuted: refuted,
                unknown: unknown,
                anchoredAt: uint64(block.timestamp),
                submitter: msg.sender,
                uri: uri
            })
        );
        idx = _records.length - 1;
        indexOf[manifestHash] = idx + 1;

        emit Anchored(
            idx,
            manifestHash,
            sourceHash,
            networkHash,
            obligations,
            proven,
            refuted,
            unknown,
            uri
        );
    }

    /// @notice 已登记的记录数。
    function count() external view returns (uint256) {
        return _records.length;
    }

    /// @notice 按索引读取记录。
    function recordAt(uint256 idx) external view returns (Record memory) {
        return _records[idx];
    }

    /// @notice 便捷查询：该清单哈希是否已登记。
    function isAnchored(bytes32 manifestHash) external view returns (bool) {
        return indexOf[manifestHash] != 0;
    }
}
