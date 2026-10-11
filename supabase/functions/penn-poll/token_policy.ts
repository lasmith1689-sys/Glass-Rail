// When the track checker asks NJ Transit for a new RailData token
// (penn-poll/index.ts). A token lasts 24 hours and getToken may be called
// ten times a day, so a token is renewed:
//
// - in New York's quiet hours: once from 2 AM and once from 11 AM, never in
//   a rush;
// - by 20 hours old, whatever the hour, if those renewals didn't happen;
// - only after a poll that NJ Transit answered, so an outage at NJ Transit
//   spends no getToken calls, and a renewal that fails costs no reads: the
//   old token carries on.
//
// Only a token 23 hours old, missing, or refused by NJ Transit stops a poll
// for a new one. getToken calls back off (30 minutes, then 1, 2 and 4 hours
// apart) and stop at six in any 24 hours, leaving NJ Transit's other four
// for connecting from the app (penn-connect).

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
export const DAY_MS = 24 * HOUR_MS;
/** A quiet hour renews a token this old, once per quiet spell: no getToken call in the last this long. */
export const QUIET_RENEW_MS = 3 * HOUR_MS;
/** Renewed by this age, whatever the hour. */
export const RENEW_BY_MS = 20 * HOUR_MS;
/** No longer polled with until it's renewed: an hour short of its 24. */
export const LAST_USE_MS = 23 * HOUR_MS;
/** getToken calls in any 24 hours, of the ten NJ Transit allows. */
export const MINTS_PER_DAY = 6;
/** A quiet renewal only goes ahead with fewer calls than this in the last 24 hours. */
export const QUIET_MINTS_PER_DAY = 4;

/** Why a token is being asked for. */
export type Need = "quiet" | "due" | "needed";

export interface Held {
  value: string;
  issuedAt: number;
}

/** New York's quiet hours: 2 to 5 AM and 11 AM to 2 PM. */
export function quietHour(now: number): boolean {
  try {
    const hour = Number(
      new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", hour: "numeric", hourCycle: "h23" })
        .formatToParts(now)
        .find((part) => part.type === "hour")?.value,
    );
    return (hour >= 2 && hour < 5) || (hour >= 11 && hour < 14);
  } catch {
    // Without the time zone, renewals wait for RENEW_BY_MS.
    return false;
  }
}

/** What a token issued at `issuedAt` needs at `now`. */
export function renewal(issuedAt: number | null, now: number): Need | "none" {
  if (issuedAt === null || Number.isNaN(issuedAt)) return "needed";
  const age = now - issuedAt;
  if (age >= LAST_USE_MS) return "needed";
  if (age >= RENEW_BY_MS) return "due";
  if (age >= QUIET_RENEW_MS && quietHour(now)) return "quiet";
  return "none";
}

/** The wait after the latest of `recent` getToken calls: 30 minutes, doubling to 4 hours. */
export function spacing(recent: number): number {
  return recent === 0 ? 0 : Math.min(30 * MINUTE_MS * 2 ** (recent - 1), 4 * HOUR_MS);
}

/** Whether getToken may be called at `now` for `need`, after calls at `attempts` (ms). */
export function mayMint(attempts: number[], now: number, need: Need): boolean {
  const recent = attempts.filter((at) => now - at < DAY_MS);
  const quiet = need === "quiet";
  const gap = quiet ? Math.max(spacing(recent.length), QUIET_RENEW_MS) : spacing(recent.length);
  return recent.length < (quiet ? QUIET_MINTS_PER_DAY : MINTS_PER_DAY) && recent.every((at) => now - at >= gap);
}

/**
 * One poll at `now`. `read` reads RailData with the token it's given, and
 * calls `fresh` for a new one if NJ Transit refuses it; `mint` calls getToken
 * if `mayMint` allows it for the need, keeps the token and returns it.
 */
export async function poll<T>(
  held: Held | null,
  now: number,
  mint: (need: Need) => Promise<string>,
  read: (token: string, fresh: () => Promise<string>) => Promise<T>,
): Promise<T> {
  const due = renewal(held?.issuedAt ?? null, now);
  let minted = false;
  const fresh = () => {
    minted = true;
    return mint("needed");
  };
  let token: string;
  if (held && due !== "needed") {
    token = held.value;
  } else {
    // A token past its last use may still be good when getToken can't be asked.
    token = await fresh().catch((err) => {
      if (held) return held.value;
      throw err;
    });
  }
  const result = await read(token, fresh);
  if (!minted && (due === "quiet" || due === "due")) {
    // Renewed in good time; if it fails, the token in hand carries on.
    await mint(due).catch(() => undefined);
  }
  return result;
}
