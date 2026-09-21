import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "changelogs", Path(__file__).resolve().parents[1] / "scripts/update-depiction-changelogs.py"
)
changelogs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelogs)


def release(tag="v1.0", **changes):
    return dict(
        dict(tag_name=tag, name=None, body="Fixed **tab switching**.\n",
             published_at="2026-09-20T01:02:03Z", draft=False, prerelease=False),
        **changes,
    )


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.workspace = Path(self.temp.name)
        self.original = {
            "class": "DepictionTabView", "headerImage": "https://example.test/banner.png",
            "tabs": [
                {"class": "DepictionStackView", "tabname": "Details", "views": [{"text": "Keep me"}]},
                {"class": "DepictionStackView", "tabname": "Changelog", "views": []},
            ],
        }
        for repository, relative in changelogs.DEPICTIONS.items():
            path = self.workspace / repository / relative
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(self.original), encoding="utf-8")

    def depiction_path(self, repository="Fila"):
        return self.workspace / repository / changelogs.DEPICTIONS[repository]

    def test_published_history_preserves_details_and_is_idempotent(self):
        history = [
            release("v0.9", name="Earlier", published_at="2026-09-01T00:00:00Z", body=None),
            release("v2", draft=True), release("v3", prerelease=True),
            release("v4.0-rc1"), release(),
        ]
        fetch = lambda _: history
        changed = changelogs.refresh(self.workspace, ["Fila"], fetch)
        self.assertEqual(changed, [self.depiction_path()])
        updated = json.loads(self.depiction_path().read_text())
        self.assertEqual(updated["headerImage"], self.original["headerImage"])
        self.assertEqual(updated["tabs"][0], self.original["tabs"][0])
        views = updated["tabs"][1]["views"]
        self.assertEqual(views[0]["views"][0]["text"], "v1.0")
        self.assertEqual(views[0]["views"][1]["text"], "2026-09-20")
        self.assertEqual(views[1]["markdown"], release()["body"])
        self.assertEqual(views[3]["views"][0]["text"], "Earlier")
        self.assertEqual(len(views), 5)
        self.assertEqual(changelogs.refresh(self.workspace, ["Fila"], fetch), [])
        self.assertEqual(json.loads(self.depiction_path("Inspector").read_text()), self.original)

    def test_invalid_later_response_changes_no_files(self):
        originals = {repo: self.depiction_path(repo).read_bytes() for repo in changelogs.DEPICTIONS}
        def fetch(repo):
            return [release()] if repo == "Fila" else [release(published_at="not a date")]
        with self.assertRaises(ValueError):
            changelogs.refresh(self.workspace, list(changelogs.DEPICTIONS), fetch)
        for repo, original in originals.items():
            self.assertEqual(self.depiction_path(repo).read_bytes(), original)

    def test_no_stable_releases_omits_changelog(self):
        self.assertIsNone(changelogs.changelog_tab([release(prerelease=True)], "Fila"))
        fetch = lambda _: []
        changelogs.refresh(self.workspace, ["Fila"], fetch)
        updated = json.loads(self.depiction_path().read_text())
        self.assertEqual(updated["tabs"], self.original["tabs"][:1])
        self.assertEqual(updated["headerImage"], self.original["headerImage"])
        self.assertEqual(changelogs.refresh(self.workspace, ["Fila"], fetch), [])

    @patch.object(changelogs.subprocess, "run")
    def test_general_mode_updates_arbitrary_depiction(self, run):
        path = self.workspace / "custom site.json"
        path.write_text(json.dumps(self.original))
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps([[release()]]), "")
        with patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(changelogs.main([
                "--repository", "another-owner/my-app", "--depiction", str(path),
            ]), 0)
        self.assertIn("repos/another-owner/my-app/releases?per_page=100", run.call_args.args[0])
        updated = json.loads(path.read_text())
        self.assertEqual(updated["tabs"][0], self.original["tabs"][0])
        self.assertEqual(updated["tabs"][1]["views"][1]["markdown"], release()["body"])
        self.assertEqual(json.loads(self.depiction_path().read_text()), self.original)

    def test_general_mode_rejects_invalid_argument_combinations(self):
        for argv in (
            ["--repository", "owner/repo"],
            ["--depiction", "file.json"],
            ["--repo", "Fila", "--repository", "owner/repo", "--depiction", "file.json"],
            ["--repository", "owner/repo?token=bad", "--depiction", "file.json"],
            ["--repository", "owner/..", "--depiction", "file.json"],
            ["--repository", "https://github.com/owner/repo", "--depiction", "file.json"],
        ):
            with self.subTest(argv=argv), patch("sys.stderr", new_callable=io.StringIO):
                with self.assertRaises(SystemExit) as caught:
                    changelogs.parse_arguments(argv)
                self.assertEqual(caught.exception.code, 2)

    @patch.object(changelogs.subprocess, "run")
    def test_general_mode_initial_site_without_releases(self, run):
        path = self.workspace / "initial.json"
        path.write_text(json.dumps(dict(self.original, tabs=self.original["tabs"][:1])))
        run.return_value = subprocess.CompletedProcess([], 0, "[[]]", "")
        with patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(changelogs.main([
                "--repository", "new-owner/new-repo", "--depiction", str(path),
            ]), 0)
        self.assertEqual(json.loads(path.read_text())["tabs"], self.original["tabs"][:1])

    @patch.object(changelogs.subprocess, "run")
    def test_paginated_api(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps([[release()], [release("v0.9")]]), "")
        self.assertEqual(len(changelogs.fetch_releases("Fila")), 2)
        self.assertIn("--paginate", run.call_args.args[0])
        self.assertIn("--slurp", run.call_args.args[0])

    @patch.object(changelogs.subprocess, "run")
    def test_api_failure_does_not_expose_output(self, run):
        run.return_value = subprocess.CompletedProcess([], 1, "private output", "secret token")
        with self.assertRaises(ValueError) as caught:
            changelogs.fetch_releases("Fila")
        self.assertNotIn("secret", str(caught.exception))
        self.assertNotIn("private", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
