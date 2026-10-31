#!/bin/zsh
# Builds build/Snowpuff.app for Apple silicon and Intel Macs, signed ad hoc.
# ./build.sh install  — also copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

# One build per architecture, joined into one binary: a universal build needs Xcode, separate ones don't.
binaries=()
for arch in arm64 x86_64; do
    swift build -c release --arch $arch
    binaries+=("$(swift build -c release --arch $arch --show-bin-path)/Snowpuff")
done

app=build/Snowpuff.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Snowpuff"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Resources/TrayIcon*.png "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/ru.lproj" "$app/Contents/Resources/en.lproj"
printf '"NSMicrophoneUsageDescription" = "Snowpuff слушает микрофон только чтобы заметить, что ты дуешь на снег. Ничего не записывается и никуда не отправляется.";\n' > "$app/Contents/Resources/ru.lproj/InfoPlist.strings"
printf '"NSMicrophoneUsageDescription" = "Snowpuff listens for a puff of breath so you can blow on the snow. Nothing is recorded or sent anywhere.";\n' > "$app/Contents/Resources/en.lproj/InfoPlist.strings"

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Snowpuff 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Snowpuff.app
    ditto "$app" /Applications/Snowpuff.app
    open /Applications/Snowpuff.app
    echo "Installed /Applications/Snowpuff.app"
fi
