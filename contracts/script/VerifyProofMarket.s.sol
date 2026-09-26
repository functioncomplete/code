// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ProofMarket} from "../src/ProofMarket.sol";

/// @notice v2 M3 ProofMarket 链上验证脚本（真实交易；断言失败 => 整笔交易回滚）。
/// @dev 需两个账户：部署账户扮 requester/prover，另需 VERIFIER_PRIVATE_KEY 扮验证者
///      （合约 v1.3 起禁止 prover/requester 自投，故验证者必须独立）。
///   参数回读 → 注册验证者 → 创建任务 → 质押 → 提交 → 投票 → 结算
///   正例：accept 达成 >2/3 → FINALIZED，证明者拿 reward-fee
///   反例：reject 达成 >2/3 → SLASHED，本任务保证金罚没 + 禁赛，之后提交被拒
/// 用法：
///   PM_ADDRESS=<addr> VERIFIER_PRIVATE_KEY=<pk2> forge script script/VerifyProofMarket.s.sol \
///     --rpc-url <rpc> --broadcast --private-key <pk>
contract VerifyProofMarket is Script {
    // Task 槽位: 1 containerId, 2 functionId, 3 path, 4 inputHash, 5 outputHash,
    //            6 reward, 7 expiresAt, 8 status, 9 requester, 10 prover,
    //            11 proofHash, 12 submittedAt, 13 acceptVotes, 14 rejectVotes
    function _status(ProofMarket pm, uint256 id) internal view returns (ProofMarket.TaskStatus s) {
        (,,,,,,, s,,,,,,) = pm.tasks(id);
    }

    function _acceptVotes(ProofMarket pm, uint256 id) internal view returns (uint256 n) {
        (,,,,,,,,,,,, n,) = pm.tasks(id);
    }

    function run() external {
        address pmAddr = vm.envAddress("PM_ADDRESS");
        ProofMarket pm = ProofMarket(pmAddr);

        // ---- 1. 常量和参数回读（白皮书 v1.3 §6.3）----
        require(pm.VOTER_NUM() == 2, "V: voterNum");
        require(pm.VOTER_DEN() == 3, "V: voterDen");
        require(pm.FEE_BPS() == 50, "V: feeBps");
        require(pm.SLASH_VALIDATOR_BPS() == 5000, "V: slashBps");
        require(pm.MIN_STAKE() == 0.01 ether, "V: minStake");
        require(pm.VOTING_WINDOW() == 3600, "V: window");

        uint256 pk = vm.envUint("DEPLOY_PRIVATE_KEY");
        address deployer = vm.addr(pk); // 部署账户（requester/prover）
        require(pm.owner() == deployer, "V: owner");
        // 验证者须为独立账户（合约禁止 prover/requester 自投）
        uint256 vpk = vm.envUint("VERIFIER_PRIVATE_KEY");
        address verifier = vm.addr(vpk);
        require(verifier != deployer, "V: verifier must differ");

        // ---- 2. 注册唯一验证者（1/1 即 >2/3）----
        if (!pm.validatorIndex(verifier)) {
            vm.broadcast(pk);
            pm.registerValidator(verifier);
        }
        require(pm.validatorCount() == 1, "V: vc");

        // ---- 3. 正例：accept → 最终性 ----
        bytes32 inputHash = keccak256("f(x) = x^2 + 7");
        bytes32 outputHash = keccak256("f(FCT-2026) = 0x95b2");
        bytes memory payload = hex"7b227265706c6179223a747275657d"; // {"replay":true}

        vm.broadcast(pk);
        uint256 idA = pm.createTask{value: 0.003 ether}(
            1, 0x71, ProofMarket.ProofPath.REPLAY, inputHash, outputHash, block.timestamp + 86400
        );
        require(_status(pm, idA) == ProofMarket.TaskStatus.OPEN, "V: A open");

        vm.broadcast(pk);
        pm.stake{value: 0.01 ether}();
        require(pm.proverStakes(deployer) == 0.01 ether, "V: stake");

        ProofMarket.Proof memory p = ProofMarket.Proof({
            inputHash: inputHash,
            outputHash: outputHash,
            payload: payload
        });
        vm.broadcast(pk);
        pm.submitProof(idA, p);
        require(_status(pm, idA) == ProofMarket.TaskStatus.SUBMITTED, "V: A submitted");

        vm.broadcast(vpk);
        pm.vote(idA, true);
        require(_acceptVotes(pm, idA) == 1, "V: A vote");

        vm.broadcast(pk);
        pm.settle(idA);
        require(_status(pm, idA) == ProofMarket.TaskStatus.FINALIZED, "V: A finalized");
        require(!pm.banned(deployer), "V: A not banned");
        // 证明者（=本账户）取回 reward-fee=0.995；手续费 0.005 归 accept 验证者（本账户）
        console2.log("  A finalized, prover payout = reward - fee");

        // ---- 4. 反例：reject → 罚没 + 禁赛 ----
        bytes32 inputB = keccak256("f(x)=sqrt(x) malicious");
        vm.broadcast(pk);
        uint256 idB = pm.createTask{value: 0.003 ether}(
            2, 0x72, ProofMarket.ProofPath.ZK, inputB, bytes32(0), block.timestamp + 86400
        );
        ProofMarket.Proof memory pB = ProofMarket.Proof({
            inputHash: inputB,
            outputHash: keccak256("fake result"),
            payload: payload
        });
        vm.broadcast(pk);
        pm.submitProof(idB, pB); // 假造 output（任务无期望输出，放行后被验证者识破）

        vm.broadcast(vpk);
        pm.vote(idB, false);
        vm.broadcast(pk);
        pm.settle(idB);
        require(_status(pm, idB) == ProofMarket.TaskStatus.SLASHED, "V: B slashed");
        require(pm.proverStakes(deployer) == 0, "V: B stake zeroed");
        require(pm.banned(deployer), "V: B banned");

        // ---- 5. 记录后续验证所需状态（禁赛提交拒绝由链下 cast 精确测试）----
        vm.broadcast(pk);
        uint256 idC = pm.createTask{value: 0.001 ether}(
            3, 0x73, ProofMarket.ProofPath.TEE, inputB, bytes32(0), block.timestamp + 86400
        );
        require(_status(pm, idC) == ProofMarket.TaskStatus.OPEN, "V: C open");
        console2.log("  idC:", idC);

        console2.log("ProofMarket verify OK @", pmAddr);
        console2.log("  taskA:", uint256(_status(pm, idA)), "(FINALIZED)");
        console2.log("  taskB:", uint256(_status(pm, idB)), "(SLASHED)");
        console2.log("  banned(prover):", pm.banned(deployer));
    }
}