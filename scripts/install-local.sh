#!/bin/sh

# helper script to build a signed release tart binary and install it for the current user
# usage: ./scripts/install-local.sh
#
# Installs tart.app into $PREFIX/share/tart and a "tart" launcher into $PREFIX/bin
# (PREFIX defaults to ~/.local), which takes precedence over a Homebrew-installed
# tart as long as $PREFIX/bin comes before /opt/homebrew/bin in PATH.
#
# The binary is ad-hoc signed, so it lacks the com.apple.vm.networking
# entitlement and --net-bridged is not available.

set -eu

PREFIX="${PREFIX:-$HOME/.local}"
APP_PATH="$PREFIX/share/tart/tart.app"
LAUNCHER_PATH="$PREFIX/bin/tart"

swift build --configuration release --product tart
BIN_PATH=$(swift build --configuration release --show-bin-path)

STAGING_PATH=$(mktemp -d)
trap 'rm -rf "$STAGING_PATH"' EXIT

mkdir -p "$STAGING_PATH/tart.app/Contents/MacOS" "$STAGING_PATH/tart.app/Contents/Resources"
cp -c "$BIN_PATH/tart" "$STAGING_PATH/tart.app/Contents/MacOS/tart"
cp -c Resources/embedded.provisionprofile "$STAGING_PATH/tart.app/Contents/embedded.provisionprofile"
cp -c Resources/Info.plist "$STAGING_PATH/tart.app/Contents/Info.plist"
cp -c "Resources/actool/UPW Tart.icns" "Resources/actool/Assets.car" "$STAGING_PATH/tart.app/Contents/Resources/"

codesign --sign - --entitlements Resources/tart-dev.entitlements --force "$STAGING_PATH/tart.app"

mkdir -p "$(dirname "$APP_PATH")" "$(dirname "$LAUNCHER_PATH")"
rm -rf "$APP_PATH"
mv "$STAGING_PATH/tart.app" "$APP_PATH"

cat > "$LAUNCHER_PATH" <<EOF
#!/bin/sh
exec "$APP_PATH/Contents/MacOS/tart" "\$@"
EOF
chmod +x "$LAUNCHER_PATH"

echo "Installed $APP_PATH"
echo "Launcher: $LAUNCHER_PATH"
