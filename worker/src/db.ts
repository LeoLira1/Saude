import { createClient, type Client, type InValue } from "@libsql/client/web";

/** Tabelas do sistema de saúde. Criadas na primeira chamada (CREATE TABLE IF NOT EXISTS). */
export const DDL = [
	`CREATE TABLE IF NOT EXISTS medicoes (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		medido_em TEXT NOT NULL UNIQUE,
		peso REAL NOT NULL,
		impedancia INTEGER,
		imc REAL,
		gordura_pct REAL,
		agua_pct REAL,
		musculo_kg REAL,
		osso_kg REAL,
		visceral REAL,
		metabolismo_kcal REAL,
		proteina_pct REAL,
		origem TEXT NOT NULL DEFAULT 'balanca',
		criado_em TEXT NOT NULL DEFAULT (datetime('now', '-3 hours'))
	)`,
	`CREATE INDEX IF NOT EXISTS idx_medicoes_medido_em ON medicoes(medido_em)`,
	`CREATE TABLE IF NOT EXISTS atividade_diaria (
		data TEXT PRIMARY KEY,
		passos INTEGER,
		calorias REAL,
		fc_repouso REAL,
		fc_media REAL,
		sono_min REAL,
		sono_profundo_min REAL,
		sono_leve_min REAL,
		sono_rem_min REAL,
		acordado_min REAL,
		spo2_medio REAL,
		atualizado_em TEXT NOT NULL DEFAULT (datetime('now', '-3 hours'))
	)`,
];

export const COLUNAS_MEDICAO = [
	"peso",
	"impedancia",
	"imc",
	"gordura_pct",
	"agua_pct",
	"musculo_kg",
	"osso_kg",
	"visceral",
	"metabolismo_kcal",
	"proteina_pct",
] as const;

export const COLUNAS_ATIVIDADE = [
	"passos",
	"calorias",
	"fc_repouso",
	"fc_media",
	"sono_min",
	"sono_profundo_min",
	"sono_leve_min",
	"sono_rem_min",
	"acordado_min",
	"spo2_medio",
] as const;

export type Medicao = {
	id?: number;
	medido_em: string;
	origem?: string;
	criado_em?: string;
} & Partial<Record<(typeof COLUNAS_MEDICAO)[number], number | null>>;

export type Atividade = { data: string; atualizado_em?: string } & Partial<
	Record<(typeof COLUNAS_ATIVIDADE)[number], number | null>
>;

export type Env = {
	TURSO_DATABASE_URL: string;
	TURSO_AUTH_TOKEN: string;
};

let pronto: Promise<void> | null = null;

export function getClient(env: Env): Client {
	if (!env.TURSO_DATABASE_URL || !env.TURSO_AUTH_TOKEN) {
		throw new Error("TURSO_DATABASE_URL / TURSO_AUTH_TOKEN não configurados nos secrets do Worker.");
	}
	return createClient({ url: env.TURSO_DATABASE_URL, authToken: env.TURSO_AUTH_TOKEN });
}

/** Garante as tabelas (uma vez por instância do Worker). */
export async function garantirTabelas(db: Client): Promise<void> {
	if (!pronto) {
		pronto = db.batch(DDL, "write").then(() => undefined);
		pronto.catch(() => {
			pronto = null;
		});
	}
	return pronto;
}

export async function abrir(env: Env): Promise<Client> {
	const db = getClient(env);
	await garantirTabelas(db);
	return db;
}

/** Linhas do libSQL → objetos simples (números e textos). */
export function linhas<T = Record<string, unknown>>(rs: { rows: unknown[]; columns: string[] }): T[] {
	return rs.rows.map((r) => {
		const o: Record<string, unknown> = {};
		const row = r as Record<string, unknown>;
		for (const c of rs.columns) {
			const v = row[c];
			o[c] = typeof v === "bigint" ? Number(v) : v;
		}
		return o as T;
	});
}

export async function inserirMedicoes(db: Client, itens: Medicao[]) {
	const cols = ["medido_em", ...COLUNAS_MEDICAO, "origem"];
	const sql = `INSERT INTO medicoes (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})
		ON CONFLICT(medido_em) DO NOTHING RETURNING id, medido_em`;
	const stmts = itens.map((m) => ({
		sql,
		args: cols.map((c) => ((m as Record<string, unknown>)[c] ?? null) as InValue),
	}));
	const res = await db.batch(stmts, "write");
	const inseridas = res.flatMap((r) => linhas<{ id: number; medido_em: string }>(r));
	const novas = new Set(inseridas.map((r) => r.medido_em));
	return {
		inseridas,
		duplicadas: itens.filter((m) => !novas.has(m.medido_em)).map((m) => m.medido_em),
	};
}

export async function upsertAtividade(db: Client, dias: Atividade[]) {
	const cols = ["data", ...COLUNAS_ATIVIDADE];
	// Campo que vem vazio não apaga o que já estava salvo.
	const sets = COLUNAS_ATIVIDADE.map((c) => `${c} = COALESCE(excluded.${c}, atividade_diaria.${c})`).join(", ");
	const sql = `INSERT INTO atividade_diaria (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})
		ON CONFLICT(data) DO UPDATE SET ${sets}, atualizado_em = datetime('now', '-3 hours')`;
	await db.batch(
		dias.map((d) => ({ sql, args: cols.map((c) => ((d as Record<string, unknown>)[c] ?? null) as InValue) })),
		"write",
	);
	return { gravados: dias.length, datas: dias.map((d) => d.data) };
}

export async function lerMedicoes(db: Client, inicio: string, fim: string): Promise<Medicao[]> {
	const rs = await db.execute({
		sql: `SELECT * FROM medicoes WHERE medido_em >= ? AND medido_em < ? ORDER BY medido_em`,
		args: [inicio, proximoDia(fim)],
	});
	return linhas<Medicao>(rs);
}

export async function lerAtividade(db: Client, inicio: string, fim: string): Promise<Atividade[]> {
	const rs = await db.execute({
		sql: `SELECT * FROM atividade_diaria WHERE data >= ? AND data <= ? ORDER BY data`,
		args: [inicio, fim],
	});
	return linhas<Atividade>(rs);
}

export function proximoDia(data: string): string {
	const d = new Date(`${data.slice(0, 10)}T00:00:00Z`);
	d.setUTCDate(d.getUTCDate() + 1);
	return d.toISOString().slice(0, 10);
}
