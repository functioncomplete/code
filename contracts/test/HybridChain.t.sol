// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DSU } from "../src/DSU.sol";
import { DSURuntime } from "../src/DSURuntime.sol";
import { GateEngine } from "../src/GateEngine.sol";
import { HybridChain } from "../src/HybridChain.sol";
import { NB } from "./helpers/NetBuilder.sol";

/// @title HybridChain.t — 门级引擎 × DSU 的零信任合流（whitepaper v1.3 §4.3.3）
contract HybridChainTest is Test {
    DSU internal dsu;
    DSURuntime internal rt;
    GateEngine internal ge;
    HybridChain internal hc;

    bytes32 internal fnId; // ADD4 门级网表
    bytes32 internal toggleId; // 时序：1 位翻转单元
    bytes32 internal arithId; // ARITH mod 16
    bytes32 internal mlId; // ML（用于验证 decode fail-closed）

    uint256 internal constant MASK4 = 0x0F;

    function setUp() public {
        dsu = new DSU();
        rt = new DSURuntime(dsu);
        ge = new GateEngine();
        hc = new HybridChain(ge, rt);

        // 门级锚：与 gatelang adder4 同构的 60 门 NAND 网表
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = NB.buildAdd4();
        fnId = ge.registerFunction(8, 0, prog, outs, nexts, depth);

        // 时序锚：out = state，next = !state（signal0=输入, signal1=latch）
        (uint32[] memory tp, uint16[] memory to, uint16[] memory tn, uint32 td) = NB.buildToggle();
        toggleId = ge.registerFunction(1, 1, tp, to, tn, td);

        arithId = dsu.registerDSU(DSU.DSUType.ARITH, keccak256("arith-v1"), keccak256("mod16"), bytes32(0), address(0), 1000);
        mlId = dsu.registerDSU(DSU.DSUType.ML, keccak256("ml-v1"), keccak256("q"), bytes32(0), address(0), 1000);
    }

    function _arithInput(uint8 op, uint256 a, uint256 b, uint256 m) internal pure returns (bytes memory) {
        return abi.encodePacked(op, bytes32(a), bytes32(b), bytes32(m));
    }

    function _addInput(uint8 a, uint8 b) internal pure returns (bytes memory) {
        return _arithInput(0, a, b, 16);
    }

    /* ==================== 一致 → VERIFIED ==================== */

    function test_agree_updates_slot() public {
        uint8 a = 5;
        uint8 b = 4;
        uint256 inBits = uint256(a) | (uint256(b) << 4);
        (uint64 reqId, HybridChain.Status st, uint256 dr, uint256 gr) =
            hc.execute(fnId, arithId, inBits, 0, _addInput(a, b), MASK4);

        assertEq(uint256(st), uint256(HybridChain.Status.VERIFIED), "status");
        assertEq(dr, 9, "dsu result");
        assertEq(gr, 9, "gate result");
        assertEq(reqId, 0, "first req");

        HybridChain.Slot memory s = hc.slotOf(fnId, arithId, inBits, 0, _addInput(a, b), MASK4);
        assertTrue(s.set, "slot set");
        assertEq(s.value, 9, "slot value");
        assertEq(s.fnId, fnId, "slot fn");
    }

    /* ==================== 不一致 → REJECTED，不写状态 ==================== */

    function test_disagree_records_rejected_without_state() public {
        uint8 a = 5;
        uint8 b = 4;
        uint256 inBits = uint256(a) | (uint256(b) << 4);
        // 模 7：(5+4)%7 = 2 ≠ 门级和 9
        (, HybridChain.Status st, uint256 dr, uint256 gr) =
            hc.execute(fnId, arithId, inBits, 0, _arithInput(0, a, b, 7), MASK4);

        assertEq(uint256(st), uint256(HybridChain.Status.REJECTED), "status");
        assertEq(dr, 2, "dsu");
        assertEq(gr, 9, "gate");
        assertFalse(hc.slotOf(fnId, arithId, inBits, 0, _arithInput(0, a, b, 7), MASK4).set, "no slot on reject");
    }

    /* ==================== 只读预演 ==================== */

    function test_preview_does_not_write() public {
        uint8 a = 15;
        uint8 b = 1;
        uint256 inBits = uint256(a) | (uint256(b) << 4);
        (bool agree, uint256 dr, uint256 gr, uint256 steps) =
            hc.preview(fnId, arithId, inBits, 0, _addInput(a, b), MASK4);
        assertTrue(agree, "agree");
        assertEq(dr, 0, "(15+1)%16");
        assertEq(gr, 0, "gate sum wraps");
        assertEq(steps, 1, "per-field-op");
        assertFalse(hc.slotOf(fnId, arithId, inBits, 0, _addInput(a, b), MASK4).set, "preview writes nothing");
    }

    /* ==================== F5 回归：键必须绑定完整语句 ==================== */

    /// 攻击者用 mask=0（任意值都"相等"）不能覆盖合法槽 —— 键含 mask 故落在别的键上。
    function test_forged_mask_zero_cannot_clobber_honest_slot() public {
        uint8 a = 5;
        uint8 b = 4;
        uint256 inBits = uint256(a) | (uint256(b) << 4);
        bytes memory honest = _addInput(a, b);
        hc.execute(fnId, arithId, inBits, 0, honest, MASK4);
        HybridChain.Slot memory good = hc.slotOf(fnId, arithId, inBits, 0, honest, MASK4);
        assertEq(good.value, 9, "honest 9");

        // 攻击：mask=0 + 退化输入（mod 1 → 恒 0）→ 0 == 0
        (, HybridChain.Status st,,) = hc.execute(fnId, arithId, inBits, 0, _arithInput(0, 0, 0, 1), 0);
        assertEq(uint256(st), uint256(HybridChain.Status.VERIFIED), "degenerate statement self-consistent");

        // 合法槽未被污染
        HybridChain.Slot memory afterGood = hc.slotOf(fnId, arithId, inBits, 0, honest, MASK4);
        assertEq(afterGood.value, 9, "honest slot intact");
        assertEq(afterGood.at, good.at, "honest slot timestamp intact");
    }

    /// 键绑定 dsuInput 内容：同一 (fnId,dsuId,inBits,mask) 下不同 dsuInput → 不同槽。
    function test_slot_key_binds_dsu_input() public {
        uint8 a = 5;
        uint8 b = 4;
        uint256 inBits = uint256(a) | (uint256(b) << 4);
        bytes memory honest = _addInput(a, b); // (5+4)%16 = 9
        bytes memory alt = _arithInput(0, 9, 0, 16); // 也是 9，但语句不同

        hc.execute(fnId, arithId, inBits, 0, honest, MASK4);
        hc.execute(fnId, arithId, inBits, 0, alt, MASK4);

        bytes32 k1 = hc.interfaceIdOf(fnId, arithId, inBits, 0, honest, MASK4);
        bytes32 k2 = hc.interfaceIdOf(fnId, arithId, inBits, 0, alt, MASK4);
        assertTrue(k1 != k2, "different statements -> different keys");
        assertTrue(hc.slotOf(fnId, arithId, inBits, 0, honest, MASK4).set);
        assertTrue(hc.slotOf(fnId, arithId, inBits, 0, alt, MASK4).set);
    }

    /// 单调：同一语句重复执行不改写首个已验证槽（时间戳不变）。
    function test_monotonic_first_verified_wins() public {
        uint8 a = 2;
        uint8 b = 3;
        uint256 inBits = uint256(a) | (uint256(b) << 4);
        bytes memory inp = _addInput(a, b);
        hc.execute(fnId, arithId, inBits, 0, inp, MASK4);
        uint48 firstAt = hc.slotOf(fnId, arithId, inBits, 0, inp, MASK4).at;
        vm.warp(block.timestamp + 1000);
        hc.execute(fnId, arithId, inBits, 0, inp, MASK4);
        assertEq(uint256(hc.slotOf(fnId, arithId, inBits, 0, inp, MASK4).at), uint256(firstAt), "timestamp frozen");
    }

    /// 时序网表：stateBits 参与求值与键 → 不同状态是不同语句。
    function test_stateful_slot_depends_on_state() public {
        // toggle 网表：out = state（mask 取 bit0）。DSU 用 (state, 0, mod16) 对齐。
        bytes memory inS0 = _arithInput(0, 0, 0, 16);
        bytes memory inS1 = _arithInput(0, 1, 0, 16);

        (,, uint256 dr0, uint256 gr0) = hc.execute(toggleId, arithId, 0, 0, inS0, 1);
        assertEq(dr0, 0, "dsu state0");
        assertEq(gr0, 0, "gate state0");

        (,, uint256 dr1, uint256 gr1) = hc.execute(toggleId, arithId, 0, 1, inS1, 1);
        assertEq(dr1, 1, "dsu state1");
        assertEq(gr1, 1, "gate state1");

        assertTrue(hc.slotOf(toggleId, arithId, 0, 0, inS0, 1).set, "state0 slot");
        assertTrue(hc.slotOf(toggleId, arithId, 0, 1, inS1, 1).set, "state1 slot");
    }

    /* ==================== 穷举：4 位域上 DSU 与门级网表恒等 ==================== */

    function testFuzz_add4_chain_always_agrees(uint8 a, uint8 b) public {
        a &= 0x0F;
        b &= 0x0F;
        uint256 inBits = uint256(a) | (uint256(b) << 4);
        (bool agree, uint256 dr, uint256 gr,) = hc.preview(fnId, arithId, inBits, 0, _addInput(a, b), MASK4);
        assertTrue(agree, "dsu vs gate must agree");
        assertEq(dr, gr, "equal results");
        assertEq(dr, (uint256(a) + uint256(b)) % 16, "value");
    }

    /* ==================== fail-closed ==================== */

    function test_budget_revert_propagates() public {
        bytes32 tiny = dsu.registerDSU(DSU.DSUType.HASH, keccak256("tiny"), keccak256("p"), bytes32(0), address(0), 1);
        bytes memory big = new bytes(64); // steps = 1 + 2 = 3 > 1
        vm.expectRevert(abi.encodeWithSelector(DSURuntime.BudgetExceeded.selector, uint256(3), uint256(1)));
        hc.execute(fnId, tiny, 0, 0, abi.encodePacked(uint8(0), big), MASK4);
    }

    function test_unknown_gate_reverts() public {
        vm.expectRevert("unknown fn");
        hc.execute(bytes32(uint256(0xBAD)), arithId, 0, 0, _addInput(1, 2), MASK4);
    }

    function test_unknown_dsu_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(DSURuntime.UnknownDSU.selector, bytes32(uint256(0xBAD))));
        hc.execute(fnId, bytes32(uint256(0xBAD)), 0, 0, _addInput(1, 2), MASK4);
    }

    /// ML 返回 int256[]（多字）→ 被显式拒绝（fail-closed），不会把 ABI 偏移量当成结果写入槽。
    function test_ml_multiword_output_rejected() public {
        bytes memory mlInput = abi.encodePacked(uint8(1), uint8(1), int8(1), int8(2), int8(0));
        vm.expectRevert("non-word output");
        hc.execute(fnId, mlId, 0, 0, mlInput, MASK4);
        vm.expectRevert("non-word output");
        hc.preview(fnId, mlId, 0, 0, mlInput, MASK4);
    }

    /* ==================== 复审建议的补测 ==================== */

    /// stateBits 独立绑定钥匙：固定 inBits/dsuInput，仅 stateBits 变 → 键不同。
    function test_state_bits_key_binding_isolation() public {
        bytes memory inp = _arithInput(0, 0, 0, 16);
        bytes32 k0 = hc.interfaceIdOf(toggleId, arithId, 0, 0, inp, 1);
        bytes32 k1 = hc.interfaceIdOf(toggleId, arithId, 0, 1, inp, 1);
        assertTrue(k0 != k1, "stateBits must be part of the key");
    }

    /// mask 独立绑定钥匙。
    function test_mask_key_binding() public {
        bytes memory inp = _addInput(1, 2);
        bytes32 k1 = hc.interfaceIdOf(fnId, arithId, 3, 0, inp, 1);
        bytes32 k2 = hc.interfaceIdOf(fnId, arithId, 3, 0, inp, 2);
        assertTrue(k1 != k2, "mask must be part of the key");
    }

    /// 单字输出的其它类别（SIGN）不应触发 "non-word output"；不匹配则 REJECTED。
    function test_sign_word_output_not_rejected() public {
        bytes32 signId = dsu.registerDSU(DSU.DSUType.SIGN, keccak256("sg"), keccak256("p"), bytes32(0), address(0), 1000);
        (uint8 v, bytes32 r, bytes32 sc) = vm.sign(0xA11CE, keccak256("m"));
        bytes memory sig = abi.encodePacked(keccak256("m"), v, r, sc);
        (, HybridChain.Status st,,) = hc.execute(fnId, signId, 3, 0, sig, MASK4);
        assertEq(uint256(st), uint256(HybridChain.Status.REJECTED), "no revert, just reject");
    }

    /// 未设置的键返回零值槽。
    function test_slot_unset_returns_zero() public {
        HybridChain.Slot memory s = hc.slotOf(fnId, arithId, 123, 0, _addInput(0, 1), MASK4);
        assertFalse(s.set);
        assertEq(s.value, 0);
        assertEq(s.at, 0);
        assertEq(s.fnId, bytes32(0));
    }

    /// reqId 单调递增。
    function test_nextreq_monotonic() public {
        (uint64 a,,,) = hc.execute(fnId, arithId, 3, 0, _addInput(1, 2), MASK4);
        (uint64 b,,,) = hc.execute(fnId, arithId, 3, 0, _addInput(1, 2), MASK4);
        assertEq(b, a + 1, "monotonic");
    }

    /// preview 同样受预算约束（fail-closed）。
    function test_preview_budget_revert() public {
        bytes32 tiny = dsu.registerDSU(DSU.DSUType.HASH, keccak256("t2"), keccak256("p"), bytes32(0), address(0), 1);
        bytes memory big = new bytes(64);
        vm.expectRevert(abi.encodeWithSelector(DSURuntime.BudgetExceeded.selector, uint256(3), uint256(1)));
        hc.preview(fnId, tiny, 0, 0, abi.encodePacked(uint8(0), big), MASK4);
    }
}
