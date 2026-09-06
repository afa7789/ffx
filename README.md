# ffx

ffx é um coding agent nativo para o terminal, escrito em Zig. É um fork
comunitário do [fx](https://fx.sh/) focado em liberdade de providers: use
OpenAI, Anthropic, DeepSeek, OpenRouter, PPQ, MiniMax, Zhipu/GLM, Z.AI,
OpenCode ou endpoints compatíveis sem login obrigatório da Vercel.

## O que o ffx oferece

- providers diretos e providers customizados;
- configuração persistida em `~/.ffx/settings.json`;
- `/connect-provider` para adicionar uma conexão;
- `/switch-provider` e `/provider` para selecionar o provider ativo;
- `/models` com catálogo dinâmico, tabs por provider e favoritos;
- skills, subagentes, MCP e instruções de projeto;
- binário nativo pequeno e embutível.

## Instalação

Compile com Zig 0.16 ou mais recente:

```bash
git clone https://github.com/afa7789/ffx.git
cd ffx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/ffx
```

Ou use o instalador:

```bash
curl -fsSL https://raw.githubusercontent.com/afa7789/ffx/main/setup.sh | bash
```

## Uso rápido

```bash
ffx
ffx ask "explique as mudanças neste repositório"
```

Dentro da sessão:

```text
/connect-provider
/switch-provider
/provider
/models
/help
```

Para um endpoint OpenAI-compatible customizado, use `/connect-provider` ou
configure as variáveis de ambiente:

```bash
export FFX_PROVIDER_API_KEY="..."
export FFX_PROVIDER_BASE_URL="https://models.example.com/v1"
./zig-out/bin/ffx
```

As configurações existentes são carregadas na inicialização e podem ser
alteradas sem editar arquivos manualmente.

## Desenvolvimento

```bash
zig build
zig build test
zig fmt src/
```

Consulte [`CONTRIBUTING.md`](CONTRIBUTING.md) para contribuir. A landing page
está em [`web/index.html`](web/index.html) e é publicada pelo GitHub Pages.

## Links

- [Site](https://afa7789.github.io/ffx/)
- [Código-fonte](https://github.com/afa7789/ffx)
- [fx original](https://github.com/vercel-labs/fx)

## Licença

[Apache-2.0](LICENSE)
