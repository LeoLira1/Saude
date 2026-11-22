/**
 * Banco das refeições: tabela TACO (carga única), alimentos manuais, refeições e itens.
 * Os itens guardam os valores JÁ calculados: editar a tabela de alimentos não muda refeição antiga.
 */
import type { Client, InValue } from "@libsql/client/web";
import { linhas } from "./db.ts";
import { calcularItem, normalizar, NUTRIENTES, somar, somarPorDia, type Por100g, type TipoRefeicao } from "./nutricao.ts";
import taco from "./taco.json" with { type: "json" };

export type Alimento = {
	id: number;
	nome: string;
	categoria: string | null;
	fonte: "TACO" | "manual";
	taco_id: number | null;
} & Por100g;

type LinhaTaco = { taco_id: number; nome: string; categoria: string | null } & Por100g;
export const TACO = taco as LinhaTaco[];

let tacoCarregada: Promise<void> | null = null;

/** Carrega a TACO (597 alimentos) na primeira vez. Depois só confere a contagem uma vez por Worker. */
export function garantirTaco(db: Client): Promise<void> {
	if (!tacoCarregada) {
		tacoCarregada = (async () => {
			const rs = await db.execute("SELECT COUNT(*) AS n FROM alimentos WHERE fonte = 'TACO'");
			const n = Number(linhas<{ n: number }>(rs)[0]?.n ?? 0);
			if (n >= TACO.length) return;
			const sql = `INSERT INTO alimentos (nome, categoria, kcal, proteina_g, carbo_g, gordura_g, fibra_g, fonte, taco_id)
				VALUES (?, ?, ?, ?, ?, ?, ?, 'TACO', ?) ON CONFLICT(taco_id) DO NOTHING`;
			for (let i = 0; i < TACO.length; i += 100) {
				await db.batch(
					TACO.slice(i, i + 100).map((a) => ({
						sql,
						args: [a.nome, a.categoria, ...NUTRIENTES.map((k) => (a[k] ?? null) as InValue), a.taco_id],
					})),
					"write",
				);
			}
		})();
		tacoCarregada.catch(() => {
			tacoCarregada = null;
		});
	}
	return tacoCarregada;
}

export async function todosAlimentos(db: Client): Promise<Alimento[]> {
	return linhas<Alimento>(await db.execute("SELECT id, nome, categoria, kcal, proteina_g, carbo_g, gordura_g, fibra_g, fonte, taco_id FROM alimentos"));
}

export async function alimentoPorId(db: Client, id: number): Promise<Alimento | null> {
	const rs = await db.execute({ sql: "SELECT * FROM alimentos WHERE id = ?", args: [id] });
	return linhas<Alimento>(rs)[0] ?? null;
}

export async function cadastrarAlimento(db: Client, a: { nome: string; categoria?: string | null } & Por100g) {
	const nome = a.nome.trim().replace(/\s+/g, " ");
	const existentes = (await todosAlimentos(db)).filter((x) => normalizar(x.nome) === normalizar(nome));
	if (existentes.length) return { criado: false as const, alimento: existentes[0] };
	const rs = await db.execute({
		sql: `INSERT INTO alimentos (nome, categoria, kcal, proteina_g, carbo_g, gordura_g, fibra_g, fonte)
			VALUES (?, ?, ?, ?, ?, ?, ?, 'manual') RETURNING id`,
		args: [nome, a.categoria ?? null, ...NUTRIENTES.map((k) => (a[k] ?? null) as InValue)],
	});
	const id = Number(linhas<{ id: number }>(rs)[0].id);
	return { criado: true as const, alimento: (await alimentoPorId(db, id))! };
}

export type ItemPedido = { alimento_id?: number; nome?: string; gramas: number } & Por100g;
export type ItemCalculado = { alimento_id: number | null; nome: string; gramas: number; fonte: string; por_100g: Por100g } & Record<
	(typeof NUTRIENTES)[number],
	number | null
>;

