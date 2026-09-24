// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CSC} from "../src/CSC.sol";

/// @notice v2 M2 CSC 组件部署脚本（Sepolia）
/// @dev 部署 CSC（压缩状态承诺：二进制 Merkle 树 + 状态租金）。
///      原型参数（白皮书 v1.2 §4.2–4.3 无固定数值，取原合理值）：
///        depth=32     -> 2^32 容器（Container ID 上限）
///        epochLen=3600-> 1 小时分区
///        maxHot=100000-> 热状态容量上限（利用率定价基准）
///        grace=24     -> 24 小时宽限后可驱逐
///        baseRent=1000 gwei/epoch
contract DeployCSC is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOY_PRIVATE_KEY");
        vm.startBroadcast(pk);

        CSC csc = new CSC(32, 3600, 100000, 24, 1000 gwei);
        console2.log("CSC:", address(csc));
        console2.log("CSC_TREE_DEPTH:", csc.TREE_DEPTH());
        console2.log("CSC_EPOCH_LEN:", csc.EPOCH_LEN());
        console2.log("CSC_MAX_HOT:", csc.MAX_HOT());
        console2.log("CSC_GRACE_EPOCHS:", csc.GRACE_EPOCHS());
        console2.log("CSC_BASE_RENT:", csc.BASE_RENT());

        vm.stopBroadcast();
    }
}