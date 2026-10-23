#!/usr/bin/env bash
#
# download_h139_icdr.sh -- download H SAF H139 ASCAT soil moisture (ICDR,
# 12.5 km, Metop-B/C) from the H SAF FTP server's rolling window.
#
# BACKGROUND
#   H139 is the near-real-time continuation of the H121 ASCAT SSM CDR (H121
#   ends 2024-12-31). The FTP server keeps only a rolling window of about
#   the last 2 months in one flat folder:
#       ftp://ftphsaf.meteoam.it/h139/h139_cur_mon_data/
#   Files older than the window are removed from the server, so to build a
#   continuous archive this script must be run regularly (e.g. weekly; at
#   least every few weeks). Data that has already left the window can only
#   be obtained by placing an order on the H SAF portal.
#
#   Files are hourly granules, one per satellite per hour, ~2-3 MB each
#   (~50 MB/day/satellite). Name pattern:
#     W_IT-HSAF-ROME,SAT,SSM-ASCAT-METOP<B|C>-12.5km-H139_C_LIIB_<proc>_<obs_start>_<obs_end>____.nc
#   where each timestamp is YYYYMMDDhhmmss and <proc> is the processing time.
#   The observation start (2nd timestamp) decides where a file is stored.
#
# OUTPUT LAYOUT (same as the local H121 archive; GEOSldas expects this)
#   <dest>/metop_b/Y<yyyy>/M<mm>/<file>.nc
#   <dest>/metop_c/Y<yyyy>/M<mm>/<file>.nc
#
# BEHAVIOR
#   - Lists the server folder (with file sizes), selects files by satellite
#     and observation-start date, and downloads each with curl.
#   - Safe to re-run: files already on disk with the server's size are
#     skipped. Downloads go to <file>.part and are renamed only after the
#     size matches the listing and the file starts with a netCDF/HDF5
#     signature, so an interrupted run never leaves a truncated .nc file.
#   - Retries refused/dropped connections and resumes partial files (the
#     server refuses or drops connections fairly often). Files that still
#     fail get a second attempt at the end of the run.
#   - Prints one line per file as it finishes (OK / FAILED), then a
#     per-day count of files on disk.
#   - Only one copy can run per <dest> at a time (lock file).
#   - Uses curl, not lftp: lftp's get/mirror hang or fail with 550 on these
#     filenames because they contain commas.
#
# CREDENTIALS
#   Read only from ~/.netrc (chmod 600), never from the command line:
#     machine ftphsaf.meteoam.it login <user> password <password>
#
# SERVER LIMITS
#   Keep parallel connections at 8 or fewer. Many more simultaneous
#   connections has previously led the server to reject the account's
#   connections. The script refuses -j above 8.
#
# USAGE
#   download_h139_icdr.sh -d DEST [options]
#
#   -d, --dest DIR        Local archive root (required)
#   -s, --start YYYYMMDD  First observation date to fetch (default: oldest on server)
#   -e, --end YYYYMMDD    Last observation date to fetch (default: newest on server)
#   -S, --sat b|c|bc      Satellites (default: bc)
#   -j, --jobs N          Parallel downloads, 1-8 (default: 4)
#   -n, --dry-run         List what would be downloaded, download nothing
#   -h, --help            Show this help
#
#   Example (weekly run, fetch everything in the window that is missing):
#     download_h139_icdr.sh -d /path/to/H139
#
# EXIT STATUS
#   0  all selected files are on disk and complete
#   1  some downloads failed (re-run to retry; see the FAILED lines)
#   2  usage or configuration error (bad option, no ~/.netrc entry)
#   3  could not list the server folder, or another run holds the lock
#
# REQUIREMENTS
#   bash 4+, curl, flock, GNU coreutils/findutils/awk.

set -uo pipefail
set -x
HOST=ftphsaf.meteoam.it
REMOTE_DIR=/h139/h139_cur_mon_data
MAX_JOBS=8
NAME_RE='^W_IT-HSAF-ROME,SAT,SSM-ASCAT-METOP[BC]-12[.]5km-H139_C_LIIB_[0-9]{14}_[0-9]{14}_[0-9]{14}____[.]nc$'

dest=""; start=""; end=""; sats=bc; jobs=4; dry_run=0

