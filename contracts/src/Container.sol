// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Container — FCT 计算容器账户
/// @notice 容器的核心状态单元（白皮书 §4.1）。每个容器是一枚容器 NFT 持有的链上
///         账户，持有：资产余额、DSU 引用、FCT 函数引用、私有状态承诺、管理权限、
///         AI 服务（模型 CID / 推理价格 / 收益地址）。
/// @dev 管理员（admin）默认跟随容器 NFT 持有者：ContainerNFT 转移时调用
///      onNFTTransfer(newAdmin)，容器内资产、服务、管理权、收益随之转移。
///      经济媒介为 ETHER（FCT 无独立代币）。
contract Container {
    // ------------------------------------------------------------------
    // 身份绑定
    // ------------------------------------------------------------------
    /// @notice 所属 ContainerNFT 合约（不可变绑定）
    address public immutable nft;
    /// @notice 容器 tokenId
    uint256 public immutable tokenId;

    // ------------------------------------------------------------------
    // 管理权限（跟随 NFT 持有者）
    // ------------------------------------------------------------------
    address public admin;

    // ------------------------------------------------------------------
    // 资产（ETHER 媒介）
    // ------------------------------------------------------------------
    /// @notice 累计收益（服务费/调用费，wei）
    uint256 public totalRevenue;
    /// @notice ERC-20 代币余额（允许容器持有稳定币等链资产）
    mapping(address => uint256) public tokenBalances;

    // ------------------------------------------------------------------
    // 引用（该容器允许调用的执行单元与门级函数）
    // ------------------------------------------------------------------
    /// @notice DSU 引用：身份哈希 → 是否启用
    mapping(bytes32 => bool) public dsuRefs;
    /// @notice 门级函数引用：函数 NFT 的 netlistHash → 是否启用
    mapping(bytes32 => bool) public functionRefs;
    bytes32[] private _dsuRefList;
    bytes32[] private _functionRefList;

    // ------------------------------------------------------------------
    // 私有状态（压缩状态承诺叶子，M2 接入 CSC）
    // ------------------------------------------------------------------
    bytes32 public privateStateCommitment;

    // ------------------------------------------------------------------
    // AI 服务（白皮书 §4.1）
    // ------------------------------------------------------------------
    bytes32 public modelCID; // 模型内容标识
    uint256 public inferencePrice; // 每次推理费用（wei）
    address public beneficiary; // AI 服务收益地址（默认 admin）

    // ------------------------------------------------------------------
    // 事件
    // ------------------------------------------------------------------
    event AdminChanged(address indexed newAdmin);
    event DsuRefAdded(bytes32 indexed ref, uint256 count);
    event DsuRefRemoved(bytes32 indexed ref, uint256 count);
    event FunctionRefAdded(bytes32 indexed ref, uint256 count);
    event FunctionRefRemoved(bytes32 indexed ref, uint256 count);
    event PrivateStateUpdated(bytes32 indexed commitment);
    event AiServiceSet(bytes32 modelCID, uint256 inferencePrice, address indexed beneficiary);
    event RevenueAccrued(address indexed source, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);
    event PaidInference(address indexed payer, uint256 amount, uint256 refund);

    // ------------------------------------------------------------------
    // 构造
    // ------------------------------------------------------------------
    constructor(address _nft, uint256 _tokenId, address _admin) {
        require(_nft != address(0), "Container: zero NFT");
        require(_admin != address(0), "Container: zero admin");
        nft = _nft;
        tokenId = _tokenId;
        admin = _admin;
        beneficiary = _admin;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Container: not admin");
        _;
    }

    // ------------------------------------------------------------------
    // 权限联动：NFT 转移时由 ContainerNFT 调用（白皮书 §4.1）
    // ------------------------------------------------------------------
    function onNFTTransfer(address newAdmin) external {
        require(msg.sender == nft, "Container: only NFT contract");
        require(newAdmin != address(0), "Container: zero admin");
        admin = newAdmin;
        emit AdminChanged(newAdmin);
    }

    // ------------------------------------------------------------------
    // 资产（ETHER）
    // ------------------------------------------------------------------
    /// @notice 接收 ETH（任何来源：资产入账、收益、推理费）
    receive() external payable {}

    /// @notice 累计收益会计（由执行节点/结算流程调用，携带 ETHER）
    function accrueRevenue() external payable {
        require(msg.value > 0, "Container: zero amount");
        totalRevenue += msg.value;
        emit RevenueAccrued(msg.sender, msg.value);
    }

    /// @notice 管理员提取 ETH（容器账户语义：admin 是容器主人）
    function withdrawETH(uint256 amount) external onlyAdmin {
        require(amount <= address(this).balance, "Container: insufficient balance");
        (bool ok, ) = payable(admin).call{value: amount}("");
        require(ok, "Container: ETH transfer failed");
        emit Withdrawn(admin, amount);
    }

    // ------------------------------------------------------------------
    // 资产（ERC-20）
    // ------------------------------------------------------------------
    /// @notice 存入 ERC-20（任何人可存入，类似收款地址）
    function depositToken(address token, uint256 amount) external {
        require(token != address(0), "Container: zero token");
        (bool ok, ) = token.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", msg.sender, address(this), amount
            )
        );
        require(ok, "Container: token deposit failed");
        tokenBalances[token] += amount;
    }

    /// @notice 管理员提取 ERC-20
    function withdrawToken(address token, uint256 amount) external onlyAdmin {
        require(token != address(0), "Container: zero token");
        require(amount <= tokenBalances[token], "Container: insufficient token balance");
        tokenBalances[token] -= amount;
        (bool ok, ) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", admin, amount)
        );
        require(ok, "Container: token transfer failed");
        emit TokenWithdrawn(token, admin, amount);
    }

    // ------------------------------------------------------------------
    // 引用管理（白皮书 §4.1：容器允许调用哪些执行单元/函数）
    // ------------------------------------------------------------------
    function addDsuRef(bytes32 ref) external onlyAdmin {
        require(ref != bytes32(0), "Container: zero ref");
        require(!dsuRefs[ref], "Container: dsu ref exists");
        dsuRefs[ref] = true;
        _dsuRefList.push(ref);
        emit DsuRefAdded(ref, _dsuRefList.length);
    }

    function removeDsuRef(bytes32 ref) external onlyAdmin {
        require(dsuRefs[ref], "Container: dsu ref missing");
        dsuRefs[ref] = false;
        for (uint256 i = 0; i < _dsuRefList.length; i++) {
            if (_dsuRefList[i] == ref) {
                _dsuRefList[i] = _dsuRefList[_dsuRefList.length - 1];
                _dsuRefList.pop();
                break;
            }
        }
        emit DsuRefRemoved(ref, _dsuRefList.length);
    }

    function addFunctionRef(bytes32 ref) external onlyAdmin {
        require(ref != bytes32(0), "Container: zero ref");
        require(!functionRefs[ref], "Container: function ref exists");
        functionRefs[ref] = true;
        _functionRefList.push(ref);
        emit FunctionRefAdded(ref, _functionRefList.length);
    }

    function removeFunctionRef(bytes32 ref) external onlyAdmin {
        require(functionRefs[ref], "Container: function ref missing");
        functionRefs[ref] = false;
        for (uint256 i = 0; i < _functionRefList.length; i++) {
            if (_functionRefList[i] == ref) {
                _functionRefList[i] = _functionRefList[_functionRefList.length - 1];
                _functionRefList.pop();
                break;
            }
        }
        emit FunctionRefRemoved(ref, _functionRefList.length);
    }

    /// @notice 引用列表（查询用）
    function dsuRefList() external view returns (bytes32[] memory) {
        return _dsuRefList;
    }

    function functionRefList() external view returns (bytes32[] memory) {
        return _functionRefList;
    }

    // ------------------------------------------------------------------
    // 私有状态（白皮书 §4.2：以压缩状态承诺叶子形式存储）
    // ------------------------------------------------------------------
    function setPrivateState(bytes32 commitment) external onlyAdmin {
        privateStateCommitment = commitment;
        emit PrivateStateUpdated(commitment);
    }

    // ------------------------------------------------------------------
    // AI 服务（白皮书 §4.1）
    // ------------------------------------------------------------------
    function setAiService(bytes32 _modelCID, uint256 _inferencePrice, address _beneficiary) external onlyAdmin {
        require(_modelCID != bytes32(0), "Container: zero modelCID");
        modelCID = _modelCID;
        inferencePrice = _inferencePrice;
        beneficiary = _beneficiary == address(0) ? admin : _beneficiary;
        emit AiServiceSet(_modelCID, _inferencePrice, beneficiary);
    }

    /// @notice 付费推理：费用沉淀为容器收益，受益地址自动收款
    /// @dev 单价 0 时允许免费推理（不校验金额）；超出部分随多付金额返还
    function payInference() external payable {
        require(msg.value >= inferencePrice, "Container: insufficient inference fee");
        uint256 revenue = inferencePrice;
        uint256 refund = msg.value - inferencePrice;
        if (revenue > 0) {
            totalRevenue += revenue;
            emit RevenueAccrued(msg.sender, revenue);
        }
        emit PaidInference(msg.sender, revenue, refund);
        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            require(ok, "Container: refund failed");
        }
    }
}