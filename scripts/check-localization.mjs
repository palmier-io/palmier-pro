#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourceRoot = path.join(repoRoot, "Sources", "PalmierPro");
const localizationRoot = path.join(sourceRoot, "Resources", "Localization");
const changelogPath = path.join(sourceRoot, "Resources", "Changelog", "changelog.json");
const englishPath = path.join(localizationRoot, "en.lproj", "Localizable.strings");
const chinesePath = path.join(localizationRoot, "zh-Hans.lproj", "Localizable.strings");
const englishInfoPath = path.join(localizationRoot, "en.lproj", "InfoPlist.strings");
const chineseInfoPath = path.join(localizationRoot, "zh-Hans.lproj", "InfoPlist.strings");
const listOnly = process.argv.includes("--list");
const syncEnglish = process.argv.includes("--sync-english");

function walk(directory, suffix) {
    const result = [];
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const fullPath = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            if (entry.name !== "Resources") result.push(...walk(fullPath, suffix));
        } else if (entry.name.endsWith(suffix)) {
            result.push(fullPath);
        }
    }
    return result;
}

function decodeEscapes(value) {
    return value
        .replace(/\\u\{([0-9a-fA-F]+)\}/g, (_, hex) => String.fromCodePoint(Number.parseInt(hex, 16)))
        .replace(/\\n/g, "\n")
        .replace(/\\r/g, "\r")
        .replace(/\\t/g, "\t")
        .replace(/\\"/g, "\"")
        .replace(/\\\\/g, "\\");
}

function parseStrings(filePath) {
    const source = fs.readFileSync(filePath, "utf8");
    const entries = new Map();
    const pattern = /^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;/gm;
    for (const match of source.matchAll(pattern)) {
        entries.set(decodeEscapes(match[1]), decodeEscapes(match[2]));
    }
    return entries;
}

function encodeStringsValue(value) {
    return value
        .replace(/\\/g, "\\\\")
        .replace(/\"/g, "\\\"")
        .replace(/\n/g, "\\n")
        .replace(/\r/g, "\\r")
        .replace(/\t/g, "\\t");
}

function lineNumber(source, offset) {
    return source.slice(0, offset).split("\n").length;
}

const literalBody = "((?:\\\\.|[^\"\\\\])*)";
const sourcePatterns = [
    new RegExp(`\\b(?:Text|Button|Label|Toggle|Picker|Menu|Section|GroupBox|ProgressView|ContentUnavailableView|InspectorSection|SettingsSection|TextField|SecureField|Link)\\s*\\(\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\.(?:help|accessibilityLabel|accessibilityHint|navigationTitle|confirmationDialog)\\s*\\(\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\b(?:NSMenu|NSMenuItem)\\s*\\(\\s*title:\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\baddItem\\s*\\(\\s*withTitle:\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\bsetActionName\\s*\\(\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\bL10n\\.(?:string|text|format)\\s*\\(\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\b(?:panel|window|alert)\\.title\\s*=\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\bcontent\\.(?:title|body)\\s*=\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\bpanel\\.message\\s*=\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\b(?:mediaPanelToast|speakerIdentifyError|lastError|palmierResult|errorText|statusText|statusMessage|resultMessage|(?:self\\.)?error)\\s*=\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\b(?:title|label|subtitle|message|placeholder|emptyMessage|intro|instruction|help):\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\.disabled\\s*\\(\\s*reason:\\s*\"${literalBody}\"`, "g"),
];
sourcePatterns.push(new RegExp(`\\b(?:flashDropError|onError)\\s*\\(\\s*"${literalBody}"`, "g"));
const shortcutDescriptionPattern = new RegExp(
    `\\(\\s*\"(?:\\\\.|[^\"\\\\])*\"\\s*,\\s*\"${literalBody}\"\\s*\\)`,
    "g"
);

