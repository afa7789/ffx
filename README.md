```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://raw.githubusercontent.com/afa7789/ffx/main/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

# ffx

ffx is a small, native coding agent written in Zig. It is a community fork of
[FX](https://fx.sh/) focused on provider freedom: use OpenAI-compatible,
Anthropic, self-hosted, or other supported endpoints with their own
credentials. A Vercel account or Vercel login is not required for direct
providers.

## Connect a provider

Choose a direct provider and provide its API key:

```bash
export OPENAI_API_KEY="..."
ffx login openai
ffx
```

A key can also be configured with `ffx setup`. The `login` command remains
available for providers that support a sign-in flow, but ffx does not force a
Vercel login. During a session, `/setup`, `/connect-provider`, and
`/switch-provider` manage connections.
Available providers include OpenAI, Anthropic, DeepSeek, OpenRouter, PPQ,
MiniMax, Zhipu, Z.AI, Alibaba Cloud, and OpenCode.

For an OpenAI-compatible endpoint that is not in the registry:

```bash
export FFX_PROVIDER_API_KEY="..."
export FFX_PROVIDER_BASE_URL="https://models.example.com/v1"
ffx
```

You can also save a custom provider in `~/.ffx/settings.json`:

```json
{
  "provider": "team-models",
  "model_preferences": { "team-models": "private-model" },
  "providers": {
    "team-models": {
      "id": "team-models",
      "display_name": "Team Models",
      "protocol": "openai_chat_completions",
      "endpoint": "https://models.example.com/v1",
      "models": ["private-model"],
      "auth": { "kind": "api_key", "env_var": "TEAM_MODELS_API_KEY" }
    }
  }
}
```

Direct provider protocols are `openai_chat_completions`,
`openai_responses`, and `anthropic_messages`.

## For agents: add a provider

The provider registry lives in [`src/builtins/providers.zig`](src/builtins/providers.zig).
To add a direct provider:

1. Add a new `ProviderId` and its aliases in
   [`src/core/config/model_provider.zig`](src/core/config/model_provider.zig).
2. Add a `Provider` in `src/builtins/providers.zig` with its id, display name,
   base URL, default model, API-key environment variable, and model endpoint.
3. Add the new id to the `agentStream`, `modelCatalog`, and `cliModelCatalog`
   switches in the same file.
4. Use `openai_direct` for OpenAI-compatible APIs; add an adapter in
   `src/gateway/` for a different protocol.
5. Add tests for parsing, credentials, catalog, and streaming. Run
   `zig fmt src/`, `zig build test`, and validate with `./zig-out/bin/ffx`.

Keep keys in environment variables or the profile's secure storage. Never
commit keys to source or the repository.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/afa7789/ffx/main/setup.sh | bash
```

To build and install a local version:

```bash
git clone https://github.com/afa7789/ffx.git
cd ffx
zig build -Doptimize=ReleaseSafe
install -m 755 ./zig-out/bin/ffx "$(command -v ffx)"
```

If the path does not exist, create its directory first or adjust the
destination. In this development environment, the installed binary is
`/Users/afa/bin/ffx`.

## Usage

```bash
cd your_project
ffx
ffx ask "explain the changes in this repository"
ffx sessions
ffx status --json
```

Use `/help` to see interactive commands. The current directory is the primary
workspace. Sessions and configuration live under `~/.ffx/`.

## Commands

| Command | Purpose |
| --- | --- |
| `ffx` | Start an interactive session |
| `ffx ask <prompt>` | Run one request and exit |
| `ffx login [provider]` | Connect or reconnect a provider |
| `ffx logout [provider]` | Remove a provider session |
| `ffx setup` | Configure a provider API key |
| `ffx provider <id>` | Select the active provider |
| `ffx models` | List available models |
| `ffx status` | Show configuration and runtime information |
| `ffx doctor` | Run local health checks |
| `ffx usage` | Show local token usage and spend |
| `ffx credits` / `ffx balance` | Show AI Gateway credits |
| `ffx sessions` | List saved sessions |
| `ffx session ...` | Inspect, resume, migrate, or recover a session |
| `ffx background [last\|id]` | Inspect background commands |
| `ffx workspace` | Manage additional workspace directories |
| `ffx permissions` | Show permission mode and rules |
| `ffx pr [context]` | Draft or publish a pull request |
| `ffx issue [context]` | Draft or publish a GitHub issue |
| `ffx replay <tape>` | Replay a recorded terminal session |
| `ffx upgrade` | Upgrade ffx on the selected release channel |
| `ffx acp` | Start an ACP server over stdio |
| `ffx teams` | Select the AI Gateway Vercel team |
| `ffx help` | Show command help |

## Development

Requires [Zig 0.16.0+](https://ziglang.org/download/).

```bash
zig build
zig build test
zig fmt src/
./zig-out/bin/ffx help
```

The WebAssembly SDK is documented in [`sdk/README.md`](sdk/README.md). Run
`ffx acp` for ACP. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before submitting
a change.

## License

[Apache-2.0](LICENSE)
