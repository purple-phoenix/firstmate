#!/usr/bin/env node
/**
 * fm-decision-document.mjs - bounded parser for dashboard decision records.
 *
 * docs/dashboard-service.md owns the structured Markdown format.
 * This module is the single parser used by the fleet snapshot and dashboard
 * service so main-home and supervisor-home decisions cannot drift.
 *
 * The internal --enrich-summary mode reads one already-bounded secondmate-home
 * summary from stdin, attaches detail to its included decisions_open rows, and
 * writes JSON to stdout. It never scans a directory: every read is derived from
 * one validated origin/key pair already present in the summary.
 */

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export const DECISION_DOCUMENT_MAX_BYTES = 131072;
const SUMMARY_OUTPUT_MAX_BYTES = 262144;
const SUMMARY_INPUT_MAX_BYTES = 4 * 1024 * 1024;
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

function unavailable(reason) {
  return { available: false, reason };
}

function errorCode(error) {
  return typeof error?.code === "string" ? error.code : "read failed";
}

export function parseDecisionDocument(text) {
  const title = (text.match(/^#\s+(.+)$/m) || [])[1]?.trim();
  if (!title) return unavailable("decision record is missing its level-one title");
  const sections = text.split(/^##\s+Options\s*$/im);
  if (sections.length < 2) return unavailable("decision record is missing its Options section");
  const context = sections[0].replace(/^#\s+.*$/m, "").trim().slice(0, 4000);
  if (!context) return unavailable("decision record has no decision context");
  const options = [];
  let current = null;
  for (const line of sections.slice(1).join("\n## Options\n").split("\n")) {
    const marker = line.match(/^\s*-\s+(?:\[recommended\]\s*)?(.+?)(?:\s+-\s+(.+))?\s*$/i);
    if (marker) {
      current = {
        text: marker[1].trim(),
        impact: (marker[2] || "").trim(),
        recommended: /^\s*-\s+\[recommended\]/i.test(line),
      };
      options.push(current);
      continue;
    }
    if (current && /^\s{2,}\S/.test(line)) current.impact = `${current.impact} ${line.trim()}`.trim();
  }
  const boundedOptions = options
    .filter((option) => option.text && option.impact)
    .slice(0, 20)
    .map((option) => ({
      ...option,
      text: option.text.slice(0, 300),
      impact: option.impact.slice(0, 1200),
    }));
  if (boundedOptions.length === 0) return unavailable("decision record has no complete options with impacts");
  return {
    available: true,
    title,
    context,
    options: boundedOptions,
  };
}

export function readDecisionDocument(home, origin, key, { allowOversizePrefix = false } = {}) {
  if (!ID_PATTERN.test(String(key || ""))) return unavailable("decision key is invalid");
  if (origin !== null && !ID_PATTERN.test(String(origin || ""))) return unavailable("decision origin is invalid");
  const root = path.resolve(home);
  const relative = origin === null
    ? path.join("data", "decisions", `${key}.md`)
    : path.join("data", origin, "decisions", `${key}.md`);
  const file = path.resolve(root, relative);
  const relation = path.relative(root, file);
  if (relation.startsWith(`..${path.sep}`) || path.isAbsolute(relation)) {
    return unavailable("decision record resolved outside its owning home");
  }
  let descriptor;
  try {
    descriptor = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) return unavailable(`decision record is not a regular file: ${relative}`);
    if (stat.size > DECISION_DOCUMENT_MAX_BYTES && !allowOversizePrefix) {
      return unavailable(`decision record exceeds the ${DECISION_DOCUMENT_MAX_BYTES}-byte limit: ${relative}`);
    }
    const buffer = Buffer.alloc(Math.min(stat.size, DECISION_DOCUMENT_MAX_BYTES));
    const bytesRead = fs.readSync(descriptor, buffer, 0, buffer.length, 0);
    const text = buffer.subarray(0, bytesRead).toString("utf8");
    return parseDecisionDocument(text);
  } catch (error) {
    const code = errorCode(error);
    if (code === "ENOENT") return unavailable(`decision record is missing: ${relative}`);
    if (code === "ELOOP") return unavailable(`decision record is a symbolic link: ${relative}`);
    return unavailable(`decision record could not be read (${code}): ${relative}`);
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

export function enrichDecisionSummary(summary, home, maxBytes = SUMMARY_OUTPUT_MAX_BYTES) {
  if (!summary || !Array.isArray(summary.decisions_open)) throw new Error("summary decisions_open must be an array");
  const overflow = unavailable("decision detail omitted to preserve the structured home snapshot byte limit");
  const enriched = {
    ...summary,
    decisions_open: summary.decisions_open.map((decision) => ({
      ...decision,
      detail: overflow,
    })),
  };
  for (let index = 0; index < enriched.decisions_open.length; index += 1) {
    const decision = enriched.decisions_open[index];
    const detail = readDecisionDocument(home, decision.origin || decision.id, decision.key);
    decision.detail = detail;
    if (Buffer.byteLength(JSON.stringify(enriched)) > maxBytes) decision.detail = overflow;
  }
  return enriched;
}

function summaryOutputMaxBytes() {
  const value = Number(process.env.FM_SNAPSHOT_SECONDMATE_MAX_BYTES || SUMMARY_OUTPUT_MAX_BYTES);
  return Number.isSafeInteger(value) && value > 0 ? value : SUMMARY_OUTPUT_MAX_BYTES;
}

async function readStdinBounded() {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > SUMMARY_INPUT_MAX_BYTES) throw new Error(`summary input exceeds ${SUMMARY_INPUT_MAX_BYTES} bytes`);
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function main() {
  if (process.argv[2] !== "--enrich-summary" || !process.argv[3]) {
    process.stderr.write("usage: fm-decision-document.mjs --enrich-summary <home>\n");
    process.exitCode = 2;
    return;
  }
  const summary = JSON.parse(await readStdinBounded());
  process.stdout.write(`${JSON.stringify(enrichDecisionSummary(summary, process.argv[3], summaryOutputMaxBytes()))}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
