/**
 * Funções puras (sem banco) usadas pelas ferramentas do MCP.
 * Datas no fuso de Brasília (UTC-3, sem horário de verão desde 2019), sempre "AAAA-MM-DD".
 */
import { COLUNAS_MEDICAO, type Atividade, type Medicao } from "./db.ts";

// ── Datas ───────────────────────────────────────────────────────────────────

export function hojeBRT(agora: Date = new Date()): string {
	return new Date(agora.getTime() - 3 * 3600_000).toISOString().slice(0, 10);
}

export function somarDias(data: string, dias: number): string {
	const d = new Date(`${data}T00:00:00Z`);
	d.setUTCDate(d.getUTCDate() + dias);
	return d.toISOString().slice(0, 10);
}

export function diasEntre(a: string, b: string): number {
	return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);
}

const RE_DATA = /^\d{4}-\d{2}-\d{2}$/;
const RE_MES = /^\d{4}-\d{2}$/;

export type Periodo = { inicio: string; fim: string; rotulo: string };

function ultimoDiaDoMes(anoMes: string): string {
	const [a, m] = anoMes.split("-").map(Number);
	return new Date(Date.UTC(a, m, 0)).toISOString().slice(0, 10);
}

/**
 * Lê o período em português ou números:
 * "7d", "30", "4 semanas", "3m", "3 meses", "1a", "ano", "mes", "semana", "hoje", "ontem", "tudo",
 * "2026-05" (um mês), "2026-05-10" (um dia), "2026-01-01..2026-03-01" ou "2026-01-01 a 2026-03-01".
 * Padrão: últimos 30 dias.
 */
export function lerPeriodo(texto: string | undefined, agora: Date = new Date()): Periodo {
	const hoje = hojeBRT(agora);
	const t = (texto ?? "").trim().toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
	if (!t) return { inicio: somarDias(hoje, -29), fim: hoje, rotulo: "últimos 30 dias" };

	const intervalo = t.match(/^(\d{4}-\d{2}(?:-\d{2})?)\s*(?:\.\.|a|ate|-{1,2}|\/|,)\s*(\d{4}-\d{2}(?:-\d{2})?)$/);
	if (intervalo) {
		let [, a, b] = intervalo;
		if (RE_MES.test(a)) a = `${a}-01`;
		if (RE_MES.test(b)) b = ultimoDiaDoMes(b);
		if (a > b) [a, b] = [b, a];
		return { inicio: a, fim: b, rotulo: `${a} a ${b}` };
	}
	if (RE_DATA.test(t)) return { inicio: t, fim: t, rotulo: t };
	if (RE_MES.test(t)) return { inicio: `${t}-01`, fim: ultimoDiaDoMes(t), rotulo: `mês ${t}` };
	if (t === "tudo" || t === "todos" || t === "sempre" || t === "all") {
		return { inicio: "1900-01-01", fim: hoje, rotulo: "todo o histórico" };
	}
	if (t === "hoje") return { inicio: hoje, fim: hoje, rotulo: "hoje" };
	if (t === "ontem") {
		const o = somarDias(hoje, -1);
		return { inicio: o, fim: o, rotulo: "ontem" };
	}

	const m = t.match(/^(?:ultim[oa]s?\s+)?(\d+)?\s*(d|dia|dias|s|sem|semana|semanas|m|mes|meses|a|ano|anos|y)?$/);
	if (m && (m[1] || m[2])) {
		const n = m[1] ? Number(m[1]) : 1;
		const u = m[2] ?? "d";
		let dias = n;
		let nome = `${n} dia${n > 1 ? "s" : ""}`;
		if (u.startsWith("s")) {
			dias = n * 7;
			nome = `${n} semana${n > 1 ? "s" : ""}`;
		} else if (u.startsWith("m")) {
			dias = n * 30;
			nome = `${n} ${n > 1 ? "meses" : "mês"}`;
		} else if (u.startsWith("a") || u === "y") {
			dias = n * 365;
			nome = `${n} ano${n > 1 ? "s" : ""}`;
		}
		dias = Math.max(1, Math.min(dias, 365 * 50));
		return { inicio: somarDias(hoje, -(dias - 1)), fim: hoje, rotulo: `últimos ${nome}` };
	}
	throw new Error(
		`Período "${texto}" não reconhecido. Use por exemplo 7d, 30d, 3 meses, 1 ano, tudo, 2026-05 ou 2026-01-01..2026-03-31.`,
	);
}

