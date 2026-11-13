/*
 * FrostByte: hardware features, detected at startup and switched by preferences before WebKit starts.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include <dlfcn.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#include <IOKit/IOKitLib.h>
#include "frostbyte.h"

/* ---- hardware features: detected, then switched by preferences (and switchable off if bugs emerge) ----
 * User defaults: GraphicsAcceleration = Auto | On | Off (default Auto), ZeroCopyFrames (default YES),
 * JavaScriptJIT (default YES), CPURasterThreads (0 = automatic). They become the switches WebKit,
 * JavaScriptCore and LeopardEGL read (LEOPARD_WPE_GL, LEOPARD_WPE_ZEROCOPY, JSC_useJIT,
 * WEBKIT_CPU_RASTER_THREADS) before any WebKit process starts; the same variable already set in the
 * environment wins (debugging). Changes take effect at the next launch (Preferences > Hardware offers
 * a restart). HardwareVideoDecoding picks UVD H.264 decoding; PreferH264WithHardwareDecoding steers sites to it. */
#define FB_RADEONNI_COMPAT_RENDERER 0x00021a00

FBGraphicsCapabilities fbGraphics;
BOOL fbGPUActive, fbZeroCopyActive;
BOOL fbHardwareVideoActive;
static NSMutableArray *s_envWeSet;             /* variables set from preferences: dropped on restart */

/* UVD, the Radeon's video decoder: read-only IORegistry look at the RadeonNI framebuffer (nothing is
 * opened). Its driver carries the decoder firmware as FW_UVD and switches decode sessions on with
 * EnableUVDSessions. The decoder itself is GStreamer's rdnvdh264dec, which FROSTBYTE_UVD=0 switches off. */
static void detectVideoDecoder(FBGraphicsCapabilities *caps)
{
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("RadeonNI"), &iter) != KERN_SUCCESS)
        return;
    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        CFTypeRef firmware = IORegistryEntryCreateCFProperty(service, CFSTR("FW_UVD"), kCFAllocatorDefault, 0);
        if (firmware) {
            if (CFGetTypeID(firmware) == CFDataGetTypeID() && CFDataGetLength(firmware) > 0)
                caps->uvd = YES;
            CFRelease(firmware);
        }
        /* The card's own name ("AMD FirePro W8100"): the GL renderer string is the driver's, not the hardware's. */
        io_name_t plane;                       /* the API takes a full io_name_t, not the 10-byte literal */
        g_strlcpy(plane, kIOServicePlane, sizeof plane);
        CFTypeRef model = IORegistryEntrySearchCFProperty(service, plane, CFSTR("model"), kCFAllocatorDefault,
                                                          kIORegistryIterateRecursively | kIORegistryIterateParents);
        if (model) {
            if (CFGetTypeID(model) == CFDataGetTypeID() && !caps->renderer[0]) {
                CFIndex n = CFDataGetLength(model);
                if (n >= (CFIndex)sizeof caps->renderer)
                    n = sizeof caps->renderer - 1;
                memcpy(caps->renderer, CFDataGetBytePtr(model), (size_t)n);
                caps->renderer[n] = 0;
            } else if (CFGetTypeID(model) == CFStringGetTypeID() && !caps->renderer[0])
                CFStringGetCString(model, caps->renderer, sizeof caps->renderer, kCFStringEncodingUTF8);
            CFRelease(model);
        }
        CFTypeRef sessions = IORegistryEntryCreateCFProperty(service, CFSTR("EnableUVDSessions"), kCFAllocatorDefault, 0);
        if (sessions) {
            if (sessions == kCFBooleanTrue)
                caps->uvdSessions = caps->uvd;
            CFRelease(sessions);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
}

