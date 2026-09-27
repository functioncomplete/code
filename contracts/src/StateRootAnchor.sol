// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BinaryMerkle} from "./lib/BinaryMerkle.sol";

/// @title ILiquidationAdapter
/// @notice 清算适配器：在远程状态根 + 包含证明被验证后，由锚定合约回调执行清算/结算。
interface ILiquidationAdapter {
    /// @notice 只应以**已证明的 leaf/index**为准；payload 已由 `keccak256(payload) == leaf` 绑定。
    ///         失败必须 revert（返回值被忽略）。
    function onLiquidation(
        uint256 chainId,
        uint64 height,
        bytes32 root,
        bytes32 leaf,
        uint256 index,
        bytes calldata payload
    ) external;
}

/// @title StateRootAnchor
/// @notice FCT v2 M7 跨链适配器（whitepaper v1.3 §6.3 清算层 / dev-plan §5.5）—— 双向状态根锚定
///         + 轻客户端原型（>2/3 质押签名共识验证 + 二进制 Merkle 包含证明）。
///
///         **入向（远端 → 本地）**：
///         `submitRoot(chainId, height, root, sigs)` —— 对 `keccak256(chainId,height,root)` 收集
///         验证者签名，按**质押加权 > 2/3** 达成最终性；高度**单调递增**且每高度只接受一次（防重放）。
///         **出向（本地 → 远端）**：`exportLocalRoot(chainId, height, root)` 记录我方根供对端读取。
///         **轻客户端**：`verifyInclusion(...)` 用 `BinaryMerkle.validateInclusion` 对**已锚定的远端根**
///         验证成员证明 —— 无需信任中继者的"结论"，只信签名共识 + 证明数学。
///         **清算**：`liquidate(...)` 在包含证明通过后回调 owner 登记的适配器；
///         **强制 `keccak256(payload) == leaf`** —— 适配器只能对"被证明的内容"行动，
///         否则任意合法证明配任意 payload 即可触发清算（跨链适配器最危险的错配）。
///         `verifyInclusion`/`liquidate` 对**畸形证明**（长度≠depth、index 越界）会 revert 而非返回 false。
///
///         信任模型：验证者集合由 owner 维护（质押权重）；>2/3 即"最终性"（§6.2 共识验证电路同构）。
///         **运维约定**：`setValidator` 会推进 `validatorEpoch`，使旧代次下收集的签名全部失效 ——
///         集合变更后须重新收集签名；另 `MAX_SIGS=256` 限制单次提交的签名数，
///         若需 >2/3 的签名者数超过 256（如等权集合 >384 个），需改用聚合签名/位图分页。
///         **远端叶约定**：清算强制 `leaf == keccak256(payload)`，远端树的叶必须按此构造。
///         签名格式：`sigs` = N×65 字节 `[r:32][s:32][v:1]`，**必须按恢复地址升序**（线性去重）；
///         强制 v∈{27,28} 与 EIP-2 low-s；N ≤ 256（防 gas DoS）。
contract StateRootAnchor {
    /* ============================ 常量 ============================ */
    uint256 internal constant BPS = 10000;
    /// @notice > 2/3 最终性阈值（10000×2/3 ≈ 6667，严格大于）
    uint256 internal constant FINALITY_BPS = 6667;
    uint256 internal constant SIG_LEN = 65;
    uint256 internal constant MAX_SIGS = 256;
    uint256 internal constant TREE_DEPTH = 32;
    /// @notice EIP-2 low-s 上界（secp256k1 n/2）
    uint256 internal constant LOW_S = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /* ============================ 验证者集合 ============================ */
    struct Validator {
        uint96 stake;
        bool active;
    }

    mapping(address => Validator) public validators;
    uint256 public totalStake;
    /// @notice 验证者集合代次：每次变更 +1，并纳入签名摘要 → 旧配置下收集的签名随即失效
    uint64 public validatorEpoch;

    /* ============================ 状态根锚定 ============================ */
    struct Anchor {
        bytes32 root;
        uint64 height;
        uint64 at;
        bool set;
    }

    mapping(uint256 => Anchor) public remoteRoots; // chainId → 最新已锚定远端根
    mapping(uint256 => mapping(uint64 => bool)) public heightUsed; // chainId → height → 已用（防重放）
    mapping(uint256 => Anchor) public localRoots; // chainId → 我方导出根

    /// @notice 已执行的清算（防重放）
    mapping(bytes32 => bool) public liquidated;
    mapping(address => bool) public adapters;

    /* ============================ 所有权（两步移交） ============================ */
    address public owner;
    address public pendingOwner;

    /// @notice 清算回调重入锁
    uint256 internal _lock = 1;

    event ValidatorUpdated(address indexed validator, uint96 stake, bool active);
    event RemoteRootAnchored(uint256 indexed chainId, uint64 height, bytes32 root, uint256 signedStake, uint256 totalStake);
    event LocalRootExported(uint256 indexed chainId, uint64 height, bytes32 root);
    event AdapterUpdated(address indexed adapter, bool allowed);
    event Liquidated(uint256 indexed chainId, uint64 height, bytes32 indexed key, address indexed adapter);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotPending();
    error BadInput();
    error NoQuorum(uint256 signedStake, uint256 totalStake);
    error StaleHeight(uint64 height, uint64 current);
    error HeightUsed(uint64 height);
    error Reentrancy();
    error NotVerified();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /* ============================ 两步所有权移交 ============================ */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPending();
        address old = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
    }

    /* ============================ 验证者集合管理 ============================ */
    /// @notice 设置/更新验证者质押（stake=0 等价于移除；active 控制是否计入）。
    function setValidator(address v, uint96 stake, bool active) external onlyOwner {
        require(v != address(0), "zero validator");
        require(!(active && stake == 0), "zero-stake active");
        Validator memory old = validators[v];
        // 无实际变化则不推进代次：否则无谓的 setValidator 会让所有在途签名失效（自伤活性）
        if (old.active == active && old.stake == stake) return;
        if (old.active) totalStake -= old.stake;
        validators[v] = Validator({stake: stake, active: active});
        if (active) totalStake += stake;
        validatorEpoch += 1;
        emit ValidatorUpdated(v, stake, active);
    }

    function setAdapter(address adapter, bool allowed) external onlyOwner {
        adapters[adapter] = allowed;
        emit AdapterUpdated(adapter, allowed);
    }

    /* ============================ 入向：锚定远端根（>2/3 签名） ============================ */
    /// @notice 提交远端状态根。签名消息 = keccak256(chainId,height,root) 经域分离（本链 + 本合约）。
    function submitRoot(uint256 chainId, uint64 height, bytes32 root, uint64 epoch, bytes calldata sigs) external {
        require(epoch == validatorEpoch, "stale epoch");
        if (root == bytes32(0)) revert BadInput();

        Anchor memory prev = remoteRoots[chainId];
        if (prev.set && height <= prev.height) revert StaleHeight(height, prev.height);
        if (heightUsed[chainId][height]) revert HeightUsed(height);

        bytes32 digest = keccak256(abi.encode(block.chainid, address(this), chainId, height, root, epoch));
        uint256 signedStake = _verifyQuorum(digest, sigs);
        // 质押加权 > 2/3（严格）
        if (signedStake * BPS <= totalStake * FINALITY_BPS) revert NoQuorum(signedStake, totalStake);

        heightUsed[chainId][height] = true;
        remoteRoots[chainId] = Anchor({root: root, height: height, at: uint64(block.timestamp), set: true});
        emit RemoteRootAnchored(chainId, height, root, signedStake, totalStake);
    }

    /// @dev 解析 N×65 字节签名，校验 v/low-s/成员/升序去重，返回累计质押。
    function _verifyQuorum(bytes32 digest, bytes calldata sigs) internal view returns (uint256 signedStake) {
        if (sigs.length == 0 || sigs.length % SIG_LEN != 0) revert BadInput();
        uint256 n = sigs.length / SIG_LEN;
        if (n > MAX_SIGS) revert BadInput();

        address last = address(0);
        for (uint256 i = 0; i < n; i++) {
            uint256 off = i * SIG_LEN;
            bytes32 r = bytes32(sigs[off:off + 32]);
            bytes32 s = bytes32(sigs[off + 32:off + 64]);
            uint8 v = uint8(sigs[off + 64]);
            if (v != 27 && v != 28) revert BadInput();
            if (uint256(s) > LOW_S) revert BadInput();
            address signer = ecrecover(digest, v, r, s);
            if (signer == address(0)) revert BadInput();
            // 严格升序：既去重又杜绝同签名反复计数
            if (signer <= last) revert BadInput();
            Validator memory val = validators[signer];
            if (!val.active) revert BadInput();
            last = signer;
            signedStake += val.stake;
        }
    }

    /* ============================ 出向：导出本地根 ============================ */
    /// @notice 记录本链在给定高度的状态根，供对端适配器读取（真正的跨链读取由对端消息证明完成）。
    function exportLocalRoot(uint256 chainId, uint64 height, bytes32 root) external onlyOwner {
        if (root == bytes32(0)) revert BadInput();
        localRoots[chainId] = Anchor({root: root, height: height, at: uint64(block.timestamp), set: true});
        emit LocalRootExported(chainId, height, root);
    }

    /* ============================ 轻客户端：成员证明 ============================ */
    /// @notice 对**最新已锚定的远端根**验证成员证明。
    function verifyInclusion(uint256 chainId, bytes32 leaf, uint256 index, bytes32[] calldata proof)
        public
        view
        returns (bool)
    {
        Anchor memory a = remoteRoots[chainId];
        if (!a.set) return false;
        return BinaryMerkle.validateInclusion(a.root, leaf, index, proof, TREE_DEPTH);
    }

    /* ============================ 清算（适配器回调） ============================ */
    /// @notice 远端状态包含某项声明 → 回调适配器执行清算。同一 (chainId,height,adapter,payload) 只执行一次。
    function liquidate(
        uint256 chainId,
        address adapter,
        bytes calldata payload,
        bytes32 leaf,
        uint256 index,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (!adapters[adapter]) revert BadInput();
        // payload 必须由被证明的 leaf 承诺：否则可用任意合法证明配任意 payload 触发清算
        if (keccak256(payload) != leaf) revert BadInput();
        Anchor memory a = remoteRoots[chainId];
        if (!a.set) revert NotVerified();
        if (!BinaryMerkle.validateInclusion(a.root, leaf, index, proof, TREE_DEPTH)) revert NotVerified();

        // 重放键绑定已证明的 leaf/index（此前仅绑定 payload → 不同 leaf 同 payload 会互相顶掉）
        bytes32 key = keccak256(abi.encode(chainId, a.height, adapter, leaf, index, payload));
        if (liquidated[key]) revert HeightUsed(a.height);
        liquidated[key] = true;

        ILiquidationAdapter(adapter).onLiquidation(chainId, a.height, a.root, leaf, index, payload);
        emit Liquidated(chainId, a.height, key, adapter);
    }

    /* ============================ 查询 ============================ */
    function latestRemote(uint256 chainId) external view returns (bytes32 root, uint64 height, uint64 at, bool set) {
        Anchor memory a = remoteRoots[chainId];
        return (a.root, a.height, a.at, a.set);
    }

    function latestLocal(uint256 chainId) external view returns (bytes32 root, uint64 height, uint64 at, bool set) {
        Anchor memory a = localRoots[chainId];
        return (a.root, a.height, a.at, a.set);
    }

    function quorumThreshold() external view returns (uint256) {
        // 达成最终性所需的最小累计质押
        return (totalStake * FINALITY_BPS) / BPS + 1;
    }
}