function looksLikeFixedEnglishUI(value) {
    if (!/[A-Za-z]/.test(value) || value.includes("\\(")) return false;
    if (value === "(image payload)") return false;
    if (/^(?:https?:|file:|[a-z]+:\/\/)/i.test(value)) return false;
    if (/[_/]/.test(value) && !value.includes(" ") && !value.includes("%")) return false;
    if (/^[a-z0-9.-]+$/i.test(value) && value.includes(".") && !value.includes(" ")) return false;
    if (/^(?:[a-z]+\.)+[a-z]+$/i.test(value)) return false;
    return true;
}

function collectCandidates() {
    const candidates = new Map();
    const dynamicRisks = [];
    const addCandidate = (value, location) => {
        if (!looksLikeFixedEnglishUI(value)) return;
        const locations = candidates.get(value) ?? [];
        if (!locations.includes(location)) locations.push(location);
        candidates.set(value, locations);
    };
    for (const filePath of walk(sourceRoot, ".swift")) {
        const relativePath = path.relative(sourceRoot, filePath);
        const source = fs.readFileSync(filePath, "utf8");
        const isAgentTool = relativePath.startsWith(path.join("Agent", "Tools"));
        const patterns = isAgentTool
            ? [sourcePatterns[5]]
            : relativePath.endsWith(path.join("Help", "ShortcutsPane.swift"))
                ? [...sourcePatterns, shortcutDescriptionPattern]
                : sourcePatterns;
        for (const pattern of patterns) {
            for (const match of source.matchAll(pattern)) {
                const raw = match[1];
                if (raw.includes("\\(")) {
                    const fixedShell = decodeEscapes(raw.replace(/\\\((?:\\.|[^)])*\)/g, " ")).trim();
                    if (!["fps", "x"].includes(fixedShell.toLowerCase()) && looksLikeFixedEnglishUI(fixedShell)) {
                        dynamicRisks.push(
                            `${path.relative(repoRoot, filePath)}:${lineNumber(source, match.index)} ${JSON.stringify(decodeEscapes(raw))}`
                        );
                    }
                    continue;
                }
                if (!looksLikeFixedEnglishUI(raw)) continue;
                const value = decodeEscapes(raw);
                const location = `${path.relative(repoRoot, filePath)}:${lineNumber(source, match.index)}`;
                addCandidate(value, location);
            }
        }
        const lines = source.split("\n");
        for (const [index, line] of lines.entries()) {
            if (/\b(?:Text|Button|Label|Toggle|Picker|Menu)\s*\([^\n]{0,200}\?\s*"[^"\n]+"\s*:\s*"[^"\n]+"/.test(line)) {
                dynamicRisks.push(`${path.relative(repoRoot, filePath)}:${index + 1} ${JSON.stringify(line.trim())}`);
            }
            if (!/\b(?:actionName|[A-Za-z]+ActionName|setActionName|onName|offName|timelineAction)\b/.test(line)) continue;
            for (const match of line.matchAll(new RegExp(`"${literalBody}"`, "g"))) {
                const value = decodeEscapes(match[1]);
                addCandidate(value, `${path.relative(repoRoot, filePath)}:${index + 1}`);
            }
        }
    }
    const changelog = JSON.parse(fs.readFileSync(changelogPath, "utf8"));
    for (const [entryIndex, entry] of (changelog.entries ?? []).entries()) {
        for (const [sectionIndex, section] of (entry.sections ?? []).entries()) {
            if (section.heading) {
                addCandidate(
                    section.heading,
                    `${path.relative(repoRoot, changelogPath)}:entries[${entryIndex}].sections[${sectionIndex}].heading`
                );
            }
            for (const [itemIndex, item] of (section.items ?? []).entries()) {
                addCandidate(
                    item,
                    `${path.relative(repoRoot, changelogPath)}:entries[${entryIndex}].sections[${sectionIndex}].items[${itemIndex}]`
                );
            }
        }
    }
    return { candidates, dynamicRisks };
}

