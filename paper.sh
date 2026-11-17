
#!/data/data/com.termux/files/usr/bin/bash

set -Eeuo pipefail

API="https://fill.papermc.io/v3/projects/paper"
USER_AGENT="boxgums-paper-installer/1.0 (https://github.com/boxgums/resources)"

prompt() {
    if [ ! -r /dev/tty ]; then
        error "Interactive terminal required."
    fi

    printf "%s" "$1"
    read -r REPLY </dev/tty
}

error() {
    echo
    echo "ERROR: $1"
    exit 1
}

# Header
clear 2>/dev/null || true

echo "================================"
echo "       PaperMC Installer"
echo "          for Termux"
echo "================================"
echo

# Dependencies
echo "Checking dependencies..."

pkg update -y
pkg install -y curl jq coreutils grep

# Fetch available versions
echo
echo "Fetching available Paper versions..."

VERSIONS_JSON=$(curl -fsSL \
    --retry 3 \
    --connect-timeout 15 \
    -H "User-Agent: $USER_AGENT" \
    -H "Accept: application/json" \
    "$API") || error "Could not fetch Paper versions."

mapfile -t VERSIONS < <(
    jq -r '
        .versions
        | to_entries[]
        | .value[]
        | select(type == "string" and (contains("-") | not))
    ' <<< "$VERSIONS_JSON" | sort -Vr
)

[ "${#VERSIONS[@]}" -gt 0 ] ||
    error "No Paper versions found. API response: $(jq -c . <<< "$VERSIONS_JSON")"

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

[[ "$CHOICE" =~ ^[0-9]+$ ]] ||
    error "Invalid selection."

(( CHOICE >= 1 && CHOICE <= ${#VERSIONS[@]} )) ||
    error "Invalid selection."

VERSION="${VERSIONS[$((CHOICE - 1))]}"

echo
echo "Selected Minecraft $VERSION"

# Build channel selection
echo
echo "Available build channels:"
echo
echo "  1) Stable  - Recommended"
echo "  2) Beta    - Experimental"
echo "  3) Alpha   - Unstable"
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
    --retry 3 \
    --connect-timeout 15 \
    -H "User-Agent: $USER_AGENT" \
    -H "Accept: application/json" \
    "$API/versions/$VERSION") ||
    error "Could not fetch version metadata."

if ! JAVA_VERSION=$(jq -er '
    .version.java.version.minimum
    | if type == "number" then tostring
      elif type == "string" and test("^[0-9]+$") then .
      else empty
      end
' <<< "$VERSION_JSON" 2>/dev/null); then
    echo
    echo "Could not determine the required Java version."
    echo
    echo "PaperMC API response:"
    jq . <<< "$VERSION_JSON" 2>/dev/null || printf '%s\n' "$VERSION_JSON"
    exit 1
fi

[[ "$JAVA_VERSION" =~ ^[0-9]+$ ]] ||
    error "Invalid Java version returned by PaperMC: $JAVA_VERSION"

echo "Required Java: $JAVA_VERSION"

# Install and select Java
JAVA_HOME="$PREFIX/lib/jvm/java-${JAVA_VERSION}-openjdk"
JAVA_BIN="$JAVA_HOME/bin/java"

if [ ! -x "$JAVA_BIN" ]; then
    echo
    echo "Installing OpenJDK $JAVA_VERSION..."

    pkg install -y "openjdk-$JAVA_VERSION" ||
        error "Could not install OpenJDK $JAVA_VERSION. This version may not be available in Termux."
fi

[ -x "$JAVA_BIN" ] ||
    error "Java executable not found: $JAVA_BIN"

JAVA_INFO=$("$JAVA_BIN" -version 2>&1)

if [[ "$JAVA_INFO" =~ \"([0-9]+)(\.|\"|[[:space:]]) ]]; then
    INSTALLED_JAVA="${BASH_REMATCH[1]}"
else
    error "Could not identify the installed Java version."
fi

[ "$INSTALLED_JAVA" = "$JAVA_VERSION" ] ||
    error "Java version mismatch. Required: $JAVA_VERSION, installed: $INSTALLED_JAVA"

echo "Using Java $INSTALLED_JAVA"

# Fetch Paper builds
echo
echo "Finding $CHANNEL builds..."

BUILDS_JSON=$(curl -fsSL \
    --retry 3 \
    --connect-timeout 15 \
    -H "User-Agent: $USER_AGENT" \
    -H "Accept: application/json" \
    "$API/versions/$VERSION/builds") ||
    error "Could not fetch Paper builds."

if ! jq -e 'type == "array"' <<< "$BUILDS_JSON" >/dev/null; then
    echo
    echo "Unexpected PaperMC API response:"
    jq . <<< "$BUILDS_JSON" 2>/dev/null || printf '%s\n' "$BUILDS_JSON"
    exit 1
fi

BUILD=$(jq -c --arg channel "$CHANNEL" '
    [
        .[]
        | select(.channel == $channel)
        | select(.downloads."server:default".url != null)
    ]
    | sort_by(.id)
    | if length > 0 then last else empty end
' <<< "$BUILDS_JSON")

[ -n "$BUILD" ] ||
    error "No $CHANNEL build exists for Minecraft $VERSION."

PAPER_URL=$(jq -er '.downloads."server:default".url' <<< "$BUILD") ||
    error "Could not find Paper download URL."

PAPER_SHA256=$(jq -r '.downloads."server:default".checksums.sha256 // empty' <<< "$BUILD")
BUILD_ID=$(jq -r '.id' <<< "$BUILD")

# Server directory
SERVER_DIR="$HOME/minecraft/$VERSION"

mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

echo
echo "================================"
echo "Minecraft: $VERSION"
echo "Channel:   $CHANNEL"
echo "Build:     $BUILD_ID"
echo "Java:      $JAVA_VERSION"
echo "Directory: $SERVER_DIR"
echo "================================"

# Protect existing server
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
trap 'rm -f "$TEMP_JAR"' EXIT

rm -f "$TEMP_JAR"

curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    -H "User-Agent: $USER_AGENT" \
    "$PAPER_URL" \
    -o "$TEMP_JAR" ||
    error "Paper download failed."

[ -s "$TEMP_JAR" ] ||
    error "Downloaded file is empty."

# Verify SHA-256
echo
echo "Verifying download..."

if [ -n "$PAPER_SHA256" ]; then
    read -r DOWNLOADED_SHA256 _ < <(sha256sum "$TEMP_JAR")

    [ "$DOWNLOADED_SHA256" = "$PAPER_SHA256" ] ||
        error "SHA-256 verification failed."

    echo "SHA-256 verified."
else
    error "PaperMC did not provide a SHA-256 checksum. Download rejected."
fi

# Replace server jar only after successful verification
mv -f "$TEMP_JAR" server.jar
trap - EXIT

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
