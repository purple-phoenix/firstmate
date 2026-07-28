/**
 * fm-wait-progress.mjs - honest wait-progress estimation for the capacity dashboard.
 *
 * This module is the single owner of the fm-capacity-wait-history.v1 durable
 * file shape and of the estimator math and plain-language progress labels that
 * bin/fm-capacity.mjs attaches to self-clearing waits. It never fabricates
 * precision: with no recorded history for a wait kind it reports "time unknown"
 * plus observed elapsed time, and once observed elapsed time exceeds the
 * recorded typical duration it reports "running longer than usual" instead of a
 * frozen near-complete percentage. Every history-based figure is labeled as an
 * estimate from past runs.
 *
 * The history file is home-local and private (data/capacity-wait-history.json,
 * gitignored with all of data/, written mode 0600 by the capacity producer):
 *   { "schema": "fm-capacity-wait-history.v1",
 *     "active":    { "<owner>/<id>:<kind>": {kind, first_observed, last_observed} },
 *     "durations": { "<kind>": [seconds, ...] } }
 * Timestamps are UTC epoch seconds taken from each snapshot's generated time,
 * so estimates stay deterministic for a given snapshot and improve at the
 * producer's own observation cadence rather than pretending to be live.
 * A missing, unreadable, or wrong-schema file starts fresh rather than failing.
 */

import fs from "node:fs";

export const WAIT_HISTORY_SCHEMA = "fm-capacity-wait-history.v1";
// Rolling per-kind duration window: enough completed observations for a stable
// median without letting ancient runs dominate a project whose waits changed.
export const WAIT_HISTORY_LIMIT = 24;
// Only kinds whose durations repeat meaningfully are recorded; dependency and
// chain waits vary too widely for a median to be honest.
export const WAIT_HISTORY_KINDS = new Set(["validation", "ci", "paused"]);

function emptyHistory() {
  return { schema: WAIT_HISTORY_SCHEMA, active: {}, durations: {} };
}

function positiveInt(value) {
  return Number.isInteger(value) && value > 0 ? value : null;
}

export function loadWaitHistory(file) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return emptyHistory();
  }
  if (!parsed || parsed.schema !== WAIT_HISTORY_SCHEMA) return emptyHistory();
  const history = emptyHistory();
  for (const [key, entry] of Object.entries(parsed.active && typeof parsed.active === "object" ? parsed.active : {})) {
    const first = positiveInt(entry?.first_observed);
    const last = positiveInt(entry?.last_observed);
    if (typeof entry?.kind !== "string" || first === null || last === null || last < first) continue;
    history.active[key] = { kind: entry.kind, first_observed: first, last_observed: last };
  }
  for (const [kind, durations] of Object.entries(parsed.durations && typeof parsed.durations === "object" ? parsed.durations : {})) {
    if (!WAIT_HISTORY_KINDS.has(kind) || !Array.isArray(durations)) continue;
    const clean = durations.map(positiveInt).filter((value) => value !== null);
    if (clean.length > 0) history.durations[kind] = clean.slice(-WAIT_HISTORY_LIMIT);
  }
  return history;
}

