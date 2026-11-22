// Quem pode usar o MCP. Confere o login E o id numérico da conta do GitHub:
// o login pode ser trocado (e outra pessoa registrar o nome antigo), o id não.
export const LOGIN_PERMITIDO = "LeoLira1";
export const GITHUB_ID_PERMITIDO = 128235911;

export function usuarioPermitido(login: unknown, id: unknown): boolean {
	return (
		typeof login === "string" &&
		login.toLowerCase() === LOGIN_PERMITIDO.toLowerCase() &&
		Number(id) === GITHUB_ID_PERMITIDO
	);
}
