import { test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@libsql/client";
import { DDL, ehReenvio, garantirTabelas, MSG_DUPLICADA, MSG_REENVIO, semReenvios, SQL_REENVIOS_GRAVADOS, inserirMedicoes, lerAtividade, lerMedicoes, menosMinutos, upsertAtividade } from "../src/db.ts";

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

	// 11 min depois, idêntica à anterior: reenvio descartado
	const r = await inserirMedicoes(db as never, [{ ...base, medido_em: "2026-11-22 15:38:33" }]);
	assert.equal(r.inseridas.length, 0);
	assert.deepEqual(r.ignoradas, [{ medido_em: "2026-11-22 15:38:33", resultado: MSG_REENVIO }]);
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

test("migração: fc_repouso_estimada entra sem mexer nos dados de atividade_diaria", async () => {
	const { migrarColunas } = await import("../src/db.ts");
	const db = createClient({ url: ":memory:" });
	// Tabela antiga, sem a coluna nova, com um dia gravado.
	await db.execute(`CREATE TABLE atividade_diaria (data TEXT PRIMARY KEY, passos INTEGER, calorias REAL, fc_repouso REAL,
		fc_media REAL, sono_min REAL, sono_profundo_min REAL, sono_leve_min REAL, sono_rem_min REAL, acordado_min REAL,
		spo2_medio REAL, atualizado_em TEXT NOT NULL DEFAULT (datetime('now', '-3 hours')))`);
	await db.execute("INSERT INTO atividade_diaria (data, passos, fc_repouso) VALUES ('2026-11-21', 8000, 60)");
	assert.deepEqual(await migrarColunas(db as never), ["atividade_diaria.fc_repouso_estimada"]);
	assert.deepEqual(await migrarColunas(db as never), []); // segunda vez não faz nada
	const antes = (await lerAtividade(db as never, "2026-11-01", "2026-11-30"))[0];
	assert.equal(antes.passos, 8000);
	assert.equal(antes.fc_repouso, 60);
	assert.equal(antes.fc_repouso_estimada, null);

	await upsertAtividade(db as never, [{ data: "2026-11-21", fc_repouso: 57, fc_repouso_estimada: 1 }]);
	await upsertAtividade(db as never, [{ data: "2026-11-21", passos: 9000 }]); // sem FC: mantém a anterior
	const d = (await lerAtividade(db as never, "2026-11-21", "2026-11-21"))[0];
	assert.equal(d.passos, 9000);
	assert.equal(d.fc_repouso, 57);
	assert.equal(d.fc_repouso_estimada, 1);
	// A real chega depois: troca o valor e desmarca a estimativa.
	await upsertAtividade(db as never, [{ data: "2026-11-21", fc_repouso: 59, fc_repouso_estimada: 0 }]);
	const e = (await lerAtividade(db as never, "2026-11-21", "2026-11-21"))[0];
	assert.equal(e.fc_repouso, 59);
	assert.equal(e.fc_repouso_estimada, 0);
});

// Histórico real (Turso, 22 a 25/11/2026): peso, impedância e horário de cada medição da balança.
const REAIS: [number, string, number, number][] = [
	[1, "2026-11-22 13:36:46", 86.35, 577],
	[2, "2026-11-22 13:37:01", 86.25, 577],
	[3, "2026-11-22 15:27:52", 86.15, 622],
	[5, "2026-11-22 15:52:29", 86.35, 592],
	[6, "2026-11-22 15:56:08", 86.45, 593],
	[7, "2026-11-22 16:33:13", 86.45, 616],
	[8, "2026-11-22 16:56:20", 87.1, 590],
	[9, "2026-11-22 22:08:10", 87.2, 619],
	[10, "2026-11-23 06:04:17", 87.2, 619], // reenvio da de 22/11 22:08
	[11, "2026-11-23 06:04:26", 86.7, 615],
	[12, "2026-11-23 17:49:28", 86.7, 615], // reenvio da de 06:04
	[13, "2026-11-23 17:49:38", 86.55, 549],
	[14, "2026-11-23 21:18:47", 86.55, 549], // reenvio da de 17:49
	[15, "2026-11-23 21:18:56", 87.3, 572],
	[16, "2026-11-23 21:39:25", 87.5, 564],
	[17, "2026-11-24 06:05:55", 87.5, 564], // reenvio da de 21:39
	[18, "2026-11-24 06:06:05", 86.5, 600],
	[21, "2026-11-24 06:20:31", 86.95, 594],
	[22, "2026-11-24 11:55:43", 86.1, 549],
	[23, "2026-11-25 06:14:41", 86.75, 608],
];
const REENVIOS = ["2026-11-23 06:04:17", "2026-11-23 17:49:28", "2026-11-23 21:18:47", "2026-11-24 06:05:55"];

test("trava: reenvio igual à última gravada é descartado, mesmo horas depois; a pesagem real 10 s depois entra", async () => {
	const db = createClient({ url: ":memory:" });
	await db.batch(DDL, "write");
	const ign: string[] = [];
	// Uma por vez, como o app manda ao subir na balança.
	for (const [, medido_em, peso, impedancia] of REAIS) {
		const r = await inserirMedicoes(db as never, [{ medido_em, peso, impedancia, origem: "balanca" }]);
		for (const x of r.ignoradas) {
			assert.equal(x.resultado, MSG_REENVIO);
			ign.push(x.medido_em);
		}
	}
	assert.deepEqual(ign, REENVIOS);
	const rs = await db.execute("SELECT medido_em FROM medicoes ORDER BY medido_em");
	assert.equal(rs.rows.length, REAIS.length - 4);

	// Manual com o mesmo peso não é barrada; medição sem impedância não cai na trava de reenvio.
	const r = await inserirMedicoes(db as never, [{ medido_em: "2026-11-25 07:00:00", peso: 86.75, origem: "manual" }]);
	assert.equal(r.inseridas.length, 1);
	assert.equal(ehReenvio({ medido_em: "b", peso: 80, origem: "balanca" }, { medido_em: "a", peso: 80, origem: "balanca" }), false);
	assert.equal(MSG_DUPLICADA, "duplicada, ignorada");
});

test("histórico: consulta acha os 4 reenvios e a leitura (ver_medicoes/ver_evolucao/resumo_periodo) já não os conta", async () => {
	const db = createClient({ url: ":memory:" });
	await db.batch(DDL, "write");
	// Grava como está hoje no banco (sem trava).
	await db.batch(
		REAIS.map(([id, medido_em, peso, impedancia]) => ({
			sql: "INSERT INTO medicoes (id, medido_em, peso, impedancia, origem) VALUES (?, ?, ?, ?, 'balanca')",
			args: [id, medido_em, peso, impedancia],
		})),
		"write",
	);
	const achados = (await db.execute(SQL_REENVIOS_GRAVADOS)).rows.map((r) => ({
		id: Number(r.id),
		medido_em: r.medido_em,
		repete: r.repete_a_de,
		seg: Number(r.segundos_ate_a_seguinte),
	}));
	assert.deepEqual(achados, [
		{ id: 10, medido_em: "2026-11-23 06:04:17", repete: "2026-11-22 22:08:10", seg: 9 },
		{ id: 12, medido_em: "2026-11-23 17:49:28", repete: "2026-11-23 06:04:26", seg: 10 },
		{ id: 14, medido_em: "2026-11-23 21:18:47", repete: "2026-11-23 17:49:38", seg: 9 },
		{ id: 17, medido_em: "2026-11-24 06:05:55", repete: "2026-11-23 21:39:25", seg: 10 },
	]);

	// Leitura de um período que começa logo depois da medição repetida (23/11 06:04:17 repete 22/11).
	const ms = await lerMedicoes(db as never, "2026-11-23", "2026-11-24");
	assert.equal(ms.some((m) => REENVIOS.includes(m.medido_em)), false);
	assert.equal(ms.length, 7); // 11 gravadas em 23 e 24/11, menos os 4 reenvios
	assert.equal(semReenvios([]).length, 0);
});
