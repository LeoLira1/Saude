// Bindings do Worker. Nenhum valor fica aqui: os secrets são enviados pelo GitHub Actions
// (ou cadastrados no painel da Cloudflare: Settings → Variables and Secrets).
declare namespace Cloudflare {
	interface Env {
		OAUTH_KV: KVNamespace;
		GITHUB_CLIENT_ID: string;
		GITHUB_CLIENT_SECRET: string;
		COOKIE_ENCRYPTION_KEY: string;
		TURSO_DATABASE_URL: string;
		TURSO_AUTH_TOKEN: string;
		/** Chave que o app Android manda em Authorization: Bearer. */
		APP_API_KEY: string;
	}
}
interface Env extends Cloudflare.Env {}