usage() { sed -n '/^# USAGE/,/^# EXIT STATUS/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
log()   { echo "[$(date '+%F %T')] $*"; }
die()   { echo "ERROR: $2" >&2; exit "$1"; }

while (($#)); do
  case "$1" in
    -d|--dest)    dest=${2:-};  shift 2 ;;
    -s|--start)   start=${2:-}; shift 2 ;;
    -e|--end)     end=${2:-};   shift 2 ;;
    -S|--sat)     sats=${2:-};  shift 2 ;;
    -j|--jobs)    jobs=${2:-};  shift 2 ;;
    -n|--dry-run) dry_run=1;    shift ;;
    -h|--help)    usage; exit 0 ;;
    *) usage >&2; die 2 "unknown option: $1" ;;
  esac
done

[[ -n "$dest" ]]                       || die 2 "--dest is required (see --help)"
[[ -z "$start" || "$start" =~ ^[0-9]{8}$ ]] || die 2 "--start must be YYYYMMDD"
[[ -z "$end"   || "$end"   =~ ^[0-9]{8}$ ]] || die 2 "--end must be YYYYMMDD"
[[ -z "$start" || -z "$end" || "$start" -le "$end" ]] || die 2 "--start is after --end"
[[ "$sats" =~ ^(b|c|bc|cb)$ ]]         || die 2 "--sat must be b, c or bc"
[[ "$jobs" =~ ^[0-9]+$ ]] && ((jobs >= 1 && jobs <= MAX_JOBS)) \
                                       || die 2 "--jobs must be 1-$MAX_JOBS (server connection limit)"
command -v curl  >/dev/null            || die 2 "curl not found"
command -v flock >/dev/null            || die 2 "flock not found"

netrc=${NETRC:-$HOME/.netrc}
grep -qE "machine[[:space:]]+$HOST([[:space:]]|$)" "$netrc" 2>/dev/null \
  || die 2 "no '$HOST' entry in $netrc (see CREDENTIALS in --help)"
[[ "$(stat -c %a "$netrc")" == 600 ]] || log "WARNING: $netrc should be chmod 600"

mkdir -p "$dest" || die 2 "cannot create $dest"
dest=$(cd "$dest" && pwd -P)

# One run per archive at a time (e.g. a slow run overlapping the next scheduled one).
exec 9>"$dest/.download_h139_icdr.lock"
flock -n 9 || die 3 "another download is already running into $dest"

# --retry-all-errors: the server also drops connections mid-transfer (curl
# error 56), which plain --retry does not cover. --continue-at - makes each
# retry resume the partial file instead of starting over.
curl_opts=(--silent --show-error --netrc --ftp-pasv --continue-at -
           --retry 5 --retry-all-errors --retry-delay 30
           --connect-timeout 60 --speed-limit 1000 --speed-time 300)

# ---- 1. List the server folder (name + size) -------------------------------
log "Listing ftp://$HOST$REMOTE_DIR/"
listing=$(curl "${curl_opts[@]}" "ftp://$HOST$REMOTE_DIR/") \
  || die 3 "could not list ftp://$HOST$REMOTE_DIR/"

