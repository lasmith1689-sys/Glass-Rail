// The checker's RailData tokens, minute by minute over weeks of polls.
// Runs under Node (node --test) and Deno (deno test).

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DAY_MS,
  type Held,
  LAST_USE_MS,
  MINTS_PER_DAY,
  mayMint,
  type Need,
  poll,
  quietHour,
  renewal,
  spacing,
} from "./token_policy.ts";

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
const at = (iso: string) => Date.parse(iso);
/** The first real token: 11:04 AM on Sunday, October 11, 2026. */
const FIRST = at("2026-10-11T15:04:00Z");

function newYorkHour(ms: number): number {
  return Number(
    new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hour: "numeric", hourCycle: "h23" })
      .formatToParts(ms)
      .find((part) => part.type === "hour")?.value,
  );
}

/** Rush hours at New York Penn: 6 to 10 AM and 4 to 8 PM. */
function rush(ms: number): boolean {
  const hour = newYorkHour(ms);
  return (hour >= 6 && hour < 10) || (hour >= 16 && hour < 20);
}

/**
 * Polls once a minute for `days` from FIRST, holding the token issued then.
 * NJ Transit answers getToken when `tokens(now)` and the data calls when
 * `data(now)`, and refuses a token 24 hours old, as penn-poll's read does.
 */
async function simulate(days: number, tokens: (now: number) => boolean, data: (now: number) => boolean = () => true) {
  let held: Held = { value: "first", issuedAt: FIRST };
  const issued = new Map([["first", FIRST]]);
  const attempts: number[] = [];
  const renewals: number[] = [];
  const failed: number[] = [];
  let oldest = 0;
  for (let now = FIRST; now < FIRST + days * DAY_MS; now += MINUTE_MS) {
    const mint = async (need: Need) => {
      if (!mayMint(attempts, now, need, held.issuedAt)) throw new Error("waiting");
      attempts.push(now);
      if (!tokens(now)) throw new Error("getToken failed");
      held = { value: `t${now}`, issuedAt: now };
      issued.set(held.value, now);
      renewals.push(now);
      return held.value;
    };
    try {
      await poll(held, now, mint, async (token, fresh) => {
        if (!data(now)) throw new Error("RailData down");
        if (now - issued.get(token)! >= DAY_MS) token = await fresh();
        oldest = Math.max(oldest, now - issued.get(token)!);
      });
    } catch {
      failed.push(now);
    }
  }
  const busiestDay = Math.max(0, ...attempts.map((a) => attempts.filter((b) => b >= a && b - a < DAY_MS).length));
  return { attempts, renewals, failed, oldest, busiestDay };
}

test("quiet hours are New York's 2 to 5 AM and 11 AM to 2 PM, in summer time and winter time", () => {
  assert.equal(quietHour(at("2026-10-12T05:59:00Z")), false); // 1:59 AM EDT
  assert.equal(quietHour(at("2026-10-12T06:00:00Z")), true); // 2:00 AM EDT
  assert.equal(quietHour(at("2026-10-12T08:59:00Z")), true); // 4:59 AM EDT
  assert.equal(quietHour(at("2026-10-12T09:00:00Z")), false); // 5:00 AM EDT
  assert.equal(quietHour(at("2026-10-12T15:00:00Z")), true); // 11:00 AM EDT
  assert.equal(quietHour(at("2026-10-12T18:00:00Z")), false); // 2:00 PM EDT
  assert.equal(quietHour(at("2026-10-12T22:30:00Z")), false); // 6:30 PM EDT
  assert.equal(quietHour(at("2026-12-14T06:00:00Z")), false); // 1:00 AM EST
  assert.equal(quietHour(at("2026-12-14T07:00:00Z")), true); // 2:00 AM EST
});

test("a token is renewed in a quiet hour from 3 hours old, by 20 hours, and polled with until 23", () => {
  assert.equal(renewal(FIRST, FIRST + 4 * HOUR_MS), "none"); // 3:04 PM
  assert.equal(renewal(FIRST, at("2026-10-11T22:30:00Z")), "none"); // 6:30 PM, 7.5 hours on
  assert.equal(renewal(FIRST, at("2026-10-12T06:00:00Z")), "quiet"); // 2 AM, 15 hours on
  assert.equal(renewal(at("2026-10-12T05:00:00Z"), at("2026-10-12T06:30:00Z")), "none"); // 2:30 AM, 1.5 hours on
  assert.equal(renewal(FIRST, FIRST + 20 * HOUR_MS), "due");
  assert.equal(renewal(FIRST, FIRST + LAST_USE_MS), "needed");
  assert.equal(renewal(null, FIRST), "needed");
  assert.equal(renewal(Number.NaN, FIRST), "needed");
});

