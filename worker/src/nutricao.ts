/**
 * Refeições: cálculo por gramas, soma do dia e busca de alimentos por nome parecido.
 * Funções puras (sem banco), testadas em test/nutricao.test.ts.
 */

export const NUTRIENTES = ["kcal", "proteina_g", "carbo_g", "gordura_g", "fibra_g"] as const;
export type Nutriente = (typeof NUTRIENTES)[number];

/** Valores por 100 g (null = não informado / "NA" na TACO). */
export type Por100g = Partial<Record<Nutriente, number | null>>;
export type Totais = Record<Nutriente, number>;

export const TIPOS_REFEICAO = ["cafe", "almoco", "lanche", "jantar", "outro"] as const;
export type TipoRefeicao = (typeof TIPOS_REFEICAO)[number];

function r2(v: number): number {
	return Math.round(v * 100) / 100;
}

/**
 * Valores do item = valor por 100 g × gramas ÷ 100, arredondado em 2 casas.
 * Nutriente sem valor na tabela fica null (não vira zero).
 */
export function calcularItem(por100: Por100g, gramas: number): Record<Nutriente, number | null> {
	if (!Number.isFinite(gramas) || gramas <= 0) throw new Error(`gramas deve ser maior que zero (recebi ${gramas})`);
	const r = {} as Record<Nutriente, number | null>;
	for (const n of NUTRIENTES) {
		const v = por100[n];
		r[n] = typeof v === "number" && Number.isFinite(v) ? r2((v * gramas) / 100) : null;
	}
	return r;
}

/** Soma de itens (null conta como 0; `faltando` diz quantos itens não tinham o nutriente). */
export function somar(itens: Partial<Record<Nutriente, number | null>>[]): Totais & { faltando: Partial<Record<Nutriente, number>> } {
	const t = { kcal: 0, proteina_g: 0, carbo_g: 0, gordura_g: 0, fibra_g: 0 } as Totais;
	const faltando: Partial<Record<Nutriente, number>> = {};
	for (const it of itens) {
		for (const n of NUTRIENTES) {
			const v = it[n];
			if (typeof v === "number" && Number.isFinite(v)) t[n] += v;
			else faltando[n] = (faltando[n] ?? 0) + 1;
		}
	}
	for (const n of NUTRIENTES) t[n] = r2(t[n]);
	return { ...t, faltando };
}

/** Totais por dia (data = "AAAA-MM-DD" do data_hora da refeição). */
export function somarPorDia(itens: (Partial<Record<Nutriente, number | null>> & { data_hora: string })[]) {
	const porDia = new Map<string, typeof itens>();
	for (const it of itens) {
		const d = it.data_hora.slice(0, 10);
		porDia.set(d, [...(porDia.get(d) ?? []), it]);
	}
	return [...porDia.entries()]
		.sort(([a], [b]) => (a < b ? -1 : 1))
		.map(([data, l]) => {
			const { faltando: _f, ...t } = somar(l);
			return { data, ...t };
		});
}

// ── Busca por nome parecido ─────────────────────────────────────────────────

export function normalizar(s: string): string {
	return s
		.toLowerCase()
		.normalize("NFD")
		.replace(/[̀-ͯ]/g, "")
		.replace(/[^a-z0-9]+/g, " ")
		.trim();
}

const VAZIAS = new Set(["de", "da", "do", "das", "dos", "com", "sem", "e", "em", "a", "o", "ao", "na", "no", "tipo"]);

/** Palavras significativas, sem plural simples (ovos → ovo, feijoes → feijoe). */
export function palavras(s: string): string[] {
	return normalizar(s)
		.split(" ")
		.filter((p) => p && !VAZIAS.has(p))
		.map((p) => (p.length > 3 && p.endsWith("s") ? p.slice(0, -1) : p));
}

/** Distância de edição contando troca de duas letras vizinhas como 1 erro ("frnago" → "frango"). */
export function levenshtein(a: string, b: string): number {
	if (a === b) return 0;
	if (!a.length) return b.length;
	if (!b.length) return a.length;
	const d: number[][] = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
	for (let j = 0; j <= b.length; j++) d[0][j] = j;
	for (let i = 1; i <= a.length; i++) {
		for (let j = 1; j <= b.length; j++) {
			const custo = a[i - 1] === b[j - 1] ? 0 : 1;
			d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + custo);
			if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
		}
	}
	return d[a.length][b.length];
}

function notaPalavra(q: string, alvo: string[]): number {
	let melhor = 0;
	for (const p of alvo) {
		let n = 0;
		if (p === q) n = 3;
		else if (p.startsWith(q) && q.length >= 3) n = 2.5;
		else if (p.includes(q) && q.length >= 4) n = 2;
		else {
			const d = levenshtein(q, p);
			if (q.length >= 4 && d === 1) n = 1.6;
			else if (q.length >= 7 && d === 2) n = 1.1;
		}
		if (n > melhor) melhor = n;
	}
	return melhor;
}

/**
 * Nota de 0 a 3+ de quanto `nome` parece com `texto`: cada palavra do texto é procurada no nome
 * (igual, começo, pedaço ou erro de digitação). Palavra não encontrada derruba a nota.
 */
export function notaBusca(texto: string, nome: string): number {
	const q = palavras(texto);
	const alvo = palavras(nome);
	if (!q.length || !alvo.length) return 0;
	let soma = 0;
	let achadas = 0;
	for (const p of q) {
		const n = notaPalavra(p, alvo);
		soma += n;
		if (n > 0) achadas++;
	}
	let nota = soma / q.length;
	if (achadas < q.length) nota *= achadas / q.length / 2; // faltou palavra: cai bastante
	if (alvo[0] === q[0]) nota += 0.4; // "arroz cozido" prefere "Arroz, ..." a "Bolo de arroz"
	nota -= Math.max(0, alvo.length - q.length) * 0.05; // nomes mais curtos primeiro em empate
	return Math.round(nota * 1000) / 1000;
}

export function buscar<T extends { nome: string }>(texto: string, lista: T[], limite = 15, minimo = 1.2) {
	return lista
		.map((a) => ({ ...a, nota: notaBusca(texto, a.nome) }))
		.filter((a) => a.nota >= minimo)
		.sort((x, y) => y.nota - x.nota || x.nome.localeCompare(y.nome))
		.slice(0, limite);
}
