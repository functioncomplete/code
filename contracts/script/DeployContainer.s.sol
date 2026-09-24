// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ContainerNFT} from "../src/ContainerNFT.sol";

/// @notice v2 M1 容器组件部署脚本（Sepolia）
/// @dev 部署 ContainerNFT + 铸造演示容器。
///      依赖环境变量：DEPLOY_PRIVATE_KEY（加载自 ~/.fct-sepolia.env 由 python 包装注入）
contract DeployContainer is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOY_PRIVATE_KEY");
        vm.startBroadcast(pk);

        ContainerNFT containerNFT = new ContainerNFT();
        console2.log("ContainerNFT:", address(containerNFT));

        // 铸造演示容器（部署账户即创建者/管理员）
        (uint256 tokenId, address container) = containerNFT.mint();
        console2.log("Container:", container);
        console2.log("ContainerTokenId:", tokenId);

        vm.stopBroadcast();
    }
}