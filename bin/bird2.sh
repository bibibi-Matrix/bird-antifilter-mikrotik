#!/bin/bash
set -uo pipefail

# === Paths ===
BASE_DIR="/etc/bird"
LIST_DIR="${BASE_DIR}/list"
LIST_CUSTOM_DIR="${BASE_DIR}/list_custom"
LIST_RSC_DIR="${BASE_DIR}/list_rsc"
BIRD_CONF="${BASE_DIR}/bird.conf"
BIRD2_CONF="${BASE_DIR}/bird2.conf"
TMP_DIR="/tmp"

log() { echo "[INFO] $(date '+%H:%M:%S') $1"; }
warn() { echo "[WARN] $(date '+%H:%M:%S') $1" >&2; }

# === Read bird2.conf ===
declare -A CFG

load_config() {
    if [[ ! -f "$BIRD2_CONF" ]]; then
        warn "Config not found: $BIRD2_CONF - using defaults"
        return 1
    fi

    while IFS='=' read -r key value; do
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | tr -d '[:space:]')
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        CFG["$key"]="$value"
    done < "$BIRD2_CONF"

    log "Config loaded: $(wc -l < "$BIRD2_CONF") entries"
}

cfg_get() {
    local key="$1" default="${2:-no}"
    echo "${CFG[$key]:-$default}"
}

check_internet() {
    nc -zw1 77.88.8.8 53 2>/dev/null
}

download_file() {
    local url="$1" output="$2"
    for ((i=1; i<=3; i++)); do
        if curl -sf --connect-timeout 10 --max-time 120 -o "$output" "$url"; then
            return 0
        fi
        [[ $i -lt 3 ]] && sleep 3
    done
    return 1
}

files_differ() {
    [[ ! -f "$2" ]] && return 0
    ! diff -q "$1" "$2" > /dev/null 2>&1
}

