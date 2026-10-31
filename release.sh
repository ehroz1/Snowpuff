#!/bin/zsh
# Publishes a release on GitHub, which both apps update from.
#   ./release.sh 1.2.0 "What changed"
# Sets the version everywhere, builds the Mac app (Snowpuff.dmg for people, Snowpuff.zip for the updater) and the
# Windows installer, commits, tags and uploads them. Needs gh signed in, mingw-w64 and the Windows Rust target.
set -euo pipefail
cd "$(dirname "$0")"

version=${1:?usage: ./release.sh <version> "notes"}
notes=${2:-"Snowpuff $version"}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must look like 1.2.0"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "commit or stash your changes first"; exit 1; }

plist=Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" $plist
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((build + 1))" $plist
sed -i '' "1,/^version = /s/^version = \".*\"/version = \"$version\"/" windows/Cargo.toml

./build.sh
dist=dist
rm -rf $dist && mkdir -p $dist
ditto -c -k --keepParent build/Snowpuff.app $dist/Snowpuff.zip

# The disk image: the app and a link to Applications. Opened from it, Snowpuff moves itself there.
stage=$(mktemp -d)
ditto build/Snowpuff.app "$stage/Snowpuff.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname Snowpuff -srcfolder "$stage" -format UDZO -ov $dist/Snowpuff.dmg
rm -rf "$stage"

windows/build.sh $dist

git add -A
git commit -q -m "Snowpuff $version"
git tag "v$version"
git push -q origin HEAD "v$version"
gh release create "v$version" $dist/Snowpuff.dmg $dist/Snowpuff.zip $dist/Snowpuff-Setup.exe \
    --title "Snowpuff $version" --notes "$notes"
echo "Released Snowpuff $version"
