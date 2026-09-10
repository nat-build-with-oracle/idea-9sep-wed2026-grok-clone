# Routine execution contract and implementation

Status: **native routine editing, execution controls, history and awake lifecycle are implemented**.
Verified with synthetic temporary stores and offline providers. This is not a claim of 24/7
background service, live-provider certification, physical sleep testing, or complete accessibility coverage.

Schema v3 preserves this routine ledger and adds attachment storage. Existing routine
consent is not file-transmission consent: runs whose recent context includes stored
attachments are recorded as blocked before credential reads or network calls because
interactive [attachment confirmation](ATTACHMENTS.md) does not widen routine authorization.

## Execution boundary

```text
Explicit Run Now             Launch / wake / 30-second awake timer
       |                                      |
       +------------ RoutineScheduler --------+
                            |
                 CAS occurrence claim + next UTC time
                 + optional skipped-range summary
                            |
               persisted RoutineRun (queued)
                            |
                  GenerationCoordinator
                   /                  \
     missing/changed provider       binding still matches
     or unavailable credential              |
               |                 message + generation committed
          blocked record                    |
                                 shared queue (global cap 3)
                                            |
                                   URLSession / provider
                                            |
                               run + generation terminal state
```

- A routine explicitly belongs to one bot. Its output goes to that bot's direct conversation,
  not an implicitly selected group. The group editor requires an explicit owner and discloses it.
- `RoutineProviderBinding` captures the provider ID, kind, API root, model and loopback policy.
  It contains no credential value or credential reference. Changes to the bound destination/model
  require new routine authorization; the composer selection cannot redirect an automatic run.
- The dispatched input includes the captured routine prompt and the owner's recent direct-chat
  context (the same bounded 100-message provider context as interactive chat). Native enabling
  controls disclose and require authorization for the prompt, full API root/model and context.
  Binding changes invalidate consent; Run Now separately confirms the immutable definition.
- A run is claimed in one serialized repository transaction **before** credential lookup or
  transport. Its prompt/name/provider metadata is immutable even if the definition is edited.
- A second active run or duplicate scheduled occurrence is rejected at the repository boundary.
  Run Now is allowed while paused and does not advance the scheduled occurrence.
- Automatic sends do not clear the user's draft, even when its text equals the routine prompt.
- Failed or missing setup creates a typed blocked result, not a fabricated assistant answer.
  No automatic credential discovery, account rotation, credential refresh or request retry is added.
- Routine-associated generation attempts cannot be retried through the ordinary chat retry path.
  An explicit new run creates a new history record rather than rewriting the old occurrence.

## Clock and catch-up policy

- Intervals are 5–525,600 minutes of absolute elapsed time. Daily triggers use a named timezone
  and an explicit Gregorian calendar, independent of the user's display calendar.
- Spring-forward gaps select the first valid local instant. Fall-back selects the first copy of
  the requested local time and uses one occurrence ID for that local date.
- A tested transition fallback handles Foundation's partial-hour-gap behavior (Lord Howe);
  exact component round-trips handle historical sub-minute timezone offsets.
- A wholly nonexistent local date, such as Samoa's skipped December 30, 2011, has no invented job.
- Reconciliation chooses at most one latest missed occurrence and moves `nextRunAt` into the
  future in the same transaction. Older misses are one terminal skipped-range record with count,
  first and last occurrence, not a catch-up burst or unbounded list of generated jobs.
- Clock rollback never creates an occurrence before its next scheduled instant. Ledger terminal
  timestamps are clamped to creation time when the wall clock has moved backwards.
- `RoutineScheduler` takes an injectable clock. The host must call reconcile on launch/wake and
  while awake, cancel/join accepted scheduling calls on workspace change/quit, and shut down the
  shared generation coordinator. The native host polls every 30 seconds while awake and observes
  macOS sleep/wake notifications. There is no helper, login item or cloud service.
  **Nothing promises execution while the app is closed, the Mac is asleep, or the user is logged out.**

## Pause, Stop and deletion

- Pause prevents new scheduled claims. An already claimed run may finish; Stop is a separate action.
- Stop atomically cancels a claim and its generation, including the credential-read race before a
  generation exists. The coordinator also prevents a cancelled claim from entering transport later.
- Deleting a routine requires no active run and deletes its run history, not its chat transcript.
  Native confirmation offers an explicit Stop-and-delete path when a run is active.
  The definition and exact run-ID set are checked before pausing future claims, then rechecked
  before final deletion. If the stop/delete sequence fails after pause, it remains paused and
  shows an error; new history requires a new confirmation.