# Columns of the FTP LIST output: perms links owner group SIZE mon day time NAME.
# Output: size <TAB> relative path <TAB> name, for selected files only.
todo_all=$(printf '%s\n' "$listing" | awk -v re="$NAME_RE" -v sats="$sats" \
                                          -v d0="${start:-00000000}" -v d1="${end:-99999999}" '
  NF >= 9 {
    name = $NF; size = $5
    if (name !~ re) { if (name ~ /\.nc$/) unknown++; next }
    sat = (name ~ /-METOPB-/) ? "b" : "c"
    split(name, t, /_/); obs = t[6]                              # obs start time
    day = substr(obs, 1, 8)
    if (index(sats, sat) == 0 || day < d0 || day > d1) next
    key = sat obs
    if (key in seen) dup++
    seen[key] = 1
    printf "%s\t%s\t%s\n", size, "metop_" sat "/Y" substr(obs,1,4) "/M" substr(obs,5,2) "/" name, name
  }
  END {
    if (unknown) printf "WARNING: %d .nc files with an unexpected name were ignored\n", unknown > "/dev/stderr"
    if (dup)     printf "WARNING: %d hours appear more than once (reprocessed?); all copies are kept\n", dup > "/dev/stderr"
  }')

n_sel=$(printf '%s' "$todo_all" | grep -c .)
range=$(printf '%s\n' "$todo_all" | awk -F'\t' 'NF{split($3,t,"_"); d=substr(t[6],1,8); if(!a||d<a)a=d; if(d>b)b=d} END{if(a) print a" to "b}')
log "Selected $n_sel files (sat: $sats, observation dates: ${range:-none})"
((n_sel > 0)) || { log "Nothing to do"; exit 0; }

# ---- 2. Drop files already complete on disk ---------------------------------
# stdin/stdout: size<TAB>relpath<TAB>name lines; keeps those not complete on disk.
still_missing() {
  while IFS=$'\t' read -r size rel name; do
    [[ -n "$rel" ]] || continue
    [[ "$(stat -c %s "$dest/$rel" 2>/dev/null)" == "$size" ]] || printf '%s\t%s\t%s\n' "$size" "$rel" "$name"
  done
}
todo=$(printf '%s\n' "$todo_all" | still_missing)
n_todo=$(printf '%s' "$todo" | grep -c .)
log "$((n_sel - n_todo)) already on disk, $n_todo to download ($jobs parallel)"

if ((dry_run)); then
  printf '%s\n' "$todo" | awk -F'\t' 'NF{print "  would fetch " $2; s+=$1} END{printf "  total %.1f MB\n", s/1e6}'
  exit 0
fi

# ---- 3. Download -------------------------------------------------------------
fetch_one() {   # args: size relpath name
  local size=$1 rel=$2 name=$3
  local out="$DEST/$rel" part="$DEST/$rel.part" got magic
  mkdir -p "${out%/*}" || { echo "FAILED $rel (mkdir)"; return 1; }
  if curl "${CURL_OPTS[@]}" -o "$part" "$URL/$name" 2>"$part.err"; then
    got=$(stat -c %s "$part")
    magic=$(head -c 4 "$part" | od -An -tx1 | tr -d ' \n')
    if [[ "$got" != "$size" ]]; then
      echo "FAILED $rel (size $got, expected $size)"
    elif [[ "$magic" != 89484446 && "$magic" != 434446* ]]; then   # \x89HDF or CDF
      echo "FAILED $rel (not a netCDF file)"
    else
      mv -f "$part" "$out" && rm -f "$part.err" && { echo "OK $rel"; return 0; }
      echo "FAILED $rel (rename)"
    fi
  else
    echo "FAILED $rel ($(tail -1 "$part.err"))"
    rm -f "$part.err"     # keep the partial .part: the next attempt resumes it
    return 1
  fi
  rm -f "$part" "$part.err"
  return 1
}
export -f fetch_one
export DEST=$dest URL="ftp://$HOST$REMOTE_DIR"
# Arrays can't be exported; pass curl options through a declared string.
export CURL_OPTS_DECL; CURL_OPTS_DECL=$(declare -p curl_opts | sed 's/curl_opts=/CURL_OPTS=/')

resfile=$(mktemp -p /tmp tmp.$$.XXXXXX) || die 2 "mktemp failed"
trap 'rm -f "$resfile"' EXIT
for pass in 1 2; do
  if ((pass == 2)); then
    todo=$(printf '%s\n' "$todo_all" | still_missing)
    n_todo=$(printf '%s' "$todo" | grep -c .)
    ((n_todo > 0)) || break
    log "Second attempt for $n_todo failed files"
  fi
  printf '%s\n' "$todo" | grep . | tr '\t' ' ' |
    xargs -P "$jobs" -L 1 bash -c 'eval "$CURL_OPTS_DECL"; fetch_one "$@"' _ |
    tee -a "$resfile"
done
n_ok=$(grep -c '^OK ' "$resfile")
n_fail=$(printf '%s\n' "$todo_all" | still_missing | grep -c .)

# ---- 4. Summary ---------------------------------------------------------------
# Files on disk per satellite per observation day, for the selected days.
log "Files on disk per day (selected days; a full day is 24):"
printf '%s\n' "$todo_all" | while IFS=$'\t' read -r size rel name; do
    [[ -n "$rel" && "$(stat -c %s "$dest/$rel" 2>/dev/null)" == "$size" ]] || continue
    IFS=_ read -ra t <<< "$name"; obs=${t[5]}      # obs start time
    echo "${rel%%/*} ${obs:0:8}"
  done | sort | uniq -c | awk '{printf "  %s %s %3d\n", $2, $3, $1}'

if ((n_fail > 0)); then
  log "Done with errors: $n_ok downloaded, $n_fail still missing after 2 attempts (re-run to retry)"
  exit 1
fi
log "Done: $n_ok downloaded, all $n_sel selected files complete in $dest"