static FBGraphicsCapabilities detectGraphics(void)
{
    FBGraphicsCapabilities caps = { NO, NO, "", NO, NO, NO };
    CGLRendererInfoObj info = NULL;
    GLint count = 0;
    if (CGLQueryRendererInfo(0xffffffff, &info, &count) == kCGLNoError) {
        for (GLint i = 0; i < count; i++) {
            GLint id = 0, accelerated = 0;
            CGLDescribeRenderer(info, i, kCGLRPRendererID, &id);
            CGLDescribeRenderer(info, i, kCGLRPAccelerated, &accelerated);
            if ((id & ~0xff) == (FB_RADEONNI_COMPAT_RENDERER & ~0xff) && accelerated)
                caps.radeon = YES;
            if (accelerated)
                caps.accelerated = YES;
        }
        CGLDestroyRendererInfo(info);
    }
    detectVideoDecoder(&caps);
    if (!caps.radeon && !(FROSTBYTE_GL_ANY_ACCELERATED && caps.accelerated))
        return caps;
    CGLPixelFormatAttribute radeonAttributes[] = {
        kCGLPFARendererID, (CGLPixelFormatAttribute)FB_RADEONNI_COMPAT_RENDERER, kCGLPFAAccelerated, 0
    };
    CGLPixelFormatAttribute anyAttributes[] = { kCGLPFAAccelerated, 0 };
    CGLPixelFormatAttribute *attributes = caps.radeon ? radeonAttributes : anyAttributes;
    CGLPixelFormatObj format = NULL;
    GLint formats = 0;
    CGLContextObj probe = NULL;
    if (CGLChoosePixelFormat(attributes, &format, &formats) == kCGLNoError && format) {
        if (CGLCreateContext(format, NULL, &probe) == kCGLNoError && probe) {
            if (CGLSetCurrentContext(probe) == kCGLNoError) {
                const GLubyte *name = glGetString(GL_RENDERER);
                if (name && !caps.renderer[0])      /* the IORegistry model, when there is one, names the card better */
                    g_strlcpy(caps.renderer, (const char *)name, sizeof caps.renderer);
                CGLSetCurrentContext(NULL);
            }
            typedef uint32_t (*VersionFn)(void *);
            VersionFn version = (VersionFn)dlsym(RTLD_DEFAULT, "LeopardGPU_SharedBufferVersion");
            caps.sharedBuffers = version && version(probe) > 0;
            CGLDestroyContext(probe);
        }
        CGLDestroyPixelFormat(format);
    }
    return caps;
}

static void setenvFromPreference(const char *name, const char *value)
{
    setenv(name, value, 1);
    [s_envWeSet addObject:str(name)];
}

/* JavaScriptCore's bytecode cache (WebKit reads WEBKIT_JSC_BYTECODE_CACHE_DIR): a script compiled on one visit is
 * loaded instead of parsed on the next, which is most of a big site's start-up time on this CPU. Files are
 * <JSC build UUID>-<URL hash>-<source hash>.jsbc, so another build never reads them; a first sighting leaves
 * an empty .seen marker. WebKit replaces a file by rename and validates it (size, checksum) before use, so a
 * damaged entry is dropped and rebuilt on its own; Empty Cache is never needed for correctness. Otherwise WebKit
 * deletes nothing: the size cap is ours, applied at startup. Any future private-browsing window must not get this
 * variable. */
NSString *fbBytecodeCacheDirectory(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/org.frostbyte.FrostByte/JSCBytecode"];
}

static NSArray *cacheEntries(unsigned long long *total)
{
    NSMutableArray *entries = [NSMutableArray array];
    NSString *dir = fbBytecodeCacheDirectory();
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath:dir];
    NSString *name;
    *total = 0;
    while ((name = [e nextObject])) {
        NSDictionary *a = [e fileAttributes];
        if (![[a fileType] isEqual:NSFileTypeRegular])
            continue;
        *total += [a fileSize];
        [entries addObject:[NSArray arrayWithObjects:[dir stringByAppendingPathComponent:name],
                            [a fileModificationDate], [NSNumber numberWithUnsignedLongLong:[a fileSize]], nil]];
    }
    return entries;
}

unsigned long long fbBytecodeCacheSize(void)
{
    unsigned long long total;
    cacheEntries(&total);
    return total;
}

void fbEmptyBytecodeCache(void)
{
    unsigned long long total;
    NSArray *entries = cacheEntries(&total);
    for (NSUInteger i = 0; i < [entries count]; i++)
        unlink([[[entries objectAtIndex:i] objectAtIndex:0] fileSystemRepresentation]);
}

