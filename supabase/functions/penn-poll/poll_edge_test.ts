// One poll's edge cases: an empty feed, a token past its time or refused, and
// RailData refusing to answer. penn-poll/index.ts hands token_policy.ts's
// poll() its getToken (mint) and its RailData read; here both are fakes that
// answer the way index.ts's would, so each case checks what poll() and
// readTokenReply() do with it.
// Runs under Node (node --test) and Deno (deno test).

import assert from "node:assert/strict";
import { test } from "node:test";
import { type Held, LAST_USE_MS, type Need, poll, RENEW_BY_MS } from "./token_policy.ts";
import { readTokenReply, type TokenReply, tokenNote } from "./token_reply.ts";

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
/** 7:30 PM EDT on Monday, October 19, 2026: not a quiet hour. */
const NOW = Date.parse("2026-10-19T23:30:00Z");

/** A token issued `hours` before NOW. */
function heldFor(hours: number, value = "old"): Held {
  return { value, issuedAt: NOW - hours * HOUR_MS };
}

/** A getToken fake: records each need, then answers with `answer`. */
function minter(answer: (need: Need, calls: number) => Promise<string>) {
  const needs: Need[] = [];
  const mint = (need: Need) => {
    needs.push(need);
    return answer(need, needs.length);
  };
  return { needs, mint };
}

/** The note penn-poll records for a getToken reply, or the token. */
function note(reply: TokenReply): string {
  return reply.kind === "token" ? `token ${reply.token}` : tokenNote(reply);
}

/** What index.ts's mint throws for a getToken reply that brought no token. */
function mintError(reply: unknown): Error {
  const read = readTokenReply(reply);
  assert.notEqual(read.kind, "token");
  return new Error(note(read));
}

// Empty feed

test("an empty board and vehicle feed is handed on as sent, with no getToken call", async () => {
  const empty = { board: { STATION: { STATIONNAME: "New York", ITEMS: [] } }, vehicles: [] };
  const { needs, mint } = minter(async () => "new");
  const tokens: string[] = [];
  const result = await poll(heldFor(1), NOW, mint, async (token) => {
    tokens.push(token);
    return empty;
  });
  assert.deepEqual(result, empty);
  assert.deepEqual(tokens, ["old"]);
  assert.deepEqual(needs, []);
});

test("an empty feed still counts as an answer: a due renewal goes ahead after it", async () => {
  const { needs, mint } = minter(async () => "new");
  const result = await poll(heldFor(RENEW_BY_MS / HOUR_MS + 1), NOW, mint, async () => ({ board: {}, vehicles: [] }));
  assert.deepEqual(result, { board: {}, vehicles: [] });
  assert.deepEqual(needs, ["due"]);
});

test("an empty getToken reply is a failure at NJ Transit, never a refused login", () => {
  for (const reply of ["", {}, null, { Authenticated: "", UserToken: "", errorMessage: "" }]) {
    const read = readTokenReply(reply);
    assert.deepEqual(read, { kind: "failed", message: "unexpected reply" }, JSON.stringify(reply));
    assert.equal(note(read), "getToken failed: unexpected reply");
    assert.ok(!note(read).startsWith("getToken refused"));
  }
});

test("with no token in hand, an empty getToken reply fails the poll before any read", async () => {
  const { needs, mint } = minter(async () => {
    throw mintError({});
  });
  let reads = 0;
  await assert.rejects(
    poll(null, NOW, mint, async () => {
      reads++;
      return "board";
    }),
    { message: "getToken failed: unexpected reply" },
  );
  assert.equal(reads, 0);
  assert.deepEqual(needs, ["needed"]);
});

test("an empty getToken reply during a due renewal costs nothing: the read's result stands", async () => {
  const { needs, mint } = minter(async () => {
    throw mintError("");
  });
  const result = await poll(heldFor(21), NOW, mint, async (token) => `read with ${token}`);
  assert.equal(result, "read with old");
  assert.deepEqual(needs, ["due"]);
});

// Token expiry

test("a token 23 hours old is replaced before the read", async () => {
  const { needs, mint } = minter(async () => "new");
  const tokens: string[] = [];
  await poll(heldFor(LAST_USE_MS / HOUR_MS), NOW, mint, async (token) => {
    tokens.push(token);
  });
  assert.deepEqual(tokens, ["new"]);
  assert.deepEqual(needs, ["needed"]);
});

test("no token kept, or one whose issue time can't be read, is replaced before the read", async () => {
  for (const held of [null, { value: "old", issuedAt: Date.parse("not a date") }]) {
    const { needs, mint } = minter(async () => "new");
    const tokens: string[] = [];
    await poll(held, NOW, mint, async (token) => {
      tokens.push(token);
    });
    assert.deepEqual(tokens, ["new"], JSON.stringify(held));
    assert.deepEqual(needs, ["needed"], JSON.stringify(held));
  }
});

