#!/usr/bin/env node
// Merges compiler-extracted strings and registered model keys into the generated English source catalog.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const root = path.resolve(path.dirname(scriptPath), "../..");
const sourceRoot = path.join(root, "Sources", "CompositorPro");

function filesUnder(directory, suffix) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const child = path.join(directory, entry.name);
    return entry.isDirectory() ? filesUnder(child, suffix) : entry.name.endsWith(suffix) ? [child] : [];
  });
}

function decodeSwiftLiteral(value) {
  return value
    .replaceAll("\\\"", "\"")
    .replaceAll("\\n", "\n")
    .replaceAll("\\t", "\t")
    .replaceAll("\\\\", "\\");
}

/// Swift trims the indentation common to every line of a multi-line literal, and drops the
/// newline after the opening delimiter and before the closing one. The catalog copy is written
/// across several lines for readability, so registration has to undo that or the key recorded
/// would not match what the app looks up.
function normaliseMultiLine(content) {
  const lines = content.split("\n");
  while (lines.length > 0 && lines[0].trim() === "") lines.shift();
  while (lines.length > 0 && lines[lines.length - 1].trim() === "") lines.pop();
  if (lines.length === 0) return "";
  const indents = lines
    .filter((line) => line.trim() !== "")
    .map((line) => line.length - line.trimStart().length);
  const common = indents.length > 0 ? Math.min(...indents) : 0;
  return lines
    .map((line) => line.slice(Math.min(common, line.length - line.trimStart().length)))
    // A trailing backslash is Swift line continuation: the line joins the next with no break.
    .join("\n")
    .replaceAll(/\\\n/g, "")
    .replaceAll("\\\n", "\n");
}

export function sourceKeys() {
  const keys = new Set();
  const singleLine = /L10n\.key\("((?:\\.|[^"\\])*)"\)/g;
  const multiLine = /L10n\.key\("""([\s\S]*?)"""\)/g;

  for (const file of filesUnder(sourceRoot, ".swift")) {
    const source = fs.readFileSync(file, "utf8");
    for (const match of source.matchAll(singleLine)) keys.add(decodeSwiftLiteral(match[1]));
    for (const match of source.matchAll(multiLine)) {
      keys.add(decodeSwiftLiteral(normaliseMultiLine(match[1])));
    }
  }

  return [...keys].sort();
}

function appStringsDataPaths(directory) {
  const sourceFiles = filesUnder(sourceRoot, ".swift").map((file) => path.resolve(file));
  const sourceNames = new Set();
  for (const file of sourceFiles) {
    const name = path.basename(file);
    if (sourceNames.has(name)) throw new Error(`Duplicate Swift filename prevents localization sync: ${name}`);
    sourceNames.add(name);
  }

  const expectedSources = new Set(sourceFiles);
  const foundSources = new Set();
  const dataPaths = [];
  // The build writes stringsdata into its own derived-sources tree rather than wherever the
  // caller asked, so search recursively instead of trusting the directory's top level.
  for (const dataPath of filesUnder(directory, ".stringsdata")) {
    const data = JSON.parse(fs.readFileSync(dataPath, "utf8"));
    const source = path.resolve(data.source);
    if (!expectedSources.has(source)) continue;
    foundSources.add(source);
    if ((data.tables?.Localizable ?? []).length > 0) dataPaths.push(dataPath);
  }

  const missingSources = sourceFiles.filter((file) => !foundSources.has(file));
  if (missingSources.length > 0) {
    throw new Error(`Missing compiler localization output for: ${missingSources.map((file) => path.relative(root, file)).join(", ")}`);
  }
  return dataPaths.sort();
}

function argumentValues(name) {
  const values = [];
  for (let index = 2; index < process.argv.length; index += 1) {
    if (process.argv[index] === name) {
      const value = process.argv[index + 1];
      if (!value) throw new Error(`${name} requires a value`);
      values.push(value);
      index += 1;
    }
  }
  return values;
}

function escapeStringsValue(value) {
  return value
    .replaceAll("\\", "\\\\")
    .replaceAll('"', '\\"')
    .replaceAll("\n", "\\n")
    .replaceAll("\r", "\\r")
    .replaceAll("\t", "\\t");
}

function synchronize() {
  const outputPaths = argumentValues("--output");
  const stringsDataPaths = argumentValues("--stringsdata");
  if (outputPaths.length !== 1) throw new Error("--output is required exactly once");
  if (stringsDataPaths.length === 0) throw new Error("at least one --stringsdata is required");

  const keys = new Set(sourceKeys());
  for (const stringsDataPath of stringsDataPaths) {
    const data = JSON.parse(fs.readFileSync(stringsDataPath, "utf8"));
    const entries = data.tables?.Localizable ?? [];
    if (entries.length === 0) {
      throw new Error(`${stringsDataPath} contains no compiler-extracted localization keys`);
    }
    for (const entry of entries) {
      if (!entry.key) throw new Error(`${stringsDataPath} contains an empty localization key`);
      keys.add(entry.key);
    }
  }

  const entries = [...keys]
    .sort()
    .map((key) => `"${escapeStringsValue(key)}" = "${escapeStringsValue(key)}";`);
  const output = [
    "/* Generated from app-owned UI copy. Translate values only in other locales. */",
    "",
    ...entries,
    "",
  ].join("\n");

  const outputPath = outputPaths[0];
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, output);
  console.log(`Synchronized ${keys.size} source strings.`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === scriptPath) {
  if (process.argv.includes("--list-app-stringsdata")) {
    const directories = argumentValues("--list-app-stringsdata");
    if (directories.length !== 1) throw new Error("--list-app-stringsdata is required exactly once");
    for (const dataPath of appStringsDataPaths(directories[0])) console.log(dataPath);
  } else {
    synchronize();
  }
}
