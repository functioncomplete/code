// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { HybridGate } from "../src/HybridGate.sol";

/// @title DeployM6 — M6 混合模式（HybridGate）的 Sepolia 部署
/// @notice DSU 执行 → 逻辑原语验证锚重放 → 容器状态更新/罚没 的乐观证明链。
///         gateId 直接复用 M5 逻辑原语引擎登记的 ADD4 `fnId`，把 M6 与 M5 的身份锚绑定。
/// 用法（目标机）：
///   export PATH="$HOME/.foundry/bin:$PATH"; set -a; . ~/.fct-sepolia.env; set +a
///   M5_FN_ID=0x3318... forge script script/DeployM6HybridGate.s.sol \
///     --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOY_PRIVATE_KEY" --broadcast
contract DeployM6 is Script {
    uint8 internal constant MODULE_ADD4 = 1;
    uint8 internal constant MODULE_CMP4 = 2;

    function run() external {
        bytes32 add4GateId = vm.envOr(
            "M5_FN_ID",
            bytes32(0x3318e947f184459cfff746c8fc79e5cb2a0596fde8a44360fce8ddac24e62ad2)
        );
        bytes32 cmp4GateId = vm.envOr("M5_CMP_FN_ID", keccak256("nand-cmp4-net-v1"));
        bytes32 dsuId = vm.envOr(
            "M5_DSU_ID",
            bytes32(0x1884de5f8d2a5163f1479bf300ccd25387070c981f489ae2331241240733cdf7)
        );

        vm.startBroadcast();

        HybridGate hg = new HybridGate();
        hg.registerModule(MODULE_ADD4, add4GateId, 60, 19);
        hg.registerModule(MODULE_CMP4, cmp4GateId, 58, 20);

        // 正例：5 + 4 → DSU 提交 9 → 逻辑原语重放 9 → VERIFIED
        uint64 okReq = hg.createRequest{ value: 0.0005 ether }(add4GateId, dsuId, MODULE_ADD4, 5, 4);
        hg.submitDsuOutputV2(okReq, 9, 1);
        hg.verifyByGate(okReq);
        require(hg.requestStatus(okReq) == HybridGate.Status.VERIFIED, "expected VERIFIED");

        // 负例：DSU 提交错误结果 10 → REJECTED（罚没 50% 给触发验证者、余款归 owner）
        uint64 badReq = hg.createRequest{ value: 0.0005 ether }(add4GateId, dsuId, MODULE_ADD4, 5, 4);
        hg.submitDsuOutputV2(badReq, 10, 1);
        hg.verifyByGate(badReq);
        require(hg.requestStatus(badReq) == HybridGate.Status.REJECTED, "expected REJECTED");

        // 逻辑原语直查交叉验证
        (uint16 gv,) = hg.gateEval(MODULE_ADD4, 5, 4);
        require(gv == 9, "gate eval");

        vm.stopBroadcast();

        console2.log("=== M6 DEPLOYED ===");
        console2.log("HybridGate   ", address(hg));
        console2.log("add4GateId   ", vm.toString(add4GateId));
        console2.log("okReq        ", okReq);
        console2.log("badReq       ", badReq);
    }
}
