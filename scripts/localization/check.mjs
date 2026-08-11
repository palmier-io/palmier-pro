#!/usr/bin/env node
// Validates localization catalogs, placeholders, registered keys, and protected UI and Agent boundaries.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { sourceKeys } from "./sync.mjs";

const scriptPath = fileURLToPath(import.meta.url);
const root = path.resolve(path.dirname(scriptPath), "../..");
const sourceRoot = path.join(root, "Sources", "PalmierPro");
const catalogRoot = path.join(sourceRoot, "Resources", "Localization");
const sourceLocale = "en";
const tableNames = ["Localizable", "InfoPlist"];
const errors = [];
const warnings = [];
const requiresCompleteCoverage = process.argv.includes("--require-complete");

function reportCoverageIssue(message) {
  (requiresCompleteCoverage ? errors : warnings).push(message);
}

function filesUnder(directory, suffix) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const child = path.join(directory, entry.name);
    return entry.isDirectory() ? filesUnder(child, suffix) : entry.name.endsWith(suffix) ? [child] : [];
  });
}

function relative(file) {
  return path.relative(root, file);
}

function lineNumber(source, index) {
  return source.slice(0, index).split("\n").length;
}

export function placeholderSignature(value) {
  const result = [];
  let nextIndex = 1;
  const pattern = /%%|%(?:(\d+)\$)?[-+#0 ']*\d*(?:\.\d+)?(?:hh|h|ll|l|L|z|t|j|q)?([@diuoxXfFeEgGaAcCsSp])/g;
  for (const match of value.matchAll(pattern)) {
    if (match[0] === "%%") continue;
    const type = match[2].toLowerCase();
    result.push({
      index: match[1] ? Number(match[1]) : nextIndex++,
      type: "diuox".includes(type) ? "integer" : "fega".includes(type) ? "floating" : type,
    });
  }
  return result
    .sort((lhs, rhs) => lhs.index - rhs.index || lhs.type.localeCompare(rhs.type))
    .map(({ index, type }) => `${index}:${type}`)
    .join(",");
}

function parseStrings(file) {
  try {
    const output = execFileSync(
      "/usr/bin/plutil",
      ["-convert", "json", "-o", "-", file],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    const values = JSON.parse(output);
    if (Array.isArray(values) || values === null || typeof values !== "object") {
      throw new Error("expected a string dictionary");
    }
    for (const [key, value] of Object.entries(values)) {
      if (typeof value !== "string") throw new Error(`${JSON.stringify(key)} does not contain a string value`);
    }
    return new Map(Object.entries(values));
  } catch (error) {
    const detail = error.stderr?.trim() || error.message;
    errors.push(`${relative(file)}: ${detail}`);
    return null;
  }
}

let locales = [];
try {
  locales = fs.readdirSync(catalogRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.endsWith(".lproj"))
    .map((entry) => entry.name.slice(0, -".lproj".length))
    .sort();
} catch (error) {
  errors.push(`${relative(catalogRoot)}: ${error.message}`);
}

if (!locales.includes(sourceLocale)) {
  errors.push(`${relative(catalogRoot)}: missing ${sourceLocale}.lproj source localization`);
}

const targetLocales = locales.filter((locale) => locale !== sourceLocale);
const sourceTables = new Map();

for (const tableName of tableNames) {
  const fileName = `${tableName}.strings`;
  const sourceFile = path.join(catalogRoot, `${sourceLocale}.lproj`, fileName);
  const sourceEntries = parseStrings(sourceFile) ?? new Map();
  sourceTables.set(tableName, sourceEntries);

  for (const [key, value] of sourceEntries) {
    if (!key) errors.push(`${relative(sourceFile)}: contains an empty key`);
    if (!value.trim()) {
      errors.push(`${relative(sourceFile)}: empty source value for ${JSON.stringify(key)}`);
    }
    if (tableName === "Localizable" && value !== key) {
      errors.push(`${relative(sourceFile)}: source value must match its key for ${JSON.stringify(key)}`);
    }
  }

  for (const locale of targetLocales) {
    const targetFile = path.join(catalogRoot, `${locale}.lproj`, fileName);
    const targetEntries = parseStrings(targetFile);
    if (!targetEntries) continue;

    for (const key of sourceEntries.keys()) {
      if (!targetEntries.has(key)) {
        reportCoverageIssue(`${relative(targetFile)}: missing ${JSON.stringify(key)}`);
        continue;
      }
      const value = targetEntries.get(key);
      if (!value.trim()) {
        errors.push(`${relative(targetFile)}: empty translation for ${JSON.stringify(key)}`);
      } else if (placeholderSignature(value) !== placeholderSignature(sourceEntries.get(key))) {
        errors.push(`${relative(targetFile)}: incompatible placeholders for ${JSON.stringify(key)}`);
      }
    }

    for (const key of targetEntries.keys()) {
      if (!sourceEntries.has(key)) {
        reportCoverageIssue(`${relative(targetFile)}: unknown key ${JSON.stringify(key)}`);
      }
    }
  }
}

const localizable = sourceTables.get("Localizable") ?? new Map();
for (const key of sourceKeys()) {
  if (!localizable.has(key)) {
    errors.push(`en.lproj/Localizable.strings: missing registered source key ${JSON.stringify(key)}`);
  }
}

function checkNamedUILiterals(file, source) {
  const patterns = [
    ["panel text", /\bpanel\.(?:message|prompt|title)\s*=\s*(?:#*)"/g],
    ["mediaPanelToast", /\b(?:[A-Za-z_][A-Za-z0-9_]*\.)?mediaPanelToast\s*=\s*(?:#*)"/g],
    ["deletionMessage", /\bdeletionMessage\s*=\s*(?:#*)"/g],
    ["submissionError", /\bsubmissionError\s*=\s*(?:#*)"/g],
  ];
  if (!file.includes(`${path.sep}Agent${path.sep}`)) {
    patterns.push(["labelHelp", /\blabelHelp\s*:\s*(?:#*)"/g]);
  }
  for (const [name, pattern] of patterns) {
    for (const match of source.matchAll(pattern)) {
      errors.push(`${relative(file)}:${lineNumber(source, match.index)}: ${name} contains an unclassified string literal`);
    }
  }
}

for (const file of filesUnder(sourceRoot, ".swift")) {
  const source = fs.readFileSync(file, "utf8");
  checkNamedUILiterals(file, source);
  if (file.includes(`${path.sep}Agent${path.sep}Tools${path.sep}`) && source.includes("L10n.")) {
    errors.push(`${relative(file)}: Agent tool contracts must not use UI localization`);
  }
}

for (const warning of warnings) console.warn(`warning: ${warning}`);

if (errors.length > 0) {
  for (const error of errors) console.error(`error: ${error}`);
  process.exit(1);
}

const stringCount = [...sourceTables.values()].reduce((sum, entries) => sum + entries.size, 0);
const localeSummary = targetLocales.join(", ") || "source language only";
const warningSummary = warnings.length > 0 ? `; ${warnings.length} coverage warnings` : "";
console.log(`Localization checks passed: ${stringCount} strings; ${localeSummary}${warningSummary}.`);
