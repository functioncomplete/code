/* ============================================================
   FunctionComplete v2 — 交互与双语切换
   策略：HTML 内联中文为初始渲染（利于 SEO / 无 JS 可用）；
        JS 在初始化时快照中文原文，英文由词典提供。
        切换时只做「快照恢复 / 词典覆盖」，避免中英文本重复维护。
   内容来源：FunctionComplete 技术组件白皮书 v1.4（最终版）
             GateLang 技术白皮书 v2.2（最终版）
             FCT 与 GateLang 标准术语 / LSM 在区块链的应用前景
   ============================================================ */
(function () {
  'use strict';

  var STORAGE_KEY = 'fct-lang';
  var DEFAULT_LANG = 'zh';

  /* ---------- 英文词典（键与 HTML 的 data-i18n 一一对应） ---------- */
  var EN = {
    /* nav */
    'nav.positioning': 'Position',
    'nav.terminology': 'Terms',
    'nav.primitives': 'Primitives',
    'nav.architecture': 'Arch',
    'nav.gatelangSec': 'GateLang',
    'nav.components': 'Components',
    'nav.security': 'Security',
    'nav.applications': 'Apps',
    'nav.roadmap': 'Roadmap',
    'nav.gatelang': 'GateLang',
    'nav.whitepaper': 'Whitepaper',
    'nav.container': 'Container',
    'nav.provable': 'Proofs',
    'nav.economy': 'Economy',
    'nav.gatelangRepo': 'GateLang repo',

    /* hero */
    'hero.badge': 'FCT v1.4 \u00b7 Logical State Machine (LSM) technical component kit \u00b7 Not a chain, not a token',
    'hero.h1a': 'Side-effect-free compute \u00b7 atomic state transitions \u00b7',
    'hero.h1b': 'the Logical State Machine (LSM)',
    'hero.h1c': 'on-chain technical component kit',
    'hero.lead': 'FCT is not a chain, not a token, and not an L2 \u2014 it is a technical component kit for on-chain computation and state management, maintained by the Ethercoin team. Its core technology is formally named the <strong>Logical State Machine (LSM)</strong>: NAND pure-function primitives carry computation, LATCH state primitives carry memory, the combinational part is boolean functions and the sequential part is finite state machines \u2014 callable on-chain for verification, conditional evaluation and state constraints.',
    'hero.cta1': 'Explore the components',
    'hero.cta3': 'GateLang v2.2 language frontend',
    'hero.cta2': 'Read whitepaper v1.4',
    'hero.stat1': 'compute primitives (logic primitive functions + DSU)',
    'hero.stat2': 'classes of technical components',
    'hero.stat3': 'tokens (all settlement in ETHER)',

    /* positioning */
    'pos.eyebrow': 'Positioning & boundaries',
    'pos.h2': 'What FCT is \u2014 and is not',
    'pos.lead': 'FCT is a <strong>technical component kit for on-chain computation and state</strong> output by the Ethercoin team \u2014 not an independent chain, and not a token project. By deploying FCT adapters on public chains, Ethercoin plans to become their L2 / sidechain, offering liquidation that resembles a cross-chain bridge but is more verifiable.',
    'pos.tableCap': 'Positioning and boundaries of FCT',
    'pos.th1': 'Dimension',
    'pos.th2': 'Positioning',
    'pos.r0k': 'Maintainer',
    'pos.r0v': 'Ethercoin team',
    'pos.r1k': 'Nature',
    'pos.r1v': 'On-chain computation and state technical component kit',
    'pos.r2k': 'Core technology',
    'pos.r2v': 'Logical State Machine (LSM)',
    'pos.r3k': 'Language tooling',
    'pos.r3v': 'GateLang v2.2',
    'pos.r4k': 'Chain status',
    'pos.r4v': '<strong>Not yet activated</strong>',
    'pos.r5k': 'Token',
    'pos.r5v': '<strong>None. No FCT token has been issued</strong>',
    'pos.r6k': 'Independent governance / staking / mining',
    'pos.r6v': 'None; the economic medium is uniformly ETHER, the Ethercoin ecosystem token',
    'pos.r7k': 'Served networks',
    'pos.r7v': 'Ethereum, Robinhood Chain, Solana, Cosmos, Move chains, Bitcoin L2s and other target public chains',
    'pos.r8k': 'Deployment entity',
    'pos.r8v': 'Ethercoin multi-chain settlement layer',
    'pos.r9k': 'Goal',
    'pos.r9v': 'Give target public chains verifiable computation, transferable state containers and cross-chain liquidation',
    'pos.warnT': 'Chain not activated \u00b7 No token',
    'pos.warnD': 'The FCT chain is not yet activated and no FCT token has been issued. Any activity claiming FCT tokens, airdrops, presales, private sales, staking, mining, mapping, swaps or compensation is unrelated to the Ethercoin team.',

    /* terminology */
    'term.eyebrow': 'Standard terminology',
    'term.h2': 'Why we no longer say \u201ccircuit\u201d, \u201cnetlist\u201d or \u201cgate-level\u201d',
    'term.lead': 'In software / on-chain contexts, reusing hardware vocabulary tends to import the wrong hardware semantics. GateLang\u2019s compilation artifacts are not circuits in the hardware sense, but <strong>executable logic-state programs / logical state machines</strong>: the combinational part is boolean functions, the sequential part is finite state machines.',
    'term.tableCap': 'Recommended and discouraged terminology',
    'term.th1': 'Abstraction layer',
    'term.th2': 'Recommended',
    'term.th3': 'Discouraged',
    'term.r1a': 'Mathematical layer',
    'term.r1b': 'Boolean functions, state-transition functions, sequential-logic functions',
    'term.r1c': 'Logic set',
    'term.r2a': 'Software implementation layer',
    'term.r2b': 'Logic-expression DAG, dataflow graph, finite state machine, state-transition system',
    'term.r2c': 'Circuit netlist',
    'term.r3a': 'On-chain execution layer',
    'term.r3b': 'On-chain executable logic module, on-chain state machine, verification function',
    'term.r3c': 'Gate-level circuit',
    'term.r4a': 'Element layer',
    'term.r4b': 'Logic primitive set (NAND, LATCH)',
    'term.r4c': 'Logic set',
    'term.r5a': 'Collective term',
    'term.r5b': 'Executable logic-state program, logical state machine',
    'term.r5c': 'Circuit',
    'term.ccipH': 'Standard phrasing in the CCIP 2.0 context',
    'term.ccipCap': 'Standard phrasing for CCIP 2.0 related objects',
    'term.ch1': 'CCIP 2.0 object',
    'term.ch2': 'Standard phrasing',
    'term.c1k': 'CCV verification logic',
    'term.c1v': 'Verification function / verification state machine',
    'term.c2k': 'Custom executor conditions',
    'term.c2v': 'Condition-evaluation program / constraint program',
    'term.c3k': 'CSC',
    'term.c3v': 'State container + state-transition rules',
    'term.c4k': 'ACE compliance rules',
    'term.c4v': 'Compliance-constraint program / compliance state machine',
    'term.ruleH': 'Usage principles',
    'term.rule1': 'When describing software / on-chain environments, avoid \u201ccircuit\u201d, \u201cnetlist\u201d and \u201cgate-level\u201d',
    'term.rule2': 'If a hardware analogy is genuinely needed, label it explicitly as a \u201chardware analogy\u201d',
    'term.rule3': 'Preferred: verification function / verification state machine, condition-evaluation program / constraint program, state container + state-transition rules, compliance-constraint program / compliance state machine, executable logic-state program / logical state machine',

    /* primitives */
    'prim.eyebrow': 'Core concept',
    'prim.h2': 'Two compute primitives',
    'prim.lead': 'FCT builds every capability on just two compute primitives: <strong>logic primitive functions</strong> carry computation, and <strong>DSU</strong> carries domain-specific execution. Both are Turing-complete and can simulate each other, yet are complementary in formal-verification granularity, proof cost and performance.',
    'prim.fnT': 'Logic primitive functions',
    'prim.fnD': 'NAND pure-function primitives are logically complete, and LATCH state primitives remember one bit of internal state, expressing arbitrary sequential logic. Side-effect-free, deterministic, composable \u2014 physically immune to reentrancy and state manipulation.',
    'prim.dsuT': 'DSU \u00b7 Domain-Specific Unit',
    'prim.dsuD': 'Five classes of precompiled units \u2014 hash, signature, arithmetic, state machine and ML inference \u2014 for high-performance batch computation. Read-only execution; state changes are performed uniformly by the container layer.',
    'prim.dsuH': 'The five DSU classes',
    'prim.dsuCap': 'DSU classes and covered scenarios',
    'prim.dh1': 'DSU class',
    'prim.dh2': 'Covered scenarios',
    'prim.d1k': 'Hash DSU',
    'prim.d1v': 'Poseidon / Blake3 / SHA-256 \u2014 low-cost hashing and commitments',
    'prim.d2k': 'Signature DSU',
    'prim.d2v': 'EdDSA / BLS / secp256k1 \u2014 batch verification support',
    'prim.d3k': 'Arithmetic DSU',
    'prim.d3v': 'Finite fields, big integers, elliptic curves \u2014 cryptographic coprocessor',
    'prim.d4k': 'State-machine DSU',
    'prim.d4v': 'Conditional branches, loops, jumps \u2014 provides control flow',
    'prim.d5k': 'ML inference DSU',
    'prim.d5v': 'Quantized neural-network forward pass \u2014 the core of verifiable AI inference',
    'prim.diffH': 'Architectural differences between the two primitives',
    'prim.diffCap': 'Architectural differences between logic primitive functions and DSU',
    'prim.dfh0': 'Property',
    'prim.dfh1': 'Logic primitive functions',
    'prim.dfh2': 'DSU',
    'prim.dfh3': 'Automatically equivalent?',
    'prim.df1a': 'Side-effect-free',
    'prim.df1b': 'Yes',
    'prim.df1c': 'Read-only by whitepaper',
    'prim.df1d': 'Yes',
    'prim.df2a': 'Read-only calls',
    'prim.df2b': 'Yes',
    'prim.df2c': 'Yes',
    'prim.df2d': 'Yes',
    'prim.df3a': 'State modification',
    'prim.df3b': 'No, handled uniformly by the container layer',
    'prim.df3c': 'No, handled uniformly by the container layer',
    'prim.df3d': 'Yes',
    'prim.df4a': 'Reentrancy immunity',
    'prim.df4b': 'Physically immune',
    'prim.df4c': 'Immune under read-only constraint',
    'prim.df4d': 'Yes',
    'prim.df5a': 'Determinism',
    'prim.df5b': 'Guaranteed by the logic primitive structure',
    'prim.df5c': 'Requires fixed implementation and precision',
    'prim.df5d': 'Needs extra constraints',
    'prim.df6a': 'Formal verification',
    'prim.df6b': 'Naturally suited to full verification',
    'prim.df6c': 'Module-level verification, harder to verify fully',
    'prim.df6d': 'No',
    'prim.df7a': 'Verification granularity',
    'prim.df7b': 'Per primitive, per LATCH',
    'prim.df7c': 'Precompiled module level',
    'prim.df7d': 'No',
    'prim.df8a': 'Cross-chain identity',
    'prim.df8b': 'NAND logic-structure hash + function NFT',
    'prim.df8c': 'DSU version + parameter hash',
    'prim.df8d': 'Needs extra spec',
    'prim.df9a': 'Proof cost',
    'prim.df9b': 'Per-primitive proofs may be larger',
    'prim.df9c': 'Class-based cost model, predictable',
    'prim.df9d': 'Different',
    'prim.df10a': 'Performance',
    'prim.df10b': 'Low',
    'prim.df10c': 'High',
    'prim.df10d': 'Different',
    'prim.selH': 'Selection matrix',
    'prim.s1t': 'Cross-chain identity anchoring / formal verification / public function libraries',
    'prim.s1d': 'Logic primitive functions recommended \u2014 the NAND logic-structure hash is unique, primitives can be fully verified, and structurally composed royalties stay traceable.',
    'prim.s2t': 'AI inference / cryptography / batch computation / small high-frequency calls',
    'prim.s2d': 'DSU recommended \u2014 the ML inference DSU is high-performance, arithmetic / signature / hash DSUs are efficient, and the class-based cost model is predictable.',
    'prim.s3t': 'RWA compliance checks / AI Agent containers',
    'prim.s3d': 'Hybrid recommended \u2014 logic primitive functions verify rules and identity; DSU handles data and execution.',

    /* architecture */
    'arch.eyebrow': 'Functional architecture',
    'arch.h2': 'The five-layer LSM functional system',
    'arch.lead': 'Core design principles: <strong>layered computation, compressed state, isolated permissions, carrier-agnostic.</strong>',
    'arch.l1t': 'Compute primitive layer',
    'arch.l1d': 'NAND as the combinational-logic primitive, LATCH as the state-holding primitive. Together they yield: boolean functions in the combinational part and finite state machines in the sequential part.',
    'arch.l1a': 'NAND logically complete',
    'arch.l1b': 'Turing-complete',
    'arch.a1': 'Compile',
    'arch.l2t': 'Language compilation layer',
    'arch.l2d': 'GateLang v2.2 offers four layers of abstraction \u2014 logic primitive, high-level language, domain DSL and visual \u2014 compiling uniformly into FCT-compatible artifacts. AI-assisted development must pass the gatelang-ai-gate.',
    'arch.l2a': 'Four-layer abstraction',
    'arch.l2b': 'AI is the accelerator',
    'arch.a2': 'Deploy',
    'arch.l3t': 'On-chain execution layer',
    'arch.l3d': 'LSM compilation artifacts deploy as function NFTs (executable logic modules) and container NFTs (state-management credentials). Function NFT calls are read-only \u2014 no gas, no transaction.',
    'arch.l3a': 'Read-only calls',
    'arch.l3b': 'Physically reentrancy-immune',
    'arch.a3': 'Prove',
    'arch.l4t': 'Verification & proof layer',
    'arch.l4d': 'Three proof paths: authorized replay, ZK proofs and TEE proofs. The path is configurable by asset value and risk preference.',
    'arch.l4a': 'Replay',
    'arch.l4b': 'ZK / TEE',
    'arch.a4': 'Cross-chain',
    'arch.l5t': 'Cross-chain coordination layer',
    'arch.l5d': 'Adapters connect EVM, Solana, Cosmos, Move and Bitcoin L2s. Cross-chain interaction is not mere message passing, but coordinated state transfer between a source-chain LSM and a target-chain LSM.',
    'arch.l5a': 'State coordination',
    'arch.l5b': 'Carrier-agnostic',

    /* gatelang */
    'gl.eyebrow': 'Unified language tooling',
    'gl.h2': 'GateLang v2.2 \u00b7 a verifiable logic-state language for all users',
    'gl.lead': 'GateLang takes <strong>NAND as its only combinational logic primitive and LATCH as its only state primitive</strong>, compiling developer logic into a single NAND/LATCH logic-primitive IR through <strong>four layers of abstraction</strong>, with no runtime overhead or hidden semantics. Its <code>spec</code> and <code>gateproof</code> generate formal-verification proofs bound to function / container NFTs; AI-assisted development must pass the <code>gatelang-ai-gate</code> \u2014 <strong>AI is the accelerator, formal verification is the guarantor</strong>.',
    'gl.tableCap': 'GateLang four-layer abstraction',
    'gl.th1': 'Layer',
    'gl.th2': 'Audience',
    'gl.th3': 'Compile target',
    'gl.r1n': 'L1 logic primitive layer',
    'gl.r1u': 'Hardware engineers / ZK circuit developers / formal researchers',
    'gl.r1v': 'NAND / LATCH logic-primitive IR',
    'gl.r2n': 'L2 high-level layer',
    'gl.r2u': 'Software developers',
    'gl.r2v': 'Logic primitive modules or DSU calls',
    'gl.r3n': 'L3 domain DSL layer',
    'gl.r3u': 'Finance / AI / gaming domain experts',
    'gl.r3v': 'Expands to L2, then to logic primitives',
    'gl.r4n': 'L4 visual layer',
    'gl.r4u': 'Education users / product managers / non-technical creators',
    'gl.r4v': 'Drag-and-wire \u2192 auto-generated L1/L2 code',
    'gl.baH': 'Portable across multiple backends',
    'gl.ba1': 'NAND/LATCH logic-primitive IR',
    'gl.ba2': 'FPGA / ASIC netlist',
    'gl.ba3': 'ZK circuits (Circom / Noir)',
    'gl.ba4': 'TEE executable code',
    'gl.ba5': 'Software simulator',
    'gl.ba6': 'C code (embedded firmware)',
    'gl.baNote': 'The same source can compile to many targets; backends are pluggable and the language binds to no execution environment.',
    'gl.resH': 'Resources fixed at compile time',
    'gl.res1t': 'NAND primitive count',
    'gl.res1d': 'Determines chip area and ZK proof generation time',
    'gl.res2t': 'Logic depth',
    'gl.res2d': 'Longest combinational path; determines clock frequency',
    'gl.res3t': 'Clock cycles',
    'gl.res3d': 'Determines TEE execution latency',
    'gl.res4t': 'LATCH count',
    'gl.res4d': 'Number of state-register bits',
    'gl.dl': 'Download GateLang whitepaper v2.2',
    'gl.repo': 'GateLang repository (GitHub)',
    'gl.toComponents': 'See the FCT components',

    /* components */
    'comp.eyebrow': 'Technical components',
    'comp.h2': 'Five classes of on-chain technical components',
    'comp.lead': 'FCT components are <strong>protocol-agnostic</strong>: they presuppose no particular network as their runtime, and instead connect to any network with basic ledger capability through adapters.',
    'comp.c1t': 'Execution \u00b7 Executable',
    'comp.c1d': 'Logic primitive functions (NAND + LATCH) and DSU together carry computation: functions define logic, DSU defines domain-specific execution, and both share the container state layer.',
    'comp.c2t': 'State \u00b7 State',
    'comp.c2d': 'Containers encapsulate node state; CSC compresses state commitments with history + extended Merkle trees and state rent, separating hot and cold state.',
    'comp.c3t': 'Proof \u00b7 Provable',
    'comp.c3d': 'Replay, ZK and TEE proofs coexist; provers and verifiers are decoupled, and users choose freely by security requirement.',
    'comp.c4t': 'Liquidation \u00b7 Liquidatable',
    'comp.c4d': 'Adapters handle cross-chain liquidation: bidirectional state-root anchoring + asset custody + challenge periods and an insurance fund, so chain state changes can be settled.',
    'comp.c5t': 'Identity \u00b7 Identifiable',
    'comp.c5d': 'Function NFTs and container NFTs: ticket, royalty registry and admin identity in one, traceable and registered cross-chain.',
    'comp.c6t': 'Carrier-agnostic',
    'comp.c6d': 'Components do not depend on a specific chain; adapters connect EVM, Solana, Cosmos, Move and Bitcoin L2s, rolled out chain by chain and independently verifiable.',

    /* container */
    'ctr.eyebrow': 'State component',
    'ctr.h2': 'Container \u2014 the \u201cbox\u201d of node state',
    'ctr.lead': 'A container carries a node\u2019s state and assets \u2014 the network\u2019s <strong>transferable, authorizable</strong> core carrier: transfer the token and you transfer management, and the holder gains full access to the node. A container belongs to its container NFT; its owner may be a person or an AI Agent.',
    'ctr.s1t': 'Transferable',
    'ctr.s1d': 'One-time transferable and non-transferable tokens: transferring the token transfers container ownership.',
    'ctr.s2t': 'Asset loading',
    'ctr.s2d': 'Natively loads ETHER, stablecoins, ERC-20 and ERC-721 assets as the node\u2019s economic entity.',
    'ctr.s3t': 'accessToken authorization',
    'ctr.s3d': 'DSU access is governed by accessTokens \u2014 granular, revocable authorization.',
    'ctr.s4t': 'Private state commitment',
    'ctr.s4d': 'Internal state is published as compressed-state-commitment leaves \u2014 details stay private while verification is preserved.',
    'ctr.s5t': 'Admin follows ownership',
    'ctr.s5d': 'A container\u2019s admin follows its container NFT\u2019s owner \u2014 whoever holds the NFT manages the container.',
    'ctr.usesH': 'Typical use cases',
    'ctr.u1t': 'AI service node',
    'ctr.u1d': 'Paid inference: callers pay ETHER, the node executes a logic primitive function or DSU and returns results; revenue settles into the container.',
    'ctr.u2t': 'Asset custody',
    'ctr.u2d': 'The container acts as a custody entity loading assets; state roots anchor to the liquidation chain, always liquidatable.',
    'ctr.u3t': 'State rental',
    'ctr.u3d': 'CSC state rent is priced per epoch; long-idle state is evicted to cold storage, putting the container to sleep but leaving it wakeable.',
    'ctr.statusH': 'Development status \u00b7 v2 dual-primitive component kit',
    'ctr.status1': 'M1 Container \u00b7 M2 CSC \u00b7 M3 ProofMarket \u00b7 M4 shared layer \u00b7 M5 logic primitive engine + DSU runtime \u00b7 M6 hybrid mode \u00b7 M7 cross-chain adapter deployed on Sepolia',
    'ctr.status2': 'Demo container tokenId #1 + CSC demo state on-chain; ProofMarket validator vote \u2192 reward / slash loop verified',
    'ctr.status4': 'M5 logic primitive engine evaluates on-chain identically to the GateLang logic-primitive structure (ADD4: 60 NAND / depth 19); the hybrid chain "execute DSU in-contract + logic-primitive replay" verifies 5+4 and writes the state slot',
    'ctr.status5': 'M6 hybrid mode (optimistic proof chain) reproduces both VERIFIED and REJECTED on-chain; M7 cross-chain adapter anchors a remote state root by stake-weighted >2/3 signatures, verifies inclusion proofs, and fires liquidation callbacks',
    'ctr.status3': 'Next: Ethereum adapter (independent audit, then mainnet settlement/verifier) \u2192 Solana adapter \u2014 see roadmap.',

    /* provable */
    'prv.eyebrow': 'Proof component',
    'prv.h2': 'Proof market \u2014 four paths to computation reliability',
    'prv.lead': 'Previously you could only trust the network or trust the app. FCT offers a <strong>fourth option</strong>: clients verify computation directly, trusting no one; and where stronger guarantees are needed, ZK or TEE proofs can be layered on. Heavy computation happens on the prover side, with only low-cost verification on-chain \u2014 computation and verification are decoupled.',
    'prv.tableCap': 'Four authorization and proof paths',
    'prv.th1': 'Authorization path',
    'prv.th2': 'Trust assumption',
    'prv.th3': 'Use case',
    'prv.r1a': 'Public replay',
    'prv.r1b': 'Zero trust (client-side replay verification)',
    'prv.r1c': 'Public functions, open-source verifiers',
    'prv.r2a': 'Authorized-only replay',
    'prv.r2b': 'Verify with an accessToken in hand',
    'prv.r2c': 'Private, restricted state',
    'prv.r3a': 'Authorized ZK',
    'prv.r3b': 'Trust cryptography; proofs verified on-chain',
    'prv.r3c': 'Aggregate proofs over n referenced functions',
    'prv.r4a': 'Authorized TEE',
    'prv.r4b': 'Trust hardware manufacturers',
    'prv.r4c': 'High-throughput, low-latency compute networks',
    'prv.noteH': 'Proof market and finality',
    'prv.note1': 'Provers earn ETHER rewards for supplying proofs; verifiers earn a fee share for verifying them',
    'prv.note2': 'Provers who submit invalid proofs are slashed and permanently disqualified',
    'prv.note3': 'Finality is reached once a state-transition proof is confirmed by more than 2/3 of verifiers \u2014 estimated at second-level latency',
    'prv.note4': 'GateLang\u2019s spec and gateproof generate formal-verification proofs bound to function / container NFTs, verifiable by callers before they call',

    /* security */
    'sec.eyebrow': 'Security model',
    'sec.h2': 'Architecture-level defenses against historical exploits',
    'sec.lead': 'LSM\u2019s side-effect freedom and atomic state transitions eliminate reentrancy, state manipulation and similar attack surfaces at the architectural level. The table below is FCT\u2019s targeted mechanism against major cross-chain and DeFi incidents in recent years.',
    'sec.tableCap': 'Historical security incidents and the targeted LSM mechanism',
    'sec.th1': 'Attack type',
    'sec.th2': 'Representative incidents',
    'sec.th3': '\u201cFlexibility\u201d the attack exploited',
    'sec.th4': 'Targeted LSM mechanism',
    'sec.r1a': 'Validator key compromise',
    'sec.r1b': 'Ronin, Wormhole',
    'sec.r1c': 'Identity trust can be overridden by a majority of signatures',
    'sec.r1d': 'Logic verification replaces identity trust; signatures cannot bypass state-transition rules',
    'sec.r2a': 'Signature / encoding flaw',
    'sec.r2b': 'Wormhole',
    'sec.r2c': 'Runtime \u201clenient\u201d handling of ambiguous input',
    'sec.r2d': 'Deterministic boolean functions; inputs and outputs exhaustively verifiable',
    'sec.r3a': 'Reentrancy',
    'sec.r3b': 'The DAO',
    'sec.r3c': 'External calls opening a window of inconsistent state',
    'sec.r3d': 'Side-effect-free, read-only calls with atomic state transitions',
    'sec.r4a': 'Oracle manipulation',
    'sec.r4b': 'Bonzo Lend',
    'sec.r4c': 'A single data source can be forged',
    'sec.r4d': 'Structural constraints on data provenance + independent client-side reproduction',
    'sec.r5a': 'Governance / configuration error',
    'sec.r5b': 'Kelp DAO',
    'sec.r5c': 'Human configuration can be misled or overlooked',
    'sec.r5d': 'Operational rules hard-coded as state-machine preconditions',
    'sec.r6a': 'Cross-chain finality violation',
    'sec.r6b': 'Nomad, Ronin',
    'sec.r6c': 'Roughness of time-window estimation',
    'sec.r6d': 'Time waits become state conditions; finality is encoded into the logic',
    'sec.chH': 'Execution security',
    'sec.s1t': 'Logic primitive functions are side-effect-free',
    'sec.s1d': 'They cannot call external contracts or write external state, and are physically immune to reentrancy and state manipulation.',
    'sec.s2t': 'DSU is read-only',
    'sec.s2d': 'State is modified uniformly by the container layer; the state manager gatekeeps \u2014 functions only propose a new state.',
    'sec.s3t': 'Invalid proofs are slashed',
    'sec.s3d': 'TEE, ZK and Optimistic paths are selectable; invalid proofs forfeit an ETHER bond.',
    'sec.pathsH': 'Liquidation security',
    'sec.p1t': 'Light-client verification',
    'sec.p1d': 'Target-chain light clients verify the Ethercoin state root; anomalies trigger challenges and slashing.',
    'sec.p2t': 'Limits and challenge period',
    'sec.p2d': 'Per-transaction and periodic limits cap risk exposure; large withdrawals are delayed and released in batches.',
    'sec.p3t': 'Decentralized provers + insurance fund',
    'sec.p3d': 'No single multisig to prevent single points of abuse; part of the protocol treasury covers extreme-case payouts.',
    'sec.pathsNote': 'AI-generated code must pass the gatelang-ai-gate, and AI modules must fail safe \u2014 never shipping unverified code.',

    /* economy */
    'eco.eyebrow': 'Economic model',
    'eco.h2': 'No token \u00b7 everything settles in ETHER',
    'eco.lead': 'FCT has <strong>no native token</strong>. It issues nothing, presells nothing and airdrops nothing \u2014 the economic medium is uniformly ETHER, binding component value directly to on-chain assets with no speculative vehicle.',
    'eco.c1t': 'Uniform ETHER settlement',
    'eco.c1d': 'All fees, royalties, liquidations and rent settle in ETHER \u2014 no token, no inflation, no speculation.',
    'eco.c2t': 'Composition royalties',
    'eco.c2d': 'When a logic primitive function is referenced or composed, its creator earns an ETHER royalty, split from the caller\u2019s fee.',
    'eco.c3t': 'Self-settled costs',
    'eco.c3d': 'The referenced function network bears its own proof costs; the user pays only for their own original function call.',
    'eco.warnT': 'Scam warning',
    'eco.warnD': 'FCT has no token, presale or airdrop of any kind. Any \u201cFCT token\u201d offered for sale, subscription or airdrop is a scam. Do not participate. Several unrelated projects use the \u201cFCT\u201d ticker; rely only on official Ethercoin channels.',

    /* applications */
    'app.eyebrow': 'Application outlook',
    'app.h2': 'Ten project forms the LSM could give rise to',
    'app.lead': 'If oracles solved \u201chow to obtain trusted external data on-chain\u201d and gave rise to Chainlink, then the Logical State Machine (LSM) solves \u201chow to execute logic and manage state on-chain in a verifiable, deterministic, side-effect-free way\u201d. What it may give rise to is not another data network, but a <strong>verifiable logic-and-state layer</strong>.',
    'app.a1t': 'Logical State Machine Network',
    'app.a1d': '<b>Analogy: Chainlink.</b> Nodes run GateLang-compiled logical state machines, offering dApps read-only verification, conditional evaluation, compliance checks and state-commitment verification.',
    'app.a2t': 'Cross-chain verifier marketplace',
    'app.a2d': '<b>LSM-CCV marketplace.</b> Third parties publish formally verified cross-chain verification state machines; issuers pick a security tier by asset value.',
    'app.a3t': 'Compliance state machine network',
    'app.a3d': '<b>For institutional cross-chain and DeFi.</b> KYC/AML, sanctions screening, transaction limits and allowlists compile into logical state machines, integrated with CCIP 2.0\u2019s ACE.',
    'app.a4t': 'Function NFT / container NFT marketplace',
    'app.a4d': '<b>An App Store for on-chain logic.</b> Developers compile verification functions, financial strategies, game rules and insurance conditions into LSMs and publish them as function NFTs.',
    'app.a5t': 'Cross-chain state coordination protocol',
    'app.a5d': '<b>Not an asset bridge, but a state bridge.</b> A source-chain LSM outputs a state root; a target-chain LSM verifies and executes the corresponding state transition.',
    'app.a6t': 'Intent solver network',
    'app.a6d': '<b>Users express intent, LSM defines conditions, solvers compete to execute.</b> Useful for cross-chain swaps, limit orders, auto-rebalancing and automatic insurance claims.',
    'app.a7t': 'Verifiable AI agent network',
    'app.a7d': '<b>AI is the accelerator, formal verification is the guarantor.</b> LSM acts as a constraint layer for AI agent behavior: proposed actions must satisfy preset state-machine rules.',
    'app.a8t': 'State rent and state compression protocol',
    'app.a8d': '<b>CSC + historical Merkle trees + extended Merkle trees.</b> Verify only the state root without expanding full state, reducing full-node storage burden and state bloat.',
    'app.a9t': 'Governance and permission state machines',
    'app.a9d': '<b>Against DAO governance attacks and configuration errors.</b> Governance rules, multisig thresholds, timelocks and permission transfers compile into LSMs; privileged actions must satisfy preset transition sequences.',
    'app.a10t': 'Formal Verification as a Service (FVaS)',
    'app.a10d': '<b>Compile business rules into LSMs automatically and generate proofs.</b> Generate logical state machines from Solidity, a DSL or natural language and output verification reports.',
    'app.concH': 'A modular blockchain stack of \u201cdata + logic + state\u201d',
    'app.concD': 'The most likely outcome is the \u201cLogical State Machine Network\u201d \u2014 an infrastructure layer alongside Chainlink. Chainlink provides data availability; LSM provides verifiability of logic and state. Combined with CCIP 2.0, the two form a modular blockchain stack of \u201cdata + logic + state\u201d.',

    /* roadmap */
    'road.eyebrow': 'Roadmap',
    'road.h2': 'Step-by-step rollout of the spec',
    'road.s1': '2026',
    'road.p1t': 'FCT spec + dual-primitive component development',
    'road.p1a': 'FCT technical components v1.4 enter specification and development; publish the dual-primitive spec and technical component whitepaper',
    'road.p1b': 'Integrate GateLang v2.2 as the unified language tooling; componentize logic primitive functions, DSU, containers, CSC and the proof market',
    'road.p1c': 'Complete component-level verification and integration tests on the Sepolia testnet',
    'road.p1v': 'Current status: M1 Container \u00b7 M2 CSC \u00b7 M3 ProofMarket \u00b7 M4 shared layer \u00b7 M5 logic primitive engine + DSU runtime \u00b7 M6 hybrid mode \u00b7 M7 cross-chain adapter live and verified on Sepolia',
    'road.s2': '2027',
    'road.p2t': 'Ethereum adapter + Robinhood Chain',
    'road.p2a': 'Ethereum adapter audited independently, then mainnet settlement / verifier deployment; identity anchoring, function NFTs and state-root verification',
    'road.p2b': 'Robinhood Chain (Arbitrum Orbit + Nitro) near-zero-cost migration with ~100 ms blocks',
    'road.p2c': 'Priority fees convert entirely into creator royalties; dividend-calculation and compliance-check functions for RWA',
    'road.s3': '2028',
    'road.p3t': 'Solana adapter',
    'road.p3a': 'Logic primitive functions compile to BPF read-only pure programs; Groth16 proofs verified on-chain via alt_bn128 syscalls',
    'road.p3b': 'Share state with the EVM ecosystem through Rome Protocol; leverage Sealevel parallel execution',
    'road.s4': '2029+',
    'road.p4t': 'Multi-chain liquidation autonomy',
    'road.p4a': 'Full adapters for EVM, Solana, Cosmos, Move and Bitcoin L2s',
    'road.p4b': 'Cross-chain function calls, cross-chain royalties, DAO governance and liquidation run autonomously',
    'road.note': 'The above is an architectural plan. The FCT chain is not yet activated and no FCT token has been issued. Each step is independently verifiable; a technical obstacle at one step does not invalidate the achievements of the previous one.',

    /* cta */
    'cta.h2': 'Make on-chain compute a property of the architecture',
    'cta.lead': 'Logic primitives carry computation, containers carry state, ETHER carries value \u2014 FCT is a technical component kit any network can integrate, with safety guaranteed by architecture rather than by application-layer code quality.',
    'cta.b1': 'Download whitepaper v1.4',
    'cta.b2': 'Revisit the primitives',

    /* footer */
    'footer.note': 'Technical component whitepaper v1.4 \u00b7 Logical State Machine (LSM) kit \u00b7 No token'
  };

  var META = {
    zh: {
      title: 'FunctionComplete (FCT) — 逻辑状态机（LSM）技术组件套件',
      desc: 'FCT 不是一条链、不是一个代币、不是 L2 —— 它是 Ethercoin 团队维护的链上计算与状态技术组件套件。FCT 提供的核心技术叫逻辑状态机（Logical State Machine, LSM）：以 NAND 纯函数原语承担计算，以 LATCH 状态原语承担记忆，组合部分为布尔函数，时序部分为有限状态机。'
    },
    en: {
      title: 'FunctionComplete (FCT) — Logical State Machine (LSM) Technical Component Kit',
      desc: 'FCT is not a chain, not a token, and not an L2 — it is a technical component kit for on-chain computation and state management, maintained by the Ethercoin team. Its core technology is formally named the Logical State Machine (LSM): NAND pure-function primitives carry computation, LATCH state primitives carry memory, boolean functions form the combinational part and finite state machines the sequential part.'
    }
  };

  /* ---------- 初始化：快照中文原文 ---------- */
  var nodes = Array.prototype.slice.call(document.querySelectorAll('[data-i18n]'));
  var snapshot = new Map();
  nodes.forEach(function (el) {
    snapshot.set(el, el.innerHTML);
  });

  function setRich(el, value) {
    if (/<[a-z][\s\S]*>/i.test(value)) el.innerHTML = value;
    else el.textContent = value;
  }

  function applyLang(lang) {
    if (lang !== 'en') lang = 'zh';
    var root = document.documentElement;
    root.setAttribute('data-lang', lang);
    root.setAttribute('lang', lang === 'zh' ? 'zh' : 'en');

    nodes.forEach(function (el) {
      var key = el.getAttribute('data-i18n');
      if (lang === 'en' && EN[key] != null) {
        setRich(el, EN[key]);
      } else {
        el.innerHTML = snapshot.get(el);
      }
    });

    var m = META[lang] || META.zh;
    document.title = m.title;
    var d = document.querySelector('meta[name="description"]');
    if (d) d.setAttribute('content', m.desc);

    var wp = 'FCT-whitepaper-zh.md'; // FCT 技术组件白皮书 v1.4（最终版）
    Array.prototype.forEach.call(document.querySelectorAll('[data-wp]'), function (a) {
      a.setAttribute('href', wp);
      a.setAttribute('download', '');
    });

    var gl = 'GateLang-whitepaper-zh.md'; // GateLang 技术白皮书 v2.2（最终版）
    Array.prototype.forEach.call(document.querySelectorAll('[data-gl]'), function (a) {
      a.setAttribute('href', gl);
      a.setAttribute('download', '');
    });

    var btn = document.getElementById('langToggle');
    if (btn) btn.setAttribute('aria-label',
      lang === 'zh' ? 'Switch to English' : '切换为中文');

    try { localStorage.setItem(STORAGE_KEY, lang); } catch (e) { /* 隐私模式忽略 */ }
  }

  /* ---------- 语言切换 ---------- */
  var stored = null;
  try { stored = localStorage.getItem(STORAGE_KEY); } catch (e) { /* ignore */ }
  applyLang(stored || DEFAULT_LANG);

  var toggle = document.getElementById('langToggle');
  if (toggle) {
    toggle.addEventListener('click', function () {
      var next = document.documentElement.getAttribute('data-lang') === 'zh' ? 'en' : 'zh';
      applyLang(next);
    });
  }

  /* ---------- 滚动入场 ---------- */
  var reveals = Array.prototype.slice.call(document.querySelectorAll('.reveal'));
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  if (reduce || !('IntersectionObserver' in window)) {
    reveals.forEach(function (el) { el.classList.add('in'); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          e.target.classList.add('in');
          io.unobserve(e.target);
        }
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    reveals.forEach(function (el) { io.observe(el); });
  }

  /* ---------- 导航当前区块高亮 ---------- */
  var sections = Array.prototype.slice.call(document.querySelectorAll('section[id]'));
  var navLinks = Array.prototype.slice.call(document.querySelectorAll('.nav-links a'));
  if (sections.length && navLinks.length && 'IntersectionObserver' in window) {
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        var id = '#' + e.target.id;
        navLinks.forEach(function (a) {
          var on = a.getAttribute('href') === id;
          a.style.color = on ? 'var(--cy)' : '';
        });
      });
    }, { rootMargin: '-45% 0px -50% 0px' });
    sections.forEach(function (s) { spy.observe(s); });
  }
})();
