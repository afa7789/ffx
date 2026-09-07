# ffx-provider-proxy

A minimal Go adapter that lets ffx talk to any OpenAI-compatible chat-completions
endpoint without going through Vercel AI Gateway.

ffx speaks the AI Gateway v3 dialect (custom request body, SSE framing). This
proxy bridges that dialect to OpenAI /v1/chat/completions so ffx can talk to
any compatible provider — Anthropic, OpenAI, Minimax, OpenRouter, an on-prem
LiteLLM, anything that speaks `POST /v1/chat/completions`.

## Build

```sh
go build -o ./bin/ffx-provider-proxy ./scripts/ffx-provider-proxy.go
```

## Run

```sh
FFX_PROVIDER_UPSTREAM=https://api.minimax.io \
FFX_PROVIDER_UPSTREAM_KEY=your-provider-key \
FFX_PROVIDER_UPSTREAM_MODEL=MiniMax-M2 \
./bin/ffx-provider-proxy
```

The proxy listens on `:9999` by default. Override with `FFX_PROVIDER_PROXY_ADDR`.

## Use with ffx

```sh
# In one terminal: the proxy
FFX_PROVIDER_UPSTREAM=https://api.minimax.io \
FFX_PROVIDER_UPSTREAM_KEY=$*** \
FFX_PROVIDER_UPSTREAM_MODEL=$MODEL \
./bin/ffx-provider-proxy

# In another terminal: ffx
FFX_PROVIDER_BASE_URL=http://127.0.0.1:9999 \
FFX_PROVIDER_API_KEY=anything \
FFX_GATEWAY_CHAT_URL=http://127.0.0.1:9999/v3/ai/language-model \
FFX_GATEWAY_BASE_URL=http://127.0.0.1:9999 \
FFX_GATEWAY_ALLOW_EXTERNAL=1 \
./zig-out/bin/ffx ask "explain this code"
```

`FFX_GATEWAY_ALLOW_EXTERNAL=1` is required because `FFX_GATEWAY_BASE_URL` would
otherwise be restricted to loopback by ffx's safety gate.

## What this proxy does NOT do

- Tool / function calls (the AG v3 dialect is non-trivial to translate)
- Vision inputs
- Streaming responses (single-shot reply only — fine for `ffx ask`)
- Trajectory / usage for ffx's session telemetry

Those features require a real ffx-side adapter. This proxy exists to prove the
no-login path works end-to-end; it is the first step, not the final word.
