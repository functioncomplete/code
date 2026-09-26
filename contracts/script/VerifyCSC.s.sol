// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CSC} from "../src/CSC.sol";
import {ContainerNFT} from "../src/ContainerNFT.sol";
import {BinaryMerkle} from "../src/lib/BinaryMerkle.sol";

/// @notice v2 M2 CSC 链上验证脚本（真实交易；任何断言失败 => 整笔交易回滚）。
/// @dev CSC 以 ContainerNFT.ownerOf 授权 submitState，故验证须先铸造容器。
///   用法（需 CSC_ADDRESS 与 CONTAINER_NFT_ADDRESS 指向同一部署批次的实例）：
///   CSC_ADDRESS=<addr> CONTAINER_NFT_ADDRESS=<addr> forge script script/VerifyCSC.s.sol \
///     --rpc-url <rpc> --broadcast --private-key <pk>
contract VerifyCSC is Script {
    function run() external {
        address cscAddr = vm.envAddress("CSC_ADDRESS");
        CSC csc = CSC(cscAddr);
        ContainerNFT nft = ContainerNFT(vm.envAddress("CONTAINER_NFT_ADDRESS"));
        uint256 pk = vm.envUint("DEPLOY_PRIVATE_KEY");

        // ---- 1. 部署参数回读 ----
        require(csc.TREE_DEPTH() == 32, "V: depth");
        require(csc.EPOCH_LEN() == 3600, "V: epochLen");
        require(csc.MAX_HOT() == 100000, "V: maxHot");
        require(csc.GRACE_EPOCHS() == 24, "V: grace");
        require(csc.BASE_RENT() == 1000 gwei, "V: baseRent");
        require(csc.containerNFT() == address(nft), "V: nft wiring");

        // ---- 2. genesis 一致性（针对全新部署）----
        require(csc.hotCount() == 0, "V: hot0");
        uint256 epoch = csc.currentEpoch();
        require(csc.lastCheckpointEpoch() == epoch, "V: checkpoint");
        require(csc.currentRoot() == BinaryMerkle.emptySubtree(32), "V: genesis root");
        require(csc.historyRoot(epoch) == csc.currentRoot(), "V: history genesis");

        // ---- 3. 铸造 demo 容器（owner=广播账户）并提交其状态 ----
        // 空树包含证明 = Z[0..31]；fresh 部署下 mint 返回 tokenId=1，路径 sibling 全空。
        bytes32[] memory z = BinaryMerkle.emptySubtrees(32);
        bytes32[] memory proof = new bytes32[](32);
        for (uint256 i = 0; i < 32; i++) proof[i] = z[i];
        bytes32 dataHash = keccak256("FCT CSC demo state v1");

        vm.startBroadcast(pk);
        (uint256 idx, ) = nft.mint();
        csc.submitState(idx, dataHash, proof, false); // 授权：ownerOf(idx) == 广播账户
        vm.stopBroadcast();

        // ---- 4. 客户端包含证明（冷热无关，独立可验证）----
        require(csc.verifyInclusion(dataHash, idx, proof), "V: verify ok");
        require(!csc.verifyInclusion(keccak256("tampered"), idx, proof), "V: tamper rejected");
        (bytes32 storedHash, , , , ) = csc.containers(bytes32(idx));
        require(storedHash == dataHash, "V: leaf stored");
        require(csc.hotCount() == 1, "V: hot+1");

        console2.log("CSC verify OK @", cscAddr);
        console2.log("  idx:", idx);
        console2.log("  root:", vm.toString(csc.currentRoot()));
        console2.log("  hotCount:", csc.hotCount());
    }
}