static NSInteger byModificationDate(id a, id b, void *ctx)
{
    (void)ctx;
    return [[a objectAtIndex:1] compare:[b objectAtIndex:1]];
}

/* Oldest first, down to 80% of the cap, so the trim doesn't run at every start. */
/* Each file name starts with the JSC build version (<build>-<host hash>-<source hash>.jsbc / .seen), and another
 * build never reads them. Keep the build of the most recently written file, drop the rest: after a WebKit update
 * the old build's files are dead weight against the cap. */
static void dropOtherBuilds(void)
{
    unsigned long long total;
    NSArray *entries = cacheEntries(&total);
    NSString *newestBuild = nil;
    NSDate *newest = nil;
    for (NSUInteger i = 0; i < [entries count]; i++) {
        NSArray *e = [entries objectAtIndex:i];
        NSString *name = [[e objectAtIndex:0] lastPathComponent];
        NSRange dash = [name rangeOfString:@"-"];
        if (dash.location == NSNotFound)
            continue;
        if (!newest || [(NSDate *)[e objectAtIndex:1] compare:newest] == NSOrderedDescending) {
            newest = [e objectAtIndex:1];
            newestBuild = [name substringToIndex:dash.location];
        }
    }
    if (!newestBuild)
        return;
    for (NSUInteger i = 0; i < [entries count]; i++) {
        NSString *path = [[entries objectAtIndex:i] objectAtIndex:0];
        NSString *name = [path lastPathComponent];
        NSRange dash = [name rangeOfString:@"-"];
        if (dash.location != NSNotFound && ![[name substringToIndex:dash.location] isEqualToString:newestBuild])
            unlink([path fileSystemRepresentation]);
    }
}

/* WebKit writes each cache file under "<name>.<pid>.tmp" and renames it into place, so a WebProcess killed mid-write
 * (a tab closed mid-load) leaves only such a file behind. At startup no WebProcess exists yet: all of them are
 * leftovers. ".writing" markers came from the previous in-place format. */
static void dropLeftovers(void)
{
    unsigned long long total;
    NSArray *entries = cacheEntries(&total);
    for (NSUInteger i = 0; i < [entries count]; i++) {
        NSString *path = [[entries objectAtIndex:i] objectAtIndex:0];
        if ([path hasSuffix:@".tmp"] || [path hasSuffix:@".writing"])
            unlink([path fileSystemRepresentation]);
    }
}

static void trimBytecodeCache(unsigned long long cap)
{
    dropLeftovers();
    dropOtherBuilds();
    unsigned long long total;
    NSArray *entries = cacheEntries(&total);
    if (total <= cap)
        return;
    NSArray *sorted = [entries sortedArrayUsingFunction:byModificationDate context:NULL];
    unsigned long long goal = cap / 5 * 4;
    for (NSUInteger i = 0; i < [sorted count] && total > goal; i++) {
        NSArray *entry = [sorted objectAtIndex:i];
        if (!unlink([[entry objectAtIndex:0] fileSystemRepresentation]))
            total -= [[entry objectAtIndex:2] unsignedLongLongValue];
    }
}

static void setupBytecodeCache(NSUserDefaults *defaults)
{
    if (getenv("WEBKIT_JSC_BYTECODE_CACHE_DIR")) {           /* explicit environment wins, "" turns it off */
        fprintf(stderr, "frostbyte: bytecode cache: %s (from the environment)\n", getenv("WEBKIT_JSC_BYTECODE_CACHE_DIR"));
        return;
    }
    if (![defaults boolForKey:PrefBytecodeCache]) {
        fprintf(stderr, "frostbyte: bytecode cache: off\n");
        return;
    }
    NSString *dir = fbBytecodeCacheDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    chmod([dir fileSystemRepresentation], 0700);
    NSInteger mb = [defaults integerForKey:PrefBytecodeCacheMB];
    unsigned long long cap = (unsigned long long)(mb > 0 ? mb : 512) << 20;
    trimBytecodeCache(cap);
    setenvFromPreference("WEBKIT_JSC_BYTECODE_CACHE_DIR", [dir fileSystemRepresentation]);
    fprintf(stderr, "frostbyte: bytecode cache: %s, %llu of %llu MB\n", [dir fileSystemRepresentation],
            fbBytecodeCacheSize() >> 20, cap >> 20);
}