// ── Métricas ────────────────────────────────────────────────────────────────

export type Fonte = "medicoes" | "atividade";
export type InfoMetrica = { coluna: string; fonte: Fonte; nome: string; unidade: string };

export const METRICAS: Record<string, InfoMetrica> = {
	peso: { coluna: "peso", fonte: "medicoes", nome: "Peso", unidade: "kg" },
	imc: { coluna: "imc", fonte: "medicoes", nome: "IMC", unidade: "" },
	gordura_pct: { coluna: "gordura_pct", fonte: "medicoes", nome: "Gordura", unidade: "%" },
	agua_pct: { coluna: "agua_pct", fonte: "medicoes", nome: "Água", unidade: "%" },
	musculo_kg: { coluna: "musculo_kg", fonte: "medicoes", nome: "Massa muscular", unidade: "kg" },
	osso_kg: { coluna: "osso_kg", fonte: "medicoes", nome: "Massa óssea", unidade: "kg" },
	visceral: { coluna: "visceral", fonte: "medicoes", nome: "Gordura visceral", unidade: "" },
	metabolismo_kcal: { coluna: "metabolismo_kcal", fonte: "medicoes", nome: "Metabolismo basal", unidade: "kcal" },
	proteina_pct: { coluna: "proteina_pct", fonte: "medicoes", nome: "Proteína", unidade: "%" },
	impedancia: { coluna: "impedancia", fonte: "medicoes", nome: "Impedância", unidade: "Ω" },
	passos: { coluna: "passos", fonte: "atividade", nome: "Passos", unidade: "" },
	calorias: { coluna: "calorias", fonte: "atividade", nome: "Calorias ativas", unidade: "kcal" },
	fc_repouso: { coluna: "fc_repouso", fonte: "atividade", nome: "FC de repouso", unidade: "bpm" },
	fc_media: { coluna: "fc_media", fonte: "atividade", nome: "FC média", unidade: "bpm" },
	sono_min: { coluna: "sono_min", fonte: "atividade", nome: "Sono total", unidade: "min" },
	sono_profundo_min: { coluna: "sono_profundo_min", fonte: "atividade", nome: "Sono profundo", unidade: "min" },
	sono_leve_min: { coluna: "sono_leve_min", fonte: "atividade", nome: "Sono leve", unidade: "min" },
	sono_rem_min: { coluna: "sono_rem_min", fonte: "atividade", nome: "Sono REM", unidade: "min" },
	acordado_min: { coluna: "acordado_min", fonte: "atividade", nome: "Acordado na noite", unidade: "min" },
	spo2_medio: { coluna: "spo2_medio", fonte: "atividade", nome: "SpO2 média", unidade: "%" },
};

const APELIDOS: Record<string, string> = {
	gordura: "gordura_pct",
	fat: "gordura_pct",
	agua: "agua_pct",
	musculo: "musculo_kg",
	massa_muscular: "musculo_kg",
	osso: "osso_kg",
	massa_ossea: "osso_kg",
	gordura_visceral: "visceral",
	metabolismo: "metabolismo_kcal",
	tmb: "metabolismo_kcal",
	bmr: "metabolismo_kcal",
	proteina: "proteina_pct",
	sono: "sono_min",
	sono_total: "sono_min",
	sono_profundo: "sono_profundo_min",
	profundo: "sono_profundo_min",
	sono_leve: "sono_leve_min",
	rem: "sono_rem_min",
	sono_rem: "sono_rem_min",
	acordado: "acordado_min",
	fc: "fc_repouso",
	frequencia_cardiaca: "fc_repouso",
	fc_de_repouso: "fc_repouso",
	spo2: "spo2_medio",
	oxigenio: "spo2_medio",
	steps: "passos",
	kcal: "calorias",
	weight: "peso",
};

