// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { GateEngine } from "../src/GateEngine.sol";
import { NandGateLib } from "../src/lib/NandGateLib.sol";
import { NB } from "./helpers/NetBuilder.sol";

/// @title GateEngine.t — 门级引擎（whitepaper v1.3 §4.1，M5 交付）
contract GateEngineTest is Test {
    GateEngine internal ge;

    function setUp() public {
        ge = new GateEngine();
    }

    /* ==================== 网表构造 ==================== */

    /// 4 位加法器：输入 a0..a3, b0..b3（signal 0..7），输出 (sum 4 位, cout)。
    /// 逐位全加器链 → 60 门 / 深度 19（与 gatelang adder4、NandGateLib.add4 一致）。
    function _buildAdd4()
        internal
        pure
        returns (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth)
    {
        NB.Ctx memory c = NB.init(8, 0);
        uint16 carry = NB.const0(c);
        uint16[4] memory sums;
        for (uint256 i = 0; i < 4; i++) {
            (uint16 s, uint16 co) = NB.fullAdd(c, i, 4 + i, carry);
            sums[i] = s;
            carry = co;
        }
        outs = new uint16[](5);
        outs[0] = sums[0];
        outs[1] = sums[1];
        outs[2] = sums[2];
        outs[3] = sums[3];
        outs[4] = carry; // cout 为第 5 位输出
        nexts = new uint16[](0);
        prog = NB.trim(c);
        depth = NB.maxDepth(c);
    }

    /// 4 位比较器（gate 语义 eq = !(d3|d2|d1|d0)，gt = 最高不同位定大小）。
    /// 输出 (eq, gt)。深度由构造器重算。
    function _buildCmp4()
        internal
        pure
        returns (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth)
    {
        NB.Ctx memory c = NB.init(8, 0);
        uint16 d0 = NB.xor_(c, 0, 4);
        uint16 d1 = NB.xor_(c, 1, 5);
        uint16 d2 = NB.xor_(c, 2, 6);
        uint16 d3 = NB.xor_(c, 3, 7);
        // eq = !(d3|d2|d1|d0)
        uint16 any = NB.or_(c, NB.or_(c, d3, d2), NB.or_(c, d1, d0));
        uint16 eq = NB.not_(c, any);
        // gt = d3&a3 | !d3 & (d2&a2 | !d2 & (d1&a1 | !d1 & (d0&a0)))
        uint16 t0 = NB.and_(c, d0, 0);
        uint16 t1 = NB.or_(c, NB.and_(c, d1, 1), NB.and_(c, NB.not_(c, d1), t0));
        uint16 t2 = NB.or_(c, NB.and_(c, d2, 2), NB.and_(c, NB.not_(c, d2), t1));
        uint16 gt = NB.or_(c, NB.and_(c, d3, 3), NB.and_(c, NB.not_(c, d3), t2));
        outs = new uint16[](2);
        outs[0] = eq;
        outs[1] = gt;
        nexts = new uint16[](0);
        prog = NB.trim(c);
        depth = NB.maxDepth(c);
    }

    /* ==================== 登记与元数据 ==================== */

    function test_add4_register_metadata_matches_gatelang() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        assertEq(prog.length, 61, "add4 program len (60 NAND + 1 const)");
        assertEq(depth, 19, "add4 depth");
        bytes32 id = ge.registerFunction(8, 0, prog, outs, nexts, depth);
        (
            uint32 signalCount,
            uint16 inputCount,
            uint16 latchCount,
            uint16 outCount,
            uint32 gateCount,
            uint32 nandCount,
            uint32 fnDepth,
            bytes32 ioSpec,
            address registrant,
            bool active
        ) = ge.fns(id);
        ioSpec;
        registrant;
        assertTrue(active);
        assertEq(uint256(nandCount), 60, "nand count matches gatelang metadata.gates");
        assertEq(uint256(gateCount), 61, "program length includes 1 const gate");
        assertEq(uint256(fnDepth), 19);
        assertEq(uint256(inputCount), 8);
        assertEq(uint256(latchCount), 0);
        assertEq(uint256(outCount), 5);
        assertEq(uint256(signalCount), 69); // 8 输入 + 61 门
        assertEq(uint256(ge.fnCount()), 1);
    }

    function test_id_is_content_derived_and_duplicate_reverts() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        bytes32 expected = ge.computeId(8, 0, prog, outs, nexts);
        bytes32 id = ge.registerFunction(8, 0, prog, outs, nexts, depth);
        assertEq(id, expected);
        // 同一程序重复登记必须 revert（id 由内容派生）
        vm.expectRevert("dup function");
        ge.registerFunction(8, 0, prog, outs, nexts, depth);
    }

    /* ==================== 等价性：链上引擎 == 门级原语库 ==================== */

    function testFuzz_add4_engine_matches_NandGateLib(uint8 a, uint8 b) public {
        a &= 0x0F;
        b &= 0x0F;
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        bytes32 id = ge.registerFunction(8, 0, prog, outs, nexts, depth);

        // 输入位域：a 占 bit0..3，b 占 bit4..7
        uint256 inBits = uint256(a) | (uint256(b) << 4);
        (uint256 outBits,) = ge.eval(id, inBits, 0);

        uint256 sum = outBits & 0x0F; // 低 4 位
        uint256 cout = (outBits >> 4) & 1; // 第 5 位

        (uint256 libSum, uint256 libCout) = NandGateLib.add4(a, b);
        assertEq(sum, libSum, "sum mismatch");
        assertEq(cout, libCout, "cout mismatch");
    }

    function test_add4_explicit_spot_checks() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        bytes32 id = ge.registerFunction(8, 0, prog, outs, nexts, depth);
        uint8[4] memory xs = [0, 15, 5, 7];
        uint8[4] memory ys = [0, 15, 4, 8];
        for (uint256 k = 0; k < 4; k++) {
            uint256 inBits = uint256(xs[k]) | (uint256(ys[k]) << 4);
            (uint256 outBits,) = ge.eval(id, inBits, 0);
            (uint256 libSum, uint256 libCout) = NandGateLib.add4(xs[k], ys[k]);
            assertEq(outBits & 0x0F, libSum);
            assertEq((outBits >> 4) & 1, libCout);
        }
    }

    function testFuzz_cmp4_engine_semantics(uint8 a, uint8 b) public {
        a &= 0x0F;
        b &= 0x0F;
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildCmp4();
        bytes32 id = ge.registerFunction(8, 0, prog, outs, nexts, depth);

        uint256 inBits = uint256(a) | (uint256(b) << 4);
        (uint256 outBits,) = ge.eval(id, inBits, 0);

        uint256 eq = outBits & 1; // bit0 = eq
        uint256 gt = (outBits >> 1) & 1; // bit1 = gt

        assertEq(eq, a == b ? 1 : 0, "eq");
        assertEq(gt, a > b ? 1 : 0, "gt");
    }

    /* ==================== 时序：LATCH 状态 ==================== */

    /// 1 位翻转单元：state' = NOT(state)（演示 LATCH 状态读入与下一状态输出）。
    function _buildToggle()
        internal
        pure
        returns (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth)
    {
        NB.Ctx memory c = NB.init(1, 1); // signal0 = 输入，signal1 = latch 当前值
        uint16 nxt = NB.not_(c, 1); // signal2 = !state
        outs = new uint16[](1);
        outs[0] = 1; // 输出当前状态
        nexts = new uint16[](1);
        nexts[0] = nxt; // 下一状态 = !state
        prog = NB.trim(c);
        depth = NB.maxDepth(c);
    }

    function test_latch_state_transition() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildToggle();
        bytes32 id = ge.registerFunction(1, 1, prog, outs, nexts, depth);
        (, uint16 inputCount2, uint16 latchCount2, , , , , , , bool active2) = ge.fns(id);
        inputCount2;
        assertTrue(active2);
        assertEq(uint256(latchCount2), 1);

        // 输入不参与逻辑；state=0 → 输出 0、下一状态 1
        (uint256 out0, uint256 next0) = ge.eval(id, 0, 0);
        assertEq(out0, 0, "out(state0)");
        assertEq(next0, 1, "next(state0)");

        // state=1 → 输出 1、下一状态 0
        (uint256 out1, uint256 next1) = ge.eval(id, 0, 1);
        assertEq(out1, 1, "out(state1)");
        assertEq(next1, 0, "next(state1)");

        // 连续推进：0 → 1 → 0 → 1（确定性状态机）
        uint256 st = 0;
        for (uint256 i = 0; i < 4; i++) {
            (, uint256 nx) = ge.eval(id, 0, st);
            st = nx;
        }
        assertEq(st, 0, "4 toggles return to start");
    }

    /* ==================== 拒绝路径（fail-closed） ==================== */

    function test_reject_non_topological() public {
        // 门 l 指向自身下标 → 必须拒绝（结构上无环的保证）
        uint32[] memory prog = new uint32[](1);
        prog[0] = uint32(uint32(0) << 12 | 0); // signal0 = NAND(0,0)，但 signal0 是输入 → self 引用非法
        uint16[] memory outs = new uint16[](1);
        outs[0] = 0;
        uint16[] memory nexts = new uint16[](0);
        // inputCount=0 → 该门 self 下标为 0，l=0 不满足 l < 0
        vm.expectRevert("topo order");
        ge.registerFunction(0, 0, prog, outs, nexts, 0);
    }

    function test_reject_bad_opcode() public {
        uint32[] memory prog = new uint32[](1);
        prog[0] = uint32(9) << 24; // 非法操作码
        uint16[] memory outs = new uint16[](1);
        outs[0] = 1;
        uint16[] memory nexts = new uint16[](0);
        vm.expectRevert("bad opcode");
        ge.registerFunction(1, 0, prog, outs, nexts, 0);
    }

    function test_reject_depth_mismatch() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        vm.expectRevert("depth mismatch");
        ge.registerFunction(8, 0, prog, outs, nexts, depth + 1);
    }

    function test_reject_out_of_bounds_output() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        outs[0] = 60000; // 越界
        vm.expectRevert("out oob");
        ge.registerFunction(8, 0, prog, outs, nexts, depth);
    }

    function test_reject_empty_and_oversized() public {
        uint32[] memory empty = new uint32[](0);
        uint16[] memory outs = new uint16[](1);
        outs[0] = 0;
        uint16[] memory nexts = new uint16[](0);
        vm.expectRevert("empty program");
        ge.registerFunction(1, 0, empty, outs, nexts, 0);

        // 信号上限：inputCount 257 超位域上限（用非空程序，确保先命中 inputs>256）
        uint32[] memory one = new uint32[](1);
        one[0] = uint32(uint32(0) << 12 | 0);
        vm.expectRevert("inputs > 256");
        ge.registerFunction(257, 0, one, outs, nexts, 0);
    }

    function test_reject_next_len_mismatch() public {
        uint32[] memory prog = new uint32[](1);
        prog[0] = uint32(uint32(0) << 12 | 0);
        uint16[] memory outs = new uint16[](1);
        outs[0] = 0;
        uint16[] memory nexts = new uint16[](1); // latchCount=0 但给了 1 个
        vm.expectRevert("next len");
        ge.registerFunction(1, 0, prog, outs, nexts, 0);
    }

    /* ==================== 停用 ==================== */

    function test_disable_only_owner() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        bytes32 id = ge.registerFunction(8, 0, prog, outs, nexts, depth);
        vm.prank(address(0xBAD));
        vm.expectRevert("not owner");
        ge.disableFunction(id);
        ge.disableFunction(id);
        assertFalse(ge.isActive(id));
        vm.expectRevert("unknown fn");
        ge.eval(id, 0, 0);
    }

    /// 登记为 owner 门控：非 owner 无法登记（否则可抢跑登记 + 永久退役）。
    function test_register_only_owner() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        vm.prank(address(0xBEEF));
        vm.expectRevert("not owner");
        ge.registerFunction(8, 0, prog, outs, nexts, depth);
    }

    function test_eval_unknown_reverts() public {
        vm.expectRevert("unknown fn");
        ge.eval(bytes32(uint256(1)), 0, 0);
    }

    /// 退役必须**永久**：否则原作者退役有缺陷的函数后，任何人可重新登记把它复活。
    function test_disable_is_permanent() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        bytes32 id = ge.registerFunction(8, 0, prog, outs, nexts, depth);
        ge.disableFunction(id);
        assertTrue(ge.retired(id), "marked retired");
        vm.expectRevert("retired");
        ge.registerFunction(8, 0, prog, outs, nexts, depth);
        // 他人同样无法复活（非 owner 在登记入口就被拦下）
        vm.prank(address(0xBEEF));
        vm.expectRevert("not owner");
        ge.registerFunction(8, 0, prog, outs, nexts, depth);
    }

    /* ==================== 边界与负例补测 ==================== */

    function test_reject_const_operands() public {
        // op=CONST0 但带非零操作数 → 拒绝
        uint32[] memory prog = new uint32[](1);
        prog[0] = uint32(1) << 24 | uint32(5) << 12 | uint32(6);
        uint16[] memory outs = new uint16[](1);
        outs[0] = 1;
        uint16[] memory nexts = new uint16[](0);
        vm.expectRevert("const operands");
        ge.registerFunction(1, 0, prog, outs, nexts, 0);
    }

    function test_reject_too_many_gates() public {
        uint32[] memory prog = new uint32[](1025); // > MAX_GATES
        uint16[] memory outs = new uint16[](1);
        outs[0] = 0;
        uint16[] memory nexts = new uint16[](0);
        vm.expectRevert("too many gates");
        ge.registerFunction(1, 0, prog, outs, nexts, 0);
    }

    function test_reject_next_oob() public {
        uint32[] memory prog = new uint32[](1);
        prog[0] = uint32(uint32(0) << 12 | 0); // signal1 = NAND(in0,in0)
        uint16[] memory outs = new uint16[](1);
        outs[0] = 1;
        uint16[] memory nexts = new uint16[](1);
        nexts[0] = 999; // 越界
        vm.expectRevert("next oob");
        ge.registerFunction(1, 1, prog, outs, nexts, 1);
    }

    function test_disable_unknown_reverts() public {
        vm.expectRevert("unknown");
        ge.disableFunction(bytes32(uint256(0xABC)));
    }

    /// 输出可以是直接引线（输入/状态位本身），不一定是门的输出。
    function test_output_direct_input_wire() public {
        uint32[] memory prog = new uint32[](1);
        prog[0] = uint32(uint32(0) << 12 | 0); // signal1 = NAND(in0,in0) = !in0
        uint16[] memory outs = new uint16[](2);
        outs[0] = 0; // 直取输入
        outs[1] = 1; // 门的输出
        uint16[] memory nexts = new uint16[](0);
        bytes32 id = ge.registerFunction(1, 0, prog, outs, nexts, 1);
        (uint256 outBits,) = ge.eval(id, 0, 0);
        assertEq(outBits & 1, 0, "input wire passthrough");
        assertEq((outBits >> 1) & 1, 1, "!in0");
        (uint256 outBits1,) = ge.eval(id, 1, 0);
        assertEq(outBits1 & 1, 1, "input wire");
        assertEq((outBits1 >> 1) & 1, 0, "!in0");
    }

    /// 位域上限边界：256 个输入可用（超出即拒）。
    function test_boundary_256_inputs() public {
        uint32[] memory prog = new uint32[](1);
        prog[0] = uint32(uint32(0) << 12 | 0);
        uint16[] memory outs = new uint16[](1);
        outs[0] = 256;
        uint16[] memory nexts = new uint16[](0);
        bytes32 id = ge.registerFunction(256, 0, prog, outs, nexts, 1);
        (uint256 o,) = ge.eval(id, uint256(1) << 255, 0);
        assertEq(o, 1, "top input wire reachable");
    }

    function test_double_disable_reverts() public {
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = _buildAdd4();
        bytes32 id = ge.registerFunction(8, 0, prog, outs, nexts, depth);
        ge.disableFunction(id);
        vm.expectRevert("unknown");
        ge.disableFunction(id);
    }
}
