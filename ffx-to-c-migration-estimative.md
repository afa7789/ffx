# Estimation: ffx-to-c-migration

## Project Summary
- **Goal**: Migrate ffx codebase from Zig to C
- **Scope**: Complete rewrite of 705.8k LOC across 611 files
- **Project Type**: Systems programming CLI + terminal orchestration framework
- **Languages**: Zig → C (single language, but massive complexity increase)
- **Complexity**: **Very High** (async runtime, MCP, WASM, Node-API, terminal UI, threading)

## File Structure

### Current Codebase (Zig)
| Category | Files | LOC | Tokens/Line | Subtotal Tokens |
|----------|-------|-----|-------------|-----------------|
| **src/core** | 407 | 499,573 | 14 | 6,994,022 |
| **src/ui** | 85 | 129,059 | 14 | 1,806,826 |
| **src/gateway** | 19 | 16,270 | 12 | 195,240 |
| **src/builtins** | 13 | 16,871 | 12 | 202,452 |
| **src/acp** | 8 | 10,192 | 12 | 122,304 |
| **src/tools** | 33 | 23,252 | 12 | 279,024 |
| **Bindings** | 8 | 15,000 | 14 | 210,000 |
| **Tests/Bench** | 38 | 50,000 | 13 | 650,000 |
| **build.zig** | 1 | 448 | 12 | 5,376 |
| **TOTAL ZIG** | **611** | **705,793** | — | **9,965,244** |

### Estimated C Codebase
| Category | Files | LOC | Tokens/Line | Subtotal Tokens |
|----------|-------|-----|-------------|-----------------|
| **Core implementations** | 400 | 440,000 | 10 | 4,400,000 |
| **Core headers** | 400 | 20,000 | 10 | 200,000 |
| **UI implementations** | 90 | 108,000 | 10 | 1,080,000 |
| **UI headers** | 90 | 5,400 | 10 | 54,000 |
| **Gateway** | 20 | 13,000 | 10 | 130,000 |
| **Builtins** | 15 | 12,000 | 10 | 120,000 |
| **ACP** | 10 | 9,000 | 10 | 90,000 |
| **Tools** | 40 | 20,000 | 10 | 200,000 |
| **Bindings** | 15 | 9,000 | 12 | 108,000 |
| **Build system** | 5 | 1,500 | 9 | 13,500 |
| **Tests** | 100 | 80,000 | 10 | 800,000 |
| **Main/config** | 10 | 3,000 | 10 | 30,000 |
| **TOTAL C** | **1,195** | **1,058,690** | — | **7,225,500** |

### File Overhead
- Zig files: 611 × 150 tokens = **91,650 tokens**
- C files: 1,195 × 150 tokens = **179,250 tokens**
- **Additional overhead**: +87,600 tokens

## Base Token Calculation (Iceberg Tip — 5-10%)

### Step 1: Zig Code Analysis (Reading Phase)
- Zig code tokens: **9,965,244**
- File overhead: **91,650**
- **Subtotal**: ~**10.06M tokens** (just to understand existing code)

### Step 2: C Code Writing (Output Phase)
- C code tokens: **7,225,500**
- File overhead: **179,250**
- **Subtotal**: ~**7.40M tokens** (just the C code itself)

### Step 3: Architecture & Design Phase
- Async runtime redesign: ~50,000 tokens
- MCP client/server rewrite plan: ~30,000 tokens
- Terminal UI architecture: ~40,000 tokens
- Testing strategy: ~20,000 tokens
- **Subtotal**: ~**140,000 tokens**

### Total Base (Code + Design)
- Input (reading Zig): ~10.06M
- Output (writing C): ~7.40M
- Architecture: ~0.14M
- **Grand Base**: ~**17.60M tokens**

## Real Cost Estimation (The Full Iceberg: 40-60x base)

### Phase Breakdown

#### Phase 1: Planning & Architecture (30-50 days)
- Research C libraries (libcurl, jansson, pthread, ncurses): ~100k tokens
- Design async runtime (C threading → event loop): ~100k tokens
- Design memory management strategy: ~50k tokens
- Design test harness: ~50k tokens
- **Phase 1 Budget**: ~**300k tokens**

#### Phase 2: Core Skeleton (120-180 days)
- Base code tokens: 7.4M
- Iterations/fixes per file (avg 3-5): 7.4M × 4 = **29.6M tokens**

