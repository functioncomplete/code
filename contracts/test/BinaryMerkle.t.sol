// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BinaryMerkle} from "../src/lib/BinaryMerkle.sol";

/// @notice External wrapper so vm.expectRevert can observe library reverts.
contract BMHarness {
    function update(
        bytes32 root,
        bytes32 oldLeaf,
        bytes32 newLeaf,
        uint256 index,
        bytes32[] memory proof,
        uint256 depth
    ) external pure returns (bytes32) {
        return BinaryMerkle.updateLeaf(root, oldLeaf, newLeaf, index, proof, depth);
    }
}

contract BinaryMerkleTest is Test {
    /* ---------- reference helpers ---------- */

    function refHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    function refEmpty(uint256 h) internal pure returns (bytes32) {
        bytes32 z = bytes32(0);
        for (uint256 i = 0; i < h; i++) z = refHash(z, z);
        return z;
    }

    function refRoot(bytes32[] memory leaves, uint256 depth) internal pure returns (bytes32) {
        uint256 n = 1;
        while (n < leaves.length) n <<= 1;
        bytes32[] memory layer = new bytes32[](n);
        for (uint256 i = 0; i < leaves.length; i++) layer[i] = leaves[i];
        uint256 h = 0;
        while (n > 1) {
            for (uint256 i = 0; i < n / 2; i++) {
                layer[i] = refHash(layer[2 * i], layer[2 * i + 1]);
            }
            n /= 2;
            h++;
        }
        bytes32 root = layer[0];
        for (uint256 i = h; i < depth; i++) root = refHash(root, refEmpty(i));
        return root;
    }

    function makeLeaves(uint256 n) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) l[i] = bytes32(uint256(keccak256(abi.encode(i))));
    }

    /// Build padded levels of a leaf array (right side empty). treeHeight = height
    /// of the fully-populated subtree (levels[treeHeight].length == 1).
    function fullLevels(
        bytes32[] memory leaves,
        uint256 depth
    ) internal pure returns (bytes32[][] memory levels, uint256 treeHeight) {
        uint256 n = 1;
        while (n < leaves.length) n <<= 1;
        levels = new bytes32[][](depth + 1);
        levels[0] = new bytes32[](n);
        for (uint256 i = 0; i < leaves.length; i++) levels[0][i] = leaves[i];
        treeHeight = 0;
        while (n > 1) {
            bytes32[] memory lv = new bytes32[](n / 2);
            for (uint256 i = 0; i < n / 2; i++) {
                lv[i] = refHash(levels[treeHeight][2 * i], levels[treeHeight][2 * i + 1]);
            }
            levels[treeHeight + 1] = lv;
            n /= 2;
            treeHeight++;
        }
    }

    /// Inclusion proof for `index` at depth in a padded tree; positions beyond
    /// the populated subtree use the empty-subtree constant Z[l].
    function computeProof(
        bytes32[][] memory levels,
        uint256 index,
        uint256 depth
    ) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](depth);
        for (uint256 l = 0; l < depth; l++) {
            uint256 sib = (index >> l) ^ 1; // sibling node index at this level
            if (sib < levels[l].length) {
                proof[l] = levels[l][sib];
            } else {
                proof[l] = refEmpty(l);
            }
        }
    }

    /* ---------- tests ---------- */

    function testEmptySubtree() public pure {
        assertEq(BinaryMerkle.emptySubtree(0), bytes32(0));
        assertEq(BinaryMerkle.emptySubtree(1), refHash(bytes32(0), bytes32(0)));
        assertEq(BinaryMerkle.emptySubtree(2), refHash(refHash(bytes32(0), bytes32(0)), refHash(bytes32(0), bytes32(0))));
    }

    function testComputeRootSingle() public pure {
        bytes32[] memory one = makeLeaves(1);
        assertEq(BinaryMerkle.computeRoot(one, 3), refRoot(one, 3));
    }

    function testComputeRootFuzz(uint8 count, uint8 depth) public pure {
        uint256 c = uint256(count) % 16 + 1;
        uint256 d = uint256(depth) % 10 + 1;
        vm.assume(c <= (1 << d));
        bytes32[] memory leaves = makeLeaves(c);
        assertEq(BinaryMerkle.computeRoot(leaves, d), refRoot(leaves, d));
    }

    function testValidateInclusionFullTree() public {
        bytes32[] memory leaves = makeLeaves(8);
        (bytes32[][] memory levels, ) = fullLevels(leaves, 3);
        bytes32 root = BinaryMerkle.computeRoot(leaves, 3);
        for (uint256 i = 0; i < 8; i++) {
            assertTrue(
                BinaryMerkle.validateInclusion(root, leaves[i], i, computeProof(levels, i, 3), 3),
                "valid proof must pass"
            );
        }
    }

    function testValidateInclusionEmptyTree() public {
        uint256 depth = 3;
        bytes32 root = BinaryMerkle.emptySubtree(depth);
        for (uint256 i = 0; i < 8; i++) {
            bytes32[] memory proof = computeProof(new bytes32[][](depth + 1), i, depth);
            assertTrue(BinaryMerkle.validateInclusion(root, bytes32(0), i, proof, depth));
        }
    }

    function testValidateInclusionRejectsTampered() public {
        bytes32[] memory leaves = makeLeaves(8);
        (bytes32[][] memory levels, ) = fullLevels(leaves, 3);
        bytes32 root = BinaryMerkle.computeRoot(leaves, 3);

        bytes32[] memory proof = computeProof(levels, 3, 3);
        // wrong leaf
        assertFalse(BinaryMerkle.validateInclusion(root, bytes32(uint256(0xdead)), 3, proof, 3));
        // wrong index
        assertFalse(BinaryMerkle.validateInclusion(root, leaves[3], 4, proof, 3));
        // tampered sibling
        bytes32[] memory bad = proof;
        bad[1] = bytes32(uint256(0xbeef));
        assertFalse(BinaryMerkle.validateInclusion(root, leaves[3], 3, bad, 3));
        // wrong root
        assertFalse(
            BinaryMerkle.validateInclusion(
                BinaryMerkle.emptySubtree(3), leaves[3], 3, proof, 3
            )
        );
    }

    function testUpdateLeaf() public {
        bytes32[] memory leaves = makeLeaves(8);
        (bytes32[][] memory levels, ) = fullLevels(leaves, 3);
        bytes32 root = BinaryMerkle.computeRoot(leaves, 3);

        bytes32 newLeaf = bytes32(uint256(0x1337));
        bytes32 newRoot = BinaryMerkle.updateLeaf(root, leaves[5], newLeaf, 5, computeProof(levels, 5, 3), 3);
        assertFalse(newRoot == root);

        // reference: tree with leaf 5 = newLeaf
        bytes32[] memory ref = new bytes32[](8);
        for (uint256 i = 0; i < 8; i++) ref[i] = leaves[i];
        ref[5] = newLeaf;
        assertEq(newRoot, refRoot(ref, 3));

        // old proof must reproduce old root; new tree validates new leaf
        assertTrue(
            BinaryMerkle.validateInclusion(root, leaves[5], 5, computeProof(levels, 5, 3), 3)
        );
        (bytes32[][] memory newLevels, ) = fullLevels(ref, 3);
        assertTrue(
            BinaryMerkle.validateInclusion(newRoot, newLeaf, 5, computeProof(newLevels, 5, 3), 3)
        );
    }

    function testUpdateLeafFuzz(uint8 index) public {
        uint256 i = uint256(index) % 8;
        bytes32[] memory leaves = makeLeaves(8);
        (bytes32[][] memory levels, ) = fullLevels(leaves, 3);
        bytes32 root = BinaryMerkle.computeRoot(leaves, 3);
        bytes32 newLeaf = keccak256(abi.encodePacked("new", i));
        bytes32 newRoot = BinaryMerkle.updateLeaf(root, leaves[i], newLeaf, i, computeProof(levels, i, 3), 3);
        bytes32[] memory ref = leaves;
        ref[i] = newLeaf;
        assertEq(newRoot, refRoot(ref, 3));
    }

    function testUpdateLeafRejectsBadProof() public {
        bytes32[] memory leaves = makeLeaves(8);
        (bytes32[][] memory levels, ) = fullLevels(leaves, 3);
        bytes32 root = BinaryMerkle.computeRoot(leaves, 3);
        bytes32[] memory proof = computeProof(levels, 2, 3);
        proof[0] = proof[0] ^ bytes32(uint256(1)); // corrupt first sibling
        BMHarness h = new BMHarness();
        vm.expectRevert();
        h.update(root, leaves[2], bytes32(uint256(1)), 2, proof, 3);
    }

    function testAppend() public {
        bytes32[] memory three = makeLeaves(3); // [a,b,c]
        bytes32[] memory full = makeLeaves(4);
        bytes32 root = BinaryMerkle.computeRoot(three, 3);
        (bytes32[][] memory levels, ) = fullLevels(three, 3);

        (bytes32 newRoot, uint256 idx) = BinaryMerkle.append(root, computeProof(levels, 3, 3), 3, full[3], 3);
        assertEq(idx, 3);
        assertEq(newRoot, refRoot(full, 3));

        // appended leaf inclusion valid under new root
        (bytes32[][] memory fullLevelsArr, ) = fullLevels(full, 3);
        assertTrue(
            BinaryMerkle.validateInclusion(newRoot, full[3], 3, computeProof(fullLevelsArr, 3, 3), 3)
        );
    }

    function testCompressProof() public {
        bytes32[] memory proof = new bytes32[](5);
        proof[0] = bytes32(uint256(1));
        proof[1] = bytes32(uint256(1));
        proof[2] = bytes32(uint256(2));
        proof[3] = bytes32(uint256(2));
        proof[4] = bytes32(uint256(2));
        (bytes32[] memory c, uint256[] memory k) = BinaryMerkle.compressProof(proof);
        assertEq(c.length, 2);
        assertEq(k.length, 2);
        assertEq(c[0], bytes32(uint256(1)));
        assertEq(c[1], bytes32(uint256(2)));
        assertEq(k[0], 2);
        assertEq(k[1], 3);
    }
}