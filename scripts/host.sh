# Host detection. Sourced by build.sh after scripts/lib.sh.
#
# Sets:
#   FB_HOST_MODE  cross | native
#   FB_HOST_TAG   linux-x86_64 | linux-aarch64 | macos-x86_64 | macos-arm64 | darwin9-ppc64
#                 (names the prebuilt toolchain tarball for this host)
#   FB_HOST_DESC  one line for humans
# and refuses hosts that cannot build FrostByte, saying why.

fb_detect_host() {
    local s m r major
    s=$(uname -s); m=$(uname -m); r=$(uname -r); major=${r%%.*}
    case "$s" in
    Linux)
        case "$m" in
        x86_64|amd64)  FB_HOST_TAG=linux-x86_64 ;;
        aarch64|arm64) FB_HOST_TAG=linux-aarch64 ;;
        *) die "Linux on $m is not a supported build host (supported: x86_64 and arm64 Linux, macOS, and Mac OS X 10.5 on a 64-bit PowerPC)." ;;
        esac
        FB_HOST_MODE=cross
        FB_HOST_DESC="Linux $m: cross-build"
        ;;
    Darwin)
        if [ "$major" -ge 10 ] 2>/dev/null; then
            # Mac OS X 10.6 and later: a modern macOS host cross-builds. 10.6-10.12 are untested and
            # their toolchains are too old for GCC 15 anyway; say so instead of failing later.
            if [ "$major" -lt 17 ]; then
                warn "Darwin $r (macOS older than 10.13) is untested as a build host; macOS 11 or later is expected."
            fi
            case "$m" in
            x86_64) FB_HOST_TAG=macos-x86_64 ;;
            arm64)  FB_HOST_TAG=macos-arm64 ;;
            *) die "macOS on $m is not a supported build host." ;;
            esac
            FB_HOST_MODE=cross
            FB_HOST_DESC="macOS $(sw_vers -productVersion 2>/dev/null || echo "(Darwin $r)") on $m: cross-build"
        elif [ "$major" = 9 ]; then
            # Mac OS X 10.5. uname -m is "Power Macintosh" on PowerPC, "i386" on Intel.
            case "$m" in
            "Power Macintosh"|ppc|ppc64|powerpc) ;;
            *) die "Mac OS X 10.5 on Intel is not a supported build host. Build on Linux or a current macOS instead (FrostByte is a PowerPC program)." ;;
            esac
            if [ "$(sysctl -n hw.cpu64bit_capable 2>/dev/null)" != 1 ]; then
                die "This Mac has a 32-bit PowerPC processor (a G3 or G4). FrostByte is a 64-bit program: it builds and runs only on a 64-bit PowerPC (a Power Mac G5, or a 64-bit Book-E system such as the NXP T4240). Build it on Linux or a current macOS instead, or on a G5."
            fi
            FB_HOST_TAG=darwin9-ppc64
            FB_HOST_MODE=native
            FB_HOST_DESC="Mac OS X $(sw_vers -productVersion 2>/dev/null || echo 10.5) on 64-bit PowerPC ($(sysctl -n hw.ncpu) CPUs, $(host_mem_gib) GiB): native build"
        else
            die "Darwin $r (Mac OS X 10.4 or older) cannot build FrostByte: it needs Mac OS X 10.5 on a 64-bit PowerPC, a current macOS, or Linux."
        fi
        ;;
    *)
        die "$s is not a supported build host (supported: Linux x86_64/arm64, macOS, Mac OS X 10.5 on a 64-bit PowerPC)."
        ;;
    esac
    export FB_HOST_MODE FB_HOST_TAG FB_HOST_DESC
}