// Reconcile one producer observation against the durable history, in place.
// observed maps "<owner>/<id>:<kind>" to its kind. An active entry no longer
// observed under an authoritative owner has completed: its observed duration
// joins the rolling per-kind history (recordable kinds only, and only when it
// was seen more than once, so a single sighting never records a meaningless
// zero). Returns elapsed seconds per observed key, measured from first
// observation - an honest lower bound, since the wait may have started before
// the producer first saw it.
export function observeWaits(history, observed, nowEpoch, authoritativeOwners = null) {
  const elapsed = new Map();
  for (const [key, entry] of Object.entries(history.active)) {
    if (observed.has(key) && observed.get(key) === entry.kind) continue;
    const owner = key.slice(0, key.indexOf("/"));
    if (authoritativeOwners && !authoritativeOwners.has(owner)) continue;
    const duration = entry.last_observed - entry.first_observed;
    if (duration > 0 && WAIT_HISTORY_KINDS.has(entry.kind)) {
      const durations = history.durations[entry.kind] || [];
      durations.push(duration);
      history.durations[entry.kind] = durations.slice(-WAIT_HISTORY_LIMIT);
    }
    delete history.active[key];
  }
  for (const [key, kind] of observed) {
    const entry = history.active[key];
    if (entry) {
      entry.last_observed = Math.max(entry.last_observed, nowEpoch);
      elapsed.set(key, entry.last_observed - entry.first_observed);
    } else {
      history.active[key] = { kind, first_observed: nowEpoch, last_observed: nowEpoch };
      elapsed.set(key, 0);
    }
  }
  return elapsed;
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// History-based estimate for one wait. basis "none" means no honest estimate
// exists; the caller shows elapsed time only. overrun means elapsed already
// exceeds the recorded typical duration, so no percentage or remaining time is
// claimed. The displayed percentage is clamped to 1-99: a wait still under way
// is never shown as 0% or 100% complete.
export function estimateWait(elapsedSeconds, durations) {
  const elapsed = Math.max(0, Math.floor(elapsedSeconds ?? 0));
  const clean = (Array.isArray(durations) ? durations : []).map(positiveInt).filter((value) => value !== null);
  if (clean.length === 0) {
    return { basis: "none", percent: null, elapsed_seconds: elapsed, remaining_seconds: null, typical_seconds: null, overrun: false };
  }
  const typical = Math.max(1, Math.round(median(clean)));
  if (elapsed > typical) {
    return { basis: "history", percent: null, elapsed_seconds: elapsed, remaining_seconds: null, typical_seconds: typical, overrun: true };
  }
  const percent = Math.min(99, Math.max(1, Math.round((elapsed / typical) * 100)));
  return { basis: "history", percent, elapsed_seconds: elapsed, remaining_seconds: typical - elapsed, typical_seconds: typical, overrun: false };
}

// Deterministic estimate for a scheduled wait with a known end (a date gate).
// The percentage is time progress through the wait window and appears only
// when the window's start is also known.
export function deadlineWait(remainingSeconds, elapsedSeconds = null) {
  const remaining = Math.max(0, Math.floor(remainingSeconds ?? 0));
  const elapsed = elapsedSeconds === null || elapsedSeconds === undefined ? null : Math.max(0, Math.floor(elapsedSeconds));
  const total = elapsed === null ? null : elapsed + remaining;
  const percent = total ? Math.min(99, Math.max(1, Math.round((elapsed / total) * 100))) : null;
  return { basis: "deadline", percent, elapsed_seconds: elapsed, remaining_seconds: remaining, typical_seconds: null, overrun: false };
}

export function formatDuration(seconds) {
  const total = Math.max(0, Math.floor(seconds ?? 0));
  if (total < 60) return "under 1m";
  const minutes = Math.round(total / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) {
    const rest = minutes % 60;
    return rest > 0 ? `${hours}h ${rest}m` : `${hours}h`;
  }
  const days = Math.floor(hours / 24);
  const restHours = hours % 24;
  return restHours > 0 ? `${days}d ${restHours}h` : `${days}d`;
}

// The one plain-language line rendered next to a progress affordance. Owns the
// honesty wording: unknown stays unknown, overruns say so, and estimates are
// attributed to past runs.
export function progressLabel(estimate) {
  if (!estimate) return "";
  if (estimate.basis === "none") {
    return `time unknown - ${formatDuration(estimate.elapsed_seconds)} elapsed so far`;
  }
  if (estimate.basis === "deadline") {
    return `~${formatDuration(estimate.remaining_seconds)} until it resumes`;
  }
  if (estimate.overrun) {
    return `running longer than usual - typically ~${formatDuration(estimate.typical_seconds)}, ${formatDuration(estimate.elapsed_seconds)} so far`;
  }
  return `~${estimate.percent}% done - ~${formatDuration(estimate.remaining_seconds)} left, based on past runs`;
}
