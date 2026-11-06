"""Declarative event and trust-boundary contracts for milestone workflows."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


def load(relative):
    return yaml.safe_load((ROOT / relative).read_text())


class WorkflowContract(unittest.TestCase):
    def test_release_caller_supports_publication_version_tags_and_manual_recovery(self):
        workflow = load("docs/release-milestone-caller.example.yml")
        events = workflow.get("on", workflow.get(True))
        self.assertEqual(events["release"]["types"], ["published"])
        self.assertEqual(events["push"]["tags"], ["v*.*.*", "[0-9]*.[0-9]*.[0-9]*", "*-v*.*.*"])
        recovery = events["workflow_dispatch"]["inputs"]
        self.assertTrue(recovery["tag"]["required"])
        self.assertTrue(recovery["dry_run"]["default"])
        self.assertIn("version", recovery)
        self.assertIn("previous_tag", recovery)
        # The reusable workflow alone owns serialization: identical groups deadlock.
        self.assertNotIn("concurrency", workflow)

    def test_privileged_guards_execute_only_embedded_metadata_scripts(self):
        for filename in ["pr-milestone.yml", "release-milestone.yml"]:
            workflow = load(".github/workflows/" + filename)
            for job in workflow["jobs"].values():
                for step in job["steps"]:
                    self.assertNotIn("run", step)
                    self.assertEqual(step.get("uses"), "actions/github-script@v7")
                    self.assertNotIn("secrets.", str(step))


if __name__ == "__main__":
    unittest.main()