test("a token past its last use is still tried when getToken can't be asked", async () => {
  const { needs, mint } = minter(async () => {
    throw new Error("waiting before asking NJ Transit for another token");
  });
  const tokens: string[] = [];
  const result = await poll(heldFor(23.5), NOW, mint, async (token) => {
    tokens.push(token);
    return "board";
  });
  assert.equal(result, "board");
  assert.deepEqual(tokens, ["old"]);
  assert.deepEqual(needs, ["needed"]);
});

test("a token RailData calls invalid is replaced once, mid-read, and the renewal isn't repeated", async () => {
  // 21 hours old: due for renewal, which the replacement already is.
  const { needs, mint } = minter(async () => "new");
  const tokens: string[] = [];
  const result = await poll(heldFor(21), NOW, mint, async (token, fresh) => {
    tokens.push(token);
    // index.ts's call(): "Invalid token." brings one fresh token and a retry.
    const replaced = await fresh();
    tokens.push(replaced);
    return { board: "board", vehicles: "vehicles" };
  });
  assert.deepEqual(result, { board: "board", vehicles: "vehicles" });
  assert.deepEqual(tokens, ["old", "new"]);
  assert.deepEqual(needs, ["needed"]);
});

test("a refused login while replacing an invalid token fails the poll as a refused login", async () => {
  const { needs, mint } = minter(async () => {
    throw mintError({ Authenticated: "False", UserToken: "" });
  });
  await assert.rejects(
    poll(heldFor(2), NOW, mint, async (_token, fresh) => {
      await fresh();
      return "never";
    }),
    (err: Error) => {
      assert.equal(err.message, "getToken refused: not authenticated");
      return true;
    },
  );
  assert.deepEqual(needs, ["needed"]);
});

test("the daily token limit while replacing an invalid token fails the poll with the limit's note", async () => {
  const limit = "Daily usage limit:10. Please try again tomorrow.";
  const { mint } = minter(async () => {
    const read = readTokenReply({ errorMessage: limit });
    assert.equal(read.kind, "limit");
    throw new Error(note(read));
  });
  await assert.rejects(
    poll(heldFor(2), NOW, mint, async (_token, fresh) => fresh()),
    { message: `NJ Transit's daily token limit: ${limit}` },
  );
});

// RailData refusal

test("RailData refusing the read fails the poll with its error and spends no getToken call", async () => {
  for (const error of [
    "getTrainSchedule19Rec: HTTP 503, not JSON", // a non-2xx page, or a malformed body
    "getTrainSchedule19Rec: HTTP 200, not JSON", // a cut-off body
    "getVehicleData: Object reference not set to an instance of an object.", // an error payload
  ]) {
    // 21 hours old: a renewal is due, but only after a poll NJ Transit answered.
    const { needs, mint } = minter(async () => "new");
    await assert.rejects(
      poll(heldFor(21), NOW, mint, async () => {
        throw new Error(error);
      }),
      { message: error },
    );
    assert.deepEqual(needs, [], error);
  }
});

test("RailData refusing the read in a quiet hour spends no getToken call either", async () => {
  const quiet = Date.parse("2026-10-19T16:00:00Z"); // noon EDT
  const { needs, mint } = minter(async () => "new");
  await assert.rejects(
    poll({ value: "old", issuedAt: quiet - 4 * HOUR_MS }, quiet, mint, async () => {
      throw new Error("getTrainSchedule19Rec: HTTP 500, not JSON");
    }),
    { message: "getTrainSchedule19Rec: HTTP 500, not JSON" },
  );
  assert.deepEqual(needs, []);
});

test("RailData refusing the retry after a replaced token fails the poll with the retry's error", async () => {
  const { needs, mint } = minter(async () => "new");
  await assert.rejects(
    poll(heldFor(2), NOW, mint, async (_token, fresh) => {
      await fresh();
      throw new Error("getTrainSchedule19Rec: Invalid token.");
    }),
    { message: "getTrainSchedule19Rec: Invalid token." },
  );
  // Only the one replacement: no renewal on top.
  assert.deepEqual(needs, ["needed"]);
});

test("getToken's own error payload or malformed reply is never blamed on the login", () => {
  for (const reply of [
    { errorMessage: "Object reference not set to an instance of an object." },
    { errorMessage: "Server is busy" },
    "<html><body>502 Bad Gateway</body></html>",
    [],
    42,
  ]) {
    const read = readTokenReply(reply);
    assert.equal(read.kind, "failed", JSON.stringify(reply));
    assert.ok(note(read).startsWith("getToken failed: "), JSON.stringify(reply));
  }
});
