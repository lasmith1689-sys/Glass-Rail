// RailData's getToken replies, and the poll notes penn_board() reads them by.
// Runs under Node (node --test) and Deno (deno test).

import assert from "node:assert/strict";
import { test } from "node:test";
import { readTokenReply, type TokenReply, tokenNote } from "./token_reply.ts";

/** The note penn-poll records, or the token. */
function note(reply: TokenReply): string {
  return reply.kind === "token" ? `token ${reply.token}` : tokenNote(reply);
}

/** penn_board()'s checker state for a failed poll's note. */
function boardState(text: string): string {
  return text.startsWith("getToken refused") ? "login-refused" : "trouble";
}

test("17 October: RailData's own error is a failure at NJ Transit, not a refused login", () => {
  const reply = readTokenReply({ errorMessage: "Object reference not set to an instance of an object." });
  assert.deepEqual(reply, { kind: "failed", message: "Object reference not set to an instance of an object." });
  assert.equal(note(reply), "getToken failed: Object reference not set to an instance of an object.");
  assert.equal(boardState(note(reply)), "trouble");
  // Even alongside "Authenticated": "False": the error says what went wrong.
  const withFlag = readTokenReply({ Authenticated: "False", UserToken: "", errorMessage: "Object reference not set to an instance of an object." });
  assert.equal(withFlag.kind, "failed");
});

test("a token", () => {
  assert.deepEqual(readTokenReply({ Authenticated: "True", UserToken: "abc123" }), { kind: "token", token: "abc123" });
  assert.deepEqual(readTokenReply({ Authenticated: "true", UserToken: "abc123", errorMessage: "" }), { kind: "token", token: "abc123" });
  assert.deepEqual(readTokenReply({ Authenticated: true, UserToken: "abc123" }), { kind: "token", token: "abc123" });
  assert.deepEqual(readTokenReply({ Authenticated: " TRUE ", UserToken: " abc123 " }), { kind: "token", token: " abc123 " });
});

test("answers about the login are refusals", () => {
  for (const reply of [
    { Authenticated: "False", UserToken: "" }, // a bad password
    { Authenticated: "false" },
    { Authenticated: false },
    { errorMessage: "Missing user account." }, // an unknown user
    { Authenticated: "False", errorMessage: "Invalid password" },
    { errorMessage: "Not authorized" },
    { errorMessage: "Authentication failed" },
    { errorMessage: "Invalid credentials" },
  ]) {
    const read = readTokenReply(reply);
    assert.equal(read.kind, "refused", JSON.stringify(reply));
    assert.equal(boardState(note(read)), "login-refused", JSON.stringify(reply));
  }
  assert.equal(note(readTokenReply({ Authenticated: "False", UserToken: "" })), "getToken refused: not authenticated");
  assert.equal(note(readTokenReply({ errorMessage: "Missing user account." })), "getToken refused: Missing user account.");
});

test("the daily limit, whatever else the reply says", () => {
  const message = "Daily usage limit:10. Please try again tomorrow.";
  for (const reply of [{ errorMessage: message }, { Authenticated: "False", errorMessage: message }, { Authenticated: "True", UserToken: "x", errorMessage: message }]) {
    assert.deepEqual(readTokenReply(reply), { kind: "limit", message }, JSON.stringify(reply));
  }
  assert.equal(note(readTokenReply({ errorMessage: message })), `NJ Transit's daily token limit: ${message}`);
});

test("a reply that can't be read is a failure, never blamed on the login", () => {
  for (const reply of [
    null,
    undefined,
    "",
    "<html>Service Unavailable</html>",
    42,
    [],
    [{ Authenticated: "True", UserToken: "x" }],
    {},
    { Authenticated: "True" }, // no token
    { Authenticated: "True", UserToken: "" },
    { Authenticated: "True", UserToken: "   " },
    { Authenticated: "True", UserToken: 12345 },
    { Authenticated: "yes", UserToken: "x" },
    { Authenticated: 1, UserToken: "x" },
    { UserToken: "x" },
    { errorMessage: "   " },
    { errorMessage: 500 },
    { errorMessage: null, Authenticated: null },
  ]) {
    const read = readTokenReply(reply);
    assert.deepEqual(read, { kind: "failed", message: "unexpected reply" }, JSON.stringify(reply));
    assert.equal(boardState(note(read)), "trouble", JSON.stringify(reply));
  }
  assert.deepEqual(readTokenReply({ errorMessage: "Server is busy" }), { kind: "failed", message: "Server is busy" });
});

test("a note never repeats a token", () => {
  for (const reply of [
    { Authenticated: "False", UserToken: "SECRET-TOKEN" },
    { Authenticated: "yes", UserToken: "SECRET-TOKEN" },
    { UserToken: "SECRET-TOKEN" },
  ]) {
    const read = readTokenReply(reply);
    assert.notEqual(read.kind, "token");
    assert.ok(!note(read).includes("SECRET-TOKEN"), JSON.stringify(reply));
  }
});
