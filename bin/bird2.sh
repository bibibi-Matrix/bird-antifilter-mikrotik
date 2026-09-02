#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="3.2.0"
LOCKFILE="/tmp/bird2-sync.lock"

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
die()  { echo "[FATAL] $(date '+%H:%M:%S') $1" >&2; exit 1; }

# === Flock: prevent concurrent runs ===
acquire_lock() {
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        die "Another bird2.sh is already running (lock: $LOCKFILE)"
    fi
}

# === Read bird2.conf ===
declare -A CFG=()

load_config() {
    if [[ ! -f "$BIRD2_CONF" ]]; then
        warn "Config not found: $BIRD2_CONF - using defaults"
        return 0
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
    local dns="${DNS1:-77.88.8.8}"
    nc -zw1 "$dns" 53 2>/dev/null
}

download_file() {
    local url="$1" output="$2"
    local delay=2
    for ((i=1; i<=3; i++)); do
        if curl -sf --connect-timeout 10 --max-time 120 -o "$output" "$url"; then
            return 0
        fi
        if (( i < 3 )); then
            warn "Download retry $i/3 in ${delay}s: $url"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    return 1
}

files_differ() {
    [[ ! -f "$2" ]] && return 0
    ! cmp -s "$1" "$2"
}

# === IP/CIDR utilities ===

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
    (( mask >= 1 && mask <= 32 )) || return 1
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
        ((STAT_CUSTOM_LISTS++)) || true
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
                ((STAT_LISTS_DOWNLOADED++)) || true
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
                ((STAT_LISTS_DOWNLOADED++)) || true
                updated=true
            else
                warn "Failed: nf_${file}.lst"
            fi
        done
    else
        log "antifilter.network: disabled"
    fi

    [[ "$updated" == "true" ]]
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

# === Step 4: Валидация .lst + генерация .rsc (IPv4 + IPv6) ===
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

        local tmp_invalid="/tmp/invalid_cids.txt"
        : > "$tmp_invalid"

        sed '/^#/d; /^$/d; /^[[:space:]]*$/d' "$file" \
        | awk '
        # IPv4: добавить /32 к голым IP
        !/\// { $0 = $0 "/32" }

        {
            # Разделяем IP и маску
            split($0, parts, "/");
            ip = parts[1];
            mask = parts[2] + 0;

            # Определяем IPv4 или IPv6
            is_v6 = (index(ip, ":") > 0);

            if (is_v6) {
                # IPv6: упрощённая валидация — проверяем наличие : и маски 0-128
                if (mask < 0 || mask > 128 || index(ip, ":") == 0) {
                    print $0 > "/dev/stderr";
                    next;
                }
                print "route " ip "/" mask " unreachable;";
            } else {
                # IPv4: полная валидация
                n = split(ip, oct, ".");
                invalid = 0;
                if (n != 4 || mask < 1 || mask > 32) { invalid = 1; }
                if (!invalid) {
                    for (i = 1; i <= 4; i++) {
                        if (oct[i]+0 < 0 || oct[i]+0 > 255) { invalid = 1; break; }
                    }
                }
                if (invalid) { print $0 > "/dev/stderr"; next; }
                print "route " ip "/" mask " unreachable;";
            }
        }' 2>"$tmp_invalid" \
        | sort -u > "${LIST_RSC_DIR}/${name}.rsc"

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

