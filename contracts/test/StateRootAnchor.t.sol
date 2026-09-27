// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StateRootAnchor, ILiquidationAdapter } from "../src/StateRootAnchor.sol";
import { BinaryMerkle } from "../src/lib/BinaryMerkle.sol";

/// @dev 清算适配器桩：只应对**已证明的 leaf/index**行动。
contract MockAdapter is ILiquidationAdapter {
    uint256 public calls;
    uint256 public lastChainId;
    uint64 public lastHeight;
    bytes32 public lastRoot;
    bytes32 public lastLeaf;
    uint256 public lastIndex;

    function onLiquidation(
        uint256 chainId,
        uint64 height,
        bytes32 root,
        bytes32 leaf,
        uint256 index,
        bytes calldata
    ) external {
        calls += 1;
        lastChainId = chainId;
        lastHeight = height;
        lastRoot = root;
        lastLeaf = leaf;
        lastIndex = index;
    }
}

/// @dev 在回调里再次尝试清算（重入应被 nonReentrant 挡下）。
contract ReentrantAdapter is ILiquidationAdapter {
    StateRootAnchor public sa;
    uint256 public chainId;
    bytes32 public leaf;
    uint256 public index;

    constructor(StateRootAnchor _sa) {
        sa = _sa;
    }

    function set(uint256 c, bytes32 l, uint256 i) external {
        chainId = c;
        leaf = l;
        index = i;
    }

    function onLiquidation(uint256, uint64, bytes32, bytes32, uint256, bytes calldata payload) external {
        bytes32[] memory proof = new bytes32[](32);
        sa.liquidate(chainId, address(this), payload, leaf, index, proof);
    }
}