- Bot deletion includes owned run-history counts and cancels claimed work before physical deletion.
  New run history changes the confirmation's destructive impact and requires a new review.
- Restart marks unfinished claims and generations interrupted. It does not replay those requests.
  A later scheduled occurrence is independent of the interrupted run.

## Persistence and export

- Schema v1 remains immutable. Schema v2 adds the separate `RoutineRun` entity and bounded,
  indexed latest-history queries; messages remain separately paginated.
- Migration recognizes the old model explicitly, migrates to a temporary store, validates it,
  retains a consistent recovery copy and uses Core Data's store replacement API. Unknown schemas
  fail closed instead of resetting user data. A failed recovery retains its backup for recovery.
- Current export format **3**, export source-schema marker **3**, includes every routine
  definition and run plus `summary.routineRunCount`, and exact referenced attachment bytes.
  These export markers are separate from the current Core Data v4 store model. Stored
  credentials remain excluded; see the [export contract](WORKSPACE-EXPORT.md).
  Routine prompts, context already in messages, and provider destinations are private content:
  export does not scrub secrets a user has pasted into them.

## Evidence and remaining work

Synthetic temporary-store tests cover calendar edge cases, run claims, migration, transaction
rollback, blocked providers, cancellation races, draft preservation, catch-up and restart.
No development run opens or migrates the user's real workspace, calls a paid provider, or imports
an authentication file. The live Z.ai/9router/Codex compatibility limits remain those documented
in [provider setup](PROVIDER-SETUP.md).

## Native controls and verification

- Use the inspector's **+** or the always-accessible header **Routines** menu in a narrow window.
- The detached editor supports create/edit, numeric interval entry (5–525,600 minutes), daily
  hour/minute, named timezone, explicit owner and provider. Editing an existing routine cannot
  change its owner. Cancel/Escape/close/quit honor dirty and accepted-save state.
- **Run Now** works while paused without moving the schedule. **Pause** does not implicitly Stop.
  **Resume…** opens the editor to review/authorize automatic sends and starts at a future occurrence.
- History shows the latest 100 records plus any active run (even after wall-clock rollback), typed
  errors, skipped ranges, Stop, and a link to the owner's chat. Export retains all records.
  Active-run discovery currently inspects that routine's ledger; very large history performance
  has not been benchmarked.
- The sample-only bundle cannot execute routines. Existing paused definitions are not enabled or
  bound to the composer provider automatically.

```sh
scripts/native-app.sh routine-smoke
scripts/native-app.sh routine-smoke --small
```

The smoke creates a daily routine through the native controller with an explicit group owner and
provider, renders its editor, runs an offline reply into the owner's direct chat, verifies the
group draft survives, resumes/pauses, closes/reopens, and renders restored history. These checks
exercise real views/controllers/services, not physical mouse/keyboard automation. Additional tests
cover consent drift, paused and blocked runs, catch-up/wake, Stop/partial text, exact deletion impact,
shutdown joining, and active history beyond the chronological page limit. No real provider is called.

R05's native functional path is delivered with this bounded evidence. Physical sleep/wake and
VoiceOver/keyboard interaction on the minimum supported OS still need the broader manual matrix.
The [native rewrite contract](NATIVE-REWRITE-CONTRACT.md) retains its attachment, accessibility,
minimum-OS and distribution gates; none are waived by this routine milestone.

## Primary API references

- Apple documents `.nextTime` and the first repeated occurrence in its
  [matching policy](https://developer.apple.com/documentation/foundation/calendar/matchingpolicy/nexttime)
  and [repeated-time policy](https://developer.apple.com/documentation/foundation/calendar/repeatedtimepolicy).
- The offset-gap fallback uses the documented
  [timezone transition API](https://developer.apple.com/documentation/foundation/timezone/nextdaylightsavingtimetransition(after:)).
  The Lord Howe workaround is supported by local regression evidence, not a claim Apple guarantees
  identical matching behavior on every OS release.
- Migration uses [inferred mapping](https://developer.apple.com/documentation/coredata/nsmappingmodel/inferredmappingmodel(forsourcemodel:destinationmodel:))
  and [persistent-store replacement](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator/replacepersistentstore(at:destinationoptions:withpersistentstorefrom:sourceoptions:type:)).
  Apple's [WAL guidance](https://developer.apple.com/library/archive/qa/qa1809/_index.html) explains why
  copying only the main SQLite file is unsafe.
