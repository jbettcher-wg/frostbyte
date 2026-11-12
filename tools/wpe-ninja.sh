#!/usr/bin/env bash
# The ONLY way to run ninja on the WebKit build (build, install, -n, anything):
#   tools/wpe-ninja.sh [ninja args...]          e.g. tools/wpe-ninja.sh install
#   LEOPARD_TARGET=g5 tools/wpe-ninja.sh        that target's build directory (build/wpe-254-g5)
#
# WebCore/JavaScriptCore unified sources need 2-4 GB per compile job, so the job count follows
# memory, not cores: bare ninja on a 112-core, 125 GB host started ~114 jobs and was OOM-killed,
# taking the desktop session with it. Defaults (scripts/lib.sh): jobs = min(cores, 0.576 x RAM /
# 3 GB, 30); on Linux with systemd the run is also confined to a user scope with
# MemoryHigh = 0.576 x RAM, MemoryMax = 0.64 x RAM and no swap (72G/80G on a 125 GB host).
# Overrides: WPE_JOBS (or FB_JOBS), WPE_MEM_HIGH/WPE_MEM_MAX (or FB_MEM_HIGH/FB_MEM_MAX), e.g. when
# two builds share the host. A full rebuild at the default width can still hit the cap on the
# largest JSBindings units; use WPE_JOBS=24 or lower for those (it stops ninja, not the host).
S="$(cd "$(dirname "$0")/.." && pwd)"
. "$S/scripts/lib.sh"
. "$S/toolchain/wpe-env.sh" 2>/dev/null
export FB_JOBS="${WPE_JOBS:-${FB_JOBS:-}}" FB_MEM_HIGH="${WPE_MEM_HIGH:-${FB_MEM_HIGH:-}}" FB_MEM_MAX="${WPE_MEM_MAX:-${FB_MEM_MAX:-}}"
capped ninja -C "${WPE_BUILD_DIR:-$LEOPARD_BUILD/wpe-254$LEOPARD_SUFFIX}" -j "$(fb_jobs)" "$@"
