#!/usr/bin/env bash
set -euo pipefail
mute_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$mute_script_dir/verify-mute-state.sh" "$@" <<'MUTE_TESTS_PY'
"""Tests for group selection and report verdicts. These tests do not access Messages data."""

import sys
import types
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from unittest.mock import patch

script_path = Path(sys.argv[1]).resolve()
sys.argv = [sys.argv[0], *sys.argv[2:]]
source = script_path.read_text().split("<<'MUTE_DRIVER_PY'\n", 1)[1].split("\nMUTE_DRIVER_PY", 1)[0]
helper = types.ModuleType("mute_verification")
helper.__file__ = str(script_path)
exec(compile(source, str(script_path), "exec"), helper.__dict__)


class GroupSelectionTests(unittest.TestCase):
    def test_native_names_override_stale_database_names(self):
        rows = [{"guid": "iMessage;+;first", "display_name": "Old name"}]
        chats = [{"guid": "iMessage;+;first", "name": "Weekend plans", "members": ["Alex", "Sam"]}]
        named = helper.attach_group_names(rows, chats)[0]
        self.assertEqual(named["selection_name"], "Weekend plans")
        self.assertEqual(named["name_source"], "Messages")
        self.assertEqual(named["guid"], rows[0]["guid"])

    def test_unnamed_native_group_uses_participant_names(self):
        rows = [{"guid": "iMessage;+;first", "display_name": "Removed name"}]
        chats = [{"guid": "iMessage;+;first", "name": "", "members": ["Alex", "Sam"]}]
        named = helper.attach_group_names(rows, chats)[0]
        self.assertEqual(named["selection_name"], "Alex, Sam")
        self.assertEqual(named["name_source"], "Messages participants")

    def test_service_prefix_fallback_preserves_the_database_identity(self):
        rows = [{"guid": "any;+;first", "group_id": "dnd-first", "display_name": ""}]
        chats = [{"guid": "iMessage;+;first", "name": "Weekend plans", "members": []}]
        named = helper.attach_group_names(rows, chats)[0]
        self.assertEqual(named["selection_name"], "Weekend plans")
        self.assertEqual(named["guid"], "any;+;first")
        self.assertEqual(named["group_id"], "dnd-first")

    def test_ambiguous_service_prefix_fallback_does_not_assign_a_native_name(self):
        rows = [{"guid": "any;+;first", "display_name": "Database title"}]
        chats = [{"guid": "iMessage;+;first", "name": "One", "members": []},
                 {"guid": "SMS;+;first", "name": "Two", "members": []}]
        named = helper.attach_group_names(rows, chats)[0]
        self.assertEqual(named["selection_name"], "Database title")
        self.assertEqual(named["name_source"], "database")

    def test_duplicate_names_remain_distinct_selections(self):
        rows = [{"guid": "iMessage;+;first", "selection_name": "Weekend plans", "member_names": ["Alex"]},
                {"guid": "iMessage;+;second", "selection_name": "Weekend plans", "member_names": ["Sam"]}]
        with patch("builtins.input", side_effect=["d 2", "2"]), \
             patch("sys.stdout", new_callable=io.StringIO) as output:
            selected = helper.choose_group(rows)
        self.assertEqual(selected["guid"], "iMessage;+;second")
        self.assertIn("Participants: Sam", output.getvalue())

    def test_name_search_keeps_identifiers_out_of_the_menu(self):
        rows = [{"guid": "iMessage;+;first", "selection_name": "Work", "member_names": ["Alex"],
                 "participants": "alex@example.com"},
                {"guid": "iMessage;+;second", "selection_name": "Weekend plans", "member_names": ["Sam"],
                 "participants": "+15555550123"}]
        for search in ("weekEND", "sAm"):
            with self.subTest(search=search), \
                 patch("builtins.input", side_effect=[search, "1"]), \
                 patch("sys.stdout", new_callable=io.StringIO) as output:
                selected = helper.choose_group(rows)
            self.assertEqual(selected["guid"], "iMessage;+;second")
            self.assertIn("Weekend plans", output.getvalue())
            for private_value in ("iMessage;+;", "alex@example.com", "+15555550123"):
                self.assertNotIn(private_value, output.getvalue())

    def test_automation_denial_has_permission_instructions(self):
        denied = helper.subprocess.CompletedProcess([], 1, "", "Not authorized to send Apple events. (-1743)")
        with patch.object(helper.subprocess, "run", return_value=denied), \
             patch.dict(helper.os.environ, {"TERM_PROGRAM": "Apple_Terminal"}), \
             patch("sys.stdout", new_callable=io.StringIO):
            with self.assertRaisesRegex(RuntimeError, "Automation") as raised:
                helper.group_names_from_messages([])
        self.assertIn("Enable Messages under Terminal.app.", str(raised.exception))


