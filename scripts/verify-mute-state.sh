#!/usr/bin/env bash
set -euo pipefail

mute_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'Python 3 is required for the report parser.' >&2
  exit 1
fi

# Use an explicit toolchain when present. Otherwise, prefer a full Xcode installation.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  mute_selected_developer="$(xcode-select -p 2>/dev/null || true)"
  case "$mute_selected_developer" in
    *.app/Contents/Developer)
      export DEVELOPER_DIR="$mute_selected_developer"
      ;;
    *)
      for mute_xcode_developer in \
        /Applications/Xcode.app/Contents/Developer \
        /Applications/Xcode-beta.app/Contents/Developer; do
        if [[ -d "$mute_xcode_developer" ]]; then
          export DEVELOPER_DIR="$mute_xcode_developer"
          break
        fi
      done
      ;;
  esac
fi

export IMESSAGE_MUTE_SCRIPT_PATH="$mute_script_dir/verify-mute-state.sh"
exec python3 -c "$(cat <<'MUTE_DRIVER_PY'
#!/usr/bin/env python3
"""Verify native mute state with an interactive group selector and a temporary probe."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

if __name__ == "__main__":
    __file__ = os.environ["IMESSAGE_MUTE_SCRIPT_PATH"]
    sys.argv[0] = __file__

ROOT = Path(__file__).resolve().parent.parent
FORCE_KEY = "IMESSAGE_MUTE_PROBE_FORCE_UNKNOWN_DND"
HOLD_KEY = "IMESSAGE_MUTE_PROBE_HOLD_AFTER_API"
READ_MARKER = "MUTE_PROBE_DND_READ"
JSON_MARKER = "MUTE_PROBE_JSON:"
PROBE_CONFIGURATION = {"revision": 5, "automationInstance": "secondary"}
MESSAGES_GROUP_NAMES_SCRIPT = r'''
function run() {
    var app = Application("/System/Applications/Messages.app");
    var ids = app.chats.id().filter(function(id) { return id.indexOf(";+;") !== -1; });
    var rows = ids.map(function(id) {
        var chat = app.chats.byId(id);
        var row = {guid: id, name: "", members: []};
        try { row.name = chat.name() || ""; } catch (error) {}
        try {
            row.members = chat.participants.name().filter(function(name) {
                return typeof name === "string" && name.length > 0;
            });
        } catch (error) {}
        return row;
    });
    return JSON.stringify(rows);
}
'''


PROBE_SWIFT = r'''import AppKit
import Foundation
@testable import IMessage

// This executable belongs to the temporary package from verify-mute-state.py.
// The temporary Defaults.swift records reads and supports a forced nil result.
private let forceKey = "IMESSAGE_MUTE_PROBE_FORCE_UNKNOWN_DND"

private func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print("MUTE_PROBE_JSON:" + String(decoding: data, as: UTF8.self))
}

private func diskState(identifier: String) -> [String: Any] {
    let path = NSHomeDirectory() + "/Library/Preferences/com.apple.MobileSMS.CKDNDList.plist"
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let domain = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return ["status": "invalid-domain"]
        }
        guard let rawList = domain["CKDNDListKey"] else {
            return ["status": "absent-key"]
        }
        guard let list = rawList as? [String: Int] else {
            return ["status": "invalid-list"]
        }
        return [
            "status": "readable",
            "muted": list[identifier] == Int(Date.distantFuture.timeIntervalSince1970),
            "entry": list[identifier].map { $0 as Any } ?? NSNull(),
        ]
    } catch {
        let error = error as NSError
        return ["status": "unavailable", "errorDomain": error.domain, "errorCode": error.code]
    }
}

@main
struct MuteStateProbe {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            try emit(["ok": false, "error": "Use snapshot GROUP_ID or mutate CHAT_GUID on|off LOG_DIRECTORY."])
            return
        }
        if command == "snapshot", args.count == 2 {
            let list = Defaults.getDNDList()
            let muted = PlatformAPI.muteState(forDNDIdentifier: args[1], from: list)
            try emit([
                "fda": MacPermissions.getAuthStatus(.fullDiskAccess).rawValue,
                "accessibility": MacPermissions.getAuthStatus(.accessibility).rawValue,
                "dndReadable": list != nil,
                "muted": muted.map { $0 as Any } ?? NSNull(),
                "entry": list?[args[1]].map { $0 as Any } ?? NSNull(),
                "disk": diskState(identifier: args[1]),
            ])
            return
        }
        if command == "verify-window", args.count == 2 {
            guard MacPermissions.getAuthStatus(.accessibility) == .authorized else {
                try emit(["ok": false, "error": "The window test requires Accessibility access."])
                return
            }
            IMessageHost.bootstrapWithOptions(dataDirPath: args[1], verbose: true, useSecondaryInstance: true)
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS")
            let existingPIDs = Set(existing.map(\.processIdentifier))
            let controller = try await MessagesController(reportErrorMessage: { print($0) })
            let current = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS")
            let created = current.filter { !existingPIDs.contains($0.processIdentifier) }
            controller.dispose()
            for _ in 0..<50 {
                if created.allSatisfy(\.isTerminated) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let preserved = existing.allSatisfy { !$0.isTerminated }
            let closed = created.allSatisfy(\.isTerminated)
            try emit([
                "ok": created.count == 1 && preserved && closed,
                "existingPIDs": existing.map(\.processIdentifier),
                "automationPIDs": created.map(\.processIdentifier),
                "existingInstancesPreserved": preserved,
                "automationInstanceClosed": closed,
            ])
            return
        }
        guard command == "mutate", args.count == 4, ["on", "off"].contains(args[2]) else {
            try emit(["ok": false, "error": "Invalid probe arguments."])
            return
        }

        let fda = MacPermissions.getAuthStatus(.fullDiskAccess).rawValue
        let forced = ProcessInfo.processInfo.environment[forceKey] == "1"
        guard fda == "authorized", MacPermissions.getAuthStatus(.accessibility) == .authorized else {
            try emit(["ok": false, "fda": fda, "forced": forced, "preflight": false,
                      "error": "The probe requires FDA and Accessibility access."])
            return
        }

        IMessageHost.bootstrapWithOptions(dataDirPath: args[3], verbose: true, useSecondaryInstance: true)
        let api = try PlatformAPI(accountID: "mute-state-probe")
        var result: [String: Any] = ["fda": fda, "forced": forced, "preflight": true]
        do {
            try await api.updateThread(threadID: args[1], muted: args[2] == "on")
            result["ok"] = true
        } catch {
            result["ok"] = false
            result["error"] = String(describing: error)
        }
        result["apiCompletedAt"] = Date().timeIntervalSince1970
        let hold = Double(ProcessInfo.processInfo.environment["IMESSAGE_MUTE_PROBE_HOLD_AFTER_API"] ?? "0") ?? 0
        if hold > 0, hold <= 30 {
            try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        }
        result["disposeStartedAt"] = Date().timeIntervalSince1970
        do {
            try await api.dispose()
        } catch {
            result["cleanupError"] = String(describing: error)
        }
        result["disposeReturnedAt"] = Date().timeIntervalSince1970
        try emit(result)
    }
}
'''


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def state_name(value):
    return "unknown" if value is None else "muted" if value else "unmuted"


def build_probe(directory, metadata):
    source = directory / "source"
    source.mkdir()
    shutil.copytree(ROOT / "src", source / "src")
    for name in ("Package.swift", "Package.resolved", "package.json"):
        if (ROOT / name).exists():
            shutil.copy2(ROOT / name, source / name)
    probe_source = source / "mute-state-probe"
    probe_source.mkdir()
    (probe_source / "MuteStateProbe.swift").write_text(PROBE_SWIFT)

    defaults = source / "src/IMessage/Sources/IMessage/Defaults.swift"
    text = defaults.read_text()
    anchor = "    static func getDNDList() -> [String: Int]? {"
    if text.count(anchor) != 1:
        raise RuntimeError("The DND reader changed. Update the probe patch before this test.")
    injection = '''
        FileHandle.standardError.write(Data("MUTE_PROBE_DND_READ\\n".utf8))
        if ProcessInfo.processInfo.environment["IMESSAGE_MUTE_PROBE_FORCE_UNKNOWN_DND"] == "1" {
            return nil
        }
'''
    defaults.write_text(text.replace(anchor, anchor + injection))

    controller = source / "src/IMessage/Sources/IMessage/Messages/MessagesController.swift"
    text = controller.read_text()
    anchor = "        try threadCell.supportedActions().compactMap { action in"
    if text.count(anchor) != 1:
        raise RuntimeError("The alert action reader changed. Update the diagnostic patch before this test.")
    diagnostics = '''        let availableActions = try threadCell.supportedActions()
        log.debug("MUTE_PROBE_AX_ACTIONS: \\(availableActions.map { $0.name.value })")
        log.debug("MUTE_PROBE_AX_LABELS: hide=\\(ThreadAction.hideAlerts.localized), show=\\(ThreadAction.showAlerts.localized)")
        return availableActions.compactMap { action in'''
    controller.write_text(text.replace(anchor, diagnostics))

    manifest = source / "Package.swift"
    text = manifest.read_text()
    anchor = "let package = Package("
    if text.count(anchor) != 1:
        raise RuntimeError("The package manifest changed. Update the probe target before this test.")
    target = '''
products.append(.executable(name: "mute-state-probe", targets: ["MuteStateProbe"]))
targets.append(.executableTarget(name: "MuteStateProbe", dependencies: ["IMessage"], path: "mute-state-probe"))

'''
    manifest.write_text(text.replace(anchor, target + anchor))
    environment = dict(os.environ)
    environment.pop("IMESSAGE_INCLUDE_NODE_BRIDGE", None)
    environment.pop(FORCE_KEY, None)
    build_log = directory / "build.log"
    print(f"The probe compiles in a temporary source copy. Build log: {build_log}", flush=True)
    with build_log.open("w") as log:
        subprocess.run(["swift", "build", "--product", "mute-state-probe"], cwd=source,
                       env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    path = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=source,
                                   env=environment, text=True).strip().splitlines()[-1]
    probe = Path(path) / "mute-state-probe"
    probe.with_name("mute-state-probe-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return probe


def terminal_host():
    return {
        "Apple_Terminal": "Terminal.app",
        "iTerm.app": "iTerm.app",
        "vscode": "Visual Studio Code",
        "WarpTerminal": "Warp",
    }.get(os.environ.get("TERM_PROGRAM"), "the application that runs this terminal")


def messages_access_error(error):
    host = terminal_host()
    return RuntimeError(
        "This terminal session cannot read ~/Library/Messages/chat.db.\n\n"
        "Open System Settings > Privacy & Security > Full Disk Access.\n"
        f"Enable {host}.\n"
        f"Quit {host} completely.\n"
        "Open a new terminal session.\n"
        "Run ./scripts/verify-mute-state.sh again.\n\n"
        f"Original error: {error}"
    )


def groups():
    database = Path.home() / "Library/Messages/chat.db"
    try:
        # Distinguish an OS denial from a query failure before SQLite opens the file.
        with database.open("rb"):
            pass
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
            connection.row_factory = sqlite3.Row
            rows = connection.execute("""
            SELECT c.guid, c.group_id, c.display_name,
                   (SELECT group_concat(h.id, ', ')
                    FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id
                    WHERE j.chat_id = c.ROWID) AS participants
            FROM chat c
            WHERE COALESCE(c.room_name, '') <> '' AND COALESCE(c.group_id, '') <> ''
            ORDER BY c.ROWID DESC
            """).fetchall()
    except PermissionError as error:
        raise messages_access_error(error) from error
    except sqlite3.Error as error:
        if getattr(error, "sqlite_errorcode", None) == 23 or "authorization denied" in str(error).lower():
            raise messages_access_error(error) from error
        raise
    return [dict(row) for row in rows]


def attach_group_names(rows, message_chats):
    by_guid = {chat["guid"]: chat for chat in message_chats}
    by_identity = {}
    for chat in message_chats:
        parts = chat["guid"].split(";", 2)
        if len(parts) == 3:
            by_identity.setdefault(tuple(parts[1:]), []).append(chat)
    enriched = []
    for row in rows:
        chat = by_guid.get(row["guid"])
        if chat is None:
            parts = row["guid"].split(";", 2)
            candidates = by_identity.get(tuple(parts[1:]), []) if len(parts) == 3 else []
            if len(candidates) == 1:
                chat = candidates[0]
        members = chat.get("members", []) if chat else []
        name = chat.get("name", "").strip() if chat else ""
        source = "Messages"
        if not name and chat is None:
            name = (row.get("display_name") or "").strip()
            source = "database"
        if not name:
            name = ", ".join(members) or "Unnamed group"
            source = "Messages participants" if members else "unavailable"
        enriched.append({**row, "selection_name": name, "name_source": source, "member_names": members})
    return enriched


def group_names_from_messages(rows):
    print("The helper reads group names from Messages.app.", flush=True)
    try:
        result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", MESSAGES_GROUP_NAMES_SCRIPT],
                                capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("Messages did not return group names within 60 seconds. Open Messages and try again.") from error
    if result.returncode:
        error = result.stderr.strip()
        if "-1743" in error:
            raise RuntimeError(
                "The terminal cannot read group names from Messages.\n\n"
                "Open System Settings > Privacy & Security > Automation.\n"
                f"Enable Messages under {terminal_host()}.\n"
                "Run ./scripts/verify-mute-state.sh again."
            )
        raise RuntimeError(f"Messages did not provide group names: {error}")
    try:
        message_chats = json.loads(result.stdout)
        if not isinstance(message_chats, list):
            raise ValueError("The response is not a chat list.")
        return attach_group_names(rows, message_chats)
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        raise RuntimeError("Messages returned an invalid group name response.") from error


def group_label(row):
    return row.get("selection_name") or row.get("display_name") or "Unnamed group"


def choose_group(rows):
    if not rows:
        raise RuntimeError("No group chat with a DND identifier exists in the database.")
    matches, page = rows, 0
    while True:
        print("\nChoose a group chat by name.")
        for index in range(page * 15, min((page + 1) * 15, len(matches))):
            row = matches[index]
            print(f"{index + 1:4}. {group_label(row)}")
        if not matches:
            print("No group names match. Enter another name, or press Enter to show all groups.")
        value = input("Enter a number or name (n: next page, d NUMBER: details, q: quit): ").strip()
        if value == "q":
            raise KeyboardInterrupt
        if value == "n":
            page = (page + 1) % max(1, (len(matches) + 14) // 15)
        elif value.startswith("d ") and value[2:].isdigit() and 1 <= int(value[2:]) <= len(matches):
            row = matches[int(value[2:]) - 1]
            print(f"\n{group_label(row)}")
            print("Participants: " + (", ".join(row.get("member_names", [])) or row.get("participants") or "unavailable"))
        elif value.isdigit() and 1 <= int(value) <= len(matches):
            return matches[int(value) - 1]
        else:
            matches = [row for row in rows if value.casefold() in " ".join([
                group_label(row), ", ".join(row.get("member_names", [])), row.get("participants") or "",
            ]).casefold()]
            page = 0


def invoke(probe, args, forced=False, hold_after_api=0):
    environment = dict(os.environ)
    environment.pop(FORCE_KEY, None)
    environment[HOLD_KEY] = str(hold_after_api)
    if forced:
        environment[FORCE_KEY] = "1"
    command = [str(probe), *args]
    try:
        process = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=120)
        output = process.stdout + "\n" + process.stderr
        packets = [line[len(JSON_MARKER):] for line in process.stdout.splitlines() if line.startswith(JSON_MARKER)]
        result = json.loads(packets[-1]) if packets else {"ok": False, "error": "The probe returned no result."}
        result["exitCode"] = process.returncode
    except subprocess.TimeoutExpired as error:
        def as_text(value):
            return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
        output = as_text(error.stdout) + "\n" + as_text(error.stderr)
        result = {"ok": False, "error": "The probe exceeded 120 seconds. The final state is uncertain.", "timeout": True}
    result["dndReads"] = output.count(READ_MARKER)
    return result, output


def snapshot(probe, identifier):
    result, _ = invoke(probe, ["snapshot", identifier])
    if "dndReadable" not in result:
        raise RuntimeError(result.get("error", "The state observation failed."))
    return result


def show_snapshot(value):
    disk = value.get("disk", {})
    print(f"FDA={value['fda']}  AX={value['accessibility']}  "
          f"UserDefaults={state_name(value['muted'])}  entry={value.get('entry')}  "
          f"disk={disk.get('status')}:{state_name(disk.get('muted'))}")


def observe(probe, identifier, seconds):
    deadline = time.monotonic() + seconds
    samples, previous = [], None
    while True:
        started = stamp()
        value = snapshot(probe, identifier)
        samples.append({"startedAt": started, "at": stamp(), **value})
        comparison = json.dumps(value, sort_keys=True)
        if comparison != previous:
            show_snapshot(value)
            previous = comparison
        if time.monotonic() >= deadline:
            return samples
        time.sleep(0.5)


def monitored_mutation(probe, args, identifier, directory, operation, forced, hold_after_api):
    samples = []
    previous = None
    with ThreadPoolExecutor(max_workers=1) as executor:
        pending = executor.submit(invoke, probe, args, forced=forced, hold_after_api=hold_after_api)
        while not pending.done():
            started = stamp()
            try:
                value = snapshot(probe, identifier)
                comparison = json.dumps(value, sort_keys=True)
                if comparison != previous:
                    print("Independent observation during the operation:")
                    show_snapshot(value)
                    previous = comparison
                sample = {"startedAt": started, "at": stamp(), **value}
            except (OSError, RuntimeError) as error:
                sample = {"startedAt": started, "at": stamp(), "observerError": str(error)}
            samples.append(sample)
            record(directory, {"event": "during-operation-sample", "operation": operation, "sample": sample})
            if not pending.done():
                time.sleep(0.5)
        result, output = pending.result()
    return result, output, samples


def assess(before, result, after, requested, forced):
    """Separate the API contract from the observed state."""
    if result.get("timeout") or result.get("exitCode", 0) != 0 or result.get("preflight") is False:
        return "INCONCLUSIVE: the probe did not complete the API request."
    if forced:
        if result.get("fda") != "authorized" or not result.get("forced") or result.get("dndReads", 0) == 0:
            return "INCONCLUSIVE: FDA plus an unavailable DND read was not established."
        if result.get("ok"):
            return "REPRODUCED: the API reported success with an unavailable DND read."
        if before.get("muted") is None or after.get("muted") is None:
            return "INCONCLUSIVE: the API returned an error, but the actual state is unknown."
        if after["muted"] != before["muted"]:
            return "FAIL: the API returned an error after the mute state changed."
        return "INCONCLUSIVE: the API returned an error without a state change. Inspect the error and AX fallback log."
    if not result.get("ok"):
        if after.get("muted") == requested:
            return "FAIL: the API returned an error. The final observed state matches the request."
        return "FAIL: the API returned an error."
    if after.get("muted") is None:
        return "INCONCLUSIVE: UserDefaults did not provide a final state."
    if after["muted"] != requested:
        return "FAIL: the observed state differs from the requested state."
    return "PASS: the API result and UserDefaults match the requested state."


def timing_summary(result, samples, requested):
    if "apiCompletedAt" not in result or "disposeStartedAt" not in result:
        return []
    descriptions = {
        "before-api-return": "before the API returned",
        "before-cleanup": "after the API returned and before cleanup started",
        "after-cleanup-start": "after cleanup started",
        "boundary-overlap": "in a sample that overlaps an API or cleanup boundary",
    }
    summaries = []
    for source in ("UserDefaults", "disk"):
        first = next((sample for sample in samples
                      if (sample.get("muted") if source == "UserDefaults" else sample.get("disk", {}).get("muted"))
                      is requested), None)
        if first is None:
            summaries.append({"source": source, "phase": "no-match",
                              "message": f"{source}: no independent sample matched the requested state."})
            continue
        completed = datetime.datetime.fromisoformat(first["at"]).timestamp()
        started = datetime.datetime.fromisoformat(first.get("startedAt", first["at"])).timestamp()
        if completed < result["apiCompletedAt"]:
            phase = "before-api-return"
        elif started >= result["apiCompletedAt"] and completed < result["disposeStartedAt"]:
            phase = "before-cleanup"
        elif started >= result["disposeStartedAt"]:
            phase = "after-cleanup-start"
        else:
            phase = "boundary-overlap"
        summaries.append({"source": source, "phase": phase, "firstMatch": first["at"],
                          "message": f"{source}: the first independent match occurred {descriptions[phase]}."})
    return summaries


def record(directory, entry):
    with (directory / "observations.jsonl").open("a") as stream:
        stream.write(json.dumps({"at": stamp(), **entry}, sort_keys=True) + "\n")


def visual_observation():
    while True:
        value = input("Observe Hide Alerts in Messages.app. Enter on, off, or unknown: ").strip().lower()
        if value in ("on", "off", "unknown"):
            return {"on": True, "off": False, "unknown": None}[value]


def session(probe, directory, seconds, available_groups=None, hold_after_api=0):
    selected = choose_group(groups() if available_groups is None else available_groups)
    print(f"\nSelected group: {group_label(selected)}")
    record(directory, {"event": "selected-group", "group": selected})
    identifier = selected["group_id"]
    initial = snapshot(probe, identifier)
    show_snapshot(initial)
    print("Mutation commands change Hide Alerts for this group through Messages.app.")
    print("Automation uses a separate Messages instance. Cleanup closes that instance.")
    if hold_after_api:
        print(f"The automation instance remains open for {hold_after_api:g} seconds after the API returns.")
    print("The report contains this group identity and native diagnostic logs.")
    while True:
        print("\n1 Observe only / Desktop relaunch\n2 Mute\n3 Unmute\n4 Mute with a forced unknown DND read\n5 Unmute with a forced unknown DND read\nr Restore the initial state\nq Quit")
        choice = input("Choose an operation: ").strip().lower()
        if choice == "q":
            print(f"Initial state: {state_name(initial['muted'])}. The script does not restore state on exit.")
            return
        if choice not in ("1", "2", "3", "4", "5", "r"):
            continue
        before = snapshot(probe, identifier)
        if choice == "1":
            expectation = input("Enter the expected final state: on, off, or unchanged: ").strip().lower()
            if expectation not in ("on", "off", "unchanged"):
                continue
            expected = before["muted"] if expectation == "unchanged" else expectation == "on"
            print(f"Expected final state: {state_name(expected)}.")
            input("Perform the manual action or relaunch Beeper. Then press Enter to observe: ")
            samples = observe(probe, identifier, seconds)
            after = samples[-1]
            verdict = ("INCONCLUSIVE" if expected is None or after["muted"] is None
                       else "PASS" if after["muted"] == expected else "FAIL")
            result = {"manual": True}
            forced = False
            during = []
        else:
            expected = initial["muted"] if choice == "r" else choice in ("2", "4")
            if expected is None or before["muted"] is None:
                print("The actual state is unknown. Use observation mode until UserDefaults provides a baseline.")
                continue
            forced = choice in ("4", "5")
            print(f"Requested state: {state_name(expected)}.")
            if forced:
                print(f"Required contract: an error and no state change ({state_name(before['muted'])}).")
                print("The current branch can report success through AX fallback. That result reproduces item 3.")
            operation = str(time.time_ns())
            record(directory, {"event": "request", "operation": operation, "before": before,
                               "requested": expected, "forced": forced})
            result, output, during = monitored_mutation(
                probe, ["mutate", selected["guid"], "on" if expected else "off", str(directory / "native-logs")],
                identifier, directory, operation, forced, hold_after_api)
            log_path = directory / f"{operation}.log"
            log_path.write_text(output)
            record(directory, {"event": "api-result", "operation": operation, "result": result, "log": str(log_path)})
            print(f"API success={result.get('ok')}  DND reads={result['dndReads']}  Log: {log_path}")
            if result.get("error"):
                print(result["error"])
            samples = observe(probe, identifier, seconds)
            after = samples[-1]
            verdict = assess(before, result, after, expected, forced)
        timing = timing_summary(result, during + samples, expected)
        record(directory, {"event": "state-observation", "before": before, "requested": expected,
                           "api": result, "duringOperation": during, "samples": samples, "verdict": verdict,
                           "timing": timing})
        print(verdict)
        for summary in timing:
            print(summary["message"])
        requested_verdict = ("INCONCLUSIVE" if after["muted"] is None or expected is None
                             else "PASS" if after["muted"] == expected else "FAIL")
        print(f"UserDefaults versus the requested state: {requested_verdict}")
        visual = visual_observation()
        expected_observation = before["muted"] if forced else expected
        visual_verdict = ("INCONCLUSIVE" if visual is None or expected_observation is None
                          else "PASS" if visual == expected_observation else "FAIL")
        print(f"Messages.app versus the required state: {visual_verdict}")
        note = input("Add an observation note, or press Enter: ")
        record(directory, {"event": "observation", "before": before, "requested": expected,
                           "forced": forced, "api": result, "samples": samples, "verdict": verdict,
                           "requestedStateVerdict": requested_verdict,
                           "visual": visual, "visualVerdict": visual_verdict, "note": note})


def main():
    parser = argparse.ArgumentParser(prog="verify-mute-state.sh", description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--build-only", action="store_true", help="Compile the probe without access to Messages data.")
    modes.add_argument("--verify-window", action="store_true", help="Verify a separate automation instance without a mute operation.")
    parser.add_argument("--probe", type=Path, help="Reuse a probe from an earlier run.")
    parser.add_argument("--seconds", type=float, default=5, help="Observe state for this duration after each operation.")
    parser.add_argument("--hold-after-api", type=float, default=0,
                        help="Keep the automation instance open after the API returns, from 0 to 30 seconds.")
    args = parser.parse_args()
    if args.seconds < 0:
        parser.error("--seconds must be zero or greater")
    if not 0 <= args.hold_after_api <= 30:
        parser.error("--hold-after-api must be between zero and 30")
    directory = Path(tempfile.mkdtemp(prefix="imessage-mute-verification-"))
    print(f"Report directory: {directory}", flush=True)
    try:
        reused_metadata = None
        if args.probe:
            reused_metadata = json.loads(args.probe.resolve().with_name("mute-state-probe-metadata.json").read_text())
            if reused_metadata.get("probeConfiguration") != PROBE_CONFIGURATION:
                raise RuntimeError("This probe lacks the current window isolation and diagnostic configuration. Run ./scripts/verify-mute-state.sh without --probe.")
        available_groups = None
        if not args.build_only and not args.verify_window:
            if not sys.stdin.isatty():
                raise RuntimeError("Run this script in an interactive terminal.")
            available_groups = groups()
            available_groups = group_names_from_messages(available_groups)
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        diff = subprocess.check_output(["git", "diff", "HEAD", "--", "src", "Package.swift"], cwd=ROOT, text=True)
        (directory / "source.diff").write_text(diff)
        metadata = {"sourceCommit": revision, "sourceDiffSHA256": hashlib.sha256(diff.encode()).hexdigest(),
                    "builtAt": stamp(), "macOS": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
                    "probeConfiguration": PROBE_CONFIGURATION}
        if args.probe:
            probe = args.probe.resolve()
            metadata = reused_metadata
        else:
            probe = build_probe(directory, metadata)
        record(directory, {"event": "session", "build": metadata, "checkoutCommit": revision,
                           "reusedProbe": bool(args.probe), "probe": str(probe)})
        print(f"Probe: {probe}", flush=True)
        if args.verify_window:
            result, output = invoke(probe, ["verify-window", str(directory / "native-logs")])
            log_path = directory / "window.log"
            log_path.write_text(output)
            record(directory, {"event": "window-verification", "result": result, "log": str(log_path)})
            print(json.dumps(result, indent=2))
            print(f"Window log: {log_path}")
            return 0 if result.get("ok") else 1
        elif not args.build_only:
            session(probe, directory, args.seconds, available_groups, args.hold_after_api)
    except KeyboardInterrupt:
        print("\nThe session stopped. No automatic restore occurred.")
    except (OSError, RuntimeError, subprocess.CalledProcessError, sqlite3.Error) as error:
        record(directory, {"event": "error", "error": str(error)})
        print(f"The test stopped: {error}", file=sys.stderr)
        return 1
    finally:
        print(f"Report directory: {directory}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

MUTE_DRIVER_PY
)" "$@"
