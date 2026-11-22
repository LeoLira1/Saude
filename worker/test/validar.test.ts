import { test } from "node:test";
import assert from "node:assert/strict";
import { chaveConfere, lista, normalizarDataHora, validarAtividade, validarMedicao } from "../src/validar.ts";

test("data/hora normalizada", () => {
	assert.equal(normalizarDataHora("2026-11-22T07:15"), "2026-11-22 07:15:00");
	assert.equal(normalizarDataHora("2026-11-22 07:15:03"), "2026-11-22 07:15:03");
	assert.throws(() => normalizarDataHora("22/11/2026"));
});

test("medição válida, impedância arredondada, origem padrão balanca", () => {
	const m = validarMedicao({ medido_em: "2026-11-22 07:15:03", peso: 80.25, impedancia: 512.4, gordura_pct: "21,5" });
	assert.equal(m.origem, "balanca");
	assert.equal(m.impedancia, 512);
	assert.equal(m.gordura_pct, 21.5);
	assert.equal(m.visceral, null);
});

test("medição inválida", () => {
	assert.throws(() => validarMedicao({ medido_em: "2026-11-22 07:15", peso: 5 }), /peso fora/);
	assert.throws(() => validarMedicao({ medido_em: "2026-11-22 07:15" }), /peso é obrigatório/);
	assert.throws(() => validarMedicao({ medido_em: "2026-11-22 07:15", peso: 80, origem: "x" }), /origem/);
});

test("atividade", () => {
	const a = validarAtividade({ data: "2026-11-22", passos: 1234.6, sono_min: 420 });
	assert.equal(a.passos, 1235);
	assert.equal(a.fc_repouso, null);
	assert.throws(() => validarAtividade({ data: "2026-11-22", spo2_medio: 120 }));
	assert.throws(() => validarAtividade({ data: "22-11-2026" }));
});

test("lista aceita objeto, array ou envelope", () => {
	assert.equal(lista({ a: 1 }, "dias").length, 1);
	assert.equal(lista([1, 2], "dias").length, 2);
	assert.equal(lista({ dias: [1, 2, 3] }, "dias").length, 3);
});

test("chave", () => {
	assert.ok(chaveConfere("abc", "abc"));
	assert.ok(!chaveConfere("abd", "abc"));
	assert.ok(!chaveConfere("ab", "abc"));
	assert.ok(!chaveConfere(undefined, "abc"));
	assert.ok(!chaveConfere("abc", undefined));
});
