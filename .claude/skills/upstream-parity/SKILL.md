---
name: upstream-parity
description: "Reconcile this tvOS port against new releases of the Android TV app it is ported from (NuvioMedia/NuvioTV), then port what belongs here and ship it. Use when the user asks to check the official repo / upstream / le dépôt officiel / Android TV and update the app, or invokes /upstream-parity. Not for answering questions about parity — docs/PARITY-AUDIT.md answers those without a release."
---

# Bringing the port forward

Nuvio for Apple TV is a port of [NuvioMedia/NuvioTV](https://github.com/NuvioMedia/NuvioTV). This
pass has been run five times; everything below is something a previous pass had to discover the
hard way. Follow it rather than re-deriving it.

The claim the project makes is narrow and checkable: **every upstream release up to the marker has
been read, and each change in it was ported, judged not applicable, or declined for a stated
reason.** The pass exists to keep that sentence true, and to find our own defects on the way —
which is where most of its value has actually come from.

## 1. Find the window

The marker is the first thing in [docs/UPSTREAM-PARITY.md](../../../docs/UPSTREAM-PARITY.md).

```
gh release list --repo NuvioMedia/NuvioTV --limit 25
gh release view <tag> --repo NuvioMedia/NuvioTV
```

Read every release published after the marker. Their notes are one line per merged PR with the
author, which is a good index and an unreliable summary — a line saying "improved X" has twice
turned out to be a rewrite of X.

## 2. Read it over the network, never from the local snapshot

There is a clone at `/Users/valentin/NuvioWork/_sources/NuvioTV`. **It sits detached at
`0.8.9-beta`**, so diffing a newer tag against it renders every intervening change as a deletion.
That has made a pass report a window backwards twice.

Either add a worktree at the tag:

```
git -C /Users/valentin/NuvioWork/_sources/NuvioTV worktree add --detach <scratch>/up-<tag> <tag>
```

…or stay on the network, which needs no local state and is what the beta.7 pass used:

```
gh api repos/NuvioMedia/NuvioTV/compare/<from>...<to> --jq '{commits:.total_commits, files:(.files|length)}'
gh api "repos/NuvioMedia/NuvioTV/compare/<from>...<to>?per_page=100" --paginate \
  --jq '.files[] | "\(.changes)\t\(.filename)"' | sort -rn | head -60
gh api "repos/NuvioMedia/NuvioTV/contents/<path>?ref=<tag>" --jq '.content' | base64 -d
```

The compare API truncates individual patches in a large window, so fetch whole files by `ref` for
anything that matters. Use the scratchpad for temporary files, never `/tmp`.

## 3. Two indexes, because each one lies on its own

**New preference keys** under `app/src/main/java/com/nuvio/tv/data/local/` — upstream adds a key
for anything a viewer can see, so the keys are the cheapest map of viewer-visible change. They
understate any window whose weight is a feature needing no key.

**The largest changed files**, from the sort above. That is what catches a 2,500-line subsystem
that shipped with one preference.

## 4. Four verdicts, not three

- **Ported** — built here, with the adaptation named.
- **Not applicable** — ExoPlayer, Compose, Android platform internals, their backend secrets.
  **Always record the reason**, or the next pass re-examines it from scratch.
- **Declined** — a decision. Monetisation, their translations, anything needing a measurement
  nobody has taken.
- **Already true here** — the one that saves the most work, because it is the verdict that stops a
  re-implementation. `group_plugin_streams_by_repository` was nearly rebuilt from scratch; their
  mpv track-refresh gate and their audio-fallback loop fix were both already ours.

A line that resists classification belongs in **declined with the doubt written down**, not in
ported with an optimistic guess. Two such doubts (`transparent_letterbox`, automatic subtitle sync)
were later resolved by upstream's own code — both confirming the doubt.

## 5. The question that actually pays: do we have the same defect?

Reading *why* upstream needed a change has been worth more than porting the change. Every one of
these was found that way, and none was on any changelog:

- the library and resume points living in purgeable Caches, where a system reclaim destroyed a
  local-only viewer's library permanently;
- deletion losing to pull, three times in three releases, in library, watch progress and addons;
- `L10n.format` accepting an `Int` for a `%@`, crashing the Episodes panel for every series since
  the day it shipped;
- a nested control that could not be focused, so **every stepper in the app was inert** — twice,
  five releases apart;
- the subtitle delay never reaching the addon tracks, which are the tracks most viewers use.

So for each upstream line, check our tree before writing a verdict. The answer is often that we
have the same bug in a worse form.

## 6. Where the record goes

- [docs/UPSTREAM-PARITY.md](../../../docs/UPSTREAM-PARITY.md) owns **the marker and the pre-0.8.9
  history**. Move the marker last, once the lot is shipped.
- [docs/PARITY-AUDIT.md](../../../docs/PARITY-AUDIT.md) owns **every window since 0.8.9**, one
  section each with a two-column table.
- Declines get one line in *Declined since 0.8.9* as well, so the list is readable without the
  argument.
- `README.md` when a viewer-visible capability or the upstream version line changes.

Two documents answering one question is how a status goes stale, which has happened three times
here. Keep the division above.

## 7. Ship it

[docs/RELEASING.md](../../../docs/RELEASING.md) has the full procedure. The two contracts that
break a release when broken:

- the version lives **only** in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`);
- the IPA is named exactly `Nuvio-<version>-tvOS-unsigned.ipa`.

Then confirm the sideloading feed actually moved — a green release with a stale feed is the exact
failure mode the workflow's assertion exists for:

```
gh run list --workflow "Update sideloading source"
```

Four build guards must stay green: `Scripts/check-settings-wiring.sh`,
`Scripts/check-localisation-keys.sh`, the workflow's feed assertion, and the compiler through
`L10n.format`'s `String`-only signature. New strings go into **both** `Resources/*.lproj` tables in
the same commit, and strings whose feature was removed come **out** of both.

Run `xcodegen generate` after adding any source file — `project.yml` is the source of truth.

## 8. Commit identity

Commits must not carry the user's real name:

```
git -c user.name=vatax3 -c user.email=vatax3@users.noreply.github.com commit ...
```

Never change the global git config.
