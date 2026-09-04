# Steps: ffx-to-c-migration

## Step 1: Analyze Prompt
- Status: done
- Notes: Migration scope is complete rewrite of 705.8k LOC Zig → C with massive complexity increase (async, MCP, terminal UI, threading)

## Step 2: Heavy Thinker (Research & Spec)
- Status: done
- Notes: Analyzed subsystems (core, ui, gateway, builtins, acp, tools); identified rewrite challenges (async runtime, memory safety, terminal state, cross-platform); expanded LOC estimate 1.5x (Zig → C verbosity)

## Step 3: Identify Files
- Status: done
- Notes: Current 611 Zig files → estimated 1,195 C files (headers + sources); mapped major subsystems; identified critical files by complexity

## Step 4: Estimate Lines
- Status: done
- Notes: Zig: 705.8k LOC / 611 files; C: 1.058M LOC / 1,195 files (40-60% expansion due to boilerplate, error handling, memory management)

## Step 5: Calculate Tokens
- Status: done
- Notes: Base: 17.6M tokens (read Zig + write C); Reiteração 8x: 141M tokens; Full iceberg: 403M tokens (including testing, debugging, reasoning)

## Step 6: Final Estimation
- Status: done
- Notes: $24M–$40M USD (Sonnet/Opus), 1.25–2.1 years (3–5 person team), 403M tokens, 60–70% success probability, high C-specific risks (memory, async, cross-platform)
