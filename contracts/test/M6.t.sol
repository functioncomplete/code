// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { NandGateLib } from "../src/lib/NandGateLib.sol";
import { HybridGate } from "../src/HybridGate.sol";

/// @title M6.t — 混合模式（whitepaper §3.4.10 / dev-plan §5.4）
contract M6HybridTest is Test {
    HybridGate internal hg;

    bytes32 internal ADD4_GATE_ID = keccak256("nand-add4-net-v1");
    bytes32 internal DSU_ARITH_ID = keccak256("dsu-arith-add-v1");

    // 模块号在 setUp 期间从合约读取并缓存。
    // 原因：MODULE_ADD4()/MODULE_CMP4() 是 public constant 的 external getter，
    // 若在 vm.expectRevert 与被测调用之间作为参数求值，会抢先消耗 expectRevert，
    // 导致 forge 误报 "next call did not revert as expected"。
    uint8 internal MOD_ADD4;
    uint8 internal MOD_CMP4;

    // 证明者（owner）与验证者必须是不同角色。
    // REJECTED 分支中 HybridGate 把 slash 打给 msg.sender（验证者）、
    // 把 remain 打给 owner（证明者）；若二者同为测试合约则两笔都会回到本合约，
    // 无法验证"罚没 50% 归验证者"这一语义。
    address internal prover = address(0xB0B);

    // verifyByGate 通过 msg.sender.call{value:...}("") 把退款/罚没打给验证者。
    // 本测试合约即验证者，必须实现 receive 才能接收 ETH，否则合约侧 ok=false。
    receive() external payable {}

    function setUp() public {
        // 以 prover 身份部署并登记模块（registerModule 为 onlyOwner），使 owner = prover。
        vm.startPrank(prover);
        hg = new HybridGate();
        MOD_ADD4 = hg.MODULE_ADD4();
        MOD_CMP4 = hg.MODULE_CMP4();
        hg.registerModule(MOD_ADD4, ADD4_GATE_ID, 60, 19);
        hg.registerModule(MOD_CMP4, keccak256("nand-cmp4-net-v1"), 58, 20);
        vm.stopPrank();
    }

    /* ============ 逻辑原语原语库单元验证 ============ */

    function test_halfAdder5nand_truthTable() public view {
        (uint256 s, uint256 c) = NandGateLib.halfAdd(0, 0);
        assertEq(s, 0);
        assertEq(c, 0);
        (s, c) = NandGateLib.halfAdd(1, 0);
        assertEq(s, 1);
        assertEq(c, 0);
        (s, c) = NandGateLib.halfAdd(0, 1);
        assertEq(s, 1);
        assertEq(c, 0);
        (s, c) = NandGateLib.halfAdd(1, 1);
        assertEq(s, 0);
        assertEq(c, 1);
    }

    function test_fullAdder15nand_truthTable() public view {
        // a b cin -> sum cout（穷举 8 组）
        (uint256 s, uint256 c) = NandGateLib.fullAdd(0, 0, 0);
        assertEq(s, 0);
        assertEq(c, 0);
        (s, c) = NandGateLib.fullAdd(1, 0, 0);
        assertEq(s, 1);
        assertEq(c, 0);
        (s, c) = NandGateLib.fullAdd(0, 1, 0);
        assertEq(s, 1);
        assertEq(c, 0);
        (s, c) = NandGateLib.fullAdd(1, 1, 0);
        assertEq(s, 0);
        assertEq(c, 1);
        (s, c) = NandGateLib.fullAdd(0, 0, 1);
        assertEq(s, 1);
        assertEq(c, 0);
        (s, c) = NandGateLib.fullAdd(1, 0, 1);
        assertEq(s, 0);
        assertEq(c, 1);
        (s, c) = NandGateLib.fullAdd(0, 1, 1);
        assertEq(s, 0);
        assertEq(c, 1);
        (s, c) = NandGateLib.fullAdd(1, 1, 1);
        assertEq(s, 1);
        assertEq(c, 1);
    }

    function test_add4_gateEval_allInputs() public view {
        // 穷举 16×16=256：验证逻辑原语加法器等价 uint 运算（60 门模块）
        for (uint256 a = 0; a < 16; a++) {
            for (uint256 b = 0; b < 16; b++) {
                (uint256 sum, uint256 cout) = NandGateLib.add4(a, b);
                assertEq(sum, (a + b) & 0xF, "sum bits");
                assertEq(cout, (a + b) >> 4, "carry");
            }
        }
    }

    function test_cmp4_gateEval() public view {
        (uint256 eq, uint256 gt) = NandGateLib.cmp4(3, 3);
        assertEq(eq, 1);
        assertEq(gt, 0);
        (eq, gt) = NandGateLib.cmp4(7, 2);
        assertEq(eq, 0);
        assertEq(gt, 1);
        (eq, gt) = NandGateLib.cmp4(1, 5);
        assertEq(eq, 0);
        assertEq(gt, 0);
    }

    /* ============ 逻辑原语资源说明 ============ */

    function test_gateNotes_matchGatelang() public view {
        (uint32 g, uint32 d) = hg.gateNotes(hg.MODULE_ADD4());
        assertEq(g, 60);
        assertEq(d, 19);
        (g, d) = hg.gateNotes(hg.MODULE_CMP4());
        assertEq(g, 58);
        assertEq(d, 20);
    }

    /* ============ 混合证明链 ============ */

    function _createReq(uint16 a, uint16 b, uint8 module) internal returns (uint64) {
        uint64 req = hg.createRequest{ value: 1 ether }(
            module == MOD_ADD4 ? ADD4_GATE_ID : keccak256("nand-cmp4-net-v1"),
            DSU_ARITH_ID,
            module,
            a,
            b
        );
        return req;
    }

    function test_proofChain_verify_updateContainer() public {
        uint64 req = _createReq(5, 7, MOD_ADD4);
        assertEq(uint8(hg.requestStatus(req)), uint8(HybridGate.Status.REQUESTED));

        // DSU 执行输出（高性能计算）
        hg.submitDsuOutputV2(req, 12, 64);
        assertEq(uint8(hg.requestStatus(req)), uint8(HybridGate.Status.DSU_EXECUTED));

        // 逻辑原语验证锚 + 状态管理器更新
        hg.verifyByGate(req);
        assertEq(uint8(hg.requestStatus(req)), uint8(HybridGate.Status.VERIFIED));
        bytes32 interfaceId = keccak256(abi.encode(MOD_ADD4, uint16(5), uint16(7)));
        assertEq(hg.containerValue(interfaceId), 12, "container value = 5+7");
    }

    function test_proofChain_gateRejectsWrongDsuResult_slash() public {
        uint64 req = _createReq(10, 3, MOD_ADD4);
        hg.submitDsuOutputV2(req, 15, 64); // 错误输出（真值 13）

        uint256 bountyBefore = address(this).balance;
        hg.verifyByGate(req); // 逻辑原语重放 = 13 ≠ 15 → REJECTED
        assertEq(uint8(hg.requestStatus(req)), uint8(HybridGate.Status.REJECTED));
        // 罚没 50% 给验证者（address(this)）
        assertEq(address(this).balance - bountyBefore, 0.5 ether, "slash 50%");
    }

    function test_gateEval_public_noStateChange() public view {
        (uint16 main, uint16 extra) = hg.gateEval(hg.MODULE_ADD4(), 9, 6);
        assertEq(main, 15);
        assertEq(extra, 0);
        (main, extra) = hg.gateEval(hg.MODULE_CMP4(), 1, 5);
        assertEq(main, 0); // gt = 0
        assertEq(extra, 0); // eq = 0
    }

    function test_registerModule_dup_rejects() public {
        // registerModule 为 onlyOwner，须以 prover 身份调用才能走到 "dup module" 断言。
        vm.prank(prover);
        vm.expectRevert("dup module");
        hg.registerModule(MOD_ADD4, keccak256("x"), 60, 19);
    }

    function test_registerModule_wrongGateCount_rejects() public {
        vm.prank(prover);
        vm.expectRevert("add4 spec");
        hg.registerModule(MOD_ADD4, keccak256("y"), 59, 19);
    }

    function test_createRequest_zeroStake_reverts() public {
        vm.expectRevert("stake 0");
        hg.createRequest{ value: 0 }(ADD4_GATE_ID, DSU_ARITH_ID, MOD_ADD4, 1, 2);
    }

    function test_createRequest_gateMismatch_reverts() public {
        vm.expectRevert("gate mismatch");
        hg.createRequest{ value: 1 ether }(
            keccak256("other-gate"),
            DSU_ARITH_ID,
            MOD_ADD4,
            1,
            2
        );
    }

    function test_stakeRefund_goesToProver_notCaller() public {
        // 回归：退款必须回到质押者，不能被第三方抢跑窃取；非质押者不得提交 DSU 输出。
        uint64 req = _createReq(5, 7, MOD_ADD4);

        // 非质押者提交 DSU 输出 -> 应被拒
        vm.prank(address(0xBAD));
        vm.expectRevert("not prover");
        hg.submitDsuOutputV2(req, 12, 64);

        // 质押者（本测试合约）提交正确输出
        hg.submitDsuOutputV2(req, 12, 64);

        // 第三方触发验证：成功退款须回到质押者，调用者分文不得
        address attacker = address(0xC0FFEE);
        uint256 proverBefore = address(this).balance;
        uint256 attackerBefore = attacker.balance;
        vm.prank(attacker);
        hg.verifyByGate(req);
        assertEq(attacker.balance - attackerBefore, 0, "attacker must not receive refund");
        assertEq(address(this).balance - proverBefore, 1 ether, "prover must receive stake back");
    }
}