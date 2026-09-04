# File Paths: ffx-to-c-migration

## Current Zig Structure (611 files, ~706k LOC)

### Core Subsystems

#### src/core (407 files, ~499k LOC)
- `mcp/` — MCP client/server runtime (18k LOC)
- `session/` — Session state, storage, lifecycle (38k LOC)
- `app/` — App state machine, lifecycle, input/render runtime (50k LOC)
- `terminal/` — Terminal abstraction, engine, store (33k LOC)
- `subagent/` — Subagent manager, execution, communication (38k LOC)
- `tooling/` — Tool runtime, admission, execution (22k LOC)
- `agent/` — Agent orchestration, worker runtime (25k LOC)
- `config/` — Configuration, settings, providers (15k LOC)
- `cli/` — CLI surface, ask command, doctor (18k LOC)
- `shared/` — Unicode data, common utilities (35k LOC)
- `background/` — Background task runtime (10k LOC)
- `output/` — Output formatting, display (12k LOC)
- Other core modules (~150k LOC)

#### src/ui (85 files, ~129k LOC)
- `transcript/` — Transcript rendering, runtime, tests (40k LOC)
- `render_engine/` — Terminal rendering, diff, blocks (15k LOC)
- `subagent/` — Subagent UI runtime (10k LOC)
- `input/` — Input handling runtime (6k LOC)
- Screen implementations (`*_screen.zig`) — Full transcript, approval, skills, settings, models (30k LOC)
- UI components and layouts (~20k LOC)

#### src/gateway (19 files, ~16k LOC)
- `client.zig` — External gateway communication (7.3k LOC)
- Supporting modules for request/response handling

#### src/builtins (13 files, ~17k LOC)
- `tools.zig` — Built-in tool definitions (3k LOC)
- `providers.zig` — Model provider configuration
- `skills.zig` — Skill definitions and execution (2k LOC)
- `hooks.zig` — Hook registration (200 LOC)
- `gateway.zig` — Gateway integration (2.8k LOC)

#### src/acp (8 files, ~10k LOC)
- `prompt.zig` — ACP prompt building (4.3k LOC)
- `server.zig` — ACP server implementation (3.5k LOC)
- Supporting modules

#### src/tools (33 files, ~23k LOC)
- Tool implementations and integrations
- Distributed across multiple tool types

### Bindings & Main Entries (8 files, ~15k LOC)
- `src/main.zig` — CLI entry point (3.9k LOC)
- `src/napi_core_main.zig` — Node-API binding (0.9k LOC)
- `src/wasm_core_main.zig` — WASM binding (0.1k LOC)
- `src/napi_fetch_state.zig` — Node-API fetch state (0.3k LOC)
- Others for testing/benchmarking

### Build System
- `build.zig` — Zig build configuration (~450 LOC)

## C Equivalent Structure (Estimated 1,200+ files, ~1.06M LOC)

### Directory Structure (Estimated)

```
src-c/
├── core/
│   ├── mcp/
│   │   ├── mcp_runtime.c / .h
│   │   ├── mcp_*.c / .h (10+ files)
│   ├── session/
│   │   ├── session.c / .h
│   │   ├── session_store.c / .h
│   │   ├── session_*.c / .h (15+ files)
│   ├── app/
│   │   ├── app.c / .h
│   │   ├── app_lifecycle.c / .h
│   │   ├── app_*.c / .h (20+ files)
│   ├── terminal/
│   │   ├── terminal.c / .h
│   │   ├── terminal_engine.c / .h
│   │   ├── terminal_*.c / .h (15+ files)
│   ├── subagent/
│   │   ├── subagent_manager.c / .h
│   │   ├── subagent_*.c / .h (15+ files)
│   ├── tooling/
│   ├── agent/
│   ├── config/
│   ├── cli/
│   ├── shared/
│   ├── background/
│   └── output/
├── ui/
│   ├── transcript/
│   │   ├── transcript.c / .h
│   │   ├── transcript_renderer.c / .h
│   │   ├── transcript_*.c / .h (10+ files)
│   ├── render_engine/
│   ├── screens/
│   ├── components/
│   └── ui_*.c / .h
├── gateway/
├── builtins/
├── acp/
├── tools/
├── bindings/
│   ├── napi_bindings.c
│   ├── wasm_bindings.c
│   └── bindings.h
├── main.c
└── main_*.c (variants for WASM, etc.)

build/
├── Makefile
├── CMakeLists.txt
├── config.h.in
└── configure (Autoconf)

tests-c/
├── unit/
│   ├── core/
│   ├── ui/
│   ├── gateway/
│   └── *.c (test files)
├── integration/
├── fixtures/
└── CMakeLists.txt

include/
├── ffx.h (main API)
├── core.h
├── ui.h
├── gateway.h
└── *.h (header library)
```

### Estimated File Distribution (C)

| Category | Files | Avg LOC/File | Total LOC |
|----------|-------|--------------|-----------|
| Core implementations | 400 | 1,100 | 440k |
| Headers (core) | 400 | 50 | 20k |
| UI implementations | 90 | 1,200 | 108k |
| Headers (UI) | 90 | 60 | 5.4k |
| Gateway | 20 | 650 | 13k |
| Builtins | 15 | 800 | 12k |
| ACP | 10 | 900 | 9k |
| Tools | 40 | 500 | 20k |
| Bindings | 15 | 600 | 9k |
| Build system | 5 | 200 | 1k |
| Tests | 100 | 800 | 80k |
| Main/config | 10 | 300 | 3k |
| **TOTAL** | **~1,195** | — | **~1,058,690** |

## Key Files for Rewrite (by complexity)

### High Priority (Complexity: Very High)
1. `src/core/mcp/mcp_runtime.zig` (18k) → C async coordination nightmare
2. `src/core/session/session_store.zig` (13.8k) → Manual state tracking
3. `src/core/app/app_input_runtime.zig` (13.8k) → Event loop redesign
4. `src/core/app/app_session_runtime.zig` (9.9k) → Thread safety challenges
5. `src/ui/full_transcript_screen.zig` (8.3k) → Complex state management

### Medium Priority (Complexity: High)
- `src/core/subagent/manager.zig` (11.9k)
- `src/core/subagent/execution.zig` (8.9k)
- `src/ui/transcript/runtime.zig` (11.9k)
- `src/core/agent/runtime/orchestrator.zig` (7.5k)

### Lower Priority (Complexity: Medium)
- Gateway, builtins, tools, acp modules
- Can be tackled after core runtime stabilizes

## Dependencies & Implications

### External Libraries Needed (Not in Zig)
- **libcurl** — HTTP client (gateway communication)
- **jansson** or **cjson** — JSON parsing/encoding
- **ncurses** or **notcurses** — Terminal UI (if keeping rich TUI)
- **openssl** or **mbedtls** — TLS/crypto
- **pthread** — Threading (for async simulation)
- **CMake** or **Autoconf** — Build system
- **Check** or **CMocka** — Testing framework

### Platform Support
- Linux: straightforward (POSIX APIs)
- macOS: POSIX with some Darwin-specific fixes
- Windows: requires MinGW or MSVC; terminal APIs differ significantly
- Cross-compilation: CMake/Autoconf; no longer as seamless as Zig

