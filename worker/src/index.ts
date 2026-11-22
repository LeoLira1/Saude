import { env } from "cloudflare:workers";
import OAuthProvider from "@cloudflare/workers-oauth-provider";
import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler } from "agents/mcp/server";
import { z } from "zod";
import { usuarioPermitido } from "./acesso.ts";
import {
	arred,
	correlacionarSeries,
	forcaCorrelacao,
	hojeBRT,
	horas,
	lerMetrica,
	lerPeriodo,
	maisProxima,
	media,
	METRICAS,
	resumoSerie,
	resumoSono,
	serieDiaria,
	somarDias,
} from "./analise.ts";
import { abrir, COLUNAS_ATIVIDADE, COLUNAS_MEDICAO, inserirMedicoes, lerAtividade, lerMedicoes, linhas } from "./db.ts";
import { GitHubHandler } from "./github-handler.ts";
import type { Props } from "./utils.ts";
import { ErroValidacao, normalizarDataHora, validarMedicao } from "./validar.ts";

function json(data: unknown) {
	return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
}

function falha(e: unknown) {
	if (!(e instanceof ErroValidacao)) console.error(e);
	const msg = e instanceof Error ? e.message : String(e);
	return { content: [{ type: "text" as const, text: `Erro: ${msg}` }], isError: true };
}

const PERIODO = z
	.string()
	.max(40)
	.optional()
	.describe(
		'Período: "7d", "30d" (padrão), "3 meses", "1 ano", "tudo", "hoje", "ontem", um mês "2026-05", um dia "2026-05-10" ou intervalo "2026-01-01..2026-03-31".',
	);

const NOMES_METRICAS = Object.keys(METRICAS).join(", ");
const METRICAS_RESUMO = ["peso", "gordura_pct", "musculo_kg", "visceral", "agua_pct", "passos", "calorias", "sono_min", "fc_repouso"];

function enxuta(m: Record<string, unknown>) {
	const o: Record<string, unknown> = {};
	for (const [k, v] of Object.entries(m)) if (v !== null && v !== undefined) o[k] = typeof v === "number" ? arred(v, 2) : v;
	return o;
}

