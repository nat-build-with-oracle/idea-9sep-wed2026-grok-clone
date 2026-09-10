# Group draft mentions

Use **Mention** above the composer to insert a current group member at the cursor, or type:

```text
@Research
@"Writing Partner"
\@literal-handle
```

A mention starts at the beginning, whitespace or opening/separator punctuation. Bare names
contain Unicode letters/numbers, `_` or `-`; names containing spaces or other punctuation
use JSON-string quoting and escaping. Names match case-sensitively after NFC normalization.
Emails, URL spans and code spans/fences are not recipient instructions. A routing escape
`\@` at a mention boundary means literal `@`; embedded non-routing escapes, code and URL
text stay unchanged. Inline backtick delimiters match exact run lengths; an unmatched inline
run stays literal. Fences start at a line boundary (up to three spaces), use at least three
backticks or tildes, and close with the same marker at least as long followed only by spaces
or tabs on that line. An inline match may close at the first equal-length boundary run,
but cannot cross a fence boundary to pair with its contents. An unclosed fence extends
to the end of the draft. These are explicit
routing exclusions, not a complete Markdown or email-address validator.

## Identity and user experience

- The picker inserts `@"Name"{full-uuid}` as plain text, replacing the native selection.
  This syntax persists in the ordinary local draft across restart. It is deliberately visible,
  not an unpersisted rich-text chip. Native undo applies to insertion.
- Bound tokens require both the current member UUID and matching name. A removed member or
  renamed binding is stale, not silently redirected. Reinsert it with Mention.
- Name-only mentions require one unique current member. Duplicate names are resolved by
  picking a member; menus, recipient preview and confirmation include a distinguishing ID
  prefix. Full identity is available in help/accessibility text.
- First mention occurrence determines reply order; repeating a member does not create another
  request. One to six members are supported. Any incomplete, malformed, unknown, ambiguous
  or stale recognized mention blocks the **whole send**, even alongside valid mentions.
- Mentions **replace** manual recipients. The ordered preview becomes read-only; edit mentions
  to change it. Removing all mentions restores the previous manual selection. Manual changes
  cannot retarget a reviewed mention send.
- Every mention send uses the existing group-round review, **including one recipient**.
  Nothing is sent and no credential is read merely because the review is open.
- Insertions are one-shot and bound to conversation, workspace context and expected draft.
  Navigation, newer text, disabled editor or active marked text rejects the insertion. Finish
  composing and choose Mention again; the app does not queue a surprise edit after IME.

The parser only sees the current **group user draft**. Direct-chat text, previous messages,
assistant output, reply previews and attachment bodies never change recipients.

## Flow and transmission boundary

```text
raw local draft + current group members
  -> resolve all mentions, or show error and retain draft
  -> ordered identities + readable message text
  -> capture routing signature and full round transmission plan
  -> review names/identities, provider/model, context, files, request count
  -> confirm; re-resolve raw draft and compare captured identities
  -> existing whole-plan/revision checks, then credential authorization
  -> atomic one-user/N-generation commit and exact-source draft clear
  -> existing ordered replies, Stop round and manual per-member Retry
```

Valid bound `{UUID}` suffixes are removed from `SendCommand.text`/`SendRoundCommand.text`;
readable `@"Name"` spelling remains. Literal routing escapes are unescaped outside excluded
code/URLs. Local bindings therefore do not enter the stored user transcript or its later
provider context. Drafts and user-selected workspace exports **do** contain raw local bindings;
they are identifiers, not credentials. Arbitrary UUID text outside a mention is not scrubbed.

The transient `MentionRoutingSnapshot` binds conversation, raw source, readable text and
ordered UUID/name snapshots. Confirmation re-resolves and compares this snapshot instead
of comparing manual selections. Draft/provider/member changes require fresh review.
The existing coordinator also compares every request fingerprint before credentials and
rejects stale revisions during authorization before committing or dispatching requests.

Both send commands accept optional transient `expectedDraftText`. When supplied, atomic
clear requires exact raw source equality as well as matching reply and attachment identities;
otherwise legacy trimmed comparison remains. A newer draft survives. No draft entity,
Core Data version or JSON export version changes for mentions.

## Verification and remaining boundaries

- `GroupMentionTests`: grammar, Unicode, identity, order, lexical exclusions, sanitized output
  and long input; pure text only.
- `MatchingDraftSourceTests`: real temporary SQLite atomic raw-source matching, sanitized
  transcript, newer-draft preservation and legacy behavior for single/round sends.
- `MentionWorkspaceTests`: offline routing, consent, persistence, stale-review and context
  isolation at the native presentation boundary.
- `NativeComposerAppKitTests`: hosted native selection replacement/spacing/undo and stale,
  disabled, marked-text and exactly-once command guards.
- `scripts/native-app.sh mention-smoke` (`--minimum` for 760×600): isolated provider fixture
  and native Light/Dark composer/error/confirmation renders. No normal user workspace or
  preference mutation, real credentials or live network.

These checks do not prove physical keyboard/IME/VoiceOver operation, actual unlocked-window
focus, macOS 14 runtime support, real provider entitlement, signing or notarization. Mention
routing grants no tools, shell, file access or private third-party API permission. Existing
[group round](GROUP-ROUNDS.md), [provider](PROVIDER-CORE.md),
[attachment](ATTACHMENTS.md) and [export](WORKSPACE-EXPORT.md) boundaries remain unchanged.
