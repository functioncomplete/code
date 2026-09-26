// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProofMarket} from "../src/ProofMarket.sol";

contract ProofMarketTest is Test {
    ProofMarket public pm;

    uint256 constant WINDOW = 100; // 秒

    address requester = makeAddr("requester");
    address prover = makeAddr("prover");
    address v1 = makeAddr("validator1");
    address v2 = makeAddr("validator2");
    address v3 = makeAddr("validator3");
    address v4 = makeAddr("validator4");

    bytes32 constant INPUT = keccak256("f(x)");
    bytes32 constant OUTPUT = keccak256("y=f(x)");
    uint256 constant FUNC_ID = 0xabcdef;

    function setUp() public {
        vm.warp(1_000_000);
        pm = new ProofMarket(WINDOW);
        vm.deal(requester, 100 ether);
        vm.deal(prover, 100 ether);
        vm.deal(v1, 0.1 ether);
        vm.deal(v2, 0.1 ether);
        vm.deal(v3, 0.1 ether);
        vm.deal(v4, 0.1 ether);

        pm.registerValidator(v1);
        pm.registerValidator(v2);
        pm.registerValidator(v3);
        pm.registerValidator(v4);
    }

    /* ---------- state readers（Task 14 槽位） ---------- */
    // 1 containerId, 2 functionId, 3 path, 4 inputHash, 5 outputHash,
    // 6 reward, 7 expiresAt, 8 status, 9 requester, 10 prover,
    // 11 proofHash, 12 submittedAt, 13 acceptVotes, 14 rejectVotes

    function rewardOf(uint256 id) internal view returns (uint256 r) {
        (,,,,, r,,,,,,,,) = pm.tasks(id);
    }

    function statusOf(uint256 id) internal view returns (ProofMarket.TaskStatus s) {
        (,,,,,,, s,,,,,,) = pm.tasks(id);
    }

    function proverOf(uint256 id) internal view returns (address p) {
        (,,,,,,,,, p,,,,) = pm.tasks(id);
    }

    function proofHashOf(uint256 id) internal view returns (bytes32 ph) {
        (,,,,,,,,,, ph,,,) = pm.tasks(id);
    }

    function submittedAtOf(uint256 id) internal view returns (uint256 sa) {
        (,,,,,,,,,,, sa,,) = pm.tasks(id);
    }

    /* ---------- helpers ---------- */

    function makeTask() internal returns (uint256 id) {
        vm.prank(requester);
        id = pm.createTask{value: 1 ether}(
            1, FUNC_ID, ProofMarket.ProofPath.REPLAY, INPUT, OUTPUT, block.timestamp + 1000
        );
    }

    function makeOpenTaskNoOutput() internal returns (uint256 id) {
        vm.prank(requester);
        id = pm.createTask{value: 1 ether}(
            1, FUNC_ID, ProofMarket.ProofPath.REPLAY, INPUT, bytes32(0), block.timestamp + 1000
        );
    }

    function proofOf(bytes32 out) internal pure returns (ProofMarket.Proof memory p) {
        p.inputHash = INPUT;
        p.outputHash = out;
        p.payload = hex"deadbeef";
    }

    function expectedHash(bytes32 out) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(INPUT, out, hex"deadbeef"));
    }

    function stakeProver() internal {
        vm.prank(prover);
        pm.stake{value: 0.02 ether}();
    }

    function submitValid() internal {
        stakeProver();
        vm.prank(prover);
        pm.submitProof(1, proofOf(OUTPUT));
    }

    function voteAccept(address a, uint256 id) internal {
        vm.prank(a);
        pm.vote(id, true);
    }

    function voteReject(address a, uint256 id) internal {
        vm.prank(a);
        pm.vote(id, false);
    }

    /* ---------- create / cancel / expire ---------- */

    function testCreateTaskStoresReward() public {
        uint256 before = requester.balance;
        vm.expectEmit(true, true, true, true);
        emit ProofMarket.TaskCreated(1, requester, 1 ether, ProofMarket.ProofPath.REPLAY);
        vm.prank(requester);
        uint256 id = pm.createTask{value: 1 ether}(
            1, FUNC_ID, ProofMarket.ProofPath.REPLAY, INPUT, OUTPUT, block.timestamp + 1000
        );
        assertEq(id, 1);
        assertEq(rewardOf(1), 1 ether);
        assertEq(requester.balance, before - 1 ether);
    }

    function testCreateTaskZeroRewardReverts() public {
        vm.prank(requester);
        vm.expectRevert("reward 0");
        pm.createTask(1, FUNC_ID, ProofMarket.ProofPath.REPLAY, INPUT, OUTPUT, block.timestamp + 1000);
    }

    function testCancelTaskByRequesterRefunds() public {
        uint256 id = makeTask();
        uint256 before = requester.balance;
        vm.prank(requester);
        pm.cancelTask(id);
        assertEq(requester.balance, before + 1 ether);
        assertEq(uint256(statusOf(id)), uint256(ProofMarket.TaskStatus.CANCELLED));
    }

    function testCancelByNonRequesterReverts() public {
        uint256 id = makeTask();
        vm.prank(prover);
        vm.expectRevert("not requester");
        pm.cancelTask(id);
    }

    function testCancelSubmittedTaskReverts() public {
        uint256 id = makeTask();
        submitValid();
        vm.prank(requester);
        vm.expectRevert("not open");
        pm.cancelTask(id);
    }

    function testClaimExpiredBeforeExpiryReverts() public {
        uint256 id = makeTask();
        vm.warp(block.timestamp + 500);
        vm.prank(requester);
        vm.expectRevert("not expired");
        pm.claimExpired(id);
    }

    function testClaimExpiredAfterExpiryRefunds() public {
        uint256 id = makeTask();
        vm.warp(block.timestamp + 1001);
        uint256 before = requester.balance;
        vm.prank(requester);
        pm.claimExpired(id);
        assertEq(requester.balance, before + 1 ether);
        assertEq(uint256(statusOf(id)), uint256(ProofMarket.TaskStatus.EXPIRED));
    }

    /* ---------- staking ---------- */

    function testStakeBelowMinReverts() public {
        vm.prank(prover);
        vm.expectRevert("min stake");
        pm.stake{value: 0.001 ether}();
    }

    function testStakeAndUnstake() public {
        vm.prank(prover);
        pm.stake{value: 0.02 ether}();
        assertEq(pm.proverStakes(prover), 0.02 ether);
        assertEq(pm.totalStake(), 0.02 ether);

        uint256 before = prover.balance;
        vm.prank(prover);
        pm.unstake();
        assertEq(prover.balance, before + 0.02 ether);
        assertEq(pm.proverStakes(prover), 0);
        assertEq(pm.totalStake(), 0);
    }

    function testUnstakeWithNoStakeReverts() public {
        vm.prank(prover);
        vm.expectRevert("no stake held");
        pm.unstake();
    }

    /* ---------- submission ---------- */

    function testSubmitRequiresStake() public {
        makeTask();
        vm.prank(prover);
        vm.expectRevert("no stake");
        pm.submitProof(1, proofOf(OUTPUT));
    }

    function testSubmitSuccess() public {
        makeTask();
        stakeProver();
        vm.prank(prover);
        pm.submitProof(1, proofOf(OUTPUT));

        assertEq(uint256(statusOf(1)), uint256(ProofMarket.TaskStatus.SUBMITTED));
        assertEq(proverOf(1), prover);
        assertEq(proofHashOf(1), expectedHash(OUTPUT));
        assertEq(submittedAtOf(1), block.timestamp);
    }

    function testSubmitWrongInputReverts() public {
        makeTask();
        stakeProver();
        ProofMarket.Proof memory p = proofOf(OUTPUT);
        p.inputHash = keccak256("other");
        vm.prank(prover);
        vm.expectRevert("input mismatch");
        pm.submitProof(1, p);
    }

    function testSubmitWrongOutputReverts() public {
        makeTask(); // 任务有期望输出
        stakeProver();
        vm.prank(prover);
        vm.expectRevert("output mismatch");
        pm.submitProof(1, proofOf(keccak256("wrong")));
    }

    function testSubmitAfterExpiryReverts() public {
        uint256 id = makeTask();
        vm.warp(block.timestamp + 1001);
        stakeProver();
        vm.prank(prover);
        vm.expectRevert("expired");
        pm.submitProof(id, proofOf(OUTPUT));
    }

    /* ---------- voting ---------- */

    function testVoteOnlyValidatorReverts() public {
        makeTask();
        submitValid();
        vm.prank(prover);
        vm.expectRevert("not validator");
        pm.vote(1, true);
    }

    function testDoubleVoteReverts() public {
        makeTask();
        submitValid();
        vm.prank(v1);
        pm.vote(1, true);
        vm.prank(v1);
        vm.expectRevert("voted");
        pm.vote(1, false);
    }

    function testSettleNeedsMajorityOrWindow() public {
        makeTask();
        submitValid();
        vm.prank(v1);
        pm.vote(1, true);
        vm.prank(v2);
        pm.vote(1, false);
        vm.expectRevert("voting pending");
        pm.settle(1);
    }

    /* ---------- finalize（>2/3 accept） ---------- */

    function testAcceptFlowPaysProverAndValidators() public {
        uint256 id = makeTask();
        submitValid();

        // 3/4 验证者 accept（>2/3 多数，第 4 个弃权）
        voteAccept(v1, id);
        voteAccept(v2, id);
        voteAccept(v3, id);

        uint256 proverBefore = prover.balance;
        uint256 v1Before = v1.balance;
        uint256 v2Before = v2.balance;
        uint256 v3Before = v3.balance;

        pm.settle(id);

        // reward 1 ether - fee(0.005) = 0.995 -> prover
        assertEq(prover.balance, proverBefore + 0.995 ether);
        // fee 0.005 分给 3 个 accept 验证者（总和对得上）
        assertEq(v1.balance + v2.balance + v3.balance, v1Before + v2Before + v3Before + 0.005 ether);
        assertEq(uint256(statusOf(id)), uint256(ProofMarket.TaskStatus.FINALIZED));
    }

    function testAcceptPaysOnlyAcceptingValidators() public {
        uint256 id = makeTask();
        submitValid();
        voteAccept(v1, id);
        voteAccept(v2, id);
        voteAccept(v3, id);
        voteReject(v4, id); // 1 reject 不影响 >2/3 accept

        uint256 v4Before = v4.balance;
        pm.settle(id);
        assertEq(v4.balance, v4Before); // reject 者无手续费
        assertEq(uint256(statusOf(id)), uint256(ProofMarket.TaskStatus.FINALIZED));
    }

    /* ---------- slash（>2/3 reject） ---------- */

    function testRejectFlowSlashesAndBans() public {
        uint256 id = makeTask();
        submitValid();

        // 3/4 验证者 reject（>2/3 多数）
        voteReject(v1, id);
        voteReject(v2, id);
        voteReject(v3, id);

        uint256 reqBefore = requester.balance;
        uint256 v1Before = v1.balance;
        uint256 v2Before = v2.balance;
        uint256 v3Before = v3.balance;

        pm.settle(id);

        // 逐任务保证金 = MIN_STAKE = 0.01：50% 给 requester，50% 给 reject 验证者平分；
        // 同时归还托管的 1 ether 奖励
        assertEq(requester.balance, reqBefore + 1 ether + 0.005 ether);
        assertEq(v1.balance + v2.balance + v3.balance, v1Before + v2Before + v3Before + 0.005 ether);
        assertEq(pm.proverStakes(prover), 0.01 ether); // 只没收本任务保证金（0.02 - 0.01）
        assertTrue(pm.banned(prover));
        assertEq(uint256(statusOf(id)), uint256(ProofMarket.TaskStatus.SLASHED));
    }

    function testBannedProverCannotSubmitAgain() public {
        uint256 id = makeTask();
        submitValid();
        voteReject(v1, id);
        voteReject(v2, id);
        voteReject(v3, id);
        pm.settle(id);

        uint256 id2 = makeTask();
        vm.prank(prover);
        vm.expectRevert("banned");
        pm.submitProof(id2, proofOf(OUTPUT));
    }

    /* ---------- no majority / reopen ---------- */

    function testUnstakeBlockedWhileTaskPending() public {
        makeTask();
        submitValid(); // prover 质押被锁定

        vm.prank(prover);
        vm.expectRevert("stake locked");
        pm.unstake();

        // 无票 + 窗口结束 -> settle 走 reopen 分支，释放锁
        vm.warp(block.timestamp + WINDOW + 1);
        pm.settle(1);

        vm.prank(prover);
        pm.unstake();
        assertEq(pm.proverStakes(prover), 0);
    }

    function testVoteAfterWindowReverts() public {
        uint256 id = makeTask();
        submitValid();
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(v1);
        vm.expectRevert("window closed");
        pm.vote(id, true);
    }

    function testReRegisteredValidatorCanVoteAgain() public {
        // 注销 + 重注册后，旧票因代次变化失效，v1 可再次投票（否则会被 "voted" 拦截）
        uint256 id = makeTask();
        submitValid();
        voteAccept(v1, id);
        pm.unregisterValidator(v1);
        pm.registerValidator(v1);
        vm.prank(v1);
        pm.vote(id, true);
        assertEq(pm.voteGen(id, v1), pm.validatorGen(v1));
    }

    function testProverCannotVote() public {
        // 证明者/需求方即使被登记为验证者也不得自投（防自证）
        uint256 id = makeTask();
        submitValid();
        pm.registerValidator(prover);
        vm.prank(prover);
        vm.expectRevert("prover cannot vote");
        pm.vote(id, true);
    }

    function testPerTaskBondIsolation() public {
        // 并发两份任务：reject 任务1 只没收其 0.01 保证金，任务2 保证金不受影响
        uint256 id1 = makeTask();
        uint256 id2 = makeTask();
        stakeProver(); // 0.02
        vm.prank(prover);
        pm.submitProof(id1, proofOf(OUTPUT));
        vm.prank(prover);
        pm.submitProof(id2, proofOf(OUTPUT));
        assertEq(pm.lockedBond(prover), 0.02 ether, "two tasks lock 0.02");
        voteReject(v1, id1);
        voteReject(v2, id1);
        voteReject(v3, id1);
        pm.settle(id1);
        assertEq(pm.proverStakes(prover), 0.01 ether, "only task1 bond slashed");
        assertEq(pm.lockedBond(prover), 0.01 ether, "task2 bond still locked");
    }

    function testUnregisterRemovesValidatorNoDuplicate() public {
        // 注销后从数组移除，重注册不产生重复项（重复项会被重复付款并操纵 quorum）
        pm.unregisterValidator(v4);
        assertEq(pm.validatorCount(), 3);
        pm.registerValidator(v4);
        assertEq(pm.validatorCount(), 4);

        uint256 id = makeTask();
        submitValid();
        voteAccept(v1, id);
        voteAccept(v2, id);
        voteAccept(v3, id);
        pm.settle(id); // 4 个验证者中 3 accept > 2/3 -> FINALIZED，无重复付款
        assertEq(uint256(statusOf(id)), uint256(ProofMarket.TaskStatus.FINALIZED));
    }

    function testNoMajorityReopensAfterWindow() public {
        uint256 id = makeTask();
        submitValid();

        voteAccept(v1, id);
        voteReject(v2, id);
        // v3、v4 弃权 -> 1/4 票不构成多数，窗口结束触发 settle

        vm.warp(block.timestamp + WINDOW + 1);
        pm.settle(id);

        assertEq(uint256(statusOf(id)), uint256(ProofMarket.TaskStatus.OPEN));
        // 证明者可再次提交
        vm.prank(prover);
        pm.submitProof(id, proofOf(OUTPUT));
        assertEq(uint256(statusOf(id)), uint256(ProofMarket.TaskStatus.SUBMITTED));
    }

    /* ---------- 公开任务（输出未知） ---------- */

    function testUnknownOutputAcceptsAnyClaim() public {
        uint256 id = makeOpenTaskNoOutput(); // outputHash = 0
        stakeProver();
        bytes32 claimed = keccak256("whatever");
        vm.prank(prover);
        pm.submitProof(id, proofOf(claimed));

        voteAccept(v1, id);
        voteAccept(v2, id);
        voteAccept(v3, id);
        pm.settle(id);

        assertEq(uint256(statusOf(id)), uint256(ProofMarket.TaskStatus.FINALIZED));
    }
}