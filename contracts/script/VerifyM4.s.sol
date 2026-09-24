// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DSU} from "../src/DSU.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {PrimitiveSelector} from "../src/PrimitiveSelector.sol";

/// @notice M4 共享层链上验证：
///   DSU：注册哈希 DSU（真实交易）+ 步数预算消费
///   身份：登记门级函数（真实交易）+ 登记 DSU 身份（真实交易）+ 依赖图链接（真实交易）
///   选择器：8 个官方规则样本只读断言
contract VerifyM4 is Script {
    DSU internal dsu;
    IdentityRegistry internal reg;
    PrimitiveSelector internal sel;

    // 从部署记录读取
    address internal constant DSU_A = 0xc125bde16E8A470aaCdfF7FdFF2fa7a5f06869BE;
    address internal constant IDR_A = 0x9Db91883aC454AeFc7011135118AB14C4F82258b;
    address internal constant SEL_A = 0x0b9B4da2A62eDe51F6C829ca35A1a10271367f78;

    bytes32 internal vh = keccak256("sha256-v4");
    bytes32 internal ph = keccak256("dom=F_2^64 fixed-8");
    bytes32 internal model0 = bytes32(0);
    bytes32 internal netHashA = keccak256("nand-net:adder4-v1");
    bytes32 internal ioSpec = keccak256("(Bits<4>,Bits<4>)->(Bits<4>,Bit)");
    bytes32 internal dsuVh = keccak256("eddsa-bn254-v2");

    function run() external {
        uint256 pk = vm.envUint("DEPLOY_PRIVATE_KEY");
        dsu = DSU(DSU_A);
        reg = IdentityRegistry(IDR_A);
        sel = PrimitiveSelector(SEL_A);

        vm.startBroadcast(pk);

        // 1) DSU 注册（哈希类别）+ 步数消费
        bytes32 dsuId = dsu.registerDSU(DSU.DSUType.HASH, vh, ph, model0, address(0), 1_000_000);
        console2.log(">> DSU register =>", Lib.toString(dsuId));
        dsu.consumeSteps(dsuId, 256);

        // 2) 门级函数身份登记（NAND 网络哈希）
        bytes32 gId = reg.registerGate(netHashA, ioSpec, 36, 9, 250, vm.addr(pk));
        console2.log(">> Gate register =>", Lib.toString(gId));

        // 3) DSU 身份登记（版本+参数）
        bytes32 idDsu = reg.registerDSU(dsuVh, dsuVh, model0, 120, vm.addr(pk));
        console2.log(">> DSU identity register =>", Lib.toString(idDsu));

        // 4) 依赖图：门级函数依赖 DSU（组合版税 40%）
        reg.linkDependency(gId, idDsu, 4000);
        console2.log(">> dependency linked (gate -> dsu, 4000bps)");

        vm.stopBroadcast();

        // ============ 只读断言 ============
        (bool gOk, , uint32 gc, uint16 gr) = reg.checkGate(gId);
        require(gOk && gc == 36 && gr == 250, "gate check fail");

        (bool dOk, , uint16 dr) = reg.checkDSU(idDsu);
        require(dOk && dr == 120, "dsu check fail");

        require(reg.identityKind(gId) == 1, "gate kind");
        require(reg.identityKind(idDsu) == 2, "dsu kind");

        (bytes32[] memory ids, uint16[] memory shares) = reg.royaltySchedule(gId);
        require(ids.length == 1 && ids[0] == idDsu && shares[0] == 4000, "royalty schedule fail");

        // 选择器 8 样本
        for (uint8 i = 0; i < 8; i++) {
            (PrimitiveSelector.Requirements memory r, PrimitiveSelector.Primitive expected) = sel.ruleTableSample(i);
            PrimitiveSelector.Recommendation memory rec = sel.recommend(r);
            require(uint8(rec.primitive) == uint8(expected), "selector sample i fail");
        }
        console2.log("=== ALL ONCHAIN ASSERTIONS PASSED ===");
    }
}

library Lib {
    function toString(bytes32 b) internal pure returns (string memory) {
        bytes memory s = new bytes(64);
        bytes16 symbols = "0123456789abcdef";
        for (uint256 i = 0; i < 32; i++) {
            bytes1 c = b[i];
            s[2 * i] = symbols[uint8(c) >> 4];
            s[2 * i + 1] = symbols[uint8(c) & 0x0f];
        }
        return string(s);
    }
}