class TimingTests(unittest.TestCase):
    def test_samples_are_classified_without_guessing_across_boundaries(self):
        result = {"apiCompletedAt": 10, "disposeStartedAt": 15}
        for start, end, expected in (
            (8, 9, "before-api-return"),
            (11, 12, "before-cleanup"),
            (16, 17, "after-cleanup-start"),
            (9, 11, "boundary-overlap"),
            (14, 16, "boundary-overlap"),
        ):
            with self.subTest(start=start, end=end):
                sample = {"startedAt": helper.datetime.datetime.fromtimestamp(start, helper.datetime.timezone.utc).isoformat(),
                          "at": helper.datetime.datetime.fromtimestamp(end, helper.datetime.timezone.utc).isoformat(),
                          "muted": True, "disk": {"muted": True}}
                summaries = helper.timing_summary(result, [sample], True)
                self.assertEqual([summary["phase"] for summary in summaries], [expected, expected])

    def test_userdefaults_and_disk_can_match_at_different_times(self):
        result = {"apiCompletedAt": 10, "disposeStartedAt": 15}
        samples = [
            {"startedAt": "1970-01-01T00:00:08+00:00", "at": "1970-01-01T00:00:09+00:00",
             "muted": True, "disk": {"muted": False}},
            {"startedAt": "1970-01-01T00:00:11+00:00", "at": "1970-01-01T00:00:12+00:00",
             "muted": True, "disk": {"muted": True}},
        ]
        summaries = helper.timing_summary(result, samples, True)
        self.assertEqual(summaries[0]["phase"], "before-api-return")
        self.assertEqual(summaries[1]["phase"], "before-cleanup")

    def test_unknown_samples_do_not_match_an_unmute_request(self):
        result = {"apiCompletedAt": 10, "disposeStartedAt": 15}
        samples = [{"muted": None, "disk": {"status": "unavailable"}}, {"observerError": "fixture error"}]
        summaries = helper.timing_summary(result, samples, False)
        self.assertEqual([summary["phase"] for summary in summaries], ["no-match", "no-match"])


