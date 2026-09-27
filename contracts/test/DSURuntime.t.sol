// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DSU } from "../src/DSU.sol";
import { DSURuntime } from "../src/DSURuntime.sol";

/// @title DSURuntime.t — DSU 执行引擎（whitepaper v1.3 §4.2，DSU 交付）
contract DSURuntimeTest is Test {
    DSU internal dsu;
    DSURuntime internal rt;

    bytes32 internal constant V1 = keccak256("impl-v1");

    function setUp() public {
        dsu = new DSU();
        rt = new DSURuntime(dsu);
    }

    function _reg(DSU.DSUType t, bytes32 params, uint256 maxSteps) internal returns (bytes32) {
        return dsu.registerDSU(t, V1, params, bytes32(0), address(0), maxSteps);
    }

    /* ==================== HASH ==================== */

    function test_hash_keccak_and_sha256() public {
        bytes32 id = _reg(DSU.DSUType.HASH, keccak256("algo-multi"), 1000);
        bytes memory data = bytes("fct-gate-engine");

        (bytes memory o1, uint256 s1) = rt.execute(id, abi.encodePacked(uint8(0), data));
        assertEq(abi.decode(o1, (bytes32)), keccak256(data), "keccak");
        assertEq(s1, 1 + (data.length + 31) / 32, "steps keccak");

        (bytes memory o2, uint256 s2) = rt.execute(id, abi.encodePacked(uint8(1), data));
        assertEq(abi.decode(o2, (bytes32)), sha256(data), "sha256");
        assertEq(s2, 1 + (data.length + 31) / 32, "steps sha256");
    }

    function test_hash_bad_algo_reverts() public {
        bytes32 id = _reg(DSU.DSUType.HASH, keccak256("x"), 1000);
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, abi.encodePacked(uint8(9), bytes("d")));
    }

    /* ==================== SIGN ==================== */

    function test_sign_recovers_signer() public {
        bytes32 id = _reg(DSU.DSUType.SIGN, keccak256("secp256k1"), 1000);
        uint256 pk = 0xA11CE;
        address signer = vm.addr(pk);
        bytes32 digest = keccak256("fct-sign");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        (bytes memory out, uint256 steps) = rt.execute(id, abi.encodePacked(digest, v, r, s));
        assertEq(abi.decode(out, (address)), signer, "recovers signer");
        assertEq(steps, 1);
    }

    function test_sign_bad_v_reverts() public {
        bytes32 id = _reg(DSU.DSUType.SIGN, keccak256("secp256k1"), 1000);
        bytes32 digest = keccak256("x");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xA11CE, digest);
        // v 取 27/28 之外 → BadInput
        bytes memory input = abi.encodePacked(digest, uint8(29), r, s);
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, input);
        v; // 抑制未使用告警
    }

    /// 可延展性：同一签名存在 (r, n−s, v^1) 等价形式。
    /// 要求 low-s 后，延展形式必须被拒（否则同一签名的"输入"不唯一）。
    function test_sign_high_s_malleability_rejected() public {
        bytes32 id = _reg(DSU.DSUType.SIGN, keccak256("secp256k1"), 1000);
        uint256 pk = 0xA11CE;
        bytes32 digest = keccak256("malleable");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        // 先确认规范形式通过
        (bytes memory out,) = rt.execute(id, abi.encodePacked(digest, v, r, s));
        assertEq(abi.decode(out, (address)), vm.addr(pk));

        // 构造延展形式：s' = n − s，v' = v ^ 1
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(n - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, abi.encodePacked(digest, vFlip, r, sHigh));
    }

    /* ==================== ARITH ==================== */

    function test_arith_add_mul_sub_mod() public {
        bytes32 id = _reg(DSU.DSUType.ARITH, keccak256("bn254-fp"), 1000);
        uint256 m = 7;
        (bytes memory oa,) = rt.execute(id, abi.encodePacked(uint8(0), bytes32(uint256(10)), bytes32(uint256(20)), bytes32(m)));
        assertEq(abi.decode(oa, (uint256)), 2, "(10+20)%7");
        (bytes memory om,) = rt.execute(id, abi.encodePacked(uint8(1), bytes32(uint256(3)), bytes32(uint256(4)), bytes32(m)));
        assertEq(abi.decode(om, (uint256)), 5, "(3*4)%7");
        (bytes memory os,) = rt.execute(id, abi.encodePacked(uint8(2), bytes32(uint256(2)), bytes32(uint256(5)), bytes32(m)));
        assertEq(abi.decode(os, (uint256)), 4, "(2-5)%7");
    }

    function test_arith_zero_mod_reverts() public {
        bytes32 id = _reg(DSU.DSUType.ARITH, keccak256("p"), 1000);
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, abi.encodePacked(uint8(0), bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(0))));
    }

    /* ==================== STATE_MACHINE ==================== */

    function test_state_machine_iterates() public {
        bytes32 id = _reg(DSU.DSUType.STATE_MACHINE, keccak256("lcg"), 1000);
        uint256 n = 3;
        uint256 seed = 0x1234;
        (bytes memory out, uint256 steps) = rt.execute(id, abi.encodePacked(uint8(n), bytes32(seed)));
        uint256 expect = seed;
        for (uint256 i = 0; i < n; i++) {
            expect = uint256(keccak256(abi.encode(expect, i)));
        }
        assertEq(abi.decode(out, (uint256)), expect, "iterate");
        assertEq(steps, n);
    }

    function test_state_machine_budget_enforced() public {
        // maxSteps=2 的 DSU：n=3 必须被预算挡下（真实终止性强制）
        bytes32 id = _reg(DSU.DSUType.STATE_MACHINE, keccak256("small"), 2);
        vm.expectRevert(abi.encodeWithSelector(DSURuntime.BudgetExceeded.selector, uint256(3), uint256(2)));
        rt.execute(id, abi.encodePacked(uint8(3), bytes32(uint256(1))));
    }

    function test_budget_enforced_across_categories() public {
        // HASH：数据 96 字节 → steps = 1 + 3 = 4 > maxSteps 2 → 拒绝
        bytes32 id = _reg(DSU.DSUType.HASH, keccak256("tiny"), 2);
        bytes memory data = new bytes(96);
        vm.expectRevert(abi.encodeWithSelector(DSURuntime.BudgetExceeded.selector, uint256(4), uint256(2)));
        rt.execute(id, abi.encodePacked(uint8(0), data));
    }

    /* ==================== ML ==================== */

    function test_ml_quantized_forward() public {
        bytes32 id = _reg(DSU.DSUType.ML, keccak256("int8-matvec"), 1000);
        // m=2, k=2；W=[1,2;3,4]；x=[1,1]；b=[0,1] → y=[3,8]
        bytes memory input = abi.encodePacked(
            uint8(2),
            uint8(2),
            int8(1),
            int8(2),
            int8(3),
            int8(4),
            int8(1),
            int8(1),
            int8(0),
            int8(1)
        );
        (bytes memory out, uint256 steps) = rt.execute(id, input);
        int256[] memory y = abi.decode(out, (int256[]));
        assertEq(y[0], 3, "y0");
        assertEq(y[1], 8, "y1");
        assertEq(steps, 4, "per-MAC");
    }

    function test_ml_negative_weights() public {
        bytes32 id = _reg(DSU.DSUType.ML, keccak256("int8-neg"), 1000);
        // m=1,k=2；W=[-3,5]；x=[4,-2]；b=[1] → -3*4 + 5*(-2) + 1 = -12 -10 + 1 = -21
        bytes memory input = abi.encodePacked(
            uint8(1), uint8(2), int8(-3), int8(5), int8(4), int8(-2), int8(1)
        );
        (bytes memory out,) = rt.execute(id, input);
        int256[] memory y = abi.decode(out, (int256[]));
        assertEq(y[0], -21, "signed");
    }

    function test_ml_bad_length_reverts() public {
        bytes32 id = _reg(DSU.DSUType.ML, keccak256("badlen"), 1000);
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, abi.encodePacked(uint8(2), uint8(2), int8(1)));
    }

    function test_ml_budget_enforced() public {
        // m=4,k=4 → 16 MAC > maxSteps 10
        bytes32 id = _reg(DSU.DSUType.ML, keccak256("tiny-ml"), 10);
        bytes memory input = new bytes(2 + 16 + 4 + 4);
        input[0] = bytes1(uint8(4));
        input[1] = bytes1(uint8(4));
        vm.expectRevert(abi.encodeWithSelector(DSURuntime.BudgetExceeded.selector, uint256(16), uint256(10)));
        rt.execute(id, input);
    }

    /* ==================== 边界 ==================== */

    function test_unknown_dsu_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(DSURuntime.UnknownDSU.selector, bytes32(uint256(0xDEAD))));
        rt.execute(bytes32(uint256(0xDEAD)), abi.encodePacked(uint8(0), bytes("d")));
    }

    function test_budgetOf_query() public {
        bytes32 id = _reg(DSU.DSUType.HASH, keccak256("q"), 42);
        (uint256 ms, DSU.DSUType t, bool reg) = rt.budgetOf(id);
        assertEq(ms, 42);
        assertEq(uint256(t), uint256(DSU.DSUType.HASH));
        assertTrue(reg);
    }

    /* ==================== 边界与负例补测 ==================== */

    function test_arith_mod_one_and_b_mod_zero() public {
        bytes32 id = _reg(DSU.DSUType.ARITH, keccak256("edge"), 1000);
        // m=1 → 恒 0
        (bytes memory o1,) = rt.execute(id, abi.encodePacked(uint8(0), bytes32(uint256(7)), bytes32(uint256(9)), bytes32(uint256(1))));
        assertEq(abi.decode(o1, (uint256)), 0, "mod 1");
        // b%m==0 的减法：10 - 20 (mod 5)：b%m=0 → (10%5)=0
        (bytes memory o2,) = rt.execute(id, abi.encodePacked(uint8(2), bytes32(uint256(10)), bytes32(uint256(20)), bytes32(uint256(5))));
        assertEq(abi.decode(o2, (uint256)), 0, "b%m==0");
        // 10 - 3 (mod 5) = 2
        (bytes memory o3,) = rt.execute(id, abi.encodePacked(uint8(2), bytes32(uint256(10)), bytes32(uint256(3)), bytes32(uint256(5))));
        assertEq(abi.decode(o3, (uint256)), 2, "10-3 mod 5");
    }

    function test_arith_bad_op_reverts() public {
        bytes32 id = _reg(DSU.DSUType.ARITH, keccak256("op"), 1000);
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, abi.encodePacked(uint8(3), bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(7))));
    }

    function test_hash_empty_data() public {
        bytes32 id = _reg(DSU.DSUType.HASH, keccak256("empty"), 1000);
        (bytes memory out, uint256 steps) = rt.execute(id, abi.encodePacked(uint8(0)));
        assertEq(abi.decode(out, (bytes32)), keccak256(bytes("")), "empty hash");
        assertEq(steps, 1, "empty -> 1");
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, bytes("")); // 连 algo 字节都没有
    }

    function test_sign_zero_rs_reverts() public {
        bytes32 id = _reg(DSU.DSUType.SIGN, keccak256("zsig"), 1000);
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, abi.encodePacked(bytes32(uint256(1)), uint8(27), bytes32(0), bytes32(0)));
    }

    function test_state_machine_zero_and_bad_length() public {
        bytes32 id = _reg(DSU.DSUType.STATE_MACHINE, keccak256("sm"), 1000);
        (bytes memory out, uint256 steps) = rt.execute(id, abi.encodePacked(uint8(0), bytes32(uint256(0x55))));
        assertEq(abi.decode(out, (uint256)), 0x55, "n=0 -> seed");
        assertEq(steps, 0, "zero steps");
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, abi.encodePacked(uint8(1))); // 长度错
    }

    function test_ml_int8_min_and_boundary() public {
        bytes32 id = _reg(DSU.DSUType.ML, keccak256("ml-edge"), 100000);
        // m=1,k=1: W=[-128], x=[2], b=[-128] → -256 - 128 = -384
        (bytes memory out,) = rt.execute(id, abi.encodePacked(uint8(1), uint8(1), int8(-128), int8(2), int8(-128)));
        int256[] memory y = abi.decode(out, (int256[]));
        assertEq(y[0], -384, "int8 min");
    }

    function test_ml_accumulation_no_overflow() public {
        bytes32 id = _reg(DSU.DSUType.ML, keccak256("ml-max"), 100000);
        // m=1,k=3: 3 × (127*127) = 48387（远小于 int256 上界）
        (bytes memory out,) = rt.execute(
            id, abi.encodePacked(uint8(1), uint8(3), int8(127), int8(127), int8(127), int8(127), int8(127), int8(127), int8(0))
        );
        int256[] memory y = abi.decode(out, (int256[]));
        assertEq(y[0], 3 * 127 * 127, "bounded accumulation");
    }

    function test_hash_budget_checked_before_work() public {
        // maxSteps=1，96 字节数据 → steps=4：必须在做哈希**之前**就 revert
        bytes32 id = _reg(DSU.DSUType.HASH, keccak256("early"), 1);
        bytes memory data = new bytes(96);
        vm.expectRevert(abi.encodeWithSelector(DSURuntime.BudgetExceeded.selector, uint256(4), uint256(1)));
        rt.execute(id, abi.encodePacked(uint8(0), data));
    }

    function test_ml_zero_dims_revert() public {
        bytes32 id = _reg(DSU.DSUType.ML, keccak256("zero"), 1000);
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, abi.encodePacked(uint8(0), uint8(2), int8(1), int8(1)));
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, abi.encodePacked(uint8(2), uint8(0), int8(1), int8(1)));
    }

    function test_budgetOf_unregistered() public {
        (uint256 ms, DSU.DSUType t, bool reg) = rt.budgetOf(bytes32(uint256(0xDEAD)));
        assertEq(ms, 0);
        assertEq(uint256(t), 0);
        assertFalse(reg);
    }

    /// low-s 上界：s > n/2 必须被拒（EIP-2）。
    function test_sign_low_s_boundary() public {
        bytes32 id = _reg(DSU.DSUType.SIGN, keccak256("bound"), 1000);
        uint256 half = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
        // s = n/2 + 1 → 超上界
        bytes memory over = abi.encodePacked(bytes32(uint256(1)), uint8(27), bytes32(uint256(1)), bytes32(half + 1));
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, over);
        // s = n（最大，> n/2）同样被拒
        bytes memory maxS = abi.encodePacked(
            bytes32(uint256(1)), uint8(27), bytes32(uint256(1)), bytes32(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141)
        );
        vm.expectRevert(DSURuntime.BadInput.selector);
        rt.execute(id, maxS);
    }
}
