// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Container.sol";
import "../src/ContainerNFT.sol";

/// @notice M1 容器组件测试：ContainerNFT + Container（白皮书 §4.1）
contract ContainerTest is Test {
    ContainerNFT public cNft;
    Container public container;
    uint256 public tokenId;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        cNft = new ContainerNFT();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        vm.prank(alice);
        (tokenId, ) = cNft.mint();
        container = Container(payable(cNft.containerOf(tokenId)));
    }

    // ------------------------------------------------------------------
    // 创建与绑定
    // ------------------------------------------------------------------
    function test_mint_createsContainerBoundToCaller() public view {
        assertEq(tokenId, 1);
        assertEq(cNft.ownerOf(tokenId), alice);
        assertEq(container.admin(), alice);
        assertEq(address(container), cNft.containerOf(tokenId));
        assertEq(container.nft(), address(cNft));
        assertEq(container.tokenId(), tokenId);
        assertEq(container.beneficiary(), alice); // 默认收益地址 = admin
    }

    // ------------------------------------------------------------------
    // 核心语义：转移容器 NFT → 容器管理员跟随
    // ------------------------------------------------------------------
    function test_transferNFT_movesContainerAdmin() public {
        vm.prank(alice);
        cNft.transferFrom(alice, bob, tokenId);

        assertEq(cNft.ownerOf(tokenId), bob);
        assertEq(container.admin(), bob); // 联动生效
    }

    function test_safeTransferNFT_movesContainerAdmin() public {
        vm.prank(alice);
        cNft.safeTransferFrom(alice, bob, tokenId);
        assertEq(container.admin(), bob);

        vm.prank(bob);
        cNft.transferFrom(bob, alice, tokenId);
        assertEq(container.admin(), alice); // 回归
        assertEq(container.beneficiary(), alice); // 管理员变更后收益地址跟随？不——beneficiary 保持原值
    }

    // ------------------------------------------------------------------
    // 资产：ETH
    // ------------------------------------------------------------------
    function test_receiveAndWithdrawETH() public {
        vm.deal(address(container), 2 ether); // 直接注资

        vm.prank(alice);
        container.withdrawETH(1 ether);
        assertEq(address(container).balance, 1 ether);
        assertEq(alice.balance, 11 ether);
    }

    function test_withdrawETH_notAdmin_reverts() public {
        vm.deal(address(container), 1 ether);
        vm.prank(bob);
        vm.expectRevert("Container: not admin");
        container.withdrawETH(0.5 ether);
    }

    function test_accrueRevenue() public {
        address executor = address(0x5EED);
        vm.deal(executor, 2 ether);
        vm.prank(executor); // 执行节点模拟
        container.accrueRevenue{value: 1 ether}();
        assertEq(container.totalRevenue(), 1 ether);
        assertEq(address(container).balance, 1 ether);
        assertEq(executor.balance, 1 ether);
    }

    // ------------------------------------------------------------------
    // 引用管理
    // ------------------------------------------------------------------
    function test_addRemoveDsuRef() public {
        bytes32 ref = keccak256("dsu-sha256-v1");

        vm.prank(alice);
        container.addDsuRef(ref);
        assertTrue(container.dsuRefs(ref));
        assertEq(container.dsuRefList().length, 1);

        vm.prank(alice);
        container.removeDsuRef(ref);
        assertFalse(container.dsuRefs(ref));
        assertEq(container.dsuRefList().length, 0);
    }

    function test_addRemoveFunctionRef() public {
        bytes32 ref = keccak256("fct-netlist-hash");
        vm.prank(alice);
        container.addFunctionRef(ref);
        assertTrue(container.functionRefs(ref));

        vm.prank(alice);
        container.removeFunctionRef(ref);
        assertFalse(container.functionRefs(ref));
    }

    function test_addDsuRef_duplicate_reverts() public {
        bytes32 ref = keccak256("duplicate");
        vm.prank(alice);
        container.addDsuRef(ref);
        vm.prank(alice);
        vm.expectRevert("Container: dsu ref exists");
        container.addDsuRef(ref);
    }

    function test_addDsuRef_notAdmin_reverts() public {
        vm.prank(bob);
        vm.expectRevert("Container: not admin");
        container.addDsuRef(keccak256("x"));
    }

    // ------------------------------------------------------------------
    // 私有状态（CSC 叶子，M2 接入）
    // ------------------------------------------------------------------
    function test_setPrivateState() public {
        bytes32 c = keccak256("leaf");
        vm.prank(alice);
        container.setPrivateState(c);
        assertEq(container.privateStateCommitment(), c);
    }

    function test_setPrivateState_notAdmin_reverts() public {
        vm.prank(bob);
        vm.expectRevert("Container: not admin");
        container.setPrivateState(keccak256("x"));
    }

    // ------------------------------------------------------------------
    // AI 服务（白皮书 §4.1）
    // ------------------------------------------------------------------
    function test_setAiService() public {
        vm.prank(alice);
        container.setAiService(keccak256("model-v1"), 0.01 ether, bob);
        assertEq(container.modelCID(), keccak256("model-v1"));
        assertEq(container.inferencePrice(), 0.01 ether);
        assertEq(container.beneficiary(), bob);
    }

    function test_payInference_accumulatesRevenueAndRefunds() public {
        vm.prank(alice);
        container.setAiService(keccak256("model"), 1 ether, alice);

        vm.deal(bob, 3 ether);
        vm.prank(bob);
        container.payInference{value: 3 ether}(); // 付 3，价 1 → 收益 1，退 2

        assertEq(container.totalRevenue(), 1 ether);
        assertEq(bob.balance, 2 ether); // 退还多付
        assertEq(address(container).balance, 1 ether);
    }

    function test_payInference_insufficient_reverts() public {
        vm.prank(alice);
        container.setAiService(keccak256("model"), 1 ether, alice);

        vm.deal(bob, 0.5 ether);
        vm.prank(bob);
        vm.expectRevert("Container: insufficient inference fee");
        container.payInference{value: 0.5 ether}();
    }

    function test_payInference_free_whenZeroPrice() public {
        vm.prank(alice);
        container.setAiService(keccak256("free-model"), 0, alice);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        container.payInference{value: 0.1 ether}(); // 免费 + 全退
        assertEq(container.totalRevenue(), 0);
        assertEq(bob.balance, 1 ether);
    }

    function test_setAiService_notAdmin_reverts() public {
        vm.prank(bob);
        vm.expectRevert("Container: not admin");
        container.setAiService(keccak256("x"), 0, bob);
    }

    // ------------------------------------------------------------------
    // ERC-721 标准合规
    // ------------------------------------------------------------------
    function test_erc721_balanceAndApproval() public {
        assertEq(cNft.balanceOf(alice), 1);
        vm.prank(alice);
        cNft.approve(bob, tokenId);
        assertEq(cNft.getApproved(tokenId), bob);

        vm.prank(bob);
        cNft.transferFrom(alice, bob, tokenId);
        assertEq(cNft.ownerOf(tokenId), bob);
        assertEq(container.admin(), bob);
    }

    function test_nft_transfer_requiresApproval() public {
        vm.prank(bob); // bob 无权转移 alice 的 NFT
        vm.expectRevert("ContainerNFT: not approved");
        cNft.transferFrom(alice, bob, tokenId);
    }
}