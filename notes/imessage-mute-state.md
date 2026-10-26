DESK-13092: iMessage mute state review, 2026-09-07.

The review treats `kb/modern-concurrency` as the merge base for `purav/fix-imessage-mute-state`.
The issue concerns “Hide Alerts” in Messages.app after a Beeper Desktop relaunch.

The local tests exposed three separate defects:

- AX action names include `Target` and `Selector` metadata after the label. The original parser rejected those names.
- A new conversation row sometimes exposes only `AXScrollToVisible`. The controller read that incomplete action list once and failed.
- Preference updates exceed the original three-second verification timeout. The API returned an error even when the requested change took effect.

The diagnostic run on macOS 27.0 established this sequence for unmute:

| Event | UTC time |
| --- | --- |
| Alert action returned | 12:14:18.023 |
| API verification timed out | 12:14:21.028 |
| Independent UserDefaults and disk reads first showed unmuted | 12:14:23.278 |
| Cleanup started for the automation instance | 12:14:26.055 |

The update appeared before cleanup. App exit was not necessary for this update.
The data establishes delayed visibility across independent readers. It does not establish the internal reason for the macOS delay.

The subsequent successful cycle needed about 7.7 seconds to verify mute and 7.5 seconds to verify unmute.
Independent UserDefaults reads briefly disagreed with the plist during that cycle. A single observation does not prove permanent convergence.

The implemented changes are:

- The label parser reads the first line. Commit `defbcd04` contains that fix.
- Action discovery refetches the selected row and waits up to three seconds for an alert action.
- The controller invokes the selected alert action once. Discovery retries do not repeat the toggle.
- Verification polls for up to ten seconds.
- The initial state read runs on the automation queue. The mutation refreshes that state after the queue wait.
- The operation retains the automation queue through verification. Another queued operation cannot overlap that interval.
- API logs include a request identifier, expected and observed states, attempt counts, and elapsed milliseconds.

The helper launches a separate Messages process for automation. Cleanup targets that process.
It records independent UserDefaults and plist observations during and after each request.
It records API completion and cleanup timestamps before the visual observation prompt.
The optional five-second hold keeps the automation instance open after the API returns. It does not extend the API verification timeout.

Only two helper scripts remain:

| Script | Purpose |
| --- | --- |
| `scripts/verify-mute-state.sh` | Interactive group selection, native probe, observations, and reports. Python and Swift sources are embedded. |
| `scripts/test-verify-mute-state.sh` | Tests for group selection, report verdicts, and observation timing. |

Both files are executable shell scripts. They use Python 3, and the native probe requires a full Xcode installation.
The separate `.py` and `.swift` helper files were removed.

Validation passed:

- Nine focused Swift tests passed. They include a 5.3-second publication delay, persistent mismatches, unavailable state, and cancellation.
- All 26 helper tests passed.
- The native probe compiled.
- A live cycle on the selected Hamsters group passed mute, repeated mute, and unmute.
- The group returned to its initial unmuted state.
- The original Messages process remained open.

The live report is in `/var/folders/wb/zt7_1t1d2dn322r86qcksy3h0000gn/T/imessage-mute-roundtrip-_tqurqol`.
The report contains `summary.json` and separate native logs for each operation. This directory is temporary.
The latest successful cycle did not exercise the missing-action retry path.

The remaining merge work is:

- Verify cold launches that initially expose only `AXScrollToVisible`.
- Verify concurrent mute requests through the public API.
- Verify Beeper Desktop relaunch with the actual native module from this branch.
- Verify existing accounts that lack Full Disk Access, including the permission recovery flow.
- Resolve the authorized-FDA case where the DND read is unavailable. The branch still permits AX fallback in that case.
- Verify supported macOS versions. Ten seconds covers the measured local delays but does not establish a universal upper bound.

To run the interactive verification:

1. Run `./scripts/verify-mute-state.sh`.
2. Select a group by name.
3. Select an operation that changes its current state.
4. Observe “Hide Alerts” in Messages.app.
5. Record the actual state and a note.

To diagnose a future timeout, run `./scripts/verify-mute-state.sh --hold-after-api 5`.
To verify the helper, run `./scripts/test-verify-mute-state.sh`.