export function lerMetrica(texto: string): InfoMetrica & { chave: string } {
	const k = texto
		.trim()
		.toLowerCase()
		.normalize("NFD")
		.replace(/[̀-ͯ]/g, "")
		.replace(/[\s-]+/g, "_");
	const chave = METRICAS[k] ? k : APELIDOS[k];
	if (!chave) {
		throw new Error(`Métrica "${texto}" não existe. Opções: ${Object.keys(METRICAS).join(", ")}.`);
	}
	return { chave, ...METRICAS[chave] };
}

// ── Estatística ─────────────────────────────────────────────────────────────

export type Ponto = { data: string; valor: number };

/** Casas decimais de cada métrica. Impedância: sempre 1 casa (média de várias medições). */
export function casasDe(chave: string): number {
	if (chave === "impedancia") return 1;
	if (chave === "passos") return 0;
	const u = METRICAS[chave]?.unidade;
	if (u === "min" || u === "kcal") return 0;
	return 2;
}

export function arred(v: number | null | undefined, casas = 2): number | null {
	if (v === null || v === undefined || !Number.isFinite(v)) return null;
	const f = 10 ** casas;
	return Math.round(v * f) / f;
}

/** Série diária de uma métrica: medições do mesmo dia viram a média do dia. */
export function serieDiaria(info: InfoMetrica, medicoes: Medicao[], atividade: Atividade[]): Ponto[] {
	const porDia = new Map<string, number[]>();
	const fonte = info.fonte === "medicoes" ? medicoes : atividade;
	for (const r of fonte as Record<string, unknown>[]) {
		const v = r[info.coluna];
		if (typeof v !== "number" || !Number.isFinite(v)) continue;
		const data = String(info.fonte === "medicoes" ? r.medido_em : r.data).slice(0, 10);
		const lista = porDia.get(data) ?? [];
		lista.push(v);
		porDia.set(data, lista);
	}
	return [...porDia.entries()]
		.sort(([a], [b]) => (a < b ? -1 : 1))
		.map(([data, vs]) => ({ data, valor: vs.reduce((s, x) => s + x, 0) / vs.length }));
}

/** Inclinação da reta (mínimos quadrados) em unidades por dia. */
export function inclinacaoPorDia(pontos: Ponto[]): number | null {
	if (pontos.length < 2) return null;
	const x0 = pontos[0].data;
	const xs = pontos.map((p) => diasEntre(x0, p.data));
	const ys = pontos.map((p) => p.valor);
	const mx = media(xs)!;
	const my = media(ys)!;
	let num = 0;
	let den = 0;
	for (let i = 0; i < xs.length; i++) {
		num += (xs[i] - mx) * (ys[i] - my);
		den += (xs[i] - mx) ** 2;
	}
	return den === 0 ? null : num / den;
}

export function media(vs: number[]): number | null {
	return vs.length ? vs.reduce((s, x) => s + x, 0) / vs.length : null;
}

/** Segunda-feira da semana da data (semana começa na segunda). */
export function inicioSemana(data: string): string {
	const d = new Date(`${data}T00:00:00Z`);
	const dow = (d.getUTCDay() + 6) % 7;
	return somarDias(data, -dow);
}

export function resumoSerie(info: InfoMetrica & { chave: string }, pontos: Ponto[]) {
	const casas = casasDe(info.chave);
	if (!pontos.length) return { metrica: info.chave, nome: info.nome, unidade: info.unidade, dias_com_dado: 0 };
	const vs = pontos.map((p) => p.valor);
	const min = Math.min(...vs);
	const max = Math.max(...vs);
	const incl = inclinacaoPorDia(pontos);
	const semanas = new Map<string, number[]>();
	for (const p of pontos) {
		const s = inicioSemana(p.data);
		semanas.set(s, [...(semanas.get(s) ?? []), p.valor]);
	}
	const semanal = [...semanas.entries()]
		.sort(([a], [b]) => (a < b ? -1 : 1))
		.map(([semana, v]) => ({ semana, media: arred(media(v), casas), dias: v.length }));
	const porSemana = incl === null ? null : incl * 7;
	return {
		metrica: info.chave,
		nome: info.nome,
		unidade: info.unidade,
		dias_com_dado: pontos.length,
		media: arred(media(vs), casas),
		minimo: arred(min, casas),
		dia_minimo: pontos.find((p) => p.valor === min)!.data,
		maximo: arred(max, casas),
		dia_maximo: pontos.find((p) => p.valor === max)!.data,
		primeiro: { data: pontos[0].data, valor: arred(pontos[0].valor, casas) },
		ultimo: { data: pontos[pontos.length - 1].data, valor: arred(pontos[pontos.length - 1].valor, casas) },
		variacao: arred(pontos[pontos.length - 1].valor - pontos[0].valor, casas),
		tendencia_por_semana: arred(porSemana, info.chave === "passos" ? 0 : info.chave === "impedancia" ? 1 : 3),
		tendencia: textoTendencia(porSemana, info),
		medias_semanais: semanal,
	};
}

