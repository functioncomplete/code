// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { GateEngine } from "../src/GateEngine.sol";
import { DSURuntime } from "../src/DSURuntime.sol";
import { HybridChain } from "../src/HybridChain.sol";
import { DSU } from "../src/DSU.sol";
import { NB } from "../test/helpers/NetBuilder.sol";

/// @title DeployM5 — 逻辑原语引擎 + DSU 执行引擎 + 混合链的 Sepolia 部署
/// @notice 复用 M4 的 DSU 登记（owner = 部署账户），新增本次三个合约并端到端自证。
/// 用法（目标机）：
///   export PATH="$HOME/.foundry/bin:$PATH"; set -a; . ~/.fct-sepolia.env; set +a
///   M4_DSU=0xc125bde16E8A470aaCdfF7FdFF2fa7a5f06869BE \
///   forge script script/DeployM5GateEngine.s.sol --rpc-url "$SEPOLIA_RPC" \
///     --private-key "$DEPLOY_PRIVATE_KEY" --broadcast
contract DeployM5 is Script {
    function run() external {
        address dsuAddr = vm.envOr("M4_DSU", address(0xc125bde16E8A470aaCdfF7FdFF2fa7a5f06869BE));

        vm.startBroadcast();

        GateEngine ge = new GateEngine();
        DSURuntime rt = new DSURuntime(DSU(dsuAddr));
        HybridChain hc = new HybridChain(ge, rt);

        // 登记与 gatelang adder4 同构的 ADD4 逻辑原语 IR （60 NAND / 深度 19）
        (uint32[] memory prog, uint16[] memory outs, uint16[] memory nexts, uint32 depth) = NB.buildAdd4();
        bytes32 fnId = ge.registerFunction(8, 0, prog, outs, nexts, depth);

        // 登记 ARITH DSU（模 16，与 4 位加法同域）
        bytes32 dsuId = DSU(dsuAddr).registerDSU(
            DSU.DSUType.ARITH, keccak256("arith-ref-v1"), keccak256("mod16"), bytes32(0), address(0), 1000
        );

        // 端到端自证：5 + 4 → 逻辑原语 9、DSU 9 → VERIFIED 且写入状态槽
        uint256 inBits = uint256(5) | (uint256(4) << 4);
        bytes memory dsuInput =
            abi.encodePacked(uint8(0), bytes32(uint256(5)), bytes32(uint256(4)), bytes32(uint256(16)));
        (, HybridChain.Status st, uint256 dr, uint256 gr) = hc.execute(fnId, dsuId, inBits, 0, dsuInput, 0x0F);
        require(st == HybridChain.Status.VERIFIED, "chain not verified");
        require(dr == 9 && gr == 9, "unexpected result");

        // 负例：模 7 应 REJECTED 且不写槽
        (bool agree,,,) = hc.preview(fnId, dsuId, inBits, 0, abi.encodePacked(uint8(0), bytes32(uint256(5)), bytes32(uint256(4)), bytes32(uint256(7))), 0x0F);
        require(!agree, "expected mismatch");

        vm.stopBroadcast();

        console2.log("=== M5 DEPLOYED ===");
        console2.log("GateEngine   ", address(ge));
        console2.log("DSURuntime   ", address(rt));
        console2.log("HybridChain  ", address(hc));
        console2.log("fnId (ADD4)  ", vm.toString(fnId));
        console2.log("dsuId (ARITH)", vm.toString(dsuId));
    }
}
