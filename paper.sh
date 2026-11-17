#!/data/data/com.termux/files/usr/bin/bash
# PaperMC installer and manager for Termux
# Copyright (C) boxgums. Licensed under GPL-3.0-or-later.
#
# Usage:  curl -fsSL https://raw.githubusercontent.com/boxgums/resources/main/paper.sh | bash
#
# Everything runs inside main(), so bash has parsed the whole script before
# anything executes. That stops programs like `pkg` from swallowing the rest of
# the script when it is piped in with `curl | bash`. Questions are read from the
# terminal (/dev/tty), and every helper program gets </dev/null for stdin.

set -Eeuo pipefail

readonly API="https://fill.papermc.io/v3/projects/paper"
readonly MOJANG_MANIFEST="https://launchermeta.mojang.com/mc/game/version_manifest_v2.json"
readonly UA="boxgums-paper-installer/2.0 (https://github.com/boxgums/resources)"
readonly EULA_URL="https://aka.ms/MinecraftEULA"
readonly CMD_VERSION=1   # bump when mcstart / mcwhitelist change, so installs update them once

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOT="${PAPER_HOME:-$HOME/minecraft}"   # PAPER_HOME / PAPER_INPUT exist mainly for testing
INPUT="${PAPER_INPUT:-/dev/tty}"

API_BODY="" API_ERR="" REPLY="" MENU_IDX=0 PART_FILE=""
VERSION="" CHANNEL="" BUILD_ID="" BUILD_URL="" BUILD_SHA="" BUILD_SIZE=""
JAVA_REQ="" JAVA_BIN="" JAVA_MAJOR="" RAM_MB="" DIR="" KEPT_JAR=0
WHITELIST=0 MCSTART_OK=0

# ───────────────────────────── interface ─────────────────────────────

setup_ui() {
    RST="" BOLD="" DIM="" ACC="" GRN="" YEL="" RED=""
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
        local colors
        colors=$(tput colors 2>/dev/null || echo 8)
        RST=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m'
        if [ "$colors" -ge 256 ] 2>/dev/null; then
            ACC=$'\e[38;5;110m' GRN=$'\e[38;5;108m' YEL=$'\e[38;5;179m' RED=$'\e[38;5;167m'
        else
            ACC=$'\e[36m' GRN=$'\e[32m' YEL=$'\e[33m' RED=$'\e[31m'
        fi
    fi
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*)
            S_OK="✔" S_ERR="✖" S_WARN="▲" S_DOT="•" S_ARROW="›" S_LINE="─" UTF=1 ;;
        *)
            S_OK="+" S_ERR="x" S_WARN="!" S_DOT="-" S_ARROW=">" S_LINE="-" UTF=0 ;;
    esac
    RULE=""
    local i
    for ((i = 0; i < 46; i++)); do RULE+="$S_LINE"; done
}

banner() {
    clear 2>/dev/null || true
    printf '\n'
    if [ "$UTF" = 1 ]; then
        printf '%s  ╔═╗ ╔═╗ ╔═╗ ╔═╗ ╦═╗%s\n' "$ACC$BOLD" "$RST"
        printf '%s  ╠═╝ ╠═╣ ╠═╝ ║╣  ╠╦╝%s\n' "$ACC$BOLD" "$RST"
        printf '%s  ╩   ╩ ╩ ╩   ╚═╝ ╩╚═%s\n' "$ACC$BOLD" "$RST"
    else
        printf '%s  P A P E R%s\n' "$ACC$BOLD" "$RST"
    fi
    printf '  %sMinecraft server installer for Termux%s\n' "$DIM" "$RST"
    printf '  %s%s%s\n' "$DIM" "$RULE" "$RST"
}

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  %s%s%s %s\n' "$GRN" "$S_OK" "$RST" "$*"; }
info() { printf '  %s%s%s %s\n' "$ACC" "$S_DOT" "$RST" "$*"; }
warn() { printf '  %s%s%s %s\n' "$YEL" "$S_WARN" "$RST" "$*" >&2; }
step() { printf '\n%s[%s/%s]%s %s%s%s\n' "$ACC" "$1" "$2" "$RST" "$BOLD" "$3" "$RST"; }
die()  { printf '\n  %s%s Error:%s %s\n\n' "$RED" "$S_ERR" "$RST" "$*" >&2; exit 1; }

cleanup() { [ -n "$PART_FILE" ] && rm -f "$PART_FILE"; return 0; }

# ───────────────────────────── input ─────────────────────────────

# ask "Question" [default]  → sets REPLY (trimmed). Reads from the terminal, not stdin.
ask() {
    local prompt=$1 def=${2-}
    printf '\n  %s%s%s %s%s%s ' "$ACC" "$S_ARROW" "$RST" "$BOLD" "$prompt${def:+ [$def]}:" "$RST"
    read -r REPLY <&3 || die "No input available. Run this in an interactive terminal."
    REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
    REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
    REPLY=${REPLY:-$def}
}

# confirm "Question" y|n  → exit status 0 for yes. Default applies on empty answer.
confirm() {
    local def=${2:-n} hint="y/N"
    [ "$def" = y ] && hint="Y/n"
    while :; do
        ask "$1 ($hint)" ""
        case "${REPLY:-$def}" in
            [Yy] | [Yy][Ee][Ss]) return 0 ;;
            [Nn] | [Nn][Oo]) return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

