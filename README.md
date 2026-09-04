```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://ffx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

ffx is a coding agent harness and CLI written in Zig, optimized for research and embeddability as part of larger systems.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and 7.8 MiB binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## Install

```bash
curl -fsSL https://ffx.sh/setup.sh | bash
```

## Run ffx

Connect a provider with an API key:

```bash
ffx login
```

Choose a provider directly:

```bash
ffx login openai
ffx
```

The current registry includes OpenAI, Anthropic, DeepSeek, Z.AI, Alibaba Cloud, OpenRouter, MiniMax, Zhipu, and OpenCode Go. Use `ffx login <provider>` to connect or replace a provider key. Use `/login` during an active session to reconnect or switch without discarding the conversation.

```bash
ffx login deepseek
ffx
```

The footer shows the active provider, its billing mode, and local session usage, for example `OpenAI PAYG spent $1.23` or `Opencode Go TOKEN PLAN used 18k`. This is local observed usage, not a remote balance. When a provider does not expose its balance, ffx reports it as unknown instead of claiming that the plan is exhausted.

To configure a key interactively:

```bash
ffx setup
```

Run ffx from a project:

```bash
cd your_project
ffx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands.

The status line hides the workspace path and Git branch by default. Enable the `Status line workspace` option in `/settings`, run `/statusline workspace`, or set it in `~/.ffx/settings.json`:

```json
{
  "statusLine": {
    "workspace": true
  }
}
```

List saved sessions with `ffx sessions`. Resume the latest session for the current workspace, or select an exact session ID, through the same command group:

```bash
ffx session resume last
ffx session resume --id <id>
```

Each interactive session names its terminal tab. The title prefers the session name, falls back to the workspace name, and keeps the active model as secondary context. Renaming or resuming a session updates the tab, and exiting clears the ffx-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/feedback` to open the feedback form at `ffx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, ffx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `ffx ask` for a single request:

```bash
ffx ask "explain the changes in this repository"
```

ffx starts in `auto` permission mode. Routine understood development actions run directly; unresolved sensitive actions receive one bounded automatic review. A blocked action may return an exact approval request that the agent can send to ffx's real permission screen. Ordinary question text never grants permission. See [Permissions](https://ffx.sh/docs/configure-ffx/permissions) for other modes and persistent rules.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow the existing Y/N approval prompt when stdin is a TTY. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed ffx

ffx builds as a native binary or WebAssembly. Applications embedding ffx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `ffx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `ffx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `ffx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://ffx.sh/docs/using-ffx/acp).

## Extend ffx

Add reusable instructions with [skills](https://ffx.sh/docs/capabilities/skills), connect external tools through [MCP](https://ffx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://ffx.sh/docs/capabilities/subagents). Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FFX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `ffx status` and `ffx doctor` report an invalid trusted MCP profile without starting its servers.

## Documentation

Read the [ffx documentation](https://ffx.sh/docs).

## Build from source

Building ffx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/ffx.git
cd ffx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/ffx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
