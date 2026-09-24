// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CSC} from "../src/CSC.sol";
import {BinaryMerkle} from "../src/lib/BinaryMerkle.sol";

/// @notice v2 M2 CSC 链上验证脚本（真实交易；任何断言失败 => 整笔交易回滚）。
/// @dev 用法：
///   CSC_ADDRESS=<addr> forge script script/VerifyCSC.s.sol \
///     --rpc-url <rpc> --broadcast --private-key <pk>
contract VerifyCSC is Script {
    function run() external {
        address cscAddr = vm.envAddress("CSC_ADDRESS");
        CSC csc = CSC(cscAddr);

        // ---- 1. 部署参数回读 ----
        require(csc.TREE_DEPTH() == 32, "V: depth");
        require(csc.EPOCH_LEN() == 3600, "V: epochLen");
        require(csc.MAX_HOT() == 100000, "V: maxHot");
        require(csc.GRACE_EPOCHS() == 24, "V: grace");
        require(csc.BASE_RENT() == 1000 gwei, "V: baseRent");

        // ---- 2. genesis 一致性 ----
        require(csc.hotCount() == 0, "V: hot0");
        uint256 epoch = csc.currentEpoch();
        require(csc.lastCheckpointEpoch() == epoch, "V: checkpoint");
        require(csc.currentRoot() == BinaryMerkle.emptySubtree(32), "V: genesis root");
        require(csc.historyRoot(epoch) == csc.currentRoot(), "V: history genesis");

        // ---- 3. 提交 demo 状态（空树包含证明 = Z[0..31]）----
        bytes32 dataHash = keccak256("FCT CSC demo state v1");
        uint256 idx = 1;
        bytes32[] memory z = BinaryMerkle.emptySubtrees(32);
        bytes32[] memory proof = new bytes32[](32);
        for (uint256 i = 0; i < 32; i++) proof[i] = z[i];

        csc.submitState(idx, dataHash, proof, false);
        // (submit above must be BROADCAST; the rest of this script reruns
        //  locally against the resulting state to assert the full loop.)

        bytes32 commRoot = csc.currentRoot();
        require(csc.hotCount() == 1, "V: hot+1");
        (bytes32 storedHash, , , bool cold) = csc.containers(bytes32(idx));
        require(storedHash == dataHash, "V: leaf stored");
        require(!cold, "V: hot");

        // ---- 4. 客户端包含证明（冷热无关，独立可验证）----
        // idx=1 路径上的 sibling 全部是左子树（全空）=> 同一 z 证明仍然有效。
        require(csc.verifyInclusion(dataHash, idx, proof), "V: verify ok");
        require(!csc.verifyInclusion(keccak256("tampered"), idx, proof), "V: tamper rejected");

        uint256 cEpoch = csc.currentEpoch();
        bytes32 hRoot = csc.historyRoot(cEpoch);
        require(hRoot == commRoot, "V: history==root");
        console2.log("CSC verify OK @", cscAddr);
        console2.log("  root:", vm.toString(commRoot));
        console2.log("  hotCount:", csc.hotCount());
        console2.log("  historyRoot[", cEpoch, "]:", vm.toString(hRoot));

        // Broadcast the submission as a real on-chain transaction.
        uint256 pk = vm.envUint("DEPLOY_PRIVATE_KEY");
        vm.broadcast(pk);
        csc.submitState(idx, dataHash, proof, false);
    }
}