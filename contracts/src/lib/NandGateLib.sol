// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title NandGateLib
/// @notice M6 门级原语库（whitepaper v1.3 §4.3.3 混合模式 / dev-plan §5.4）。
///         与 GateLang 网表门数一致：NOT=1 AND=2 OR=3 XOR=4(深度3)，
///         半加器=5（共享 t=NAND）、全加器=15、4 位加法器=60、4 位比较器=58。
///         所有模块由 NAND 组合而成，作为链上"验证锚"。
library NandGateLib {
    /// @notice 单 bit NAND。
    function _nand(uint256 a, uint256 b) internal pure returns (uint256) {
        return (~(a & b)) & 1;
    }

    /// @notice XOR via NAND（4 门）。
    function xor1(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 t = _nand(a, b);
        return _nand(_nand(a, t), _nand(b, t));
    }

    function and1(uint256 a, uint256 b) internal pure returns (uint256) {
        return _nand(_nand(a, b), _nand(a, b));
    }

    function or1(uint256 a, uint256 b) internal pure returns (uint256) {
        return _nand(_nand(a, a), _nand(b, b));
    }

    /// @notice 半加器：5 个 NAND（共享 t=NAND(a,b)，GateLang 白皮书 v2.1 §4.2）。
    ///         sum=a^b, carry=a&b
    function halfAdd(uint256 a, uint256 b) internal pure returns (uint256 sum, uint256 carry) {
        uint256 t = _nand(a, b); // 1
        sum = _nand(_nand(a, t), _nand(b, t)); // +3 = 4
        carry = _nand(t, t); // +1 = 5
    }

    /// @notice 全加器：15 门（2×XOR4 + 2×AND2 + OR3），深度 7。与 gatelang FullAdder 一致。
    function fullAdd(uint256 a, uint256 b, uint256 cin) internal pure returns (uint256 sum, uint256 cout) {
        uint256 ab = xor1(a, b); // 4
        sum = xor1(ab, cin); // 4 → 8
        uint256 aab = and1(a, b); // 2 → 10
        uint256 cab = and1(cin, ab); // 2 → 12
        cout = or1(aab, cab); // 3 → 15
    }

    /// @notice 4 位加法器：60 门（4×15），深度 19。与 gatelang adder4 一致。
    function add4(uint256 a, uint256 b) internal pure returns (uint256 sumValue, uint256 cout) {
        uint256 cin = 0;
        uint256 s;
        (s, cin) = fullAdd(a & 1, b & 1, cin);
        sumValue = s;
        (s, cin) = fullAdd((a >> 1) & 1, (b >> 1) & 1, cin);
        sumValue |= s << 1;
        (s, cin) = fullAdd((a >> 2) & 1, (b >> 2) & 1, cin);
        sumValue |= s << 2;
        (s, cin) = fullAdd((a >> 3) & 1, (b >> 3) & 1, cin);
        sumValue |= s << 3;
        cout = cin;
    }

    /// @notice 4 位比较器：与 GateLang `examples/stdlib_l1.gat` 的 Comparator4 网表对齐
    ///         （58 门 / 深度 20，见 gatelang CLI 与集成测试 comparator4_58gates_eq_gt_spec）。
    ///         语义：
    ///           eq = !(d3|d2|d1|d0)
    ///           gt = a[3] if d3 else (a[2] if d2 else (a[1] if d1 else (a[0] if d0 else 0)))
    ///         即"最高不同位"决定大小：d_i=1 ⇒ 该位不同 ⇒ a[i]=1 时 a>b。
    ///         此处为等价的紧凑 NAND 展开（不额外为 b 建 NOT 门）。
    function cmp4(uint256 a, uint256 b) internal pure returns (uint256 eq, uint256 gt) {
        uint256 d0 = xor1(a & 1, b & 1);
        uint256 d1 = xor1((a >> 1) & 1, (b >> 1) & 1);
        uint256 d2 = xor1((a >> 2) & 1, (b >> 2) & 1);
        uint256 d3 = xor1((a >> 3) & 1, (b >> 3) & 1);
        // eq = !(d3|d2|d1|d0)
        eq = _nand(or1(or1(d3, d2), or1(d1, d0)), or1(or1(d3, d2), or1(d1, d0)));
        // gt = (d3&a3) | (!d3 & ((d2&a2) | (!d2 & ((d1&a1) | (!d1 & (d0&a0))))))
        uint256 t0 = and1(d0, a & 1);
        uint256 t1 = or1(and1(d1, (a >> 1) & 1), and1(_nand(d1, d1), t0));
        uint256 t2 = or1(and1(d2, (a >> 2) & 1), and1(_nand(d2, d2), t1));
        gt = or1(and1(d3, (a >> 3) & 1), and1(_nand(d3, d3), t2));
    }
}