function textoTendencia(porSemana: number | null, info: InfoMetrica): string {
	if (porSemana === null) return "dados insuficientes";
	const escala = Math.abs(porSemana);
	const limiar: Record<string, number> = { kg: 0.05, "%": 0.05, min: 3, kcal: 10, bpm: 0.3, "": 0.05 };
	const lim = info.coluna === "passos" ? 150 : (limiar[info.unidade] ?? 0.05);
	if (escala < lim) return "estável";
	return porSemana > 0 ? "subindo" : "caindo";
}

/** Correlação de Pearson. */
export function pearson(xs: number[], ys: number[]): number | null {
	const n = Math.min(xs.length, ys.length);
	if (n < 3) return null;
	const mx = media(xs.slice(0, n))!;
	const my = media(ys.slice(0, n))!;
	let sxy = 0;
	let sxx = 0;
	let syy = 0;
	for (let i = 0; i < n; i++) {
		sxy += (xs[i] - mx) * (ys[i] - my);
		sxx += (xs[i] - mx) ** 2;
		syy += (ys[i] - my) ** 2;
	}
	if (sxx === 0 || syy === 0) return null;
	return sxy / Math.sqrt(sxx * syy);
}

export function forcaCorrelacao(r: number | null): string {
	if (r === null) return "sem dados suficientes (precisa de pelo menos 3 dias com as duas métricas)";
	const a = Math.abs(r);
	const sentido = r > 0 ? "positiva (sobem juntas)" : "negativa (quando uma sobe a outra desce)";
	if (a < 0.1) return "nenhuma relação clara";
	if (a < 0.3) return `fraca, ${sentido}`;
	if (a < 0.5) return `moderada, ${sentido}`;
	if (a < 0.7) return `forte, ${sentido}`;
	return `muito forte, ${sentido}`;
}

/**
 * Junta duas séries por dia. defasagem = N compara metrica1 do dia D com metrica2 do dia D+N
 * (ex.: sono da noite x peso do dia seguinte = defasagem 1 se o sono fosse da data em que dormiu;
 * aqui o sono já fica na data em que acordou, então sono x peso da mesma manhã é defasagem 0).
 */
export function correlacionarSeries(a: Ponto[], b: Ponto[], defasagem = 0) {
	const mb = new Map(b.map((p) => [p.data, p.valor]));
	const pares: { data: string; x: number; y: number }[] = [];
	for (const p of a) {
		const y = mb.get(somarDias(p.data, defasagem));
		if (y !== undefined) pares.push({ data: p.data, x: p.valor, y });
	}
	const r = pearson(
		pares.map((p) => p.x),
		pares.map((p) => p.y),
	);
	// Reta y = a + b·x, para dizer "cada +1 em X muda Y em ..."
	let inclinacao: number | null = null;
	if (pares.length >= 3) {
		const mx = media(pares.map((p) => p.x))!;
		const my = media(pares.map((p) => p.y))!;
		let num = 0;
		let den = 0;
		for (const p of pares) {
			num += (p.x - mx) * (p.y - my);
			den += (p.x - mx) ** 2;
		}
		inclinacao = den ? num / den : null;
	}
	return { pares, r, inclinacao };
}

// ── Sono ────────────────────────────────────────────────────────────────────

export function horas(min: number | null | undefined): string | null {
	if (min === null || min === undefined || !Number.isFinite(min)) return null;
	const h = Math.floor(min / 60);
	const m = Math.round(min - h * 60);
	return `${h}h${String(m).padStart(2, "0")}`;
}

