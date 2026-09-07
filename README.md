<p align="center">
  <img src="web/ffx-mark.svg" alt="ffx" width="220">
</p>

<p align="center">A tiny, open, native coding agent for the terminal.</p>

ffx is a native coding agent written in Zig. It is a community fork of
[fx](https://fx.sh/) focused on provider freedom: use OpenAI, Anthropic,
DeepSeek, OpenRouter, PPQ, MiniMax, Zhipu/GLM, Z.AI, OpenCode, or compatible
custom endpoints without a mandatory Vercel login.

## Features

- Direct and custom AI providers.
- Persistent configuration in `~/.ffx/settings.json`.
- `/connect-provider` for adding a provider connection.
- `/switch-provider` and `/provider` for selecting the active provider.
- `/models` with dynamic provider tabs, model discovery, and favorites.
- Skills, subagents, MCP, and project instructions.
- A small native binary designed for embedding.

## Install

Build with Zig 0.16 or newer:

```bash
git clone https://github.com/afa7789/ffx.git
cd ffx
zig build --release=safe
./zig-out/bin/ffx
```

Or use the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/afa7789/ffx/main/setup.sh | bash
```

## Quick start

```bash
ffx
ffx ask "explain the changes in this repository"
```

Inside a session:

```text
/connect-provider
/switch-provider
/provider
/models
/help
```

For an OpenAI-compatible custom endpoint, use `/connect-provider` or set:

```bash
export FFX_PROVIDER_API_KEY="..."
export FFX_PROVIDER_BASE_URL="https://models.example.com/v1"
./zig-out/bin/ffx
```

Existing settings are loaded from `~/.ffx/settings.json` at startup and can be
changed without editing configuration files by hand. Older `~/.fx` settings
are still accepted for migration, while new state is written to `~/.ffx`.

The current directory becomes the primary workspace. Enter a prompt, or run
`/help` to browse interactive commands. Saved conversations can be listed and
resumed with `ffx sessions` and `ffx session resume last`.

Use `/trace` to create a private diagnostic, `/feedback` to open the feedback
form, and `/permissions` to inspect the active permission policy.

## Development

```bash
zig build
zig build test
zig fmt src/
```

The landing page lives in [`web/index.html`](web/index.html) and is published
through GitHub Pages.

## Links

- [Website](https://afa7789.github.io/ffx/)
- [Source](https://github.com/afa7789/ffx)
- [Original fx project](https://github.com/vercel-labs/fx)

## License

[Apache-2.0](LICENSE)