/* Where the WPE runtime's data lives: the /opt/wpe prefix, or the app's own Resources/share when the runtime is
 * bundled (setupBundledRuntime). */
static const char *s_runtimeShare = "/opt/wpe/share";

/* A self-contained FrostByte.app (tools/package-app.py: the LEOPARD_TARGET=g5/generic release builds) carries the
 * whole WPE runtime: libraries and GStreamer/GIO modules in Contents/Frameworks, WPEWebProcess, WPENetworkProcess
 * and gst-plugin-scanner in Contents/Libexec, and fontconfig, TLS trust and the MIME database in
 * Contents/Resources. The libraries find each other by @loader_path; everything found by path at run time is
 * pointed into the bundle here, before GLib, GStreamer or WebKit look. A variable already in the environment wins
 * (debugging). Without Contents/Frameworks/libWPEWebKit-2.0.1.dylib (a development run from the /opt/wpe
 * prefix) nothing changes. */
static BOOL s_bundledRuntime;

static void setBundlePath(const char *name, NSString *path, BOOL mustExist)
{
    if (getenv(name) || (mustExist && ![[NSFileManager defaultManager] fileExistsAtPath:path]))
        return;
    setenv(name, [path fileSystemRepresentation], 1);
}

static void setupBundledRuntime(void)
{
    NSString *contents = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents"];
    NSString *frameworks = [contents stringByAppendingPathComponent:@"Frameworks"];
    NSString *libexec = [contents stringByAppendingPathComponent:@"Libexec"];
    NSString *resources = [contents stringByAppendingPathComponent:@"Resources"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[frameworks stringByAppendingPathComponent:@"libWPEWebKit-2.0.1.dylib"]])
        return;
    s_bundledRuntime = YES;
    setBundlePath("WEBKIT_EXEC_PATH", libexec, YES);
    setBundlePath("WEBKIT_INJECTED_BUNDLE_PATH", [frameworks stringByAppendingPathComponent:@"wpe-webkit-2.0/injected-bundle"], YES);
    setBundlePath("GIO_MODULE_DIR", [frameworks stringByAppendingPathComponent:@"gio/modules"], YES);
    setBundlePath("GST_PLUGIN_SYSTEM_PATH_1_0", [frameworks stringByAppendingPathComponent:@"gstreamer-1.0"], YES);
    setBundlePath("GST_PLUGIN_SCANNER_1_0", [libexec stringByAppendingPathComponent:@"gst-plugin-scanner"], YES);
    if (!getenv("GST_PLUGIN_PATH_1_0"))
        setenv("GST_PLUGIN_PATH_1_0", "", 1);      /* only the bundle's plugins */
    /* GStreamer's registry caches plugin paths: one per bundle location, so another copy (or the /opt/wpe
     * install) never hands this one stale paths. */
    NSString *caches = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/org.frostbyte.FrostByte"];
    [[NSFileManager defaultManager] createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:NULL];
    setBundlePath("GST_REGISTRY_1_0", [caches stringByAppendingPathComponent:
        [NSString stringWithFormat:@"gstreamer-registry-%08lx.bin", (unsigned long)[contents hash]]], NO);
    NSString *etc = [resources stringByAppendingPathComponent:@"etc"];
    setBundlePath("FONTCONFIG_FILE", [etc stringByAppendingPathComponent:@"fonts/fonts.conf"], YES);
    setBundlePath("FONTCONFIG_PATH", [etc stringByAppendingPathComponent:@"fonts"], YES);
    setBundlePath("LEOPARD_TLS_CA_FILE", [etc stringByAppendingPathComponent:@"ssl/cert.pem"], YES);
    setBundlePath("LEOPARD_TLS_INTERMEDIATES", [etc stringByAppendingPathComponent:@"ssl/intermediates.pem"], YES);
    setBundlePath("XKB_CONFIG_ROOT", [resources stringByAppendingPathComponent:@"share/X11/xkb"], YES);
    /* WTF's GResources aborts (g_error) when inspector.gresource is missing from its directory. */
    setBundlePath("WEBKIT_INSPECTOR_RESOURCES_PATH", [resources stringByAppendingPathComponent:@"share/wpe-webkit-2.0"], YES);
    const char *share = [[resources stringByAppendingPathComponent:@"share"] fileSystemRepresentation];
    if (share)
        s_runtimeShare = strdup(share);
    fprintf(stderr, "frostbyte: self-contained runtime in %s\n", [contents fileSystemRepresentation]);
}