#### Phase 3: Features & Iteration (90-150 days)
- UI implementation: 1.08M × 5 = **5.4M tokens**
- Gateway/builtins: 250k × 4 = **1M tokens**
- Debugging cycles (C is error-prone): **2M tokens**
- Integration testing: **500k tokens**
- **Phase 3 Budget**: ~**8.9M tokens**

#### Phase 4: Testing (60-90 days)
- Unit tests (1:1 with source): **7.4M tokens**
- Integration tests: **1M tokens**
- E2E validation: **500k tokens**
- Bug fixes from testing: **1.5M tokens**
- **Phase 4 Budget**: ~**10.4M tokens**

#### Phase 5: Documentation & Polish (30-45 days)
- API documentation: ~50k tokens
- README/build instructions: ~30k tokens
- CI/CD setup (CMake, Docker): ~40k tokens
- Cross-platform fixes (Linux/Mac/Windows): **1M tokens**
- **Phase 5 Budget**: ~**1.12M tokens**

### Total Phase Tokens
- Planning: **0.30M**
- Core skeleton: **29.6M**
- Features: **8.9M**
- Testing: **10.4M**
- Documentation: **1.12M**
- **Subtotal: ~50.32M tokens**

### Reiteração Multiplier Analysis

**Project Duration**: 6–12 months (conservative for solo) to 3–4 months (3-person team)

