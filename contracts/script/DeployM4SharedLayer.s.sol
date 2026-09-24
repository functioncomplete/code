// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DSU} from "../src/DSU.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {PrimitiveSelector} from "../src/PrimitiveSelector.sol";

/// @notice v2 M4 共享层：DSU 登记 + 双原语身份登记 + 原语选择器（Sepolia 批量部署）
contract DeployM4SharedLayer is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOY_PRIVATE_KEY");
        vm.startBroadcast(pk);

        DSU dsu = new DSU();
        console2.log("DSU_REGISTRY:", address(dsu));
        console2.log("DSU_OWNER:", dsu.owner());

        IdentityRegistry reg = new IdentityRegistry();
        console2.log("IDENTITY_REGISTRY:", address(reg));
        console2.log("IDR_OWNER:", reg.owner());

        PrimitiveSelector sel = new PrimitiveSelector();
        console2.log("PRIMITIVE_SELECTOR:", address(sel));

        vm.stopBroadcast();
    }
}