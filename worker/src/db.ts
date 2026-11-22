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
	`CREATE TABLE IF NOT EXISTS alimentos (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		nome TEXT NOT NULL,
		categoria TEXT,
		kcal REAL,
		proteina_g REAL,
		carbo_g REAL,
		gordura_g REAL,
		fibra_g REAL,
		fonte TEXT NOT NULL CHECK (fonte IN ('TACO', 'manual')),
		taco_id INTEGER UNIQUE,
		criado_em TEXT NOT NULL DEFAULT (datetime('now', '-3 hours'))
	)`,
	`CREATE TABLE IF NOT EXISTS refeicoes (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		data_hora TEXT NOT NULL,
		tipo TEXT NOT NULL CHECK (tipo IN ('cafe', 'almoco', 'lanche', 'jantar', 'outro')),
		observacao TEXT,
		criado_em TEXT NOT NULL DEFAULT (datetime('now', '-3 hours'))
	)`,
	`CREATE INDEX IF NOT EXISTS idx_refeicoes_data_hora ON refeicoes(data_hora)`,
	`CREATE TABLE IF NOT EXISTS refeicao_itens (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		refeicao_id INTEGER NOT NULL REFERENCES refeicoes(id) ON DELETE CASCADE,
		alimento_id INTEGER REFERENCES alimentos(id),
		nome TEXT NOT NULL,
		gramas REAL NOT NULL,
		kcal REAL,
		proteina_g REAL,
		carbo_g REAL,
		gordura_g REAL,
		fibra_g REAL
	)`,
	`CREATE INDEX IF NOT EXISTS idx_refeicao_itens_refeicao ON refeicao_itens(refeicao_id)`,
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

/** Janela em que uma medição da balança com peso e impedância idênticos é tratada como repetida. */
export const JANELA_DUPLICADA_MIN = 30;
export const MSG_DUPLICADA = "duplicada, ignorada";

/** "AAAA-MM-DD HH:MM:SS" − N minutos, no mesmo formato. */
export function menosMinutos(medidoEm: string, minutos: number): string {
	const t = Date.parse(`${medidoEm.replace(" ", "T")}Z`) - minutos * 60_000;
	return new Date(t).toISOString().slice(0, 19).replace("T", " ");
}

/**
 * Grava medições. Pula (sem erro):
 *  - a que tem o mesmo medido_em de outra já gravada (`duplicadas`);
 *  - a da balança com peso E impedância idênticos a outra dos 30 minutos anteriores (`ignoradas`, "duplicada, ignorada").
 *    A balança às vezes reenvia a mesma pesagem com outro horário.
 */
export async function inserirMedicoes(db: Client, itens: Medicao[]) {
	const cols = ["medido_em", ...COLUNAS_MEDICAO, "origem"];
	const marcadores = cols.map(() => "?").join(", ");
	const simples = `INSERT INTO medicoes (${cols.join(", ")}) VALUES (${marcadores})
		ON CONFLICT(medido_em) DO NOTHING RETURNING id, medido_em`;
	const comJanela = `INSERT INTO medicoes (${cols.join(", ")}) SELECT ${marcadores}
		WHERE NOT EXISTS (
			SELECT 1 FROM medicoes WHERE peso = ? AND impedancia IS ? AND medido_em >= ? AND medido_em < ?
		)
		ON CONFLICT(medido_em) DO NOTHING RETURNING id, medido_em`;
	// Em ordem de horário: dentro do mesmo envio, a primeira entra e as repetidas depois dela são barradas.
	const ordem = [...itens].sort((x, y) => (x.medido_em < y.medido_em ? -1 : 1));
	const stmts = ordem.map((m) => {
		const valores = cols.map((c) => ((m as Record<string, unknown>)[c] ?? null) as InValue);
		if (m.origem === "manual") return { sql: simples, args: valores };
		return {
			sql: comJanela,
			args: [...valores, m.peso ?? null, m.impedancia ?? null, menosMinutos(m.medido_em, JANELA_DUPLICADA_MIN), m.medido_em],
		};
	});
	const res = await db.batch(stmts, "write");
	const inseridas = res.flatMap((r) => linhas<{ id: number; medido_em: string }>(r));
	const novas = new Set(inseridas.map((r) => r.medido_em));
	const fora = ordem.filter((m) => !novas.has(m.medido_em)).map((m) => m.medido_em);
	// Das que não entraram: se o horário existe no banco, já estava gravada; se não, foi barrada pela janela de 30 min.
	let existentes = new Set<string>();
	if (fora.length) {
		const rs = await db.execute({
			sql: `SELECT medido_em FROM medicoes WHERE medido_em IN (${fora.map(() => "?").join(", ")})`,
			args: fora,
		});
		existentes = new Set(linhas<{ medido_em: string }>(rs).map((r) => r.medido_em));
	}
	return {
		inseridas,
		duplicadas: fora.filter((k) => existentes.has(k)),
		ignoradas: fora.filter((k) => !existentes.has(k)).map((medido_em) => ({ medido_em, resultado: MSG_DUPLICADA })),
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
