# Saúde

Sistema pessoal de saúde em duas partes:

| Pasta | O que é |
|---|---|
| [`app/`](app) | App Flutter para Android. Lê a balança **Xiaomi Mi Body Composition Scale 2** direto pelo Bluetooth (sem parear) e a **Mi Band** pelo Health Connect. Calcula a composição corporal e envia para a API. Funciona sem internet: guarda no celular e reenvia depois. |
| [`worker/`](worker) | Worker na Cloudflare: API do app (`POST /medicao`, `POST /atividade`, `GET /prato`) e servidor **MCP** para o Claude, gravando no **Turso**. |

## Como funciona

```
Balança ──BLE (anúncio 0x181B)──▶ App ──HTTPS + chave──▶ Worker ──▶ Turso
Mi Band ──▶ Mi Fitness ──▶ Health Connect ──▶ App          ▲
                                                           │ MCP (login GitHub, só LeoLira1)
                                                         Claude
```

- **Balança:** o app escuta os anúncios BLE (service data `0x181B`, 13 bytes) e só salva a medição
  final (peso estabilizado **e** com impedância). A data/hora que a balança manda é a chave única: o
  mesmo anúncio repetido não duplica. **Reenvio:** ao subir na balança, ela manda de novo a pesagem anterior
  (mesmo peso e impedância) com o horário de agora, uns 10 s antes da nova; o app e o Worker descartam toda
  medição com peso **e** impedância iguais aos da medição anterior da balança, e registram o descarte (no app:
  Ajustes → Sincronização; no Worker: log). `limpar_reenvios` no MCP acha e apaga os que já estavam gravados. Se o peso diferir mais de 5 kg da última medição, o app pergunta
  "É você?" antes de salvar.
- **Fórmulas:** porte para Dart da `MiScaleLib` do [openScale](https://github.com/oliexdev/openScale)
  (IMC, gordura, água, osso, visceral, massa muscular) e da `BodyMiScaleLib` (metabolismo basal e
  proteína). Peso ideal = IMC 22 na sua altura. Testes com os valores de referência do openScale em
  `app/test/mi_scale_lib_test.dart`.
- **Pulseira:** lê do Health Connect passos, calorias ativas, frequência cardíaca (média e repouso),
  sono por estágio e SpO2. Sincroniza ao abrir o app e 1x por dia em segundo plano, enviando só os dias
  que mudaram. O sono fica na data em que você acordou.

- **Hoje no prato:** card da tela Início, abaixo de "Hoje na pulseira". Busca no Worker (`GET /prato`) as
  calorias das refeições de hoje (as que o conector grava) e a água do dia com a meta. Gasto estimado =
  metabolismo basal da última pesagem + calorias ativas da pulseira de hoje; saldo = ingerido − gasto (verde no
  déficit, laranja no superávit). Atualiza ao abrir o app e ao puxar a tela para baixo.

## Publicação

- **APK:** cada push em `app/` roda `.github/workflows/app.yml`, que testa, gera o APK e publica em
  [Releases → app-latest](../../releases/tag/app-latest) (`Saude.apk`).
- **Worker:** cada push em `worker/` roda `.github/workflows/worker.yml`, que testa, faz o deploy com
  wrangler e envia os secrets do GitHub para o Worker.

### Secrets do GitHub (Settings → Secrets and variables → Actions)

| Nome | De onde vem |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare → My Profile → API Tokens → modelo "Edit Cloudflare Workers" |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare → Workers & Pages (coluna da direita, "Account ID") |
| `TURSO_DATABASE_URL` | Turso → banco `saude` → URL (`libsql://...`) |
| `TURSO_AUTH_TOKEN` | Turso → banco `saude` → Create Token |
| `APP_API_KEY` | Uma senha longa inventada por você; a mesma vai no app (Ajustes) |
| `APK_KEYSTORE_BASE64` | Chave de assinatura do APK em base64 (opcional, recomendado) |
| `MCP_GITHUB_CLIENT_ID` / `MCP_GITHUB_CLIENT_SECRET` | GitHub → Settings → Developer settings → OAuth Apps (callback `https://saude.<subdominio>.workers.dev/callback`) |

O token do Turso fica só no Worker; o app nunca o vê.

## Ferramentas MCP

`ver_medicoes`, `ver_evolucao`, `resumo_periodo`, `comparar_datas`, `ver_atividade`, `ver_sono`,
`correlacionar`, `registrar_medicao_manual`, `apagar_medicao`, `limpar_reenvios` e `resumo_hoje`.

Água ingerida: `registrar_agua`, `ver_agua`, `apagar_agua` e `definir_meta_agua` (tabelas `agua` e `config`;
aparece também em `resumo_hoje` e em `ver_refeicoes`, à parte da comida e do `agua_pct` da balança).

Refeições: `buscar_alimento`, `cadastrar_alimento`, `registrar_refeicao`, `ver_refeicoes` e `apagar_refeicao`.
A tabela `alimentos` vem com a **TACO 4ª edição** (NEPA/Unicamp, 597 alimentos, valores por 100 g, nomes como na
tabela; extraída da planilha oficial para `worker/src/taco.json` e carregada no Turso na primeira chamada).
Os itens de cada refeição guardam os valores já calculados pelos gramas. As métricas `kcal_consumidas`,
`proteina_g`, `carbo_g`, `gordura_g` e `fibra_g` (soma do dia) entram em `ver_evolucao`, `resumo_periodo` e
`correlacionar` (ex.: `kcal_consumidas` x `peso` com `defasagem_dias = 1`). Períodos aceitos: `7d`,
`30d`, `3 meses`, `1 ano`, `tudo`, `2026-05`, `2026-01-01..2026-03-31`.

## Desenvolvimento

```bash
cd worker && npm ci && npm test && npx tsc --noEmit
cd app && flutter test && flutter analyze
```

A chave de assinatura do APK vem do secret `APK_KEYSTORE_BASE64` (não fica no repositório). Com ela,
toda versão nova instala por cima da anterior sem apagar os dados.

Licença das fórmulas portadas: GPL-3.0 (openScale).
