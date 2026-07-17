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
        const key = decodeEscapes(match[1]);
        if (entries.has(key)) {
            catalogParseErrors.push(
                `词典存在重复键：${JSON.stringify(key)} (${path.relative(repoRoot, filePath)}:${lineNumber(source, match.index)})`
            );
        }
        entries.set(key, decodeEscapes(match[2]));
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
const catalogParseErrors = [];
const l10nLiteralPattern = new RegExp(
    `\\bL10n\\.(?:string|text|format|message)\\s*\\(\\s*\"${literalBody}\"`,
    "g"
);
const sourcePatterns = [
    new RegExp(`\\b(?:Text|Button|Label|Toggle|Picker|Menu|Section|GroupBox|ProgressView|ContentUnavailableView|InspectorSection|SettingsSection|TextField|SecureField|Link)\\s*\\(\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\.(?:help|accessibilityLabel|accessibilityHint|navigationTitle|confirmationDialog)\\s*\\(\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\b(?:NSMenu|NSMenuItem)\\s*\\(\\s*title:\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\baddItem\\s*\\(\\s*withTitle:\\s*\"${literalBody}\"`, "g"),
    new RegExp(`\\bsetActionName\\s*\\(\\s*\"${literalBody}\"`, "g"),
    l10nLiteralPattern,
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
    const typedAssignmentRisks = [];
    const nativeMenuRisks = [];
    const addCandidate = (value, location, force = false) => {
        if (!force && !looksLikeFixedEnglishUI(value)) return;
        const locations = candidates.get(value) ?? [];
        if (!locations.includes(location)) locations.push(location);
        candidates.set(value, locations);
    };
    for (const filePath of walk(sourceRoot, ".swift")) {
        const relativePath = path.relative(sourceRoot, filePath);
        const source = fs.readFileSync(filePath, "utf8");
        const nativeMenuPattern = new RegExp(
            `\\bNSMenuItem\\s*\\(\\s*title:\\s*\"${literalBody}\"`,
            "g"
        );
        for (const match of source.matchAll(nativeMenuPattern)) {
            const raw = match[1];
            if (!raw.includes("\\(") && looksLikeFixedEnglishUI(raw)) {
                nativeMenuRisks.push(
                    `${path.relative(repoRoot, filePath)}:${lineNumber(source, match.index)} ${JSON.stringify(decodeEscapes(raw))}`
                );
            }
        }
        const isAgentTool = relativePath.startsWith(path.join("Agent", "Tools"));
        const patterns = isAgentTool
            ? [sourcePatterns[5]]
            : relativePath.endsWith(path.join("Help", "ShortcutsPane.swift"))
                ? [...sourcePatterns, shortcutDescriptionPattern]
                : sourcePatterns;
        for (const pattern of patterns) {
            for (const match of source.matchAll(pattern)) {
                const raw = match[1];
                const isExplicitL10nLiteral = pattern === l10nLiteralPattern;
                if (raw.includes("\\(")) {
                    const fixedShell = decodeEscapes(raw.replace(/\\\((?:\\.|[^)])*\)/g, " ")).trim();
                    if (!["fps", "x"].includes(fixedShell.toLowerCase()) && looksLikeFixedEnglishUI(fixedShell)) {
                        dynamicRisks.push(
                            `${path.relative(repoRoot, filePath)}:${lineNumber(source, match.index)} ${JSON.stringify(decodeEscapes(raw))}`
                        );
                    }
                    continue;
                }
                const value = decodeEscapes(raw);
                const location = `${path.relative(repoRoot, filePath)}:${lineNumber(source, match.index)}`;
                addCandidate(value, location, isExplicitL10nLiteral);
            }
        }
        const lines = source.split("\n");
        for (const [index, line] of lines.entries()) {
            const conditionalUIPatterns = [
                new RegExp(
                    `\\bL10n\\.(?:string|text|format)\\s*\\(\\s*[^)?\\n]{0,200}\\?\\s*"${literalBody}"\\s*:\\s*"${literalBody}"`,
                    "g"
                ),
                new RegExp(
                    `\\b(?:title|label|subtitle|message|placeholder|emptyMessage|intro|instruction|help):\\s*[^?\\n]{0,200}\\?\\s*"${literalBody}"\\s*:\\s*"${literalBody}"`,
                    "g"
                ),
            ];
            for (const pattern of conditionalUIPatterns) {
                for (const match of line.matchAll(pattern)) {
                    addCandidate(
                        decodeEscapes(match[1]),
                        `${path.relative(repoRoot, filePath)}:${index + 1}`
                    );
                    addCandidate(
                        decodeEscapes(match[2]),
                        `${path.relative(repoRoot, filePath)}:${index + 1}`
                    );
                }
            }
            if (/\b(?:editor\.)?mediaPanelToast\s*=\s*L10n\.(?:string|format)\s*\(/.test(line)) {
                typedAssignmentRisks.push(
                    `${path.relative(repoRoot, filePath)}:${index + 1} ${JSON.stringify(line.trim())}`
                );
            }
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
    return { candidates, dynamicRisks, typedAssignmentRisks, nativeMenuRisks };
}

function placeholders(value) {
    return [...value.replace(/%%/g, "").matchAll(/%(?:\d+\$)?[-+0 #'I]*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|L|z|j|t)?[@a-zA-Z]/g)]
        .map((match) => match[0]);
}

const protectedTokens = [
    "Palmier Pro", "Google", "Anthropic", "Claude", "Codex", "Cursor", "MCP", "API", "HDR", "LUT",
];
const allowedUntranslatedKeys = new Set(["AI", "Agent", "FPS", "Lottie", "MCP", "Max", "Palmier Pro", "Pro"]);
const protectedTokenExceptions = new Set(["Zoom Preview to Cursor", "Zoom to Cursor"]);

function containsProtectedToken(value, token) {
    const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return new RegExp(`(^|[^A-Za-z0-9])${escaped}(?=$|[^A-Za-z0-9])`).test(value);
}

const english = parseStrings(englishPath);
const chinese = parseStrings(chinesePath);
const englishInfo = parseStrings(englishInfoPath);
const chineseInfo = parseStrings(chineseInfoPath);
const { candidates, dynamicRisks, typedAssignmentRisks, nativeMenuRisks } = collectCandidates();

const runtimeCandidates = [
    "Ambient",
    "Available",
    "Both",
    "Cinematic",
    "Clear Search",
    "Community",
    "Gain",
    "Gamma",
    "Installed",
    "Lift",
    "Lo-fi",
    "Lottie",
    "Mic",
    "New Skill",
    "Ripple Delete (Agent)",
    "Tense",
    "Try Again",
    "Upbeat",
    "Update available",
];
for (const key of runtimeCandidates) {
    const locations = candidates.get(key) ?? [];
    locations.push("scripts/check-localization.mjs:runtimeCandidates");
    candidates.set(key, locations);
}

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

const errors = [...catalogParseErrors];

const requiredLiteralCandidates = [
    "First/Last",
    "Preparing…",
    "Downloading…",
    "Rendering…",
    "Generating…",
    "Exporting…",
    "Uploading…",
];
for (const key of requiredLiteralCandidates) {
    if (!candidates.has(key)) {
        errors.push(`直接 L10n 字面量未进入候选：${JSON.stringify(key)}`);
    }
}

const sourceGuards = [
    {
        file: path.join(sourceRoot, "UI", "SidebarRowButton.swift"),
        required: "L10n.text(label)",
        forbidden: "Text(verbatim: label)",
        error: "侧边栏固定标签必须通过 L10n 显示，不能按原文直出",
    },
    {
        file: path.join(sourceRoot, "MediaPanel", "MediaTab", "MediaTab+IndexStatus.swift"),
        required: "Text(verbatim: formattedLabel)",
        forbidden: "L10n.text(formattedLabel)",
        error: "媒体索引动态进度已完成格式化，显示层不能再次把结果当作词典键",
    },
    {
        file: path.join(sourceRoot, "MediaPanel", "MediaTab", "MediaTab+IndexStatus.swift"),
        required: "statusIndicator(L10n.string(\"Preparing…\")",
        error: "媒体索引静态状态必须先本地化，再进入统一的动态状态显示层",
    },
    {
        file: path.join(sourceRoot, "Editor", "EditorUndo.swift"),
        required: "func undoLatest() -> Bool",
        forbidden: "sourceActionNames",
        error: "Agent 撤销必须与本地化菜单标题解耦，不能按标题反查协议动作名",
    },
    {
        file: path.join(sourceRoot, "Agent", "Tools", "ToolExecutor.swift"),
        required: "Undid the latest edit.",
        forbidden: "Undid: \\(actionName)",
        error: "Agent 撤销结果必须使用稳定协议文案，不能插入本地化菜单标题",
    },
    {
        file: path.join(sourceRoot, "Agent", "Tools", "ToolExecutor+Transcription.swift"),
        required: "CostEstimator.agentFormat(cost)",
        forbidden: "CostEstimator.format(cost)) needed.",
        error: "Agent 积分错误必须保持完整英文协议，不能混入本地化积分标签",
    },
    {
        file: path.join(sourceRoot, "App", "AppNotifications.swift"),
        required: "assetType.notificationLabel",
        forbidden: "assetType.trackLabel",
        error: "生成通知必须区分 Sequence 与 Video，不能复用轨道标签",
    },
    {
        file: path.join(sourceRoot, "Generation", "UI", "GenerationView.swift"),
        required: "Text(verbatim: promptPlaceholder)",
        forbidden: "L10n.text(promptPlaceholder)",
        error: "生成提示占位符已完成本地化，显示层不能再次当作词典键解析",
    },
    {
        file: path.join(sourceRoot, "Generation", "UI", "GenerationView+References.swift"),
        required: "flashDropError(L10n.string(\"Drop image here.\"))",
        forbidden: "flashDropError(\"Drop image here.\")",
        error: "图片参考拖放类型错误必须显示本地化提示",
    },
    {
        file: path.join(sourceRoot, "Editor", "ViewModel", "EditorViewModel+Sync.swift"),
        required: "return \"Clip not found.\"",
        forbidden: "return L10n.string(\"Clip not found.\")",
        error: "同步报告由 UI 与 Agent 共用，底层失败原因必须保持一致的英文协议",
    },
    {
        file: path.join(sourceRoot, "UI", "L10n.swift"),
        required: "static func message(_ key: String, localized: Bool",
        error: "共享校验必须显式区分界面本地化文案与稳定英文协议",
    },
    {
        file: path.join(sourceRoot, "UI", "L10n.swift"),
        required: "root.appendingPathComponent(\"PalmierPro_PalmierPro.bundle\")",
        forbidden: "Bundle.module",
        error: "L10n 必须探测 SwiftPM 资源包，且不能依赖独立打包不可用的 Bundle.module",
    },
    {
        file: path.join(sourceRoot, "UI", "L10n.swift"),
        required: "Text(verbatim: string(key))",
        error: "L10n.text 必须复用带资源包回退的字符串解析",
    },
    {
        file: path.join(sourceRoot, "Editor", "ViewModel", "EditorViewModel+Ripple.swift"),
        required: "\"Clip not found: %@\",\n                localized: localized",
        error: "波纹编辑缺失片段提示必须遵守界面与 Agent 的本地化边界",
    },
    {
        file: path.join(sourceRoot, "Editor", "ViewModel", "EditorViewModel+Ripple.swift"),
        required: "\"Track index out of range: %d\",\n                localized: localized",
        error: "波纹编辑轨道越界提示必须遵守界面与 Agent 的本地化边界",
    },
    {
        file: path.join(sourceRoot, "Editor", "ViewModel", "EditorViewModel+Ripple.swift"),
        required: "\"No non-empty ranges to delete\",\n                localized: localized",
        error: "波纹编辑空范围提示必须遵守界面与 Agent 的本地化边界",
    },
    {
        file: path.join(sourceRoot, "Editor", "ViewModel", "EditorViewModel+Ripple.swift"),
        required: "localized: true\n                ) ?? reason\n            mediaPanelToast = MediaPanelToast(stringLiteral: toastReason)",
        error: "Agent 波纹编辑必须将稳定英文协议与本地化界面提示分离",
    },
    {
        file: path.join(sourceRoot, "Editor", "ViewModel", "EditorViewModel+Nesting.swift"),
        required: "func nestBlockReason(childId: String, localized: Bool = false)",
        error: "嵌套校验默认必须返回稳定英文，仅由界面调用方显式请求本地化",
    },
    {
        file: path.join(sourceRoot, "Editor", "ViewModel", "EditorViewModel+Nesting.swift"),
        required: "nestBlockReason(childId: childId, localized: true)",
        error: "嵌套界面提示必须显式请求本地化",
    },
    {
        file: path.join(sourceRoot, "Editor", "ViewModel", "EditorViewModel+Multicam.swift"),
        required: "localized: Bool = false",
        error: "多机位移动校验默认必须返回稳定英文协议",
    },
    {
        file: path.join(sourceRoot, "Generation", "Submission", "VideoGenerationSubmission.swift"),
        required: "func validate(for model: VideoModelConfig, localized: Bool = false)",
        error: "生成引用校验默认必须返回稳定英文协议",
    },
    {
        file: path.join(sourceRoot, "Generation", "UI", "GenerationView+Submit.swift"),
        required: "inputAssets.validate(for: videoModel, localized: true)",
        error: "生成界面必须显式请求本地化校验文案",
    },
    {
        file: path.join(sourceRoot, "Agent", "Tools", "ToolExecutor+Generate.swift"),
        forbidden: "localized: true",
        error: "Agent 生成工具不能请求界面语言校验文案",
    },
    {
        file: path.join(sourceRoot, "Generation", "Catalog", "VideoModelConfig.swift"),
        required: "localized: Bool = false",
        error: "视频模型校验默认必须保持英文协议",
    },
    {
        file: path.join(sourceRoot, "Generation", "Catalog", "ImageModelConfig.swift"),
        required: "localized: Bool = false",
        error: "图片模型校验默认必须保持英文协议",
    },
    {
        file: path.join(sourceRoot, "Generation", "Catalog", "AudioModelConfig.swift"),
        required: "func validate(params: AudioGenerationParams, localized: Bool = false)",
        error: "音频模型校验默认必须保持英文协议",
    },
    {
        file: path.join(sourceRoot, "Agent", "Tools", "ToolExecutor+Clips.swift"),
        required: "localized: false",
        error: "Agent 波纹编辑拒绝原因必须保持稳定英文协议",
    },
    {
        file: path.join(sourceRoot, "Agent", "Tools", "ToolExecutor+Words.swift"),
        required: "removeAllDeadAir(localized: false)",
        error: "Agent 静音移除拒绝原因必须保持稳定英文协议",
    },
    {
        file: path.join(sourceRoot, "Account", "AccountService.swift"),
        required: "case .pro: return \"Pro plan\"",
        forbidden: "return L10n.string(\"Pro plan\")",
        error: "套餐属性必须返回稳定词典键，只能由 UI 消费端本地化一次",
    },
    {
        file: path.join(sourceRoot, "Utilities", "Constants.swift"),
        required: "case .default: \"Default\"",
        forbidden: "case .default: L10n.string(\"Default\")",
        error: "布局属性必须返回稳定词典键，只能由菜单消费端本地化一次",
    },
    {
        file: path.join(sourceRoot, "Generation", "Submission", "VideoGenerationSubmission.swift"),
        required: "L10n.string(expected.trackLabel)",
        forbidden: "expected.rawValue",
        error: "生成引用类型错误必须显示本地化类型名，不能直出小写 raw value",
    },
    {
        file: path.join(sourceRoot, "Agent", "Panel", "MentionPopover.swift"),
        required: "L10n.text(asset.type.trackLabel)",
        error: "媒体类型必须通过标题形式的本地化键显示，不能直接使用小写 rawValue",
    },
    {
        file: path.join(sourceRoot, "Generation", "UI", "GenerationView+Mentions.swift"),
        required: "kindLabel: type.trackLabel",
        forbidden: "kindLabel: type.rawValue",
        error: "生成引用类型必须使用可本地化的标题键，不能直出小写 rawValue",
    },
    {
        file: path.join(sourceRoot, "App", "UpdateBadgeView.swift"),
        required: "L10n.text(\"Click to install update\")",
        forbidden: "Text(\"Click to install update\")",
        error: "更新卡片标题必须显式使用 L10n 资源包",
    },
    {
        file: path.join(sourceRoot, "App", "UpdateBadgeView.swift"),
        required: "L10n.text(\"Update\")",
        forbidden: "Label(\"Update\"",
        error: "更新项目徽标必须显式使用 L10n 资源包",
    },
    {
        file: path.join(sourceRoot, "Generation", "UI", "GenerationView+Mentions.swift"),
        required: "L10n.text(\"No matches\")",
        forbidden: "Text(\"No matches\")",
        error: "生成引用空状态必须显式使用 L10n 资源包",
    },
    {
        file: path.join(sourceRoot, "Editor", "ProjectActivityView.swift"),
        required: "L10n.text(\"Project Activity\")",
        forbidden: "Text(\"Project Activity\")",
        error: "项目活动标题必须显式使用 L10n 资源包",
    },
    {
        file: path.join(sourceRoot, "Editor", "ProjectActivityView.swift"),
        required: "L10n.text(\"No generations yet\")",
        forbidden: "Text(\"No generations yet\")",
        error: "项目活动空状态必须显式使用 L10n 资源包",
    },
    {
        file: path.join(sourceRoot, "Agent", "Tools", "ToolExecutor+Color.swift"),
        required: "throw ToolError(e.protocolDescription)",
        forbidden: "throw ToolError(e.errorDescription",
        error: "Agent LUT 错误必须保持稳定英文协议，不能透传本地化界面文案",
    },
    {
        file: path.join(sourceRoot, "Agent", "AgentMentionContext.swift"),
        required: "clipDisplayLabel(for: clip, localized: false)",
        error: "Agent 片段摘要必须使用稳定英文占位标签，不能序列化本地化 UI 文案",
    },
    {
        file: path.join(sourceRoot, "Agent", "AgentService.swift"),
        required: "clipDisplayLabel(for: clip, localized: false)",
        error: "Agent 片段引用必须使用稳定英文占位标签，不能把本地化 UI 文案写入协议名称",
    },
    {
        file: path.join(sourceRoot, "Export", "ExportView.swift"),
        required: "1 media file missing — it'll be skipped.",
        error: "缺失媒体提示必须保留单数文案",
    },
    {
        file: path.join(sourceRoot, "Export", "ExportView.swift"),
        required: "%d media files missing — they'll be skipped.",
        error: "缺失媒体提示必须保留复数文案",
    },
    {
        file: path.join(sourceRoot, "Editor", "EditorUndo.swift"),
        required: "let localizedActionName = localizeActionName(actionName)",
        error: "统一 Undo 入口必须本地化操作名称",
    },
    {
        file: path.join(sourceRoot, "Project", "HomeView.swift"),
        required: "window.title = L10n.string(\"Palmier Pro\")",
        error: "主窗口标题必须显式本地化",
    },
    {
        file: path.join(sourceRoot, "Settings", "SettingsView.swift"),
        required: "window.title = L10n.string(\"Settings\")",
        error: "设置窗口标题必须显式本地化",
    },
    {
        file: path.join(sourceRoot, "Help", "FeedbackView.swift"),
        required: "window.title = L10n.string(\"Send feedback\")",
        error: "反馈窗口标题必须显式本地化",
    },
    {
        file: path.join(sourceRoot, "Timeline", "TimelineView.swift"),
        required: "NSMenuItem(title: L10n.string(title)",
        error: "时间线上下文菜单的固定闭包标题必须显式本地化",
    },
    {
        file: path.join(sourceRoot, "Timeline", "TimelineView+AIEditMenu.swift"),
        required: "NSMenuItem(title: L10n.string(title)",
        error: "AI 编辑上下文菜单的固定闭包标题必须显式本地化",
    },
    {
        file: path.join(sourceRoot, "Account", "IdentityViews.swift"),
        required: ".clipShape(Circle())\n        .accessibilityHidden(true)",
        error: "用户头像的 SF Symbol 必须对辅助功能隐藏，并由父按钮提供本地化标签",
    },
    {
        file: path.join(sourceRoot, "Account", "IdentityViews.swift"),
        required: ".accessibilityLabel(account.isSignedIn ? L10n.string(\"Account\") : L10n.string(\"Sign in\"))",
        error: "用户头像按钮必须提供本地化辅助功能标签",
    },
    {
        file: path.join(sourceRoot, "MediaPanel", "MediaTab", "MediaTab.swift"),
        required: "Label {\n                L10n.text(accessibilityLabel)\n            } icon:",
        error: "媒体工具栏菜单必须使用本地化 Label，避免泄露 SF Symbol 英文名称",
    },
    {
        file: path.join(sourceRoot, "Generation", "UI", "GenerationView+Submit.swift"),
        required: ".accessibilityLabel(costHelpText)",
        error: "生成积分预估必须提供完整的本地化辅助功能标签",
    },
    {
        file: path.join(sourceRoot, "MediaPanel", "CaptionsTab", "CaptionTab.swift"),
        required: ".font(.system(size: AppTheme.FontSize.xs))\n                                .accessibilityHidden(true)",
        error: "字幕积分图标必须对辅助功能隐藏，避免泄露 SF Symbol 英文名称",
    },
];
for (const guard of sourceGuards) {
    const source = fs.readFileSync(guard.file, "utf8");
    if ((guard.required && !source.includes(guard.required))
        || (guard.forbidden && source.includes(guard.forbidden))) {
        errors.push(guard.error);
    }
}

for (const risk of dynamicRisks) {
    errors.push(`动态 UI 未经过 L10n.format：${risk}`);
}
for (const risk of typedAssignmentRisks) {
    errors.push(`MediaPanelToast 必须显式包装本地化字符串：${risk}`);
}
for (const risk of nativeMenuRisks) {
    errors.push(`AppKit 菜单固定标题必须显式调用 L10n.string：${risk}`);
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
