import { test } from "node:test";
import assert from "node:assert/strict";
import { medicaoDoDia, medicoesSuspeitas } from "../src/analise.ts";

const ms = [
	{ id: 1, medido_em: "2026-11-10 07:00:00", peso: 80, impedancia: 500, gordura_pct: 22 },
	{ id: 2, medido_em: "2026-11-10 20:00:00", peso: 81, impedancia: 510, gordura_pct: 23 },
	{ id: 3, medido_em: "2026-11-13 07:00:00", peso: 79, impedancia: 505, gordura_pct: 21 },
	{ id: 4, medido_em: "2026-11-13 07:02:00", peso: 79.2, impedancia: 560, gordura_pct: 25 },
];

test("usa a média do próprio dia", () => {
	const d = medicaoDoDia(ms, "2026-11-10")!;
	assert.equal(d.data_real_medicao, "2026-11-10");
	assert.equal(d.mesmo_dia, true);
	assert.equal(d.medicoes_no_dia, 2);
	assert.equal(d.media_do_dia.peso, 80.5);
	assert.equal(d.media_do_dia.gordura_pct, 22.5);
	assert.equal(d.media_do_dia.impedancia, 505);
	assert.deepEqual(d.horarios, ["07:00", "20:00"]);
});

test("sem medição no dia: busca até 3 dias e informa a data real (empate fica com o anterior)", () => {
	const d = medicaoDoDia(ms, "2026-11-11")!;
	assert.equal(d.data_real_medicao, "2026-11-10");
	assert.equal(d.mesmo_dia, false);
	assert.equal(d.distancia_dias, -1);
	assert.equal(medicaoDoDia(ms, "2026-11-12")!.data_real_medicao, "2026-11-13"); // 13 está a 1 dia, 10 a 2
	assert.equal(medicaoDoDia(ms, "2026-11-20"), null);
});

test("datas diferentes que caem no mesmo dia de medição", () => {
	assert.equal(medicaoDoDia(ms, "2026-11-09")!.data_real_medicao, medicaoDoDia(ms, "2026-11-10")!.data_real_medicao);
});

test("impedância suspeita: > 30 Ω vs. a anterior do mesmo dia", () => {
	const s = medicoesSuspeitas(ms);
	assert.equal(s.length, 1);
	assert.equal(s[0].id, 4);
	assert.equal(s[0].diferenca_ohms, 55);
	assert.equal(s[0].medido_em_anterior, "2026-11-13 07:00:00");
	// 30 exatos não é suspeito; dias diferentes não comparam
	assert.equal(
		medicoesSuspeitas([
			{ medido_em: "2026-11-01 07:00:00", peso: 80, impedancia: 500 },
			{ medido_em: "2026-11-01 08:00:00", peso: 80, impedancia: 530 },
			{ medido_em: "2026-11-02 07:00:00", peso: 80, impedancia: 600 },
		]).length,
		0,
	);
});
