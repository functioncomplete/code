// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GateEngine
/// @notice FCT v2 门级引擎（whitepaper v1.3 §4.1 / dev-plan §5.2）——M5 交付。
///
///         语义：链上**通用** NAND/LATCH 网表的登记、校验与求值。
///         门级函数 = 输入引线（signal 0..I-1） + LATCH 状态位（signal I..I+L-1）
///         + 门（signal I+L..S-1，按拓扑序逐个定义）。
///
///         与 GateLang 编译产物（`gatelang --fct` 的 `gate_ir/*.json`）对齐：
///         - 扁平网表：无环、拓扑序（门的操作数下标严格小于自身下标 → 结构上不可能成环）
///         - 门原语只有 NAND 与常量（NOT/AND/OR/XOR 等在编译期已全部展开为 NAND）
///         - LATCH 以"状态位"表达：本次求值读入当前状态，输出下一状态（与 fct.rs
///           "latch 以输入形式表达" 的导出方式一致）
///         - 资源元数据（门数/深度/LATCH 数）在登记时**重新计算并与声明值比对**
///
///         只读、确定性：`eval` 为 view，无外部调用、无状态写入、无重入面。
///         身份与版税归属由 IdentityRegistry 承载（networkHash → owner/royalty/proofHash），
///         本合约只承载**可执行程序**；同一程序重复登记 revert（id 由内容派生，幂等）。
contract GateEngine {
    /* ============================ 操作码 ============================ */
    uint8 internal constant OP_NAND = 0;
    uint8 internal constant OP_CONST0 = 1;
    uint8 internal constant OP_CONST1 = 2;

    /* ============================ 资源上限（fail-closed 守卫） ============================ */
    /// @notice 信号总数上限（内存/气体守卫）。
    uint32 public constant MAX_SIGNALS = 1024;
    /// @notice 门数上限。
    uint32 public constant MAX_GATES = 1024;
    /// @notice 输入/输出/状态以 uint256 位域承载 → 各自位数上限 256。
    uint16 public constant MAX_IO_BITS = 256;

    /* ============================ 存储 ============================ */
    struct GateFn {
        uint32 signalCount; // 信号总数 S = I + L + gateCount
        uint16 inputCount; // 主输入位数 I
        uint16 latchCount; // LATCH 状态位数 L
        uint16 outCount; // 输出位数（≤ MAX_IO_BITS）
        uint32 gateCount; // 门列表长度（含常量门）
        uint32 nandCount; // 其中的 NAND 门数（与 GateLang `metadata.gates` 对齐）
        uint32 depth; // 计算得到的最深组合路径（与声明值比对）
        bytes32 ioSpec; // 接口哈希（输入数/输出信号）
        address registrant; // 首次登记者的地址（身份归属以 IdentityRegistry 为准）
        bool active;
    }

    mapping(bytes32 => GateFn) public fns; // fnId -> 元数据
    /// @notice 永久退役标记：一旦停用，同一（内容派生的）fnId 不可再登记。
    ///         否则原作者退役一个有缺陷的函数后，任何人都能重新登记把它"复活"。
    mapping(bytes32 => bool) public retired;
    // 门列表：`_program[id][k]` 定义 signal (I + L + k)，
    // 打包为 op(8) | l(12) | r(12)。
    mapping(bytes32 => uint32[]) internal _program;
    mapping(bytes32 => uint16[]) public outSigsOf; // 输出信号下标
    mapping(bytes32 => uint16[]) public nextSigsOf; // LATCH 下一状态信号（长度 = L）

    uint256 public fnCount;
    /// @notice 治理地址（与 DSU / IdentityRegistry / PrimitiveSelector 同级的 owner）。
    ///         登记若开放无权限，"首个登记者"可抢跑并调用 disableFunction **永久退役**他人函数
    ///         → 把合法函数与所有使用者锁死。故登记与退役均为 owner 门控。
    ///         非 immutable：支持**两步移交**给多签 / 时间锁 / DAO（见 transferOwnership）。
    address public owner;
    /// @notice 待接任的 owner（两步移交的中间态）。
    address public pendingOwner;

    event FunctionRegistered(bytes32 indexed fnId, uint32 signalCount, uint32 gateCount, uint32 depth, uint16 inputCount, uint16 latchCount);
    event FunctionDisabled(bytes32 indexed fnId);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /* ============================ 两步所有权移交 ============================ */
    /// @notice 第一步：当前 owner 提名接任者（不立即生效，避免误转到错误地址后无法挽回）。
    ///         生产部署建议把 owner 交给多签（Safe）或时间锁，以消除单一 key 的中心化风险。
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice 第二步：接任者接受（唯一能完成移交的地址）。
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending");
        address old = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
    }

    /* ============================ 登记 ============================ */
    /// @notice 登记一个门级函数程序。
    /// @param inputCount   主输入位数 I（signal 0..I-1）
    /// @param latchCount   LATCH 状态位数 L（signal I..I+L-1）
    /// @param program      门列表（signal I+L..S-1 逐个定义），打包 op(8)|l(12)|r(12)
    /// @param outSigs      输出信号下标（顺序即输出位序）
    /// @param nextSigs     LATCH 下一状态信号下标（长度必须 = L）
    /// @param declaredDepth 声明的逻辑深度（与链上重算值比对，不符 revert）
    /// @return fnId 内容派生的函数 id
    function registerFunction(
        uint16 inputCount,
        uint16 latchCount,
        uint32[] calldata program,
        uint16[] calldata outSigs,
        uint16[] calldata nextSigs,
        uint32 declaredDepth
    ) external onlyOwner returns (bytes32 fnId) {
        uint256 gateCount = program.length;
        require(gateCount > 0, "empty program");
        require(gateCount <= MAX_GATES, "too many gates");
        require(inputCount <= MAX_IO_BITS, "inputs > 256");
        require(latchCount <= MAX_IO_BITS, "latches > 256");
        require(outSigs.length <= MAX_IO_BITS, "outputs > 256");
        require(outSigs.length > 0, "no outputs");
        require(nextSigs.length == latchCount, "next len");

        uint256 sigCount = uint256(inputCount) + latchCount + gateCount;
        require(sigCount <= MAX_SIGNALS, "too many signals");

        // 深度与拓扑校验（逐门）
        uint32[] memory depth = new uint32[](sigCount);
        uint32 nandCount = 0;
        for (uint256 k = 0; k < gateCount; k++) {
            uint32 g = program[k];
            uint8 op = uint8(g >> 24);
            uint256 l = (g >> 12) & 0xFFF;
            uint256 r = g & 0xFFF;
            uint256 self = uint256(inputCount) + latchCount + k;
            if (op == OP_NAND) {
                // 拓扑序：操作数必须严格早于本信号 → 结构上无环
                require(l < self && r < self, "topo order");
                uint32 dl = depth[l];
                uint32 dr = depth[r];
                depth[self] = (dl > dr ? dl : dr) + 1;
                nandCount += 1;
            } else if (op == OP_CONST0 || op == OP_CONST1) {
                require(l == 0 && r == 0, "const operands");
                depth[self] = 0;
            } else {
                revert("bad opcode");
            }
        }

        // 计算深度（对全部信号取最大）
        uint32 computedDepth = 0;
        for (uint256 s = 0; s < sigCount; s++) {
            if (depth[s] > computedDepth) computedDepth = depth[s];
        }
        require(computedDepth == declaredDepth, "depth mismatch");

        // 输出/下一状态下标边界
        for (uint256 i = 0; i < outSigs.length; i++) {
            require(outSigs[i] < sigCount, "out oob");
        }
        for (uint256 j = 0; j < nextSigs.length; j++) {
            require(nextSigs[j] < sigCount, "next oob");
        }

        fnId = _computeId(inputCount, latchCount, program, outSigs, nextSigs);
        require(!retired[fnId], "retired");
        require(!fns[fnId].active, "dup function");

        fns[fnId] = GateFn({
            signalCount: uint32(sigCount),
            inputCount: inputCount,
            latchCount: latchCount,
            outCount: uint16(outSigs.length),
            gateCount: uint32(gateCount),
            nandCount: nandCount,
            depth: computedDepth,
            ioSpec: _ioSpec(inputCount, outSigs),
            registrant: msg.sender,
            active: true
        });
        _program[fnId] = program;
        outSigsOf[fnId] = outSigs;
        nextSigsOf[fnId] = nextSigs;
        fnCount += 1;

        emit FunctionRegistered(fnId, uint32(sigCount), uint32(gateCount), computedDepth, inputCount, latchCount);
        return fnId;
    }

    /// @notice 退役某函数（仅 owner）。**永久**：同一 fnId 之后不可再登记。
    function disableFunction(bytes32 fnId) external onlyOwner {
        require(fns[fnId].active, "unknown");
        fns[fnId].active = false;
        retired[fnId] = true;
        emit FunctionDisabled(fnId);
    }

    /* ============================ 求值 ============================ */
    /// @notice 链上求值（只读）：输入位域 + 当前 LATCH 状态位域 → 输出位域 + 下一状态位域。
    ///         位序：输入/输出/状态的第 i 位对应第 i 个引线（LSB 起）。
    function eval(bytes32 fnId, uint256 inBits, uint256 stateBits)
        external
        view
        returns (uint256 outBits, uint256 nextStateBits)
    {
        GateFn memory f = fns[fnId];
        require(f.active, "unknown fn");

        uint256 sigCount = f.signalCount;
        uint256 iN = f.inputCount;
        uint256 lN = f.latchCount;

        uint256[] memory sig = new uint256[](sigCount);
        for (uint256 i = 0; i < iN; i++) {
            sig[i] = (inBits >> i) & 1;
        }
        for (uint256 j = 0; j < lN; j++) {
            sig[iN + j] = (stateBits >> j) & 1;
        }

        uint32[] memory program = _program[fnId];
        for (uint256 k = 0; k < program.length; k++) {
            uint32 g = program[k];
            uint8 op = uint8(g >> 24);
            uint256 self = iN + lN + k;
            if (op == OP_NAND) {
                uint256 l = (g >> 12) & 0xFFF;
                uint256 r = g & 0xFFF;
                sig[self] = (~(sig[l] & sig[r])) & 1;
            } else if (op == OP_CONST1) {
                sig[self] = 1;
            } else {
                sig[self] = 0; // OP_CONST0（登记时已校验只有 0/1）
            }
        }

        uint16[] memory outs = outSigsOf[fnId];
        for (uint256 i = 0; i < outs.length; i++) {
            outBits |= sig[outs[i]] << i;
        }
        uint16[] memory nexts = nextSigsOf[fnId];
        for (uint256 j = 0; j < nexts.length; j++) {
            nextStateBits |= sig[nexts[j]] << j;
        }
    }

    /* ============================ 查询 ============================ */
    function programOf(bytes32 fnId) external view returns (uint32[] memory) {
        return _program[fnId];
    }

    function isActive(bytes32 fnId) external view returns (bool) {
        return fns[fnId].active;
    }

    /// @notice 内容派生的函数 id（跨实现可复现：同一程序 → 同一 id）。
    function computeId(
        uint16 inputCount,
        uint16 latchCount,
        uint32[] calldata program,
        uint16[] calldata outSigs,
        uint16[] calldata nextSigs
    ) external pure returns (bytes32) {
        return _computeId(inputCount, latchCount, program, outSigs, nextSigs);
    }

    /* ============================ 内部 ============================ */
    function _computeId(
        uint16 inputCount,
        uint16 latchCount,
        uint32[] calldata program,
        uint16[] calldata outSigs,
        uint16[] calldata nextSigs
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(inputCount, latchCount, program, outSigs, nextSigs));
    }

    function _ioSpec(uint16 inputCount, uint16[] calldata outSigs) private pure returns (bytes32) {
        return keccak256(abi.encode(inputCount, outSigs));
    }
}
