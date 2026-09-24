// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BinaryMerkle} from "./lib/BinaryMerkle.sol";

/// @title CSC — Compressed State Commitment
/// @notice FCT state component (whitepaper v1.2 §4.2–4.3).
///         - One sparse binary Merkle tree commits ALL container state
///           (current root); leaves are indexed by container ID, not address.
///         - History is the same tree's root snapshotted per epoch (unified
///           history + extended tree per the v1.2 optimization).
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
        uint256 baseRent
    ) {
        require(treeDepth <= 32, "depth>32");
        TREE_DEPTH = treeDepth;
        EPOCH_LEN = epochLen;
        MAX_HOT = maxHot;
        GRACE_EPOCHS = graceEpochs;
        BASE_RENT = baseRent;
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

    /// @notice Public client-side verification (§4.2): proves `dataHash` sits
    ///         at `index` under `currentRoot`. No trust in the caller.
    function verifyInclusion(
        bytes32 dataHash,
        uint256 index,
        bytes32[] calldata proof
    ) public view returns (bool) {
        bytes32[] memory p = proof;
        return BinaryMerkle.validateInclusion(currentRoot, dataHash, index, p, TREE_DEPTH);
    }

    function leafIndex(uint256 containerId) public pure returns (uint256) {
        return containerId & ((1 << 32) - 1);
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
        bytes32 id = bytes32(containerId);
        Container storage c = containers[id];
        require(!c.cold, "container is cold; wake first");
        bytes32 oldLeaf = c.dataHash == bytes32(0) ? bytes32(0) : c.dataHash;

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
        if (c.dataHash == bytes32(0) && !c.resolved) {
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
            for (uint256 e = lastCheckpointEpoch + 1; e <= epoch; e++) {
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
        uint256 cost = rate * epochs;
        require(msg.value >= cost, "insufficient payment");
        uint256 until = rentPaidUntilEpoch[id];
        uint256 nowE = currentEpoch();
        if (until < nowE) until = nowE;
        rentPaidUntilEpoch[id] = until + epochs;
        if (msg.value > cost) {
            payable(msg.sender).transfer(msg.value - cost);
        }
        emit RentPaid(id, epochs, cost);
    }

    /* ===================== Hot/cold ===================== */
    /// @notice Evict a container that has not paid rent beyond GRACE_EPOCHS.
    ///         Its commitment leaf stays in the tree; full data moves to
    ///         off-chain state slices. Anyone may evict (leaf is unchanged).
    function evict(bytes32 containerId) external {
        Container storage c = containers[containerId];
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
        if (nowE > paidUntil) {
            uint256 due = effectiveRentPerEpoch() * (nowE - paidUntil);
            require(msg.value >= due, "rent in arrears");
            rentPaidUntilEpoch[id] = nowE;
            if (msg.value > due) {
                payable(msg.sender).transfer(msg.value - due);
            }
        }

        c.dataHash = dataHash;
        c.cold = false;
        c.updatedAtEpoch = nowE;
        hotCount++;
        emit Woken(id, dataHash, nowE);
    }

    /// @notice Read any historical root snapshot (history Merkle tree).
    function historicalRoot(uint256 epoch) external view returns (bytes32) {
        return historyRoot[epoch];
    }
}