export function resumoSono(dias: Atividade[]) {
	const noites = dias
		.filter((d) => typeof d.sono_min === "number" && d.sono_min! > 0)
		.map((d) => {
			const total = d.sono_min!;
			const pct = (v: number | null | undefined) => (typeof v === "number" && total > 0 ? arred((v / total) * 100, 0) : null);
			return {
				data: d.data,
				total: horas(total),
				total_min: arred(total, 0),
				profundo_min: arred(d.sono_profundo_min, 0),
				leve_min: arred(d.sono_leve_min, 0),
				rem_min: arred(d.sono_rem_min, 0),
				acordado_min: arred(d.acordado_min, 0),
				profundo_pct: pct(d.sono_profundo_min),
				rem_pct: pct(d.sono_rem_min),
				spo2: arred(d.spo2_medio, 1),
			};
		});
	const med = (k: keyof Atividade) => {
		const v = dias.map((d) => d[k]).filter((x): x is number => typeof x === "number" && x > 0);
		return media(v);
	};
	const totais = noites.map((n) => n.total_min!).filter((x) => x !== null);
	const ruins = noites.filter((n) => (n.total_min ?? 0) < 360).length;
	return {
		noites_com_dado: noites.length,
		media_total: horas(med("sono_min")),
		media_total_min: arred(med("sono_min"), 0),
		media_profundo_min: arred(med("sono_profundo_min"), 0),
		media_leve_min: arred(med("sono_leve_min"), 0),
		media_rem_min: arred(med("sono_rem_min"), 0),
		media_acordado_min: arred(med("acordado_min"), 0),
		melhor_noite: noites.length ? noites.find((n) => n.total_min === Math.max(...totais)) : null,
		pior_noite: noites.length ? noites.find((n) => n.total_min === Math.min(...totais)) : null,
		noites_abaixo_de_6h: ruins,
		noites,
	};
}

/** Medição mais próxima de uma data (até `tolerancia` dias de distância). */
export function maisProxima(medicoes: Medicao[], data: string, tolerancia = 3): Medicao | null {
	let melhor: Medicao | null = null;
	let dist = Infinity;
	for (const m of medicoes) {
		const d = Math.abs(diasEntre(data, m.medido_em.slice(0, 10)));
		if (d <= tolerancia && d < dist) {
			melhor = m;
			dist = d;
		}
	}
	return melhor;
}

// ── Medição do dia e impedância suspeita ────────────────────────────────────

/**
 * Média das medições de um dia, como o ver_evolucao faz.
 * Se o dia não tem medição, usa o dia mais próximo com medição (até `tolerancia` dias; empate: o dia anterior)
 * e diz qual foi em `data_real_medicao`.
 */
export function medicaoDoDia(medicoes: Medicao[], data: string, tolerancia = 3) {
	const porDia = new Map<string, Medicao[]>();
	for (const m of medicoes) {
		const d = m.medido_em.slice(0, 10);
		porDia.set(d, [...(porDia.get(d) ?? []), m]);
	}
	let dia: string | null = porDia.has(data) ? data : null;
	if (!dia) {
		for (let k = 1; k <= tolerancia && !dia; k++) {
			if (porDia.has(somarDias(data, -k))) dia = somarDias(data, -k);
			else if (porDia.has(somarDias(data, k))) dia = somarDias(data, k);
		}
	}
	if (!dia) return null;
	const lista = [...porDia.get(dia)!].sort((a, b) => (a.medido_em < b.medido_em ? -1 : 1));
	const mediaDia: Record<string, number> = {};
	for (const c of COLUNAS_MEDICAO) {
		const v = media(lista.map((m) => m[c]).filter((x): x is number => typeof x === "number" && Number.isFinite(x)));
		if (v !== null) mediaDia[c] = arred(v, casasDe(c)) as number;
	}
	return {
		data_real_medicao: dia,
		mesmo_dia: dia === data,
		distancia_dias: diasEntre(data, dia),
		medicoes_no_dia: lista.length,
		horarios: lista.map((m) => m.medido_em.slice(11, 16)),
		ids: lista.map((m) => m.id).filter((x) => x !== undefined),
		media_do_dia: mediaDia,
	};
}

