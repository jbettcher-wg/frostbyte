# Shared helpers for build.sh and scripts/stage-*.sh. POSIX-ish bash; runs on Linux, modern macOS
# and Mac OS X 10.5 (bash 3.2), so no associative arrays, no mapfile, no ${var,,}.
#
# Layout (every path can be overridden from the environment):
#   FB_ROOT         this checkout
#   FROSTBYTE_CACHE downloads, toolchains and the imported SDK, shared by every checkout
#                   (default ~/.cache/frostbyte)
#   LEOPARD_BUILD   build outputs for this checkout (default $FB_ROOT/build)
#   LEOPARD_DL      verified source archives ($FROSTBYTE_CACHE/dl/<category>/<file>)

FB_ROOT="${FB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FROSTBYTE_CACHE="${FROSTBYTE_CACHE:-$HOME/.cache/frostbyte}"
LEOPARD_BUILD="${LEOPARD_BUILD:-$FB_ROOT/build}"
LEOPARD_DL="${LEOPARD_DL:-$FROSTBYTE_CACHE/dl}"
export FB_ROOT FROSTBYTE_CACHE LEOPARD_BUILD LEOPARD_DL

FB_TARGET_TRIPLE=powerpc-apple-darwin9
FB_LOCK="$FB_ROOT/config/sources.lock"
FB_TOOLCHAIN_LOCK="$FB_ROOT/config/toolchain.lock"

# ---- messages ---------------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _b=$(printf '\033[1m'); _r=$(printf '\033[31m'); _y=$(printf '\033[33m'); _g=$(printf '\033[32m'); _n=$(printf '\033[0m')
else
    _b=; _r=; _y=; _g=; _n=
fi
# Messages go to stderr, so a function whose stdout is captured ($(...)) can still talk.
say()   { printf '%s==>%s %s\n' "$_b" "$_n" "$*" >&2; }
note()  { printf '    %s\n' "$*" >&2; }
ok()    { printf '    %sok%s %s\n' "$_g" "$_n" "$*" >&2; }
warn()  { printf '%swarning:%s %s\n' "$_y" "$_n" "$*" >&2; }
die()   { printf '%serror:%s %s\n' "$_r" "$_n" "$*" >&2; exit 1; }
# run CMD...: print it; with FB_DRY_RUN=1 only print it.
run() {
    printf '    $ %s\n' "$*" >&2
    [ "${FB_DRY_RUN:-0}" = 1 ] && return 0
    "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---- host facts ---------------------------------------------------------------------------------
host_os()   { uname -s; }
host_ncpu() {
    if have nproc; then nproc
    elif sysctl -n hw.ncpu >/dev/null 2>&1; then sysctl -n hw.ncpu
    else echo 2; fi
}
# Physical memory in whole GiB.
host_mem_gib() {
    local b
    if [ -r /proc/meminfo ]; then
        b=$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo)
    else
        b=$(sysctl -n hw.memsize 2>/dev/null || echo 4294967296)
    fi
    awk -v b="$b" 'BEGIN { printf "%d\n", b / 1073741824 }'
}

# ---- hashing (sha256sum on Linux, shasum on macOS, python3 everywhere incl. 10.5 + MacPorts) -----
sha256_file() {
    if have sha256sum; then sha256sum "$1" | awk '{print $1}'
    elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
    else "$(fb_python)" -I -c 'import hashlib,sys
h=hashlib.sha256()
with open(sys.argv[1],"rb") as f:
    for b in iter(lambda: f.read(1<<20), b""): h.update(b)
print(h.hexdigest())' "$1"
    fi
}

# A Python 3 interpreter (MacPorts names it python3.13 etc. on 10.5).
fb_python() {
    if [ -n "${FB_PYTHON:-}" ]; then echo "$FB_PYTHON"; return; fi
    local p
    for p in python3 python3.13 python3.12 python3.11 python3.10 python3.9; do
        if have "$p" && "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
            command -v "$p"; return
        fi
    done
    echo python3
}

