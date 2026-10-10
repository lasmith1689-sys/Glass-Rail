// What Glass Rail reads: New York Penn's NJ Transit departures on the board
// now, each with the track the board posted or the checker's call and its
// probability, plus the checker's record (penn_board() in Postgres).
//
// Public and read-only: it serves what the board and the checker already
// say, so it needs no key, and it never calls NJ Transit itself.

import { createClient } from "npm:@supabase/supabase-js@2";

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

Deno.serve(async (request) => {
  if (request.method !== "GET") return new Response("method not allowed", { status: 405 });
  const { data, error } = await db.rpc("penn_board");
  if (error) return Response.json({ error: "unavailable" }, { status: 503 });
  return Response.json(data, { headers: { "Cache-Control": "public, max-age=15" } });
});
