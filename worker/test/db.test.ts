import { test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@libsql/client";
import { DDL, garantirTabelas, inserirMedicoes, lerAtividade, lerMedicoes, menosMinutos, upsertAtividade } from "../src/db.ts";

test("tabelas, medição sem duplicar e upsert de atividade que não apaga campo", async () => {
	const db = createClient({ url: ":memory:" });
	await garantirTabelas(db as never);

	const m = { medido_em: "2026-11-22 07:15:03", peso: 80.2, impedancia: 500, gordura_pct: 21.3, origem: "balanca" };
	const r1 = await inserirMedicoes(db as never, [m, { ...m, medido_em: "2026-11-22 20:00:00", peso: 81 }]);
	assert.equal(r1.inseridas.length, 2);
	const r2 = await inserirMedicoes(db as never, [m]);
	assert.equal(r2.inseridas.length, 0);
	assert.deepEqual(r2.duplicadas, ["2026-11-22 07:15:03"]);

	const ms = await lerMedicoes(db as never, "2026-11-22", "2026-11-22");
	assert.equal(ms.length, 2);
	assert.equal(ms[0].peso, 80.2);
	assert.equal(ms[0].origem, "balanca");

	await upsertAtividade(db as never, [{ data: "2026-11-22", passos: 1000, sono_min: 420 }]);
	await upsertAtividade(db as never, [{ data: "2026-11-22", passos: 5000, sono_min: null }]);
	const at = await lerAtividade(db as never, "2026-11-01", "2026-11-30");
	assert.equal(at.length, 1);
	assert.equal(at[0].passos, 5000);
	assert.equal(at[0].sono_min, 420);
});

test("balança: peso e impedância idênticos nos 30 min anteriores = duplicada, ignorada", async () => {
	const db = createClient({ url: ":memory:" });
	await db.batch(DDL, "write"); // garantirTabelas guarda "já criei" por Worker; banco novo aqui
	const base = { peso: 86.15, impedancia: 622, origem: "balanca" };
	await inserirMedicoes(db as never, [{ ...base, medido_em: "2026-11-22 15:27:52" }]);

	// 11 min depois, idêntica: ignorada
	const r = await inserirMedicoes(db as never, [{ ...base, medido_em: "2026-11-22 15:38:33" }]);
	assert.equal(r.inseridas.length, 0);
	assert.deepEqual(r.ignoradas, [{ medido_em: "2026-11-22 15:38:33", resultado: "duplicada, ignorada" }]);
	assert.deepEqual(r.duplicadas, []);

	// Mesmo horário de uma já gravada: "duplicadas" (não "ignoradas")
	const r2 = await inserirMedicoes(db as never, [{ ...base, medido_em: "2026-11-22 15:27:52" }]);
	assert.deepEqual(r2.duplicadas, ["2026-11-22 15:27:52"]);
	assert.equal(r2.ignoradas.length, 0);

	// Impedância diferente, peso diferente ou mais de 30 min depois: grava
	const r3 = await inserirMedicoes(db as never, [
		{ ...base, impedancia: 621, medido_em: "2026-11-22 15:40:00" },
		{ ...base, peso: 86.2, medido_em: "2026-11-22 15:41:00" },
		{ ...base, medido_em: "2026-11-22 15:58:00" },
	]);
	assert.equal(r3.inseridas.length, 3);

	// No mesmo envio: a primeira entra, a repetida 5 min depois é barrada
	const r4 = await inserirMedicoes(db as never, [
		{ peso: 70, impedancia: 500, origem: "balanca", medido_em: "2026-11-23 07:05:00" },
		{ peso: 70, impedancia: 500, origem: "balanca", medido_em: "2026-11-23 07:00:00" },
	]);
	assert.deepEqual(r4.inseridas.map((x) => x.medido_em), ["2026-11-23 07:00:00"]);
	assert.equal(r4.ignoradas[0].medido_em, "2026-11-23 07:05:00");

	// Manual não passa por essa regra
	const r5 = await inserirMedicoes(db as never, [{ peso: 70, impedancia: 500, origem: "manual", medido_em: "2026-11-23 07:10:00" }]);
	assert.equal(r5.inseridas.length, 1);

	assert.equal(menosMinutos("2026-11-23 00:10:00", 30), "2026-11-22 23:40:00");
	assert.equal((await lerMedicoes(db as never, "2026-11-22", "2026-11-23")).length, 6); // 4 em 22/11 + 2 em 23/11
});
