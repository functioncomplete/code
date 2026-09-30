// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DSU} from "../src/DSU.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {PrimitiveSelector} from "../src/PrimitiveSelector.sol";

contract DSUTest is Test {
    DSU internal dsu;
    address internal owner;
    address internal alice;
    address internal bob;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        dsu = new DSU();
    }

    bytes32 internal vh = keccak256("sha256-v4");
    bytes32 internal ph = keccak256("dom=F_2^64 fixed-8");
    bytes32 internal mz = bytes32(0);
    bytes32 internal model = keccak256("cnn-q8");

    function testRegisterHashDSU() public {
        bytes32 id = dsu.registerDSU(DSU.DSUType.HASH, vh, ph, mz, address(0), 1_000_000);
        assertTrue(id != bytes32(0));
        (DSU.DSUType t, , , , , uint256 maxSteps, bool reg) = dsu.records(id);
        assertEq(uint8(t), uint8(DSU.DSUType.HASH));
        assertEq(maxSteps, 1_000_000);
        assertTrue(reg);
        // 预算检查
        assertEq(dsu.getBudget(id), 1_000_000);
        assertEq(uint8(dsu.classify(id)), uint8(DSU.DSUType.HASH));
    }

    function testRejectDupAndZero() public {
        dsu.registerDSU(DSU.DSUType.HASH, vh, ph, mz, address(0), 1_000_000);
        vm.expectRevert(bytes("dup"));
        dsu.registerDSU(DSU.DSUType.HASH, vh, ph, mz, address(0), 1_000_000);
        vm.expectRevert();
        dsu.registerDSU(DSU.DSUType.STATE_MACHINE, bytes32(0), ph, mz, address(0), 100);
        vm.expectRevert(bytes("steps 0"));
        dsu.registerDSU(DSU.DSUType.ML, vh, ph, model, address(0), 0);
    }

    function testVersionBumpIsNewIdentity() public {
        bytes32 v1 = dsu.registerDSU(DSU.DSUType.HASH, vh, ph, mz, address(0), 1_000_000);
        bytes32 v2 = dsu.registerDSU(DSU.DSUType.HASH, keccak256("sha256-v5"), ph, mz, address(0), 1_000_000);
        assertTrue(v1 != v2);
        // 参数哈希变化也是新身份
        bytes32 v3 = dsu.registerDSU(DSU.DSUType.HASH, vh, keccak256("dom=F_2^64 fixed-16"), mz, address(0), 1_000_000);
        assertTrue(v1 != v3);
    }

    function testModelCIDMakesDistinctMLDSU() public {
        bytes32 plain = dsu.registerDSU(DSU.DSUType.ML, vh, ph, mz, address(0), 1_000_000);
        bytes32 withModel = dsu.registerDSU(DSU.DSUType.ML, vh, ph, model, address(0), 1_000_000);
        assertTrue(plain != withModel);
    }

    function testConsumeStepsWithinBudget() public {
        bytes32 id = dsu.registerDSU(DSU.DSUType.ARITH, vh, ph, mz, address(0), 500);
        vm.prank(alice);
        assertTrue(dsu.consumeSteps(id, 500));
        vm.prank(alice);
        assertTrue(dsu.consumeSteps(id, 1));
    }

    function testConsumeStepsOverflowReverts() public {
        bytes32 id = dsu.registerDSU(DSU.DSUType.STATE_MACHINE, vh, ph, mz, address(0), 100);
        vm.expectRevert(bytes("budget exceeded"));
        dsu.consumeSteps(id, 101);
    }

    function testConsumeUnknownReverts() public {
        vm.expectRevert(bytes("unknown"));
        dsu.consumeSteps(keccak256("ghost"), 1);
    }

    function testOnlyOwnerRegister() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not owner"));
        dsu.registerDSU(DSU.DSUType.HASH, vh, ph, mz, address(0), 100);
    }

    function testUpdateImpl() public {
        bytes32 id = dsu.registerDSU(DSU.DSUType.SIGN, vh, ph, mz, address(0), 1_000);
        dsu.updateImpl(id, alice);
        ( , , , , address impl, , ) = dsu.records(id);
        assertEq(impl, alice);
        vm.prank(bob);
        vm.expectRevert(bytes("not owner"));
        dsu.updateImpl(id, bob);
    }

    function testCostModelNotes() public view {
        assertEq(dsu.costModelNote(DSU.DSUType.HASH), keccak256("per-hash + per-byte"));
        assertEq(dsu.costModelNote(DSU.DSUType.ML), keccak256("per-layer FLOPs (quantized)"));
        assertEq(dsu.costModelNote(DSU.DSUType.SIGN), keccak256("per-signature + batch discount"));
        assertEq(dsu.costModelNote(DSU.DSUType.ARITH), keccak256("per-field-op"));
        assertEq(dsu.costModelNote(DSU.DSUType.STATE_MACHINE), keccak256("per-step"));
    }
}

