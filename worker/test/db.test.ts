import { test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@libsql/client";
import { garantirTabelas, inserirMedicoes, lerAtividade, lerMedicoes, upsertAtividade } from "../src/db.ts";

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