function createServer() {
	const server = new McpServer({ name: "Saúde", version: "1.0.0" });

	server.registerTool(
		"ver_medicoes",
		{
			description:
				"Lista as medições da balança (Xiaomi Mi Body Composition Scale 2) no período, mais recentes primeiro: peso, IMC, gordura %, água %, " +
				"massa muscular kg, massa óssea kg, gordura visceral, metabolismo basal, proteína %, impedância e origem (balanca/manual). Só leitura.",
			inputSchema: z.object({
				periodo: PERIODO,
				limite: z.number().int().min(1).max(1000).optional().describe("Máximo de medições (padrão 100)."),
			}),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ periodo, limite }) => {
			try {
				const p = lerPeriodo(periodo);
				const db = await abrir(env);
				const ms = (await lerMedicoes(db, p.inicio, p.fim)).reverse();
				return json({ periodo: p, total: ms.length, medicoes: ms.slice(0, limite ?? 100).map(enxuta) });
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"ver_evolucao",
		{
			description:
				"Evolução dia a dia de UMA métrica no período (média do dia quando há mais de uma medição), com primeiro/último valor, variação, " +
				`mínimo, máximo e tendência por semana. Métricas: ${NOMES_METRICAS} (aceita apelidos: gordura, musculo, sono, fc, spo2…). Só leitura.`,
			inputSchema: z.object({
				metrica: z.string().min(1).max(40).describe("Métrica, ex.: peso, gordura, musculo, visceral, passos, sono, fc_repouso."),
				periodo: PERIODO,
			}),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ metrica, periodo }) => {
			try {
				const info = lerMetrica(metrica);
				const p = lerPeriodo(periodo);
				const db = await abrir(env);
				const [ms, at] = await Promise.all([
					info.fonte === "medicoes" ? lerMedicoes(db, p.inicio, p.fim) : [],
					info.fonte === "atividade" ? lerAtividade(db, p.inicio, p.fim) : [],
				]);
				const serie = serieDiaria(info, ms, at);
				const casas = info.unidade === "kg" || info.unidade === "%" ? 2 : 0;
				return json({
					periodo: p,
					resumo: resumoSerie(info, serie),
					serie: serie.map((s) => ({ data: s.data, valor: arred(s.valor, casas) })),
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"resumo_periodo",
		{
			description:
				"Resumo do período para várias métricas de uma vez: média, mínimo, máximo (com o dia), primeiro e último valor, variação, " +
				"tendência por semana (reta de mínimos quadrados) e médias de cada semana (segunda a domingo). " +
				`Padrão: ${METRICAS_RESUMO.join(", ")}. Só leitura.`,
			inputSchema: z.object({
				periodo: PERIODO,
				metricas: z.array(z.string().max(40)).max(20).optional().describe("Lista de métricas (opcional)."),
			}),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ periodo, metricas }) => {
			try {
				const p = lerPeriodo(periodo);
				const infos = (metricas?.length ? metricas : METRICAS_RESUMO).map(lerMetrica);
				const db = await abrir(env);
				const [ms, at] = await Promise.all([lerMedicoes(db, p.inicio, p.fim), lerAtividade(db, p.inicio, p.fim)]);
				return json({
					periodo: p,
					medicoes_no_periodo: ms.length,
					dias_de_atividade: at.length,
					metricas: infos.map((i) => resumoSerie(i, serieDiaria(i, ms, at))),
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"comparar_datas",
		{
			description:
				"Compara duas datas: a medição da balança mais próxima de cada uma (até 3 dias de distância) e a atividade/sono do dia, " +
				"com a diferença (data2 − data1) de cada métrica. Só leitura.",
			inputSchema: z.object({
				data1: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).describe("Primeira data, AAAA-MM-DD."),
				data2: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).describe("Segunda data, AAAA-MM-DD."),
			}),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ data1, data2 }) => {
			try {
				const db = await abrir(env);
				const pega = async (d: string) => {
					const [ms, at] = await Promise.all([
						lerMedicoes(db, somarDias(d, -3), somarDias(d, 3)),
						lerAtividade(db, d, d),
					]);
					return { medicao: maisProxima(ms, d), atividade: at[0] ?? null };
				};
				const [a, b] = await Promise.all([pega(data1), pega(data2)]);
				const dif: Record<string, number | null> = {};
				for (const c of COLUNAS_MEDICAO) {
					const x = a.medicao?.[c];
					const y = b.medicao?.[c];
					if (typeof x === "number" && typeof y === "number") dif[c] = arred(y - x, 2);
				}
				for (const c of COLUNAS_ATIVIDADE) {
					const x = a.atividade?.[c];
					const y = b.atividade?.[c];
					if (typeof x === "number" && typeof y === "number") dif[c] = arred(y - x, 1);
				}
				return json({
					data1: { data: data1, medicao: a.medicao && enxuta(a.medicao), atividade: a.atividade && enxuta(a.atividade) },
					data2: { data: data2, medicao: b.medicao && enxuta(b.medicao), atividade: b.atividade && enxuta(b.atividade) },
					diferenca_data2_menos_data1: dif,
					aviso: !a.medicao || !b.medicao ? "Sem medição da balança até 3 dias de uma das datas." : undefined,
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"ver_atividade",
		{
			description:
				"Atividade diária da pulseira (Mi Band via Health Connect) no período: passos, calorias ativas, FC de repouso e média, sono e SpO2, " +
				"mais as médias do período. O sono fica na data em que você acordou. Só leitura.",
			inputSchema: z.object({ periodo: PERIODO }),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ periodo }) => {
			try {
				const p = lerPeriodo(periodo);
				const db = await abrir(env);
				const at = await lerAtividade(db, p.inicio, p.fim);
				const med = (k: (typeof COLUNAS_ATIVIDADE)[number]) =>
					arred(media(at.map((d) => d[k]).filter((v): v is number => typeof v === "number" && v > 0)), 1);
				const medias: Record<string, number | null> = {};
				for (const c of COLUNAS_ATIVIDADE) medias[c] = med(c);
				const total = at.reduce((s, d) => s + (d.passos ?? 0), 0);
				return json({
					periodo: p,
					dias: at.length,
					medias,
					passos_total: total,
					dias_com_10mil_passos: at.filter((d) => (d.passos ?? 0) >= 10_000).length,
					atividade: [...at].reverse().map(enxuta),
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"ver_sono",
		{
			description:
				"Sono por noite no período (data = dia em que acordou): total, profundo, leve, REM, acordado, % de profundo e REM e SpO2; " +
				"mais médias, melhor e pior noite e quantas noites ficaram abaixo de 6 h. Só leitura.",
			inputSchema: z.object({ periodo: PERIODO }),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ periodo }) => {
			try {
				const p = lerPeriodo(periodo);
				const db = await abrir(env);
				const at = await lerAtividade(db, p.inicio, p.fim);
				const r = resumoSono(at);
				return json({ periodo: p, ...r, noites: [...r.noites].reverse() });
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"correlacionar",
		{
			description:
				"Correlação (Pearson) entre duas métricas, dia a dia, no período. Ex.: sono x peso, passos x gordura, fc_repouso x sono. " +
				"Devolve r (−1 a 1), força em português, quantos dias entraram, a inclinação (quanto metrica2 muda por +1 de metrica1) e os pares. " +
				"defasagem_dias = N compara metrica1 do dia D com metrica2 do dia D+N (ex.: passos de hoje x peso de amanhã = 1). " +
				"Correlação não prova causa; com menos de ~10 dias o resultado é frágil. Só leitura.",
			inputSchema: z.object({
				metrica1: z.string().min(1).max(40),
				metrica2: z.string().min(1).max(40),
				periodo: z.string().max(40).optional().describe('Período (padrão "90d"). Mesmo formato das outras ferramentas.'),
				defasagem_dias: z.number().int().min(-30).max(30).optional().describe("Padrão 0."),
			}),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ metrica1, metrica2, periodo, defasagem_dias }) => {
			try {
				const i1 = lerMetrica(metrica1);
				const i2 = lerMetrica(metrica2);
				const lag = defasagem_dias ?? 0;
				const p = lerPeriodo(periodo ?? "90d");
				const db = await abrir(env);
				const fim2 = lag > 0 ? somarDias(p.fim, lag) : p.fim;
				const ini2 = lag < 0 ? somarDias(p.inicio, lag) : p.inicio;
				const [ms, at] = await Promise.all([lerMedicoes(db, ini2, fim2), lerAtividade(db, ini2, fim2)]);
				const s1 = serieDiaria(i1, ms, at).filter((x) => x.data >= p.inicio && x.data <= p.fim);
				const s2 = serieDiaria(i2, ms, at);
				const { pares, r, inclinacao } = correlacionarSeries(s1, s2, lag);
				return json({
					periodo: p,
					metrica1: i1.chave,
					metrica2: i2.chave,
					defasagem_dias: lag,
					dias_pareados: pares.length,
					r: arred(r, 3),
					forca: forcaCorrelacao(r),
					inclinacao:
						inclinacao === null
							? null
							: `cada +1 ${i1.unidade || "un."} de ${i1.nome} ↔ ${arred(inclinacao, 4)} ${i2.unidade || ""} de ${i2.nome}`.trim(),
					aviso: pares.length < 10 ? "Poucos dias pareados: trate como indício, não conclusão." : undefined,
					pares: pares.map((x) => ({ data: x.data, [i1.chave]: arred(x.x, 2), [i2.chave]: arred(x.y, 2) })),
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"registrar_medicao_manual",
		{
			description:
				"Grava uma medição feita sem o app (origem = manual). Só o peso é obrigatório; o resto é opcional. " +
				"Se o IMC não vier, é calculado com a altura deduzida da última medição que tem IMC. " +
				"medido_em padrão = agora (Brasília). Se já existir medição no mesmo horário, nada é gravado. Confirme os valores com o usuário antes.",
			inputSchema: z.object({
				peso: z.number().min(10).max(300).describe("Peso em kg."),
				medido_em: z.string().max(19).optional().describe('"AAAA-MM-DD HH:MM" no horário de Brasília. Padrão: agora.'),
				gordura_pct: z.number().min(0).max(80).optional(),
				agua_pct: z.number().min(0).max(90).optional(),
				musculo_kg: z.number().min(0).max(200).optional(),
				osso_kg: z.number().min(0).max(15).optional(),
				visceral: z.number().min(0).max(100).optional(),
				metabolismo_kcal: z.number().min(0).max(6000).optional(),
				proteina_pct: z.number().min(0).max(60).optional(),
				imc: z.number().min(5).max(100).optional(),
			}),
			annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
		},
		async (args) => {
			try {
				const agora = new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 19).replace("T", " ");
				const medido_em = args.medido_em ? normalizarDataHora(args.medido_em) : agora;
				const db = await abrir(env);
				let imc = args.imc;
				let altura_usada: number | null = null;
				if (imc === undefined) {
					const ult = linhas<{ peso: number; imc: number }>(
						await db.execute(
							"SELECT peso, imc FROM medicoes WHERE imc IS NOT NULL AND imc > 0 ORDER BY medido_em DESC LIMIT 1",
						),
					)[0];
					if (ult) {
						const h2 = ult.peso / ult.imc;
						altura_usada = arred(Math.sqrt(h2) * 100, 1);
						imc = arred(args.peso / h2, 2) ?? undefined;
					}
				}
				const m = validarMedicao({ ...args, imc, medido_em, origem: "manual" }, "manual");
				const r = await inserirMedicoes(db, [m]);
				if (!r.inseridas.length) {
					return json({ gravado: false, motivo: `Já existe uma medição em ${medido_em}. Nada foi gravado.` });
				}
				return json({ gravado: true, id: r.inseridas[0].id, medicao: enxuta(m), altura_usada_no_imc_cm: altura_usada });
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"apagar_medicao",
		{
			description:
				"Apaga UMA medição pelo id. Sem confirmar = true só mostra o que seria apagado. " +
				"Mostre a medição ao usuário e peça confirmação antes de chamar com confirmar = true. Devolve o registro apagado.",
			inputSchema: z.object({
				id: z.number().int().positive(),
				confirmar: z.boolean().optional().describe("true para apagar de verdade."),
			}),
			annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
		},
		async ({ id, confirmar }) => {
			try {
				const db = await abrir(env);
				const atual = linhas(await db.execute({ sql: "SELECT * FROM medicoes WHERE id = ?", args: [id] }))[0];
				if (!atual) return json({ apagado: false, motivo: `Medição ${id} não existe.` });
				if (!confirmar) {
					return json({ apagado: false, seria_apagada: enxuta(atual), aviso: "Chame de novo com confirmar = true para apagar." });
				}
				await db.execute({ sql: "DELETE FROM medicoes WHERE id = ?", args: [id] });
				return json({ apagado: true, medicao_apagada: enxuta(atual) });
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"resumo_hoje",
		{
			description:
				"Painel rápido: última medição da balança (com variação vs. a anterior e vs. ~30 dias atrás) e a atividade de hoje e de ontem. Só leitura.",
			inputSchema: z.object({}),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async () => {
			try {
				const db = await abrir(env);
				const hoje = hojeBRT();
				const ultimas = linhas<Record<string, number | string>>(
					await db.execute("SELECT * FROM medicoes ORDER BY medido_em DESC LIMIT 2"),
				);
				const u = ultimas[0];
				let ha30: Record<string, number | string> | undefined;
				if (u) {
					const ref = somarDias(String(u.medido_em).slice(0, 10), -30);
					ha30 = linhas<Record<string, number | string>>(
						await db.execute({
							sql: "SELECT * FROM medicoes WHERE medido_em <= ? ORDER BY medido_em DESC LIMIT 1",
							args: [`${ref} 23:59:59`],
						}),
					)[0];
				}
				const dif = (a?: Record<string, number | string>, b?: Record<string, number | string>) =>
					a && b
						? Object.fromEntries(
								["peso", "gordura_pct", "musculo_kg", "visceral"].map((k) => [
									k,
									typeof a[k] === "number" && typeof b[k] === "number" ? arred((a[k] as number) - (b[k] as number), 2) : null,
								]),
							)
						: null;
				const at = await lerAtividade(db, somarDias(hoje, -1), hoje);
				const dia = (d: string) => at.find((x) => x.data === d);
				const fmt = (a?: (typeof at)[number]) => a && { ...enxuta(a), sono: horas(a.sono_min) };
				return json({
					ultima_medicao: u ? enxuta(u) : null,
					variacao_vs_anterior: dif(u, ultimas[1]),
					variacao_vs_30_dias: dif(u, ha30),
					medicao_de_30_dias_atras: ha30 ? ha30.medido_em : null,
					hoje: fmt(dia(hoje)) ?? null,
					ontem: fmt(dia(somarDias(hoje, -1))) ?? null,
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	return server;
}

const mcpHandler = createMcpHandler(createServer);
const apiHandler = {
	fetch(request: Request, bindings: Env, ctx: ExecutionContext) {
		// Segunda trava (a primeira fica no /callback): token de outra conta não passa.
		const props = (ctx as ExecutionContext & { props?: Props }).props;
		if (!props || !usuarioPermitido(props.login, props.id)) {
			return new Response("Acesso negado", { status: 403 });
		}
		return mcpHandler(request, bindings, ctx);
	},
} satisfies ExportedHandler<Env>;

export default new OAuthProvider({
	allowPlainPKCE: false,
	apiHandler,
	apiRoute: "/mcp",
	authorizeEndpoint: "/authorize",
	clientRegistrationEndpoint: "/register",
	defaultHandler: GitHubHandler as any,
	tokenEndpoint: "/token",
});
