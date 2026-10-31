#!/bin/zsh
# Builds the Windows app and its installer on macOS, into dist/Snowpuff-Setup.exe or the folder given.
# The installer carries the app, so the app is built first and handed to it.
# Needs: rustup target add x86_64-pc-windows-gnu, brew install mingw-w64.
set -euo pipefail

out=${1:-$(dirname "$0")/../dist}
out=${out:A}
cd "$(dirname "$0")"
target=x86_64-pc-windows-gnu
release=$PWD/target/$target/release
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc

cargo build --release --target $target --bin Snowpuff
SNOWPUFF_APP=$release/Snowpuff.exe cargo build --release --target $target --bin Snowpuff-Setup --features setup
mkdir -p "$out"
cp "$release/Snowpuff-Setup.exe" "$out/Snowpuff-Setup.exe"
echo "$out/Snowpuff-Setup.exe"