function placeholders(value) {
    return [...value.replace(/%%/g, "").matchAll(/%(?:\d+\$)?[-+0 #'I]*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|L|z|j|t)?[@a-zA-Z]/g)]
        .map((match) => match[0])
        .sort();
}

const protectedTokens = [
    "Palmier Pro", "Google", "Anthropic", "Claude", "Codex", "Cursor", "MCP", "API", "HDR", "LUT",
];
const allowedUntranslatedKeys = new Set(["AI", "Agent", "FPS", "MCP", "Max", "Palmier Pro", "Pro"]);
const protectedTokenExceptions = new Set(["Zoom Preview to Cursor", "Zoom to Cursor"]);

function containsProtectedToken(value, token) {
    const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return new RegExp(`(^|[^A-Za-z0-9])${escaped}(?=$|[^A-Za-z0-9])`).test(value);
}

const english = parseStrings(englishPath);
const chinese = parseStrings(chinesePath);
const englishInfo = parseStrings(englishInfoPath);
const chineseInfo = parseStrings(chineseInfoPath);
const { candidates, dynamicRisks } = collectCandidates();

if (syncEnglish) {
    const keys = new Set([...english.keys(), ...candidates.keys()]);
    const lines = [
        "/* English source strings. Keep keys synchronized with zh-Hans using scripts/check-localization.mjs. */",
        ...[...keys].sort((a, b) => a.localeCompare(b)).map((key) => {
            const encoded = encodeStringsValue(key);
            return `\"${encoded}\" = \"${encoded}\";`;
        }),
        "",
    ];
    fs.writeFileSync(englishPath, lines.join("\n"));
    console.log(`已同步英文词典：${keys.size} 条。`);
    process.exit(0);
}

if (listOnly) {
    for (const [value, locations] of [...candidates].sort(([a], [b]) => a.localeCompare(b))) {
        console.log(`${value}\t${locations.join(",")}`);
    }
    process.exit(0);
}

const errors = [];
for (const risk of dynamicRisks) {
    errors.push(`动态 UI 未经过 L10n.format：${risk}`);
}
for (const [key, locations] of candidates) {
    if (!english.has(key)) errors.push(`英文词典缺少：${JSON.stringify(key)} (${locations[0]})`);
    if (!chinese.has(key)) errors.push(`简体中文词典缺少：${JSON.stringify(key)} (${locations[0]})`);
    if (english.has(key) && chinese.has(key)
        && chinese.get(key) === english.get(key) && !allowedUntranslatedKeys.has(key)) {
        errors.push(`简体中文仍为英文：${JSON.stringify(key)} (${locations[0]})`);
    }
}

for (const key of english.keys()) {
    if (!chinese.has(key)) errors.push(`简体中文词典缺少英文键：${JSON.stringify(key)}`);
}
for (const key of chinese.keys()) {
    if (!english.has(key)) errors.push(`简体中文词典存在额外键：${JSON.stringify(key)}`);
}
for (const [key, value] of englishInfo) {
    if (!chineseInfo.has(key)) errors.push(`简体中文 InfoPlist 缺少：${JSON.stringify(key)}`);
    if (key !== "CFBundleTypeName" && chineseInfo.get(key) !== value) {
        errors.push(`简体中文 InfoPlist 改写了产品标识：${JSON.stringify(key)}`);
    }
}
for (const key of chineseInfo.keys()) {
    if (!englishInfo.has(key)) errors.push(`简体中文 InfoPlist 存在额外键：${JSON.stringify(key)}`);
}

for (const [key, translation] of chinese) {
    const sourcePlaceholders = placeholders(english.get(key) ?? key);
    const translatedPlaceholders = placeholders(translation);
    if (JSON.stringify(sourcePlaceholders) !== JSON.stringify(translatedPlaceholders)) {
        errors.push(`占位符不一致：${JSON.stringify(key)} -> ${JSON.stringify(translation)}`);
    }
    for (const token of protectedTokens) {
        if (!protectedTokenExceptions.has(key)
            && containsProtectedToken(key, token) && !containsProtectedToken(translation, token)) {
            errors.push(`受保护标识被改写：${JSON.stringify(key)} 必须保留 ${token}`);
        }
    }
}

if (errors.length > 0) {
    console.error(`本地化检查失败（${errors.length} 项）：`);
    for (const error of errors) console.error(`- ${error}`);
    process.exit(1);
}

console.log(`本地化检查通过：${candidates.size} 条固定 UI 候选，${chinese.size} 条简体中文翻译。`);
