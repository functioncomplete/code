// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BinaryMerkle} from "./lib/BinaryMerkle.sol";

/// @notice 容器所有权预言机：与 ContainerNFT.ownerOf(uint256) 同签名。
///         生产环境传入 ContainerNFT 地址；测试可传 mock。
interface IContainerOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title CSC — Compressed State Commitment
/// @notice FCT state component (whitepaper v1.4 §5.2–5.3).
///         - One sparse binary Merkle tree commits ALL container state
///           (current root); leaves are indexed by container ID, not address.
///         - History is the same tree's root snapshotted per epoch (unified
///           history + extended tree per the v1.4 optimization).
///         - Hot/cold separation: hot states stay fully accessible; cold
///           states (rent unpaid / evicted) keep only their commitment leaf
///           on-chain, with full data managed by off-chain state slices.
///         - Cold states remain verifiable by anyone via inclusion proofs.
///         - State rent: paid per epoch, dynamically priced by utilization;
///           unpaid containers are evicted to cold and can be woken up.
contract CSC {
    /* ===================== Parameters ===================== */
    /// @notice Tree depth: supports 2^32 containers.
    uint256 public immutable TREE_DEPTH;
    /// @notice Seconds per epoch.
    uint256 public immutable EPOCH_LEN;
    /// @notice Hot-state capacity cap (for utilization pricing).
    uint256 public immutable MAX_HOT;
    /// @notice Grace epochs before an unpaid container is evictable.
    uint256 public immutable GRACE_EPOCHS;
    /// @notice Base rent per container per epoch (wei).
    uint256 public immutable BASE_RENT;
    /// @notice 容器所有权源头（ContainerNFT）：submitState 授权用 ownerOf(containerId)。
    address public immutable containerNFT;
    /// @notice history 回填的最大 epoch 跨度（防长期停用后一次提交的 gas DoS）。
    uint256 public constant MAX_BACKFILL = 64;

    /* ===================== Core state ===================== */
    /// @notice Current commitment root of the sparse binary tree.
    bytes32 public currentRoot;
    /// @notice Historical root snapshot per epoch (unified history tree).
    mapping(uint256 => bytes32) public historyRoot;
    /// @notice Most recent checkpointed epoch.
    uint256 public lastCheckpointEpoch;
    /// @notice Number of hot containers.
    uint256 public hotCount;

    /* ===================== Containers ===================== */
    struct Container {
        bytes32 dataHash;      // compressed state commitment (leaf value)
        uint256 updatedAtEpoch;
        bool resolved;         // resolution flag (resolution table)
        bool cold;             // evicted to cold storage?
        bool initialized;      // 是否已登记（替代 dataHash==0 哨兵，防未注册 id 误判）
    }

    mapping(bytes32 => Container) public containers;
    mapping(bytes32 => uint256) public rentPaidUntilEpoch;

    /* ===================== Events ===================== */
    event StateSubmitted(
        bytes32 indexed containerId,
        bytes32 dataHash,
        bool resolved,
        uint256 epoch,
        bytes32 root
    );
    event HistoryCheckpoint(uint256 indexed epoch, bytes32 root);
    event RentPaid(bytes32 indexed containerId, uint256 epochs, uint256 amount);
    event Evicted(bytes32 indexed containerId, uint256 epoch);
    event Woken(bytes32 indexed containerId, bytes32 dataHash, uint256 epoch);

    /* ===================== Errors ===================== */
    error NotContainerOwner();
    error BadInclusionProof();
    error RentUnpaid();
    error NotEvictable();
    error NotCold();

    constructor(
        uint256 treeDepth,
        uint256 epochLen,
        uint256 maxHot,
        uint256 graceEpochs,
        uint256 baseRent,
        address containerNFT_
    ) {
        require(treeDepth <= 32, "depth>32");
        require(epochLen > 0, "epochLen=0");
        require(containerNFT_ != address(0), "nft=0");
        TREE_DEPTH = treeDepth;
        EPOCH_LEN = epochLen;
        MAX_HOT = maxHot;
        GRACE_EPOCHS = graceEpochs;
        BASE_RENT = baseRent;
        containerNFT = containerNFT_;
        // genesis: empty tree root
        currentRoot = BinaryMerkle.emptySubtree(treeDepth);
        lastCheckpointEpoch = currentEpoch();
        historyRoot[currentEpoch()] = currentRoot;
    }

    /* ===================== Views ===================== */
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH_LEN;
    }

    /// @notice Utilization in basis points (0..10000).
    function utilizationBps() public view returns (uint256) {
        if (MAX_HOT == 0) return 10000;
        return (hotCount * 10000) / MAX_HOT;
    }

    /// @notice Effective rent per epoch under utilization-based pricing:
    ///         +1% per 100 bps above the 50% utilization target.
    function effectiveRentPerEpoch() public view returns (uint256) {
        uint256 u = utilizationBps();
        if (u <= 5000) return BASE_RENT;
        uint256 excess = (u - 5000) / 100; // every 1% above target
        return BASE_RENT + (BASE_RENT * excess) / 100;
    }

    /// @notice Public client-side verification (§5.2): proves `dataHash` sits
    ///         at `index` under `currentRoot`. No trust in the caller.
    function verifyInclusion(
        bytes32 dataHash,
        uint256 index,
        bytes32[] calldata proof
    ) public view returns (bool) {
        bytes32[] memory p = proof;
        return BinaryMerkle.validateInclusion(currentRoot, dataHash, index, p, TREE_DEPTH);
    }

    function leafIndex(uint256 containerId) public view returns (uint256) {
        return containerId & ((1 << TREE_DEPTH) - 1);
    }

    /* ===================== State submission ===================== */
    /// @notice Submit a new compressed state commitment for a container.
    ///         `proof` must be an inclusion proof for the previous leaf
    ///         (empty leaf for first submission) at index = containerId.
    /// @param containerId Container ID (= container NFT tokenId).
    /// @param dataHash New committed state hash.
    /// @param proof Inclusion proof of the OLD leaf.
    /// @param resolved Resolution flag of this update.
    function submitState(
        uint256 containerId,
        bytes32 dataHash,
        bytes32[] calldata proof,
        bool resolved
    ) external {
        // 授权：仅容器所有者（ContainerNFT.ownerOf）可提交其状态。
        if (IContainerOwner(containerNFT).ownerOf(containerId) != msg.sender) {
            revert NotContainerOwner();
        }
        require(containerId < (1 << TREE_DEPTH), "index overflow");
        bytes32 id = bytes32(containerId);
        Container storage c = containers[id];
        require(!c.cold, "container is cold; wake first");
        bytes32 oldLeaf = c.dataHash;

        uint256 idx = leafIndex(containerId);
        bytes32[] memory p = proof; // calldata -> memory for library
        // validate the proof reproduces currentRoot with the old leaf,
        // then compute the new root.
        if (!BinaryMerkle.validateInclusion(currentRoot, oldLeaf, idx, p, TREE_DEPTH)) {
            revert BadInclusionProof();
        }
        bytes32 newRoot = BinaryMerkle.updateLeaf(
            currentRoot, oldLeaf, dataHash, idx, p, TREE_DEPTH
        );

        uint256 epoch = currentEpoch();
        if (!c.initialized) {
            c.initialized = true;
            hotCount++; // first time seen -> leaves -> hot
            // rent counter starts at this epoch; no retroactive arrears
            if (rentPaidUntilEpoch[id] == 0) rentPaidUntilEpoch[id] = epoch;
        }
        c.dataHash = dataHash;
        c.resolved = resolved;
        c.updatedAtEpoch = epoch;
        c.cold = false;

        currentRoot = newRoot;

        if (epoch > lastCheckpointEpoch) {
            // gap 回填有上限，避免长期停用后一次提交遍历成千上万 epoch（gas DoS）。
            uint256 from = lastCheckpointEpoch + 1;
            uint256 start = epoch > from + MAX_BACKFILL ? epoch - MAX_BACKFILL : from;
            for (uint256 e = start; e <= epoch; e++) {
                historyRoot[e] = currentRoot; // fill gaps with latest root
            }
            lastCheckpointEpoch = epoch;
        } else {
            historyRoot[epoch] = currentRoot; // latest root for this epoch
        }

        emit StateSubmitted(id, dataHash, resolved, epoch, newRoot);
        emit HistoryCheckpoint(epoch, newRoot);
    }

    /* ===================== State rent ===================== */
    /// @notice Pay rent for `epochs` ahead. Uses the current effective rate.
    function payRent(uint256 containerId, uint256 epochs) external payable {
        bytes32 id = bytes32(containerId);
        uint256 rate = effectiveRentPerEpoch();
        uint256 until = rentPaidUntilEpoch[id];
        uint256 nowE = currentEpoch();
        // 欠租不可豁免：until < nowE 时先把欠的 nowE-until 个 epoch 一并计入，
        // 否则拖欠者可用极低成本重置宽限窗口、规避驱逐（与 wakeUp 语义一致）。
        uint256 owed = until < nowE ? nowE - until : 0;
        uint256 cost = rate * (owed + epochs);
        require(msg.value >= cost, "insufficient payment");
        rentPaidUntilEpoch[id] = (until > nowE ? until : nowE) + epochs;
        if (msg.value > cost) {
            (bool ok, ) = payable(msg.sender).call{ value: msg.value - cost }("");
            require(ok, "refund failed");
        }
        emit RentPaid(id, epochs, cost);
    }

    /* ===================== Hot/cold ===================== */
    /// @notice Evict a container that has not paid rent beyond GRACE_EPOCHS.
    ///         Its commitment leaf stays in the tree; full data moves to
    ///         off-chain state slices. Anyone may evict (leaf is unchanged).
    function evict(bytes32 containerId) external {
        Container storage c = containers[containerId];
        require(c.initialized, "not registered");
        require(!c.cold, "already cold");
        uint256 nowE = currentEpoch();
        if (nowE <= rentPaidUntilEpoch[containerId] + GRACE_EPOCHS) {
            revert NotEvictable();
        }
        c.cold = true;
        hotCount--;
        emit Evicted(containerId, nowE);
    }

    /// @notice Wake a cold container: must prove its data commitment is the
    ///         current leaf, and rent must be covered (paid or paid now).
    function wakeUp(
        uint256 containerId,
        bytes32 dataHash,
        bytes32[] calldata proof
    ) external payable {
        bytes32 id = bytes32(containerId);
        Container storage c = containers[id];
        require(c.cold, "not cold");

        if (!verifyInclusion(dataHash, leafIndex(containerId), proof)) {
            revert BadInclusionProof();
        }

        uint256 paidUntil = rentPaidUntilEpoch[id];
        uint256 nowE = currentEpoch();
        uint256 refundAmt = 0;
        if (nowE > paidUntil) {
            uint256 due = effectiveRentPerEpoch() * (nowE - paidUntil);
            require(msg.value >= due, "rent in arrears");
            rentPaidUntilEpoch[id] = nowE;
            refundAmt = msg.value - due;
        } else {
            // 未欠租：不收费，全额退还（此前 msg.value 被吞且 CSC 无提现 → 永久锁死）
            refundAmt = msg.value;
        }

        // CEI：先落状态再退款。否则退款回调可在 c.cold 仍为 true 时重入 wakeUp，
        // 重复执行 hotCount++，破坏 hotCount 不变式并抬高全局租金。
        c.dataHash = dataHash;
        c.cold = false;
        c.updatedAtEpoch = nowE;
        hotCount++;
        emit Woken(id, dataHash, nowE);

        if (refundAmt > 0) {
            (bool ok, ) = payable(msg.sender).call{ value: refundAmt }("");
            require(ok, "refund failed");
        }
    }

    /// @notice Read any historical root snapshot (history Merkle tree).
    function historicalRoot(uint256 epoch) external view returns (bytes32) {
        return historyRoot[epoch];
    }
}