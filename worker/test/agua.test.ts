import { test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@libsql/client";
import {
	aguaDoDia,
	aguaPorId,
	apagarAgua,
	gravarMeta,
	lerAgua,
	lerMeta,
	registrarAgua,
	situacaoMeta,
	somarAguaPorDia,
	validarMeta,
	validarMl,
} from "../src/agua.ts";
import { DDL } from "../src/db.ts";

test("soma por dia e situação da meta", () => {
	const dias = somarAguaPorDia([
		{ data_hora: "2026-11-22 08:00:00", ml: 300 },
		{ data_hora: "2026-11-22 23:59:00", ml: 500 },
		{ data_hora: "2026-11-23 00:01:00", ml: 250 },
	]);
	assert.deepEqual(dias, [
		{ data: "2026-11-22", total_ml: 800, registros: 2 },
		{ data: "2026-11-23", total_ml: 250, registros: 1 },
	]);
	assert.equal(situacaoMeta(800, null), null);
	assert.deepEqual(situacaoMeta(800, 2000), { meta_ml: 2000, falta_ml: 1200, meta_batida: false, percentual: 40 });
	assert.deepEqual(situacaoMeta(2100, 2000), { meta_ml: 2000, falta_ml: 0, meta_batida: true, percentual: 105 });
});

test("validação de ml e meta", () => {
	assert.equal(validarMl(250), 250);
	assert.equal(validarMl(5000), 5000);
	assert.throws(() => validarMl(0), /1 a 5000/);
	assert.throws(() => validarMl(5001), /1 a 5000/);
	assert.throws(() => validarMl(250.5), /inteiro/);
	assert.equal(validarMeta(500), 500);
	assert.equal(validarMeta(8000), 8000);
	assert.throws(() => validarMeta(499), /500 a 8000/);
	assert.throws(() => validarMeta(8001), /500 a 8000/);
});

test("migração não mexe em dados existentes; registrar, ver, meta, apagar", async () => {
	const db = createClient({ url: ":memory:" });
	// Banco "antigo": só as tabelas de antes, com dados.
	await db.batch(DDL.filter((d) => !/\b(agua|config)\b/.test(d)), "write");
	await db.execute("INSERT INTO medicoes (medido_em, peso, agua_pct) VALUES ('2026-11-22 07:00:00', 86.4, 50.1)");
	await db.execute("INSERT INTO refeicoes (data_hora, tipo) VALUES ('2026-11-22 12:00:00', 'almoco')");
	// Migração (DDL completo, como o Worker roda).
	await db.batch(DDL, "write");
	await db.batch(DDL, "write"); // rodar de novo não faz nada
	const med = (await db.execute("SELECT peso, agua_pct FROM medicoes")).rows;
	assert.equal(med.length, 1);
	assert.equal(med[0].agua_pct, 50.1);
	assert.equal((await db.execute("SELECT COUNT(*) AS n FROM refeicoes")).rows[0].n, 1);

	const c = db as never as Parameters<typeof registrarAgua>[0];
	assert.equal(await lerMeta(c), null);
	const r1 = await registrarAgua(c, "2026-11-22 08:00:00", 300);
	await registrarAgua(c, "2026-11-22 15:00:00", 500);
	await registrarAgua(c, "2026-11-23 09:00:00", 250);
	await assert.rejects(registrarAgua(c, "2026-11-22 16:00:00", 0));

	// Sem meta: só o total, sem campos de meta.
	const semMeta = await aguaDoDia(c, "2026-11-22");
	assert.deepEqual(semMeta, { data: "2026-11-22", total_ml: 800, registros: 2 });

	assert.deepEqual(await gravarMeta(c, 2000), { anterior: null, atual: 2000 });
	assert.deepEqual(await gravarMeta(c, 2500), { anterior: 2000, atual: 2500 });
	await assert.rejects(gravarMeta(c, 100));
	assert.equal(await lerMeta(c), 2500);
	const comMeta = await aguaDoDia(c, "2026-11-22");
	assert.equal(comMeta.falta_ml, 1700);
	assert.equal(comMeta.meta_batida, false);

	assert.equal((await lerAgua(c, "2026-11-22", "2026-11-23")).length, 3);
	assert.deepEqual((await aguaPorId(c, r1.id))?.ml, 300);
	await apagarAgua(c, r1.id);
	assert.equal(await aguaPorId(c, r1.id), null);
	assert.equal((await aguaDoDia(c, "2026-11-22")).total_ml, 500);
	// A água não entra em refeições nem na balança.
	assert.equal((await db.execute("SELECT COUNT(*) AS n FROM refeicao_itens")).rows[0].n, 0);
	assert.equal((await db.execute("SELECT agua_pct FROM medicoes")).rows[0].agua_pct, 50.1);
});