/** Resolve cada item (alimento da tabela ou nome livre com valores) e calcula pelos gramas. */
export async function calcularItens(db: Client, itens: ItemPedido[]): Promise<ItemCalculado[]> {
	const r: ItemCalculado[] = [];
	for (const [i, it] of itens.entries()) {
		let por100: Por100g;
		let nome: string;
		let alimentoId: number | null = null;
		let fonte: string;
		if (it.alimento_id !== undefined) {
			const a = await alimentoPorId(db, it.alimento_id);
			if (!a) throw new Error(`Item ${i + 1}: alimento_id ${it.alimento_id} não existe. Use buscar_alimento.`);
			por100 = Object.fromEntries(NUTRIENTES.map((k) => [k, a[k] ?? null]));
			nome = a.nome;
			alimentoId = a.id;
			fonte = a.fonte;
		} else {
			if (!it.nome?.trim()) throw new Error(`Item ${i + 1}: informe alimento_id ou nome.`);
			if (typeof it.kcal !== "number") {
				throw new Error(`Item ${i + 1} ("${it.nome}"): sem alimento_id, informe os valores por 100 g (pelo menos kcal).`);
			}
			por100 = Object.fromEntries(NUTRIENTES.map((k) => [k, it[k] ?? null]));
			nome = it.nome.trim();
			fonte = "nome livre";
		}
		r.push({ alimento_id: alimentoId, nome, gramas: it.gramas, fonte, por_100g: por100, ...calcularItem(por100, it.gramas) });
	}
	return r;
}

export async function gravarRefeicao(
	db: Client,
	r: { data_hora: string; tipo: TipoRefeicao; observacao?: string | null },
	itens: ItemCalculado[],
): Promise<number> {
	// Um lote só (transação): a refeição e os itens entram juntos ou nada entra.
	const res = await db.batch(
		[
			{
				sql: "INSERT INTO refeicoes (data_hora, tipo, observacao) VALUES (?, ?, ?) RETURNING id",
				args: [r.data_hora, r.tipo, r.observacao ?? null],
			},
			...itens.map((it) => ({
				sql: `INSERT INTO refeicao_itens (refeicao_id, alimento_id, nome, gramas, kcal, proteina_g, carbo_g, gordura_g, fibra_g)
					VALUES ((SELECT MAX(id) FROM refeicoes), ?, ?, ?, ?, ?, ?, ?, ?)`,
				args: [it.alimento_id, it.nome, it.gramas, ...NUTRIENTES.map((k) => it[k] as InValue)],
			})),
		],
		"write",
	);
	return Number(linhas<{ id: number }>(res[0])[0].id);
}

export type LinhaItem = {
	id: number;
	refeicao_id: number;
	alimento_id: number | null;
	nome: string;
	gramas: number;
	data_hora: string;
	tipo: string;
	observacao: string | null;
} & Record<(typeof NUTRIENTES)[number], number | null>;

/** Itens das refeições com data entre inicio e fim (inclusive), já com data_hora e tipo da refeição. */
export async function lerItens(db: Client, inicio: string, fim: string): Promise<LinhaItem[]> {
	const rs = await db.execute({
		sql: `SELECT i.*, r.data_hora, r.tipo, r.observacao FROM refeicoes r
			LEFT JOIN refeicao_itens i ON i.refeicao_id = r.id
			WHERE substr(r.data_hora, 1, 10) BETWEEN ? AND ? ORDER BY r.data_hora, r.id, i.id`,
		args: [inicio, fim],
	});
	return linhas<LinhaItem>(rs).map((l) => ({ ...l, refeicao_id: l.refeicao_id ?? (l as unknown as { id: number }).id }));
}

export async function totalDoDia(db: Client, data: string) {
	const itens = (await lerItens(db, data, data)).filter((i) => i.nome);
	const { faltando, ...t } = somar(itens);
	const refeicoes = new Set(itens.map((i) => i.refeicao_id)).size;
	return { data, refeicoes, ...t, itens_sem_valor: Object.keys(faltando).length ? faltando : undefined };
}

/** Série diária de nutrição para ver_evolucao / resumo_periodo / correlacionar. Só dias com refeição registrada. */
export async function nutricaoPorDia(db: Client, inicio: string, fim: string) {
	const itens = (await lerItens(db, inicio, fim)).filter((i) => i.nome);
	return somarPorDia(itens).map((d) => ({
		data: d.data,
		kcal_consumidas: d.kcal,
		proteina_g: d.proteina_g,
		carbo_g: d.carbo_g,
		gordura_g: d.gordura_g,
		fibra_g: d.fibra_g,
	}));
}

export async function apagarRefeicao(db: Client, id: number) {
	await db.batch(
		[
			{ sql: "DELETE FROM refeicao_itens WHERE refeicao_id = ?", args: [id] },
			{ sql: "DELETE FROM refeicoes WHERE id = ?", args: [id] },
		],
		"write",
	);
}
