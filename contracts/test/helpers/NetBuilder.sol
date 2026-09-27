// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title NetBuilder（测试辅助）
/// @notice 逐项镜像 `gatelang/src/netlist.rs` 的 NAND 原语展开
///         （NOT=1 / AND=2 / OR=3 / XOR=4 / 全加器=15），
///         用于在测试中构造与 GateLang 编译产物同构的扁平网表，喂给链上门级引擎。
///         信号编号约定：`0..nIn-1` 为主输入，`nIn..nIn+nLatch-1` 为 LATCH 状态位，
///         其后每个 NAND/常量门按拓扑序逐个占用一个信号下标。
library NB {
    uint256 internal constant MAXSIG = 1024;

    struct Ctx {
        uint32[] prog; // op(8) | l(12) | r(12)（预分配缓冲）
        uint32[] dep; // 每信号深度
        uint256 progLen;
        uint256 sigCount;
    }

    function init(uint256 nIn, uint256 nLatch) internal pure returns (Ctx memory c) {
        c.prog = new uint32[](MAXSIG);
        c.dep = new uint32[](MAXSIG);
        c.progLen = 0;
        c.sigCount = nIn + nLatch; // 输入/状态信号深度 0
    }

    /// 取出实际用到的门列表（裁剪到 progLen）。
    function trim(Ctx memory c) internal pure returns (uint32[] memory p) {
        p = new uint32[](c.progLen);
        for (uint256 i = 0; i < c.progLen; i++) {
            p[i] = c.prog[i];
        }
    }

    function nand(Ctx memory c, uint256 l, uint256 r) internal pure returns (uint16) {
        uint256 out = c.sigCount;
        c.prog[c.progLen++] = uint32(l) << 12 | uint32(r); // op=0 (NAND)
        uint32 dl = c.dep[l];
        uint32 dr = c.dep[r];
        c.dep[out] = (dl > dr ? dl : dr) + 1;
        c.sigCount = out + 1;
        return uint16(out);
    }

    function const0(Ctx memory c) internal pure returns (uint16) {
        uint256 out = c.sigCount;
        c.prog[c.progLen++] = uint32(1) << 24;
        c.dep[out] = 0;
        c.sigCount = out + 1;
        return uint16(out);
    }

    function const1(Ctx memory c) internal pure returns (uint16) {
        uint256 out = c.sigCount;
        c.prog[c.progLen++] = uint32(2) << 24;
        c.dep[out] = 0;
        c.sigCount = out + 1;
        return uint16(out);
    }

    function not_(Ctx memory c, uint256 x) internal pure returns (uint16) {
        return nand(c, x, x);
    }

    function and_(Ctx memory c, uint256 a, uint256 b) internal pure returns (uint16) {
        return not_(c, nand(c, a, b));
    }

    function or_(Ctx memory c, uint256 a, uint256 b) internal pure returns (uint16) {
        return nand(c, nand(c, a, a), nand(c, b, b));
    }

    function xor_(Ctx memory c, uint256 a, uint256 b) internal pure returns (uint16) {
        uint16 t = nand(c, a, b);
        return nand(c, nand(c, a, t), nand(c, b, t));
    }

    /// 全加器：15 门 / 深度 7（与 netlist.rs 的 full_adder 逐门一致）。
    function fullAdd(Ctx memory c, uint256 a, uint256 b, uint256 cin)
        internal
        pure
        returns (uint16 sum, uint16 cout)
    {
        uint16 ab = xor_(c, a, b);
        sum = xor_(c, ab, cin);
        uint16 aab = and_(c, a, b);
        uint16 cab = and_(c, cin, ab);
        cout = or_(c, aab, cab);
    }

    function maxDepth(Ctx memory c) internal pure returns (uint32 d) {
        for (uint256 i = 0; i < c.sigCount; i++) {
            if (c.dep[i] > d) d = c.dep[i];
        }
    }

    /* ---------- 现成电路 ---------- */

    /// 4 位加法器：输入 a0..a3(sig0..3), b0..b3(sig4..7)；输出 [sum0..sum3, cout]。
    /// 61 门（60 NAND + 1 const）/ 深度 19（与 gatelang adder4 一致）。
    function buildAdd4()
        internal
        pure
        returns (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth)
    {
        Ctx memory c = init(8, 0);
        uint16 carry = const0(c);
        uint16[4] memory sums;
        for (uint256 i = 0; i < 4; i++) {
            (uint16 s, uint16 co) = fullAdd(c, i, 4 + i, carry);
            sums[i] = s;
            carry = co;
        }
        outs = new uint16[](5);
        outs[0] = sums[0];
        outs[1] = sums[1];
        outs[2] = sums[2];
        outs[3] = sums[3];
        outs[4] = carry;
        nexts = new uint16[](0);
        prog = trim(c);
        depth = maxDepth(c);
    }

    /// 1 位翻转单元：signal0 = 输入，signal1 = latch 当前值；
    /// out = state（bit0），next = !state。演示 LATCH 状态的读入与下一状态输出。
    function buildToggle()
        internal
        pure
        returns (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth)
    {
        Ctx memory c = init(1, 1);
        uint16 nxt = not_(c, 1);
        outs = new uint16[](1);
        outs[0] = 1;
        nexts = new uint16[](1);
        nexts[0] = nxt;
        prog = trim(c);
        depth = maxDepth(c);
    }
}
