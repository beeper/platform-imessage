This procedure verifies the fallback in `PlatformAPI.updateThread`. The relevant condition combines authorized Full Disk Access with an unavailable `Defaults.getDNDList()` result.

FDA denial exercises a different branch. It does not reproduce this condition.

The helper compiles the current source in a temporary directory. Its probe calls the actual `PlatformAPI.updateThread` implementation.
The temporary DND reader records each call. A process environment variable can force that reader to return `nil`.
The regular source and the Messages preference files receive no direct edits from this instrumentation.
The temporary controller also records raw AX action names and the expected alert labels.

The helper performs real mute operations through Messages.app. Its selection menu displays group names from Messages.
For an unnamed group, the menu displays participant names from Messages. The generated list can differ from the sidebar's abbreviated title.
Its report contains the selected group identity and native diagnostic logs.

The helper opens a separate Messages process with its own window. Deep links and accessibility operations target that process.
Cleanup closes the automation process. The original Messages process remains open.
Both processes share the same conversations and mute preferences. A mute operation changes the selected conversation in both processes.

1. Quit Beeper before the direct API test.
2. Grant Full Disk Access to the terminal host for this test.

```sh
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles'
```

3. Grant Accessibility access to the same host.

```sh
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
```

4. If macOS requests a restart, restart that host.
5. Run the helper from the repository root.

```sh
./scripts/verify-mute-state.sh
```

The executable Bash script selects a full Xcode installation when `DEVELOPER_DIR` is unset.
An explicit `DEVELOPER_DIR` takes precedence. The script uses Python 3 for data and report operations.
The helper verifies database access before compilation. An access denial includes permission instructions for the terminal application.
The shell script includes the Python driver and the Swift source for the probe. The executable entry point is `./scripts/verify-mute-state.sh`.
Messages supplies names through its Automation interface. macOS can request permission for the terminal application to control Messages.

6. Select the group by number.
7. If the group is absent from the page, enter a search term or `n`.
8. Verify that `FDA=authorized` appears.
9. Verify that `UserDefaults` shows `muted` or `unmuted`.

The search accepts group names and participant names. The command `d NUMBER` displays participants for a particular result.
The menu retains separate entries for groups with the same name. Chat identifiers remain in the diagnostic report.

An `unknown` state is not an unmuted state. The helper refuses automatic mutations without a readable baseline.
Observation mode remains available for permission diagnosis.

10. Select `2` to mute the group normally.
11. Observe “Hide Alerts” in Messages.app.
12. Enter `on` if the checkbox is selected.
13. Enter a note about the result.
14. Select `2` again to verify repeated mute requests.

A normal mute must return success and end with “Hide Alerts” selected. An initial state change also needs a successful DND verification.
The native log contains `verified DND state after thread mute update` for that verification.
An operation that already matches the requested state can return without a toggle or another DND read.

15. Select `5` to request unmute with a forced unavailable DND read.
16. Observe “Hide Alerts” again.
17. Enter the actual checkbox state.
18. Enter a note about the result.

The recommended contract requires an error before any toggle. The group must remain muted when the initial DND read is unavailable.

The current branch instead permits AX fallback. A successful fallback unmute reproduces the defect under the injected condition.
The helper reports `REPRODUCED` if the API reports success with authorized FDA and the injected unavailable read.

The evidence for the current branch consists of these results:

- The mutation reports `fda: authorized`.
- The mutation reports `forced: true`.
- The DND reader records at least one call.
- The native log reports `falling back to Messages accessibility actions`.
- The native log lacks `verified DND state after thread mute update`.
- The API reports success.

The script reports state comparisons separately. A successful unmute can match the requested state and still violate the required refusal on an unavailable initial read.
An unrelated AX error gives an inconclusive result. It does not prove that the required guard exists.

