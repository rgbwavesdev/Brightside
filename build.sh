#!/bin/zsh
# Builds Brightside.app and installs it to ~/Applications.
set -e
cd "${0:A:h}"
mkdir -p build

APP="build/Brightside.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14 \
  Sources/*.swift -o "$APP/Contents/MacOS/Brightside"
cp Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || Tools/make_icon.swift -nt build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  rm -rf $ICONSET && mkdir -p $ICONSET
  swift Tools/make_icon.swift build/icon.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICONSET -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/Brightside.app
cp -R "$APP" ~/Applications/
echo "Installed to ~/Applications/Brightside.app"