# === Step 1: list_custom -> list ===
sync_custom_lists() {
    log "--- Syncing list_custom -> list ---"
    if ! ls "$LIST_CUSTOM_DIR"/*.lst 1>/dev/null 2>&1; then
        log "No custom lists found in $LIST_CUSTOM_DIR"
        return 0
    fi
    for file in "$LIST_CUSTOM_DIR"/*.lst; do
        [[ ! -f "$file" ]] && continue
        local name=$(basename "$file" .lst)
        cp "$file" "${LIST_DIR}/${name}.lst"
        log "Copied: $name"
    done
}

# === Step 2: Download antifilter -> /tmp ===
download_antifilter_lists() {
    log "--- Downloading antifilter lists ---"
    if ! check_internet; then
        warn "No internet - skip download"
        return 1
    fi

    local updated=false

    if [[ "$(cfg_get antifilter_download)" == "yes" ]]; then
        for file in ip ipresolve ipsum subnet allyouneed community; do
            if [[ "$(cfg_get "$file")" != "yes" ]]; then
                log "Skipped (disabled): $file"
                continue
            fi
            local url
            if [[ "$file" == "community" ]]; then
                url="https://community.antifilter.download/list/${file}.lst"
            else
                url="https://antifilter.download/list/${file}.lst"
            fi
            if download_file "$url" "${TMP_DIR}/${file}.lst"; then
                log "Downloaded (antifilter.download): $file.lst"
                updated=true
            else
                warn "Failed: $file.lst"
            fi
        done
    else
        log "antifilter.download: disabled"
    fi

    if [[ "$(cfg_get antifilter_network)" == "yes" ]]; then
        for file in ip ipsmart ipsum subnet uablacklist govno ip6; do
            if [[ "$(cfg_get "nf_$file")" != "yes" ]]; then
                log "Skipped (disabled): nf_$file"
                continue
            fi
            if download_file "https://antifilter.network/download/${file}.lst" "${TMP_DIR}/nf_${file}.lst"; then
                log "Downloaded (antifilter.network): nf_${file}.lst"
                updated=true
            else
                warn "Failed: nf_${file}.lst"
            fi
        done
    else
        log "antifilter.network: disabled"
    fi

    $updated
}

# === Step 3: Compare /tmp vs list, update if changed ===
compare_and_update() {
    log "--- Comparing lists ---"
    local updated=0 unchanged=0

    for file in "${TMP_DIR}"/*.lst; do
        [[ ! -f "$file" ]] && continue
        local name=$(basename "$file")
        local target="${LIST_DIR}/${name}"

        if files_differ "$file" "$target"; then
            cp "$file" "$target"
            log "Updated: $name"
            ((updated++))
        else
            log "Unchanged: $name"
            ((unchanged++))
        fi
    done

    log "Result: $updated updated, $unchanged unchanged"
}

# === Step 4: list -> list_rsc (.rsc) per file ===
process_lists() {
    log "--- Processing lists -> list_rsc ---"
    rm -f "${LIST_RSC_DIR}"/*.rsc 2>/dev/null

    if ! ls "$LIST_DIR"/*.lst 1>/dev/null 2>&1; then
        warn "No .lst files in $LIST_DIR"
        return 0
    fi

    for file in "${LIST_DIR}"/*.lst; do
        [[ ! -f "$file" ]] && continue
        local name=$(basename "$file" .lst)
        sed '/^#/d; /^$/d; /^[[:space:]]*$/d' "$file" | awk '!/\//{ $0=$0"/32" } { print }' | sed 's_.*_route & unreachable;_' | sort -u > "${LIST_RSC_DIR}/${name}.rsc"
        local count
        count=$(wc -l < "${LIST_RSC_DIR}/${name}.rsc")
        log "Generated: ${name}.rsc ($count routes)"
    done
}

# === Step 5: Generate bird.conf from list_rsc ===
generate_bird_conf() {
    log "--- Generating bird.conf ---"

    local ROUTER_ID
    local DEFAULT_IF
    DEFAULT_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "$DEFAULT_IF" ]]; then
        ROUTER_ID=$(ip -4 addr show "$DEFAULT_IF" 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
    fi
    [[ -z "$ROUTER_ID" ]] && ROUTER_ID=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
    [[ -z "$ROUTER_ID" ]] && ROUTER_ID=$(hostname -I 2>/dev/null | awk '{print $1}')
    ROUTER_ID="${ROUTER_ID:-10.137.10.253}"
    log "Router ID: $ROUTER_ID"

    local GW_IP
    GW_IP=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    [[ -z "$GW_IP" ]] && GW_IP="10.137.10.1"
    log "Gateway IP: $GW_IP"

    local includes=""
    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ ! -f "$file" ]] && continue
        local name=$(basename "$file")
        includes="${includes}    include \"/etc/bird/list_rsc/${name}\";
"
    done

    [[ -z "$includes" ]] && { warn "No .rsc files to include"; return 1; }

    cat > "$BIRD_CONF" <<EOF
log syslog all;
router id ${ROUTER_ID};

protocol device {
}

protocol direct {
    disabled;
    ipv4;
    ipv6;
}

protocol kernel {
    ipv4 {
        import none;
        export none;
    };
}

protocol kernel {
    ipv6 { export none; };
}

protocol static static_all {
    ipv4;
${includes}}

filter bgp_out_all {
    if proto = "static_all" then {
        bgp_community.add((64500, 100));
        accept;
    }
    reject;
}

protocol bgp MRK_CHR_GW01 {
    description "Mikrotik CHR GW01";
    neighbor ${GW_IP} as 64501;
    hold time 240;
    local as 64500;
    passive on;
    ipv4 {
        import none;
        export filter bgp_out_all;
        next hop self;
    };
}
EOF
    local count
    count=$(echo "$includes" | grep -c 'include')
    log "bird.conf generated with $count includes"
}

# === Main ===
main() {
    log "=== BIRD2 List Sync Started ==="

    mkdir -p "$LIST_DIR" "$LIST_RSC_DIR" "$LIST_CUSTOM_DIR" "$TMP_DIR" 2>/dev/null

    load_config
    sync_custom_lists
    download_antifilter_lists
    compare_and_update
    process_lists
    generate_bird_conf

    rm -f "${TMP_DIR}"/*.lst 2>/dev/null

    if birdc configure 2>/dev/null; then
        log "BIRD reloaded"
    else
        log "BIRD not running - config will be applied on start"
    fi

    log "=== BIRD2 List Sync Completed ==="
}

main "$@"