class VerdictTests(unittest.TestCase):
    def test_error_and_matching_final_state_remain_distinct(self):
        verdict = helper.assess({"muted": False}, {"ok": False}, {"muted": True}, True, False)
        self.assertTrue(verdict.startswith("FAIL:"))
        self.assertIn("final observed state matches", verdict)

    def test_independent_observation_occurs_before_mutation_returns(self):
        api_started = threading.Event()
        observed = threading.Event()
        state = {"fda": "authorized", "accessibility": "authorized", "muted": True, "dndReadable": True}

        def mutate(*args, **kwargs):
            api_started.set()
            if not observed.wait(5):
                raise RuntimeError("The observer did not run during the mutation.")
            return {"ok": False, "dndReads": 30}, "mutation log"

        def read_state(*args):
            self.assertTrue(api_started.wait(5))
            observed.set()
            return state

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(helper, "invoke", side_effect=mutate), \
                 patch.object(helper, "snapshot", side_effect=read_state), \
                 patch("sys.stdout", new_callable=io.StringIO):
                result, output, samples = helper.monitored_mutation(
                    Path("probe"), ["mutate"], "fixture", directory, "operation", False, 5)
            events = [json.loads(line) for line in (directory / "observations.jsonl").read_text().splitlines()]
        self.assertFalse(result["ok"])
        self.assertEqual(output, "mutation log")
        self.assertTrue(samples[0]["muted"])
        self.assertEqual(events[0]["event"], "during-operation-sample")
        self.assertEqual(events[0]["operation"], "operation")

    def test_old_probe_is_rejected_before_access_to_messages(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            probe = directory / "mute-state-probe"
            probe.with_name("mute-state-probe-metadata.json").write_text(json.dumps({"sourceCommit": "old"}))
            with patch.object(helper.tempfile, "mkdtemp", return_value=temporary), \
                 patch.object(helper.sys, "argv", ["verify-mute-state.sh", "--probe", str(probe)]), \
                 patch.object(helper, "groups") as groups, \
                 patch.object(helper, "invoke") as invoke, \
                 patch("sys.stdout", new_callable=io.StringIO), \
                 patch("sys.stderr", new_callable=io.StringIO):
                self.assertEqual(helper.main(), 1)
            groups.assert_not_called()
            invoke.assert_not_called()
            error = json.loads((directory / "observations.jsonl").read_text())
            self.assertIn("window isolation", error["error"])

    def test_window_verification_does_not_start_a_mute_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            probe = directory / "mute-state-probe"
            probe.with_name("mute-state-probe-metadata.json").write_text(
                json.dumps({"probeConfiguration": helper.PROBE_CONFIGURATION}))
            with patch.object(helper.tempfile, "mkdtemp", return_value=temporary), \
                 patch.object(helper.sys, "argv", ["verify-mute-state.sh", "--probe", str(probe), "--verify-window"]), \
                 patch.object(helper, "groups") as groups, \
                 patch.object(helper, "session") as session, \
                 patch.object(helper, "invoke", return_value=({"ok": True}, "window log")) as invoke, \
                 patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(helper.main(), 0)
            groups.assert_not_called()
            session.assert_not_called()
            self.assertEqual(invoke.call_args.args[1][0], "verify-window")

    def test_os_denial_identifies_the_terminal_permission(self):
        with patch.object(Path, "open", side_effect=PermissionError(1, "Operation not permitted")), \
             patch.dict(helper.os.environ, {"TERM_PROGRAM": "Apple_Terminal"}):
            with self.assertRaisesRegex(RuntimeError, "Full Disk Access") as raised:
                helper.groups()
        self.assertIn("Enable Terminal.app.", str(raised.exception))

    def test_sqlite_denial_has_permission_instructions(self):
        with patch.object(Path, "open"), \
             patch.object(sqlite3, "connect", side_effect=sqlite3.OperationalError("authorization denied")):
            with self.assertRaisesRegex(RuntimeError, "Full Disk Access"):
                helper.groups()

    def test_other_database_errors_remain_distinct(self):
        with patch.object(Path, "open"), \
             patch.object(sqlite3, "connect", side_effect=sqlite3.OperationalError("database disk image is malformed")):
            with self.assertRaises(sqlite3.OperationalError):
                helper.groups()

    def test_denial_stops_before_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(helper.tempfile, "mkdtemp", return_value=directory), \
                 patch.object(helper.sys, "argv", ["verify-mute-state.sh"]), \
                 patch.object(helper.sys.stdin, "isatty", return_value=True), \
                 patch.object(helper, "groups", side_effect=helper.messages_access_error("fixture denial")), \
                 patch.object(helper, "build_probe") as build, \
                 patch("sys.stdout", new_callable=io.StringIO), \
                 patch("sys.stderr", new_callable=io.StringIO):
                self.assertEqual(helper.main(), 1)
            build.assert_not_called()
            error = json.loads((Path(directory) / "observations.jsonl").read_text())
            self.assertEqual(error["event"], "error")
            self.assertIn("Full Disk Access", error["error"])

    def test_forced_failure_success_is_a_defect_even_when_state_matches(self):
        result = {"ok": True, "fda": "authorized", "forced": True, "dndReads": 1}
        verdict = helper.assess({"muted": False}, result, {"muted": True}, True, True)
        self.assertTrue(verdict.startswith("REPRODUCED:"))

    def test_missing_permission_does_not_prove_the_fallback_defect(self):
        result = {"ok": False, "fda": "denied", "forced": True, "dndReads": 0, "preflight": False}
        verdict = helper.assess({"muted": False}, result, {"muted": False}, True, True)
        self.assertTrue(verdict.startswith("INCONCLUSIVE:"))

    def test_ax_error_does_not_count_as_a_successful_guard(self):
        result = {"ok": False, "fda": "authorized", "forced": True, "dndReads": 1}
        verdict = helper.assess({"muted": False}, result, {"muted": False}, True, True)
        self.assertTrue(verdict.startswith("INCONCLUSIVE:"))

    def test_side_effect_after_error_is_a_failure(self):
        result = {"ok": False, "fda": "authorized", "forced": True, "dndReads": 2}
        verdict = helper.assess({"muted": False}, result, {"muted": True}, True, True)
        self.assertTrue(verdict.startswith("FAIL:"))

    def test_unknown_is_not_unmuted(self):
        verdict = helper.assess({"muted": True}, {"ok": True}, {"muted": None}, False, False)
        self.assertTrue(verdict.startswith("INCONCLUSIVE:"))

    def test_normal_success_requires_the_requested_state(self):
        for requested in (True, False):
            verdict = helper.assess({"muted": not requested}, {"ok": True}, {"muted": requested}, requested, False)
            self.assertTrue(verdict.startswith("PASS:"))
            verdict = helper.assess({"muted": not requested}, {"ok": True}, {"muted": not requested}, requested, False)
            self.assertTrue(verdict.startswith("FAIL:"))

    def test_timeout_is_inconclusive_even_when_state_matches(self):
        verdict = helper.assess({"muted": False}, {"ok": False, "timeout": True}, {"muted": True}, True, False)
        self.assertTrue(verdict.startswith("INCONCLUSIVE:"))

    def test_interactive_fault_report_keeps_actual_and_expected_states(self):
        group = {"guid": "iMessage;+;fixture", "group_id": "fixture", "display_name": "Fixture"}
        before = {"fda": "authorized", "accessibility": "authorized", "muted": True, "dndReadable": True}
        after = {**before, "muted": False}
        result = {"ok": True, "fda": "authorized", "forced": True, "dndReads": 1, "preflight": True}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(helper, "groups", return_value=[group]), \
                 patch.object(helper, "choose_group", return_value=group), \
                 patch.object(helper, "snapshot", return_value=before), \
                 patch.object(helper, "invoke", return_value=(result, "fixture log")), \
                 patch.object(helper, "observe", return_value=[after]), \
                 patch("builtins.input", side_effect=["5", "off", "The chat became unmuted.", "q"]), \
                 patch("sys.stdout", new_callable=io.StringIO):
                helper.session(Path("unused-probe"), directory, 0)
            events = [json.loads(line) for line in (directory / "observations.jsonl").read_text().splitlines()]
        observation = events[-1]
        self.assertTrue(any(event["event"] == "state-observation" for event in events))
        self.assertEqual(observation["event"], "observation")
        self.assertTrue(observation["verdict"].startswith("REPRODUCED:"))
        self.assertEqual(observation["requestedStateVerdict"], "PASS")
        self.assertEqual(observation["visualVerdict"], "FAIL")
        self.assertFalse(observation["visual"])
        self.assertEqual(observation["note"], "The chat became unmuted.")


if __name__ == "__main__":
    unittest.main()

MUTE_TESTS_PY