# === Step 5: Blacklist — awk-based O(n+m) ===
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

    # Конкатенируем все black_list .lst в один файл для awk
    local bl_combined="/tmp/blacklist_combined.txt"
    : > "$bl_combined"
    local bl_files_count=0
    for bl_file in "$BLACKLIST_DIR"/*.lst; do
        [[ -f "$bl_file" ]] || continue
        ((bl_files_count++))
        sed '/^#/d; /^[[:space:]]*$/d' "$bl_file" >> "$bl_combined"
    done

    if [[ ! -s "$bl_combined" ]]; then
        log "Blacklist: empty ($bl_files_count files scanned)"
        return 0
    fi

    # awk: загружаем blacklist CIDR, проверяем containment за один проход
    local removed=0
    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" ]] || continue
        local fname
        fname=$(basename "$file")
        local before
        before=$(wc -l < "$file")

        local result
        result=$(awk -v bl_file="$bl_combined" '
        function ip2int(ip,    a) {
            split(ip, a, ".");
            return a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4];
        }
        function cidr_contains(parent_ip, parent_mask, child_ip, child_mask,    p_int, c_int, p_end, c_end) {
            p_int = ip2int(parent_ip);
            c_int = ip2int(child_ip);
            p_end = p_int + (2^(32 - parent_mask)) - 1;
            c_end = c_int + (2^(32 - child_mask)) - 1;
            return (p_int <= c_int && p_end >= c_end);
        }
        BEGIN {
            # Загружаем blacklist
            nbl = 0;
            while ((getline line < bl_file) > 0) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
                if (line == "" || /^#/) continue;
                if (index(line, "/") == 0) line = line "/32";
                split(line, p, "/");
                bl_ip[nbl] = p[1];
                bl_mask[nbl] = p[2] + 0;
                nbl++;
            }
            close(bl_file);
            total = 0; blocked = 0;
        }
        {
            total++;
            # Извлекаем CIDR из "route X.X.X.X/N unreachable;"
            gsub(/^route /, "");
            gsub(/ unreachable;$/, "");
            split($0, p, "/");
            child_ip = p[1];
            child_mask = p[2] + 0;

            is_blocked = 0;
            for (i = 0; i < nbl; i++) {
                if (cidr_contains(bl_ip[i], bl_mask[i], child_ip, child_mask)) {
                    is_blocked = 1;
                    break;
                }
            }
            if (is_blocked) {
                blocked++;
            } else {
                print "route " child_ip "/" child_mask " unreachable;";
            }
        }
        END {
            print blocked > "/dev/stderr";
        }' "$file" 2>/tmp/blk_removed.txt > "${file}.tmp"

        local blk=0
        [[ -s /tmp/blk_removed.txt ]] && blk=$(cat /tmp/blk_removed.txt)
        removed=$((removed + blk))
        mv "${file}.tmp" "$file"

        local after
        after=$(wc -l < "$file")
        local diff=$((before - after))
        (( diff > 0 )) && log "  $fname: -$diff routes ($before -> $after)"
    done

    STAT_BLACKLIST_REMOVED=$removed
    log "Blacklist applied: $removed routes removed"

    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" && ! -s "$file" ]] && rm -f "$file"
    done

    rm -f "$bl_combined" /tmp/blk_removed.txt
    _recalc_route_count
}

# === Step 6: Проверка и исправление перекрытий CIDR ===
resolve_overlaps() {
    if [[ "$(cfg_get overlap_check)" != "yes" ]]; then
        log "Overlap check: disabled"
        return 0
    fi

    log "--- Resolving CIDR overlaps ---"

    # Конкатенируем все .rsc для awk за один проход
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

    # Один awk: загружает все маршруты, сортирует по mask, ищет containment
    sort -t$'\t' -k1,1 "$all_routes" \
    | awk -F'\t' '
    function ip2int(ip,    a) {
        split(ip, a, ".");
        return a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4];
    }
    {
        lines[NR] = $1; files[NR] = $2;
        gsub(/^route /, "", lines[NR]);
        gsub(/ unreachable;$/, "", lines[NR]);

        split(lines[NR], p, "/");
        base[NR] = ip2int(p[1]);
        mask[NR] = p[2] + 0;
        end[NR] = base[NR] + (2^(32 - mask[NR])) - 1;
        total = NR;
    }
    END {
        # Сортируем индексы по mask ascending (широкие первые)
        for (i = 1; i <= total; i++) idx[i] = i;
        for (i = 1; i <= total; i++) {
            for (j = i+1; j <= total; j++) {
                if (mask[idx[i]] > mask[idx[j]]) {
                    tmp = idx[i]; idx[i] = idx[j]; idx[j] = tmp;
                }
            }
        }
        # Проверяем containment
        nstore = 0;
        for (k = 1; k <= total; k++) {
            i = idx[k];
            for (s = 1; s <= nstore; s++) {
                si = sidx[s];
                if (mask[si] < mask[i] && base[si] <= base[i] && end[si] >= end[i] && lines[si] != lines[i]) {
                    printf "%s\t%s\t%s\t%s\n", lines[i], files[i], lines[si], files[si];
                }
            }
            nstore++;
            sidx[nstore] = i;
        }
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

    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" && ! -s "$file" ]] && rm -f "$file"
    done

    _recalc_route_count
    rm -f "$overlaps_file" "$all_routes"
}

# === Пересчёт маршрутов ===
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
        die "Template not found: $BIRD_TEMPLATE"
    fi

    local ROUTER_ID=""
    local DEFAULT_IF
    DEFAULT_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}') || true
    if [[ -n "${DEFAULT_IF:-}" ]]; then
        ROUTER_ID=$(ip -4 addr show "$DEFAULT_IF" 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}') || true
    fi
    [[ -z "$ROUTER_ID" ]] && ROUTER_ID=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}') || true
    [[ -z "$ROUTER_ID" ]] && ROUTER_ID=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    ROUTER_ID="${ROUTER_ID:-10.137.10.253}"
    log "Router ID: $ROUTER_ID"

    local GW_IP
    GW_IP=$(ip route show default 2>/dev/null | awk '{print $3; exit}') || true
    [[ -z "$GW_IP" ]] && GW_IP="10.137.10.1"
    log "Gateway IP: $GW_IP"

    local LOCAL_AS GW_AS HOLD_TIME
    LOCAL_AS=$(cfg_get local_as 64500)
    GW_AS=$(cfg_get gw_as 64501)
    HOLD_TIME=$(cfg_get hold_time 240)

    local includes=""
    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" ]] || continue
        local name
        name=$(basename "$file")
        includes="${includes}    include \"/etc/bird/list_rsc/${name}\";
"
    done

    [[ -z "$includes" ]] && die "No .rsc files to include"
    includes="${includes%$'\n'}"

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

# === Валидация конфига перед применением ===
validate_bird_config() {
    log "--- Validating bird.conf ---"
    if birdc configure -p 2>/tmp/birdc_check.txt; then
        log "Config validation: OK"
        rm -f /tmp/birdc_check.txt
        return 0
    else
        warn "Config validation FAILED:"
        cat /tmp/birdc_check.txt >&2 2>/dev/null || true
        rm -f /tmp/birdc_check.txt
        return 1
    fi
}

# === Сводка ===
print_stats() {
    echo ""
    echo "=== SYNC REPORT (v${SCRIPT_VERSION}) ==="
    echo "Lists downloaded:     $STAT_LISTS_DOWNLOADED"
    echo "Lists unchanged:      $STAT_LISTS_UNCHANGED"
    echo "Custom lists:         $STAT_CUSTOM_LISTS"
    echo "Invalid CIDRs:        $STAT_INVALID_CIDRS"
    echo "Blacklist removed:    $STAT_BLACKLIST_REMOVED"
    echo "Overlap removed:      $STAT_OVERLAPS_REMOVED"
    echo "Total routes:         $STAT_TOTAL_ROUTES"
    echo "========================"
    echo ""
}

# === Main ===
main() {
    acquire_lock

    log "=== BIRD2 List Sync Started (v${SCRIPT_VERSION}) ==="

    mkdir -p "$LIST_DIR" "$LIST_RSC_DIR" "$LIST_CUSTOM_DIR" "$BLACKLIST_DIR" "$TMP_DIR" 2>/dev/null

    load_config
    sync_custom_lists
    download_antifilter_lists || warn "Download failed - using existing lists"
    compare_and_update
    process_lists
    apply_blacklist
    resolve_overlaps
    generate_bird_conf

    rm -f "${TMP_DIR}"/*.lst 2>/dev/null || true

    print_stats

    if validate_bird_config; then
        if birdc configure 2>/dev/null; then
            log "BIRD reloaded"
        else
            log "BIRD not running - config will be applied on start"
        fi
    else
        warn "BIRD config invalid - NOT reloading (previous config preserved)"
    fi

    log "=== BIRD2 List Sync Completed ==="
}

# === BGP Session Monitor (режим monitor) ===
monitor() {
    if ! birdc show protocols > /tmp/bird_protocols.txt 2>/dev/null; then
        warn "ALERT: BIRD2 is not running or birdc unavailable"
        return 1
    fi

    local alert=0
    local state

    # Проверяем состояние BGP-пиров (Established / не поднят)
    while IFS= read -r line; do
        [[ "$line" =~ ^[^#] || -z "$line" ]] || continue
        case "$line" in
            BGP*) ;;
            *) continue ;;
        esac
        state=$(echo "$line" | awk '{print $4}')
        if [[ "$state" != "Established" && "$state" != "Running" && "$state" != "Up" ]]; then
            warn "ALERT: BGP peer not established: $line"
            alert=1
        fi
    done < /tmp/bird_protocols.txt

    # Проверяем количество маршрутов относительно порога
    local min_routes
    min_routes=$(cfg_get min_routes 1000)
    if [[ "$min_routes" -gt 0 ]]; then
        local route_count
        route_count=$(birdc show route count 2>/dev/null | awk '/routes/{print $NF; exit}' | tr -d '[:space:]')
        if [[ -n "$route_count" ]] && (( 10#$route_count < min_routes )); then
            warn "ALERT: route count ($route_count) below threshold ($min_routes)"
            alert=1
        fi
    fi

    # Периодический лимит для алертов — не спамить чаще чем раз в 15 минут
    local stamp_file="/tmp/bgp_alert_stamp"
    if (( alert == 1 )); then
        local now
        now=$(date +%s)
        if [[ -f "$stamp_file" ]]; then
            local last
            last=$(cat "$stamp_file")
            if (( now - last < 900 )); then
                log "BGP alerts suppressed (last alert <15min ago)"
                rm -f /tmp/bird_protocols.txt
                return 0
            fi
        fi
        echo "$now" > "$stamp_file"
    else
        rm -f "$stamp_file"
    fi

    rm -f /tmp/bird_protocols.txt
    return $alert
}

if [[ "${1:-}" == "monitor" ]]; then
    # monitor требует конфиг для min_routes
    load_config > /dev/null 2>&1 || true
    monitor
    exit $?
fi

main "$@"