contract IdentityRegistryTest is Test {
    IdentityRegistry internal reg;
    address internal owner;
    bytes32 internal netHashA = keccak256("nand-net:adder4-v1");
    bytes32 internal netHashB = keccak256("nand-net:sha-round-v1");
    bytes32 internal ioSpec = keccak256("(Bits<4>,Bits<4>)->(Bits<4>,Bit)");
    bytes32 internal dsuVh = keccak256("eddsa-bn254-v2");
    bytes32 internal dsuPh = keccak256("field=bn254");
    bytes32 internal model = keccak256("cnn-q8");

    function setUp() public {
        owner = address(this);
        reg = new IdentityRegistry();
    }

    function testRegisterGate() public {
        reg.registerGate(netHashA, ioSpec, 36, 9, 250, makeAddr("creator"), keccak256("gateproof"));
        (bool ok, address o, uint32 g, uint16 r) = reg.checkGate(netHashA);
        assertTrue(ok);
        assertEq(o, makeAddr("creator"));
        assertEq(g, 36);
        assertEq(r, 250);
        assertEq(reg.identityKind(netHashA), 1);
    }

    function testRegisterDSUIdentity() public {
        bytes32 id = reg.registerDSU(DSU.DSUType.SIGN, dsuVh, dsuPh, model, 500, makeAddr("dsuDev"), keccak256("dsuproof"));
        (bool ok, address o, uint16 r) = reg.checkDSU(id);
        assertTrue(ok);
        assertEq(o, makeAddr("dsuDev"));
        assertEq(r, 500);
        assertEq(reg.identityKind(id), 2);
    }

    function testDsuIdMatchesDsuContract() public {
        // 回归：IdentityRegistry 与 DSU.sol 必须派生同一 dsuId（跨合约身份锚），
        // 否则登记层的版税/依赖与执行层永不交集。
        bytes32 vh = keccak256("ver");
        bytes32 ph = keccak256("par");
        bytes32 mc = keccak256("model");
        DSU d0 = new DSU();
        bytes32 idA = d0.registerDSU(DSU.DSUType.HASH, vh, ph, mc, address(0), 1000);
        bytes32 idB = reg.registerDSU(DSU.DSUType.HASH, vh, ph, mc, 0, address(this), keccak256("dsuproof"));
        assertEq(idA, idB, "dsuId derivation mismatch across contracts");
    }

    function testProofHashBoundToIdentity() public {
        // v1.4 §3.4/§6.4：形式化验证证明（spec/gateproof）须与身份绑定，可先验证
        bytes32 gproof = keccak256("gateproof-v1");
        reg.registerGate(netHashA, ioSpec, 36, 9, 250, makeAddr("creator"), gproof);
        assertEq(reg.gateProofOf(netHashA), gproof);

        bytes32 dproof = keccak256("dsuproof-v1");
        bytes32 d = reg.registerDSU(DSU.DSUType.SIGN, dsuVh, dsuPh, model, 500, makeAddr("dsuDev"), dproof);
        assertEq(reg.dsuProofOf(d), dproof);
    }

    function testDepsCapEnforced() public {
        // royaltySchedule 有界：单身份依赖数不超过 MAX_DEPS
        bytes32 parent = reg.registerGate(netHashA, ioSpec, 36, 9, 250, makeAddr("c"), keccak256("gateproof"));
        for (uint256 i = 0; i < reg.MAX_DEPS(); i++) {
            bytes32 child = keccak256(abi.encode("child", i));
            reg.registerGate(child, ioSpec, 1, 1, 0, makeAddr("c"), keccak256("gateproof"));
            reg.linkDependency(parent, child, 100);
        }
        bytes32 extra = keccak256("extra-child");
        reg.registerGate(extra, ioSpec, 1, 1, 0, makeAddr("c"), keccak256("gateproof"));
        vm.expectRevert("too many deps");
        reg.linkDependency(parent, extra, 100);
    }

    function testDupGateReverts() public {
        reg.registerGate(netHashA, ioSpec, 36, 9, 250, makeAddr("creator"), keccak256("gateproof"));
        vm.expectRevert(bytes("dup gate"));
        reg.registerGate(netHashA, ioSpec, 40, 10, 250, makeAddr("other"), keccak256("gateproof"));
    }

    function testLinkRoyaltySchedule() public {
        bytes32 g = reg.registerGate(netHashA, ioSpec, 36, 9, 300, makeAddr("creator"), keccak256("gateproof"));
        bytes32 d = reg.registerDSU(DSU.DSUType.SIGN, dsuVh, dsuPh, model, 500, makeAddr("dsuDev"), keccak256("dsuproof"));
        reg.linkDependency(g, d, 400); // adder4 依赖 eddsa DSU，40% 分成
        (bytes32[] memory ids, uint16[] memory shares) = reg.royaltySchedule(g);
        assertEq(ids.length, 1);
        assertEq(ids[0], d);
        assertEq(shares[0], 400);
        assertEq(reg.combinedRoyaltyBps(g), 300);
    }

    function testRoyaltyScheduleHidesDisabled() public {
        bytes32 g = reg.registerGate(netHashA, ioSpec, 36, 9, 300, makeAddr("creator"), keccak256("gateproof"));
        bytes32 d = reg.registerDSU(DSU.DSUType.SIGN, dsuVh, dsuPh, model, 500, makeAddr("dsuDev"), keccak256("dsuproof"));
        reg.linkDependency(g, d, 400);
        reg.disableDependency(g, 0);
        (bytes32[] memory ids, ) = reg.royaltySchedule(g);
        assertEq(ids.length, 0);
    }

    function testLinkConstraints() public {
        bytes32 g = reg.registerGate(netHashA, ioSpec, 36, 9, 300, makeAddr("creator"), keccak256("gateproof"));
        vm.expectRevert(bytes("self dep"));
        reg.linkDependency(g, g, 100);
        vm.expectRevert(bytes("unknown parent"));
        reg.linkDependency(keccak256("ghost"), g, 100);
        // share 超限但 child 也未知：合约先检查 child 已知性，用已登记 DSU 测试 share 校验
        bytes32 d = reg.registerDSU(DSU.DSUType.SIGN, dsuVh, dsuPh, model, 500, makeAddr("dsuDev"), keccak256("dsuproof"));
        vm.expectRevert(bytes("share"));
        reg.linkDependency(g, d, 10_001);
    }

    function testUnknownIdentityKind() public {
        assertEq(reg.identityKind(keccak256("unknown")), 0);
    }
}

