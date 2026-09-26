"""Check change routing and stale/unmapped-document detection in a temporary repo."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("doc_impact", ROOT / "tools/doc_impact.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class DocImpactTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Maintenance Test")
        self.git("config", "user.email", "maintenance@example.invalid")
        for path in ("src/installer.lua", "docs/installer.md", "docs/results/old.md", "build/artifact.lua", "build/release.md"):
            self.write(path, "fixture\n" * 20)
        self.write(".gitignore", "__pycache__/\n")
        self.data = {
            "schema_version": 1, "policy": {},
            "external_surfaces": {"release": {"description": "Release body", "maintained": [
                {"tag": "v1.0.0", "source": "build/release.md"}]}},
            "coverage": {"include": ["docs/**", "src/**"], "exclude": ["**/__pycache__/**"]},
            "groups": [
                {"id": "installer", "title": "Installer", "triggers": ["src/installer.lua"],
                 "authority": ["src/installer.lua"], "review": ["docs/installer.md"],
                 "artifacts": ["build/artifact.lua"], "historical": ["docs/results/*.md"],
                 "external": ["release"], "checks": ["Review progress text; preserve old evidence."]},
                {"id": "maintenance", "title": "Maintenance", "triggers": ["docs/map.json"],
                 "authority": ["docs/map.json"], "review": [], "artifacts": [],
                 "historical": [], "external": [], "checks": []}
            ]
        }
        self.save()
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True).stdout.decode()

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def save(self):
        self.write("docs/map.json", json.dumps(self.data))

    def run_cli(self, *args):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = helper.main(["--root", str(self.root), "--map", "docs/map.json", *args])
        return code, json.loads(output.getvalue() if code == 0 else errors.getvalue())

    def test_topic_and_path_routes_include_current_and_historical_context(self):
        for arguments in (("--topic", "installer"), ("src/installer.lua",),
                          ("docs/installer.md",), ("docs/results/old.md",), ("build/artifact.lua",)):
            with self.subTest(arguments=arguments):
                code, result = self.run_cli(*arguments)
                self.assertEqual(code, 0)
                self.assertEqual(result["review_status"], "not_checked")
                group = result["groups"][0]
                self.assertEqual(group["id"], "installer")
                self.assertEqual(group["review"], ["docs/installer.md"])
                self.assertEqual(group["historical"], ["docs/results/*.md"])
                self.assertEqual(group["checks"], self.data["groups"][0]["checks"])
                self.assertIn("release", result["external_surfaces"])

    def test_repeat_topics_and_paths_do_not_duplicate_groups(self):
        code, result = self.run_cli("--topic", "installer", "--topic", "installer", "src/installer.lua")
        self.assertEqual(code, 0)
        self.assertEqual(len(result["groups"]), 1)

    def test_check_uses_tracked_and_untracked_inventory_without_writing(self):
        before = self.git("status", "--porcelain")
        code, result = self.run_cli("--check")
        self.assertEqual(code, 0)
        self.assertEqual(result["validation"], {"map_valid": True, "covered_files": 4, "content_checks_performed": False})
        self.assertEqual(before, self.git("status", "--porcelain"))
        self.write("docs/new-topic.md", "unmapped\n")
        code, result = self.run_cli("--check")
        self.assertEqual(code, 2)
        self.assertIn("unmapped relevant file: docs/new-topic.md", result["error"])

    def test_missing_reference_is_reported(self):
        (self.root / "docs/installer.md").unlink()
        code, result = self.run_cli("--check")
        self.assertEqual(code, 2)
        self.assertIn("no file matches docs/installer.md", result["error"])

    def test_missing_external_maintained_source_is_reported_without_group_reference(self):
        (self.root / "build/release.md").unlink()
        code, result = self.run_cli("--check")
        self.assertEqual(code, 2)
        self.assertIn("release.maintained: missing source build/release.md", result["error"])

    def test_external_maintained_schema(self):
        for maintained in ("not-list", ["not-object"], [{"tag": "v1.0.0"}],
                           [{"tag": "v1.0.0", "source": "build/release.md"}] * 2):
            with self.subTest(maintained=maintained):
                self.data["external_surfaces"]["release"]["maintained"] = maintained
                self.save()
                code, result = self.run_cli("--check")
                self.assertEqual(code, 2)
                self.assertIn("error", result)

    def test_unmapped_changed_path_and_unknown_topic_fail(self):
        for arguments in (("docs/unmapped.md",), ("--topic", "missing")):
            with self.subTest(arguments=arguments):
                code, result = self.run_cli(*arguments)
                self.assertEqual(code, 2)
                self.assertIn("error", result)

    def test_schema_errors_do_not_silently_omit_links(self):
        for mutate, expected in (
                (lambda d: d.update(schema_version=2), "schema_version"),
                (lambda d: d["groups"].append(dict(d["groups"][0])), "unique"),
                (lambda d: d["groups"][0].update(external=["missing"]), "external"),
                (lambda d: d["groups"][0].update(review="docs/installer.md"), "array"),
                (lambda d: d["groups"][0].update(review=["../outside.md"]), "repository-relative")):
            with self.subTest(expected=expected):
                original = json.loads(json.dumps(self.data))
                mutate(self.data)
                self.save()
                code, result = self.run_cli("--check")
                self.assertEqual(code, 2)
                self.assertIn(expected, result["error"])
                self.data = original

    def test_diff_keeps_old_and_new_rename_paths_and_untracked_files(self):
        self.git("mv", "docs/installer.md", "docs/renamed.md")
        self.write("docs/results/new report.md", "untracked report\n")
        self.write("docs/__pycache__/cache.pyc", "ignored\n")
        paths = helper.diff_paths(self.root, "HEAD")
        self.assertEqual(paths, ["docs/installer.md", "docs/renamed.md", "docs/results/new report.md"])
        # The new name must be deliberately mapped before review can proceed.
        code, result = self.run_cli("--diff", "HEAD")
        self.assertEqual(code, 2)
        self.assertIn("docs/renamed.md", result["error"])
        self.data["groups"][0]["review"].append("docs/renamed.md")
        self.save()
        code, result = self.run_cli("--diff", "HEAD")
        self.assertEqual(code, 0)
        self.assertEqual({g["id"] for g in result["groups"]}, {"installer", "maintenance"})
        self.assertIn("docs/installer.md", result["changed_paths"])
        self.assertIn("docs/renamed.md", result["changed_paths"])

    def test_list_and_missing_map(self):
        code, result = self.run_cli("--list")
        self.assertEqual(code, 0)
        self.assertEqual([t["id"] for t in result["topics"]], ["installer", "maintenance"])
        (self.root / "docs/map.json").unlink()
        code, result = self.run_cli("--check")
        self.assertEqual(code, 2)
        self.assertIn("map.json", result["error"])

    def test_diff_rejects_unknown_reference_and_git_option_injection(self):
        for reference in ("missing-ref", "--output=unexpected-write"):
            with self.subTest(reference=reference):
                code, result = self.run_cli("--diff=" + reference)
                self.assertEqual(code, 2)
                self.assertIn("error", result)
        self.assertFalse((self.root / "unexpected-write").exists())


if __name__ == "__main__":
    unittest.main()
