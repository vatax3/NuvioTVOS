---
name: parity-backlog
description: "Work through what earlier parity passes left open or declined — features the Android TV app (NuvioMedia/NuvioTV) has and this tvOS port does not — re-check each against today's tree and upstream, pick one with the user, port it and ship it. Use when the user asks what is missing / il nous manque quoi, wants to tackle the backlog / les features laissées de côté, or invokes /parity-backlog. Not for new upstream releases: that is upstream-parity."
---

# Working through the backlog

[`upstream-parity`](../upstream-parity/SKILL.md) brings the port forward one upstream window at a
time, and every window ends the same way: what it ports ships, and what it leaves open or declines
is written down and never picked up again. This skill is the other half. It reads what the passes
left behind, checks that it is still true, lets the user choose, and ports the choice as carefully
as a window would be.

Read `upstream-parity` first if it is not already loaded. Everything it says about reading
upstream over the network, the four verdicts, the bytes being the contract, and shipping applies
here unchanged; this file only says what is different.

## 1. There is no backlog file, on purpose

The backlog is **derived each time** from the documents that own it. A third list answering the
same question is how statuses have gone stale here three times (`upstream-parity` § 6). Read, in
this order:

1. The **latest "Still open from earlier windows" line** — the last one in
   [docs/PARITY-AUDIT.md](../../../docs/PARITY-AUDIT.md). Each window's section ends with it.
2. The **status table** near the top of that file: rows marked *Partial*, *Open* or *Missing*, and
   the "Missing:" clause inside a *Partial* row's text.
3. **Declined since 0.8.9** in [docs/UPSTREAM-PARITY.md](../../../docs/UPSTREAM-PARITY.md). Some of
   these are open in all but name ("Open, not declined", "Blocked rather than refused").
4. The **key sweep** (`upstream-parity` § 3) after regenerating the manifest at the marker tag.
   Any printed key without a verdict in the audit is a candidate; so is a key we name whose values
   differ from their enum.

## 2. Re-check every item before listing it

The list is only as good as its least-read line, and the lines here are exactly the ones nobody
reads again. For each item:

- **Is it already done?** An open line goes false silently when the work lands for another reason.
  Grep the tree for the feature and its keys before trusting the word "open".
- **Does upstream still have it, and in what form?** Read it at the marker tag over the network,
  never from the local clone at 0.8.9. A feature they rewrote or removed changes the cost.
- **Does the stated blocker still hold?** A decline is a reason, and reasons expire: a filter
  missing from our FFmpeg build, no YouTube path on tvOS, a sideloading feed with one channel, a
  measurement nobody has taken. A decline whose reason no longer holds is reported as
  **reopenable**, not listed as declined.
- **Is the item really ours to want?** Monetisation, their backend's private contracts and their
  translations stay declined unless the user says otherwise.

## 3. Present, then let the user choose

Give a short ranked list, each item with:
- what the viewer gets, in one line;
- its size, in rough lines of upstream code;
- its blocker, if any;
- whether it touches anything the Android app shares (synced settings, watch parties, account
  rows). Then `upstream-parity` § 5b applies: the bytes are the contract.

Rank small, unblocked, viewer-visible fixes first, and **say so when an item is a defect rather
than a missing feature** — a setting that disagrees with the Android app's outranks a new screen.
Ask with AskUserQuestion. Never start a large item unasked, and do one item per release unless the
user groups them.

## 4. Scope from their code, not their changelog

Fetch the whole files at the marker tag. For anything synced, read the sender **and** the receiver.
List every preference key the feature declares, so the manifest and `SettingsBlob` routing cover
them, and compare each key's values with their enum. Name every adaptation to tvOS in the code
comment and in the audit row: a port that departs silently is the next pass's false parity claim.

## 5. Build it as a window would be built

Tests that pin upstream's own literals, both `Resources/*.lproj` tables, `xcodegen generate` after
adding files, and the four build guards (`upstream-parity` § 7).

## 6. Close the line where it lives, in the same commit

- The audit gets a short section for the release ("Backlog: <item> (1.0.x)") with the usual
  two-column table and a `file:line` on every row.
- The item comes **off** the "Still open" line: write the corrected line at the end of the new
  section, so the latest one stays the source of truth.
- A reopened decline is removed from *Declined since 0.8.9*, not left beside its refutation.
- The status table row changes if the area's status did.
- `README.md` if a viewer-visible capability changed.
- **The marker does not move.** No upstream window was read.

## 7. Ship

Exactly as `upstream-parity` §§ 7–8: [docs/RELEASING.md](../../../docs/RELEASING.md), the version
only in `project.yml`, the IPA named `Nuvio-<version>-tvOS-unsigned.ipa`, the feed confirmed with
`gh run list --workflow "Update sideloading source"`, commits as `vatax3`, never the global git
config.
