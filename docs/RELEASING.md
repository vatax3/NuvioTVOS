# Cutting a release

The sideloading feed is generated, not written: `.github/workflows/update-sideloading-source.yml`
runs `Scripts/update-altstore-source.py` on every published release, reads the GitHub release list
back, and commits `altstore-source.json`. Nothing here needs editing by hand.

That only holds while the release matches two contracts. Both have been broken once, so both are
now checked.

## The two contracts

**The version lives in `project.yml` and nowhere else.** `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` under each target. The checked-in `Info.plist` files are generated from
them and reference them as `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`, so there is one
number to bump per release, not three.

> Written as literals, they drifted: the build number was bumped in the settings for six releases
> running and left at 18 in the plists, so the plist claimed a build the app had not been since
> 1.0.16 — and the feed, which read the plist, published the stale number.

**The IPA asset is named `Nuvio-<version>-tvOS-unsigned.ipa`.** Exactly that. The generator looks
for that name and nothing else.

> 1.0.17 through 1.0.22 were packaged as `Nuvio-1.0.17.ipa` and friends. Every one of them was
> passed over, the regenerated feed came out byte-identical, the commit step found no diff and
> exited zero. Six green runs, and the feed still advertising 1.0.16.

## The steps

```bash
VERSION=1.0.23

# 1. One place. Both targets.
#    project.yml: MARKETING_VERSION -> $VERSION, CURRENT_PROJECT_VERSION -> next integer
xcodegen generate
git commit -am "Release $VERSION" && git push
```

Archive from a detached worktree rather than the working tree, so the build contains only what was
committed — an untracked file that compiles locally and does not exist for anyone else has shipped
before. Two things the worktree needs beyond `Vendor/`: **Xcode 27 or later** (AetherEngine's floor,
Swift 6.4 — Xcode 26 cannot compile it), and a package resolve, which `xcodegen generate` sets up and
the first `xcodebuild` performs. `Packages/PlayerEngineKit` is in the repository, so the worktree
carries it; its dependencies are fetched from the network at their pinned versions.

```bash
# 2. Build
git worktree add --detach ../nuvio-release-$VERSION HEAD
ln -s "$PWD/Vendor" ../nuvio-release-$VERSION/Vendor
cd ../nuvio-release-$VERSION && xcodegen generate
xcodebuild -project NuvioTVOS.xcodeproj -scheme NuvioTVOS \
  -destination 'generic/platform=tvOS' -archivePath build/Nuvio.xcarchive \
  CODE_SIGNING_ALLOWED=NO archive

# 3. Package — the name is the contract
mkdir -p build/ipa/Payload
cp -R build/Nuvio.xcarchive/Products/Applications/Nuvio.app build/ipa/Payload/
(cd build/ipa && zip -qry "../Nuvio-$VERSION-tvOS-unsigned.ipa" Payload)
```

Confirm the archive carries the numbers you meant before publishing it, because after this point
they are what the feed will advertise:

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" \
  build/ipa/Payload/Nuvio.app/Info.plist
```

```bash
# 4. Publish
gh release create "v$VERSION" "build/Nuvio-$VERSION-tvOS-unsigned.ipa" \
  --title "$VERSION" --notes-file notes.md

cd - && git worktree remove ../nuvio-release-$VERSION
```

## Writing the notes

The release notes become the version's `localizedDescription` in the feed, so they are read in two
places at once: the GitHub release page and a sideloading client. Both audiences are strangers to
the work. Four rules, and they are not negotiable per release:

1. **English.** Every release, regardless of the language the work was discussed in.
2. **A changelog, not a story.** Group the changes under short headings — *Added*, *Changed*,
   *Fixed* — and give each entry one or two sentences: what changed, and what it means for someone
   using the app. Longest-reaching change first.
3. **Impersonal.** No first person, no second person, no account of how the work went, what was
   tried, what was learned, or who asked for it. The subject of every sentence is the app or the
   feature, never a developer or a particular user. "Playback now bitstreams E-AC-3 JOC", not
   "I fixed Atmos for you".
4. **Legible on its own.** Someone reading the repository months later, with no memory of the
   conversation, should understand each entry without opening a diff. Name features as the UI names
   them; expand an acronym the first time it appears.

Technical detail is welcome where it explains a user-visible consequence. Detail that only explains
the implementation belongs in the commit message.

> Through 1.0.51 the notes were written in French as a first-person account of the session. They
> read as a diary to anyone who was not in it, and a sideloading client showed that diary as the
> version's description.

## Then check the feed actually moved

The workflow is the last step of the release, not a background detail:

```bash
gh run list --workflow "Update sideloading source" --limit 1
```

Green now means the release is in the feed — the run asserts its own tag is present, which is the
check the six silent successes did not have. If it is red, the message names what is wrong: a
missing asset lists the names it did find, and a version mismatch names both numbers.

> **One release fires the workflow twice.** `gh release create` with an asset emits `published`
> and then `edited` a couple of seconds apart. Until 1.0.40 the two raced for the same push and the
> loser went red with `cannot lock ref` — a failure that meant the feed was already correct, which
> is the worst kind of red on a check whose whole job is to be believed. The workflow is serialised
> now, so the second run finds no diff and exits green. If you see two runs for one tag, that is
> expected; both should be green.
