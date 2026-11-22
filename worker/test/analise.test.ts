import { test } from "node:test";
import assert from "node:assert/strict";
import {
	correlacionarSeries,
	forcaCorrelacao,
	hojeBRT,
	inicioSemana,
	lerMetrica,
	lerPeriodo,
	maisProxima,
	pearson,
	resumoSerie,
	resumoSono,
	serieDiaria,
} from "../src/analise.ts";

const AGORA = new Date("2026-11-22T12:00:00Z"); // 09:00 em Brasília

test("hoje no fuso de Brasília vira o dia só às 03:00 UTC", () => {
	assert.equal(hojeBRT(new Date("2026-11-22T02:59:00Z")), "2026-11-21");
	assert.equal(hojeBRT(new Date("2026-11-22T03:00:00Z")), "2026-11-22");
});

test("períodos", () => {
	assert.deepEqual(lerPeriodo(undefined, AGORA), { inicio: "2026-10-24", fim: "2026-11-22", rotulo: "últimos 30 dias" });
	assert.equal(lerPeriodo("7d", AGORA).inicio, "2026-11-16");
	assert.equal(lerPeriodo("7", AGORA).inicio, "2026-11-16");
	assert.equal(lerPeriodo("2 semanas", AGORA).inicio, "2026-11-09");
	assert.equal(lerPeriodo("3 meses", AGORA).inicio, somar("2026-11-22", -89));
	assert.equal(lerPeriodo("1 ano", AGORA).inicio, somar("2026-11-22", -364));
	assert.equal(lerPeriodo("ano", AGORA).inicio, somar("2026-11-22", -364));
	assert.equal(lerPeriodo("mês", AGORA).inicio, somar("2026-11-22", -29));
	assert.deepEqual(lerPeriodo("2026-02", AGORA), { inicio: "2026-02-01", fim: "2026-02-28", rotulo: "mês 2026-02" });
	assert.deepEqual(lerPeriodo("2026-03-01..2026-01-01", AGORA), {
		inicio: "2026-01-01",
		fim: "2026-03-01",
		rotulo: "2026-01-01 a 2026-03-01",
	});
	assert.equal(lerPeriodo("2026-01-01 a 2026-03", AGORA).fim, "2026-03-31");
	assert.equal(lerPeriodo("ontem", AGORA).inicio, "2026-11-21");
	assert.equal(lerPeriodo("tudo", AGORA).inicio, "1900-01-01");
	assert.throws(() => lerPeriodo("semana passada de março", AGORA));
});

function somar(d: string, n: number) {
	const x = new Date(`${d}T00:00:00Z`);
	x.setUTCDate(x.getUTCDate() + n);
	return x.toISOString().slice(0, 10);
}

test("métricas aceitam apelidos e acento", () => {
	assert.equal(lerMetrica("Gordura").chave, "gordura_pct");
	assert.equal(lerMetrica("músculo").chave, "musculo_kg");
	assert.equal(lerMetrica("sono").chave, "sono_min");
	assert.equal(lerMetrica("FC de repouso").chave, "fc_repouso");
	assert.throws(() => lerMetrica("altura"));
});

test("série diária faz média das medições do mesmo dia", () => {
	const s = serieDiaria(
		lerMetrica("peso"),
		[
			{ medido_em: "2026-11-01 07:00:00", peso: 80 },
			{ medido_em: "2026-11-01 20:00:00", peso: 81 },
			{ medido_em: "2026-11-02 07:00:00", peso: 79.5 },
		],
		[],
	);
	assert.deepEqual(s, [
		{ data: "2026-11-01", valor: 80.5 },
		{ data: "2026-11-02", valor: 79.5 },
	]);
});

test("resumo: tendência semanal de quem perde 0,1 kg/dia = -0,7 kg/semana", () => {
	const pts = Array.from({ length: 21 }, (_, i) => ({ data: somar("2026-11-02", i), valor: 90 - 0.1 * i }));
	const r = resumoSerie(lerMetrica("peso"), pts) as Record<string, unknown>;
	assert.equal(r.tendencia_por_semana, -0.7);
	assert.equal(r.tendencia, "caindo");
	assert.equal(r.minimo, 88);
	assert.equal(r.maximo, 90);
	assert.equal(r.variacao, -2);
	assert.equal((r.medias_semanais as unknown[]).length, 3); // 02/11/2026 é segunda-feira
	assert.equal(inicioSemana("2026-11-08"), "2026-11-02");
});

test("Pearson", () => {
	assert.equal(pearson([1, 2, 3, 4], [2, 4, 6, 8]), 1);
	assert.ok(Math.abs(pearson([1, 2, 3, 4], [8, 6, 4, 2])! + 1) < 1e-12);
	assert.equal(pearson([1, 2], [1, 2]), null);
	assert.equal(pearson([1, 1, 1], [1, 2, 3]), null);
	assert.match(forcaCorrelacao(-0.8), /muito forte, negativa/);
	assert.match(forcaCorrelacao(0.05), /nenhuma/);
});

test("correlação com defasagem compara D com D+N", () => {
	const a = [
		{ data: "2026-11-01", valor: 1 },
		{ data: "2026-11-02", valor: 2 },
		{ data: "2026-11-03", valor: 3 },
	];
	const b = [
		{ data: "2026-11-02", valor: 10 },
		{ data: "2026-11-03", valor: 20 },
		{ data: "2026-11-04", valor: 30 },
	];
	assert.equal(correlacionarSeries(a, b, 0).pares.length, 2);
	const r = correlacionarSeries(a, b, 1);
	assert.equal(r.pares.length, 3);
	assert.equal(r.r, 1);
	assert.equal(r.inclinacao, 10);
});

test("resumo do sono", () => {
	const r = resumoSono([
		{ data: "2026-11-01", sono_min: 420, sono_profundo_min: 84, sono_rem_min: 105, sono_leve_min: 231, acordado_min: 10 },
		{ data: "2026-11-02", sono_min: 300 },
		{ data: "2026-11-03", passos: 5000 },
	]);
	assert.equal(r.noites_com_dado, 2);
	assert.equal(r.media_total, "6h00");
	assert.equal(r.noites_abaixo_de_6h, 1);
	assert.equal(r.melhor_noite?.data, "2026-11-01");
	assert.equal(r.noites[0].profundo_pct, 20);
});

test("medição mais próxima respeita a tolerância", () => {
	const ms = [
		{ medido_em: "2026-11-01 07:00:00", peso: 80 },
		{ medido_em: "2026-11-10 07:00:00", peso: 79 },
	];
	assert.equal(maisProxima(ms, "2026-11-03")?.peso, 80);
	assert.equal(maisProxima(ms, "2026-11-06"), null);
});