test("getToken calls back off from 30 minutes to 4 hours and stop at the day's allowance", () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5].map((n) => spacing(n) / MINUTE_MS), [0, 30, 60, 120, 240, 240]);
  const now = FIRST;
  const ago = (...hours: number[]) => hours.map((h) => now - h * HOUR_MS);
  assert.equal(mayMint([], now, "needed"), true);
  assert.equal(mayMint([now - 29 * MINUTE_MS], now, "needed"), false);
  assert.equal(mayMint([now - 30 * MINUTE_MS], now, "needed"), true);
  assert.equal(mayMint(ago(3, 59 / 60), now, "due"), false);
  assert.equal(mayMint(ago(23, 22, 21, 20, 4), now, "due"), true);
  assert.equal(mayMint(ago(23, 22, 21, 20, 5, 4), now, "needed"), false);
  assert.equal(mayMint(ago(30, 29, 28, 27, 26, 25), now, "needed"), true);
  assert.equal(mayMint([now + MINUTE_MS], now, "needed"), false);
});

test("a quiet renewal is one getToken call per quiet spell, with the day's calls to spare", () => {
  const now = FIRST;
  const ago = (...hours: number[]) => hours.map((h) => now - h * HOUR_MS);
  assert.equal(mayMint(ago(2), now, "quiet"), false);
  assert.equal(mayMint(ago(3), now, "quiet"), true);
  assert.equal(mayMint(ago(9, 8, 7), now, "quiet"), true);
  assert.equal(mayMint(ago(10, 9, 8, 7), now, "quiet"), false);
  assert.equal(mayMint(ago(10, 9, 8, 7), now, "due"), true);
});

test("a renewal waits for NJ Transit to answer, and failing costs no reads", async () => {
  const held = { value: "old", issuedAt: FIRST };
  const later = FIRST + 21 * HOUR_MS;
  const calls: Need[] = [];
  const mint = (need: Need) => {
    calls.push(need);
    return Promise.reject(new Error("getToken failed"));
  };
  // RailData down: no getToken call is spent.
  await assert.rejects(poll(held, later, mint, () => Promise.reject(new Error("down"))), /down/);
  assert.deepEqual(calls, []);
  // RailData up: the poll reads with the old token, then tries to renew it.
  assert.equal(await poll(held, later, mint, async (token) => token), "old");
  assert.deepEqual(calls, ["due"]);
});

test("a token past its last use is renewed first, and still tried when getToken can't be asked", async () => {
  const held = { value: "old", issuedAt: FIRST };
  const late = FIRST + LAST_USE_MS;
  assert.equal(await poll(held, late, () => Promise.resolve("new"), async (token) => token), "new");
  assert.equal(await poll(held, late, () => Promise.reject(new Error("waiting")), async (token) => token), "old");
  await assert.rejects(poll(null, late, () => Promise.reject(new Error("no login")), async (t) => t), /no login/);
});

test("a month of polls: two renewals a day in quiet hours, none in a rush, no poll lost", async () => {
  // Past the end of summer time on November 1.
  const run = await simulate(30, () => true);
  assert.deepEqual(run.failed, []);
  assert.ok(run.renewals.length >= 58 && run.renewals.length <= 61, `${run.renewals.length} renewals`);
  for (const renewed of run.renewals) assert.ok(quietHour(renewed), new Date(renewed).toISOString());
  // 15 hours from 11 AM to 2 AM; 16 the night the clocks go back.
  assert.ok(run.oldest <= 16 * HOUR_MS, `oldest token polled with: ${run.oldest / HOUR_MS} hours`);
  assert.ok(run.busiestDay <= 3, `${run.busiestDay} getToken calls in 24 hours`);
});

test("getToken down every night: renewed after the morning's first reads instead, no poll lost", async () => {
  const run = await simulate(14, (now) => newYorkHour(now) >= 6);
  assert.deepEqual(run.failed, []);
  // The 2 AM renewal fails, so the 20-hour one comes in the morning rush,
  // after that minute's reads; the 11 AM one puts it back.
  assert.ok(run.renewals.filter(rush).length <= 14, `${run.renewals.filter(rush).length} renewals in a rush`);
  assert.ok(run.busiestDay <= MINTS_PER_DAY, `${run.busiestDay} getToken calls in 24 hours`);
});

test("all of RailData down for 30 hours: no getToken call spent until the token runs out, back within 4 hours", async () => {
  const up = (now: number) => now < FIRST + 2 * HOUR_MS || now >= FIRST + 32 * HOUR_MS;
  const run = await simulate(4, up, up);
  assert.ok(run.attempts.every((a) => a >= FIRST + LAST_USE_MS), "a call before the token ran out");
  assert.ok(run.busiestDay <= MINTS_PER_DAY, `${run.busiestDay} getToken calls in 24 hours`);
  const lost = run.failed.filter(up);
  assert.ok(lost.length <= 4 * 60, `${lost.length} polls lost after NJ Transit came back`);
});

test("getToken down for a day while the board answers: reads carry on to 23 hours, back within 4 hours", async () => {
  const up = (now: number) => now < FIRST + 2 * HOUR_MS || now >= FIRST + 26 * HOUR_MS;
  const run = await simulate(4, up);
  assert.ok(run.failed[0] >= FIRST + LAST_USE_MS, new Date(run.failed[0]).toISOString());
  assert.ok(run.busiestDay <= MINTS_PER_DAY, `${run.busiestDay} getToken calls in 24 hours`);
  const lost = run.failed.filter(up);
  assert.ok(lost.length <= 4 * 60, `${lost.length} polls lost after getToken came back`);
});