/** Métricas calculadas a partir da impedância (bioimpedância). */
export const METRICAS_DE_IMPEDANCIA = new Set(["gordura_pct", "musculo_kg", "agua_pct", "osso_kg", "proteina_pct", "impedancia"]);
export const LIMIAR_IMPEDANCIA_OHMS = 30;

export type Suspeita = {
	id?: number;
	medido_em: string;
	impedancia: number;
	/** "mediana do dia" ou "mediana dos últimos 7 dias" */
	referencia: string;
	medicoes_na_referencia: number;
	impedancia_referencia: number;
	diferenca_ohms: number;
};

export function mediana(vs: number[]): number | null {
	if (!vs.length) return null;
	const o = [...vs].sort((a, b) => a - b);
	const m = Math.floor(o.length / 2);
	return o.length % 2 ? o[m] : (o[m - 1] + o[m]) / 2;
}

export const MIN_MEDICOES_DIA = 3;
export const MSG_HISTORICO_INSUFICIENTE = "histórico insuficiente";

/** Peso + impedância: medições idênticas (a balança reenviando a mesma pesagem) contam uma vez só. */
function chaveDistinta(m: Medicao) {
	return `${m.peso}|${m.impedancia}`;
}

/**
 * Avalia a impedância de cada medição de `alvo`. Referência:
 *  - mediana do MESMO dia, se o dia tem pelo menos 3 medições distintas (peso+impedância iguais contam uma vez);
 *  - senão, mediana das medições distintas dos 7 dias anteriores;
 *  - sem nenhuma nos 7 dias anteriores: não marca e devolve em `historico_insuficiente`.
 * Suspeita = diferença maior que 30 Ω da referência.
 * `historico` deve trazer as medições desde 7 dias antes da primeira de `alvo` (pode incluir `alvo`).
 */
export function avaliarImpedancia(alvo: Medicao[], historico: Medicao[] = alvo, limiar = LIMIAR_IMPEDANCIA_OHMS) {
	const comImp = (l: Medicao[]) => l.filter((m) => typeof m.impedancia === "number" && m.impedancia! > 0);
	const todas = new Map<string, Medicao>();
	for (const m of comImp([...historico, ...alvo])) todas.set(m.medido_em, m);
	// Por dia: impedâncias das medições distintas.
	const porDia = new Map<string, Map<string, number>>();
	for (const m of todas.values()) {
		const d = m.medido_em.slice(0, 10);
		if (!porDia.has(d)) porDia.set(d, new Map());
		porDia.get(d)!.set(chaveDistinta(m), m.impedancia!);
	}
	const doDia = (d: string) => [...(porDia.get(d)?.values() ?? [])];

	const suspeitas: Suspeita[] = [];
	const historico_insuficiente: string[] = [];
	for (const m of comImp(alvo).sort((a, b) => (a.medido_em < b.medido_em ? -1 : 1))) {
		const dia = m.medido_em.slice(0, 10);
		const noDia = doDia(dia);
		let valores: number[];
		let referencia: string;
		if (noDia.length >= MIN_MEDICOES_DIA) {
			valores = noDia;
			referencia = "mediana do dia";
		} else {
			valores = [];
			for (let k = 1; k <= 7; k++) valores.push(...doDia(somarDias(dia, -k)));
			referencia = "mediana dos últimos 7 dias";
		}
		const ref = mediana(valores);
		if (ref === null) {
			historico_insuficiente.push(m.medido_em);
			continue;
		}
		const dif = m.impedancia! - ref;
		if (Math.abs(dif) > limiar) {
			suspeitas.push({
				id: m.id,
				medido_em: m.medido_em,
				impedancia: m.impedancia!,
				referencia,
				medicoes_na_referencia: valores.length,
				impedancia_referencia: arred(ref, 1)!,
				diferenca_ohms: arred(dif, 1)!,
			});
		}
	}
	return { suspeitas, historico_insuficiente };
}

/** Só a lista de suspeitas (ver `avaliarImpedancia`). */
export function medicoesSuspeitas(alvo: Medicao[], historico: Medicao[] = alvo, limiar = LIMIAR_IMPEDANCIA_OHMS): Suspeita[] {
	return avaliarImpedancia(alvo, historico, limiar).suspeitas;
}
