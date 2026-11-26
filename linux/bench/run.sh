#!/usr/bin/env bash
# Runs the Linux app in a compositor inside a container, without a display, and leaves what happened in
# linux/bench/out/<scene>: a trace, the app's and the compositor's logs, and for Sway and niri, screenshots.
# Drawing is in software, so it shows whether things work, not how fast. Needs Docker.
#
#   linux/bench/run.sh sway    snowfall and the drift on the ground
#   linux/bench/run.sh niri    the same, in niri
#   linux/bench/run.sh kwin    the KWin script reports windows, and goes quiet once the app is killed
#   linux/bench/run.sh side    window snow across two displays side by side, in Sway
#   linux/bench/run.sh stacked the same with one display under the other
#   linux/bench/run.sh newyear the New Year's tree, countdown and midnight fireworks, in Sway
#   linux/bench/run.sh wallpaper snow in swaybg's picture: SNOWPUFF_BENCH_MEDIA=folder with wallpaper.jpg
#   linux/bench/run.sh fight    the bot in that picture, clicked at: the same, with SNOWPUFF_FIGHT=1
#   linux/bench/run.sh room     a friend's room in that picture: the same, with SNOWPUFF_BENCH_INVITE=snowpuff://join/…
#                               from `cargo run --example peer -- host` in net/
#
# Settings for the app can follow the scene, as lines of its settings file: run.sh sway autumn=1
# The holidays' previews pass through: SNOWPUFF_NEW_YEAR=1 SNOWPUFF_MIDNIGHT=1 run.sh sway
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
scene=${1:?usage: run.sh sway|niri|kwin|side|stacked|newyear|wallpaper|fight|room [setting=value…]}
shift
out=$here/out/$scene
rm -rf "$out"
mkdir -p "$out"
chmod 777 "$out"

docker build -q -t snowpuff-bench "$here" >/dev/null
echo "Building snowpuff…"
docker run --rm -v "$root:/src:ro" -v snowpuff-bench-target:/target -v snowpuff-bench-cargo:/usr/local/cargo/registry \
    -e CARGO_TARGET_DIR=/target -w /src/linux rust:1-bookworm \
    bash -c "apt-get update -qq && apt-get install -y -qq libwayland-dev >/dev/null && cargo build --release --locked -q"
echo "Running ${scene}…"
media=${SNOWPUFF_BENCH_MEDIA:-$here}
docker run --rm -v "$here:/bench:ro" -v "$out:/out" -v snowpuff-bench-target:/target:ro -v "$media:/media:ro" --user tester \
    -e SNOWPUFF_HALLOWEEN -e SNOWPUFF_HOUR -e SNOWPUFF_NEW_YEAR -e SNOWPUFF_MIDNIGHT -e SNOWPUFF_FIGHT -e SNOWPUFF_FIGHT_PRACTICE -e SNOWPUFF_BENCH_INVITE snowpuff-bench \
    dbus-run-session /bench/scene.sh "$scene" "$@"
cat "$out/trace"
