// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CSC, IContainerOwner} from "../src/CSC.sol";

/// @notice 测试用所有权预言机：任何 id 都归 owner 所有。
contract MockOwnerRegistry is IContainerOwner {
    address public immutable owner;

    constructor(address o) {
        owner = o;
    }

    function ownerOf(uint256) external view override returns (address) {
        return owner;
    }
}

contract CSCTest is Test {
    CSC public csc;

    uint256 constant DEPTH = 8;
    uint256 constant EPOCH = 1; // 1-second epochs (test via vm.warp)
    uint256 constant MAX_HOT = 10;
    uint256 constant GRACE = 2;
    uint256 constant BASE_RENT = 0.01 ether;

    address alice = makeAddr("alice");

    /// Local mirror of the sparse commitment tree (off-chain state slices).
    bytes32[256] internal mirror;
    bytes32[][] internal levels;

    function setUp() public {
        vm.deal(alice, 100 ether);
        // time must be set BEFORE construction so the genesis epoch matches
        // and the history-checkpoint fill loop never runs over a huge gap
        vm.warp(1_000_000); // epoch 1_000_000
        csc = new CSC(DEPTH, EPOCH, MAX_HOT, GRACE, BASE_RENT, address(new MockOwnerRegistry(alice)));
        rebuildLevels();
    }

    /* ---------- helpers ---------- */

    function node(bytes32 l, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(l, r));
    }

    function emptyAt(uint256 h) internal pure returns (bytes32) {
        bytes32 z = bytes32(0);
        for (uint256 i = 0; i < h; i++) z = node(z, z);
        return z;
    }

    /// Rebuild all levels from the mirror (sparse tree, empty slots = 0).
    function rebuildLevels() internal {
        uint256 max = 1 << DEPTH;
        levels = new bytes32[][](DEPTH + 1);
        levels[0] = new bytes32[](max);
        for (uint256 i = 0; i < max; i++) levels[0][i] = mirror[i];
        for (uint256 l = 0; l < DEPTH; l++) {
            uint256 len = levels[l].length;
            levels[l + 1] = new bytes32[](len / 2);
            for (uint256 i = 0; i < len / 2; i++) {
                levels[l + 1][i] = node(levels[l][2 * i], levels[l][2 * i + 1]);
            }
        }
    }

    /// Inclusion proof for `index` at DEPTH against the current mirror.
    function proofFor(uint256 index) internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](DEPTH);
        for (uint256 l = 0; l < DEPTH; l++) {
            uint256 sib = (index >> l) ^ 1;
            proof[l] = sib < levels[l].length ? levels[l][sib] : emptyAt(l);
        }
    }

    /// Inclusion proof for an empty leaf (first submission).
    function emptyProof() internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](DEPTH);
        for (uint256 l = 0; l < DEPTH; l++) proof[l] = emptyAt(l);
    }

    /// Store a commitment in the local slice mirror and rebuild the proof levels.
    function patchLeaf(uint256 index, bytes32 data) internal {
        mirror[index] = data;
        rebuildLevels();
    }

    /// Submit as alice and keep the local mirror in sync.
    /// Proof is for the OLD leaf (0) at `id`; siblings come from the current
    /// mirror so populated positions on the path are handled.
    function submit(uint256 id, bytes32 data) internal {
        vm.prank(alice);
        csc.submitState(id, data, proofFor(id), false);
        patchLeaf(id, data);
    }

    /* ---------- submissions ---------- */

    function testFirstSubmitCreatesHotState() public {
        bytes32 data = keccak256("state-v1");
        submit(1, data);

        (bytes32 dataHash, uint256 updatedAt, bool resolved, bool cold, ) = csc.containers(bytes32(uint256(1)));
        assertEq(dataHash, data);
        assertFalse(cold);
        assertFalse(resolved);
        assertEq(csc.hotCount(), 1);
        assertEq(csc.currentRoot(), levels[DEPTH][0]);
        assertEq(csc.historyRoot(csc.currentEpoch()), csc.currentRoot());
        assertGt(updatedAt, 0);
    }

    function testSubmitByNonOwnerReverts() public {
        // 授权回归：非容器所有者不得提交状态（Critical 修复）。
        address bob = makeAddr("bob");
        vm.prank(bob);
        vm.expectRevert(CSC.NotContainerOwner.selector);
        csc.submitState(1, keccak256("x"), emptyProof(), false);
    }

    function testUpdateState() public {
        bytes32 d1 = keccak256("v1");
        bytes32 d2 = keccak256("v2");
        submit(1, d1);

        vm.prank(alice);
        csc.submitState(1, d2, proofFor(1), true);
        patchLeaf(1, d2);

        (bytes32 dataHash, , bool resolved, bool cold, ) = csc.containers(bytes32(uint256(1)));
        assertEq(dataHash, d2);
        assertTrue(resolved);
        assertFalse(cold);
        assertEq(csc.hotCount(), 1, "still single hot container");
        assertEq(csc.currentRoot(), levels[DEPTH][0]);
    }

    function testSubmitRejectsBadProof() public {
        submit(1, keccak256("v1"));

        bytes32[] memory bad = proofFor(1);
        bad[0] = bytes32(uint256(0xbeef));
        vm.prank(alice);
        vm.expectRevert(CSC.BadInclusionProof.selector);
        csc.submitState(2, keccak256("x"), bad, false);
        assertEq(csc.hotCount(), 1, "no new state on bad proof");
    }

    function testSparseIndicesDoNotDisturb() public {
        submit(5, keccak256("a"));
        submit(200, keccak256("b"));

        assertEq(csc.hotCount(), 2);
        assertEq(csc.currentRoot(), levels[DEPTH][0]);
        // both remain independently verifiable
        assertTrue(csc.verifyInclusion(keccak256("a"), 5, proofFor(5)));
        assertTrue(csc.verifyInclusion(keccak256("b"), 200, proofFor(200)));
        // id=5 unchanged
        (bytes32 dataHash, , , , ) = csc.containers(bytes32(uint256(5)));
        assertEq(dataHash, keccak256("a"));
    }

    /* ---------- history snapshots ---------- */

    function testHistorySnapshotsPerEpoch() public {
        submit(1, keccak256("e1"));
        bytes32 r1 = csc.currentRoot();

        vm.warp(block.timestamp + 3); // new epoch
        submit(2, keccak256("e2"));
        bytes32 r2 = csc.currentRoot();

        assertEq(csc.historyRoot(block.timestamp - 3), r1);
        assertEq(csc.historyRoot(block.timestamp), r2);
        assertTrue(r1 != r2);
    }

    /* ---------- state rent ---------- */

    function testPayRent() public {
        submit(1, keccak256("s"));
        uint256 epoch = csc.currentEpoch();

        vm.prank(alice);
        csc.payRent{value: 0.05 ether}(1, 5); // BASE_RENT * 5
        assertEq(csc.rentPaidUntilEpoch(bytes32(uint256(1))), epoch + 5);
    }

    function testWakeUpNotInArrearsRefunds() public {
        // 未欠租时 wakeUp 不应吞掉 msg.value（此前会被永久锁死）
        bytes32 data = keccak256("cold-state");
        submit(1, data);
        vm.warp(block.timestamp + (GRACE + 3));
        csc.evict(bytes32(uint256(1))); // 未付费 → 可驱逐
        vm.prank(alice);
        csc.payRent{value: BASE_RENT * 2000}(1, 1000); // 冷却期预付（payRent 无 cold 检查）
        uint256 before = alice.balance;
        vm.prank(alice);
        csc.wakeUp{value: 1 ether}(1, data, proofFor(1)); // 未欠租 → 全额退还
        assertEq(alice.balance, before, "no charge when not in arrears");
        (, , , bool cold, ) = csc.containers(bytes32(uint256(1)));
        assertFalse(cold);
    }

    function testPayRentChargesArrears() public {
        submit(1, keccak256("s"));
        uint256 start = csc.currentEpoch();
        vm.warp(block.timestamp + 5); // 拖欠 5 个 epoch
        uint256 rate = csc.effectiveRentPerEpoch();
        // 只付 1 个 epoch 不足以覆盖欠租 5 + 新增 1
        vm.prank(alice);
        vm.expectRevert("insufficient payment");
        csc.payRent{value: rate}(1, 1);
        // 付清欠租 5 + 新增 1
        vm.prank(alice);
        csc.payRent{value: rate * 6}(1, 1);
        assertEq(csc.rentPaidUntilEpoch(bytes32(uint256(1))), start + 6);
    }

    function testPayRentRefundsOverpayment() public {
        submit(1, keccak256("s"));
        uint256 before = alice.balance;
        vm.prank(alice);
        csc.payRent{value: 0.09 ether}(1, 5); // pays 0.05, refunds 0.04
        assertEq(alice.balance, before - 0.05 ether); // net cost = rent only
    }

    function testPayRentInsufficientReverts() public {
        submit(1, keccak256("s"));
        vm.prank(alice);
        vm.expectRevert("insufficient payment");
        csc.payRent{value: 0.03 ether}(1, 5);
    }

    function testUtilizationPricing() public {
        // Fill 6 containers -> 60% utilization -> +10% over base
        for (uint256 i = 0; i < 6; i++) {
            submit(i, keccak256(abi.encode(i)));
        }
        assertEq(csc.utilizationBps(), 6000);
        assertEq(csc.effectiveRentPerEpoch(), BASE_RENT + (BASE_RENT * 10) / 100);

        uint256 paying = csc.effectiveRentPerEpoch() * 2;
        vm.prank(alice);
        csc.payRent{value: paying}(0, 2);
        assertEq(csc.rentPaidUntilEpoch(bytes32(0)), csc.currentEpoch() + 2);
    }

    function testRentBelowTargetIsBase() public {
        submit(1, keccak256("s"));
        assertEq(csc.utilizationBps(), 1000);
        assertEq(csc.effectiveRentPerEpoch(), BASE_RENT);
    }

    /* ---------- evict / wake ---------- */

    function testEvictToCold() public {
        submit(1, keccak256("s"));
        uint256 epoch = csc.currentEpoch();
        vm.prank(alice);
        csc.payRent{value: BASE_RENT * 1}(1, 1); // covered until epoch+1

        vm.warp(block.timestamp + (GRACE + 2)); // now > epoch+1+2 -> evictable
        csc.evict(bytes32(uint256(1)));
        (, , , bool cold, ) = csc.containers(bytes32(uint256(1)));
        assertTrue(cold);
        assertEq(csc.hotCount(), 0);
    }

    function testEvictWithinGraceReverts() public {
        submit(1, keccak256("s"));
        uint256 epoch = csc.currentEpoch();
        vm.prank(alice);
        csc.payRent{value: BASE_RENT * 2}(1, 2); // covered until epoch+2

        vm.warp(block.timestamp + 3); // now = epoch+3 <= epoch+2+grace
        vm.expectRevert(CSC.NotEvictable.selector);
        csc.evict(bytes32(uint256(1)));
    }

    function testWakeUpRestores() public {
        bytes32 data = keccak256("cold-state");
        submit(1, data);
        vm.warp(block.timestamp + (GRACE + 3));
        csc.evict(bytes32(uint256(1)));

        // wake with the commitment still in the tree (leaf unchanged after evict)
        vm.prank(alice);
        csc.wakeUp{value: BASE_RENT * 100}(1, data, proofFor(1));

        (, , , bool cold, ) = csc.containers(bytes32(uint256(1)));
        assertFalse(cold);
        assertEq(csc.hotCount(), 1);
        (bytes32 dataHash2, , , , ) = csc.containers(bytes32(uint256(1)));
        assertEq(dataHash2, data);
    }

    function testWakeUpRejectsWrongData() public {
        bytes32 data = keccak256("cold-state");
        submit(1, data);
        vm.warp(block.timestamp + (GRACE + 3));
        csc.evict(bytes32(uint256(1)));

        vm.prank(alice);
        vm.expectRevert(CSC.BadInclusionProof.selector);
        csc.wakeUp{value: 0}(1, keccak256("forged"), proofFor(1));
    }

    function testWakeUpArrears() public {
        bytes32 data = keccak256("cold-state");
        submit(1, data);
        vm.warp(block.timestamp + (GRACE + 10));
        csc.evict(bytes32(uint256(1)));

        // no rent paid and no value sent -> arrears revert
        vm.prank(alice);
        vm.expectRevert("rent in arrears");
        csc.wakeUp(1, data, proofFor(1));

        // with enough value -> succeeds; no more arrears for rented span
        vm.prank(alice);
        csc.wakeUp{value: BASE_RENT * 100}(1, data, proofFor(1));
        (, , , bool cold, ) = csc.containers(bytes32(uint256(1)));
        assertFalse(cold);
    }

    function testCannotSubmitWhenCold() public {
        bytes32 data = keccak256("cold-state");
        submit(1, data);
        vm.warp(block.timestamp + (GRACE + 3));
        csc.evict(bytes32(uint256(1)));

        vm.prank(alice);
        vm.expectRevert("container is cold; wake first");
        csc.submitState(1, keccak256("new"), proofFor(1), false);
    }

    /* ---------- client-side verification ---------- */

    function testClientVerification() public {
        bytes32 data = keccak256("public-state");
        submit(7, data);

        assertTrue(csc.verifyInclusion(data, 7, proofFor(7)));
        assertFalse(csc.verifyInclusion(keccak256("else"), 7, proofFor(7)));
        assertFalse(csc.verifyInclusion(data, 8, proofFor(7)));

        // reader without alice's key can verify after cold too
        vm.warp(block.timestamp + (GRACE + 3));
        csc.evict(bytes32(uint256(7)));
        assertTrue(csc.verifyInclusion(data, 7, proofFor(7)));
    }
}