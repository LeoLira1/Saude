import { test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@libsql/client";
import { buscar, calcularItem, notaBusca, somar, somarPorDia } from "../src/nutricao.ts";
import { DDL } from "../src/db.ts";
import { calcularItens, cadastrarAlimento, garantirTaco, gravarRefeicao, nutricaoPorDia, TACO, todosAlimentos, totalDoDia } from "../src/refeicoes.ts";
import { lerMetrica, serieDiaria, correlacionarSeries } from "../src/analise.ts";

// Arroz, tipo 1, cozido (TACO 3): 128,26 kcal; 2,52 g prot; 28,06 g carbo; 0,23 g gord; 1,56 g fibra por 100 g
const ARROZ = { kcal: 128.26, proteina_g: 2.52, carbo_g: 28.06, gordura_g: 0.23, fibra_g: 1.56 };

test("cálculo por gramas: valor por 100 g × gramas ÷ 100", () => {
	assert.deepEqual(calcularItem(ARROZ, 100), ARROZ);
	assert.deepEqual(calcularItem(ARROZ, 150), { kcal: 192.39, proteina_g: 3.78, carbo_g: 42.09, gordura_g: 0.35, fibra_g: 2.34 });
	assert.deepEqual(calcularItem(ARROZ, 50), { kcal: 64.13, proteina_g: 1.26, carbo_g: 14.03, gordura_g: 0.12, fibra_g: 0.78 });
	assert.equal(calcularItem({ kcal: 100 }, 1).kcal, 1);
	assert.equal(calcularItem({ kcal: 100 }, 1234).kcal, 1234);
});

test("nutriente sem valor (NA na TACO) fica null, não zero", () => {
	const r = calcularItem({ kcal: 61, proteina_g: null }, 200);
	assert.equal(r.kcal, 122);
	assert.equal(r.proteina_g, null);
	assert.equal(r.fibra_g, null);
});

test("gramas inválidos dão erro", () => {
	assert.throws(() => calcularItem(ARROZ, 0));
	assert.throws(() => calcularItem(ARROZ, -10));
	assert.throws(() => calcularItem(ARROZ, Number.NaN));
});

test("soma da refeição e contagem de valores faltando", () => {
	const t = somar([
		{ kcal: 192.39, proteina_g: 3.78, carbo_g: 42.09, gordura_g: 0.35, fibra_g: 2.34 },
		{ kcal: 76.3, proteina_g: 4.8, carbo_g: 13.6, gordura_g: 0.5, fibra_g: 8.5 },
		{ kcal: 100, proteina_g: null },
	]);
	assert.equal(t.kcal, 368.69);
	assert.equal(t.proteina_g, 8.58);
	assert.equal(t.carbo_g, 55.69);
	assert.deepEqual(t.faltando, { proteina_g: 1, carbo_g: 1, gordura_g: 1, fibra_g: 1 });
	// sem erro de ponto flutuante acumulado
	assert.equal(somar([{ kcal: 0.1 }, { kcal: 0.2 }]).kcal, 0.3);
});

test("soma do dia junta todas as refeições da mesma data, separando dias", () => {
	const dias = somarPorDia([
		{ data_hora: "2026-11-22 07:30:00", kcal: 300, proteina_g: 20 },
		{ data_hora: "2026-11-22 12:30:00", kcal: 650.5, proteina_g: 40.25 },
		{ data_hora: "2026-11-22 23:59:00", kcal: 49.5, proteina_g: 0 },
		{ data_hora: "2026-11-23 00:01:00", kcal: 200, proteina_g: 10 },
	]);
	assert.equal(dias.length, 2);
	assert.equal(dias[0].data, "2026-11-22");
	assert.equal(dias[0].kcal, 1000);
	assert.equal(dias[0].proteina_g, 60.25);
	assert.equal(dias[1].data, "2026-11-23");
	assert.equal(dias[1].kcal, 200);
});

test("busca tolera acento, plural, ordem e erro de digitação", () => {
	const lista = TACO.map((a, i) => ({ ...a, id: i + 1 }));
	const nomes = (t: string, n = 3) => buscar(t, lista, n).map((a) => a.nome);
	assert.equal(nomes("arroz tipo 1 cozido")[0], "Arroz, tipo 1, cozido");
	assert.ok(nomes("feijao carioca cozido").includes("Feijão, carioca, cozido"));
	assert.ok(nomes("banana prata", 5).some((n) => n.startsWith("Banana, prata")));
	assert.ok(nomes("ovos cozidos", 5).some((n) => /^Ovo, de galinha, inteiro, cozido/.test(n)));
	assert.ok(nomes("frnago peito", 8).some((n) => n.startsWith("Frango, peito")), "erro de digitação");
	assert.ok(notaBusca("pão francês", "Pão, trigo, francês") > notaBusca("pão francês", "Pão, de queijo, cru"));
	assert.equal(buscar("xyzwq", lista).length, 0);
});

test("fluxo no banco: TACO, cadastrar, refeição com valores gravados e total do dia", async () => {
	const db = createClient({ url: ":memory:" }) as never as Parameters<typeof garantirTaco>[0];
	await (db as never as { batch: (s: string[], m: string) => Promise<unknown> }).batch(DDL, "write");
	await garantirTaco(db);
	const todos = await todosAlimentos(db);
	assert.equal(todos.filter((a) => a.fonte === "TACO").length, 597);

	const arroz = todos.find((a) => a.nome === "Arroz, tipo 1, cozido")!;
	const whey = await cadastrarAlimento(db, { nome: "Whey protein baunilha", kcal: 400, proteina_g: 80, carbo_g: 8, gordura_g: 6 });
	assert.equal(whey.criado, true);
	assert.equal((await cadastrarAlimento(db, { nome: "whey PROTEIN baunilha", kcal: 1 })).criado, false);

	const itens = await calcularItens(db, [
		{ alimento_id: arroz.id, gramas: 150 },
		{ alimento_id: whey.alimento.id, gramas: 30 },
		{ nome: "Molho caseiro", kcal: 50, gramas: 20 },
	]);
	assert.equal(itens[1].kcal, 120);
	assert.equal(itens[1].proteina_g, 24);
	assert.equal(itens[2].kcal, 10);
	assert.equal(itens[2].proteina_g, null);
	await assert.rejects(calcularItens(db, [{ nome: "sem valores", gramas: 10 }]), /kcal/);
	await assert.rejects(calcularItens(db, [{ alimento_id: 99999, gramas: 10 }]), /não existe/);

	await gravarRefeicao(db, { data_hora: "2026-11-22 12:30:00", tipo: "almoco" }, itens);
	await gravarRefeicao(db, { data_hora: "2026-11-22 20:00:00", tipo: "jantar" }, await calcularItens(db, [{ alimento_id: arroz.id, gramas: 100 }]));
	await gravarRefeicao(db, { data_hora: "2026-11-23 08:00:00", tipo: "cafe" }, await calcularItens(db, [{ alimento_id: whey.alimento.id, gramas: 25 }]));

	const kcalArroz150 = Math.round(arroz.kcal! * 1.5 * 100) / 100;
	const kcalArroz100 = Math.round(arroz.kcal! * 100) / 100;
	const dia = await totalDoDia(db, "2026-11-22");
	assert.equal(dia.refeicoes, 2);
	assert.equal(dia.kcal, Math.round((kcalArroz150 + 120 + 10 + kcalArroz100) * 100) / 100);

	// Os valores gravados não mudam se o alimento for editado depois.
	await (db as never as { execute: (s: string) => Promise<unknown> }).execute("UPDATE alimentos SET kcal = 999 WHERE nome = 'Whey protein baunilha'");
	assert.equal((await totalDoDia(db, "2026-11-23")).kcal, 100);

	// Série diária para as ferramentas (kcal do dia x peso do dia seguinte).
	const nut = await nutricaoPorDia(db, "2026-11-01", "2026-11-30");
	assert.deepEqual(nut.map((d) => d.data), ["2026-11-22", "2026-11-23"]);
	const kcal = serieDiaria(lerMetrica("kcal_consumidas"), [], [], nut);
	const peso = serieDiaria(lerMetrica("peso"), [
		{ medido_em: "2026-11-23 07:00:00", peso: 86.4 },
		{ medido_em: "2026-11-24 07:00:00", peso: 86.2 },
	], []);
	const c = correlacionarSeries(kcal, peso, 1);
	assert.deepEqual(c.pares.map((p) => p.data), ["2026-11-22", "2026-11-23"]);
	assert.equal(lerMetrica("carboidratos").chave, "carbo_g");
	assert.equal(lerMetrica("proteína_g").chave, "proteina_g");
});
