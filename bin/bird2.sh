#!/bin/bash
set -uo pipefail

# === Paths ===
BASE_DIR="/etc/bird"
LIST_DIR="${BASE_DIR}/list"
LIST_CUSTOM_DIR="${BASE_DIR}/list_custom"
LIST_RSC_DIR="${BASE_DIR}/list_rsc"
BLACKLIST_DIR="${BASE_DIR}/black_list"
BIRD_CONF="${BASE_DIR}/bird.conf"
BIRD_TEMPLATE="${BASE_DIR}/bird.conf.template"
BIRD2_CONF="${BASE_DIR}/bird2.conf"
TMP_DIR="/tmp"

# === Counters ===
STAT_LISTS_DOWNLOADED=0
STAT_LISTS_UNCHANGED=0
STAT_CUSTOM_LISTS=0
STAT_TOTAL_ROUTES=0
STAT_INVALID_CIDRS=0
STAT_BLACKLIST_REMOVED=0
STAT_OVERLAPS_REMOVED=0

log()  { echo "[INFO] $(date '+%H:%M:%S') $1"; }
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
    echo "${CFG[$1]:-${2:-no}}"
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

# === IP/CIDR utilities ===

ip_to_int() {
    local ip="$1" a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

validate_cidr() {
    local cidr="$1" ip mask
    if [[ "$cidr" == */* ]]; then
        ip="${cidr%/*}"
        mask="${cidr#*/}"
    else
        ip="$cidr"
        mask=32
    fi
    [[ "$mask" =~ ^[0-9]+$ ]] || return 1
    (( mask >= 0 && mask <= 32 )) || return 1
    local -a octets
    IFS='.' read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -ne 4 ]] && return 1
    local o
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

cidr_contains() {
    local parent_ip="${1%/*}" parent_mask="${1#*/}"
    local child_ip="${2%/*}"  child_mask="${2#*/}"
    local p_int c_int p_end c_end
    p_int=$(ip_to_int "$parent_ip")
    c_int=$(ip_to_int "$child_ip")
    p_end=$(( p_int + (1 << (32 - parent_mask)) - 1 ))
    c_end=$(( c_int + (1 << (32 - child_mask)) - 1 ))
    (( p_int <= c_int && p_end >= c_end ))
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
        local name
        name=$(basename "$file" .lst)
        cp "$file" "${LIST_DIR}/${name}.lst"
        log "Copied: $name"
        ((STAT_CUSTOM_LISTS++))
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
            [[ "$(cfg_get "$file")" != "yes" ]] && { log "Skipped (disabled): $file"; continue; }
            local url
            if [[ "$file" == "community" ]]; then
                url="https://community.antifilter.download/list/${file}.lst"
            else
                url="https://antifilter.download/list/${file}.lst"
            fi
            if download_file "$url" "${TMP_DIR}/${file}.lst"; then
                log "Downloaded (antifilter.download): $file.lst"
                ((STAT_LISTS_DOWNLOADED++))
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
            [[ "$(cfg_get "nf_$file")" != "yes" ]] && { log "Skipped (disabled): nf_$file"; continue; }
            if download_file "https://antifilter.network/download/${file}.lst" "${TMP_DIR}/nf_${file}.lst"; then
                log "Downloaded (antifilter.network): nf_${file}.lst"
                ((STAT_LISTS_DOWNLOADED++))
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
        local name
        name=$(basename "$file")
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

    STAT_LISTS_UNCHANGED=$unchanged
    log "Result: $updated updated, $unchanged unchanged"
}

# === Step 4: Валидация .lst + генерация .rsc ===
process_lists() {
    log "--- Processing lists -> list_rsc ---"
    rm -f "${LIST_RSC_DIR}"/*.rsc 2>/dev/null

    if ! ls "$LIST_DIR"/*.lst 1>/dev/null 2>&1; then
        warn "No .lst files in $LIST_DIR"
        return 0
    fi

    for file in "${LIST_DIR}"/*.lst; do
        [[ ! -f "$file" ]] && continue
        local name
        name=$(basename "$file" .lst)

        # Сбор невалидных CIDR и генерация .rsc
        local tmp_invalid="/tmp/invalid_cids.txt"
        : > "$tmp_invalid"

        sed '/^#/d; /^$/d; /^[[:space:]]*$/d' "$file" \
        | awk '!/\//{ $0=$0"/32" }
        {
            split($0, a, "/");
            ip = a[1]; mask = a[2]+0;
            n = split(ip, oct, ".");
            invalid = 0;
            if (n != 4 || mask < 0 || mask > 32) { invalid = 1; }
            if (!invalid) {
                for (i = 1; i <= 4; i++) {
                    if (oct[i]+0 < 0 || oct[i]+0 > 255) { invalid = 1; break; }
                }
            }
            if (invalid) { print $0 > "/dev/stderr"; next }
            print
        }' 2>"$tmp_invalid" \
        | sed 's_.*_route & unreachable;_' \
        | sort -u > "${LIST_RSC_DIR}/${name}.rsc"

        # Подсчёт невалидных
        local inv=0
        if [[ -s "$tmp_invalid" ]]; then
            inv=$(wc -l < "$tmp_invalid")
            STAT_INVALID_CIDRS=$((STAT_INVALID_CIDRS + inv))
            warn "Invalid CIDRs in $name.lst ($inv):"
            cat "$tmp_invalid" >&2
        fi
        rm -f "$tmp_invalid"

        local count=0
        [[ -s "${LIST_RSC_DIR}/${name}.rsc" ]] && count=$(wc -l < "${LIST_RSC_DIR}/${name}.rsc")
        STAT_TOTAL_ROUTES=$((STAT_TOTAL_ROUTES + count))

        if (( inv > 0 )); then
            log "Generated: ${name}.rsc ($count routes, $inv invalid skipped)"
        else
            log "Generated: ${name}.rsc ($count routes)"
        fi
    done
}

# === Step 5: Blacklist — удаление из .rsc по black_list/ ===
apply_blacklist() {
    if [[ "$(cfg_get blacklist)" != "yes" ]]; then
        log "Blacklist: disabled"
        return 0
    fi

    if [[ ! -d "$BLACKLIST_DIR" ]]; then
        log "Blacklist: directory not found"
        return 0
    fi

    if ! ls "$BLACKLIST_DIR"/*.lst 1>/dev/null 2>&1; then
        log "Blacklist: no .lst files"
        return 0
    fi

    log "--- Applying blacklist ---"

    # Загружаем все CIDR из black_list/
    local bl_cidrs=()
    local bl_files_count=0
    for bl_file in "$BLACKLIST_DIR"/*.lst; do
        [[ -f "$bl_file" ]] || continue
        ((bl_files_count++))
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/#.*//; /^[[:space:]]*$/d')
            [[ -z "$line" ]] && continue
            [[ "$line" != */* ]] && line="${line}/32"
            if validate_cidr "$line"; then
                bl_cidrs+=("$line")
            else
                warn "Invalid CIDR in black_list: $line"
            fi
        done < "$bl_file"
    done

    if [[ ${#bl_cidrs[@]} -eq 0 ]]; then
        log "Blacklist: empty or no valid entries ($bl_files_count files scanned)"
        return 0
    fi

    log "Blacklist loaded: ${#bl_cidrs[@]} CIDRs from $bl_files_count files"

    local removed=0
    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" ]] || continue
        local fname
        fname=$(basename "$file")
        local before
        before=$(wc -l < "$file")

        local tmp="${file}.tmp"
        : > "$tmp"

        while IFS= read -r route_line; do
            local route_cidr
            route_cidr=$(echo "$route_line" | sed 's/^route //; s/ unreachable;$//')

            local blocked=false
            for bl in "${bl_cidrs[@]}"; do
                if cidr_contains "$bl" "$route_cidr"; then
                    blocked=true
                    break
                fi
            done

            if [[ "$blocked" == "true" ]]; then
                ((removed++))
            else
                echo "$route_line" >> "$tmp"
            fi
        done < "$file"

        mv "$tmp" "$file"

        local after
        after=$(wc -l < "$file")
        local diff=$((before - after))
        (( diff > 0 )) && log "  $fname: -$diff routes ($before -> $after)"
    done

    STAT_BLACKLIST_REMOVED=$removed
    log "Blacklist applied: $removed routes removed"

    # Удалить пустые .rsc
    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" && ! -s "$file" ]] && rm -f "$file"
    done

    _recalc_route_count
}

# === Step 6: Проверка и исправление перекрытий CIDR ===
resolve_overlaps() {
    if [[ "$(cfg_get overlap_check)" != "yes" ]]; then
        log "Overlap check: disabled"
        return 0
    fi

    log "--- Resolving CIDR overlaps ---"

    local all_routes="/tmp/all_routes.txt"
    : > "$all_routes"

    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" ]] || continue
        local fname
        fname=$(basename "$file")
        while IFS= read -r line; do
            printf '%s\t%s\n' "$line" "$fname" >> "$all_routes"
        done < "$file"
    done

    if [[ ! -s "$all_routes" ]]; then
        rm -f "$all_routes"
        return 0
    fi

    local overlaps_file="/tmp/overlaps.txt"
    local strategy
    strategy=$(cfg_get overlap_strategy specific)

    # Сортировка по mask (ascending) → более широкие префиксы первыми
    awk -F'\t' '{ split($1, a, "/"); print a[2] "\t" $0 }' "$all_routes" \
    | sort -t$'\t' -k1,1n \
    | cut -f2- \
    | awk -F'\t' '
    function ip2int(ip,    a) {
        split(ip, a, ".");
        return a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4];
    }
    {
        line = $1; file = $2;
        gsub(/^route /, "", line);
        gsub(/ unreachable;$/, "", line);

        split(line, p, "/");
        base = ip2int(p[1]);
        mask = p[2] + 0;
        end = base + (2^(32 - mask)) - 1;

        # Проверяем: текущий subnet contained in ранее сохранённом supernet?
        for (i = 1; i <= n; i++) {
            if (sb[i] < mask && sbase[i] <= base && send[i] >= end && sline[i] != line) {
                printf "%s\t%s\t%s\t%s\n", line, file, sline[i], sfile[i];
            }
        }

        n++;
        sbase[n] = base; send[n] = end; sb[n] = mask;
        sline[n] = line; sfile[n] = file;
    }' > "$overlaps_file"

    local overlap_count
    overlap_count=$(wc -l < "$overlaps_file")

    if (( overlap_count == 0 )); then
        log "No CIDR overlaps detected"
        rm -f "$overlaps_file" "$all_routes"
        return 0
    fi

    log "Detected $overlap_count overlaps"

    if [[ "$strategy" == "log_only" ]]; then
        while IFS=$'\t' read -r child cf parent pf; do
            warn "  $child ($cf) contained in $parent ($pf)"
        done < "$overlaps_file"
        rm -f "$overlaps_file" "$all_routes"
        return 0
    fi

    # strategy=specific: удаляем supernet (parent) из его .rsc файла
    local removed=0
    while IFS=$'\t' read -r child cf parent pf; do
        warn "  $child ($cf) contained in $parent ($pf)"
        local target="${LIST_RSC_DIR}/${pf}"
        if [[ -f "$target" ]]; then
            local route_line="route ${parent} unreachable;"
            grep -vxF "$route_line" "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
            log "  Removed: $parent from $pf"
            ((removed++))
        fi
    done < "$overlaps_file"

    STAT_OVERLAPS_REMOVED=$removed
    log "Overlap resolution: $removed supernet routes removed (strategy: $strategy)"

    # Удалить пустые .rsc
    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" && ! -s "$file" ]] && rm -f "$file"
    done

    _recalc_route_count
    rm -f "$overlaps_file" "$all_routes"
}

# === Пересчёт общего количества маршрутов ===
_recalc_route_count() {
    STAT_TOTAL_ROUTES=0
    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" ]] || continue
        local c
        c=$(wc -l < "$file")
        STAT_TOTAL_ROUTES=$((STAT_TOTAL_ROUTES + c))
    done
}

# === Step 7: Генерация bird.conf из шаблона ===
generate_bird_conf() {
    log "--- Generating bird.conf from template ---"

    if [[ ! -f "$BIRD_TEMPLATE" ]]; then
        warn "Template not found: $BIRD_TEMPLATE"
        return 1
    fi

    # Router ID
    local ROUTER_ID=""
    local DEFAULT_IF
    DEFAULT_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "$DEFAULT_IF" ]]; then
        ROUTER_ID=$(ip -4 addr show "$DEFAULT_IF" 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
    fi
    [[ -z "$ROUTER_ID" ]] && ROUTER_ID=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
    [[ -z "$ROUTER_ID" ]] && ROUTER_ID=$(hostname -I 2>/dev/null | awk '{print $1}')
    ROUTER_ID="${ROUTER_ID:-10.137.10.253}"
    log "Router ID: $ROUTER_ID"

    # Gateway IP
    local GW_IP
    GW_IP=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    [[ -z "$GW_IP" ]] && GW_IP="10.137.10.1"
    log "Gateway IP: $GW_IP"

    # BGP параметры
    local LOCAL_AS GW_AS HOLD_TIME
    LOCAL_AS=$(cfg_get local_as 64500)
    GW_AS=$(cfg_get gw_as 64501)
    HOLD_TIME=$(cfg_get hold_time 240)

    # Сбор include-ов
    local includes=""
    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" ]] || continue
        local name
        name=$(basename "$file")
        includes="${includes}    include \"/etc/bird/list_rsc/${name}\";
"
    done

    [[ -z "$includes" ]] && { warn "No .rsc files to include"; return 1; }
    includes="${includes%$'\n'}"

    # Подстановка переменных
    sed -e "s|@@ROUTER_ID@@|${ROUTER_ID}|g" \
        -e "s|@@GW_IP@@|${GW_IP}|g" \
        -e "s|@@LOCAL_AS@@|${LOCAL_AS}|g" \
        -e "s|@@GW_AS@@|${GW_AS}|g" \
        -e "s|@@HOLD_TIME@@|${HOLD_TIME}|g" \
        -e "s|@@INCLUDES@@|${includes}|" \
        "$BIRD_TEMPLATE" > "$BIRD_CONF"

    local count
    count=$(echo "$includes" | grep -c 'include')
    log "bird.conf generated from template with $count includes"
}

# === Сводка ===
print_stats() {
    echo ""
    echo "=== SYNC REPORT ==="
    echo "Lists downloaded:     $STAT_LISTS_DOWNLOADED"
    echo "Lists unchanged:      $STAT_LISTS_UNCHANGED"
    echo "Custom lists:         $STAT_CUSTOM_LISTS"
    echo "Invalid CIDRs:        $STAT_INVALID_CIDRS"
    echo "Blacklist removed:    $STAT_BLACKLIST_REMOVED"
    echo "Overlap removed:      $STAT_OVERLAPS_REMOVED"
    echo "Total routes:         $STAT_TOTAL_ROUTES"
    echo "===================="
    echo ""
}

# === Main ===
main() {
    log "=== BIRD2 List Sync Started ==="

    mkdir -p "$LIST_DIR" "$LIST_RSC_DIR" "$LIST_CUSTOM_DIR" "$BLACKLIST_DIR" "$TMP_DIR" 2>/dev/null

    load_config
    sync_custom_lists
    download_antifilter_lists
    compare_and_update
    process_lists
    apply_blacklist
    resolve_overlaps
    generate_bird_conf

    rm -f "${TMP_DIR}"/*.lst 2>/dev/null

    print_stats

    if birdc configure 2>/dev/null; then
        log "BIRD reloaded"
    else
        log "BIRD not running - config will be applied on start"
    fi

    log "=== BIRD2 List Sync Completed ==="
}

main "$@"
