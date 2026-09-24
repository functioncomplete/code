// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Container} from "./Container.sol";

/// @title ContainerNFT — 容器 NFT（ERC-721）
/// @notice 一枚容器 NFT 拥有一枚 Container 账户（白皮书 §4.1）。mint 时创建
///         Container 实例并绑定；NFT 转移时调用 Container.onNFTTransfer(newAdmin)，
///         容器内资产、服务、管理权、收益随之转移。
/// @dev 手写最小 ERC-721（零外部依赖，借 1.0 FunctionNFT 模式）。
interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract ContainerNFT {
    // ------------------------------------------------------------------
    // ERC-721 元数据
    // ------------------------------------------------------------------
    string public name = "FunctionComplete Container";
    string public symbol = "FCT-CNT";

    // ------------------------------------------------------------------
    // ERC-721 状态（tokenId 从 1 开始）
    // ------------------------------------------------------------------
    uint256 private _tokenIdCounter = 1;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // ------------------------------------------------------------------
    // FCT 特有状态
    // ------------------------------------------------------------------
    /// @notice tokenId → 容器实例地址
    mapping(uint256 => address) public containerOf;

    // ------------------------------------------------------------------
    // 事件
    // ------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event ContainerCreated(uint256 indexed tokenId, address indexed container, address indexed creator);

    // ------------------------------------------------------------------
    // 铸造
    // ------------------------------------------------------------------
    /// @notice 铸造容器 NFT 并创建容器实例
    /// @return tokenId 新容器 NFT id
    /// @return container 新容器实例地址
    function mint() external returns (uint256 tokenId, address container) {
        tokenId = _tokenIdCounter;
        _tokenIdCounter += 1;

        container = address(new Container(address(this), tokenId, msg.sender));

        _owners[tokenId] = msg.sender;
        _balances[msg.sender] += 1;
        containerOf[tokenId] = container;

        emit Transfer(address(0), msg.sender, tokenId);
        emit ContainerCreated(tokenId, container, msg.sender);
    }

    // ------------------------------------------------------------------
    // ERC-721 核心接口
    // ------------------------------------------------------------------
    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ContainerNFT: nonexistent token");
        return owner;
    }

    function balanceOf(address owner) public view returns (uint256) {
        require(owner != address(0), "ContainerNFT: zero address");
        return _balances[owner];
    }

    function approve(address to, uint256 tokenId) public {
        address owner = ownerOf(tokenId);
        require(to != owner, "ContainerNFT: self-approve");
        require(msg.sender == owner || isApprovedForAll(owner, msg.sender), "ContainerNFT: not authorized");
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) public {
        require(operator != msg.sender, "ContainerNFT: self-operator");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "ContainerNFT: not approved");
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "ContainerNFT: not approved");
        _transfer(from, to, tokenId);
        require(
            _checkOnERC721Received(from, to, tokenId, data),
            "ContainerNFT: transfer to non-ERC721Receiver"
        );
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------
    function _transfer(address from, address to, uint256 tokenId) internal {
        require(ownerOf(tokenId) == from, "ContainerNFT: transfer from incorrect owner");
        require(to != address(0), "ContainerNFT: transfer to zero");

        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        // 关键联动：容器管理员跟随 NFT 转移（白皮书 §4.1）
        Container(payable(containerOf[tokenId])).onNFTTransfer(to);

        emit Transfer(from, to, tokenId);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = ownerOf(tokenId);
        return spender == owner || isApprovedForAll(owner, spender) || getApproved(tokenId) == spender;
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data)
        internal
        returns (bool)
    {
        if (to.code.length == 0) return true; // EOA，无需回调
        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (
            bytes4 retval
        ) {
            return retval == IERC721Receiver.onERC721Received.selector;
        } catch {
            return false;
        }
    }
}