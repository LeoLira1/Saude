import { test } from "node:test";
import assert from "node:assert/strict";
import { casasDe, medicaoDoDia, medicoesSuspeitas, mediana, resumoSerie, lerMetrica } from "../src/analise.ts";

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
	assert.equal(medicaoDoDia([{ medido_em: "2026-11-10 07:00:00", peso: 80, impedancia: 500 }, { medido_em: "2026-11-10 08:00:00", peso: 80, impedancia: 503 }, { medido_em: "2026-11-10 09:00:00", peso: 80, impedancia: 503 }], "2026-11-10")!.media_do_dia.impedancia, 502);
	assert.equal(medicaoDoDia([{ medido_em: "2026-11-10 07:00:00", peso: 80, impedancia: 500 }, { medido_em: "2026-11-10 08:00:00", peso: 80, impedancia: 501 }, { medido_em: "2026-11-10 09:00:00", peso: 80, impedancia: 501 }], "2026-11-10")!.media_do_dia.impedancia, 500.7);
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

test("mediana", () => {
	assert.equal(mediana([3, 1, 2]), 2);
	assert.equal(mediana([4, 1, 3, 2]), 2.5);
	assert.equal(mediana([]), null);
});

test("suspeita: compara com a mediana do dia", () => {
	// Dia com 577, 577, 622 → mediana 577; só a de 622 (+45) é suspeita.
	const dia = [
		{ id: 1, medido_em: "2026-11-22 13:36:46", peso: 86.35, impedancia: 577 },
		{ id: 2, medido_em: "2026-11-22 13:37:01", peso: 86.25, impedancia: 577 },
		{ id: 3, medido_em: "2026-11-22 15:27:52", peso: 86.15, impedancia: 622 },
	];
	const s = medicoesSuspeitas(dia);
	assert.equal(s.length, 1);
	assert.equal(s[0].id, 3);
	assert.equal(s[0].referencia, "mediana do dia");
	assert.equal(s[0].impedancia_referencia, 577);
	assert.equal(s[0].diferenca_ohms, 45);
	assert.equal(s[0].medicoes_na_referencia, 3);

	// A PRIMEIRA do dia também pode ser a errada (antes só a posterior era marcada).
	const s2 = medicoesSuspeitas([
		{ id: 1, medido_em: "2026-11-23 07:00:00", peso: 86, impedancia: 640 },
		{ id: 2, medido_em: "2026-11-23 07:01:00", peso: 86, impedancia: 580 },
		{ id: 3, medido_em: "2026-11-23 07:02:00", peso: 86, impedancia: 582 },
	]);
	assert.deepEqual(s2.map((x) => x.id), [1]);
	assert.equal(s2[0].diferenca_ohms, 58);

	// Exatamente 30 Ω não é suspeita.
	assert.equal(
		medicoesSuspeitas([
			{ medido_em: "2026-11-01 07:00:00", peso: 80, impedancia: 500 },
			{ medido_em: "2026-11-01 08:00:00", peso: 80, impedancia: 500 },
			{ medido_em: "2026-11-01 09:00:00", peso: 80, impedancia: 530 },
		]).length,
		0,
	);
});

test("suspeita: única do dia compara com a mediana dos 7 dias anteriores", () => {
	const hist = [
		{ medido_em: "2026-11-10 07:00:00", peso: 80, impedancia: 500 },
		{ medido_em: "2026-11-12 07:00:00", peso: 80, impedancia: 505 },
		{ medido_em: "2026-11-14 07:00:00", peso: 80, impedancia: 510 },
		{ medido_em: "2026-11-01 07:00:00", peso: 80, impedancia: 900 }, // mais de 7 dias antes: fora
	];
	const alvo = [{ id: 9, medido_em: "2026-11-16 07:00:00", peso: 80, impedancia: 540 }];
	const s = medicoesSuspeitas(alvo, hist);
	assert.equal(s.length, 1);
	assert.equal(s[0].referencia, "mediana dos últimos 7 dias");
	assert.equal(s[0].impedancia_referencia, 505);
	assert.equal(s[0].diferenca_ohms, 35);
	assert.equal(s[0].medicoes_na_referencia, 3);
	// 535 fica a 30 Ω: não marca.
	assert.equal(medicoesSuspeitas([{ medido_em: "2026-11-16 07:00:00", peso: 80, impedancia: 535 }], hist).length, 0);
	// Sem nada nos 7 dias antes: não dá para avaliar.
	assert.equal(medicoesSuspeitas([{ medido_em: "2026-11-30 07:00:00", peso: 80, impedancia: 900 }], hist).length, 0);
});

test("impedância média sempre com 1 casa", () => {
	assert.equal(casasDe("impedancia"), 1);
	assert.equal(casasDe("peso"), 2);
	assert.equal(casasDe("passos"), 0);
	const r = resumoSerie(lerMetrica("impedancia"), [
		{ data: "2026-11-01", valor: 500 },
		{ data: "2026-11-02", valor: 501 },
		{ data: "2026-11-03", valor: 501 },
	]) as Record<string, unknown>;
	assert.equal(r.media, 500.7);
});
