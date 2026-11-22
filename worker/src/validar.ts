import { COLUNAS_ATIVIDADE, COLUNAS_MEDICAO, type Atividade, type Medicao } from "./db.ts";

/** Faixas aceitas: o que estiver fora vira erro (dado claramente quebrado). */
const FAIXA_MEDICAO: Record<(typeof COLUNAS_MEDICAO)[number], [number, number]> = {
	peso: [10, 300],
	impedancia: [1, 3000],
	imc: [5, 100],
	gordura_pct: [0, 80],
	agua_pct: [0, 90],
	musculo_kg: [0, 200],
	osso_kg: [0, 15],
	visceral: [-100, 100],
	metabolismo_kcal: [0, 6000],
	proteina_pct: [0, 60],
};

const FAIXA_ATIVIDADE: Record<(typeof COLUNAS_ATIVIDADE)[number], [number, number]> = {
	passos: [0, 200_000],
	calorias: [0, 20_000],
	fc_repouso: [20, 220],
	fc_repouso_estimada: [0, 1],
	fc_media: [20, 250],
	sono_min: [0, 1440],
	sono_profundo_min: [0, 1440],
	sono_leve_min: [0, 1440],
	sono_rem_min: [0, 1440],
	acordado_min: [0, 1440],
	spo2_medio: [50, 100],
};

const RE_DATA_HORA = /^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?$/;
const RE_DATA = /^\d{4}-\d{2}-\d{2}$/;

export class ErroValidacao extends Error {}

function numero(v: unknown, campo: string, [min, max]: [number, number]): number | null {
	if (v === null || v === undefined || v === "") return null;
	const n = typeof v === "string" ? Number(v.replace(",", ".")) : v;
	if (typeof n !== "number" || !Number.isFinite(n)) throw new ErroValidacao(`${campo} inválido: ${JSON.stringify(v)}`);
	if (n < min || n > max) throw new ErroValidacao(`${campo} fora da faixa (${min}–${max}): ${n}`);
	return n;
}

/** "2026-11-22T07:15" / "2026-11-22 07:15:03" → "2026-11-22 07:15:03" (horário local de Brasília). */
export function normalizarDataHora(v: unknown, campo = "medido_em"): string {
	if (typeof v !== "string" || !RE_DATA_HORA.test(v.trim())) {
		throw new ErroValidacao(`${campo} deve ser "AAAA-MM-DD HH:MM" ou "AAAA-MM-DD HH:MM:SS" (recebi ${JSON.stringify(v)})`);
	}
	const s = v.trim().replace("T", " ");
	const comSeg = s.length === 16 ? `${s}:00` : s;
	if (Number.isNaN(Date.parse(comSeg.replace(" ", "T") + "Z"))) throw new ErroValidacao(`${campo} inválido: ${v}`);
	return comSeg;
}

export function validarMedicao(o: unknown, origemPadrao = "balanca"): Medicao {
	if (!o || typeof o !== "object") throw new ErroValidacao("medição precisa ser um objeto");
	const r = o as Record<string, unknown>;
	const m: Medicao = { medido_em: normalizarDataHora(r.medido_em) };
	for (const c of COLUNAS_MEDICAO) {
		const n = numero(r[c], c, FAIXA_MEDICAO[c]);
		m[c] = c === "impedancia" && n !== null ? Math.round(n) : n;
	}
	if (m.peso === null || m.peso === undefined) throw new ErroValidacao("peso é obrigatório");
	const origem = r.origem ?? origemPadrao;
	if (origem !== "balanca" && origem !== "manual") throw new ErroValidacao('origem deve ser "balanca" ou "manual"');
	m.origem = origem;
	return m;
}

export function validarAtividade(o: unknown): Atividade {
	if (!o || typeof o !== "object") throw new ErroValidacao("atividade precisa ser um objeto");
	const r = o as Record<string, unknown>;
	if (typeof r.data !== "string" || !RE_DATA.test(r.data)) {
		throw new ErroValidacao(`data deve ser "AAAA-MM-DD" (recebi ${JSON.stringify(r.data)})`);
	}
	const a: Atividade = { data: r.data };
	for (const c of COLUNAS_ATIVIDADE) {
		const n = numero(r[c], c, FAIXA_ATIVIDADE[c]);
		a[c] = (c === "passos" || c === "fc_repouso_estimada") && n !== null ? Math.round(n) : n;
	}
	return a;
}

/** Aceita um objeto só, uma lista, ou { medicoes: [...] } / { dias: [...] }. */
export function lista(body: unknown, chave: string): unknown[] {
	if (Array.isArray(body)) return body;
	if (body && typeof body === "object" && Array.isArray((body as Record<string, unknown>)[chave])) {
		return (body as Record<string, unknown[]>)[chave];
	}
	return [body];
}

/** Comparação em tempo constante (não vaza a chave por tempo de resposta). */
export function chaveConfere(recebida: string | null | undefined, esperada: string | undefined): boolean {
	if (!recebida || !esperada) return false;
	const a = new TextEncoder().encode(recebida);
	const b = new TextEncoder().encode(esperada);
	let dif = a.length ^ b.length;
	for (let i = 0; i < Math.max(a.length, b.length); i++) dif |= (a[i] ?? 0) ^ (b[i] ?? 0);
	return dif === 0;
}