/* GIO finds the freedesktop MIME database (deps: pkg_mimedb) through XDG_DATA_DIRS. Leopard has none of its own,
 * and without it every file:// URL is application/octet-stream, which WebKit turns into a download. */
static void setupDataDirs(void)
{
    const char *runtimeShare = s_runtimeShare;
    const char *dirs = getenv("XDG_DATA_DIRS");
    char value[1024];
    if (dirs && strstr(dirs, runtimeShare))
        return;
    snprintf(value, sizeof value, "%s:%s", runtimeShare, dirs && *dirs ? dirs : "/usr/local/share:/usr/share");
    setenv("XDG_DATA_DIRS", value, 1);
}

/* Leopard starts GUI apps with a soft limit of 256 open files. On Darwin every GLib wakeup (each GMainContext,
 * GStreamer's threads) is a pipe, two descriptors, so a media page plus a search page ran the web and network
 * processes out of descriptors on the G5 and GLib aborted ("Creating pipes for GWakeup: Too many open files").
 * Raise the soft limit to the per-process maximum before any WebKit process exists; the helpers inherit it.
 * Build option FROSTBYTE_RAISE_FD_LIMIT: on by default for every target (Leopard's 256 soft limit starves WebProcesses). */
#ifndef FROSTBYTE_RAISE_FD_LIMIT
#define FROSTBYTE_RAISE_FD_LIMIT 1
#endif
static void raiseDescriptorLimit(void)
{
    struct rlimit rl;
    if (!FROSTBYTE_RAISE_FD_LIMIT || getrlimit(RLIMIT_NOFILE, &rl))
        return;
    int perProcess = 0;
    size_t size = sizeof perProcess;
    rlim_t want = 10240;                                    /* OPEN_MAX: setrlimit refuses more than this */
    if (!sysctlbyname("kern.maxfilesperproc", &perProcess, &size, NULL, 0) && perProcess > 0 && (rlim_t)perProcess < want)
        want = (rlim_t)perProcess;
    if (rl.rlim_max != RLIM_INFINITY && rl.rlim_max < want)
        want = rl.rlim_max;
    if (rl.rlim_cur >= want)
        return;
    rlim_t was = rl.rlim_cur;
    rl.rlim_cur = want;
    if (!setrlimit(RLIMIT_NOFILE, &rl))
        fprintf(stderr, "frostbyte: open file limit %llu -> %llu\n", (unsigned long long)was, (unsigned long long)want);
}

