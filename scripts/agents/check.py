#!/usr/bin/env python3

from pathlib import Path
import glob
import json
import re
import sys
from urllib.parse import unquote, urlsplit


ROOT_BYTE_LIMIT = 8000
ROOT_LINE_LIMIT = 100
POLICY_LINE_LIMIT = 50
SKILL_LINE_LIMIT = 80
DISPATCHER_LINE_LIMIT = 20
REQUIRED_FILES = ("AGENTS.md", "CLAUDE.md", ".cursor/BUGBOT.md", "docs/agents/README.md")
REPOSITORY_PREFIXES = ("Sources/", "Tests/", "docs/", "scripts/", ".agents/", ".cursor/", "mcpb/", "Plugins/", "Metal/")
ROOT_FILE_NAMES = ("AGENTS.md", "CLAUDE.md", "Package.swift", "Package.resolved", ".swift-version")
LINK_PATTERN = re.compile(r"(?<!!)\[[^\]\n]*\]\(([^)\s]+)\)")
CODE_PATTERN = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")
SKILL_NAME_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")


def frontmatter(text: str) -> dict[str, object]:
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise ValueError("missing frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        raise ValueError("unterminated frontmatter") from error
    fields = {}
    for line in lines[1:end]:
        if not line.strip():
            continue
        match = re.fullmatch(r"([a-zA-Z][\w-]*):\s*(.*)", line)
        if not match:
            raise ValueError("frontmatter must use flat scalar key: value entries")
        key, value = match.groups()
        if key in fields:
            raise ValueError(f"duplicate frontmatter field: {key}")
        if value.startswith('"'):
            try:
                value = json.loads(value)
            except json.JSONDecodeError as error:
                raise ValueError(f"invalid double-quoted scalar: {key}") from error
        elif value.startswith("'"):
            if not re.fullmatch(r"'(?:[^']|'')*'", value):
                raise ValueError(f"invalid single-quoted scalar: {key}")
            value = value[1:-1].replace("''", "'")
        elif value in ("true", "false"):
            value = value == "true"
        elif value in ("null", "~"):
            value = None
        elif value and (value[0] in "[{>|&*!" or re.search(r":\s|\s#", value) or re.fullmatch(r"[-+]?\d+(?:\.\d+)?", value)):
            raise ValueError(f"quote complex or numeric scalar: {key}")
        fields[key] = value
    return fields


def local_references(root: Path, path: Path, text: str) -> list[tuple[Path, str]]:
    references = []
    for target in LINK_PATTERN.findall(text):
        if not target.startswith("#") and not urlsplit(target).scheme:
            references.append((path.parent, unquote(target.split("#", 1)[0])))
    for target in CODE_PATTERN.findall(text):
        if not any(character.isspace() for character in target) and (
            target in ROOT_FILE_NAMES or target.startswith(REPOSITORY_PREFIXES)
        ):
            references.append((root, target))
    return references


def resolve_reference(root: Path, base: Path, target: str) -> list[Path]:
    candidate = (base / target).resolve()
    if candidate != root and root not in candidate.parents:
        raise ValueError(f"reference escapes repository: {target}")
    if glob.has_magic(target):
        return list(root.glob(candidate.relative_to(root).as_posix()))
    return [candidate] if candidate.exists() else []


def check_guidance(root: Path) -> list[str]:
    root = root.resolve()
    errors = []
    policies = sorted(root.glob("docs/agents/rules/*.md"))
    skills = sorted(root.glob(".agents/skills/**/SKILL.md"))
    dispatchers = sorted(root.glob(".cursor/rules/**/*.mdc"))
    paths = sorted({root / name for name in REQUIRED_FILES} | set(root.glob("docs/agents/**/*.md")) | set(skills) | set(dispatchers))
    for label, collection in (("policies", policies), ("skills", skills), ("scoped dispatchers", dispatchers)):
        if not collection:
            errors.append(f"missing project {label}")
    texts = {}
    referenced_by_root = set()
    seen_skill_names = set()
    for path in paths:
        relative = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            errors.append(f"{relative}: cannot read guidance ({error})")
            continue
        texts[path] = text
        line_limit = None
        if relative == "AGENTS.md":
            line_limit = ROOT_LINE_LIMIT
            if len(text.encode("utf-8")) > ROOT_BYTE_LIMIT:
                errors.append(f"{relative}: exceeds {ROOT_BYTE_LIMIT}-byte always-on budget")
        elif path in policies:
            line_limit = POLICY_LINE_LIMIT
        elif path in skills:
            line_limit = SKILL_LINE_LIMIT
        elif path in dispatchers:
            line_limit = DISPATCHER_LINE_LIMIT
        if line_limit and len(text.splitlines()) > line_limit:
            errors.append(f"{relative}: exceeds {line_limit}-line budget")
        for base, target in local_references(root, path, text):
            try:
                resolved = resolve_reference(root, base, target)
            except (OSError, ValueError) as error:
                errors.append(f"{relative}: {error}")
                continue
            if not resolved:
                errors.append(f"{relative}: missing reference: {target}")
            if relative == "AGENTS.md":
                referenced_by_root.update(resolved)
        if path not in skills and path not in dispatchers:
            continue
        try:
            fields = frontmatter(text)
        except ValueError as error:
            errors.append(f"{relative}: {error}")
            continue
        description = fields.get("description")
        if not isinstance(description, str) or not description.strip() or len(description) > 1024:
            errors.append(f"{relative}: description must be a nonempty string of at most 1024 characters")
        if path in skills:
            name = fields.get("name")
            if not isinstance(name, str) or len(name) > 64 or not SKILL_NAME_PATTERN.fullmatch(name) or name != path.parent.name:
                errors.append(f"{relative}: skill name must match its lowercase kebab-case directory (1-64 characters)")
            elif name in seen_skill_names:
                errors.append(f"{relative}: duplicate skill ID: {name}")
            else:
                seen_skill_names.add(name)
            invocation_disabled = fields.get("disable-model-invocation", False)
            if not isinstance(invocation_disabled, bool):
                errors.append(f"{relative}: disable-model-invocation must be a boolean")
            elif invocation_disabled:
                errors.append(f"{relative}: project workflow is hidden from automatic discovery")
        else:
            if fields.get("alwaysApply") is not False:
                errors.append(f"{relative}: dispatcher must set alwaysApply: false")
            patterns = fields.get("globs")
            if not isinstance(patterns, str) or not patterns.strip():
                errors.append(f"{relative}: dispatcher needs nonempty globs")
                continue
            for pattern in patterns.split(","):
                pattern = pattern.strip()
                try:
                    matches = resolve_reference(root, root, pattern) if pattern else []
                except (OSError, ValueError) as error:
                    errors.append(f"{relative}: {error}")
                    continue
                if not matches:
                    errors.append(f"{relative}: glob matches no repository paths: {pattern}")
    for path in policies + skills:
        if path.resolve() not in referenced_by_root:
            errors.append(f"{path.relative_to(root)}: missing explicit AGENTS.md route")
    claude = texts.get(root / "CLAUDE.md")
    if claude is not None and claude.strip() != "@AGENTS.md":
        errors.append("CLAUDE.md: import AGENTS.md only; do not duplicate policy")
    return errors


def main(root: Path) -> int:
    errors = check_guidance(root)
    if errors:
        for error in errors:
            print(f"ERROR {error}", file=sys.stderr)
        return 1
    skills = len(list(root.glob(".agents/skills/**/SKILL.md")))
    dispatchers = len(list(root.glob(".cursor/rules/**/*.mdc")))
    size = (root / "AGENTS.md").stat().st_size
    print(f"Agent guidance OK: {skills} skills, {dispatchers} scoped dispatchers; AGENTS.md {size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(__file__).resolve().parents[2]))
