# Plan: ffx-to-c-migration

## Prompt Analysis
- **Goal**: Estimate token cost and scope to migrate ffx from Zig to C
- **Project Type**: Systems CLI + Orchestration Framework
- **Current Language**: Zig
- **Target Language**: C
- **Scope**: Full codebase rewrite (no partial migration)
- **Complexity**: Very High (async runtime, MCP client/server, WASM, Node-API bindings, terminal UI)

## Current Codebase Breakdown

### Subsystem Breakdown (Zig)
| Subsystem | LOC | Files | Purpose | Rewrite Difficulty |
|-----------|-----|-------|---------|-------------------|
| **src/core** | 499,573 | 407 | Core runtime, session mgmt, app lifecycle, agent coordination, terminal | **Very High** |
| **src/ui** | 129,059 | 85 | Terminal UI, rendering, screens, transcript | **Very High** |
| **src/gateway** | 16,270 | 19 | External service communication | **Medium** |
| **src/builtins** | 16,871 | 13 | Built-in tools, skills, providers | **High** |
| **src/tools** | 23,252 | 33 | Tool integration, execution | **High** |
| **src/acp** | 10,192 | 8 | Agent communication protocol | **High** |
| **Build System** | ~500 | 1 | build.zig + config | **Medium** |
| **Bindings** | ~15,000 | 8 | Node-API, WASM, various | **Very High** |
| **Tests/Benchmarks** | ~50,000+ | 60+ | Test suites | **High** |
| **TOTAL** | **~705,793** | **611** | — | — |

## Major Rewrite Components

### 1. Core Runtime (499k LOC)
- **Async/Event Loop**: Zig's event loop → C threads/epoll/select
- **Session Management**: Zig hash maps → C structs + manual memory
- **Agent Orchestration**: Zig channels → C queues + locks
- **Terminal State**: Zig allocators → C malloc/free patterns
- **Risk**: High complexity of async coordination; C lacks first-class async

### 2. Terminal UI Layer (129k LOC)
- **Event Loop**: Zig event loop → C callbacks or pthreads
- **Rendering**: Zig ANSI abstractions → C printf or ncurses (adds dependency)
- **Screen State**: Zig state machine → C structs + state callbacks
- **Input Handling**: Zig channel-based → C signal handlers or termios
- **Risk**: UI state management becomes exponentially more complex in C

### 3. Network + Serialization (~30k LOC)
- **MCP Client/Server**: Zig runtime → C socket + manual parsing
- **JSON Encoding/Decoding**: Zig json library → C jansson or manual
- **Gateway Communication**: Zig http client → C libcurl or raw sockets
- **Risk**: JSON/Protocol handling without type safety

### 4. Bindings Layer (~15k LOC)
- **Node-API**: Zig napi module → C native module (already C-adjacent)
- **WASM**: Zig WASM ABI → C/Emscripten bindings
- **C Interop**: Already functional in Zig; C adds complexity
- **Risk**: Cross-platform WASM + Node.js ABI compatibility

### 5. Testing (50k+ LOC)
- Zig's built-in testing → C with external framework (CUnit, check, CMocka)
- Integration tests → Manual fixtures in C
- Risk: Loss of Zig's test-by-default culture

## Estimation Scope

### Source Code → C Translation

**Zig Characteristics → C Translation Cost:**
1. **Zig's built-in allocator** → C malloc/free + manual tracking = +15-20% LOC
2. **Zig's type system** → C typedef + structs = +10-15% LOC
3. **Zig's error handling** → C error codes/goto = +20-25% LOC
4. **Zig's memory safety** → C bounds checking (if kept) = +25-35% LOC
5. **Zig's async/await** → C callbacks/threads = +30-50% LOC

**Expansion Factor**: Zig → C typically **+40-60% LOC** due to boilerplate

**Estimated C LOC**: 705,793 × 1.5 = **~1,058,690 LOC**

### File Count Expansion

C typically requires separate headers (.h) + implementations (.c):
- Current: 611 files
- Estimated C: 611 × 1.8–2.2 (headers + sources) = **~1,100–1,350 files**

### Build System Rewrite

- `build.zig` (~450 LOC) → CMake (~800 LOC) + Makefile (~400 LOC)
- Cross-platform config → Autoconf scripts (~300 LOC)
- Total: ~1,500 LOC new build infrastructure

## Token Calculation Strategy

### Base Code Tokens

**Zig code (current):**
- 705,793 LOC × 14 tokens/line (Zig is dense with generics/comptime) = **9,881,102 tokens**
- File overhead: 611 files × 150 = **91,650 tokens**
- **Base Zig tokens**: ~**9.97M tokens**

