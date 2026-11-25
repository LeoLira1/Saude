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
	// Água ingerida (não confundir com agua_pct da balança, que é % de água corporal).
	`CREATE TABLE IF NOT EXISTS agua (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		data_hora TEXT NOT NULL,
		ml INTEGER NOT NULL CHECK (ml > 0 AND ml <= 5000),
		criado_em TEXT NOT NULL DEFAULT (datetime('now', '-3 hours'))
	)`,
	`CREATE INDEX IF NOT EXISTS idx_agua_data_hora ON agua(data_hora)`,
	// Configurações chave/valor (ex.: meta_agua_ml).
	`CREATE TABLE IF NOT EXISTS config (
		chave TEXT PRIMARY KEY,
		valor TEXT NOT NULL,
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
	"fc_repouso_estimada",
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
/**
 * Colunas acrescentadas depois da criação das tabelas. ALTER TABLE ADD COLUMN só roda se a coluna
 * ainda não existe: não altera nem apaga dado nenhum.
 */
export const COLUNAS_NOVAS: { tabela: string; coluna: string; tipo: string }[] = [
	// 1 = FC de repouso calculada pelo app (o Mi Fitness não mandou a dele); 0 = a do Health Connect.
	{ tabela: "atividade_diaria", coluna: "fc_repouso_estimada", tipo: "INTEGER" },
];

export async function migrarColunas(db: Client): Promise<string[]> {
	const feitas: string[] = [];
	for (const { tabela, coluna, tipo } of COLUNAS_NOVAS) {
		const rs = await db.execute(`PRAGMA table_info(${tabela})`);
		const existe = linhas<{ name: string }>(rs).some((c) => c.name === coluna);
		if (!existe) {
			await db.execute(`ALTER TABLE ${tabela} ADD COLUMN ${coluna} ${tipo}`);
			feitas.push(`${tabela}.${coluna}`);
		}
	}
	return feitas;
}

export async function garantirTabelas(db: Client): Promise<void> {
	if (!pronto) {
		pronto = db
			.batch(DDL, "write")
			.then(() => migrarColunas(db))
			.then(() => undefined);
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
export const MSG_REENVIO = "reenvio da balança (mesmo peso e impedância da medição anterior), descartada";

/** "AAAA-MM-DD HH:MM:SS" − N minutos, no mesmo formato. */
export function menosMinutos(medidoEm: string, minutos: number): string {
	const t = Date.parse(`${medidoEm.replace(" ", "T")}Z`) - minutos * 60_000;
	return new Date(t).toISOString().slice(0, 19).replace("T", " ");
}

/** Última medição da balança (não manual) antes de `medidoEm`: peso e impedância. */
const SQL_ANTERIOR_BALANCA = `SELECT peso, impedancia FROM medicoes
	WHERE origem <> 'manual' AND medido_em < ? ORDER BY medido_em DESC LIMIT 1`;

/**
 * Grava medições. Pula (sem erro):
 *  - a que tem o mesmo medido_em de outra já gravada (`duplicadas`);
 *  - a da balança com peso E impedância idênticos aos da medição da balança imediatamente anterior, a qualquer
 *    distância de tempo (`ignoradas`, MSG_REENVIO). Ao subir na balança, ela reenvia a pesagem anterior com o
 *    horário de agora, uns 10 s antes da pesagem nova; por isso o horário não serve para barrar;
 *  - a da balança com peso E impedância idênticos a outra dos 30 minutos anteriores (`ignoradas`, MSG_DUPLICADA).
 */
export async function inserirMedicoes(db: Client, itens: Medicao[]) {
	const cols = ["medido_em", ...COLUNAS_MEDICAO, "origem"];
	const marcadores = cols.map(() => "?").join(", ");
	const simples = `INSERT INTO medicoes (${cols.join(", ")}) VALUES (${marcadores})
		ON CONFLICT(medido_em) DO NOTHING RETURNING id, medido_em`;
	const comTrava = `INSERT INTO medicoes (${cols.join(", ")}) SELECT ${marcadores}
		WHERE NOT EXISTS (
			SELECT 1 FROM medicoes WHERE peso = ? AND impedancia IS ? AND medido_em >= ? AND medido_em < ?
		)
		AND NOT EXISTS (
			SELECT 1 FROM (${SQL_ANTERIOR_BALANCA}) u WHERE u.peso = ? AND u.impedancia = ?
		)
		ON CONFLICT(medido_em) DO NOTHING RETURNING id, medido_em`;
	// Em ordem de horário: dentro do mesmo envio, a primeira entra e as repetidas depois dela são barradas.
	const ordem = [...itens].sort((x, y) => (x.medido_em < y.medido_em ? -1 : 1));
	const stmts = ordem.map((m) => {
		const valores = cols.map((c) => ((m as Record<string, unknown>)[c] ?? null) as InValue);
		if (m.origem === "manual") return { sql: simples, args: valores };
		const peso = m.peso ?? null;
		const imp = m.impedancia ?? null;
		return {
			sql: comTrava,
			args: [...valores, peso, imp, menosMinutos(m.medido_em, JANELA_DUPLICADA_MIN), m.medido_em, m.medido_em, peso, imp],
		};
	});
	const res = await db.batch(stmts, "write");
	const inseridas = res.flatMap((r) => linhas<{ id: number; medido_em: string }>(r));
	const novas = new Set(inseridas.map((r) => r.medido_em));
	const fora = ordem.filter((m) => !novas.has(m.medido_em));
	// Das que não entraram: se o horário existe no banco, já estava gravada; se não, foi barrada por uma das travas.
	let existentes = new Set<string>();
	if (fora.length) {
		const rs = await db.execute({
			sql: `SELECT medido_em FROM medicoes WHERE medido_em IN (${fora.map(() => "?").join(", ")})`,
			args: fora.map((m) => m.medido_em),
		});
		existentes = new Set(linhas<{ medido_em: string }>(rs).map((r) => r.medido_em));
	}
	const ignoradas: { medido_em: string; resultado: string }[] = [];
	for (const m of fora.filter((x) => !existentes.has(x.medido_em))) {
		const ant = linhas<{ peso: number; impedancia: number | null }>(
			await db.execute({ sql: SQL_ANTERIOR_BALANCA, args: [m.medido_em] }),
		)[0];
		const reenvio = !!ant && ant.peso === m.peso && m.impedancia != null && ant.impedancia === m.impedancia;
		const resultado = reenvio ? MSG_REENVIO : MSG_DUPLICADA;
		console.log(`medição descartada: ${m.medido_em} ${m.peso} kg ${m.impedancia ?? "-"} Ω — ${resultado}`);
		ignoradas.push({ medido_em: m.medido_em, resultado });
	}
	return {
		inseridas,
		duplicadas: fora.filter((m) => existentes.has(m.medido_em)).map((m) => m.medido_em),
		ignoradas,
	};
}

/** Reenvio da balança: peso e impedância iguais aos da medição da balança imediatamente anterior. */
export function ehReenvio(m: Medicao, anterior: Medicao | null | undefined): boolean {
	if (!anterior || m.origem === "manual" || anterior.origem === "manual") return false;
	return m.peso === anterior.peso && m.impedancia != null && m.impedancia === anterior.impedancia;
}

/** Tira os reenvios (ver `ehReenvio`). `antes` = última medição da balança antes da lista, se houver. */
export function semReenvios(ms: Medicao[], antes?: Medicao | null): Medicao[] {
	let ant = antes && antes.origem !== "manual" ? antes : null;
	const r: Medicao[] = [];
	for (const m of ms) {
		if (m.origem === "manual") {
			r.push(m);
			continue;
		}
		if (!ehReenvio(m, ant)) r.push(m);
		ant = m;
	}
	return r;
}

/**
 * Reenvios já gravados, para limpar o histórico: medição da balança com peso e impedância iguais aos da anterior
 * e seguida de outra medição em até 60 segundos (a pesagem de verdade). Só leitura.
 */
export const SQL_REENVIOS_GRAVADOS = `
WITH b AS (
	SELECT id, medido_em, peso, impedancia,
		LAG(peso) OVER (ORDER BY medido_em) AS peso_ant,
		LAG(impedancia) OVER (ORDER BY medido_em) AS imp_ant,
		LAG(medido_em) OVER (ORDER BY medido_em) AS em_ant,
		LEAD(medido_em) OVER (ORDER BY medido_em) AS em_prox
	FROM medicoes WHERE origem <> 'manual'
)
SELECT id, medido_em, peso, impedancia, em_ant AS repete_a_de, em_prox AS seguida_de,
	CAST(ROUND((julianday(em_prox) - julianday(medido_em)) * 86400) AS INTEGER) AS segundos_ate_a_seguinte
FROM b
WHERE impedancia IS NOT NULL AND peso = peso_ant AND impedancia = imp_ant
	AND em_prox IS NOT NULL AND (julianday(em_prox) - julianday(medido_em)) * 86400 <= 60
ORDER BY medido_em`;

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

/** Medições do período, em ordem de horário, já sem os reenvios da balança (ver `semReenvios`). */
export async function lerMedicoes(db: Client, inicio: string, fim: string): Promise<Medicao[]> {
	const [rs, ant] = await db.batch(
		[
			{ sql: `SELECT * FROM medicoes WHERE medido_em >= ? AND medido_em < ? ORDER BY medido_em`, args: [inicio, proximoDia(fim)] },
			{ sql: `SELECT * FROM medicoes WHERE origem <> 'manual' AND medido_em < ? ORDER BY medido_em DESC LIMIT 1`, args: [inicio] },
		],
		"read",
	);
	return semReenvios(linhas<Medicao>(rs), linhas<Medicao>(ant)[0]);
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
