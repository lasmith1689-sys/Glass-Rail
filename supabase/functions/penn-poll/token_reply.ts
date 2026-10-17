// What RailData's getToken answered, as penn-poll records it
// (penn-poll/index.ts). The note matters: penn_board() shows a poll note
// starting "getToken refused" as "login-refused", which tells the rider to
// look at their NJ Transit login, so only an answer about the login itself
// may read that way.
//
// Replies seen (penn-connect/index.ts): a token reads "Authenticated":
// "True" with a UserToken; a bad password "Authenticated": "False"; an
// unknown user "Missing user account."; a spent allowance "Daily usage
// limit:10. ...". Any other errorMessage is RailData's own trouble (on 17
// October 2026, "Object reference not set to an instance of an object."),
// and so is any reply this can't read: neither is the login's fault.

export type TokenReply =
  | { kind: "token"; token: string }
  | { kind: "limit"; message: string }
  | { kind: "refused"; message: string }
  | { kind: "failed"; message: string };

/** An errorMessage that is about the login, not RailData. */
const LOGIN_MESSAGE = /user|account|password|credential|auth|login/i;

function field(reply: Record<string, unknown>, name: string): string | null {
  const value = reply[name];
  if (typeof value === "boolean") return String(value);
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

/** Reads a getToken reply, whatever came back. Never repeats a token in a message. */
export function readTokenReply(reply: unknown): TokenReply {
  if (!reply || typeof reply !== "object" || Array.isArray(reply)) {
    return { kind: "failed", message: "unexpected reply" };
  }
  const answer = reply as Record<string, unknown>;
  const message = field(answer, "errorMessage");
  const authenticated = field(answer, "Authenticated")?.toLowerCase() ?? null;
  // The token itself goes on as sent; blank is no token.
  const token = typeof answer.UserToken === "string" && answer.UserToken.trim() ? answer.UserToken : null;

  if (message && /usage limit/i.test(message)) return { kind: "limit", message };
  if (authenticated === "true" && token) return { kind: "token", token };
  if (message) return LOGIN_MESSAGE.test(message) ? { kind: "refused", message } : { kind: "failed", message };
  if (authenticated === "false") return { kind: "refused", message: "not authenticated" };
  return { kind: "failed", message: "unexpected reply" };
}

/** The poll note for a reply that brought no token. */
export function tokenNote(reply: Exclude<TokenReply, { kind: "token" }>): string {
  switch (reply.kind) {
    case "limit":
      return `NJ Transit's daily token limit: ${reply.message}`;
    case "refused":
      return `getToken refused: ${reply.message}`;
    case "failed":
      return `getToken failed: ${reply.message}`;
  }
}
