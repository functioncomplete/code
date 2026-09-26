/* ============================================================
   FunctionComplete v2 — 交互与双语切换
   策略：HTML 内联中文为初始渲染（利于 SEO / 无 JS 可用）；
        JS 在初始化时快照中文原文，英文由词典提供。
        切换时只做「快照恢复 / 词典覆盖」，避免中英文本重复维护。
   内容来源：FunctionComplete 技术组件白皮书 v1.3
   ============================================================ */
(function () {
  'use strict';

  var STORAGE_KEY = 'fct-lang';
  var DEFAULT_LANG = 'zh';

  /* ---------- 英文词典（键与 HTML 的 data-i18n 一一对应） ---------- */
  var EN = {
    /* nav */
    'nav.primitives': 'Primitives',
    'nav.components': 'Components',
    'nav.container': 'Container',
    'nav.provable': 'Provable',
    'nav.economy': 'Economy',
    'nav.roadmap': 'Roadmap',
    'nav.whitepaper': 'Whitepaper',
    'nav.gatelang': 'GateLang',
    'nav.gatelangSec': 'GateLang',
    'nav.gatelangRepo': 'GateLang repo',

    /* hero */
    'hero.badge': 'FCT v2 · Technical component kit · Not an L2, not a token',
    'hero.h1a': 'Gate-level functions + state containers,',
    'hero.h1b': 'compute that physically cannot do harm',
    'hero.h1c': 'as a technical component kit',
    'hero.lead': 'FCT is not a chain, not a token, and not an L2 — it is a technical component kit for on-chain computation and state management: NAND + LATCH gate-level functions carry computation, containers + CSC carry state, built by the Ethercoin team. Any network that wants reliable on-chain compute can integrate FCT components.',
    'hero.cta1': 'Explore the components',
    'hero.cta2': 'Read whitepaper v1.3',
    'hero.cta3': 'GateLang frontend',
    'hero.stat1': 'compute primitives (gate-level functions + DSU)',
    'hero.stat2': 'classes of technical components',
    'hero.stat3': 'tokens (all settlement in ETHER)',

    /* primitives */
    'prim.eyebrow': 'Core concept',
    'prim.h2': 'Two compute primitives',
    'prim.lead': 'FCT builds every capability on just two compute primitives: <strong>gate-level functions</strong> carry computation, and <strong>DSU</strong> carries state. Every component, every proof path and every application scenario rests on these two primitives.',
    'prim.fnT': 'Gate-level functions',
    'prim.fnD': 'NAND gates are functionally complete and LATCH flip-flops store state, expressing arbitrary sequential logic. Side-effect-free, deterministic, composable — physically incapable of doing harm.',
    'prim.dsuT': 'DSU · Unified state interface',
    'prim.dsuD': 'Three tables in one — immutable data, proof list and resolution record — so any client can verify state, trusting no intermediary.',
    'prim.tableCap': 'Key properties of the two primitives',
    'prim.th1': 'Primitive',
    'prim.th2': 'Property',
    'prim.p1k': 'Gate-level function',
    'prim.p1v': 'Side-effect-free: cannot call external contracts or write external state',
    'prim.p2k': 'Gate-level function',
    'prim.p2v': 'Read-only calls: no gas, no transaction',
    'prim.p3k': 'Gate-level function',
    'prim.p3v': 'Deterministic: same inputs and state always yield the same output',
    'prim.p4k': 'Gate-level function',
    'prim.p4v': 'Composable: a function can be referenced as a submodule of another; composition is structural',
    'prim.p5k': 'DSU',
    'prim.p5v': 'Verifiable: data, proofs and resolutions are verified directly by the client, with no trusted third party',
    'prim.p6k': 'DSU',
    'prim.p6v': 'Abstract: agnostic to the carrier (chain, off-chain store, decentralized storage) — only the verifiability of state matters',

    /* gatelang */
    'gl.eyebrow': 'Unified language frontend',
    'gl.h2': 'GateLang v2.1 · the unified verifiable-compute language frontend',
    'gl.lead': 'GateLang takes NAND gates as its only combinational primitive and LATCH as its only state primitive, compiling developer logic into FCT-compatible artifacts through <strong>four layers of abstraction</strong>. Its <code>spec</code> and <code>gateproof</code> generate formal-verification proofs bound to function / container NFTs; AI-assisted development must pass the <code>gatelang-ai-gate</code> gate — <strong>AI is the accelerator, formal verification is the guarantor</strong>.',
    'gl.tableCap': 'GateLang four-layer abstraction',
    'gl.th1': 'Layer',
    'gl.th2': 'Audience and compile target',
    'gl.r1n': 'L1 gate level',
    'gl.r1v': 'Hardware engineers / formal researchers → NAND/LATCH netlist (FCT gate-level on-chain functions)',
    'gl.r2n': 'L2 high-level',
    'gl.r2v': 'Software developers → gate netlist or DSU calls (FCT gate-level functions + container ABI)',
    'gl.r3n': 'L3 domain DSL',
    'gl.r3v': 'Finance / AI / gaming experts → DSU descriptor + dedicated circuits (FCT DSU)',
    'gl.r4n': 'L4 visual',
    'gl.r4v': 'Education users / PMs → auto-generated L1/L2 code (FCT function NFT / container NFT)',
    'gl.dl': 'Download GateLang whitepaper v2.1',
    'gl.repo': 'GateLang repository (GitHub)',
    'gl.toProvable': 'See the proof path',

    /* components */
    'comp.eyebrow': 'Technical components',
    'comp.h2': 'Five classes of on-chain technical components',
    'comp.lead': 'FCT components are <strong>protocol-agnostic</strong>: they presuppose no particular network as their runtime, and instead connect to any network with basic ledger capability through adapters.',
    'comp.c1t': 'Execution · Executable',
    'comp.c1d': 'Gate-level functions (NAND + LATCH) and DSU together carry computation: functions define logic, DSU defines the state interface.',
    'comp.c2t': 'State · State',
    'comp.c2d': 'Containers encapsulate node state; CSC compresses state commitments with history + extended Merkle trees and state rent.',
    'comp.c3t': 'Proof · Provable',
    'comp.c3d': 'Authorized replay, ZK proofs and TEE proofs coexist — users choose freely by security requirement.',
    'comp.c4t': 'Liquidation · Liquidatable',
    'comp.c4d': 'Adapters handle cross-chain liquidation: state root anchoring + asset custody + final arbitration, so chain state changes can be settled.',
    'comp.c5t': 'Identity · Identifiable',
    'comp.c5d': 'Function NFTs and container NFTs: ticket, royalty registry and admin identity in one, with traceable provenance.',
    'comp.c6t': 'Carrier-agnostic',
    'comp.c6d': 'Components do not depend on a specific chain; adapters connect EVM, Solana, Cosmos, Move and Bitcoin L2s, rolled out chain by chain.',

    /* container */
    'ctr.eyebrow': 'State component',
    'ctr.h2': 'Container —— the \u201cbox\u201d of node state',
    'ctr.lead': 'A container carries a node\u2019s state and assets — the network\u2019s <strong>transferable, authorizable</strong> core carrier: transfer the token and you transfer management, and the holder gains full access to the node.',
    'ctr.s1t': 'Transferable',
    'ctr.s1d': 'One-time transferable and non-transferable tokens: transferring the token transfers container ownership.',
    'ctr.s2t': 'Asset loading',
    'ctr.s2d': 'Natively loads ETH, ERC-20 and ERC-721 assets as the node\u2019s economic entity.',
    'ctr.s3t': 'accessToken authorization',
    'ctr.s3d': 'DSU access is governed by accessTokens — granular, revocable authorization.',
    'ctr.s4t': 'Private state commitment',
    'ctr.s4d': 'Internal state is published as a commitment — details stay private while verification is preserved.',
    'ctr.s5t': 'Admin follows ownership',
    'ctr.s5d': 'A container\u2019s admin follows its container NFT\u2019s owner — whoever holds the NFT manages the container.',
    'ctr.usesH': 'Typical use cases',
    'ctr.u1t': 'AI service node',
    'ctr.u1d': 'Paid inference: callers pay ETHER, the node executes a gate-level function and returns results; revenue settles into the container.',
    'ctr.u2t': 'Asset custody',
    'ctr.u2d': 'The container acts as a custody entity loading assets; state roots anchor to the liquidation chain, always liquidatable.',
    'ctr.u3t': 'State rental',
    'ctr.u3d': 'CSC state rent is priced per byte; long-idle state is recycled, with state-market subsidies for rent.',
    'ctr.statusH': 'Development status · v2 dual-primitive component kit',
    'ctr.status1': 'M1 Container · M2 CSC · M3 ProofMarket · M4 shared layer deployed on Sepolia',
    'ctr.status2': 'Demo container tokenId #1 + CSC demo state on-chain; ProofMarket validator vote → reward / slash loop verified',
    'ctr.status3': 'Upcoming milestones: M5 gate engine → M6 hybrid mode → M7 cross-chain adapters.',

    /* provable */
    'prv.eyebrow': 'Proof component',
    'prv.h2': 'Proof market —— four paths to computation reliability',
    'prv.lead': 'Previously you could only trust the network or trust the app. FCT offers a <strong>fourth option</strong>: clients verify computation directly, trusting no one; and where stronger guarantees are needed, ZK or TEE proofs can be layered on.',
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
    'prv.noteH': 'DSU verifiability',
    'prv.note1': 'Data, proofs and resolutions live in one place — any client can verify state updates directly',
    'prv.note2': 'Referenced function networks bear their own proof costs — the caller pays one original function fee',
    'prv.note3': 'The proof market spans replay, ZK and TEE — provable logic interconnects across them',

    /* economy */
    'eco.eyebrow': 'Economic model',
    'eco.h2': 'No token · everything settles in ETHER',
    'eco.lead': 'FCT has <strong>no native token</strong>. It issues nothing, presells nothing and airdrops nothing — the economic medium is uniformly ETHER, binding component value directly to on-chain assets with no speculative vehicle.',
    'eco.c1t': 'Uniform ETHER settlement',
    'eco.c1d': 'All fees, royalties, liquidations and rent settle in ETHER — no token, no inflation, no speculation.',
    'eco.c2t': 'Composition royalties',
    'eco.c2d': 'When a gate-level function is referenced or composed, its creator earns an ETHER royalty, split from the caller\u2019s fee.',
    'eco.c3t': 'Self-settled costs',
    'eco.c3d': 'The referenced function network bears its own proof costs; the user pays only for their own original function call.',
    'eco.warnT': 'Scam warning',
    'eco.warnD': 'FCT has no token, presale or airdrop of any kind. Any \u201cFCT token\u201d offered for sale, subscription or airdrop is a scam. Do not participate.',

    /* roadmap */
    'road.eyebrow': 'Roadmap',
    'road.h2': 'Step-by-step rollout of the spec',
    'road.s1': '2026',
    'road.s2': '2027',
    'road.s3': '2028',
    'road.s4': '2029',
    'road.p1t': 'Spec + dual-primitive component development',
    'road.p1a': 'Publish the FCT v2 dual-primitive spec and technical component whitepaper',
    'road.p1b': 'Build the five component classes: Container, CSC, proof market, DSU, gate engine',
    'road.p1c': 'Complete component-level verification and integration tests on Sepolia',
    'road.p1v': 'Current status: M1 Container · M2 CSC · M3 ProofMarket · M4 shared layer live and verified on Sepolia; gate engine in progress',
    'road.p2t': 'Ethereum adapter + Robinhood Chain',
    'road.p2a': 'Ethereum adapter audited independently, then mainnet liquidation/verifier deployment',
    'road.p2b': 'Robinhood Chain (Arbitrum Orbit + Nitro) near-zero-cost migration',
    'road.p2c': '~100 ms blocks; priority fees convert entirely into creator royalties',
    'road.p3t': 'Solana adapter',
    'road.p3a': 'Gate-level functions compile to read-only pure programs; Groth16 proofs verified on-chain',
    'road.p3b': 'Parallel execution, sub-second confirmation, constant and predictable verification cost',
    'road.p4t': 'Multi-chain liquidation autonomy',
    'road.p4a': 'Full adapters for EVM, Solana, Cosmos, Move and Bitcoin L2s',
    'road.p4b': 'Cross-chain liquidation and royalty settlement run autonomously',

    /* cta */
    'cta.h2': 'Make on-chain compute a property of the architecture',
    'cta.lead': 'Gate-level functions carry computation, containers carry state, ETHER carries value — FCT is a technical component kit any network can integrate, with safety guaranteed by architecture rather than by application-layer code quality.',
    'cta.b1': 'Download whitepaper v1.3',
    'cta.b2': 'Revisit the primitives',

    /* footer */
    'footer.note': 'Technical component whitepaper v1.3 · Dual-primitive kit · No token'
  };

  var META = {
    zh: {
      title: 'FunctionComplete (FCT) — 技术组件套件 · 门级函数 + 状态容器',
      desc: 'FCT 不是一条链、不是一个代币、不是 L2 —— 它是一套链上计算与状态管理技术组件：以 NAND + LATCH 门级函数承担计算，以容器 + CSC 承担状态，由 Ethercoin 团队构建。任何想提供可靠链上计算服务的网络的理想组件。'
    },
    en: {
      title: 'FunctionComplete (FCT) — Technical Component Kit · Gate-level Functions + State Containers',
      desc: 'FCT is not a chain, not a token, and not an L2 — it is a technical component kit for on-chain computation and state management: NAND + LATCH gate-level functions carry computation, containers + CSC carry state, built by the Ethercoin team. The ideal component kit for any network that wants reliable on-chain compute.'
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

    var wp = 'FCT-whitepaper-zh.md'; // 目前仅中文版；英文版待补（v1.3 起网站尚未同步）
    Array.prototype.forEach.call(document.querySelectorAll('[data-wp]'), function (a) {
      a.setAttribute('href', wp);
      a.setAttribute('download', '');
    });

    var gl = 'GateLang-whitepaper-zh.md'; // GateLang 语言前端白皮书（v2.1）
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