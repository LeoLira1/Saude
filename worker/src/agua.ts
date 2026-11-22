/**
 * Água ingerida: registros (tabela agua) e meta diária (tabela config, chave meta_agua_ml).
 * Separado de refeições e do agua_pct da balança (% de água corporal).
 */
import type { Client } from "@libsql/client/web";
import { linhas } from "./db.ts";
import { ErroValidacao } from "./validar.ts";

export const ML_MAX_REGISTRO = 5000;
export const META_MIN = 500;
export const META_MAX = 8000;
const CHAVE_META = "meta_agua_ml";

export type RegistroAgua = { id: number; data_hora: string; ml: number; criado_em?: string };
export type DiaAgua = { data: string; total_ml: number; registros: number };

// ── Funções puras (testadas em test/agua.test.ts) ───────────────────────────

/** Total por dia (data = "AAAA-MM-DD" do data_hora), em ordem de data. */
export function somarAguaPorDia(registros: { data_hora: string; ml: number }[]): DiaAgua[] {
	const m = new Map<string, DiaAgua>();
	for (const r of registros) {
		const d = r.data_hora.slice(0, 10);
		const x = m.get(d) ?? { data: d, total_ml: 0, registros: 0 };
		x.total_ml += r.ml;
		x.registros++;
		m.set(d, x);
	}
	return [...m.values()].sort((a, b) => (a.data < b.data ? -1 : 1));
}

/** Situação do dia em relação à meta. Sem meta: null (as ferramentas não mostram meta). */
export function situacaoMeta(total: number, meta: number | null) {
	if (meta === null) return null;
	const falta = Math.max(0, meta - total);
	return {
		meta_ml: meta,
		falta_ml: falta,
		meta_batida: total >= meta,
		percentual: Math.round((total / meta) * 100),
	};
}

export function validarMl(ml: number): number {
	if (!Number.isInteger(ml) || ml <= 0 || ml > ML_MAX_REGISTRO) {
		throw new ErroValidacao(`ml deve ser um número inteiro de 1 a ${ML_MAX_REGISTRO} (recebi ${ml}).`);
	}
	return ml;
}

export function validarMeta(ml: number): number {
	if (!Number.isInteger(ml) || ml < META_MIN || ml > META_MAX) {
		throw new ErroValidacao(`A meta deve ser um número inteiro de ${META_MIN} a ${META_MAX} ml (recebi ${ml}).`);
	}
	return ml;
}

// ── Banco ───────────────────────────────────────────────────────────────────

export async function lerMeta(db: Client): Promise<number | null> {
	const rs = await db.execute({ sql: "SELECT valor FROM config WHERE chave = ?", args: [CHAVE_META] });
	const v = Number(linhas<{ valor: string }>(rs)[0]?.valor);
	return Number.isFinite(v) && v > 0 ? v : null;
}

export async function gravarMeta(db: Client, ml: number) {
	const anterior = await lerMeta(db);
	await db.execute({
		sql: `INSERT INTO config (chave, valor) VALUES (?, ?)
			ON CONFLICT(chave) DO UPDATE SET valor = excluded.valor, atualizado_em = datetime('now', '-3 hours')`,
		args: [CHAVE_META, String(validarMeta(ml))],
	});
	return { anterior, atual: ml };
}

export async function registrarAgua(db: Client, dataHora: string, ml: number): Promise<RegistroAgua> {
	const rs = await db.execute({
		sql: "INSERT INTO agua (data_hora, ml) VALUES (?, ?) RETURNING id, data_hora, ml, criado_em",
		args: [dataHora, validarMl(ml)],
	});
	return linhas<RegistroAgua>(rs)[0];
}

export async function lerAgua(db: Client, inicio: string, fim: string): Promise<RegistroAgua[]> {
	const rs = await db.execute({
		sql: "SELECT id, data_hora, ml, criado_em FROM agua WHERE substr(data_hora, 1, 10) BETWEEN ? AND ? ORDER BY data_hora, id",
		args: [inicio, fim],
	});
	return linhas<RegistroAgua>(rs);
}

export async function aguaPorId(db: Client, id: number): Promise<RegistroAgua | null> {
	const rs = await db.execute({ sql: "SELECT id, data_hora, ml, criado_em FROM agua WHERE id = ?", args: [id] });
	return linhas<RegistroAgua>(rs)[0] ?? null;
}

export async function apagarAgua(db: Client, id: number) {
	await db.execute({ sql: "DELETE FROM agua WHERE id = ?", args: [id] });
}

/** Total do dia + situação da meta (sem meta: só o total). */
export async function aguaDoDia(db: Client, data: string) {
	const [regs, meta] = await Promise.all([lerAgua(db, data, data), lerMeta(db)]);
	const total = regs.reduce((s, r) => s + r.ml, 0);
	return { data, total_ml: total, registros: regs.length, ...(situacaoMeta(total, meta) ?? {}) };
}
