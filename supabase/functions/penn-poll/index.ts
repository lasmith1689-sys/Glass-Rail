// Glass Rail's New York Penn track checker: one poll of NJ Transit's RailData
// API, run every minute by pg_cron (supabase/README.md).
//
// It asks RailData for New York Penn's departure board and the vehicle feed
// and hands both, exactly as sent, to penn_ingest() in Postgres, which does
// everything else. What lives here is the RailData session: the token is
// kept in penn_config and renewed as token_policy.ts says, in quiet hours
// and never at the cost of a read, whatever the cron does.
//
// The RailData developer login: the one connected from Glass Rail's Settings
// (penn-connect keeps it encrypted in Vault; penn_login() reads it), else the
// NJT_USERNAME and NJT_PASSWORD Edge Function secrets. Never in the repo or a
// log. Callers must send the poll secret from penn_config as x-poll-secret;
// anyone else gets a 403, so nobody else can spend the account's daily quota.

import { createClient } from "npm:@supabase/supabase-js@2";
import { DAY_MS, type Held, mayMint, type Need, poll } from "./token_policy.ts";

const RAILDATA = "https://raildata.njtransit.com/api/TrainData";

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

/** A poll that cannot run yet, such as before the credentials are set. */
class Waiting extends Error {}

async function setting(key: string): Promise<string | null> {
  const { data, error } = await db.from("penn_config").select("value").eq("key", key).maybeSingle();
  if (error) throw new Error(`penn_config: ${error.message}`);
  return data?.value ?? null;
}

async function remember(key: string, value: string): Promise<void> {
  const { error } = await db
    .from("penn_config")
    .upsert({ key, value, updated_at: new Date().toISOString() });
  if (error) throw new Error(`penn_config: ${error.message}`);
}

/** RailData takes multipart forms only, and reports errors with a 200. */
async function post(method: string, fields: Record<string, string>): Promise<unknown> {
  const form = new FormData();
  for (const [name, value] of Object.entries(fields)) form.append(name, value);
  const response = await fetch(`${RAILDATA}/${method}`, {
    method: "POST",
    body: form,
    signal: AbortSignal.timeout(20_000),
  });
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${method}: HTTP ${response.status}, not JSON`);
  }
}

function errorMessage(reply: unknown): string | null {
  if (reply && typeof reply === "object" && !Array.isArray(reply)) {
    const message = (reply as Record<string, unknown>).errorMessage;
    if (typeof message === "string" && message.trim()) return message.trim();
  }
  return null;
}

/** The login connected from the app, else the Edge Function secrets. */
async function login(): Promise<{ username: string; password: string } | null> {
  const { data, error } = await db.rpc("penn_login");
  if (error) throw new Error(`penn_login: ${error.message}`);
  if (typeof data?.username === "string" && typeof data?.password === "string") return data;
  const username = Deno.env.get("NJT_USERNAME");
  const password = Deno.env.get("NJT_PASSWORD");
  return username && password ? { username, password } : null;
}

/** The token kept in penn_config, if any. */
async function held(): Promise<Held | null> {
  const kept = await setting("raildata_token");
  try {
    const { value, at } = JSON.parse(kept ?? "null") ?? {};
    return typeof value === "string" ? { value, issuedAt: Date.parse(at) } : null;
  } catch {
    return null;
  }
}

/** A new token from getToken, if token_policy.ts allows one for `need`, kept in penn_config. */
async function mint(need: Need): Promise<string> {
  const account = await login();
  if (!account) throw new Waiting("no NJ Transit credentials yet");
  const { username, password } = account;

  const now = Date.now();
  const attempts = (JSON.parse((await setting("token_attempts")) ?? "[]") as string[])
    .filter((at) => now - Date.parse(at) < DAY_MS);
  if (!mayMint(attempts.map(Date.parse), now, need)) {
    throw new Waiting("waiting before asking NJ Transit for another token");
  }
  attempts.push(new Date(now).toISOString());
  await remember("token_attempts", JSON.stringify(attempts));

  const reply = (await post("getToken", { username, password })) as Record<string, unknown> | null;
  const issued = reply?.UserToken;
  if (/usage limit/i.test(errorMessage(reply) ?? "")) {
    throw new Waiting(`NJ Transit's daily token limit: ${errorMessage(reply)}`);
  }
  if (String(reply?.Authenticated ?? "").toLowerCase() !== "true" || typeof issued !== "string") {
    throw new Error(`getToken refused: ${errorMessage(reply) ?? "not authenticated"}`);
  }
  await remember("raildata_token", JSON.stringify({ value: issued, at: new Date(now).toISOString() }));
  return issued;
}

/** A token-bearing call; a token RailData calls invalid ("Invalid token.") is replaced once. */
async function call(
  method: string,
  fields: Record<string, string>,
  session: { token: string; fresh: () => Promise<string> },
) {
  let reply = await post(method, { ...fields, token: session.token });
  if (/invalid token/i.test(errorMessage(reply) ?? "")) {
    session.token = await session.fresh();
    reply = await post(method, { ...fields, token: session.token });
  }
  const message = errorMessage(reply);
  if (message) throw new Error(`${method}: ${message}`);
  return reply;
}

Deno.serve(async (request) => {
  const started = Date.now();
  const polledAt = new Date(Math.floor(started / 1000) * 1000).toISOString();
  const secret = await setting("poll_secret");
  if (!secret || request.headers.get("x-poll-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }
  try {
    const data = await poll(await held(), started, mint, async (token, fresh) => {
      // One after the other, so a replaced token serves both.
      const session = { token, fresh };
      const board = await call("getTrainSchedule19Rec", { station: "NY" }, session);
      const vehicles = await call("getVehicleData", {}, session);
      const { data, error } = await db.rpc("penn_ingest", {
        p_board: board,
        p_vehicles: vehicles,
        p_polled_at: polledAt,
        p_millis: Date.now() - started,
      });
      if (error) throw new Error(`penn_ingest: ${error.message}`);
      return data;
    });
    return Response.json({ ok: true, ...data });
  } catch (err) {
    const note = (err instanceof Error ? err.message : String(err)).slice(0, 300);
    await db.from("penn_polls").upsert({
      polled_at: polledAt,
      ok: false,
      millis: Date.now() - started,
      note,
    });
    return Response.json({ ok: false, note }, { status: err instanceof Waiting ? 200 : 502 });
  }
});