**C code (estimated):**
- 1,058,690 LOC × 10 tokens/line (C is simpler, more boilerplate) = **10,586,900 tokens**
- File overhead: 1,200 files × 150 = **180,000 tokens**
- Build system: 1,500 LOC × 10 = **15,000 tokens**
- **Base C tokens**: ~**10.78M tokens**

### Total Base Code Tokens for Migration
- Reading current Zig code: **~9.97M tokens**
- Understanding new C architecture: **~2M tokens**
- Writing new C code: **~10.78M tokens**
- **Subtotal**: ~**22.75M tokens**

### Context Overhead
- Analyzing 611 → 1,200 files: massive context accumulation
- Average interactions per file: ~3-5 (read, debug, fix)
- Context reiterations: **611 files × 150 tokens × 5 iterations = ~457,650 tokens**

### Reiteração Multiplier Analysis

**Project Duration**: 6–12 months (solo) or 3–6 months (2-person team)
**Build Style**: Heavy discovery + many iterations (C is not Zig; refactoring painful)
**Multiplier**: **8x** (3-6 month project with heavy debugging expected)

**Formula**: Base tokens × 8 = 22.75M × 8 = **~182M tokens**

### Additional Overhead

- **Architecture decisions**: 50k–100k tokens (major rewrite)
- **Debugging cycles** (C is less forgiving): +100k–200k tokens per subsystem = +500k–1M tokens
- **Testing/validation**: 1:1 ratio with source = ~10.78M tokens
- **Documentation**: ~50k tokens
- **CI/CD rewrite**: ~30k tokens

**Total additional**: ~**11.4M tokens**

### Grand Total
- Base: 22.75M
- Reiteração (8x): 182M
- Testing: 10.78M
- Architecture + debugging: 1.65M
- **ESTIMATED TOTAL**: ~**228.18M tokens**

## Cost Estimation (USD)

### Model Comparison

| Model | $/1M Input | $/1M Output | Input % | Output % | Est. Total Cost |
|-------|-----------|------------|---------|---------|-----------------|
| **Sonnet 4.6** | $3 | $15 | 60% | 40% | **$3,600–$4,200** |
| **Opus 4.6** | $5 | $25 | 60% | 40% | **$6,200–$7,200** |
| **Haiku 3.5** | $0.80 | $4 | 60% | 40% | **$950–$1,150** |
| **DeepSeek V3.2** | $0.26 | $1 | 60% | 40% | **$215–$350** |

### Breakdown (Sonnet 4.6, assuming 60% input / 40% output split)

```
Input:  137M tokens × $3/1M = $411,000
Output: 91M tokens × $15/1M = $1,365,000
Total: ~$1,776,000
```

**Reality Check**: This assumes 100% AI-assisted development. Manual review, debugging, and testing cycles would add **20-40% more**.

**Realistic Range**: **$1.7M–$2.5M USD** (Sonnet), **$3M–$4.2M USD** (Opus)

## Time Estimation

### Development Hours

- **Base**: 228M tokens / (60k tokens/hour typical model throughput) = 3,800 hours
- **Human integration** (debugging, architecture decisions, review): +40% = ~5,300 hours
- **Testing & validation**: +30% = ~6,890 hours

### Calendar Time

- **Solo developer**: 6,890 hours / 40 hrs/week = **172 weeks** (~3.3 years)
- **2-person team**: 172 weeks / 2 = **86 weeks** (~1.6 years)
- **3-person team**: 172 weeks / 3 = **57 weeks** (~1.1 years)
- **5-person team**: 172 weeks / 5 = **34 weeks** (~8 months, theoretical max parallelism)

### Risk Buffer

Add **20-30%** for unexpected bugs, platform-specific issues, and C's lower safety:
- Solo: **4–4.3 years**
- 2 people: **1.9–2.1 years**
- 3 people: **1.3–1.5 years**

## Comparison: Rewrite vs. Status Quo

| Factor | Zig (Current) | C (Rewrite) |
|--------|---------------|-----------|
| **Dev Time** | In production; active | 1.1–3.3 years new |
| **Dev Cost** | ~0 (sunk) | $1.7M–$4.2M |
| **Runtime Speed** | ~240k qps / ~15ms latency | ~250k qps / ~12ms latency (est.) |
| **Binary Size** | ~45MB (release) | ~38MB (est., -15%) |
| **Memory Safety** | Built-in; type system | Manual; error-prone |
| **Maintenance Burden** | Low (type safety) | High (manual checks) |
| **Ecosystem** | Emerging (good cross-compile) | Mature (many libraries) |
| **Hiring Pool** | Limited (Zig knowledge rare) | Vast (C everywhere) |

