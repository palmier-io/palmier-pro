from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import tempfile
import unittest

import check


class GuidanceCheckTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="compositor-agent-guidance-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.root_text = "# Project\n[Policy](docs/agents/rules/swift.md)\n[Skill](.agents/skills/compositor-change/SKILL.md)\n"
        self.write("AGENTS.md", self.root_text)
        self.write("CLAUDE.md", "@AGENTS.md\n")
        self.write(".cursor/BUGBOT.md", "Read `AGENTS.md`.\n")
        self.write("docs/agents/README.md", "Read `AGENTS.md`.\n")
        self.write("docs/agents/rules/swift.md", "Read `Sources/CompositorPro/Example.swift`.\n")
        self.write("Sources/CompositorPro/Example.swift", "struct Example {}\n")
        self.skill = ".agents/skills/compositor-change/SKILL.md"
        self.dispatcher = ".cursor/rules/swift.mdc"
        self.skill_text = "---\nname: compositor-change\ndescription: Implements project changes.\n---\nRead `AGENTS.md`.\n"
        self.dispatcher_text = "---\ndescription: Swift safety.\nglobs: Sources/CompositorPro/**/*.swift\nalwaysApply: false\n---\nRead `docs/agents/rules/swift.md`.\n"
        self.write(self.skill, self.skill_text)
        self.write(self.dispatcher, self.dispatcher_text)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def expect_error(self, fragment):
        errors = check.check_guidance(self.root)
        self.assertTrue(any(fragment in error for error in errors), errors)

    def test_valid_guidance_resolves_root_and_relative_links(self):
        self.write("docs/agents/README.md", "[Policy](rules/swift.md)\n[External](https://example.com/missing.md)\n")
        self.assertEqual(check.check_guidance(self.root), [])

    def test_required_file_failure_is_reported(self):
        (self.root / "CLAUDE.md").unlink()
        self.expect_error("CLAUDE.md: cannot read guidance")

    def test_root_byte_budget_cannot_grow_silently(self):
        with (self.root / "AGENTS.md").open("a", encoding="utf-8") as file:
            file.write("x" * check.ROOT_BYTE_LIMIT)
        self.expect_error("always-on budget")

    def test_root_line_budget_is_independent_of_byte_budget(self):
        with (self.root / "AGENTS.md").open("a", encoding="utf-8") as file:
            file.write("\n" * check.ROOT_LINE_LIMIT)
        self.expect_error(f"exceeds {check.ROOT_LINE_LIMIT}-line budget")

    def test_missing_code_and_markdown_references_fail(self):
        for text in ("Read `Sources/CompositorPro/Missing.swift`.\n", "[Missing](rules/missing.md)\n"):
            with self.subTest(text=text):
                self.write("docs/agents/README.md", text)
                self.expect_error("missing reference")

    def test_glob_references_require_a_real_match(self):
        self.write("docs/agents/README.md", "Read `Sources/CompositorPro/Missing*.swift`.\n")
        self.expect_error("missing reference")

    def test_policy_and_skill_need_explicit_root_routes(self):
        for route in ("[Policy]", "[Skill]"):
            with self.subTest(route=route):
                self.write("AGENTS.md", "".join(line for line in self.root_text.splitlines(keepends=True) if route not in line))
                self.expect_error("missing explicit AGENTS.md route")

    def test_invalid_skill_name_cannot_pass_discovery_checks(self):
        for name in ("DifferentName", "different-name", "x" * 65):
            with self.subTest(name=name):
                self.write(self.skill, self.skill_text.replace("name: compositor-change", f"name: {name}"))
                self.expect_error("skill name must match")

    def test_skill_description_must_be_nonempty_string(self):
        for description in ("", "false", "null", "x" * 1025):
            with self.subTest(description=description):
                self.write(self.skill, self.skill_text.replace("Implements project changes.", description))
                self.expect_error("description must be")

    def test_hidden_workflow_fails(self):
        self.write(self.skill, self.skill_text.replace("name: compositor-change", "disable-model-invocation: true\nname: compositor-change"))
        self.expect_error("hidden from automatic discovery")

    def test_invocation_flag_cannot_be_a_string(self):
        self.write(self.skill, self.skill_text.replace("name: compositor-change", 'disable-model-invocation: "false"\nname: compositor-change'))
        self.expect_error("disable-model-invocation must be a boolean")

    def test_duplicate_path_derived_skill_ids_fail(self):
        self.write(".agents/skills/team/compositor-change/SKILL.md", self.skill_text)
        self.expect_error("duplicate skill ID: compositor-change")

    def test_invalid_frontmatter_is_reported_without_crashing(self):
        for text, expected in (
            ("name: compositor-change\n", "missing frontmatter"),
            ("---\nname: compositor-change\n", "unterminated frontmatter"),
            (self.skill_text.replace("name: compositor-change", "name: compositor-change\nname: compositor-change"), "duplicate frontmatter field"),
            (self.skill_text.replace("Implements project changes.", "Unsafe: scalar"), "quote complex"),
            (self.skill_text.replace("Implements project changes.", '"Invalid "quote""'), "invalid double-quoted scalar"),
            (self.skill_text.replace("Implements project changes.", "'Invalid 'quote''"), "invalid single-quoted scalar"),
        ):
            with self.subTest(expected=expected):
                self.write(self.skill, text)
                self.expect_error(expected)

    def test_quoted_descriptions_preserve_scalar_text(self):
        for description in ('"Safe: description"', "'Native Mac''s rules'"):
            with self.subTest(description=description):
                self.write(self.skill, self.skill_text.replace("Implements project changes.", description))
                self.assertEqual(check.check_guidance(self.root), [])

    def test_dispatcher_cannot_become_always_on(self):
        self.write(self.dispatcher, self.dispatcher_text.replace("alwaysApply: false", "alwaysApply: true"))
        self.expect_error("must set alwaysApply: false")

    def test_dispatcher_globs_must_be_nonempty_and_match(self):
        for pattern in ("", "Sources/Missing/**/*.swift", "Sources/CompositorPro/**/*.swift,"):
            with self.subTest(pattern=pattern):
                self.write(self.dispatcher, self.dispatcher_text.replace("Sources/CompositorPro/**/*.swift", pattern))
                self.expect_error("nonempty globs" if not pattern else "glob matches no repository paths")

    def test_policy_skill_and_dispatcher_size_budgets(self):
        for path, text, limit in (
            ("docs/agents/rules/swift.md", "Policy\n", check.POLICY_LINE_LIMIT),
            (self.skill, self.skill_text, check.SKILL_LINE_LIMIT),
            (self.dispatcher, self.dispatcher_text, check.DISPATCHER_LINE_LIMIT),
        ):
            with self.subTest(path=path):
                self.write(path, text + "\n" * limit)
                self.expect_error(f"exceeds {limit}-line budget")
                self.write(path, text)

    def test_local_reference_cannot_escape_repository(self):
        self.write("docs/agents/README.md", "[Outside](../../../outside.md)\n")
        self.expect_error("reference escapes repository")

    def test_claude_import_cannot_duplicate_policy(self):
        self.write("CLAUDE.md", "@AGENTS.md\nExtra independent policy.\n")
        self.expect_error("import AGENTS.md only")

    def test_cli_failure_returns_nonzero_and_diagnostics(self):
        self.write("docs/agents/README.md", "[Missing](missing.md)\n")
        output = io.StringIO()
        with redirect_stderr(output):
            status = check.main(self.root)
        self.assertEqual(status, 1)
        self.assertIn("ERROR", output.getvalue())
        self.assertIn("missing reference", output.getvalue())

    def test_cli_success_reports_validated_counts(self):
        output = io.StringIO()
        with redirect_stdout(output):
            status = check.main(self.root)
        self.assertEqual(status, 0)
        self.assertIn("Agent guidance OK: 1 skills, 1 scoped dispatchers", output.getvalue())


if __name__ == "__main__":
    unittest.main()
