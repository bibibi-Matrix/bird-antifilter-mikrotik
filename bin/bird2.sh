#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="3.3.0"
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
STAT_DUPLICATES_SKIPPED=0
STAT_BLACKLIST_REMOVED=0
STAT_BLACKLIST_SPLITS=0
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

    # Сквозной список уже выданных маршрутов — дубликаты (в т.ч. из других
    # списков) пропускаются, количество пропущенных учитывается в статистике.
    local seen_file="$TMP_DIR/rsc_seen.txt"
    : > "$seen_file"

    for file in "${LIST_DIR}"/*.lst; do
        [[ ! -f "$file" ]] && continue
        local name
        name=$(basename "$file" .lst)

        local tmp_invalid="/tmp/invalid_cids.txt"
        : > "$tmp_invalid"
        local tmp_dup="/tmp/dup_cids.txt"
        : > "$tmp_dup"
        local converted="$TMP_DIR/${name}.pre"

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
        | sort > "$converted"

        local inv=0
        if [[ -s "$tmp_invalid" ]]; then
            inv=$(wc -l < "$tmp_invalid")
            STAT_INVALID_CIDRS=$((STAT_INVALID_CIDRS + inv))
            warn "Invalid CIDRs in $name.lst ($inv):"
            cat "$tmp_invalid" >&2
        fi
        rm -f "$tmp_invalid"

        # Дедупликация: строки, уже встречавшиеся в этом прогоне (включая
        # разные формы одной сети, напр. IP vs IP/32), пропускаются и считаются.
        awk -v sfile="$seen_file" '
            BEGIN {
                dn = 0;
                while ((getline k < sfile) > 0) seen[k] = 1;
                close(sfile);
            }
            {
                if ($0 in seen) { dup++; next; }
                seen[$0] = 1;
                print;
                buf[++dn] = $0;
            }
            END {
                for (i = 1; i <= dn; i++) print buf[i] >> sfile;
                close(sfile);
                print (dup+0) > "/dev/stderr";
            }' "$converted" 2>"$tmp_dup" > "${LIST_RSC_DIR}/${name}.rsc"
        rm -f "$converted"

        local dup=0
        if [[ -s "$tmp_dup" ]]; then
            dup=$(cat "$tmp_dup")
        fi
        rm -f "$tmp_dup"
        STAT_DUPLICATES_SKIPPED=$((STAT_DUPLICATES_SKIPPED + dup))

        local count=0
        [[ -s "${LIST_RSC_DIR}/${name}.rsc" ]] && count=$(wc -l < "${LIST_RSC_DIR}/${name}.rsc")
        STAT_TOTAL_ROUTES=$((STAT_TOTAL_ROUTES + count))

        local msg="Generated: ${name}.rsc ($count routes"
        (( inv > 0 )) && msg="${msg}, $inv invalid"
        (( dup > 0 )) && msg="${msg}, $dup duplicates skipped"
        msg="${msg})"
        log "$msg"
    done
}

# === Step 5: Blacklist — удаление и вычитание префиксов (IPv4 + IPv6) ===
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

    # Конкатенируем все black_list .lst в один файл
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

    local split_on
    split_on=$(cfg_get blacklist_split yes)

    # Общие функции: IPv4/IPv6 представляются как 32-hex строки, операции
    # над префиксами (вложение, деление на sibling-префиксы) — без 128-бит
    # арифметики, только строки и таблицы.
    cat > /tmp/bl_lib.awk <<'AWK'
function hd(ch,    idx) {
    idx = index("0123456789abcdefABCDEF", ch);
    if (idx == 0) return -1;
    if (idx > 16) return idx - 16 - 1;
    return idx - 1;
}
function hexd(v) { return substr("0123456789abcdef", v + 1, 1); }
function hex2(v) { return hexd(int(v / 16)) hexd(v % 16); }
function hex4(v) { return hexd(int(v / 4096)) hexd(int(v / 256) % 16) hexd(int(v / 16) % 16) hexd(v % 16); }
function hx(str,    v, i) {
    v = 0;
    for (i = 1; i <= length(str); i++) v = v * 16 + hd(substr(str, i, 1));
    return v;
}
function v4tohex(addr,    o, n, i, v, h) {
    n = split(addr, o, ".");
    if (n != 4) return "";
    h = "";
    for (i = 1; i <= 4; i++) {
        if (o[i] == "" || o[i] ~ /[^0-9]/) return "";
        v = o[i] + 0;
        if (v > 255) return "";
        h = h hex2(v);
    }
    return h;
}
function pad4(hexgrp,    v, i) {
    v = 0;
    for (i = 1; i <= length(hexgrp); i++) v = v * 16 + hd(substr(hexgrp, i, 1));
    return hex4(v);
}
function v6tohex(addr,    a, xmarks, n, i, p, hex, hg, emb, ehex, compress, c) {
    if (index(addr, ":") == 0) return "";
    a = addr;
    xmarks = gsub(/::/, ":X:", a);
    if (xmarks > 1) return "";
    n = split(a, parts_, ":");
    hex = ""; hg = 0; emb = 0; ehex = "";
    for (i = 1; i <= n; i++) {
        p = parts_[i];
        if (p == "X") continue;
        if (p == "") {
            # граничные пустые поля допустимы только у "::" на краях
            if (xmarks == 0) return "";
            if (i != 1 && i != n) return "";
            continue;
        }
        if (p ~ /\./) {
            if (emb) return "";
            ehex = v4tohex(p);
            if (ehex == "" || i != n) return "";
            emb = 1;
            continue;
        }
        if (!(p ~ /^[0-9a-fA-F]{1,4}$/)) return "";
        hg++;
    }
    hg = hg + (emb ? 2 : 0);
    if (xmarks > 0) {
        if (hg > 7) return "";
        compress = 8 - hg;
    } else {
        if (hg != 8) return "";
        compress = 0;
    }
    for (i = 1; i <= n; i++) {
        p = parts_[i];
        if (p == "X") {
            for (c = 1; c <= compress; c++) hex = hex "0000";
        } else if (p == "") {
            continue;
        } else if (p ~ /\./) {
            hex = hex ehex;
        } else {
            hex = hex pad4(p);
        }
    }
    if (length(hex) != 32) return "";
    return hex;
}
function ip2hex(addr,    h) {
    if (index(addr, ":") > 0) return v6tohex(addr);
    h = v4tohex(addr);
    if (h == "") return "";
    return "000000000000000000000000" h;
}
function fam_off(isv6) { return (isv6 ? 0 : 96); }
function masked(hex, off, L,    sc, full, rem, out, pad, i) {
    sc = off / 4 + 1;
    full = int(L / 4);
    rem = L % 4;
    out = substr(hex, 1, sc - 1);
    out = out substr(hex, sc, full);
    if (rem > 0) out = out hexd(KEEP[rem "," hd(substr(hex, sc + full, 1))]);
    pad = 32 - sc + 1 - (full + (rem > 0 ? 1 : 0));
    for (i = 1; i <= pad; i++) out = out "0";
    return out;
}
function bit_eq(a, b, off, L,    sc, full, rem, da, db) {
    sc = off / 4 + 1;
    full = int(L / 4);
    rem = L % 4;
    if (substr(a, sc, full) != substr(b, sc, full)) return 0;
    if (rem > 0) {
        da = KEEP[rem "," hd(substr(a, sc + full, 1))];
        db = KEEP[rem "," hd(substr(b, sc + full, 1))];
        if (da != db) return 0;
    }
    return 1;
}
function hex2v4(hex,    t) {
    t = substr(hex, 25, 8);
    return hx(substr(t, 1, 2)) "." hx(substr(t, 3, 2)) "." hx(substr(t, 5, 2)) "." hx(substr(t, 7, 2));
}
function hex2v6(hex,    g, i, bests, beste, run, out, pending) {
    for (i = 0; i < 8; i++) {
        g[i] = substr(hex, i * 4 + 1, 4);
        sub(/^0+/, "", g[i]);
        if (g[i] == "") g[i] = "0";
    }
    bests = -1; beste = -1;
    i = 0;
    while (i < 8) {
        if (g[i] == "0") {
            run = i;
            while (run < 8 && g[run] == "0") run++;
            if (run - i >= 2 && (run - i) > (beste - bests)) { bests = i; beste = run; }
            i = run;
        } else i++;
    }
    out = ""; pending = 0;
    for (i = 0; i < 8; i++) {
        if (bests >= 0 && i == bests) {
            out = out "::";
            i = beste - 1;
            pending = 0;
            continue;
        }
        if (pending) out = out ":";
        out = out g[i];
        pending = 1;
    }
    return out;
}
function sub_one(PH, PO, PM, BH, BO, BM,    L, off, path, ci, bo, sib) {
    res_n = 0;
    for (L = PM + 1; L <= BM; L++) {
        off = PO;
        path = masked(BH, off, L);
        ci = int((off + L - 1) / 4) + 1;
        bo = (off + L - 1) % 4;
        sib = substr(path, 1, ci - 1) hexd(FLIP[bo "," hd(substr(path, ci, 1))]) substr(path, ci + 1);
        res_n++;
        res_h[res_n] = sib;
        res_m[res_n] = L;
    }
}
function tables_init(    d) {
    for (d = 0; d < 16; d++) {
        KEEP[1 "," d] = (d >= 8 ? 8 : 0);
        KEEP[2 "," d] = int(d / 4) * 4;
        KEEP[3 "," d] = int(d / 2) * 2;
        FLIP[0 "," d] = (d >= 8 ? d - 8 : d + 8);
        FLIP[1 "," d] = (int(d / 4) % 2 ? d - 4 : d + 4);
        FLIP[2 "," d] = (int(d / 2) % 2 ? d - 2 : d + 2);
        FLIP[3 "," d] = (d % 2 ? d - 1 : d + 1);
    }
}
AWK

    # Нормализация чёрного списка: каждая запись -> "hex|mask|is_v6",
    # невалидные и дубликаты отбрасываются с подсчётом.
    cat > /tmp/bl_norm.awk <<'AWK'
BEGIN {
    tables_init();
    inv = 0; dupb = 0;
    while ((getline line < src) > 0) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
        ok = 0;
        if (line != "" && !(line ~ /^#/)) {
            if (index(line, "/") == 0) {
                if (index(line, ":") > 0) line = line "/128"; else line = line "/32";
            }
            split(line, p, "/");
            if (p[2] ~ /^[0-9]+$/) {
                pm = p[2] + 0;
                pv6 = (index(p[1], ":") > 0);
                if (pm >= 1 && !(pv6 && pm > 128) && !(!pv6 && pm > 32)) {
                    ph = ip2hex(p[1]);
                    ok = (ph != "");
                    if (!ok) inv++;
                } else { inv++; }
            } else { inv++; }
        }
        if (ok) {
            key = ph "," pm;
            if (seen[key]) { dupb++; }
            else { seen[key] = 1; printf "%s|%d|%d\n", ph, pm, pv6; }
        }
    }
    close(src);
    printf "INVALID %d\n", inv > "/dev/stderr";
    printf "DUPBL %d\n", dupb > "/dev/stderr";
}
AWK

    awk -v src="$bl_combined" -f /tmp/bl_lib.awk -f /tmp/bl_norm.awk \
        > /tmp/blacklist_norm.txt 2>/tmp/blacklist_norm_err.txt || true

    local bl_inv=0 bl_dupb=0 bl_line=""
    while IFS= read -r bl_line; do
        case "$bl_line" in
            INVALID*) bl_inv=${bl_line#INVALID } ;;
            DUPBL*)   bl_dupb=${bl_line#DUPBL } ;;
        esac
    done < /tmp/blacklist_norm_err.txt
    rm -f /tmp/blacklist_norm_err.txt
    (( bl_inv > 0 )) && warn "Blacklist: $bl_inv invalid entries skipped (0.0.0.0/0 отклоняется)"
    (( bl_dupb > 0 )) && log "Blacklist: $bl_dupb duplicate entries collapsed"

    if [[ ! -s /tmp/blacklist_norm.txt ]]; then
        log "Blacklist: no valid entries"
        rm -f "$bl_combined" /tmp/blacklist_norm.txt
        return 0
    fi

    # Основной фильтр: маршрут в чёрном -> удалить; чёрный внутри маршрута ->
    # разбить маршрут на sibling-префиксы (если включено).
    cat > /tmp/bl_apply.awk <<'AWK'
BEGIN {
    tables_init();
    nbl = 0;
    while ((getline line < src) > 0) {
        if (line != "" && !(line ~ /^#/)) {
            split(line, f, "|");
            bl_hex[nbl] = f[1];
            bl_mask[nbl] = f[2] + 0;
            bl_v6[nbl] = f[3] + 0;
            bl_off[nbl] = fam_off(bl_v6[nbl]);
            nbl++;
        }
    }
    close(src);
    if (nbl == 0) no_bl = 1;
    blocked_cnt = 0; split_cnt = 0;
}
{
    if (no_bl) { print; next; }
    gsub(/^route /, "");
    gsub(/ unreachable;$/, "");
    split($0, p, "/");
    rv6 = (index(p[1], ":") > 0);
    roff = fam_off(rv6);
    rmask = p[2] + 0;
    rhex = ip2hex(p[1]);
    if (rhex == "") { print "route " $0 " unreachable;"; next; }

    blocked = 0;
    for (i = 0; i < nbl; i++) {
        if (bl_v6[i] != rv6) continue;
        if (bl_mask[i] <= rmask && bit_eq(bl_hex[i], rhex, bl_off[i], bl_mask[i])) { blocked = 1; break; }
    }
    if (blocked) { blocked_cnt++; next; }

    if (do_split == "yes") {
        nin = 0;
        for (i = 0; i < nbl; i++) {
            if (bl_v6[i] != rv6) continue;
            if (bl_mask[i] > rmask && bit_eq(rhex, bl_hex[i], roff, rmask)) inside[++nin] = i;
        }
        if (nin > 0) {
            pc = 1; p_h[1] = rhex; p_m[1] = rmask;
            for (j = 1; j <= nin; j++) {
                b = inside[j];
                nc = 0;
                for (k = 1; k <= pc; k++) {
                    if (p_m[k] < bl_mask[b] && bit_eq(p_h[k], bl_hex[b], roff, p_m[k])) {
                        sub_one(p_h[k], roff, p_m[k], bl_hex[b], bl_off[b], bl_mask[b]);
                        for (t = 1; t <= res_n; t++) { nc++; n_h[nc] = res_h[t]; n_m[nc] = res_m[t]; }
                    } else if (bl_mask[b] <= p_m[k] && bit_eq(bl_hex[b], p_h[k], bl_off[b], bl_mask[b])) {
                        continue;
                    } else {
                        nc++; n_h[nc] = p_h[k]; n_m[nc] = p_m[k];
                    }
                }
                for (k = 1; k <= nc; k++) { p_h[k] = n_h[k]; p_m[k] = n_m[k]; }
                pc = nc;
            }
            split_cnt++;
            for (k = 1; k <= pc; k++) {
                if (rv6) a = hex2v6(p_h[k]); else a = hex2v4(p_h[k]);
                print "route " a "/" p_m[k] " unreachable;";
            }
            next;
        }
    }
    print "route " $0 " unreachable;";
}
END {
    if (cnt_f != "") {
        printf "%d\n", blocked_cnt > cnt_f;
        printf "%d\n", split_cnt > cnt_f;
        close(cnt_f);
    }
}
AWK

    local removed=0 splits=0
    local cntf
    for file in "${LIST_RSC_DIR}"/*.rsc; do
        [[ -f "$file" ]] || continue
        local fname
        fname=$(basename "$file")
        local before
        before=$(wc -l < "$file")
        cntf="/tmp/blk_counts.${fname}.txt"
        : > "$cntf"

        awk -v src="/tmp/blacklist_norm.txt" -v cnt_f="$cntf" \
            -v do_split="$split_on" \
            -f /tmp/bl_lib.awk -f /tmp/bl_apply.awk \
            "$file" > "${file}.tmp" || true

        local bcnt=0 scnt=0
        { read -r bcnt; read -r scnt; } < "$cntf" || true
        removed=$((removed + bcnt))
        splits=$((splits + scnt))
        mv "${file}.tmp" "$file"

        local after
        after=$(wc -l < "$file")
        if (( bcnt > 0 || scnt > 0 || before != after )); then
            log "  $fname: removed $bcnt, split $scnt (routes: $before -> $after)"
        fi
    done

    STAT_BLACKLIST_REMOVED=$removed
    STAT_BLACKLIST_SPLITS=$splits

    # После разбиения некоторые префиксы могут совпасть с уже существующими
    # маршрутами других файлов — глобальная дедупликация с сортировкой.
    local total_dups=0
    if [[ "$splits" -gt 0 ]]; then
        local comb="$TMP_DIR/rsc_combine.txt"
        : > "$comb"
        for file in "${LIST_RSC_DIR}"/*.rsc; do
            [[ -f "$file" ]] || continue
            awk -v tag="$(basename "$file")" '{ print tag "\t" $0 }' "$file" >> "$comb"
        done

        local outd="$TMP_DIR/rsc_out"
        rm -rf "$outd"
        mkdir -p "$outd"
        local dcounts="$TMP_DIR/rsc_dup.txt"
        : > "$dcounts"

        sort -t$'\t' -k2,2 "$comb" | awk -F'\t' -v outd="$outd" -v dcounts="$dcounts" '
            {
                if (seen[$2]++) { dups[$1]++; next; }
                print $2 > (outd "/" $1);
            }
            END {
                for (f in dups) printf "%s\t%d\n", f, dups[f] > dcounts;
                close(dcounts);
            }
        '

        while IFS=$'\t' read -r fnam n; do
            [[ -n "$fnam" ]] || continue
            total_dups=$((total_dups + n))
            (( n > 0 )) && log "  $fnam: dedup -$n duplicates"
        done < "$dcounts"

        for file in "${LIST_RSC_DIR}"/*.rsc; do
            [[ -f "$file" ]] || continue
            local fn
            fn=$(basename "$file")
            if [[ -f "$outd/$fn" && -s "$outd/$fn" ]]; then
                mv -f "$outd/$fn" "$file"
            else
                rm -f "$file"
            fi
        done

        rm -f "$comb"
        rm -rf "$outd"
        rm -f "$dcounts"
    else
        for file in "${LIST_RSC_DIR}"/*.rsc; do
            [[ -f "$file" && ! -s "$file" ]] && rm -f "$file"
        done
    fi

    STAT_DUPLICATES_SKIPPED=$((STAT_DUPLICATES_SKIPPED + total_dups))
    log "Blacklist applied: $removed removed, $splits split, $total_dups dedup"
    rm -f "$bl_combined" /tmp/blacklist_norm.txt \
        /tmp/bl_lib.awk /tmp/bl_norm.awk /tmp/bl_apply.awk \
        /tmp/blk_counts.*.txt 2>/dev/null || true
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
    echo "Duplicates skipped:   $STAT_DUPLICATES_SKIPPED"
    echo "Blacklist removed:    $STAT_BLACKLIST_REMOVED"
    echo "Blacklist splits:     $STAT_BLACKLIST_SPLITS"
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

    rm -f "${TMP_DIR}"/*.lst "${TMP_DIR}/rsc_seen.txt" 2>/dev/null || true

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
