#!/data/data/com.termux/files/usr/bin/bash

set -e

API="https://fill.papermc.io/v3/projects/paper"
USER_AGENT="termux-papermc-installer/1.0 (https://github.com/YOURNAME/YOURREPO)"

clear

echo "=============================="
echo "      PaperMC Installer"
echo "          for Termux"
echo "=============================="
echo

# Check required tools
for command in curl jq; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Installing $command..."
        pkg install -y "$command"
    fi
done

echo "Getting available Paper versions..."
echo

VERSIONS_JSON=$(curl -fsSL \
    -H "User-Agent: $USER_AGENT" \
    "$API")

# Extract versions while removing release candidates/pre-releases.
mapfile -t VERSIONS < <(
    echo "$VERSIONS_JSON" |
    jq -r '.versions | to_entries[] | .value[]' |
    grep -v -- '-' |
    sort -V -r
)

if [ "${#VERSIONS[@]}" -eq 0 ]; then
    echo "Could not find any Paper versions."
    exit 1
fi

echo "Available versions:"
echo

for i in "${!VERSIONS[@]}"; do
    printf "  %2d) %s\n" "$((i + 1))" "${VERSIONS[$i]}"
done

echo
read -rp "Choose a Minecraft version [1]: " CHOICE

CHOICE=${CHOICE:-1}

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    echo "Invalid choice."
    exit 1
fi

if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#VERSIONS[@]}" ]; then
    echo "Invalid choice."
    exit 1
fi

VERSION="${VERSIONS[$((CHOICE - 1))]}"

echo
echo "Selected: Minecraft $VERSION"
echo

# Get version information
echo "Checking Java requirement..."

VERSION_JSON=$(curl -fsSL \
    -H "User-Agent: $USER_AGENT" \
    "$API/versions/$VERSION")

JAVA_VERSION=$(echo "$VERSION_JSON" | jq -r '.java.version.minimum')

if [ -z "$JAVA_VERSION" ] || [ "$JAVA_VERSION" = "null" ]; then
    echo "Could not determine the required Java version."
    exit 1
fi

echo "Required Java: $JAVA_VERSION"
echo

# Install the required Java version if necessary.
if ! command -v "java" >/dev/null 2>&1; then
    echo "Java is not installed."
    echo "Installing OpenJDK $JAVA_VERSION..."
    pkg install -y "openjdk-$JAVA_VERSION"
else
    CURRENT_JAVA=$(java -version 2>&1 |
        sed -n 's/.*version "\([0-9]*\).*/\1/p' |
        head -n 1)

    if [ "$CURRENT_JAVA" != "$JAVA_VERSION" ]; then
        echo "Current Java: ${CURRENT_JAVA:-unknown}"
        echo "Installing OpenJDK $JAVA_VERSION..."
        pkg install -y "openjdk-$JAVA_VERSION"
    else
        echo "Java $JAVA_VERSION is already installed."
    fi
fi

# Find latest stable Paper build.
echo
echo "Finding latest stable Paper build..."

BUILDS_JSON=$(curl -fsSL \
    -H "User-Agent: $USER_AGENT" \
    "$API/versions/$VERSION/builds")

PAPER_URL=$(echo "$BUILDS_JSON" |
    jq -r '
        first(
            .[]
            | select(.channel == "STABLE")
            | .downloads."server:default".url
        )
    ')

PAPER_NAME=$(echo "$BUILDS_JSON" |
    jq -r '
        first(
            .[]
            | select(.channel == "STABLE")
            | .downloads."server:default".name
        )
    ')

PAPER_SHA256=$(echo "$BUILDS_JSON" |
    jq -r '
        first(
            .[]
            | select(.channel == "STABLE")
            | .downloads."server:default".checksums.sha256
        )
    ')

if [ -z "$PAPER_URL" ] || [ "$PAPER_URL" = "null" ]; then
    echo
    echo "No stable Paper build exists for Minecraft $VERSION."
    echo
    echo "Paper may not support this version yet."
    exit 1
fi

echo "Build: $PAPER_NAME"
echo

# Create server directory.
SERVER_DIR="$HOME/minecraft/$VERSION"

mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

echo "Server directory:"
echo "$SERVER_DIR"
echo

# Download Paper.
echo "Downloading Paper..."

curl -fL \
    -H "User-Agent: $USER_AGENT" \
    "$PAPER_URL" \
    -o server.jar

echo
echo "Download complete."

# Verify SHA-256.
echo
echo "Checking SHA-256..."

DOWNLOADED_SHA256=$(sha256sum server.jar | awk '{print $1}')

if [ "$DOWNLOADED_SHA256" != "$PAPER_SHA256" ]; then
    echo
    echo "ERROR: SHA-256 checksum does not match."
    echo
    rm -f server.jar
    exit 1
fi

echo "Checksum OK."

# Create EULA.
if [ ! -f eula.txt ]; then
    echo
    echo "Accepting Minecraft EULA..."
    echo "eula=true" > eula.txt
fi

echo
echo "=============================="
echo "Installation complete!"
echo "=============================="
echo
echo "Minecraft: $VERSION"
echo "Java:      $JAVA_VERSION"
echo "Paper:     $PAPER_NAME"
echo "Directory: $SERVER_DIR"
echo
echo "Starting server..."
echo

exec java -Xms2G -Xmx6G -jar server.jar --nogui