/// @title StateRootAnchor.t — M7 跨链适配器（双向锚定 + 轻客户端 + 清算）
contract StateRootAnchorTest is Test {
    StateRootAnchor internal sa;

    uint256 internal constant PK1 = 0xA11;
    uint256 internal constant PK2 = 0xB22;
    uint256 internal constant PK3 = 0xC33;
    uint256 internal constant PK4 = 0xD44; // 非验证者
    uint256 internal constant CHAIN = 11155111;

    address internal v1;
    address internal v2;
    address internal v3;

    function setUp() public {
        sa = new StateRootAnchor();
        v1 = vm.addr(PK1);
        v2 = vm.addr(PK2);
        v3 = vm.addr(PK3);
        sa.setValidator(v1, 1, true);
        sa.setValidator(v2, 1, true);
        sa.setValidator(v3, 1, true);
    }

    /* ==================== 工具 ==================== */

    function _digest(uint256 chainId, uint64 height, bytes32 root, uint64 epoch) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(sa), chainId, height, root, epoch));
    }

    function _epoch() internal view returns (uint64) {
        return sa.validatorEpoch();
    }

    /// @dev 注意：expectRevert 之后不得再触发任何对 sa 的外部读（会被抢先消费），
    ///      因此 epoch 必须在断言前取好、并经参数传入。
    function _submit(uint256 chainId, uint64 height, bytes32 root) internal {
        uint64 e = _epoch();
        sa.submitRoot(chainId, height, root, e, _threeSigs(_digest(chainId, height, root, e)));
    }

    /// 对给定私钥集合签名，并按恢复地址**升序**拼接为 N×65 字节。
    function _signAll(uint256[] memory pks, bytes32 digest) internal returns (bytes memory) {
        uint256 n = pks.length;
        uint256[] memory order = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            order[i] = i;
        }
        bytes32[] memory r = new bytes32[](n);
        bytes32[] memory s = new bytes32[](n);
        uint8[] memory v = new uint8[](n);
        address[] memory a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            (uint8 vi, bytes32 ri, bytes32 si) = vm.sign(pks[i], digest);
            v[i] = vi;
            r[i] = ri;
            s[i] = si;
            a[i] = vm.addr(pks[i]);
        }
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (a[order[j]] < a[order[i]]) {
                    (order[i], order[j]) = (order[j], order[i]);
                }
            }
        }
        bytes memory out = new bytes(n * 65);
        for (uint256 i = 0; i < n; i++) {
            uint256 k = order[i];
            uint256 off = i * 65;
            for (uint256 b = 0; b < 32; b++) {
                out[off + b] = r[k][b];
                out[off + 32 + b] = s[k][b];
            }
            out[off + 64] = bytes1(v[k]);
        }
        return out;
    }

    function _threeSigs(bytes32 digest) internal returns (bytes memory) {
        uint256[] memory pks = new uint256[](3);
        pks[0] = PK1;
        pks[1] = PK2;
        pks[2] = PK3;
        return _signAll(pks, digest);
    }

    function _twoSigs(bytes32 digest) internal returns (bytes memory) {
        uint256[] memory pks = new uint256[](2);
        pks[0] = PK1;
        pks[1] = PK2;
        return _signAll(pks, digest);
    }

    /// 单叶树的成员证明 = 各高度空子树常量（长度恰好 depth=32）。
    function _emptyProof() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](32);
        for (uint256 i = 0; i < 32; i++) {
            p[i] = BinaryMerkle.emptySubtree(i);
        }
    }

    /// 令 payload 被 leaf 承诺（合约强制 keccak256(payload) == leaf）。
    function _rootOfPayload(bytes memory payload) internal pure returns (bytes32 leaf, bytes32 root) {
        leaf = keccak256(payload);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        root = BinaryMerkle.computeRoot(leaves, 32);
    }

    /* ==================== 入向锚定 ==================== */

    function test_submit_root_with_full_quorum() public {
        bytes32 root = keccak256("remote-root-1");
        uint64 e = _epoch();
        sa.submitRoot(CHAIN, 100, root, e, _threeSigs(_digest(CHAIN, 100, root, e)));
        (bytes32 r, uint64 h,, bool set) = sa.latestRemote(CHAIN);
        assertTrue(set);
        assertEq(r, root);
        assertEq(uint256(h), 100);
    }

    /// 3 验证者各 1 票：2/3 不满足严格 ">2/3"（20000 <= 20001）→ 必须拒绝。
    function test_two_of_three_is_not_quorum() public {
        bytes32 root = keccak256("r2");
        uint64 e = _epoch();
        vm.expectRevert(abi.encodeWithSelector(StateRootAnchor.NoQuorum.selector, uint256(2), uint256(3)));
        sa.submitRoot(CHAIN, 100, root, e, _twoSigs(_digest(CHAIN, 100, root, e)));
    }

    /// 验证者集合代次不符 → 旧配置下的签名失效。
    function test_stale_epoch_rejected() public {
        bytes32 root = keccak256("epoch");
        uint64 old = _epoch();
        sa.setValidator(v3, 2, true); // 变更集合 → epoch +1
        bytes memory sigs = _threeSigs(_digest(CHAIN, 50, root, old));
        vm.expectRevert("stale epoch");
        sa.submitRoot(CHAIN, 50, root, old, sigs);
    }

    function test_stale_height_rejected() public {
        bytes32 root1 = keccak256("a");
        _submit(CHAIN, 100, root1);
        uint64 e = _epoch();
        bytes32 root2 = keccak256("b");
        vm.expectRevert(abi.encodeWithSelector(StateRootAnchor.StaleHeight.selector, uint64(99), uint64(100)));
        sa.submitRoot(CHAIN, 99, root2, e, _threeSigs(_digest(CHAIN, 99, root2, e)));
    }

    function test_height_replay_rejected() public {
        bytes32 root1 = keccak256("c");
        _submit(CHAIN, 100, root1);
        uint64 e = _epoch();
        bytes32 root2 = keccak256("d");
        vm.expectRevert(abi.encodeWithSelector(StateRootAnchor.StaleHeight.selector, uint64(100), uint64(100)));
        sa.submitRoot(CHAIN, 100, root2, e, _threeSigs(_digest(CHAIN, 100, root2, e)));
    }

    function test_non_validator_signature_rejected() public {
        bytes32 root = keccak256("e");
        uint64 e = _epoch();
        bytes32 dg = _digest(CHAIN, 7, root, e);
        uint256[] memory pks = new uint256[](3);
        pks[0] = PK1;
        pks[1] = PK2;
        pks[2] = PK4; // 非验证者
        vm.expectRevert(StateRootAnchor.BadInput.selector);
        sa.submitRoot(CHAIN, 7, root, e, _signAll(pks, dg));
    }

    function test_unsorted_signatures_rejected() public {
        bytes32 root = keccak256("f");
        uint64 e = _epoch();
        bytes32 dg = _digest(CHAIN, 8, root, e);
        uint256[] memory pks = new uint256[](2);
        pks[0] = PK1;
        pks[1] = PK1; // 重复 → 非严格升序
        vm.expectRevert(StateRootAnchor.BadInput.selector);
        sa.submitRoot(CHAIN, 8, root, e, _signAll(pks, dg));
    }

    function test_high_s_signature_rejected() public {
        bytes32 root = keccak256("g");
        uint64 e = _epoch();
        bytes32 dg = _digest(CHAIN, 9, root, e);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK1, dg);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory sigs = abi.encodePacked(r, bytes32(n - uint256(s)), uint8(v == 27 ? 28 : 27));
        vm.expectRevert(StateRootAnchor.BadInput.selector);
        sa.submitRoot(CHAIN, 9, root, e, sigs);
    }

    function test_empty_or_zero_root_rejected() public {
        uint64 e = _epoch();
        vm.expectRevert(StateRootAnchor.BadInput.selector);
        sa.submitRoot(CHAIN, 1, bytes32(0), e, _threeSigs(_digest(CHAIN, 1, bytes32(0), e)));
        vm.expectRevert(StateRootAnchor.BadInput.selector);
        sa.submitRoot(CHAIN, 1, keccak256("x"), e, "");
    }

    function test_validator_removal_changes_quorum() public {
        sa.setValidator(v3, 0, false); // totalStake 3 → 2
        assertEq(sa.totalStake(), 2);
        bytes32 root = keccak256("h");
        uint64 e = _epoch();
        bytes32 dg = _digest(CHAIN, 10, root, e);
        uint256[] memory pks = new uint256[](2);
        pks[0] = PK1;
        pks[1] = PK2;
        sa.submitRoot(CHAIN, 10, root, e, _signAll(pks, dg)); // 2/2 > 2/3 ✅
        (,,, bool set) = sa.latestRemote(CHAIN);
        assertTrue(set);
    }

    function test_zero_stake_active_validator_rejected() public {
        vm.expectRevert("zero-stake active");
        sa.setValidator(address(0x1234), 0, true);
    }

    /* ==================== 轻客户端：包含证明 ==================== */

    function test_verify_inclusion_against_anchored_root() public {
        bytes memory payload = bytes("tx-claim");
        (bytes32 leaf, bytes32 root) = _rootOfPayload(payload);
        _submit(CHAIN, 200, root);

        bytes32[] memory proof = _emptyProof();
        assertTrue(sa.verifyInclusion(CHAIN, leaf, 0, proof), "valid proof");
        assertFalse(sa.verifyInclusion(CHAIN, keccak256("fake"), 0, proof), "tampered leaf");
        assertFalse(sa.verifyInclusion(999, leaf, 0, proof), "unanchored chain");
    }

    /* ==================== 清算 ==================== */

    function test_liquidate_calls_adapter_and_blocks_replay() public {
        MockAdapter ad = new MockAdapter();
        sa.setAdapter(address(ad), true);

        bytes memory payload = bytes("claim-A");
        (bytes32 leaf, bytes32 root) = _rootOfPayload(payload);
        _submit(CHAIN, 300, root);

        bytes32[] memory proof = _emptyProof();
        sa.liquidate(CHAIN, address(ad), payload, leaf, 0, proof);
        assertEq(ad.calls(), 1);
        assertEq(ad.lastChainId(), CHAIN);
        assertEq(uint256(ad.lastHeight()), 300);
        assertEq(ad.lastLeaf(), leaf, "adapter receives proven leaf");
        assertEq(ad.lastIndex(), 0);

        // 同一 (chainId,height,adapter,leaf,index,payload) 重放 → 拒绝
        vm.expectRevert(abi.encodeWithSelector(StateRootAnchor.HeightUsed.selector, uint64(300)));
        sa.liquidate(CHAIN, address(ad), payload, leaf, 0, proof);
    }

    /// High 回归：payload 未被 leaf 承诺 → 拒绝（否则任意证明可配任意 payload）。
    function test_liquidate_payload_not_committed_rejected() public {
        MockAdapter ad = new MockAdapter();
        sa.setAdapter(address(ad), true);

        bytes memory goodPayload = bytes("good");
        (bytes32 leaf, bytes32 root) = _rootOfPayload(goodPayload);
        _submit(CHAIN, 350, root);

        bytes32[] memory proof = _emptyProof();
        vm.expectRevert(StateRootAnchor.BadInput.selector);
        sa.liquidate(CHAIN, address(ad), bytes("attacker-payload"), leaf, 0, proof);
        assertEq(ad.calls(), 0, "must not call adapter");
    }

    function test_liquidate_requires_adapter_and_proof() public {
        MockAdapter ad = new MockAdapter();
        bytes memory payload = bytes("claim2");
        (bytes32 leaf, bytes32 root) = _rootOfPayload(payload);
        _submit(CHAIN, 400, root);
        bytes32[] memory proof = _emptyProof();

        vm.expectRevert(StateRootAnchor.BadInput.selector); // 未登记适配器
        sa.liquidate(CHAIN, address(ad), payload, leaf, 0, proof);

        sa.setAdapter(address(ad), true);
        // 叶与 payload 绑定（通过承诺检查）但不在已锚定的树中 → NotVerified
        bytes memory other = bytes("not-in-tree");
        vm.expectRevert(StateRootAnchor.NotVerified.selector);
        sa.liquidate(CHAIN, address(ad), other, keccak256(other), 0, proof);
    }

    /// 适配器在回调中重入 liquidate → nonReentrant 挡下。
    function test_liquidate_reentrancy_blocked() public {
        ReentrantAdapter rad = new ReentrantAdapter(sa);
        sa.setAdapter(address(rad), true);
        bytes memory payload = bytes("reenter");
        (bytes32 leaf, bytes32 root) = _rootOfPayload(payload);
        _submit(CHAIN, 450, root);
        rad.set(CHAIN, leaf, 0);

        bytes32[] memory proof = _emptyProof();
        vm.expectRevert(StateRootAnchor.Reentrancy.selector);
        sa.liquidate(CHAIN, address(rad), payload, leaf, 0, proof);
    }

    /* ==================== 出向 + 所有权 ==================== */

    function test_export_local_root() public {
        bytes32 root = keccak256("local");
        sa.exportLocalRoot(CHAIN, 500, root);
        (bytes32 r, uint64 h,, bool set) = sa.latestLocal(CHAIN);
        assertTrue(set);
        assertEq(r, root);
        assertEq(uint256(h), 500);

        vm.prank(address(0xBAD));
        vm.expectRevert(StateRootAnchor.NotOwner.selector);
        sa.exportLocalRoot(CHAIN, 501, root);
    }

    function test_two_step_ownership() public {
        address next = address(0xABCD);
        sa.transferOwnership(next);
        assertEq(sa.pendingOwner(), next);
        vm.prank(address(0xBAD));
        vm.expectRevert(StateRootAnchor.NotPending.selector);
        sa.acceptOwnership();
        vm.prank(next);
        sa.acceptOwnership();
        assertEq(sa.owner(), next);
        assertEq(sa.pendingOwner(), address(0));
    }

    function test_quorum_threshold_view() public {
        // totalStake 3 → 3*6667/10000 + 1 = 3
        assertEq(sa.quorumThreshold(), 3);
    }

    function test_validator_epoch_increments() public {
        uint64 e = sa.validatorEpoch();
        sa.setValidator(v1, 5, true);
        assertEq(sa.validatorEpoch(), e + 1);
    }

    /* ==================== 复审建议的补测 ==================== */

    /// 活性：集合变更后旧代次签名被拒，**重签即可提交**（不是死锁）。
    function test_epoch_resign_enables_resubmit() public {
        bytes32 root = keccak256("liveness");
        uint64 e0 = _epoch();
        sa.setValidator(v1, 5, true); // 变更 → epoch+1
        vm.expectRevert("stale epoch");
        sa.submitRoot(CHAIN, 60, root, e0, _threeSigs(_digest(CHAIN, 60, root, e0)));
        uint64 e1 = _epoch();
        sa.submitRoot(CHAIN, 60, root, e1, _threeSigs(_digest(CHAIN, 60, root, e1)));
        (,,, bool set) = sa.latestRemote(CHAIN);
        assertTrue(set, "re-signed submission succeeds");
    }

    /// 无变化的 setValidator 不推进代次（避免自伤活性）。
    function test_noop_set_validator_keeps_epoch() public {
        uint64 e = _epoch();
        sa.setValidator(v1, 1, true); // 与现值完全相同
        assertEq(sa.validatorEpoch(), e, "no-op must not bump epoch");
    }

    /// 签名数上限：> MAX_SIGS 直接拒绝。
    function test_too_many_signatures_rejected() public {
        uint64 e = _epoch();
        bytes memory sigs = new bytes(257 * 65);
        vm.expectRevert(StateRootAnchor.BadInput.selector);
        sa.submitRoot(CHAIN, 70, keccak256("m"), e, sigs);
    }

    /// index 错误 → 证明不通过。
    function test_wrong_index_not_verified() public {
        MockAdapter ad = new MockAdapter();
        sa.setAdapter(address(ad), true);
        bytes memory payload = bytes("idx");
        (bytes32 leaf, bytes32 root) = _rootOfPayload(payload);
        _submit(CHAIN, 480, root);
        bytes32[] memory proof = _emptyProof();
        vm.expectRevert(StateRootAnchor.NotVerified.selector);
        sa.liquidate(CHAIN, address(ad), payload, leaf, 1, proof);
    }

    /// 更高高度的新根锚定后，旧根的证明不再有效（只认最新锚定）。
    function test_old_root_proof_invalid_after_new_anchor() public {
        bytes memory p1 = bytes("v1");
        (bytes32 leaf1, bytes32 root1) = _rootOfPayload(p1);
        _submit(CHAIN, 490, root1);
        bytes32[] memory proof = _emptyProof();
        assertTrue(sa.verifyInclusion(CHAIN, leaf1, 0, proof), "valid at first");

        bytes memory p2 = bytes("v2");
        (bytes32 leaf2, bytes32 root2) = _rootOfPayload(p2);
        _submit(CHAIN, 491, root2);

        assertTrue(sa.verifyInclusion(CHAIN, leaf2, 0, proof), "new root valid");
        assertFalse(sa.verifyInclusion(CHAIN, leaf1, 0, proof), "old root superseded");
    }
}
