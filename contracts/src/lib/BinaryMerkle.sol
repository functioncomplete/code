// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BinaryMerkle
/// @notice Binary Merkle tree primitives for FCT CSC (Compressed State Commitment).
///         Whitepaper v1.2 §4.2: binary trees have branches 4x shorter than
///         16-ary MPT, cutting verification bandwidth. Leaves are indexed by
///         container ID (not address) per the v1.2 optimization.
/// @dev Pure library: no storage. Hash is keccak256 double-hash (constant 64B
///      input via abi.encodePacked, unambiguous). Production may swap to
///      Poseidon/Blake3 on chains with precompiles; root math is identical.
library BinaryMerkle {
    /// @notice Default tree depth: 2^32 leaves.
    uint256 public constant DEFAULT_DEPTH = 32;

    /// @notice Node hash: keccak256(a || b). abi.encodePacked of two bytes32
    ///         is exactly 64 bytes, so this is naturally length-extension safe.
    function hash2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    /// @notice Empty subtree constant at a given height.
    ///         Z[0] = 0x0, Z[h] = hash2(Z[h-1], Z[h-1]).
    function emptySubtree(uint256 height) internal pure returns (bytes32) {
        bytes32 h = bytes32(0);
        for (uint256 i = 0; i < height; i++) {
            h = hash2(h, h);
        }
        return h;
    }

    /// @notice Build Z array up to `depth` in one pass (for caching in a contract).
    function emptySubtrees(uint256 depth) internal pure returns (bytes32[] memory z) {
        z = new bytes32[](depth + 1);
        z[0] = bytes32(0);
        for (uint256 i = 1; i <= depth; i++) {
            z[i] = hash2(z[i - 1], z[i - 1]);
        }
    }

    /// @notice Compute the root of a leaf array padded with empty leaves
    ///         to the next power of two, then folded up to `depth`.
    function computeRoot(bytes32[] memory leaves, uint256 depth) internal pure returns (bytes32) {
        require(leaves.length <= (1 << depth), "too many leaves");
        if (leaves.length == 0) return emptySubtree(depth);

        uint256 n = 1;
        while (n < leaves.length) n <<= 1;
        bytes32[] memory layer = new bytes32[](n);
        for (uint256 i = 0; i < leaves.length; i++) layer[i] = leaves[i];
        // remaining positions are empty leaves (bytes32(0)) by default

        uint256 height = 0;
        while (n > 1) {
            for (uint256 i = 0; i < n; i += 2) {
                layer[i >> 1] = hash2(layer[i], layer[i + 1]);
            }
            n >>= 1;
            height++;
        }
        // Fold the empty upper region: right sibling at each level is Z[level].
        bytes32 root = layer[0];
        for (uint256 i = height; i < depth; i++) {
            root = hash2(root, emptySubtree(i));
        }
        return root;
    }

    function heightOf(uint256 n) private pure returns (uint256) {
        uint256 h = 0;
        while (n > 1) {
            n >>= 1;
            h++;
        }
        return h;
    }

    /// @notice Verify that `leaf` sits at `index` under `root` in a tree of `depth`.
    function validateInclusion(
        bytes32 root,
        bytes32 leaf,
        uint256 index,
        bytes32[] memory proof,
        uint256 depth
    ) internal pure returns (bool) {
        require(index < (1 << depth), "index overflow");
        require(proof.length == depth, "bad proof length");
        bytes32 h = leaf;
        for (uint256 i = 0; i < depth; i++) {
            if (((index >> i) & 1) == 0) {
                h = hash2(h, proof[i]);
            } else {
                h = hash2(proof[i], h);
            }
        }
        return h == root;
    }

    /// @notice Recompute the root after replacing the leaf at `index` with
    ///         `newLeaf`, given a valid inclusion `proof` for `oldLeaf`.
    ///         Reverts if the proof does not reproduce `root`.
    function updateLeaf(
        bytes32 root,
        bytes32 oldLeaf,
        bytes32 newLeaf,
        uint256 index,
        bytes32[] memory proof,
        uint256 depth
    ) internal pure returns (bytes32 newRoot) {
        require(index < (1 << depth), "index overflow");
        require(proof.length == depth, "bad proof length");

        bytes32 h = oldLeaf;
        bytes32 h2 = newLeaf;
        for (uint256 i = 0; i < depth; i++) {
            bytes32 sibling = proof[i];
            if (((index >> i) & 1) == 0) {
                h = hash2(h, sibling);
                h2 = hash2(h2, sibling);
            } else {
                h = hash2(sibling, h);
                h2 = hash2(sibling, h2);
            }
        }
        require(h == root, "old root mismatch");
        return h2;
    }

    /// @notice Append `newLeaf` to a full tree of `numLeaves` existing leaves.
    ///         Returns the new root and the index of the appended leaf.
    ///         The tree must already be full (all leaves present).
    function append(
        bytes32 root,
        bytes32[] memory proof,
        uint256 numLeaves,
        bytes32 newLeaf,
        uint256 depth
    ) internal pure returns (bytes32 newRoot, uint256 newIndex) {
        newIndex = numLeaves;
        require(newIndex < (1 << depth), "tree full");
        // The append position is exactly numLeaves; its sibling path is the
        // binary representation of numLeaves. Proof must reproduce the root
        // with an empty leaf at the new position.
        require(proof.length == depth, "bad proof length");
        bytes32 h = bytes32(0); // old leaf at append position is empty
        bytes32 h2 = newLeaf;
        for (uint256 i = 0; i < depth; i++) {
            bytes32 sibling = proof[i];
            if (((newIndex >> i) & 1) == 0) {
                h = hash2(h, sibling);
                h2 = hash2(h2, sibling);
            } else {
                h = hash2(sibling, h);
                h2 = hash2(sibling, h2);
            }
        }
        require(h == root, "old root mismatch (append)");
        return (h2, newIndex);
    }

    /// @notice Compress a run of identical sibling hashes in a proof path.
    ///         Returns (compressedProof, counts) where each non-zero count
    ///         tells how many times that sibling repeats. Saves calldata/gas
    ///         on deep sparse trees with repeated empty subtrees.
    function compressProof(
        bytes32[] memory proof
    ) internal pure returns (bytes32[] memory compressed, uint256[] memory counts) {
        bytes32[] memory tmpC = new bytes32[](proof.length);
        uint256[] memory tmpK = new uint256[](proof.length);
        uint256 m = 0;
        for (uint256 i = 0; i < proof.length; i++) {
            if (m > 0 && tmpC[m - 1] == proof[i]) {
                tmpK[m - 1]++;
            } else {
                tmpC[m] = proof[i];
                tmpK[m] = 1;
                m++;
            }
        }
        compressed = new bytes32[](m);
        counts = new uint256[](m);
        for (uint256 i = 0; i < m; i++) {
            compressed[i] = tmpC[i];
            counts[i] = tmpK[i];
        }
    }
}