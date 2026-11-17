
#!/data/data/com.termux/files/usr/bin/bash

set -Eeuo pipefail

API="https://fill.papermc.io/v3/projects/paper"
USER_AGENT="boxgums-paper-installer/1.0 (https://github.com/boxgums/resources)"

# Always read interactive input from the terminal.
# This also allows: curl ... | bash

prompt() {
    printf "%s" "$1"
    read -r REPLY </dev/tty
}

error() {
    echo
    echo "ERROR: $1"
    exit 1
}

# Header
clear

echo "================================"
echo "       PaperMC Installer"
echo "          for Termux"
echo "================================"
echo

# Install dependencies
echo "Checking dependencies..."

pkg update -y

pkg install -y curl jq coreutils

# Fetch available versions
echo
echo "Fetching available Paper versions..."

VERSIONS_JSON=$(curl -fsSL \
    -H "User-Agent: $USER_AGENT" \
    "$API") || error "Could not fetch Paper versions."

mapfile -t VERSIONS < <(
    printf '%s' "$VERSIONS_JSON" |
    jq -r '.versions | to_entries[] | .value[]' |
    grep -v -- '-' |
    sort -V -r
)

[ "${#VERSIONS[@]}" -gt 0 ] || error "No Paper versions found."

# Version selection
echo
echo "Available Minecraft versions:"
echo

for i in "${!VERSIONS[@]}"; do
    printf "  %2d) %s\n" "$((i + 1))" "${VERSIONS[$i]}"
done

echo
prompt "Choose a version [1]: "
CHOICE="${REPLY:-1}"

[[ "$CHOICE" =~ ^[0-9]+$ ]] || error "Invalid selection."

(( CHOICE >= 1 && CHOICE <= ${#VERSIONS[@]} )) ||
    error "Invalid selection."

VERSION="${VERSIONS[$((CHOICE - 1))]}"

echo
echo "Selected Minecraft $VERSION"

# Build channel selection
echo
echo "Available build channels:"
echo
echo "  1) Stable  - Recommended for servers"
echo "  2) Beta    - Experimental builds"
echo "  3) Alpha   - Unstable development builds"
echo

prompt "Choose a channel [1]: "
CHANNEL_CHOICE="${REPLY:-1}"

case "$CHANNEL_CHOICE" in
    1) CHANNEL="STABLE" ;;
    2) CHANNEL="BETA" ;;
    3) CHANNEL="ALPHA" ;;
    *) error "Invalid channel." ;;
esac

# Fetch Java requirement
echo
echo "Checking Java requirement..."

VERSION_JSON=$(curl -fsSL \
    -H "User-Agent: $USER_AGENT" \
    "$API/versions/$VERSION") ||
    error "Could not fetch version information."

JAVA_VERSION=$(printf '%s' "$VERSION_JSON" |
    jq -r '.java.version.minimum // empty')

[[ "$JAVA_VERSION" =~ ^[0-9]+$ ]] ||
    error "Could not determine required Java version."

echo "Required Java: $JAVA_VERSION"

# Install and select the correct Java
JAVA_HOME="$PREFIX/lib/jvm/java-${JAVA_VERSION}-openjdk"
JAVA_BIN="$JAVA_HOME/bin/java"

if [ ! -x "$JAVA_BIN" ]; then
    echo
    echo "Installing OpenJDK $JAVA_VERSION..."

    pkg install -y "openjdk-$JAVA_VERSION" ||
        error "Could not install OpenJDK $JAVA_VERSION. Check Termux package availability."

fi

[ -x "$JAVA_BIN" ] ||
    error "Java executable not found: $JAVA_BIN"

INSTALLED_JAVA=$("$JAVA_BIN" -version 2>&1 |
    sed -n 's/.*version "\([0-9]*\).*/\1/p' |
    head -n 1)

[ "$INSTALLED_JAVA" = "$JAVA_VERSION" ] ||
    error "Installed Java version does not match the requirement."

echo "Using Java $INSTALLED_JAVA"

# Fetch Paper builds
echo
echo "Finding $CHANNEL builds..."

BUILDS_JSON=$(curl -fsSL \
    -H "User-Agent: $USER_AGENT" \
    "$API/versions/$VERSION/builds") ||
    error "Could not fetch Paper builds."

BUILD=$(printf '%s' "$BUILDS_JSON" |
    jq -c --arg channel "$CHANNEL" '
        [
            .[]
            | select(.channel == $channel)
            | select(.downloads."server:default".url != null)
        ]
        | sort_by(.id)
        | last // empty
    ')

[ -n "$BUILD" ] ||
    error "No $CHANNEL build exists for Minecraft $VERSION."

PAPER_URL=$(printf '%s' "$BUILD" |
    jq -r '.downloads."server:default".url')

PAPER_NAME=$(printf '%s' "$BUILD" |
    jq -r '.downloads."server:default".name')

PAPER_SHA256=$(printf '%s' "$BUILD" |
    jq -r '.downloads."server:default".checksums.sha256 // empty')

BUILD_ID=$(printf '%s' "$BUILD" |
    jq -r '.id')

echo
echo "Minecraft: $VERSION"
echo "Channel:   $CHANNEL"
echo "Build:     $BUILD_ID"
echo "Java:      $JAVA_VERSION"

# Server directory
SERVER_DIR="$HOME/minecraft/$VERSION"

mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

echo
echo "Server directory: $SERVER_DIR"

# Protect existing server.jar
if [ -f server.jar ]; then
    echo
    prompt "server.jar already exists. Replace it? [y/N]: "

    case "$REPLY" in
        y|Y|yes|YES) ;;
        *) error "Installation cancelled." ;;
    esac
fi

# Download Paper
echo
echo "Downloading Paper..."

TEMP_JAR="server.jar.tmp"

rm -f "$TEMP_JAR"

curl -fL \
    --retry 3 \
    -H "User-Agent: $USER_AGENT" \
    "$PAPER_URL" \
    -o "$TEMP_JAR" ||
    error "Paper download failed."

# Verify SHA-256
echo
echo "Verifying download..."

if [ -n "$PAPER_SHA256" ]; then
    DOWNLOADED_SHA256=$(sha256sum "$TEMP_JAR" | awk '{print $1}')

    [ "$DOWNLOADED_SHA256" = "$PAPER_SHA256" ] ||
        error "SHA-256 verification failed."

    echo "SHA-256 verified."
else
    echo "Warning: No SHA-256 checksum was provided."
fi

mv -f "$TEMP_JAR" server.jar

# EULA
echo
echo "Minecraft EULA:"
echo "https://aka.ms/MinecraftEULA"
echo

if [ ! -f eula.txt ] || ! grep -qx 'eula=true' eula.txt; then
    prompt "Do you accept the Minecraft EULA? [y/N]: "

    case "$REPLY" in
        y|Y|yes|YES)
            echo "eula=true" > eula.txt
            ;;
        *)
            error "EULA not accepted. Server will not start."
            ;;
    esac
fi

# Start server
echo
echo "================================"
echo "       Installation complete!"
echo "================================"
echo
echo "Minecraft: $VERSION"
echo "Channel:   $CHANNEL"
echo "Build:     $BUILD_ID"
echo "Java:      $JAVA_VERSION"
echo "Directory: $SERVER_DIR"
echo

echo "Starting Paper..."
echo

export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

exec "$JAVA_BIN" \
    -Xms1G \
    -Xmx4G \
    -jar server.jar \
    --nogui