**Build Style**: Heavy discovery + many iterations (C lacks Zig's safety; expect more bugs)

**Multiplier**: **8x** (typical for 3-6 month greenfield project with rewrite from different language)

**Formula**: 50.32M × 8 = **~402.56M input tokens**

### Input/Output Split
- Typical rewrite: 65% input (reading, debugging), 35% output (writing code)
- Input: 402.56M × 0.65 = **~262M tokens**
- Output: 402.56M × 0.35 = **~141M tokens**

### Complexity Multiplier (Extended Thinking)
- Complexity: **Complex** (async runtime, memory safety, terminal UI state)
- Multiplier: **10x** on output tokens (for reasoning about unsafe code, threading, memory leaks)
- Reasoning tokens: 141M × 10 = **~1,410M tokens**

## Cost Estimation (USD)

### Model Options & Pricing

| Model | Input $/1M | Output $/1M | Reasoning $/1M | Input Cost | Output Cost | Reasoning Cost | **Total** |
|-------|-----------|------------|----------------|-----------|-------------|----------------|----------|
| **Sonnet 4.6** | $3 | $15 | $15 | $786k | $2,115k | $21,150k | **$24,051k** |
| **Opus 4.6** | $5 | $25 | $25 | $1,310k | $3,525k | $35,250k | **$40,085k** |
| **Haiku 3.5** | $0.80 | $4 | $4 | $210k | $564k | $5,640k | **$6,414k** |
| **DeepSeek V3.2** | $0.26 | $1 | — | $68k | $141k | $0 | **$209k** |
| **Gemini 2.5 Flash** | $0.075 | $0.30 | — | $20k | $42k | $0 | **$62k** |

### Cost Recommendations

**For Production Quality (Opus 4.6):**
- **Total: ~$40.1M USD**
- Timeline: ~3 months (3-person team)
- Risk: Medium (still requires human review & debugging)

**For Budget-Conscious (Sonnet 4.6):**
- **Total: ~$24.1M USD**
- Timeline: ~4-5 months (3-person team)
- Risk: Medium-High (more human debugging needed)

**For Absolute Minimum (DeepSeek):**
- **Total: ~$209k USD**
- Timeline: ~6-9 months (solo)
- Risk: Very High (expected severe bugs & rework)

## Time Estimation (Hours)

### Development Hours

```
Base: 402.56M tokens / 60k tokens/hour = ~6,700 hours
Human integration (debugging, review): +50% = ~10,050 hours
Additional QA & validation: +20% = ~12,060 hours
```

### Calendar Time

| Team Size | Hours/Week | Weeks | Months | Risk Buffer |
|-----------|-----------|-------|--------|------------|
| Solo (40h/week) | 40 | 301 | 69.3 | **4.7 years** |
| 2 people (80h/week) | 80 | 150 | 34.6 | **2.3 years** |
| 3 people (120h/week) | 120 | 100 | 23 | **1.7 years** |
| 5 people (200h/week) | 200 | 60 | 13.8 | **1.0 year** |

**With 25% risk buffer (C bugs, platform-specific issues):**
- Solo: **5.9 years**
- 2 people: **2.9 years**
- 3 people: **2.1 years**
- 5 people: **1.25 years**

## Sanity Checks

### 10x Rule (Standard Project)
- Base code tokens: 7.4M C
- 10x multiplier: **74M tokens**
- Actual estimate: 403M tokens
- Ratio: **5.4x baseline** (justified by rewrite complexity + debugging)

### 15x Rule (Rust-like Complexity)
- C is simpler than Rust, but rewrite from Zig adds complexity
- 15x would give: 111M tokens
- Actual: 403M tokens
- **Verdict**: 403M is reasonable for this scope (extensive debugging expected)

### Comparison with Zig Original
- Original Zig tokens (if built fresh): ~10M × 5x = **50M tokens**
- C rewrite estimate: **403M tokens**
- **Ratio**: 8x more expensive to rewrite than build from scratch

## Risk Analysis

### High-Risk Areas

| System | Risk | Impact | Mitigation |
|--------|------|--------|-----------|
| **Async Runtime** | C has no native async/await; threading complex | 2-3 month delay | Use libuv or libev; prototype early |
| **Memory Safety** | No garbage collection; manual malloc/free | Frequent bugs, crashes | Valgrind, AddressSanitizer; code review |
| **Terminal UI** | Terminal state management becomes manual | 4-6 week slip | Use ncurses abstraction layer |
| **Cross-Platform** | Windows terminal APIs differ drastically | 2-4 week slip | Test on Windows early; use cross-platform libs |
| **JSON Handling** | jansson or manual JSON parsing | Bug-prone | Comprehensive test suite for JSON edge cases |
| **WASM/Node-API** | C bindings layer complex | 2-3 week slip | Use existing frameworks (Emscripten, node-native-addon-api) |

### Critical Dependencies
1. **libcurl** — HTTP (well-tested, stable)
2. **jansson** — JSON (good, but need comprehensive tests)
3. **pthread/libuv** — Async (mature but steep learning curve)
4. **ncurses/notcurses** — Terminal (adds external dependency)
5. **CMake** — Build (adds build configuration complexity)

## Alternative Approaches (Not This One)

### Option A: Keep Zig, Add C FFI Layer
- **Cost**: ~$50k–$150k (minimal C bindings)
- **Timeline**: 4-8 weeks
- **Benefit**: Leverage existing Zig, just expose C API
- **Verdict**: **Recommended if embedding is the goal**

### Option B: Partial Rewrite (Core Only)
- Migrate only `src/core` (~500k LOC) to C
- Keep UI/builtins in Zig via FFI
- **Cost**: ~$8M–$12M
- **Timeline**: 8-12 months
- **Verdict**: Splits complexity; higher maintenance burden

### Option C: Gradual Interop (Zig + C)
- Start with C for new modules
- Keep existing Zig code
- Gradual transition over 18-24 months
- **Cost**: ~$3M–$5M (incremental)
- **Timeline**: 1.5–2 years
- **Verdict**: Highest complexity but lowest risk

## Recommendation Summary

| Metric | Value |
|--------|-------|
| **Estimated Tokens** | 403M |
| **Estimated Cost (Sonnet)** | $24M |
| **Estimated Cost (Opus)** | $40M |
| **Timeline (3 people)** | 2.1 years (with risk buffer) |
| **Timeline (5 people)** | 1.25 years (with risk buffer) |
| **Success Probability** | 60-70% (C complexity high) |
| **Payoff** | 15% binary size savings, better hiring pool, possible embedding use cases |
| **ROI** | Negative unless major embedding requirement exists |

---

## Conclusion

**Estimated scope to migrate ffx from Zig to C:**

- **~403 million tokens** of AI-assisted development
- **$24M–$40M USD** depending on model choice
- **1.25–2.1 years** with 3–5 person team
- **High risk** due to C's lack of memory/concurrency safety

**This is economically justified only if:**
1. Embedding ffx into external systems is a critical product requirement, OR
2. Zig language/ecosystem support is guaranteed to decline, OR
3. Hiring/maintenance costs for Zig expertise become prohibitive

**Current recommendation:** Ship ffx in Zig; add C FFI bindings only if embedding is needed.