contract PrimitiveSelectorTest is Test {
    PrimitiveSelector internal sel;

    function setUp() public {
        sel = new PrimitiveSelector();
    }

    function testOfficialSamples() public {
        for (uint8 i = 0; i < 8; i++) {
            (PrimitiveSelector.Requirements memory r, PrimitiveSelector.Primitive expected) = sel.ruleTableSample(i);
            PrimitiveSelector.Recommendation memory got = sel.recommend(r);
            assertEq(uint8(got.primitive), uint8(expected), "sample mismatch");
        }
    }

    function testAIDedicated() public {
        PrimitiveSelector.Recommendation memory rec = sel.recommend(
            PrimitiveSelector.Requirements(false, false, true, false)
        );
        assertEq(uint8(rec.primitive), uint8(PrimitiveSelector.Primitive.DSU));
        assertEq(rec.confidence, 100);
        assertEq(rec.reason, keccak256("high-perf-dsu"));
    }

    function testFormalDefaultGate() public {
        PrimitiveSelector.Recommendation memory rec = sel.recommend(
            PrimitiveSelector.Requirements(true, false, false, false)
        );
        assertEq(uint8(rec.primitive), uint8(PrimitiveSelector.Primitive.GATE));
    }

    function testSafeDefault() public {
        PrimitiveSelector.Recommendation memory rec = sel.recommend(
            PrimitiveSelector.Requirements(false, false, false, false)
        );
        assertEq(uint8(rec.primitive), uint8(PrimitiveSelector.Primitive.GATE));
        assertEq(rec.confidence, 60);
    }

    function testRWAComplianceHybrid() public {
        PrimitiveSelector.Recommendation memory rec = sel.recommend(
            PrimitiveSelector.Requirements(true, false, false, true)
        );
        assertEq(uint8(rec.primitive), uint8(PrimitiveSelector.Primitive.HYBRID));
        assertEq(rec.reason, keccak256("RWA-AI-hybrid"));
    }

    function testAIAgentHybrid() public {
        PrimitiveSelector.Recommendation memory rec = sel.recommend(
            PrimitiveSelector.Requirements(false, false, true, true)
        );
        assertEq(uint8(rec.primitive), uint8(PrimitiveSelector.Primitive.HYBRID));
    }

    function testCrossChainGateWinsOverPerfOnly() public {
        // 需要跨链身份（如公共函数库）即使高性能也走逻辑原语
        PrimitiveSelector.Recommendation memory rec = sel.recommend(
            PrimitiveSelector.Requirements(false, true, true, false)
        );
        assertEq(uint8(rec.primitive), uint8(PrimitiveSelector.Primitive.GATE));
    }
}