Each independent observation uses a fresh process with the regular DND reader. Observations run during and after each operation.
Each observation also includes the selected entry from the plist on disk. The helper saves these observations before the prompt for visual verification.
The disk value is supplementary evidence. A delayed preference write can make it differ from UserDefaults during the observation interval.
The manual checkbox observation provides an additional result without the AX label parser under test.

19. Select `r` to restore the initial state through the normal API.
20. Verify the result in Messages.app.
21. Select `q` to exit.

The helper does not restore state automatically after exit or interruption. The report remains at the printed temporary directory.
The file `observations.jsonl` contains the expectations and observations. Each mutation also has a separate native log.

This test does not prove that authorized FDA naturally produces an unavailable read on this Mac. It proves the code behavior under that condition.
It also does not prove that Beeper Desktop uses this branch or inherits the probe's permissions.

For a Desktop relaunch test:

1. Install this branch's native module and JavaScript code in the Desktop build under test.
2. Start the helper.
3. Select the same group.
4. Select `1` for observation mode.
5. Enter `unchanged` as the expected state.
6. Relaunch Beeper Desktop.
7. Press Enter in the helper.
8. Observe “Hide Alerts” in Messages.app.
9. Enter the checkbox state and a note.

Observation mode does not invoke the mute API. It can verify a state change across Desktop relaunch, but it cannot expose Desktop's internal permission result.

These commands verify the helper without access to Messages data:

```sh
./scripts/test-verify-mute-state.sh
./scripts/verify-mute-state.sh --build-only
```

The build prints the probe path. A later session can reuse that exact source snapshot:

```sh
./scripts/verify-mute-state.sh --probe '/absolute/path/printed/by/the/build/mute-state-probe'
```

The report records the original probe revision. A reused probe does not include subsequent source changes.
The helper rejects older probes that lack the separate instance configuration.

To verify window isolation without a mute operation:

1. Keep the original Messages app open.
2. Run this command.

```sh
./scripts/verify-mute-state.sh --verify-window
```

3. Verify that `ok` is `true`.
4. Verify that `existingPIDs` includes the original Messages process.

The test creates a controller for a separate instance and disposes that controller.
The result includes the original process identifiers and the new process identifier.
Success requires one new process, preservation of the original processes, and termination of the new process.

An API error and a later state match represent separate results. The API requires the requested state within its ten-second verification interval.
A later match does not change the API result to success. The report retains both results.

To diagnose a late preference update:

1. Run this command without an older probe.

```sh
./scripts/verify-mute-state.sh --hold-after-api 5
```

2. Select the same group.
3. Select an operation that changes its current mute state.
4. Observe “Hide Alerts” in Messages.app.
5. Enter the actual state and a note.

The five-second hold starts after the API returns. It does not extend the API verification timeout.
The automation instance stays open during that interval. The original Messages process remains separate.

The report includes these timestamps:

- `apiCompletedAt`: the API returned success or an error.
- `disposeStartedAt`: cleanup started for the automation instance.
- `disposeReturnedAt`: cleanup returned after its termination request.

Each independent sample records its start and completion timestamps. These timestamps distinguish observations before and after cleanup.
The terminal prints the first matching phase for UserDefaults and the plist on disk separately.
If a sample spans a phase boundary, the summary states that limitation.
An independent match during repeated API mismatches supports stale reads in the API process.
A match after the API returns and before cleanup supports delayed preference updates.
A match only after cleanup requires a further comparison before a conclusion about persistence at app exit.

The API debug log assigns an identifier to each mute request. It records the requested state and the initial state.
Each verification attempt records its number, elapsed milliseconds, requested state, and observed state.
The final error records the last observed state and the total number of attempts.
The earlier three-second timeout expired before a measured preference update at about 5.3 seconds.
The API now allows ten seconds for that update. The operation retains the automation queue until verification completes.
The API reads the current state again after the queue wait. Another queued request cannot overlap the toggle and its verification.

The controller also waits up to three seconds for alert actions on a new row.
That wait repeats action discovery. The selected action executes once after discovery succeeds.
