// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ProofMarket
/// @notice FCT v2 M3 证明市场（whitepaper v1.3 §6.2–6.3, dev-plan §5.3）。
///         Prover 生成执行证明 → 验证者投票（>2/3 达到最终性）→ 结算。
///         无效证明罚没保证金，证明者永久失去资格；验证者获得手续费分成。
/// @dev 原型聚焦结算时序与质押经济，不绑定具体密码学：
///      proof 以摘要 proofHash 存链，payload 由验证者按需要链下对证；
///      任务标记 REPLAY / ZK / TEE 路径，验证者可插拨。
contract ProofMarket {
    /* ===================== 常量 ===================== */
    /// @notice 2/3 验证者多数（白皮书 v1.3 §6.3 最终性 >2/3 确认）。
    uint256 public constant VOTER_NUM = 2;
    uint256 public constant VOTER_DEN = 3;
    /// @notice 结算手续费 0.5%（分给投 accept 的验证者）。
    uint256 public constant FEE_BPS = 50;
    /// @notice 罚没分配：投 reject 的验证者 50%，需求方 50%。
    uint256 public constant SLASH_VALIDATOR_BPS = 5000;
    /// @notice 证明者最小质押。
    uint256 public constant MIN_STAKE = 0.01 ether;

    /* ===================== 配置 ===================== */
    address public immutable owner;
    /// @notice 投票窗口（秒）：提交后窗口内投票，窗口外触发结算。
    uint256 public immutable VOTING_WINDOW;

    /* ===================== 状态 ===================== */
    uint256 public taskSeq;
    uint256 public validatorCount;
    uint256 public totalStake;

    enum ProofPath { REPLAY, ZK, TEE }
    enum TaskStatus { OPEN, SUBMITTED, FINALIZED, SLASHED, CANCELLED, EXPIRED }

    struct Proof {
        bytes32 inputHash;
        bytes32 outputHash;
        bytes payload; // 重放痕迹 / ZK proof / TEE sig+quote
    }

    struct Task {
        uint256 containerId; // 关联容器（0 = 与容器无关的公开计算）
        uint256 functionId; // 门级函数 / DSU 版本哈希
        ProofPath path;
        bytes32 inputHash; // 任务定义输入
        bytes32 outputHash; // 期望输出；0 = 未知，由验证者判定
        uint256 reward; // 需求方托管的 ETHER 奖励
        uint256 expiresAt; // 提交截止
        TaskStatus status;
        address requester;
        address prover;
        bytes32 proofHash;
        uint256 submittedAt;
        uint256 acceptVotes;
        uint256 rejectVotes;
    }

    mapping(uint256 => Task) public tasks;
    mapping(address => uint256) public proverStakes;
    mapping(address => bool) public banned;
    mapping(uint256 => mapping(address => bool)) public acceptVote;
    mapping(uint256 => mapping(address => bool)) public rejectVote;

    address[] public validators;
    mapping(address => bool) public validatorIndex;
    /// @notice 验证者在 validators 数组中的 1-based 槽位（0 = 不在）。
    mapping(address => uint256) public validatorSlot;
    /// @notice 验证者注册代次（每次注册 +1）：使注销/重注册后的旧投票失效。
    mapping(address => uint256) public validatorGen;
    /// @notice 任务 → 验证者 → 投票时的注册代次。
    mapping(uint256 => mapping(address => uint256)) public voteGen;
    /// @notice 待结算任务中锁定的质押计数（>0 时禁止 unstake，防抢跑逃逸罚没）。
    mapping(address => uint256) public lockedTasks;
    /// @notice 任务 → 绑定的保证金（每任务 MIN_STAKE）。罚没只没收本任务的保证金。
    mapping(uint256 => uint256) public taskBond;
    /// @notice 证明者 → 已锁定保证金合计（free stake = proverStakes - lockedBond）。
    mapping(address => uint256) public lockedBond;
    /// @notice 拉取式提款账本：转账失败的收款方在此记账，避免阻塞结算。
    mapping(address => uint256) public pendingWithdrawals;

    /* ===================== 事件 ===================== */
    event TaskCreated(uint256 indexed id, address indexed requester, uint256 reward, ProofPath path);
    event TaskCancelled(uint256 indexed id);
    event TaskExpired(uint256 indexed id);
    event Staked(address indexed prover, uint256 amount);
    event Unstaked(address indexed prover, uint256 amount);
    event ProofSubmitted(uint256 indexed id, address indexed prover, bytes32 proofHash);
    event Voted(uint256 indexed id, address indexed validator, bool accept);
    event TaskFinalized(uint256 indexed id, address indexed prover, uint256 payout);
    event TaskSlashed(uint256 indexed id, address indexed prover, uint256 slashed);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(uint256 votingWindow_) {
        owner = msg.sender;
        VOTING_WINDOW = votingWindow_;
    }

    /// @notice 尽力转账：失败则记入拉取式提款账本，绝不 revert（防恶意收款方阻塞结算）。
    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{ value: amount }("");
        if (!ok) pendingWithdrawals[to] += amount;
    }

    /// @notice 提取因转账失败而记账的余额。
    function withdraw() external {
        uint256 a = pendingWithdrawals[msg.sender];
        require(a > 0, "nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{ value: a }("");
        require(ok, "withdraw failed");
    }

    /* ===================== 验证者管理 ===================== */
    function registerValidator(address v) external onlyOwner {
        require(!validatorIndex[v], "dup");
        validatorIndex[v] = true;
        validators.push(v);
        validatorSlot[v] = validators.length; // 1-based
        validatorGen[v] += 1; // 新代次：旧投票自动失效
        validatorCount++;
    }

    function unregisterValidator(address v) external onlyOwner {
        require(validatorIndex[v], "not validator");
        validatorIndex[v] = false;
        // swap-and-pop：从数组移除，避免重注册产生重复项（重复项会被重复付款并操纵 quorum）
        uint256 slot = validatorSlot[v];
        uint256 last = validators.length;
        if (slot != last) {
            address moved = validators[last - 1];
            validators[slot - 1] = moved;
            validatorSlot[moved] = slot;
        }
        validators.pop();
        delete validatorSlot[v];
        validatorCount--;
    }

    function isValidator(address v) public view returns (bool) {
        return validatorIndex[v];
    }

    /* ===================== 任务生命周期 ===================== */
    /// @notice 发布证明任务并托管奖励。`expiresAt` 之后未提交，需求方可撤回。
    function createTask(
        uint256 containerId,
        uint256 functionId,
        ProofPath path,
        bytes32 inputHash,
        bytes32 outputHash,
        uint256 expiresAt
    ) external payable returns (uint256 id) {
        require(msg.value > 0, "reward 0");
        require(expiresAt > block.timestamp, "expiry past");
        id = ++taskSeq;
        tasks[id] = Task({
            containerId: containerId,
            functionId: functionId,
            path: path,
            inputHash: inputHash,
            outputHash: outputHash,
            reward: msg.value,
            expiresAt: expiresAt,
            status: TaskStatus.OPEN,
            requester: msg.sender,
            prover: address(0),
            proofHash: bytes32(0),
            submittedAt: 0,
            acceptVotes: 0,
            rejectVotes: 0
        });
        emit TaskCreated(id, msg.sender, msg.value, path);
    }

    /// @notice 需求方在 OPEN 期取消任务并取回奖励。
    function cancelTask(uint256 id) external {
        Task storage t = tasks[id];
        require(t.requester == msg.sender, "not requester");
        require(t.status == TaskStatus.OPEN, "not open");
        t.status = TaskStatus.CANCELLED;
        uint256 rw = t.reward;
        t.reward = 0;
        _send(msg.sender, rw);
        emit TaskCancelled(id);
    }

    /// @notice OPEN 期无人提交且已过期 → 需求方取回奖励。
    function claimExpired(uint256 id) external {
        Task storage t = tasks[id];
        require(t.status == TaskStatus.OPEN, "not open");
        require(block.timestamp >= t.expiresAt, "not expired");
        t.status = TaskStatus.EXPIRED;
        uint256 rw = t.reward;
        t.reward = 0;
        _send(t.requester, rw);
        emit TaskExpired(id);
    }

    /* ===================== 质押 ===================== */
    function stake() external payable {
        require(msg.value >= MIN_STAKE, "min stake");
        proverStakes[msg.sender] += msg.value;
        totalStake += msg.value;
        emit Staked(msg.sender, msg.value);
    }

    function unstake() external {
        require(lockedBond[msg.sender] == 0, "stake locked");
        uint256 a = proverStakes[msg.sender];
        require(a > 0, "no stake held");
        proverStakes[msg.sender] = 0;
        totalStake -= a;
        _send(msg.sender, a);
        emit Unstaked(msg.sender, a);
    }

    /* ===================== 证明提交 ===================== */
    function submitProof(uint256 id, Proof calldata p) external {
        Task storage t = tasks[id];
        require(t.status == TaskStatus.OPEN, "not open");
        require(block.timestamp < t.expiresAt, "expired");
        require(!banned[msg.sender], "banned");
        require(proverStakes[msg.sender] > 0, "no stake");
        // 逐任务绑定 MIN_STAKE：一份质押不能担保无限并发任务（free stake 须足额）
        require(proverStakes[msg.sender] - lockedBond[msg.sender] >= MIN_STAKE, "free stake < MIN_STAKE");
        require(p.inputHash == t.inputHash, "input mismatch");
        if (t.outputHash != bytes32(0)) {
            require(p.outputHash == t.outputHash, "output mismatch");
        }
        t.status = TaskStatus.SUBMITTED;
        t.prover = msg.sender;
        lockedTasks[msg.sender]++;
        taskBond[id] = MIN_STAKE;
        lockedBond[msg.sender] += MIN_STAKE;
        t.proofHash = keccak256(abi.encodePacked(p.inputHash, p.outputHash, p.payload));
        t.submittedAt = block.timestamp;
        emit ProofSubmitted(id, msg.sender, t.proofHash);
    }

    /* ===================== 验证与结算 ===================== */
    /// @notice 验证者投一票。同任务同验证者只能投一次。
    function vote(uint256 id, bool accept) external {
        require(validatorIndex[msg.sender], "not validator");
        Task storage t = tasks[id];
        require(t.status == TaskStatus.SUBMITTED, "not submitted");
        require(msg.sender != t.prover, "prover cannot vote");
        require(msg.sender != t.requester, "requester cannot vote");
        require(block.timestamp < t.submittedAt + VOTING_WINDOW, "window closed");
        require(!_voted(id, msg.sender, true) && !_voted(id, msg.sender, false), "voted");
        // 清除可能残留的旧方向票（重注册后旧 flag 会在新代次下“复活”，使两个方向都为真）
        delete acceptVote[id][msg.sender];
        delete rejectVote[id][msg.sender];
        voteGen[id][msg.sender] = validatorGen[msg.sender];
        if (accept) {
            acceptVote[id][msg.sender] = true;
            t.acceptVotes++;
        } else {
            rejectVote[id][msg.sender] = true;
            t.rejectVotes++;
        }
        emit Voted(id, msg.sender, accept);
    }

    /// @notice 该验证者在当前注册代次下是否已投该任务的票（旧代次的投票视为无效）。
    function _voted(uint256 id, address v, bool accept) internal view returns (bool) {
        return validatorGen[v] != 0
            && voteGen[id][v] == validatorGen[v]
            && (accept ? acceptVote[id][v] : rejectVote[id][v]);
    }

    function allVoted(uint256 id) public view returns (bool) {
        for (uint256 i = 0; i < validators.length; i++) {
            address v = validators[i];
            if (!validatorIndex[v]) continue;
            if (!_voted(id, v, true) && !_voted(id, v, false)) return false;
        }
        return validatorCount > 0;
    }

    /// @notice 结算：>2/3 accept → 立即奖励证明者、手续费分给 accept 验证者；
    ///         >2/3 reject → 立即罚没质押（reject 验证者 50% + 需求方 50%）、禁赛证明者；
    ///         无多数且（全部已投票或窗口结束）→ 任务回到 OPEN 并重置投票（可再次提交）。
    function settle(uint256 id) external {
        Task storage t = tasks[id];
        require(t.status == TaskStatus.SUBMITTED, "not submitted");

        // 按“当前注册代次的有效票”计票（存储计数器会包含已失效/重复票）
        uint256 liveAccept = 0;
        uint256 liveReject = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            address v = validators[i];
            if (!validatorIndex[v]) continue;
            if (_voted(id, v, true)) liveAccept++;
            else if (_voted(id, v, false)) liveReject++;
        }

        uint256 vc = validatorCount;
        if (liveAccept * VOTER_DEN > vc * VOTER_NUM) {
            _finalize(id);
            return;
        }
        if (liveReject * VOTER_DEN > vc * VOTER_NUM) {
            _slash(id);
            return;
        }

        // 无多数：需等待窗口结束或全体投票才能重新开放，否则保持 pending
        bool windowOver = block.timestamp >= t.submittedAt + VOTING_WINDOW;
        require(windowOver || allVoted(id), "voting pending");
        _reopen(id);
    }

    function _finalize(uint256 id) internal {
        Task storage t = tasks[id];
        t.status = TaskStatus.FINALIZED;
        lockedTasks[t.prover]--;
        lockedBond[t.prover] -= taskBond[id];
        uint256 fee = (t.reward * FEE_BPS) / 10000;
        uint256 payout = t.reward - fee;
        t.reward = 0;

        // 统计实际可付款的 accept 验证者（已注销者不在此列，避免留灰尘）
        uint256 payees = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            address v = validators[i];
            if (_voted(id, v, true)) payees++;
        }
        if (payees == 0) {
            // 无 accept 验证者可付：手续费归证明者，避免锁死
            _send(t.prover, payout + fee);
        } else {
            _send(t.prover, payout);
            uint256 remaining = fee;
            uint256 n = payees;
            for (uint256 i = 0; i < validators.length && n > 0; i++) {
                address v = validators[i];
                if (!_voted(id, v, true)) continue;
                uint256 share = remaining / n;
                _send(v, share);
                remaining -= share;
                n--;
            }
        }
        emit TaskFinalized(id, t.prover, payout);
    }

    function _slash(uint256 id) internal {
        Task storage t = tasks[id];
        t.status = TaskStatus.SLASHED;
        lockedTasks[t.prover]--;
        address prover = t.prover;
        lockedBond[prover] -= taskBond[id];
        // 只没收本任务的保证金（其余任务的保证金不受影响）
        uint256 slashed = taskBond[id];
        proverStakes[prover] -= slashed;
        totalStake -= slashed;
        banned[prover] = true;

        uint256 toRequester = (slashed * SLASH_VALIDATOR_BPS) / 10000;
        // 归还需求方托管的奖励（任务失败，需求方不应损失奖励）
        uint256 reward = t.reward;
        t.reward = 0;

        // 统计实际可付款的 reject 验证者
        uint256 payees = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            address v = validators[i];
            if (_voted(id, v, false)) payees++;
        }
        uint256 remaining = slashed - toRequester;
        if (payees == 0) {
            // 无 reject 验证者可付：连同罚没余款一并归需求方，避免锁死
            _send(t.requester, reward + toRequester + remaining);
        } else {
            _send(t.requester, reward + toRequester);
            uint256 n = payees;
            for (uint256 i = 0; i < validators.length && n > 0; i++) {
                address v = validators[i];
                if (!_voted(id, v, false)) continue;
                uint256 share = remaining / n;
                _send(v, share);
                remaining -= share;
                n--;
            }
        }
        emit TaskSlashed(id, prover, slashed);
    }

    /// @notice 窗口结束无多数：回 OPEN，清除提交与所有投票，允许再次提交。
    function _reopen(uint256 id) internal {
        Task storage t = tasks[id];
        t.status = TaskStatus.OPEN;
        if (t.prover != address(0)) {
            lockedTasks[t.prover]--;
            lockedBond[t.prover] -= taskBond[id];
        }
        t.prover = address(0);
        t.proofHash = bytes32(0);
        t.submittedAt = 0;
        t.acceptVotes = 0;
        t.rejectVotes = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            address v = validators[i];
            acceptVote[id][v] = false;
            rejectVote[id][v] = false;
        }
    }
}