# menu "Title" default limit item...  → sets MENU_IDX (0-based). Re-asks until valid.
menu() {
    local title=$1 def=$2 limit=$3
    shift 3
    local -a items=("$@")
    local n=${#items[@]} shown i
    shown=$limit
    if [ "$shown" -gt "$n" ]; then shown=$n; fi
    while :; do
        printf '\n  %s%s%s\n\n' "$BOLD" "$title" "$RST"
        for ((i = 0; i < shown; i++)); do
            printf '   %s%3d%s  %s\n' "$ACC" "$((i + 1))" "$RST" "${items[$i]}"
        done
        if [ "$shown" -lt "$n" ]; then
            printf '   %s  m%s  %sshow all %d%s\n' "$ACC" "$RST" "$DIM" "$n" "$RST"
        fi
        ask "Your choice" "$def"
        if [ "$REPLY" = m ] && [ "$shown" -lt "$n" ]; then
            shown=$n
        elif [[ $REPLY =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$n" ]; then
            MENU_IDX=$((REPLY - 1))
            return 0
        else
            warn "Please type a number from 1 to $n."
        fi
    done
}

# ───────────────────────────── network ─────────────────────────────

# api_get URL  → body in API_BODY. Checks HTTP status and that the body is JSON.
api_get() {
    local raw code
    API_BODY="" API_ERR=""
    raw=$(curl -sSL --retry 3 --connect-timeout 15 --max-time 60 \
        -H "User-Agent: $UA" -H "Accept: application/json" \
        -w $'\n%{http_code}' "$1" 2>&1 </dev/null) || {
        API_ERR="network error (${raw%%$'\n'*})"
        return 1
    }
    code=${raw##*$'\n'}
    raw=${raw%$'\n'*}
    if [[ $code != 2* ]]; then
        API_ERR="HTTP $code $(jq -r '.message? // empty' <<<"$raw" 2>/dev/null | head -c 200 || true)"
        return 1
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$raw"; then
        API_ERR="the response was not valid JSON"
        return 1
    fi
    API_BODY=$raw
}

excerpt() { jq -c . <<<"$API_BODY" 2>/dev/null | head -c 700 || true; }

# ───────────────────────────── environment ─────────────────────────────

check_termux() {
    if [ "${PAPER_ALLOW_NON_TERMUX:-0}" != 1 ] && [[ $PREFIX != */com.termux/* ]]; then
        die "This installer is made for Termux on Android. Install Termux from F-Droid or GitHub and run it there."
    fi
    open_input
}

# Open the terminal once on fd 3; all questions and the server console read from it.
open_input() {
    { exec 3<"$INPUT"; } 2>/dev/null ||
        die "No interactive terminal found ($INPUT). Run the installer from a Termux session."
}

pkg_install() {
    pkg install -y "$@" </dev/null && return 0
    warn "Install failed. Refreshing package lists and trying once more..."
    pkg update -y </dev/null || true
    pkg install -y "$@" </dev/null
}

ensure_tools() {
    local -a missing=()
    command -v curl >/dev/null || missing+=(curl)
    command -v jq >/dev/null || missing+=(jq)
    command -v sha256sum >/dev/null || missing+=(coreutils)
    if [ "${#missing[@]}" -gt 0 ]; then
        info "Installing helper tools: ${missing[*]}"
        pkg_install "${missing[@]}" || die "Could not install ${missing[*]}. Check your internet connection and try again."
    fi
    ok "Helper tools ready"
}

# ───────────────────────────── version & build ─────────────────────────────

choose_version() {
    step 1 6 "Choose a Minecraft version"
    api_get "$API" || die "Could not get the Paper version list: $API_ERR"
    local -a versions labels
    mapfile -t versions < <(
        jq -r '.versions | to_entries[] | .value[]' <<<"$API_BODY" 2>/dev/null |
            grep -E '^[0-9]+(\.[0-9]+)+$' | sort -Vru || true
    )
    [ "${#versions[@]}" -gt 0 ] ||
        die "PaperMC returned no release versions. Response (trimmed): $(excerpt)"
    labels=("${versions[@]}")
    labels[0]+="   ${DIM}newest${RST}"
    menu "Minecraft versions (newest first)" 1 10 "${labels[@]}"
    VERSION=${versions[$MENU_IDX]}
    ok "Selected Minecraft $VERSION"
}

# Fetches builds for $VERSION and lets the user pick a channel that actually has downloads.
choose_channel() {
    step 2 6 "Choose a build type"
    api_get "$API/versions/$VERSION/builds" || die "Could not get builds for $VERSION: $API_ERR"
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$API_BODY" ||
        die "Unexpected builds response from PaperMC: $(excerpt)"

    local have c
    have=$(jq -r '.[] | select(.downloads."server:default".url != null
                               and .downloads."server:default".checksums.sha256 != null) | .channel' \
        <<<"$API_BODY" | sort -u || true)

    local -a keys=() labels=() missing=()
    for c in RECOMMENDED STABLE BETA ALPHA; do
        if grep -qx "$c" <<<"$have"; then
            keys+=("$c")
            case $c in
                RECOMMENDED) labels+=("Recommended  ${DIM}tested, best choice for most people${RST}") ;;
                STABLE) labels+=("Stable       ${DIM}production-ready${RST}") ;;
                BETA) labels+=("Beta         ${DIM}feature-complete, may have bugs${RST}") ;;
                ALPHA) labels+=("Alpha        ${DIM}early and unstable, expect problems${RST}") ;;
            esac
        else
            missing+=("$c")
        fi
    done
    if [ "${#keys[@]}" -eq 0 ]; then
        warn "Minecraft $VERSION has no downloadable Paper builds yet."
        return 1
    fi
    [ "${#missing[@]}" -eq 0 ] || say "${DIM}Not available for $VERSION: ${missing[*]}${RST}"
    menu "Build types for $VERSION" 1 10 "${labels[@]}"
    CHANNEL=${keys[$MENU_IDX]}

    local build
    build=$(jq -c --arg c "$CHANNEL" '
        [.[] | select(.channel == $c
                      and .downloads."server:default".url != null
                      and .downloads."server:default".checksums.sha256 != null)]
        | max_by(.id)' <<<"$API_BODY")
    BUILD_ID=$(jq -r '.id // empty' <<<"$build")
    BUILD_URL=$(jq -r '.downloads."server:default".url // empty' <<<"$build")
    BUILD_SHA=$(jq -r '.downloads."server:default".checksums.sha256 // empty' <<<"$build")
    BUILD_SIZE=$(jq -r '.downloads."server:default".size // empty' <<<"$build")
    [[ $BUILD_SIZE =~ ^[0-9]+$ ]] || BUILD_SIZE=""

    [[ $BUILD_ID =~ ^[0-9]+$ ]] || die "PaperMC returned an invalid build id: '$BUILD_ID'"
    [[ $BUILD_URL == https://* ]] || die "PaperMC returned an unusable download URL: '$BUILD_URL'"
    [[ $BUILD_SHA =~ ^[0-9a-fA-F]{64}$ ]] || die "PaperMC returned an invalid SHA-256: '$BUILD_SHA'"
    ok "Latest $CHANNEL build: #$BUILD_ID"
}

# ───────────────────────────── java ─────────────────────────────

# Looks for "java": {"version": {"minimum": N}} anywhere in the version metadata.
readonly JAVA_FILTER='[ .. | objects | select(has("java")) | .java | select(type == "object")
                        | (.version.minimum? // .minimum? // empty)
                        | select(type == "number" or (type == "string" and test("^[0-9]+$")))
                        | tonumber ] | first // empty'

mojang_java() {
    local url
    api_get "$MOJANG_MANIFEST" || return 1
    url=$(jq -r --arg v "$VERSION" '.versions[]? | select(.id == $v) | .url' <<<"$API_BODY" | head -n1 || true)
    [[ $url == https://* ]] || return 1
    api_get "$url" || return 1
    JAVA_REQ=$(jq -r '.javaVersion.majorVersion // empty' <<<"$API_BODY" 2>/dev/null || true)
    [[ $JAVA_REQ =~ ^[0-9]+$ ]]
}

determine_java() {
    step 3 6 "Find out which Java it needs"
    api_get "$API/versions/$VERSION" || die "Could not get details for $VERSION: $API_ERR"
    local status paper_excerpt
    JAVA_REQ=$(jq -r "$JAVA_FILTER" <<<"$API_BODY" 2>/dev/null || true)
    status=$(jq -r '[.. | objects | .support? | select(type == "object") | .status?
                     | select(type == "string")] | first // empty' <<<"$API_BODY" 2>/dev/null || true)
    case $status in
        UNSUPPORTED) warn "Paper no longer supports Minecraft $VERSION. It works, but gets no updates." ;;
        DEPRECATED) warn "Paper will stop supporting Minecraft $VERSION soon." ;;
    esac

    if [[ ! $JAVA_REQ =~ ^[0-9]+$ ]]; then
        paper_excerpt=$(excerpt)
        warn "PaperMC did not report a Java version for $VERSION."
        info "Asking Mojang's own version data instead..."
        mojang_java ||
            die "Could not determine the Java version for $VERSION from PaperMC or Mojang.
  PaperMC's response (trimmed): $paper_excerpt
  Please report this at https://github.com/boxgums/resources/issues"
        ok "Java $JAVA_REQ needed (from Mojang's data)"
    else
        ok "Java $JAVA_REQ needed (from PaperMC)"
    fi
}

find_java() { # find_java MAJOR → prints path of that JDK's java
    local d
    for d in "$PREFIX/lib/jvm/java-$1-openjdk" "$PREFIX/lib/jvm/openjdk-$1"; do
        if [ -x "$d/bin/java" ]; then printf '%s' "$d/bin/java"; return 0; fi
    done
    return 1
}

java_major() { # java_major PATH → prints the major version that binary reports
    local out
    out=$("$1" -version 2>&1 </dev/null) || return 1
    [[ $out =~ version\ \"([0-9]+) ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

explain_missing_java() {
    local n=$1 avail
    avail=$(pkg list-all 2>/dev/null | grep -oE '^openjdk-[0-9]+' | sort -Vu | tr '\n' ' ' || true)
    warn "Termux could not install Java $n (package openjdk-$n)."
    say "Java packages Termux lists right now: ${avail:-unknown}"
    say "Minecraft $VERSION needs Java $n or newer, so you can:"
    say "  ${S_DOT} pick an older Minecraft version that needs a Java Termux has, or"
    say "  ${S_DOT} try again later, once Termux adds openjdk-$n."
    say "If the message above mentions a conflict with another openjdk package,"
    say "remove that one yourself (pkg uninstall openjdk-XX). Nothing was removed for you."
}

ensure_java() {
    local n=$JAVA_REQ
    JAVA_BIN=$(find_java "$n" || true)
    if [ -z "$JAVA_BIN" ]; then
        info "Java is the program that runs Minecraft servers. Installing OpenJDK $n..."
        if ! pkg_install "openjdk-$n"; then
            explain_missing_java "$n"
            exit 1
        fi
        JAVA_BIN=$(find_java "$n" || true)
        [ -n "$JAVA_BIN" ] ||
            die "openjdk-$n installed, but no java was found under $PREFIX/lib/jvm ($(ls "$PREFIX/lib/jvm" 2>/dev/null | tr '\n' ' '))."
    else
        ok "OpenJDK $n already installed"
    fi
    JAVA_MAJOR=$(java_major "$JAVA_BIN" || true)
    [ "$JAVA_MAJOR" = "$n" ] ||
        die "Expected Java $n but $JAVA_BIN reports '${JAVA_MAJOR:-unknown}'."
    ok "Verified Java $JAVA_MAJOR: $JAVA_BIN"
}

# ───────────────────────────── server files ─────────────────────────────

conf_get() { # conf_get FILE KEY → prints value (empty if missing)
    local k v
    [ -f "$1" ] || return 0
    while IFS='=' read -r k v || [ -n "$k" ]; do
        if [ "$k" = "$2" ]; then printf '%s' "$v"; return 0; fi
    done <"$1"
    return 0
}

conf_set() { # conf_set FILE KEY VALUE
    { grep -v "^$2=" "$1" 2>/dev/null || true; printf '%s=%s\n' "$2" "$3"; } >"$1.tmp" &&
        mv -f "$1.tmp" "$1"
}

download_jar() {
    step 4 6 "Download Paper $VERSION (build #$BUILD_ID)"
    KEPT_JAR=0
    DIR="$ROOT/$VERSION"
    mkdir -p "$DIR" || die "Could not create $DIR"

    if [ -f "$DIR/server.jar" ]; then
        warn "A server is already installed in $DIR"
        say "Replacing server.jar does not touch your worlds, plugins or settings."
        if ! confirm "Replace server.jar with build #$BUILD_ID?" n; then
            info "Keeping the existing server.jar."
            KEPT_JAR=1
            return 0
        fi
    fi

    PART_FILE="$DIR/server.jar.part"
    rm -f "$PART_FILE"
    say "${DIM}${BUILD_SIZE:+$((BUILD_SIZE / 1048576)) MB · }from fill-data.papermc.io${RST}"
    curl -fL# --retry 3 --connect-timeout 15 -H "User-Agent: $UA" -o "$PART_FILE" "$BUILD_URL" </dev/null ||
        die "The download failed. Your existing files were not changed."
    [ -s "$PART_FILE" ] || die "The downloaded file is empty. Your existing files were not changed."

    local got
    read -r got _ < <(sha256sum "$PART_FILE")
    [ "$got" = "${BUILD_SHA,,}" ] ||
        die "Checksum mismatch, so the file was thrown away. Expected ${BUILD_SHA,,} but got $got. Try again."
    ok "Checksum verified (SHA-256)"

    mv -f "$PART_FILE" "$DIR/server.jar"
    PART_FILE=""
    conf_set "$DIR/server.conf" BUILD "$BUILD_ID"
    conf_set "$DIR/server.conf" CHANNEL "$CHANNEL"
    ok "Installed server.jar"
}

# ───────────────────────────── RAM ─────────────────────────────

meminfo_mb() { # meminfo_mb MemTotal|MemAvailable
    local k v _
    while read -r k v _; do
        if [ "$k" = "$1:" ]; then printf '%s' "$((v / 1024))"; return 0; fi
    done </proc/meminfo
    printf '0'
}

default_ram_mb() {
    local total avail d
    total=$(meminfo_mb MemTotal)
    avail=$(meminfo_mb MemAvailable)
    d=$((total / 2))
    if [ "$avail" -gt 0 ] && [ "$d" -gt $((avail * 3 / 4)) ]; then d=$((avail * 3 / 4)); fi
    if [ "$d" -gt 4096 ]; then d=4096; fi
    d=$((d / 256 * 256))
    if [ "$d" -lt 1024 ]; then d=1024; fi
    printf '%s' "$d"
}

# parse_ram "2G" | "2048" | "2048M" → prints MB, or fails
parse_ram() {
    local s=${1,,}
    s=${s// /}
    if [[ $s =~ ^([0-9]+)(g|gb)$ ]]; then printf '%s' "$((BASH_REMATCH[1] * 1024))"
    elif [[ $s =~ ^([0-9]+)(m|mb)?$ ]]; then printf '%s' "${BASH_REMATCH[1]}"
    else return 1
    fi
}

ask_ram() { # ask_ram [current]  → sets RAM_MB
    local total def mb
    total=$(meminfo_mb MemTotal)
    def=${1:-$(default_ram_mb)}
    say "RAM is the memory Minecraft may use. More RAM = smoother play, but if you"
    say "give too much, Android may close Termux. Phones also need RAM for Android."
    say "${DIM}Your phone: about ${total} MB total, $(meminfo_mb MemAvailable) MB free right now.${RST}"
    say "${DIM}Examples: 1536, 2048, 2G. Recommended: ${def} MB.${RST}"
    while :; do
        ask "RAM for the server" "$def"
        if ! mb=$(parse_ram "$REPLY"); then warn "Please enter a number like 2048 or 2G."; continue; fi
        if [ "$mb" -lt 512 ]; then warn "Minecraft needs at least 512 MB."; continue; fi
        if [ "$total" -gt 0 ] && [ "$mb" -gt $((total * 3 / 4)) ]; then
            warn "$mb MB is more than 75% of your phone's memory. Android will likely kill the server."
            confirm "Use $mb MB anyway?" n || continue
        fi
        RAM_MB=$mb
        return 0
    done
}

# ───────────────────────────── EULA & launcher ─────────────────────────────

eula_accepted() { grep -qx 'eula=true' "$1/eula.txt" 2>/dev/null; }

ensure_eula() { # ensure_eula DIR → 0 if accepted
    local f="$1/eula.txt"
    if eula_accepted "$1"; then return 0; fi
    say "Running a Minecraft server requires accepting the Minecraft EULA:"
    say "${BOLD}$EULA_URL${RST}"
    if confirm "Do you accept the Minecraft EULA?" n; then
        { grep -v '^eula=' "$f" 2>/dev/null || true; echo "eula=true"; } >"$f.tmp" && mv -f "$f.tmp" "$f"
        ok "EULA accepted"
        return 0
    fi
    warn "EULA not accepted. The server will not start."
    return 1
}

write_start_script() { # write_start_script DIR
    local f="$1/start.sh"
    if [ -f "$f" ] && ! grep -q '^# Generated by paper.sh' "$f"; then
        mv -f "$f" "$f.bak.$(date +%s)"
        warn "Your own start.sh was saved as $(basename "$f").bak.*"
    fi
    cat >"$f" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Generated by paper.sh. Settings live in server.conf (change RAM with the installer menu).
cd "$(dirname "$0")" || exit 1
JAVA_BIN="" RAM_MB=""
while IFS='=' read -r k v || [ -n "$k" ]; do
    case $k in JAVA_BIN) JAVA_BIN=$v ;; RAM_MB) RAM_MB=$v ;; esac
done <server.conf
[ -x "$JAVA_BIN" ] || { echo "Java not found: $JAVA_BIN. Run the installer again."; exit 1; }
[[ $RAM_MB =~ ^[0-9]+$ ]] || { echo "Invalid RAM setting in server.conf."; exit 1; }
grep -qx 'eula=true' eula.txt 2>/dev/null || { echo "EULA not accepted. Run the installer and start from its menu."; exit 1; }
command -v termux-wake-lock >/dev/null && termux-wake-lock
XMS=$(( RAM_MB < 512 ? RAM_MB : 512 ))
exec "$JAVA_BIN" -Xms"${XMS}M" -Xmx"${RAM_MB}M" -jar server.jar --nogui
EOF
    chmod +x "$f"
}

save_settings() {
    conf_set "$DIR/server.conf" MC_VERSION "$VERSION"
    conf_set "$DIR/server.conf" JAVA_BIN "$JAVA_BIN"
    conf_set "$DIR/server.conf" JAVA_MAJOR "$JAVA_MAJOR"
    conf_set "$DIR/server.conf" RAM_MB "$RAM_MB"
    write_start_script "$DIR"
}

# ───────────────────────────── global commands (mcstart, mcwhitelist) ─────────────────────────────
# Both are small stand-alone scripts kept inside this installer. They are written to
# $PREFIX/bin, which Termux always has on PATH, so nobody has to edit .bashrc.

emit_mcstart() {
    printf '#!/data/data/com.termux/files/usr/bin/bash\n# paper.sh-managed: mcstart v%s\n' "$CMD_VERSION"
    cat <<'MCCMD_EOF'
# mcstart: start any Minecraft server installed by paper.sh. Type: mcstart
# This file is managed by paper.sh and may be replaced when the installer updates.
# Your servers, worlds and settings are never touched by that.
set -u

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOT="${PAPER_HOME:-$HOME/minecraft}"
INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/boxgums/resources/main/paper.sh | bash"

# ── look and feel ──
RST="" BOLD="" DIM="" ACC="" GRN="" YEL="" RED=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    RST=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m' ACC=$'\e[36m' GRN=$'\e[32m' YEL=$'\e[33m' RED=$'\e[31m'
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*)
        C_TL="╭" C_TR="╮" C_BL="╰" C_BR="╯" C_H="─" C_V="│" C_LT="├" C_RT="┤" ;;
    *)
        C_TL="+" C_TR="+" C_BL="+" C_BR="+" C_H="-" C_V="|" C_LT="+" C_RT="+" ;;
esac

err()  { printf '\n  %sProblem:%s %s\n' "$RED$BOLD" "$RST" "$1" >&2; shift; local l; for l in "$@"; do printf '  %s\n' "$l" >&2; done; printf '\n' >&2; }
note() { printf '  %s\n' "$*"; }

conf_get() { # conf_get FILE KEY
    local k v
    [ -f "$1" ] || return 0
    while IFS='=' read -r k v || [ -n "$k" ]; do
        if [ "$k" = "$2" ]; then printf '%s' "$v"; return 0; fi
    done <"$1"
    return 0
}

conf_set() { # conf_set FILE KEY VALUE
    { grep -v "^$2=" "$1" 2>/dev/null || true; printf '%s=%s\n' "$2" "$3"; } >"$1.tmp" &&
        mv -f "$1.tmp" "$1"
}

meminfo_mb() {
    local k v _
    while read -r k v _; do
        if [ "$k" = "$1:" ]; then printf '%s' "$((v / 1024))"; return 0; fi
    done </proc/meminfo 2>/dev/null
    printf '0'
}

# ── finding servers ──
SERVERS=()
find_servers() {
    local f
    SERVERS=()
    shopt -s nullglob
    for f in "$ROOT"/*/server.conf; do SERVERS+=("$(dirname "$f")"); done
    shopt -u nullglob
    if [ "${#SERVERS[@]}" -gt 1 ]; then
        mapfile -t SERVERS < <(printf '%s\n' "${SERVERS[@]}" | sort -Vr)
    fi
}

server_version() {
    local v
    v=$(conf_get "$1/server.conf" MC_VERSION)
    printf '%s' "${v:-$(basename "$1")}"
}

no_servers_message() {
    err "No Minecraft servers are installed yet." \
        "Install one with this command, then type mcstart again:" \
        "" "    $INSTALL_CMD"
}

# ── Java ──
find_java() { # find_java MAJOR
    local d
    for d in "$PREFIX/lib/jvm/java-$1-openjdk" "$PREFIX/lib/jvm/openjdk-$1"; do
        if [ -x "$d/bin/java" ]; then printf '%s' "$d/bin/java"; return 0; fi
    done
    return 1
}

java_major() { # java_major PATH
    local out
    out=$("$1" -version 2>&1 </dev/null) || return 1
    [[ $out =~ version\ \"([0-9]+) ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# resolve_java DIR → sets JAVA_BIN to the Java this server needs. Returns 1 with an explanation if impossible.
JAVA_BIN=""
resolve_java() {
    local conf="$1/server.conf" need saved
    need=$(conf_get "$conf" JAVA_MAJOR)
    saved=$(conf_get "$conf" JAVA_BIN)
    if [[ ! $need =~ ^[0-9]+$ ]] && [ -n "$saved" ] && [ -x "$saved" ]; then
        need=$(java_major "$saved" || true)
    fi
    if [[ ! $need =~ ^[0-9]+$ ]]; then
        err "I don't know which Java this server needs." \
            "Run the installer again for this Minecraft version. Your world will be kept:" \
            "" "    $INSTALL_CMD"
        return 1
    fi

    JAVA_BIN=""
    if [ -n "$saved" ] && [ -x "$saved" ] && [ "$(java_major "$saved" || true)" = "$need" ]; then
        JAVA_BIN=$saved
    else
        JAVA_BIN=$(find_java "$need" || true)
    fi

    if [ -z "$JAVA_BIN" ]; then
        printf '\n  %sJava %s is missing.%s\n' "$YEL$BOLD" "$need" "$RST"
        note "Java is the program that runs Minecraft. This server needs Java $need,"
        note "and it is not installed (or was removed)."
        if ! command -v pkg >/dev/null 2>&1; then
            err "I can't install it automatically here." "Install the package openjdk-$need with your package manager."
            return 1
        fi
        local ans
        printf '\n  Install Java %s now? (Y/n): ' "$need"
        read -r ans || { printf '\n'; return 1; }
        case "${ans:-y}" in
            [Yy] | [Yy][Ee][Ss]) ;;
            *) note "Okay, not installing. The server was not started."; return 1 ;;
        esac
        if ! pkg install -y "openjdk-$need" </dev/null; then
            err "Termux could not install openjdk-$need." \
                "Check your internet connection and try again. If the message above mentions a" \
                "conflict with another openjdk package, remove that one first (pkg uninstall openjdk-XX)." \
                "Nothing was removed for you."
            return 1
        fi
        JAVA_BIN=$(find_java "$need" || true)
        if [ -z "$JAVA_BIN" ]; then
            err "openjdk-$need was installed but I could not find its java program."
            return 1
        fi
    fi

    if [ "$(java_major "$JAVA_BIN" || true)" != "$need" ]; then
        err "Expected Java $need but $JAVA_BIN reports a different version." \
            "Run the installer again to repair it: $INSTALL_CMD"
        return 1
    fi
    [ "$saved" = "$JAVA_BIN" ] || conf_set "$conf" JAVA_BIN "$JAVA_BIN" 2>/dev/null || true
    return 0
}

# ── RAM ──
RAM_MB=""
resolve_ram() { # resolve_ram DIR
    local conf="$1/server.conf" total d
    RAM_MB=$(conf_get "$conf" RAM_MB)
    total=$(meminfo_mb MemTotal)
    if [[ ! $RAM_MB =~ ^[0-9]+$ ]] || [ "$RAM_MB" -lt 512 ]; then
        d=$((total / 2))
        if [ "$d" -gt 4096 ]; then d=4096; fi
        d=$((d / 256 * 256))
        if [ "$d" -lt 1024 ]; then d=1024; fi
        RAM_MB=$d
        conf_set "$conf" RAM_MB "$RAM_MB" 2>/dev/null || true
        note "${DIM}No RAM setting was saved, so I chose a safe $RAM_MB MB (about half your phone's memory, max 4 GB).${RST}"
    fi
    if [ "$total" -gt 0 ] && [ "$RAM_MB" -gt $((total * 3 / 4)) ]; then
        printf '  %sWarning:%s %s MB is a lot for this phone. Android may close Termux.\n' "$YEL" "$RST" "$RAM_MB"
    fi
}

# ── EULA ──
resolve_eula() { # resolve_eula DIR
    grep -qx 'eula=true' "$1/eula.txt" 2>/dev/null && return 0
    note "Running a Minecraft server requires accepting the Minecraft EULA:"
    note "${BOLD}https://aka.ms/MinecraftEULA${RST}"
    local ans
    printf '\n  Do you accept the Minecraft EULA? (y/N): '
    read -r ans || { printf '\n'; return 1; }
    case "$ans" in
        [Yy] | [Yy][Ee][Ss])
            { grep -v '^eula=' "$1/eula.txt" 2>/dev/null || true; echo "eula=true"; } >"$1/eula.txt.tmp" &&
                mv -f "$1/eula.txt.tmp" "$1/eula.txt" && return 0
            err "Could not write eula.txt in $1"; return 1 ;;
        *) note "EULA not accepted, so the server will not start."; return 1 ;;
    esac
}

# ── starting ──
start_server() { # start_server DIR → returns 1 if it could not start (caller shows the menu again)
    local dir=$1 ver
    ver=$(server_version "$dir")
    if [ ! -d "$dir" ]; then err "The folder for Minecraft $ver is gone ($dir)."; return 1; fi
    if [ ! -f "$dir/server.jar" ]; then
        err "The server file (server.jar) for Minecraft $ver is missing." \
            "Your worlds are safe. Reinstall that version with the installer to get it back:" \
            "" "    $INSTALL_CMD"
        return 1
    fi
    resolve_java "$dir" || return 1
    resolve_ram "$dir"
    resolve_eula "$dir" || return 1
    cd "$dir" || { err "Could not open $dir"; return 1; }

    printf '\n  %s▶ Starting Minecraft %s%s  %s(Java %s, %s MB RAM)%s\n' \
        "$GRN$BOLD" "$ver" "$RST" "$DIM" "$(java_major "$JAVA_BIN" || echo '?')" "$RAM_MB" "$RST"
    note "${DIM}Type \"stop\" to shut the server down safely.${RST}"
    printf '\n'
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
    local xms=$((RAM_MB < 512 ? RAM_MB : 512)) rc=0
    "$JAVA_BIN" -Xms"${xms}M" -Xmx"${RAM_MB}M" -jar server.jar --nogui || rc=$?
    printf '\n  Server stopped.'
    [ "$rc" -eq 0 ] || printf ' %s(exit code %s)%s' "$YEL" "$rc" "$RST"
    printf '\n'
    exit "$rc"
}

# ── menu ──
draw_menu() {
    local -a rows=("$@")
    local w=36 r i line
    for r in "${rows[@]}"; do [ "${#r}" -gt $((w - 4)) ] && w=$((${#r} + 4)); done
    local bar=""
    for ((i = 0; i < w; i++)); do bar+="$C_H"; done
    center() {
        local t=$1 l=$(((w - ${#1}) / 2))
        printf '%s%*s%s%*s%s\n' "$C_V" "$l" "" "$t" "$((w - l - ${#t}))" "" "$C_V"
    }
    row() { printf '%s  %-*s%s\n' "$C_V" "$((w - 2))" "$1" "$C_V"; }
    blank() { printf '%s%*s%s\n' "$C_V" "$w" "" "$C_V"; }
    printf '\n%s%s%s%s\n' "$C_TL" "$bar" "$C_TR" ""
    center "PaperMC Server"
    blank
    center "Select a server"
    printf '%s%s%s\n' "$C_LT" "$bar" "$C_RT"
    blank
    for line in "${rows[@]}"; do row "$line"; done
    blank
    row "0. Exit"
    blank
    printf '%s%s%s\n\n' "$C_BL" "$bar" "$C_BR"
}

choose_and_start() {
    local -a rows=()
    local i n=${#SERVERS[@]} choice
    for ((i = 0; i < n; i++)); do rows+=("$((i + 1)). Minecraft $(server_version "${SERVERS[$i]}")"); done
    while :; do
        draw_menu "${rows[@]}"
        while :; do
            printf 'Choose a server: '
            read -r choice || { printf '\n'; exit 0; }
            choice=${choice#"${choice%%[![:space:]]*}"}
            choice=${choice%"${choice##*[![:space:]]}"}
            if [ "$choice" = 0 ]; then note "Goodbye!"; exit 0; fi
            if [[ $choice =~ ^[0-9]+$ ]] && [ "$((10#$choice))" -ge 1 ] && [ "$((10#$choice))" -le "$n" ]; then
                start_server "${SERVERS[$((10#$choice - 1))]}" || true
                break   # could not start: show the menu again
            fi
            printf '  %sPlease type a number from 0 to %s.%s\n' "$YEL" "$n" "$RST"
        done
    done
}

list_servers() {
    local d i=0 ver jmaj ram flag
    for d in "${SERVERS[@]}"; do
        i=$((i + 1))
        ver=$(server_version "$d")
        jmaj=$(conf_get "$d/server.conf" JAVA_MAJOR)
        ram=$(conf_get "$d/server.conf" RAM_MB)
        flag=""
        [ -f "$d/server.jar" ] || flag="  ${YEL}(server.jar missing)${RST}"
        printf '  %s. Minecraft %s  %sJava %s, %s MB%s%s\n' "$i" "$ver" "$DIM" "${jmaj:-?}" "${ram:-?}" "$RST" "$flag"
        printf '     %s%s%s\n' "$DIM" "$d" "$RST"
    done
}

usage() {
    cat <<EOF

  mcstart - start a Minecraft server with one command

    mcstart          pick a server from a menu and start it
    mcstart --list   show installed servers without starting one
    mcstart --help   show this help

  Install more servers, or change a server's RAM, by running the installer:
    $INSTALL_CMD

  Servers live in: $ROOT

EOF
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    -l | --list)
        find_servers
        if [ "${#SERVERS[@]}" -eq 0 ]; then no_servers_message; exit 1; fi
        printf '\n  %sInstalled servers%s\n\n' "$BOLD" "$RST"
        list_servers
        printf '\n'
        exit 0 ;;
    "") ;;
    *) err "I don't understand \"$1\"." "Try: mcstart --help"; exit 2 ;;
esac

find_servers
if [ "${#SERVERS[@]}" -eq 0 ]; then no_servers_message; exit 1; fi
choose_and_start
MCCMD_EOF
}

emit_mcwhitelist() {
    printf '#!/data/data/com.termux/files/usr/bin/bash\n# paper.sh-managed: mcwhitelist v%s\n' "$CMD_VERSION"
    cat <<'MCCMD_EOF'
# mcwhitelist: choose which players may join your Minecraft server. Type: mcwhitelist
# This file is managed by paper.sh and may be replaced when the installer updates.
# Your servers, worlds and settings are never touched by that.
set -u

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOT="${PAPER_HOME:-$HOME/minecraft}"
UA="boxgums-paper-installer/2.0 (https://github.com/boxgums/resources)"
INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/boxgums/resources/main/paper.sh | bash"

RST="" BOLD="" DIM="" ACC="" GRN="" YEL="" RED=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    RST=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m' ACC=$'\e[36m' GRN=$'\e[32m' YEL=$'\e[33m' RED=$'\e[31m'
fi

say()  { printf '  %s\n' "$*"; }
good() { printf '  %s+%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '\n  %sProblem:%s %s\n' "$RED$BOLD" "$RST" "$1" >&2; shift; local l; for l in "$@"; do printf '  %s\n' "$l" >&2; done; printf '\n' >&2; }

conf_get() { # conf_get FILE KEY
    local k v
    [ -f "$1" ] || return 0
    while IFS='=' read -r k v || [ -n "$k" ]; do
        if [ "$k" = "$2" ]; then printf '%s' "$v"; return 0; fi
    done <"$1"
    return 0
}

conf_set() {
    { grep -v "^$2=" "$1" 2>/dev/null || true; printf '%s=%s\n' "$2" "$3"; } >"$1.tmp" &&
        mv -f "$1.tmp" "$1"
}

# prop_get FILE KEY DEFAULT / prop_set FILE KEY VALUE  (server.properties, other lines are kept as they are)
prop_get() {
    local k v
    if [ -f "$1" ]; then
        while IFS='=' read -r k v || [ -n "$k" ]; do
            if [ "$k" = "$2" ]; then printf '%s' "${v%$'\r'}"; return 0; fi
        done <"$1"
    fi
    printf '%s' "$3"
}

prop_set() {
    if [ -f "$1" ] && grep -q "^$2=" "$1"; then
        sed -i "s/^$2=.*/$2=$3/" "$1"
    else
        printf '%s=%s\n' "$2" "$3" >>"$1"
    fi
}

command -v jq >/dev/null 2>&1 || {
    err "The helper tool \"jq\" is missing." "Install it with:  pkg install jq"
    exit 1
}

# ── choosing a server ──
SERVERS=()
find_servers() {
    local f
    SERVERS=()
    shopt -s nullglob
    for f in "$ROOT"/*/server.conf; do SERVERS+=("$(dirname "$f")"); done
    shopt -u nullglob
    if [ "${#SERVERS[@]}" -gt 1 ]; then
        mapfile -t SERVERS < <(printf '%s\n' "${SERVERS[@]}" | sort -Vr)
    fi
}

sver() { local v; v=$(conf_get "$1/server.conf" MC_VERSION); printf '%s' "${v:-$(basename "$1")}"; }

DIR=""
pick_server() {
    local i n choice
    find_servers
    n=${#SERVERS[@]}
    if [ "$n" -eq 0 ]; then
        err "No Minecraft servers are installed yet." "Install one first:" "" "    $INSTALL_CMD"
        return 1
    fi
    if [ "$n" -eq 1 ]; then DIR=${SERVERS[0]}; return 0; fi
    printf '\n  %sWhich server is the whitelist for?%s\n\n' "$BOLD" "$RST"
    for ((i = 0; i < n; i++)); do printf '   %s%d.%s Minecraft %s\n' "$ACC" "$((i + 1))" "$RST" "$(sver "${SERVERS[$i]}")"; done
    printf '   %s0.%s Exit\n' "$ACC" "$RST"
    while :; do
        printf '\n  Choose a server: '
        read -r choice || { printf '\n'; return 1; }
        [ "$choice" = 0 ] && return 1
        if [[ $choice =~ ^[0-9]+$ ]] && [ "$((10#$choice))" -ge 1 ] && [ "$((10#$choice))" -le "$n" ]; then
            DIR=${SERVERS[$((10#$choice - 1))]}
            return 0
        fi
        warn "Please type a number from 0 to $n."
    done
}

# ── players ──
valid_name() { [[ $1 =~ ^[A-Za-z0-9_]{3,16}$ ]]; }

dash_uuid() { # 32 hex → 8-4-4-4-12
    local h=${1,,}
    printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

offline_uuid() { # servers with online-mode=false use this name-based id
    local h b6 b8
    h=$(printf 'OfflinePlayer:%s' "$1" | md5sum | cut -c1-32)
    b6=$(printf '%02x' $(((0x${h:12:2} & 0x0f) | 0x30)))
    b8=$(printf '%02x' $(((0x${h:16:2} & 0x3f) | 0x80)))
    dash_uuid "${h:0:12}${b6}${h:14:2}${b8}${h:18}"
}

# lookup_player NAME → sets P_NAME and P_UUID, or returns 1 after explaining
P_NAME="" P_UUID=""
lookup_player() {
    local name=$1 online raw code body id
    online=$(prop_get "$DIR/server.properties" online-mode true)
    if [ "$online" = false ]; then
        P_NAME=$name P_UUID=$(offline_uuid "$name")
        return 0
    fi
    raw=$(curl -sS --max-time 15 --connect-timeout 10 -H "User-Agent: $UA" \
        -w $'\n%{http_code}' "https://api.mojang.com/users/profiles/minecraft/$name" 2>&1 </dev/null) || {
        warn "Could not reach Mojang to look up \"$name\". Check your internet connection."
        return 1
    }
    code=${raw##*$'\n'}
    body=${raw%$'\n'*}
    case $code in
        200) ;;
        204 | 404) warn "There is no Minecraft Java player called \"$name\". Check the spelling."; return 1 ;;
        *) warn "Mojang answered with an error ($code). Try again in a minute."; return 1 ;;
    esac
    id=$(jq -r '.id // empty' <<<"$body" 2>/dev/null || true)
    P_NAME=$(jq -r '.name // empty' <<<"$body" 2>/dev/null || true)
    if [[ ! $id =~ ^[0-9a-fA-F]{32}$ ]] || [ -z "$P_NAME" ]; then
        warn "Mojang's answer for \"$name\" looked wrong. Try again later."
        return 1
    fi
    P_UUID=$(dash_uuid "$id")
}

# ── the whitelist file ──
WL=""
prepare_file() {
    WL="$DIR/whitelist.json"
    if [ ! -f "$WL" ]; then printf '[]\n' >"$WL" || { err "Could not create $WL"; return 1; }; fi
    if ! jq -e 'type == "array"' "$WL" >/dev/null 2>&1; then
        err "whitelist.json in $DIR is damaged, so I left it alone." \
            "Fix or rename that file, then run mcwhitelist again."
        return 1
    fi
}

wl_write() { # wl_write JQ_ARGS... (filter is last arg)
    jq "$@" "$WL" >"$WL.tmp" && mv -f "$WL.tmp" "$WL"
}

server_running() {
    local p
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/cwd" 2>/dev/null)" = "$DIR" ] || continue
        tr '\0' ' ' <"$p/cmdline" 2>/dev/null | grep -q 'server.jar' && return 0
    done
    return 1
}

running_note() {
    if server_running; then
        warn "This server is running right now. Type  whitelist reload  in its console"
        say "  so it notices the change (or ask the player to rejoin later)."
    fi
}

whitelist_on() { [ "$(prop_get "$DIR/server.properties" white-list false)" = true ]; }

show_list() {
    local n
    n=$(jq 'length' "$WL")
    printf '\n  %sPlayers allowed on Minecraft %s%s\n\n' "$BOLD" "$(sver "$DIR")" "$RST"
    if [ "$n" -eq 0 ]; then say "(nobody yet)"; else jq -r '.[].name' "$WL" | sort -f | sed 's/^/   • /'; fi
}

add_players() {
    local name changed=0
    printf '\n'
    say "Type a player's exact Minecraft name and press Enter."
    say "Add as many as you like, one at a time. Press Enter on an empty line when done."
    while :; do
        printf '\n  Player name: '
        read -r name || { printf '\n'; break; }
        name=${name#"${name%%[![:space:]]*}"}
        name=${name%"${name##*[![:space:]]}"}
        [ -z "$name" ] && break
        if ! valid_name "$name"; then
            warn "Names use 3-16 letters, numbers or underscores (no spaces)."
            continue
        fi
        lookup_player "$name" || continue
        if wl_write --arg u "$P_UUID" --arg n "$P_NAME" \
            'map(select((.name | ascii_downcase) != ($n | ascii_downcase))) + [{uuid: $u, name: $n}]'; then
            good "Added $P_NAME"
            changed=1
        else
            err "Could not save whitelist.json."
        fi
    done
    [ "$changed" = 1 ] && running_note
    return 0
}

remove_player() {
    local -a names=()
    local i choice
    mapfile -t names < <(jq -r '.[].name' "$WL" | sort -f)
    if [ "${#names[@]}" -eq 0 ]; then warn "The whitelist is empty."; return 0; fi
    printf '\n'
    for ((i = 0; i < ${#names[@]}; i++)); do printf '   %s%d.%s %s\n' "$ACC" "$((i + 1))" "$RST" "${names[$i]}"; done
    printf '   %s0.%s Cancel\n' "$ACC" "$RST"
    while :; do
        printf '\n  Remove which player (number): '
        read -r choice || { printf '\n'; return 0; }
        [ "$choice" = 0 ] && return 0
        if [[ $choice =~ ^[0-9]+$ ]] && [ "$((10#$choice))" -ge 1 ] && [ "$((10#$choice))" -le "${#names[@]}" ]; then
            local who=${names[$((10#$choice - 1))]}
            if wl_write --arg n "$who" 'map(select((.name | ascii_downcase) != ($n | ascii_downcase)))'; then
                good "Removed $who"
                running_note
            else
                err "Could not save whitelist.json."
            fi
            return 0
        fi
        warn "Please type a number from 0 to ${#names[@]}."
    done
}

toggle_whitelist() {
    local props="$DIR/server.properties"
    if whitelist_on; then
        prop_set "$props" white-list false
        prop_set "$props" enforce-whitelist false
        conf_set "$DIR/server.conf" WHITELIST 0
        good "Whitelist turned OFF. Anyone can join (after the server restarts)."
    else
        prop_set "$props" white-list true
        prop_set "$props" enforce-whitelist true
        conf_set "$DIR/server.conf" WHITELIST 1
        good "Whitelist turned ON. Only listed players can join (after the server restarts)."
    fi
    if server_running; then warn "The server is running: restart it for this switch to apply."; fi
}

main_menu() {
    local state choice
    while :; do
        if whitelist_on; then state="${GRN}ON${RST}"; else state="${YEL}OFF${RST}"; fi
        printf '\n  %sWhitelist for Minecraft %s%s  (currently %s)\n' "$BOLD" "$(sver "$DIR")" "$RST" "$state"
        say "${DIM}A whitelist lets only the players you list join your server.${RST}"
        printf '\n   %s1.%s Add players\n   %s2.%s Remove a player\n   %s3.%s Show who is allowed\n   %s4.%s Turn whitelist on/off\n   %s0.%s Done\n' \
            "$ACC" "$RST" "$ACC" "$RST" "$ACC" "$RST" "$ACC" "$RST" "$ACC" "$RST"
        printf '\n  Your choice: '
        read -r choice || { printf '\n'; return 0; }
        case $choice in
            1) add_players ;;
            2) remove_player ;;
            3) show_list ;;
            4) toggle_whitelist ;;
            0) say "Done. Start your server with:  mcstart"; return 0 ;;
            *) warn "Please type a number from 0 to 4." ;;
        esac
    done
}

usage() {
    cat <<EOF

  mcwhitelist - choose who may join your Minecraft server

    mcwhitelist          open the whitelist menu
    mcwhitelist --help   show this help

  You need each player's exact Minecraft (Java Edition) name.
  Servers are in: $ROOT

EOF
}

TARGET=""
case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    --dir) TARGET=${2:-}; [ -d "$TARGET" ] || { err "Folder not found: $TARGET"; exit 2; } ;;
    "") ;;
    *) err "I don't understand \"$1\"." "Try: mcwhitelist --help"; exit 2 ;;
esac

if [ -n "$TARGET" ]; then DIR=$TARGET; else pick_server || exit 0; fi
prepare_file || exit 1
main_menu
MCCMD_EOF
}

# install_command NAME → installs or updates $PREFIX/bin/NAME. Never touches a file that
# paper.sh did not create, and does not rewrite one that is already up to date.
install_command() {
    local name=$1 dest="$PREFIX/bin/$1" tmp
    mkdir -p "$PREFIX/bin" 2>/dev/null || { warn "Could not create $PREFIX/bin"; return 1; }
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        if ! grep -qx "# paper.sh-managed: $name v[0-9]*" "$dest" 2>/dev/null; then
            warn "A different \"$name\" command already exists ($dest). I left it alone."
            return 1
        fi
        if grep -qx "# paper.sh-managed: $name v$CMD_VERSION" "$dest"; then
            ok "Command \"$name\" is already installed"
            return 0
        fi
    fi
    tmp=$(mktemp "$dest.XXXXXX") || { warn "Could not write to $PREFIX/bin"; return 1; }
    if "emit_$name" >"$tmp" && bash -n "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$dest"; then
        ok "Command \"$name\" installed. Type: $name"
        return 0
    fi
    rm -f "$tmp"
    warn "Could not install the \"$name\" command."
    return 1
}

install_commands() {
    if install_command mcstart; then MCSTART_OK=1; fi
    # Keep mcwhitelist current if it was installed before (it is created when a whitelist is chosen).
    if [ -e "$PREFIX/bin/mcwhitelist" ]; then install_command mcwhitelist || true; fi
    case ":$PATH:" in
        *":$PREFIX/bin:"*) ;;
        *) warn "$PREFIX/bin is not on your PATH. Close and reopen Termux; if it still fails, mcstart cannot be found by name." ;;
    esac
}

prop_set() { # prop_set FILE KEY VALUE → changes one line of server.properties, keeps the rest
    if [ -f "$1" ] && grep -q "^$2=" "$1"; then
        sed -i "s/^$2=.*/$2=$3/" "$1"
    else
        printf '%s=%s\n' "$2" "$3" >>"$1"
    fi
}

setup_whitelist() {
    local props="$DIR/server.properties"
    WHITELIST=0
    printf '\n'
    say "A ${BOLD}whitelist${RST} is a list of players who are allowed to join."
    say "Everyone else is kept out, even if they find your server address."
    say "${DIM}Recommended if you only want to play with friends.${RST}"
    if confirm "Do you want a whitelist?" y; then
        WHITELIST=1
        prop_set "$props" white-list true
        prop_set "$props" enforce-whitelist true
        conf_set "$DIR/server.conf" WHITELIST 1
        ok "Whitelist turned on for Minecraft $VERSION"
        if install_command mcwhitelist; then
            say "${DIM}Use the command ${RST}${BOLD}mcwhitelist${RST}${DIM} any time to add or remove players.${RST}"
            if confirm "Add players to the whitelist now?" y; then
                bash "$PREFIX/bin/mcwhitelist" --dir "$DIR" <&3 || warn "mcwhitelist stopped early. Run mcwhitelist later to finish."
            fi
        else
            warn "Whitelist is on, but the mcwhitelist command could not be installed."
        fi
    else
        conf_set "$DIR/server.conf" WHITELIST 0
        info "No whitelist. Anyone who knows your server address can join."
        if [ "$(grep -s '^white-list=' "$props" | tail -n1)" = "white-list=true" ]; then
            warn "This server already had a whitelist on. I left that setting as it was."
        fi
    fi
}

# ───────────────────────────── flows ─────────────────────────────

run_server() { # run_server DIR  (stdin must be the terminal so the console works)
    ensure_eula "$1" || return 0
    printf '\n  %sStarting server. Type "stop" to shut it down safely.%s\n\n' "$DIM" "$RST"
    "$1/start.sh" <&3 || warn "The server exited with an error (code $?)."
}

install_server() {
    while :; do
        choose_version
        choose_channel && break
        say "Let's pick another version."
    done
    determine_java
    ensure_java
    download_jar

    step 5 6 "Memory, whitelist and EULA"
    local current
    current=$(conf_get "$DIR/server.conf" RAM_MB)
    ask_ram "$current"
    save_settings
    setup_whitelist
    local accepted=0
    ensure_eula "$DIR" && accepted=1

    step 6 6 "All done"
    summary "$accepted"
    if [ "$accepted" = 1 ] && confirm "Start the server now?" y; then
        run_server "$DIR"
    fi
}

summary() {
    printf '\n  %s%s%s\n' "$GRN" "$RULE" "$RST"
    printf '  %s%s Installation complete%s\n' "$GRN$BOLD" "$S_OK" "$RST"
    printf '  %s%s%s\n\n' "$GRN" "$RULE" "$RST"
    printf '   %-11s %s\n' "Minecraft" "$VERSION"
    printf '   %-11s %s\n' "Build" "#$(conf_get "$DIR/server.conf" BUILD) ($(conf_get "$DIR/server.conf" CHANNEL))"
    printf '   %-11s %s\n' "Java" "$JAVA_MAJOR"
    printf '   %-11s %s MB\n' "RAM" "$RAM_MB"
    printf '   %-11s %s\n' "Whitelist" "$([ "$WHITELIST" = 1 ] && echo on || echo off)"
    printf '   %-11s %s\n' "Folder" "$DIR"
    if [ "$MCSTART_OK" = 1 ]; then
        printf '\n  %sStart your server any time, from any folder, by typing:%s\n' "$BOLD" "$RST"
        printf '    %smcstart%s\n' "$ACC$BOLD" "$RST"
    else
        printf '\n  %sStart it again later:%s\n' "$BOLD" "$RST"
        printf '    bash %q\n' "$DIR/start.sh"
        printf '  %sor run the installer again and pick "Start a server".%s\n' "$DIM" "$RST"
    fi
    if [ "$WHITELIST" = 1 ]; then
        printf '  %sChange who can join by typing:%s %smcwhitelist%s\n' "$DIM" "$RST" "$ACC$BOLD" "$RST"
    fi
    [ "$1" = 1 ] || warn "You have not accepted the EULA yet. The server will not start until you do."
}

SERVERS=()
list_servers() {
    local f
    SERVERS=()
    shopt -s nullglob
    for f in "$ROOT"/*/server.conf; do SERVERS+=("$(dirname "$f")"); done
    shopt -u nullglob
    if [ "${#SERVERS[@]}" -gt 1 ]; then
        mapfile -t SERVERS < <(printf '%s\n' "${SERVERS[@]}" | sort -Vr)
    fi
}

server_label() {
    local c="$1/server.conf"
    printf '%s  %sbuild #%s · Java %s · %s MB%s' "$(conf_get "$c" MC_VERSION)" "$DIM" \
        "$(conf_get "$c" BUILD)" "$(conf_get "$c" JAVA_MAJOR)" "$(conf_get "$c" RAM_MB)" "$RST"
}

pick_server() { # pick_server "Title" → sets DIR
    local -a labels=()
    local d
    for d in "${SERVERS[@]}"; do labels+=("$(server_label "$d")"); done
    if [ "${#SERVERS[@]}" -eq 1 ]; then DIR=${SERVERS[0]}; return 0; fi
    menu "$1" 1 10 "${labels[@]}"
    DIR=${SERVERS[$MENU_IDX]}
}

view_servers() {
    local d
    printf '\n  %sInstalled servers%s  %s(in %s)%s\n\n' "$BOLD" "$RST" "$DIM" "$ROOT" "$RST"
    for d in "${SERVERS[@]}"; do
        printf '   %s%s\n   %s%s%s\n\n' "$S_DOT " "$(server_label "$d")" "$DIM" "$d" "$RST"
    done
}

change_ram() {
    pick_server "Change RAM for which server?"
    ask_ram "$(conf_get "$DIR/server.conf" RAM_MB)"
    conf_set "$DIR/server.conf" RAM_MB "$RAM_MB"
    ok "RAM for $(conf_get "$DIR/server.conf" MC_VERSION) set to $RAM_MB MB"
}

main_menu() {
    while :; do
        list_servers
        menu "What would you like to do?" 1 10 \
            "Start a server" \
            "Install another Minecraft version" \
            "View installed servers" \
            "Change server RAM" \
            "Exit"
        if [ "${#SERVERS[@]}" -eq 0 ] && { [ "$MENU_IDX" = 0 ] || [ "$MENU_IDX" = 2 ] || [ "$MENU_IDX" = 3 ]; }; then
            warn "No servers installed yet. Choose \"Install another Minecraft version\"."
            continue
        fi
        case $MENU_IDX in
            0) pick_server "Start which server?" && run_server "$DIR" ;;
            1) install_server ;;
            2) view_servers ;;
            3) change_ram ;;
            4) say "Goodbye!"; return 0 ;;
        esac
    done
}

main() {
    trap cleanup EXIT
    trap 'printf "\n  Unexpected error on line %s. Nothing was deleted.\n" "$LINENO" >&2' ERR
    setup_ui
    banner
    check_termux
    info "Checking tools..."
    ensure_tools
    install_commands
    list_servers
    if [ "${#SERVERS[@]}" -eq 0 ]; then
        say "No servers installed yet. Let's set one up."
        install_server
    fi
    main_menu
}

# Run only when executed (or piped into bash), not when sourced for testing.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
