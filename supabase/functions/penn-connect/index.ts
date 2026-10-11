// Connects the track checker to NJ Transit from Glass Rail's Settings: the
// rider's RailData developer login, with a one-time setup code, in place of
// the dashboard's NJT_USERNAME / NJT_PASSWORD secrets (supabase/README.md).
//
// POST {"code", "username", "password"}. The setup code is checked first
// (penn_check_code: only its SHA-256 is kept, and eight wrong tries retire
// it), so nobody without one can spend the account's getToken allowance.
// Then RailData's getToken has to accept the login. Only then is it kept,
// encrypted in Vault, with the token it just earned, and the code retired
// (penn_finish_connect). The login goes nowhere but RailData and Vault, and
// is never logged.
//
// Replies 200 {"ok": true}, or {"ok": false, "reason"} with reason one of
// code, code-used, code-expired, code-locked, login, busy; 502 with
// unreachable when RailData or the database can't be reached.

import { createClient } from "npm:@supabase/supabase-js@2";

const RAILDATA = "https://raildata.njtransit.com/api/TrainData";
const DAY_MS = 24 * 60 * 60 * 1000;
const TOKENS_PER_DAY = 9; // getToken allows ten a day, shared with penn-poll

function secretKey(): string {
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (keys) {
    const parsed = JSON.parse(keys) as Record<string, string>;
    if (parsed.default) return parsed.default;
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}

const db = createClient(Deno.env.get("SUPABASE_URL")!, secretKey(), {
  auth: { persistSession: false },
});

const CODE_REASONS: Record<string, string> = {
  wrong: "code",
  none: "code",
  used: "code-used",
  expired: "code-expired",
  locked: "code-locked",
};

function answer(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

/** Counts this getToken against the day's allowance; false when it's spent. */
async function spendToken(): Promise<boolean> {
  const { data, error } = await db.from("penn_config").select("value").eq("key", "token_attempts").maybeSingle();
  if (error) throw new Error(error.message);
  const now = Date.now();
  const attempts = (JSON.parse(data?.value ?? "[]") as string[]).filter((at) => now - Date.parse(at) < DAY_MS);
  if (attempts.length >= TOKENS_PER_DAY) return false;
  attempts.push(new Date(now).toISOString());
  const { error: saveError } = await db.from("penn_config").upsert({
    key: "token_attempts",
    value: JSON.stringify(attempts),
    updated_at: new Date(now).toISOString(),
  });
  if (saveError) throw new Error(saveError.message);
  return true;
}

/**
 * RailData's getToken: the token for a login it accepts, or why not. A bad
 * password reads "Authenticated": "False", an unknown user "Missing user
 * account.", a spent allowance "Daily usage limit:10. ..."; any other
 * errorMessage is RailData's trouble, not the login's, and throws.
 */
async function getToken(username: string, password: string): Promise<{ token: string } | { reason: string }> {
  const form = new FormData();
  form.append("username", username);
  form.append("password", password);
  const response = await fetch(`${RAILDATA}/getToken`, {
    method: "POST",
    body: form,
    signal: AbortSignal.timeout(20_000),
  });
  const reply = JSON.parse(await response.text()) as Record<string, unknown> | null;
  const message = typeof reply?.errorMessage === "string" ? reply.errorMessage.toLowerCase() : "";
  if (message.includes("usage limit")) return { reason: "busy" };
  const token = reply?.UserToken;
  if (String(reply?.Authenticated ?? "").toLowerCase() === "true" && typeof token === "string" && token) {
    return { token };
  }
  if (message && !/user|account|password|credential|auth/.test(message)) throw new Error(message);
  return { reason: "login" };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("method not allowed", { status: 405 });
  let input: Record<string, unknown>;
  try {
    input = await request.json();
  } catch {
    return answer({ ok: false, reason: "bad-request" }, 400);
  }
  const code = typeof input?.code === "string" ? input.code : "";
  const username = typeof input?.username === "string" ? input.username.trim() : "";
  const password = typeof input?.password === "string" ? input.password : "";
  if (!code || !username || !password || code.length > 32 || username.length > 200 || password.length > 200) {
    return answer({ ok: false, reason: "bad-request" }, 400);
  }

  try {
    const { data: check, error } = await db.rpc("penn_check_code", { p_code: code });
    if (error) throw new Error(error.message);
    if (check !== "ok") return answer({ ok: false, reason: CODE_REASONS[check] ?? "code" });

    if (!(await spendToken())) return answer({ ok: false, reason: "busy" });
    const result = await getToken(username, password);
    if ("reason" in result) return answer({ ok: false, reason: result.reason });

    const { error: saveError } = await db.rpc("penn_finish_connect", {
      p_username: username,
      p_password: password,
      p_token: result.token,
    });
    if (saveError) throw new Error(saveError.message);
    return answer({ ok: true });
  } catch {
    return answer({ ok: false, reason: "unreachable" }, 502);
  }
});
