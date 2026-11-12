#!/usr/bin/env bash
# Stage "check": detect the host and make sure the tools the build runs are there, with install
# hints for this kind of host. Exits non-zero if something required is missing.
#   scripts/stage-check.sh [--toolchain-source] [--sdk-dmg]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/host.sh"
fb_detect_host

need_tc_src=0; need_dmg=0
for a in "$@"; do
    case "$a" in --toolchain-source) need_tc_src=1 ;; --sdk-dmg) need_dmg=1 ;; esac
done

say "host: $FB_HOST_DESC"
missing=()
check() { # <what> <test command...>
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$what"; else printf '    %smissing%s %s\n' "$_r" "$_n" "$what" >&2; missing+=("$what"); fi
}
ver_ge() { # <have> <want>: dotted versions
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}
PY=$(fb_python)
check "python3 >= 3.9 ($PY)"        "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'
check "perl >= 5.10 with JSON::PP"  perl -MJSON::PP -e 'exit($] >= 5.010 ? 0 : 1)'
check "ruby >= 2.5"                 ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.5") ? 0 : 1)'
check "cmake >= 3.20"               bash -c 'v=$(cmake --version | head -1 | awk "{print \$3}"); [ "$(printf "%s\n3.20\n" "$v" | sort -t. -k1,1n -k2,2n | head -1)" = 3.20 ]'
check "ninja"                       ninja --version
check "pkg-config"                  pkg-config --version
check "make"                        make --version
check "patch"                       patch --version
check "rsync"                       rsync --version
check "xz"                          xz --version
check "bzip2"                       bash -c 'command -v bzip2'
check "curl or wget"                bash -c 'command -v curl || command -v wget'
check "a host C/C++ compiler"       bash -c 'command -v cc && command -v c++'
check "update-mime-database (shared-mime-info)" bash -c 'command -v update-mime-database'
check "freedesktop.org.xml (shared-mime-info data)" bash -c '[ -f "${MIME_XML:-/usr/share/mime/packages/freedesktop.org.xml}" ] || [ -f /opt/homebrew/share/mime/packages/freedesktop.org.xml ] || [ -f /usr/local/share/mime/packages/freedesktop.org.xml ] || [ -f /opt/local/share/mime/packages/freedesktop.org.xml ]'
check "libffi, pcre2, zlib development files (host GLib tools)" pkg-config --exists libffi libpcre2-8 zlib
check "llvm-objdump (bundle check's instruction scan)" bash -c 'command -v llvm-objdump'
if [ "$need_tc_src" = 1 ]; then
    check "autoconf, automake, libtool (cctools)" bash -c 'command -v autoconf && command -v automake && (command -v libtoolize || command -v glibtoolize)'
    check "m4"                      m4 --version
fi
if [ "$need_dmg" = 1 ] && [ "$FB_HOST_MODE" = cross ] && [ "$(host_os)" = Linux ]; then
    check "7z (to open the Xcode .dmg)" bash -c 'command -v 7z || command -v 7zz'
    check "cpio"                    cpio --version
fi

mem=$(host_mem_gib)
note "memory: ${mem} GiB -> $(fb_jobs) parallel WebKit compile jobs (FB_JOBS overrides)"
[ "$mem" -lt 8 ] && warn "WebKit needs 2-4 GiB per compile job; with ${mem} GiB the build will be slow or fail."
free_gib=$(df -Pk "$FB_ROOT" | awk 'NR==2 {printf "%d", $4 / 1048576}')
note "free disk at $FB_ROOT: ${free_gib} GiB (a target needs about 10 GiB; add 6 GiB to build the toolchain)"
[ "$free_gib" -lt 12 ] && warn "less than 12 GiB free"

if [ "${#missing[@]}" -gt 0 ]; then
    echo >&2
    echo "Install what is missing, then run ./build.sh again. For example:" >&2
    case "$FB_HOST_TAG" in
    linux-*)
        echo "  Debian/Ubuntu: sudo apt install python3 perl libjson-pp-perl ruby cmake ninja-build pkg-config make patch rsync xz-utils bzip2 curl build-essential shared-mime-info libffi-dev libpcre2-dev zlib1g-dev autoconf automake libtool m4 p7zip-full cpio llvm" >&2
        echo "  Fedora:        sudo dnf install python3 perl perl-JSON-PP ruby cmake ninja-build pkgconf make patch rsync xz bzip2 curl gcc gcc-c++ shared-mime-info libffi-devel pcre2-devel zlib-devel autoconf automake libtool m4 p7zip cpio llvm" >&2
        echo "  Arch:          sudo pacman -S python perl ruby cmake ninja pkgconf make patch rsync xz bzip2 curl base-devel shared-mime-info libffi pcre2 zlib 7zip cpio llvm" >&2 ;;
    macos-*)
        echo "  xcode-select --install; then with Homebrew:" >&2
        echo "  brew install python cmake ninja pkg-config ruby rsync xz shared-mime-info libffi pcre2 autoconf automake libtool llvm" >&2 ;;
    darwin9-*)
        echo "  MacPorts (https://www.macports.org; 10.5 PowerPC is supported by the legacy ports):" >&2
        echo "  sudo port install python313 perl5 ruby33 cmake ninja pkgconfig rsync xz bzip2 curl shared-mime-info libffi pcre2 zlib autoconf automake libtool llvm-17" >&2
        echo "  (and see docs/building.md, \"Building on a G5 or a T4240\")" >&2 ;;
    esac
    exit 1
fi
ok "all build tools present"
