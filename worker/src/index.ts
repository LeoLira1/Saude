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
	medicaoDoDia,
	avaliarImpedancia,
	MSG_HISTORICO_INSUFICIENTE,
	casasDe,
	METRICAS_DE_IMPEDANCIA,
	LIMIAR_IMPEDANCIA_OHMS,
	media,
	METRICAS,
	resumoSerie,
	resumoSono,
	serieDiaria,
	somarDias,
} from "./analise.ts";
import { abrir, COLUNAS_ATIVIDADE, COLUNAS_MEDICAO, inserirMedicoes, lerAtividade, lerMedicoes, linhas, semReenvios, SQL_REENVIOS_GRAVADOS, type Medicao } from "./db.ts";
import { GitHubHandler } from "./github-handler.ts";
import { buscar, somar, TIPOS_REFEICAO, NUTRIENTES } from "./nutricao.ts";
import {
	aguaDoDia,
	aguaPorId,
	apagarAgua,
	gravarMeta,
	lerAgua,
	lerMeta,
	META_MAX,
	META_MIN,
	ML_MAX_REGISTRO,
	registrarAgua,
	situacaoMeta,
	somarAguaPorDia,
} from "./agua.ts";
import {
	apagarRefeicao,
	cadastrarAlimento,
	calcularItens,
	garantirTaco,
	gravarRefeicao,
	lerItens,
	nutricaoPorDia,
	todosAlimentos,
	totalDoDia,
} from "./refeicoes.ts";
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
const METRICAS_RESUMO = ["peso", "gordura_pct", "musculo_kg", "visceral", "agua_pct", "passos", "calorias", "sono_min", "fc_repouso", "kcal_consumidas", "proteina_g"];

function enxuta(m: Record<string, unknown>) {
	const o: Record<string, unknown> = {};
	for (const [k, v] of Object.entries(m)) if (v !== null && v !== undefined) o[k] = typeof v === "number" ? arred(v, 2) : v;
	return o;
}

/** Bônus: marca medições com impedância > 30 Ω diferente da anterior do mesmo dia (só nas métricas de bioimpedância). */
function comSuspeitas<T extends object>(chave: string, resumo: T, ms: Medicao[], hist: Medicao[]) {
	if (!METRICAS_DE_IMPEDANCIA.has(chave)) return resumo;
	const { suspeitas: sus, historico_insuficiente: semRef } = avaliarImpedancia(ms, hist);
	let r: Record<string, unknown> = { ...(resumo as Record<string, unknown>) };
	if (sus.length) {
		r = {
			...r,
			medicoes_suspeitas: sus,
			aviso_suspeitas:
				`${sus.length} medição(ões) com impedância a mais de ${LIMIAR_IMPEDANCIA_OHMS} Ω da referência (mediana do dia com 3+ medições distintas, ` +
				"ou dos 7 dias anteriores): gordura, músculo e água delas podem estar errados (pé molhado, meia, posição). Os valores acima ainda as incluem.",
		};
	}
	if (semRef.length) {
		r = { ...r, aviso_impedancia: `${MSG_HISTORICO_INSUFICIENTE}: ${semRef.length} medição(ões) sem referência para avaliar a impedância`, sem_referencia: semRef };
	}
	return r;
}

/** Medições do período + as dos 7 dias antes (referência da impedância suspeita). */
async function lerComHistorico(db: Awaited<ReturnType<typeof abrir>>, inicio: string, fim: string) {
	const hist = await lerMedicoes(db, somarDias(inicio, -7), fim);
	return { ms: hist.filter((m) => m.medido_em.slice(0, 10) >= inicio), hist };
}