# ---- the source lock -----------------------------------------------------------------------------
# config/sources.lock lines: <category> <file> <sha256> <url> [<url>...]
# Prints matching lines for the given categories (all when none given).
lock_entries() {
    awk -v cats=" $* " '
        /^[[:space:]]*(#|$)/ { next }
        { if (cats == "  " || index(cats, " " $1 " ")) print }' "$FB_LOCK"
}
# lock_field <file> <field#>: one field of the entry for a file name.
lock_field() { awk -v f="$1" -v n="$2" '$1 !~ /^#/ && $2 == f { print $n; exit }' "$FB_LOCK"; }
# The local path of a locked file (after fetch).
dl_path() {
    local cat; cat=$(lock_field "$1" 1)
    [ -n "$cat" ] || die "no entry for $1 in config/sources.lock"
    echo "$LEOPARD_DL/$cat/$1"
}

# fetch_entry <category> <file> <sha256> <url>...: download into $LEOPARD_DL/<category>/<file> and
# verify. A verified file is kept and never fetched again. FB_MIRROR=<base> is tried first as
# <base>/<category>/<file>; FB_DL_SEED=<dir>[:<dir>] is searched for an already-downloaded copy.
fetch_entry() {
    local cat="$1" file="$2" sum="$3"; shift 3
    local dest="$LEOPARD_DL/$cat/$file" got u d
    mkdir -p "$LEOPARD_DL/$cat"
    if [ -f "$dest" ]; then
        got=$(sha256_file "$dest")
        if [ "$got" = "$sum" ]; then ok "$file (cached)"; return 0; fi
        warn "$file: cached copy has the wrong checksum ($got); fetching again"
        rm -f "$dest"
    fi
    if [ -n "${FB_DL_SEED:-}" ]; then
        local IFS_save="$IFS"; IFS=:
        for d in $FB_DL_SEED; do
            IFS="$IFS_save"
            for u in "$d/$file" "$d/$cat/$file"; do
                if [ -f "$u" ] && [ "$(sha256_file "$u")" = "$sum" ]; then
                    cp "$u" "$dest"; ok "$file (seeded from $u)"; return 0
                fi
            done
        done
        IFS="$IFS_save"
    fi
    [ "${FB_OFFLINE:-0}" = 1 ] && die "$file is not in the cache and FB_OFFLINE=1"
    set -- ${FB_MIRROR:+"$FB_MIRROR/$cat/$file"} "$@"
    for u in "$@"; do
        note "fetch $u"
        if fb_download "$u" "$dest.part"; then
            got=$(sha256_file "$dest.part")
            if [ "$got" = "$sum" ]; then
                mv "$dest.part" "$dest"; ok "$file"; return 0
            fi
            warn "$file from $u: checksum $got, expected $sum"
        fi
        rm -f "$dest.part"
    done
    die "could not fetch a verified $file (tried: $*)"
}

fb_download() { # <url> <out>
    if have curl; then curl -fL -sS --retry 3 --connect-timeout 30 -o "$2" "$1"
    elif have wget; then wget -O "$2" "$1"
    else die "need curl or wget to download sources"; fi
}

# fetch_file <file>: fetch one locked file by name.
fetch_file() {
    local line
    line=$(awk -v f="$1" '$1 !~ /^#/ && $2 == f' "$FB_LOCK")
    [ -n "$line" ] || die "no entry for $1 in config/sources.lock"
    # shellcheck disable=SC2086
    fetch_entry $line
}

# ---- memory-capped execution -------------------------------------------------------------------
# WebKit's unified sources need 2-4 GiB per compile job, so the job count follows memory, not cores.
# FB_JOBS overrides; the default is min(cores, MemoryHigh / 3 GiB, 30). On Linux with systemd the
# command also runs in a user scope with MemoryHigh/MemoryMax and no swap, so a build that outgrows
# memory is throttled, then stopped, instead of taking the desktop down (FB_MEM_HIGH/FB_MEM_MAX
# override, e.g. 72G/80G; FB_NO_SCOPE=1 turns the scope off).
fb_mem_high_gib() { [ -n "${FB_MEM_HIGH:-}" ] && { echo "${FB_MEM_HIGH%G}"; return; }; awk -v m="$(host_mem_gib)" 'BEGIN { printf "%d\n", m * 0.576 }'; }
fb_mem_max_gib()  { [ -n "${FB_MEM_MAX:-}" ]  && { echo "${FB_MEM_MAX%G}";  return; }; awk -v m="$(host_mem_gib)" 'BEGIN { printf "%d\n", m * 0.64 }'; }
fb_jobs() {
    [ -n "${FB_JOBS:-}" ] && { echo "$FB_JOBS"; return; }
    local c m j
    c=$(host_ncpu); m=$(fb_mem_high_gib)
    j=$((m / 3)); [ "$j" -lt 1 ] && j=1
    [ "$j" -gt "$c" ] && j=$c
    [ "$j" -gt 30 ] && j=30
    echo "$j"
}
# capped CMD...: run CMD inside the memory cap where the host supports one.
capped() {
    if [ "$(host_os)" = Linux ] && [ "${FB_NO_SCOPE:-0}" != 1 ] && have systemd-run \
        && systemctl --user show-environment >/dev/null 2>&1; then
        run systemd-run --user --scope --quiet -p "MemoryHigh=$(fb_mem_high_gib)G" \
            -p "MemoryMax=$(fb_mem_max_gib)G" -p MemorySwapMax=0 "$@"
    else
        run "$@"
    fi
}

# ---- state files --------------------------------------------------------------------------------
# $LEOPARD_BUILD/toolchain.env records the toolchain and SDK chosen by the toolchain/sdk stages;
# toolchain/wpe-env.sh reads it.
state_set() { # <key> <value>
    local f="$LEOPARD_BUILD/toolchain.env"
    mkdir -p "$LEOPARD_BUILD"; touch "$f"
    grep -v "^$1=" "$f" > "$f.tmp" || true
    printf '%s=%s\n' "$1" "$(printf '%q' "$2")" >> "$f.tmp"
    mv "$f.tmp" "$f"
}
state_get() { # <key>
    local f="$LEOPARD_BUILD/toolchain.env"
    [ -f "$f" ] || return 0
    ( . "$f"; eval "printf '%s' \"\${$1:-}\"" )
}