void applyStartupPreferences(void)
{
    raiseDescriptorLimit();
    setupBundledRuntime();
    setupDataDirs();
    s_envWeSet = [[NSMutableArray alloc] init];
    NSUserDefaults *defaults = prefs();
    fbGraphics = detectGraphics();
    FBGraphicsCapabilities caps = fbGraphics;
    NSString *mode = [defaults stringForKey:PrefGraphics];
    BOOL zeroCopy = [defaults boolForKey:PrefZeroCopy];
    const char *forcedZeroCopy = getenv("LEOPARD_WPE_ZEROCOPY");   /* explicit environment wins, as for the GL tier */
    if (forcedZeroCopy && *forcedZeroCopy)
        zeroCopy = strcmp(forcedZeroCopy, "0") != 0;

    const char *forced = getenv("LEOPARD_WPE_GL");
    BOOL gpu;
    if (forced && *forced)
        gpu = strcmp(forced, "soft") != 0;
    else {
        /* "On" only counts where an accelerated renderer exists (Preferences greys it out otherwise; a stored
         * "On" from another card falls back to CPU rendering). LEOPARD_WPE_GL still forces for testing. */
        gpu = ([mode caseInsensitiveCompare:@"On"] == NSOrderedSame && (caps.radeon || caps.accelerated))
            || ([mode caseInsensitiveCompare:@"Auto"] == NSOrderedSame
                && (caps.radeon || (FROSTBYTE_GL_ANY_ACCELERATED && caps.accelerated)));
        setenvFromPreference("LEOPARD_WPE_GL", gpu ? "gl21" : "soft");
    }
    if (!zeroCopy || !caps.sharedBuffers)
        setenvFromPreference("LEOPARD_WPE_ZEROCOPY", "0");
    fbGPUActive = gpu;
    fbZeroCopyActive = gpu && zeroCopy && caps.sharedBuffers;
    if (FROSTBYTE_GL_ANY_ACCELERATED)
        fprintf(stderr, "frostbyte: graphics: accelerated renderer %s\n", caps.accelerated ? "yes" : "no");
    fprintf(stderr, "frostbyte: graphics: Radeon %s (%s), shared buffers %s; preference %s, zero-copy %s -> %s%s\n",
            caps.radeon ? "yes" : "no", caps.renderer, caps.sharedBuffers ? "yes" : "no", [mode UTF8String],
            zeroCopy ? "on" : "off", gpu ? "GPU" : "CPU", fbZeroCopyActive ? " (zero-copy)" : "");
    /* Hardware video decoding: Auto uses UVD when its driver has decode sessions on. An explicit FROSTBYTE_UVD
     * in the environment wins, as for the GL tier. Off reaches the web process's GStreamer as FROSTBYTE_UVD=0. */
    NSString *video = [defaults stringForKey:PrefVideoDecoding];
    const char *forcedUVD = getenv("FROSTBYTE_UVD");
    if (forcedUVD && *forcedUVD)
        fbHardwareVideoActive = strcmp(forcedUVD, "0") != 0;
    else {
        /* Hardware decoding only where UVD decode sessions exist, whether the choice is On or Automatic. */
        fbHardwareVideoActive = caps.uvdSessions && [video caseInsensitiveCompare:@"Off"] != NSOrderedSame;
        if (!fbHardwareVideoActive)
            setenvFromPreference("FROSTBYTE_UVD", "0");
    }
    fprintf(stderr, "frostbyte: video decoder: UVD %s; preference %s -> %s%s\n",
            caps.uvdSessions ? "firmware, sessions on" : caps.uvd ? "firmware, sessions off" : "not found",
            [video UTF8String], fbHardwareVideoActive ? "hardware H.264" : "software",
            fbHardwareVideoActive && [defaults boolForKey:PrefPreferH264] ? " (sites steered to H.264)" : "");

    if (![defaults boolForKey:PrefJIT] && !getenv("JSC_useJIT"))
        setenvFromPreference("JSC_useJIT", "0");
    NSInteger threads = [defaults integerForKey:PrefRasterThreads];
    if (threads > 0 && !getenv("WEBKIT_CPU_RASTER_THREADS")) {
        char n[8];
        snprintf(n, sizeof n, "%d", (int)MIN(threads, 16));
        setenvFromPreference("WEBKIT_CPU_RASTER_THREADS", n);
    }
    fprintf(stderr, "frostbyte: JavaScript JIT %s, CPU raster threads %s\n", getenv("JSC_useJIT") ? "off" : "on",
            getenv("WEBKIT_CPU_RASTER_THREADS") ?: "auto");
    setupBytecodeCache(defaults);
}

/* Quit and start again (Hardware preferences). A shell waits for this process to exit, then runs the
 * same executable; variables we set from preferences are dropped so the new values apply. */
void relaunch(void)
{
    for (NSString *name in s_envWeSet)
        unsetenv([name UTF8String]);
    NSString *exe = [[NSBundle mainBundle] executablePath];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:@"-c",
        @"while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; exec \"$1\"",
        [NSString stringWithFormat:@"%d", (int)getpid()], exe, nil]];
    [task launch];
    [NSApp terminate:nil];
}