// Back-off counts the failed calls since the token in hand was issued.

const ISSUED = at("2026-10-17T06:00:01Z"); // 2:00 AM EDT, a quiet-hour renewal that brought a token

test("17 October: a token issued at 2 AM, refused at 10:08 and getToken failing, is retried 30 minutes later, not an hour", () => {
  const failedAt = at("2026-10-17T14:08:00Z");
  const calls = [ISSUED, failedAt];
  assert.equal(mayMint(calls, failedAt + 30 * MINUTE_MS - 1, "needed", ISSUED), false);
  assert.equal(mayMint(calls, failedAt + 30 * MINUTE_MS, "needed", ISSUED), true);
  // As deployed until now: the 2 AM call counted too, an hour.
  assert.equal(mayMint(calls, failedAt + 30 * MINUTE_MS, "needed"), false);
  assert.equal(mayMint(calls, failedAt + HOUR_MS, "needed"), true);
});

test("each failure since the token was issued doubles the wait: 30 minutes, 1, 2, then 4 hours", () => {
  let last = at("2026-10-17T14:08:00Z");
  const calls = [ISSUED, last];
  for (const wait of [30 * MINUTE_MS, HOUR_MS, 2 * HOUR_MS, 4 * HOUR_MS]) {
    assert.equal(mayMint(calls, last + wait - 1, "needed", ISSUED), false, `before ${wait / MINUTE_MS} minutes`);
    assert.equal(mayMint(calls, last + wait, "needed", ISSUED), true, `at ${wait / MINUTE_MS} minutes`);
    last += wait;
    calls.push(last);
    if (calls.length === MINTS_PER_DAY) break;
  }
  // Six calls in 24 hours, the 2 AM one among them: no seventh, however long the wait.
  assert.equal(calls.length, MINTS_PER_DAY);
  assert.equal(mayMint(calls, last + 4 * HOUR_MS, "needed", ISSUED), false);
  // The 2 AM call leaves the 24 hours at 2 AM: the next is allowed, 4 hours after the last.
  assert.equal(mayMint(calls, ISSUED + DAY_MS, "needed", ISSUED), true);
});

test("a call that brought a token still waits 30 minutes before the next, so instant refusals can't spend the day", () => {
  const now = at("2026-10-17T14:08:00Z");
  assert.equal(mayMint([now - 29 * MINUTE_MS], now, "needed", now - 29 * MINUTE_MS), false);
  assert.equal(mayMint([now - 30 * MINUTE_MS], now, "needed", now - 30 * MINUTE_MS), true);
  // A token connected from the app, issued after the last call: still 30 minutes after that call.
  assert.equal(mayMint([now - 10 * MINUTE_MS], now, "needed", now - 5 * MINUTE_MS), false);
});

test("the cap counts every call, good or failed: six in 24 hours, four before a quiet renewal", () => {
  const now = at("2026-10-17T20:00:00Z");
  const good = [-23, -19, -15, -11, -7, -3].map((h) => now + h * HOUR_MS);
  // All six brought tokens (the latest issued 3 hours ago): no failures, still no seventh.
  assert.equal(mayMint(good, now, "needed", good[5]), false);
  assert.equal(mayMint(good.slice(1), now, "needed", good[5]), true);
  // Quiet renewals need fewer than four: three calls yes, four no.
  assert.equal(mayMint(good.slice(3), now, "quiet", good[5]), true);
  assert.equal(mayMint(good.slice(2), now, "quiet", good[5]), false);
});

test("an issue time that can't be used counts every call as failed: the longer wait", () => {
  const failedAt = at("2026-10-17T14:08:00Z");
  const calls = [ISSUED, failedAt];
  for (const issuedAt of [null, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.equal(mayMint(calls, failedAt + 30 * MINUTE_MS, "needed", issuedAt), false, String(issuedAt));
    assert.equal(mayMint(calls, failedAt + HOUR_MS, "needed", issuedAt), true, String(issuedAt));
  }
  // Issued in the future (a bad clock): no failures counted, but 30 minutes after the last call still.
  assert.equal(mayMint(calls, failedAt + 29 * MINUTE_MS, "needed", failedAt + DAY_MS), false);
  assert.equal(mayMint(calls, failedAt + 30 * MINUTE_MS, "needed", failedAt + DAY_MS), true);
  // A call stamped in the future always waits.
  assert.equal(mayMint([failedAt + MINUTE_MS], failedAt, "needed", ISSUED), false);
});

test("a quiet renewal still waits 3 hours after any call, whatever the failures", () => {
  const now = at("2026-10-17T15:30:00Z"); // 11:30 AM EDT
  assert.equal(mayMint([now - 2 * HOUR_MS], now, "quiet", now - 2 * HOUR_MS), false);
  assert.equal(mayMint([now - 3 * HOUR_MS], now, "quiet", now - 3 * HOUR_MS), true);
});
