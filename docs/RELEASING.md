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
before:

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

The release notes become the version's `localizedDescription` in the feed — they are what a
sideloading client shows, so write them for a viewer rather than for a changelog.

## Then check the feed actually moved

The workflow is the last step of the release, not a background detail:

```bash
gh run list --workflow "Update sideloading source" --limit 1
```

Green now means the release is in the feed — the run asserts its own tag is present, which is the
check the six silent successes did not have. If it is red, the message names what is wrong: a
missing asset lists the names it did find, and a version mismatch names both numbers.
