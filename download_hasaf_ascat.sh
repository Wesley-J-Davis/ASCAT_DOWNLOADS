#!/usr/bin/env bash

set -euo pipefail

HOST="ftphsaf.meteoam.it"
PRODUCT="h121"
FORMAT="netcdf"
SATELLITE="all"
YEAR=""
MONTH=""
PARALLEL=4
DRY_RUN=0

usage() {
    cat <<'EOF'
Download H SAF ASCAT soil-moisture files.

Usage:
  download_hsaf_ascat.sh --user USER --dest DIR [options]

Required:
  -u, --user USER          H SAF FTP username
  -d, --dest DIR           Local product root (for example, /data/H121)

Options:
  -p, --product PRODUCT    h121 or h139 (default: h121)
  -s, --satellite SAT      metop_a, metop_b, metop_c, or all (default: all)
  -y, --year YYYY          Limit the download to one year
  -m, --month MM           Limit the download to one month (requires --year)
  -j, --parallel N         h121 only: number of parallel lftp transfers (default: 4)
      --dry-run            List what would transfer without downloading
  -h, --help               Show this help

h121 is the reprocessed CDR: full historical archive, organized as
/h121/netcdf/<sat>/<year>/<month>/ on the server, mirrored locally the
same way under DEST/<sat>/<year>/<month>/. Ends per-satellite: Metop-A
Nov 2021, Metop-B/C Dec 2021 (no newer H121 data exists).

h139 is the near-real-time counterpart: NOT a continuous archive. The
server keeps only a rolling ~2-month window in one flat directory
(/h139/h139_cur_mon_data/), so --year/--month just filter within
whatever that window currently covers - they will not reach back to
the H121 cutoff. Files land flat under DEST/<sat>/ (no year/month
subfolders, since the server has none either); the filename itself
encodes the exact timestamp. Downloaded via curl, one file at a time,
because lftp's own get/mirror hang or fail on this product's filenames
(embedded commas). Requires a ~/.netrc entry for machine ftphsaf.meteoam.it
(chmod 600) - curl's per-file connections can't do an interactive password prompt.

As of 2026-08-28 there is a real gap between the end of H121 and the
start of H139's rolling window (Dec 2021 - Jun 2026) that neither
product covers on this server. See projects/ascat_da/report/ for the
investigation.

Examples:
  # Test one H121 month from Metop-A.
  download_hsaf_ascat.sh -u USER -d /data/H121 -p h121 -s metop_a -y 2020 -m 01 --dry-run

  # Resume/synchronize the complete H121 NetCDF archive.
  download_hsaf_ascat.sh -u USER -d /data/H121 -p h121

  # Pull whatever H139 currently has for Metop-B in August 2026.
  download_hsaf_ascat.sh -u USER -d /data/H139 -p h139 -s metop_b -y 2026 -m 08
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

USER_NAME=""
DEST=""

while (($#)); do
    case "$1" in
        -u|--user) USER_NAME=${2:-}; shift 2 ;;
        -d|--dest) DEST=${2:-}; shift 2 ;;
        -p|--product) PRODUCT=${2:-}; shift 2 ;;
        -s|--satellite) SATELLITE=${2:-}; shift 2 ;;
        -y|--year) YEAR=${2:-}; shift 2 ;;
        -m|--month) MONTH=${2:-}; shift 2 ;;
        -j|--parallel) PARALLEL=${2:-}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$USER_NAME" ]] || die "--user is required"
[[ -n "$DEST" ]] || die "--dest is required"
command -v lftp >/dev/null 2>&1 || die "lftp is not installed (macOS: brew install lftp)"
command -v curl >/dev/null 2>&1 || die "curl is not installed"

PRODUCT=$(printf '%s' "$PRODUCT" | tr '[:upper:]' '[:lower:]')
FORMAT=$(printf '%s' "$FORMAT" | tr '[:upper:]' '[:lower:]')
SATELLITE=$(printf '%s' "$SATELLITE" | tr '[:upper:]' '[:lower:]')

case "$PRODUCT" in
    h121|h139) ;;
    *) die "--product must be h121 or h139" ;;
esac

case "$SATELLITE" in
    all|metop_a|metop_b|metop_c) ;;
    *) die "--satellite must be metop_a, metop_b, metop_c, or all" ;;
esac

[[ -z "$YEAR" || "$YEAR" =~ ^[0-9]{4}$ ]] || die "--year must be YYYY"
[[ -z "$MONTH" || "$MONTH" =~ ^(0[1-9]|1[0-2])$ ]] || die "--month must be MM (01-12)"
[[ -z "$MONTH" || -n "$YEAR" ]] || die "--month requires --year"
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || die "--parallel must be a positive integer"
[[ "$USER_NAME" != *$'\n'* && "$USER_NAME" != *$'\r'* ]] || die "invalid username"
[[ "$DEST" != *$'\n'* && "$DEST" != *$'\r'* ]] || die "invalid destination"

mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd -P)

if [[ "$SATELLITE" == "all" ]]; then
    SATELLITES=(metop_a metop_b metop_c)
else
    SATELLITES=("$SATELLITE")
fi

if [[ "$PRODUCT" == "h121" ]]; then
    # Escape the only characters significant inside an lftp double-quoted string.
    LFTP_DEST=${DEST//\\/\\\\}
    LFTP_DEST=${LFTP_DEST//\"/\\\"}

    LFTP_COMMANDS="set cmd:fail-exit yes; set ftp:passive-mode yes; lcd \"$LFTP_DEST\"; cd /$PRODUCT/$FORMAT;"
    for sat in "${SATELLITES[@]}"; do
        remote_path=$sat
        [[ -z "$YEAR" ]] || remote_path+="/$YEAR"
        [[ -z "$MONTH" ]] || remote_path+="/$MONTH"

        mirror_opts="--continue --only-newer --parallel=$PARALLEL"
        ((DRY_RUN == 0)) || mirror_opts+=" --dry-run"
        LFTP_COMMANDS+=" mirror $mirror_opts $remote_path $remote_path;"
    done
    LFTP_COMMANDS+=" bye"

    printf 'Server:      ftp://%s\n' "$HOST"
    printf 'Remote root: /%s/%s\n' "$PRODUCT" "$FORMAT"
    printf 'Local root:  %s\n' "$DEST"
    printf 'Selection:   %s%s%s\n' "$SATELLITE" "${YEAR:+/$YEAR}" "${MONTH:+/$MONTH}"
    ((DRY_RUN == 0)) || printf 'Mode:        dry run\n'
    printf '\nlftp will prompt for the H SAF password if ~/.netrc has no entry for %s.\n\n' "$HOST"

    lftp -u "$USER_NAME" "ftp://$HOST" -e "$LFTP_COMMANDS"
    exit 0
fi

# h139: flat rolling-window directory, no per-satellite/year/month server structure.
# lftp's own get/mirror hang or 550 on this product's filenames (embedded commas),
# so list with lftp (fast, works fine) and fetch each file individually with curl.
grep -q "machine $HOST" ~/.netrc 2>/dev/null || die "h139 needs a ~/.netrc entry for machine $HOST (curl can't prompt per-file)"

H139_REMOTE_DIR="/h139/h139_cur_mon_data"
YEAR_PART=${YEAR:-'[0-9]{4}'}
MONTH_PART=${MONTH:-'[0-9]{2}'}

printf 'Server:      ftp://%s\n' "$HOST"
printf 'Remote root: %s (flat, rolling ~2-month window)\n' "$H139_REMOTE_DIR"
printf 'Local root:  %s\n' "$DEST"
printf 'Selection:   %s%s%s\n' "$SATELLITE" "${YEAR:+/$YEAR}" "${MONTH:+/$MONTH}"
((DRY_RUN == 0)) || printf 'Mode:        dry run\n'
printf '\n'

LISTING=$(lftp -u "$USER_NAME" "ftp://$HOST" -e "set ftp:passive-mode yes; set cmd:fail-exit yes; cd $H139_REMOTE_DIR; cls -1; bye" 2>&1) \
    || die "failed to list $H139_REMOTE_DIR"

for sat in "${SATELLITES[@]}"; do
    sat_tag=$(printf '%s' "$sat" | tr '[:lower:]' '[:upper:]' | tr -d '_')
    pattern="ASCAT-${sat_tag}-12\.5km-H139_C_LIIB_[0-9]{14}_${YEAR_PART}${MONTH_PART}[0-9]{8}_[0-9]{14}____\.nc\$"
    matches=$(printf '%s\n' "$LISTING" | grep -E "$pattern" || true)

    if [[ -z "$matches" ]]; then
        printf '%s: 0 files match in the current rolling window\n' "$sat"
        continue
    fi

    out_dir="$DEST/$sat"
    mkdir -p "$out_dir"
    count=$(printf '%s\n' "$matches" | wc -l)
    printf '%s: %d files\n' "$sat" "$count"

    while IFS= read -r fname; do
        [[ -n "$fname" ]] || continue
        out_path="$out_dir/$fname"
        if ((DRY_RUN)); then
            printf '  would fetch %s\n' "$fname"
            continue
        fi
        if [[ -s "$out_path" ]]; then
            printf '  skip (exists) %s\n' "$fname"
            continue
        fi
        printf '  fetching %s\n' "$fname"
        curl -sS -n --ftp-pasv -o "$out_path" "ftp://$HOST$H139_REMOTE_DIR/$fname" \
            || { rm -f "$out_path"; die "download failed: $fname"; }
    done <<< "$matches"
done
