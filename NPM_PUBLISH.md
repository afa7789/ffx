# NPM Publish — notas do sprint (ler antes de publicar)

Status: **ainda NÃO publicado**. A máquina npm (package.json, prepack, shim, tarball) está
pronta e testada na branch `npm/publish-setup`. O publish espera o sync do upstream.

## Regra de versão (registrada em AGENTS.md, seção Releasing)

Este fork segue a versão do upstream `vercel-labs/fx` verbatim (`src/main.zig`, `pub const
version`). Toda vez que sincronizarmos o upstream, herdamos a versão deles. A versão npm é
sempre igual à do `src/main.zig` — o script `scripts/prepare-publish.mjs` (hook `prepack`)
estampa o `package.json` sozinho. Nunca editar versão na mão no npm. Upstream está em
`v0.0.7`; o repo local ainda está em `0.0.4` (sem sync).

## Ordem correta antes do publish

1. O loop de auth (sprint "Dynamic provider configuration") assentar — árvore está com
   trabalho em andamento.
2. Sync do upstream (`vercel-labs/fx`) para o fork. Merge pode colidir com o trabalho do
   loop; fazer depois que ele terminar.
3. `npm publish` na branch `npm/publish-setup` — o prepack pega a versão nova sozinho.

## Como publicar (manual, sem chave compartilhada)

- Chave npm **não é necessária** para publish manual. `npm login` guarda o token em
  `~/.npmrc` (local, seu).
- `NPM_TOKEN` só seria preciso se um dia quisermos CI auto-publish (workflow com secret no
  GitHub Actions). Nada disso existe ainda.

Comandos:

```bash
git worktree add ../ffx-npm-merge -b npm/publish-setup   # se ainda não existir
cd ../ffx-npm-merge
npm run prepack          # build + stage + stamp de versão
npm pack                 # gera afa7789-ffx-<versao>.tgz
npm publish              # publica (roda prepack automaticamente)
```

## Depois do publish

1. Substituir o bloco INSTALL em `web/index.html` — o placeholder marcado com comentário
   `<!-- INSTALL: substituir este bloco pelos comandos reais depois do npm publish ... -->`.
   Colocar `npm install -g @afa7789/ffx` real + commit + push.
2. Habilitar GitHub Pages: Settings > Pages > Source: GitHub Actions. No plano free, o repo
   precisa ser **público** (decisão sua).
3. Fazer merge de `npm/publish-setup` → `ffx` (esperar o loop de auth assentar para não
   misturar as árvores).

## O que a branch contém (8 commits, testado)

- `package.json` — nome `@afa7789/ffx`, bin `ffx` → `bin/ffx.js`, prepack, access public
- `scripts/prepare-publish.mjs` — build ReleaseSafe, gate darwin-arm64, stamp de versão,
  contrato de erro fechado (`prepack failed: ...`)
- `bin/ffx.js` — shim npm que spawna o binário nativo com argv/TTY herdados
- `.gitignore` — `/npm-pkg/` ignorado
- `README.md` — resumido (27 linhas): fork do fx, sem login obrigatório
- `web/` — landing page estática PT-BR (fork sem login Vercel) + placeholder INSTALL
- `.github/workflows/pages.yml` — deploy do `web/` para GH Pages (target branch `ffx`)

Verificação end-to-end feita (wire-up PASS): tarball → install global em prefixo temporário
→ binário real rodou → versão correta. Review: APPROVE.

## Isolamento (contexto)

O sprint correu isolado do loop de auth: DB dagRobin dedicado em
`/var/folders/1w/9g6qlcsj6wq1_0p6m8cf8w380000gn/T/opencode/ffx-npm-sprint/.dagrobin/db`,
plano em `.claude/PLAN_NPM.md` (o loop usa `.claude/PLAN.md`). Nada foi mergeado em `ffx`.