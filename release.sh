#!/bin/sh
# Releases a new version for everyone:
#   ./release.sh 1.3.0 "What changed"
# Sets the version in both apps, commits, and pushes a tag. GitHub Actions (.github/workflows/release.yml) then builds
# Snowpuff.dmg, Snowpuff.zip and Snowpuff-Setup.exe and publishes the release; both apps update from it by themselves.
set -eu
cd "$(dirname "$0")"

version=${1:?usage: ./release.sh <version> "notes"}
notes=${2:-"Snowpuff $version"}
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must look like 1.3.0"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first"; exit 1; }

plist=Resources/Info.plist
perl -0pi -e "s|(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*|\${1}$version|" $plist
build=$(perl -0ne 'print $1 if /<key>CFBundleVersion<\/key>\s*<string>(\d+)/' $plist)
perl -0pi -e "s|(<key>CFBundleVersion</key>\s*<string>)\d+|\${1}$((build + 1))|" $plist
perl -pi -e 'if (!$done && s/^version = ".*"/version = "'"$version"'"/) { $done = 1 }' windows/Cargo.toml

git add -A
git commit -q -m "Snowpuff $version"
git tag -a "v$version" -m "$notes"
git push -q origin HEAD "v$version"
echo "Tagged v$version: GitHub Actions builds and publishes it — https://github.com/ehroz1/Snowpuff/actions"
