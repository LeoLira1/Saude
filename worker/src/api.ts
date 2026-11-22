import { Hono, type MiddlewareHandler } from "hono";
import { abrir, inserirMedicoes, lerAtividade, lerMedicoes, upsertAtividade } from "./db.ts";
import { hojeBRT } from "./analise.ts";
import { chaveConfere, ErroValidacao, lista, validarAtividade, validarMedicao } from "./validar.ts";

const MAX_ITENS = 500;

/** Endpoints do app Android. Protegidos pela chave APP_API_KEY (header Authorization: Bearer <chave> ou X-Api-Key). */
export const api = new Hono<{ Bindings: Env }>();

const chaveApp: MiddlewareHandler<{ Bindings: Env }> = async (c, next) => {
	const auth = c.req.header("authorization");
	const chave = auth?.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : c.req.header("x-api-key");
	if (!c.env.APP_API_KEY) return c.json({ erro: "APP_API_KEY não configurada no Worker" }, 500);
	if (!chaveConfere(chave, c.env.APP_API_KEY)) return c.json({ erro: "chave inválida" }, 401);
	await next();
};

api.onError((e, c) => {
	if (e instanceof ErroValidacao) return c.json({ erro: e.message }, 400);
	console.error(e);
	return c.json({ erro: e instanceof Error ? e.message : String(e) }, 500);
});

async function corpo(c: { req: { json: () => Promise<unknown> } }): Promise<unknown> {
	try {
		return await c.req.json();
	} catch {
		throw new ErroValidacao("corpo precisa ser JSON");
	}
}

api.post("/medicao", chaveApp, async (c) => {
	const itens = lista(await corpo(c), "medicoes");
	if (!itens.length || itens.length > MAX_ITENS) throw new ErroValidacao(`envie de 1 a ${MAX_ITENS} medições`);
	const medicoes = itens.map((m) => validarMedicao(m));
	const db = await abrir(c.env);
	const r = await inserirMedicoes(db, medicoes);
	return c.json({ ok: true, inseridas: r.inseridas.length, duplicadas: r.duplicadas.length, ids: r.inseridas });
});

api.post("/atividade", chaveApp, async (c) => {
	const itens = lista(await corpo(c), "dias");
	if (!itens.length || itens.length > MAX_ITENS) throw new ErroValidacao(`envie de 1 a ${MAX_ITENS} dias`);
	const dias = itens.map(validarAtividade);
	const db = await abrir(c.env);
	const r = await upsertAtividade(db, dias);
	return c.json({ ok: true, ...r });
});

/** Para o app recuperar o histórico (ex.: depois de reinstalar). */
api.get("/medicoes", chaveApp, async (c) => {
	const desde = c.req.query("desde") ?? "1900-01-01";
	const db = await abrir(c.env);
	return c.json({ medicoes: await lerMedicoes(db, desde, hojeBRT()) });
});

api.get("/atividade", chaveApp, async (c) => {
	const desde = c.req.query("desde") ?? "1900-01-01";
	const db = await abrir(c.env);
	return c.json({ dias: await lerAtividade(db, desde, hojeBRT()) });
});

api.get("/ping", chaveApp, (c) => c.json({ ok: true, hoje: hojeBRT() }));