function motivoSuspeita(x: { diferenca_ohms: number; referencia: string; impedancia_referencia: number }) {
	return `impedância ${x.diferenca_ohms > 0 ? "+" : ""}${x.diferenca_ohms} Ω vs. ${x.referencia} (${x.impedancia_referencia} Ω)`;
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
				const { ms: lidas, hist } = await lerComHistorico(db, p.inicio, p.fim);
				const ms = [...lidas].reverse();
				const av = avaliarImpedancia(ms, hist);
				const sus = new Map(av.suspeitas.map((x) => [x.medido_em, x]));
				const semRef = new Set(av.historico_insuficiente);
				return json({
					periodo: p,
					total: ms.length,
					medicoes: ms.slice(0, limite ?? 100).map((m) => {
						const x = sus.get(m.medido_em);
						return x
							? { ...enxuta(m), suspeita: true, motivo_suspeita: motivoSuspeita(x) }
							: semRef.has(m.medido_em)
								? { ...enxuta(m), aviso_impedancia: MSG_HISTORICO_INSUFICIENTE }
								: enxuta(m);
					}),
				});
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
				const [{ ms, hist }, at, nut] = await Promise.all([
					info.fonte === "medicoes" ? lerComHistorico(db, p.inicio, p.fim) : { ms: [], hist: [] },
					info.fonte === "atividade" ? lerAtividade(db, p.inicio, p.fim) : [],
					info.fonte === "nutricao" ? nutricaoPorDia(db, p.inicio, p.fim) : [],
				]);
				const serie = serieDiaria(info, ms, at, nut);
				const casas = casasDe(info.chave);
				return json({
					periodo: p,
					resumo: comSuspeitas(info.chave, resumoSerie(info, serie), ms, hist),
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
				const [{ ms, hist }, at, nut] = await Promise.all([
					lerComHistorico(db, p.inicio, p.fim),
					lerAtividade(db, p.inicio, p.fim),
					nutricaoPorDia(db, p.inicio, p.fim),
				]);
				return json({
					periodo: p,
					medicoes_no_periodo: ms.length,
					dias_de_atividade: at.length,
					dias_com_refeicoes: nut.length,
					metricas: infos.map((i) => comSuspeitas(i.chave, resumoSerie(i, serieDiaria(i, ms, at, nut)), ms, hist)),
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
				"Compara duas datas. Balança: média das medições do próprio dia (igual ao ver_evolucao); se o dia não tem medição, usa o dia " +
				"mais próximo até 3 dias e informa em data_real_medicao. Se as duas datas caem no mesmo dia de medição, não calcula diferença " +
				"(\"sem medição distinta para comparar\"). Também compara a atividade/sono de cada data. Diferença = data2 − data1. Só leitura.",
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
					const [{ ms, hist }, at] = await Promise.all([
						lerComHistorico(db, somarDias(d, -3), somarDias(d, 3)),
						lerAtividade(db, d, d),
					]);
					const dia = medicaoDoDia(ms, d);
					const av = dia
						? avaliarImpedancia(
								ms.filter((m) => m.medido_em.startsWith(dia.data_real_medicao)),
								hist,
							)
						: { suspeitas: [], historico_insuficiente: [] };
					return { dia, atividade: at[0] ?? null, suspeitas: av.suspeitas, semRef: av.historico_insuficiente };
				};
				const [a, b] = await Promise.all([pega(data1), pega(data2)]);
				const avisos: string[] = [];
				const mesmaData = data1 === data2;
				const mesmaMedicao = !!a.dia && !!b.dia && a.dia.data_real_medicao === b.dia.data_real_medicao;

				let difMed: Record<string, number | null> | null = null;
				if (mesmaData || mesmaMedicao) {
					avisos.push(
						`sem medição distinta para comparar (as duas datas usam a medição de ${a.dia?.data_real_medicao ?? data1}).`,
					);
				} else if (a.dia && b.dia) {
					difMed = {};
					for (const c of COLUNAS_MEDICAO) {
						const x = a.dia.media_do_dia[c];
						const y = b.dia.media_do_dia[c];
						if (typeof x === "number" && typeof y === "number") difMed[c] = arred(y - x, casasDe(c));
					}
				} else {
					avisos.push("Sem medição da balança até 3 dias de uma das datas.");
				}

				let difAt: Record<string, number | null> | null = null;
				if (!mesmaData && a.atividade && b.atividade) {
					difAt = {};
					for (const c of COLUNAS_ATIVIDADE) {
						if (c === "fc_repouso_estimada") continue;
						const x = a.atividade[c];
						const y = b.atividade[c];
						if (typeof x === "number" && typeof y === "number") difAt[c] = arred(y - x, 1);
					}
				}
				for (const [rot, lado] of [["data1", a], ["data2", b]] as const) {
					if (lado.dia && !lado.dia.mesmo_dia) {
						avisos.push(`${rot}: sem medição no dia; usada a de ${lado.dia.data_real_medicao}.`);
					}
					if (lado.semRef.length) {
						avisos.push(`${rot}: ${MSG_HISTORICO_INSUFICIENTE} para avaliar a impedância (${lado.semRef.length} medição(ões)).`);
					}
					if (lado.suspeitas.length) {
						avisos.push(
							`${rot}: ${lado.suspeitas.length} medição(ões) do dia com impedância a mais de ${LIMIAR_IMPEDANCIA_OHMS} Ω da referência; ` +
								"gordura/músculo/água da média podem estar distorcidos.",
						);
					}
				}

				const lado = (d: string, x: typeof a) => ({
					data: d,
					data_real_medicao: x.dia?.data_real_medicao ?? null,
					medicao: x.dia
						? {
								medicoes_no_dia: x.dia.medicoes_no_dia,
								horarios: x.dia.horarios,
								media_do_dia: x.dia.media_do_dia,
								...(x.suspeitas.length ? { medicoes_suspeitas: x.suspeitas } : {}),
							}
						: null,
					atividade: x.atividade && enxuta(x.atividade),
				});

				return json({
					data1: lado(data1, a),
					data2: lado(data2, b),
					diferenca_data2_menos_data1: difMed || difAt ? { medicao: difMed, atividade: difAt } : null,
					avisos: avisos.length ? avisos : undefined,
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
					"(fc_repouso_estimada = 1: o Mi Fitness não mandou a FC de repouso e o app estimou pelos menores batimentos do dia), " +
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
				for (const c of COLUNAS_ATIVIDADE) if (c !== "fc_repouso_estimada") medias[c] = med(c);
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
				"Correlação (Pearson) entre duas métricas, dia a dia, no período. Ex.: sono x peso, passos x gordura, fc_repouso x sono, " +
				"kcal_consumidas x peso do dia seguinte (defasagem_dias = 1). Métricas de refeição só contam dias com refeição registrada. " +
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
				const [ms, at, nut] = await Promise.all([lerMedicoes(db, ini2, fim2), lerAtividade(db, ini2, fim2), nutricaoPorDia(db, ini2, fim2)]);
				const s1 = serieDiaria(i1, ms, at, nut).filter((x) => x.data >= p.inicio && x.data <= p.fim);
				const s2 = serieDiaria(i2, ms, at, nut);
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
					pares: pares.map((x) => ({ data: x.data, [i1.chave]: arred(x.x, casasDe(i1.chave)), [i2.chave]: arred(x.y, casasDe(i2.chave)) })),
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
		"limpar_reenvios",
		{
			description:
				"Acha no histórico os reenvios da balança: medição com peso e impedância iguais aos da medição anterior e seguida de outra " +
				"em até 60 s (a pesagem de verdade). Sem confirmar = true só lista. Mostre a lista ao usuário e, depois que ele confirmar, " +
				"chame com confirmar = true e os ids mostrados: apaga só os ids que continuam na lista.",
			inputSchema: z.object({
				confirmar: z.boolean().optional().describe("true para apagar de verdade."),
				ids: z.array(z.number().int().positive()).max(500).optional().describe("Ids a apagar (da lista mostrada)."),
			}),
			annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
		},
		async ({ confirmar, ids }) => {
			try {
				const db = await abrir(env);
				const lista = linhas<Record<string, unknown> & { id: number }>(await db.execute(SQL_REENVIOS_GRAVADOS));
				if (!confirmar) {
					return json({
						apagado: false,
						total: lista.length,
						reenvios: lista.map(enxuta),
						aviso: lista.length ? "Chame de novo com confirmar = true e os ids para apagar." : "Nenhum reenvio no histórico.",
					});
				}
				const validos = new Set(lista.map((x) => x.id));
				const apagar = (ids ?? []).filter((id) => validos.has(id));
				const recusados = (ids ?? []).filter((id) => !validos.has(id));
				if (apagar.length) {
					await db.batch(apagar.map((id) => ({ sql: "DELETE FROM medicoes WHERE id = ?", args: [id] })), "write");
				}
				return json({
					apagado: apagar.length > 0,
					apagados: lista.filter((x) => apagar.includes(x.id)).map(enxuta),
					...(recusados.length ? { nao_apagados: recusados, motivo: "esses ids não estão na lista de reenvios" } : {}),
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	// ── Refeições ──────────────────────────────────────────────────────────

	const POR_100G = {
		kcal: z.number().min(0).max(900).optional().describe("kcal por 100 g."),
		proteina_g: z.number().min(0).max(100).optional().describe("Proteína (g) por 100 g."),
		carbo_g: z.number().min(0).max(100).optional().describe("Carboidrato (g) por 100 g."),
		gordura_g: z.number().min(0).max(100).optional().describe("Gordura/lipídeos (g) por 100 g."),
		fibra_g: z.number().min(0).max(100).optional().describe("Fibra alimentar (g) por 100 g."),
	};

	const porCem = (a: Record<string, unknown>) => Object.fromEntries(NUTRIENTES.map((k) => [k, a[k] ?? null]));

	server.registerTool(
		"buscar_alimento",
		{
			description:
				"Procura alimentos pelo nome na tabela de alimentos (TACO/Unicamp 4ª edição, 597 itens, mais os cadastrados à mão). " +
				"Tolera erro de digitação, falta de acento e plural. Devolve id, nome exato, categoria, fonte e valores POR 100 g " +
				"(kcal, proteína, carboidrato, gordura, fibra; null = não analisado na TACO). " +
				"A TACO separa cru e cozido: escolha a forma em que o alimento foi pesado. Se houver mais de um candidato plausível, " +
				"pergunte ao usuário antes de registrar. Só leitura.",
			inputSchema: z.object({
				texto: z.string().min(1).max(120).describe('Ex.: "arroz cozido", "frango peito grelhado", "banana prata".'),
				limite: z.number().int().min(1).max(40).optional().describe("Máximo de candidatos (padrão 15)."),
			}),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ texto, limite }) => {
			try {
				const db = await abrir(env);
				await garantirTaco(db);
				const achados = buscar(texto, await todosAlimentos(db), limite ?? 15);
				if (!achados.length) {
					return json({ encontrados: 0, mensagem: `Nada parecido com "${texto}". Tente outra palavra ou use cadastrar_alimento.` });
				}
				return json({
					encontrados: achados.length,
					alimentos: achados.map((a) => ({
						id: a.id,
						nome: a.nome,
						categoria: a.categoria,
						fonte: a.fonte,
						por_100g: porCem(a),
						semelhanca: a.nota,
					})),
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"cadastrar_alimento",
		{
			description:
				"Cadastra um alimento que não está na TACO (fonte = manual), com valores POR 100 g (ex.: rótulo do produto convertido para 100 g). " +
				"kcal é obrigatório. Se já existir alimento com o mesmo nome, não duplica e devolve o existente. Confirme os valores com o usuário antes.",
			inputSchema: z.object({
				nome: z.string().min(2).max(120),
				categoria: z.string().max(60).optional(),
				...POR_100G,
				kcal: z.number().min(0).max(900).describe("kcal por 100 g."),
			}),
			annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
		},
		async (a) => {
			try {
				const soma = (a.proteina_g ?? 0) + (a.carbo_g ?? 0) + (a.gordura_g ?? 0) + (a.fibra_g ?? 0);
				if (soma > 101) throw new ErroValidacao(`Proteína + carboidrato + gordura + fibra = ${soma} g em 100 g: confira os valores.`);
				const db = await abrir(env);
				await garantirTaco(db);
				const r = await cadastrarAlimento(db, a);
				return json({
					criado: r.criado,
					mensagem: r.criado ? "Alimento cadastrado." : "Já existia um alimento com esse nome; nada foi criado.",
					alimento: { id: r.alimento.id, nome: r.alimento.nome, fonte: r.alimento.fonte, por_100g: porCem(r.alimento) },
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"registrar_refeicao",
		{
			description:
				"Registra uma refeição. Cada item: alimento_id (de buscar_alimento) OU nome + valores por 100 g (pelo menos kcal), e os gramas. " +
				"Calcula cada item pelos gramas (valor por 100 g × gramas ÷ 100) e grava os valores calculados (não mudam se a tabela for editada depois). " +
				"data_hora padrão = agora (Brasília). Devolve os itens, o total da refeição e o total do dia. " +
				"Confirme alimentos e gramas com o usuário antes de gravar.",
			inputSchema: z.object({
				tipo: z.enum(TIPOS_REFEICAO).describe("cafe, almoco, lanche, jantar ou outro."),
				data_hora: z.string().max(19).optional().describe('"AAAA-MM-DD HH:MM" no horário de Brasília. Padrão: agora.'),
				observacao: z.string().max(300).optional(),
				itens: z
					.array(
						z.object({
							alimento_id: z.number().int().positive().optional(),
							nome: z.string().min(1).max(120).optional().describe("Nome livre, quando não há alimento_id."),
							...POR_100G,
							gramas: z.number().gt(0).max(5000).describe("Quantidade consumida em gramas."),
						}),
					)
					.min(1)
					.max(40),
			}),
			annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
		},
		async ({ tipo, data_hora, observacao, itens }) => {
			try {
				const agora = new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 19).replace("T", " ");
				const quando = data_hora ? normalizarDataHora(data_hora, "data_hora") : agora;
				const db = await abrir(env);
				await garantirTaco(db);
				const calculados = await calcularItens(db, itens);
				const id = await gravarRefeicao(db, { data_hora: quando, tipo, observacao }, calculados);
				const { faltando, ...total } = somar(calculados);
				return json({
					gravado: true,
					refeicao: { id, data_hora: quando, tipo, observacao: observacao ?? null },
					itens: calculados.map((it) => ({
						alimento_id: it.alimento_id,
						nome: it.nome,
						fonte: it.fonte,
						gramas: it.gramas,
						...Object.fromEntries(NUTRIENTES.map((k) => [k, it[k]])),
					})),
					total_refeicao: total,
					total_dia: await totalDoDia(db, quando.slice(0, 10)),
					aviso: Object.keys(faltando).length
						? `Alguns itens não têm valor na TACO para: ${Object.keys(faltando).join(", ")} (contados como 0 nos totais).`
						: undefined,
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"ver_refeicoes",
		{
			description:
				"Lista as refeições do período (mais recentes primeiro) com itens, gramas e valores, o total de cada refeição, " +
				"o total de cada dia (com a água ingerida no dia em agua_ml, à parte da comida) e a média por dia (só dias com refeição registrada). Só leitura.",
			inputSchema: z.object({ periodo: PERIODO }),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ periodo }) => {
			try {
				const p = lerPeriodo(periodo ?? "7d");
				const db = await abrir(env);
				const linhasItens = await lerItens(db, p.inicio, p.fim);
				const porRef = new Map<number, typeof linhasItens>();
				for (const l of linhasItens) porRef.set(l.refeicao_id, [...(porRef.get(l.refeicao_id) ?? []), l]);
				const refeicoes = [...porRef.entries()]
					.map(([id, l]) => {
						const itens = l.filter((x) => x.nome);
						const { faltando: _f, ...total } = somar(itens);
						return {
							id,
							data_hora: l[0].data_hora,
							tipo: l[0].tipo,
							observacao: l[0].observacao ?? undefined,
							itens: itens.map((x) => ({
								nome: x.nome,
								alimento_id: x.alimento_id,
								gramas: x.gramas,
								...Object.fromEntries(NUTRIENTES.map((k) => [k, x[k]])),
							})),
							total,
						};
					})
					.sort((a, b) => (a.data_hora < b.data_hora ? 1 : -1));
				const [dias, regsAgua] = await Promise.all([nutricaoPorDia(db, p.inicio, p.fim), lerAgua(db, p.inicio, p.fim)]);
				const aguaDia = new Map(somarAguaPorDia(regsAgua).map((d) => [d.data, d.total_ml]));
				const med = (k: keyof (typeof dias)[number]) => arred(media(dias.map((d) => d[k] as number)), k === "kcal_consumidas" ? 0 : 1);
				return json({
					periodo: p,
					refeicoes_no_periodo: refeicoes.length,
					dias_com_refeicoes: dias.length,
					media_por_dia: dias.length
						? { kcal: med("kcal_consumidas"), proteina_g: med("proteina_g"), carbo_g: med("carbo_g"), gordura_g: med("gordura_g"), fibra_g: med("fibra_g") }
						: null,
					// agua_ml = água ingerida no dia (registrar_agua); não entra nos totais da comida.
					totais_por_dia: [...dias].reverse().map((d) => ({ ...d, agua_ml: aguaDia.get(d.data) ?? 0 })),
					refeicoes,
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"apagar_refeicao",
		{
			description:
				"Apaga UMA refeição (e os itens dela) pelo id. Sem confirmar = true só mostra o que seria apagado. " +
				"Mostre a refeição ao usuário e peça confirmação antes de chamar com confirmar = true.",
			inputSchema: z.object({
				id: z.number().int().positive(),
				confirmar: z.boolean().optional().describe("true para apagar de verdade."),
			}),
			annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
		},
		async ({ id, confirmar }) => {
			try {
				const db = await abrir(env);
				const ref = linhas<{ id: number; data_hora: string; tipo: string; observacao: string | null }>(
					await db.execute({ sql: "SELECT * FROM refeicoes WHERE id = ?", args: [id] }),
				)[0];
				if (!ref) return json({ apagado: false, motivo: `Refeição ${id} não existe.` });
				const itens = linhas<Record<string, number | string | null>>(
					await db.execute({ sql: "SELECT nome, gramas, kcal, proteina_g, carbo_g, gordura_g, fibra_g FROM refeicao_itens WHERE refeicao_id = ?", args: [id] }),
				);
				const { faltando: _f, ...total } = somar(itens as never);
				const descricao = { ...ref, itens, total };
				if (!confirmar) return json({ apagado: false, seria_apagada: descricao, aviso: "Chame de novo com confirmar = true para apagar." });
				await apagarRefeicao(db, id);
				return json({ apagado: true, refeicao_apagada: descricao, total_dia: await totalDoDia(db, ref.data_hora.slice(0, 10)) });
			} catch (e) {
				return falha(e);
			}
		},
	);

	// ── Água ingerida ──────────────────────────────────────────────────────

	server.registerTool(
		"registrar_agua",
		{
			description:
				`Registra água bebida, em ml (inteiro de 1 a ${ML_MAX_REGISTRO} por registro; ex.: copo 250, garrafa 500). ` +
				"data_hora padrão = agora (Brasília). Devolve o registro gravado, o total do dia e, se houver meta (definir_meta_agua), " +
				"quanto falta. É a água ingerida: não tem relação com agua_pct da balança (% de água corporal).",
			inputSchema: z.object({
				ml: z.number().int().min(1).max(ML_MAX_REGISTRO).describe("Quantidade em ml."),
				data_hora: z.string().max(19).optional().describe('"AAAA-MM-DD HH:MM" no horário de Brasília. Padrão: agora.'),
			}),
			annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
		},
		async ({ ml, data_hora }) => {
			try {
				const agora = new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 19).replace("T", " ");
				const quando = data_hora ? normalizarDataHora(data_hora, "data_hora") : agora;
				const db = await abrir(env);
				const reg = await registrarAgua(db, quando, ml);
				return json({ gravado: true, registro: reg, total_dia: await aguaDoDia(db, quando.slice(0, 10)) });
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"ver_agua",
		{
			description:
				"Lista a água ingerida no período (mais recentes primeiro), o total de cada dia e a média por dia (só dias com registro). " +
				"Se houver meta (definir_meta_agua), diz em quantos dias ela foi batida. Só leitura.",
			inputSchema: z.object({ periodo: PERIODO }),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async ({ periodo }) => {
			try {
				const p = lerPeriodo(periodo ?? "7d");
				const db = await abrir(env);
				const [regs, meta] = await Promise.all([lerAgua(db, p.inicio, p.fim), lerMeta(db)]);
				const dias = somarAguaPorDia(regs);
				const mediaDia = media(dias.map((d) => d.total_ml));
				return json({
					periodo: p,
					meta_ml: meta ?? undefined,
					registros_no_periodo: regs.length,
					dias_com_registro: dias.length,
					media_por_dia_ml: mediaDia === null ? null : Math.round(mediaDia),
					dias_meta_batida: meta === null ? undefined : dias.filter((d) => d.total_ml >= meta).length,
					totais_por_dia: [...dias].reverse().map((d) => ({ ...d, ...(situacaoMeta(d.total_ml, meta) ?? {}) })),
					registros: [...regs].reverse(),
				});
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"apagar_agua",
		{
			description:
				"Apaga UM registro de água pelo id. Sem confirmar = true só mostra o que seria apagado. " +
				"Mostre o registro ao usuário e peça confirmação antes de chamar com confirmar = true.",
			inputSchema: z.object({
				id: z.number().int().positive(),
				confirmar: z.boolean().optional().describe("true para apagar de verdade."),
			}),
			annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
		},
		async ({ id, confirmar }) => {
			try {
				const db = await abrir(env);
				const reg = await aguaPorId(db, id);
				if (!reg) return json({ apagado: false, motivo: `Registro de água ${id} não existe.` });
				if (!confirmar) return json({ apagado: false, seria_apagado: reg, aviso: "Chame de novo com confirmar = true para apagar." });
				await apagarAgua(db, id);
				return json({ apagado: true, registro_apagado: reg, total_dia: await aguaDoDia(db, reg.data_hora.slice(0, 10)) });
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"definir_meta_agua",
		{
			description:
				`Define a meta diária de água em ml (inteiro de ${META_MIN} a ${META_MAX}). Substitui a meta anterior. ` +
				"Com meta, registrar_agua, ver_agua e resumo_hoje mostram quanto falta e se a meta foi batida; sem meta, não mostram.",
			inputSchema: z.object({
				ml: z.number().int().min(META_MIN).max(META_MAX).describe("Meta diária em ml, ex.: 2500."),
			}),
			annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
		},
		async ({ ml }) => {
			try {
				const db = await abrir(env);
				const r = await gravarMeta(db, ml);
				return json({ gravado: true, meta_ml: r.atual, meta_anterior_ml: r.anterior, hoje: await aguaDoDia(db, hojeBRT()) });
			} catch (e) {
				return falha(e);
			}
		},
	);

	server.registerTool(
		"resumo_hoje",
		{
			description:
				"Painel rápido: última medição da balança (com variação vs. a anterior e vs. ~30 dias atrás), a atividade de hoje e de ontem " +
					"e a água ingerida hoje (total, meta e quanto falta, se houver meta). Só leitura.",
			inputSchema: z.object({}),
			annotations: { readOnlyHint: true, openWorldHint: false },
		},
		async () => {
			try {
				const db = await abrir(env);
				const hoje = hojeBRT();
				// Sem os reenvios da balança: lê umas a mais e filtra (em ordem de horário).
				const ultimas = semReenvios(
					linhas<Medicao>(await db.execute("SELECT * FROM medicoes ORDER BY medido_em DESC LIMIT 12")).reverse(),
				)
					.reverse()
					.slice(0, 2) as unknown as Record<string, number | string>[];
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
					agua_hoje: await aguaDoDia(db, hoje),
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
