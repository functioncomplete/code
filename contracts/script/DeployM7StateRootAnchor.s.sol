// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { StateRootAnchor, ILiquidationAdapter } from "../src/StateRootAnchor.sol";
import { BinaryMerkle } from "../src/lib/BinaryMerkle.sol";

/// @dev 清算适配器演示桩。
contract DemoAdapter is ILiquidationAdapter {
    uint256 public calls;
    event AdapterCalled(uint256 chainId, uint64 height, bytes32 root);

    function onLiquidation(uint256 chainId, uint64 height, bytes32 root, bytes32, uint256, bytes calldata) external {
        calls += 1;
        emit AdapterCalled(chainId, height, root);
    }
}

/// @title DeployM7 — M7 跨链适配器（StateRootAnchor）的 Sepolia 部署 + 端到端自证
/// @notice 演示：单验证者（部署账户）共识 → 锚定远端根 → 成员证明 → 清算回调。
///         多验证者 >2/3 的完整博弈由合约测试覆盖（本脚本只需演示链路可用）。
/// 用法（目标机）：
///   export PATH="$HOME/.foundry/bin:$PATH"; set -a; . ~/.fct-sepolia.env; set +a
///   forge script script/DeployM7StateRootAnchor.s.sol \
///     --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOY_PRIVATE_KEY" --broadcast
contract DeployM7 is Script {
    uint256 internal constant TREE_DEPTH = 32;

    function run() external {
        uint256 pk = vm.envUint("DEPLOY_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 remoteChainId = 1; // 演示：锚定主网链 ID
        uint64 height = 20_000_000;

        vm.startBroadcast();

        StateRootAnchor sa = new StateRootAnchor();
        DemoAdapter ad = new DemoAdapter();
        sa.setValidator(deployer, 1, true);
        sa.setAdapter(address(ad), true);

        // 远端根：单叶树，leaf 承诺 payload（合约强制 keccak256(payload) == leaf）
        bytes memory payload = bytes("demo-payload");
        bytes32 leaf = keccak256(payload);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        bytes32 root = BinaryMerkle.computeRoot(leaves, TREE_DEPTH);

        // 域分离摘要（含验证者集合代次）+ 部署账户签名（签名者地址严格升序；单个即平凡升序）
        uint64 epoch = sa.validatorEpoch();
        bytes32 digest = keccak256(abi.encode(block.chainid, address(sa), remoteChainId, height, root, epoch));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sigs = abi.encodePacked(r, s, v);

        sa.submitRoot(remoteChainId, height, root, epoch, sigs);
        (bytes32 gotRoot, uint64 gotHeight,, bool set) = sa.latestRemote(remoteChainId);
        require(set && gotRoot == root && gotHeight == height, "anchor failed");

        // 轻客户端：包含证明
        bytes32[] memory proof = new bytes32[](TREE_DEPTH);
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            proof[i] = BinaryMerkle.emptySubtree(i);
        }
        require(sa.verifyInclusion(remoteChainId, leaf, 0, proof), "inclusion failed");

        // 出向：导出本地根
        bytes32 localRoot = keccak256("local-root");
        sa.exportLocalRoot(remoteChainId, height, localRoot);

        // 清算回调
        sa.liquidate(remoteChainId, address(ad), payload, leaf, 0, proof);
        require(ad.calls() == 1, "adapter not called");

        vm.stopBroadcast();

        console2.log("=== M7 DEPLOYED ===");
        console2.log("StateRootAnchor", address(sa));
        console2.log("DemoAdapter    ", address(ad));
        console2.log("validator      ", deployer);
        console2.log("anchored root  ", vm.toString(root));
        console2.log("height         ", height);
        console2.log("quorumThreshold", sa.quorumThreshold());
    }
}
