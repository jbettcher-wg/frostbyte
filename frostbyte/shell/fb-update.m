/*
 * FrostByte: the updater (Check for Updates..., a daily check at launch, install and relaunch).
 *
 * Every release publishes a small signed manifest beside its disk images:
 *   frostbyte-update.txt       key=value lines (tools/make-update-manifest.sh):
 *                                format=1, product=org.frostbyte.FrostByte, version=0.3.4, notes-url=...,
 *                                per build <t>.file / <t>.url / <t>.size / <t>.sha256 (t = g5, e6500, generic),
 *                                notes=... (one per line of release notes, a small Markdown subset)
 *   frostbyte-update.txt.sig   the raw 64-byte Ed25519 signature of the manifest's exact bytes
 *                              (tools/sign-release.sh), checked against kUpdatePublicKey with Nettle
 * fetched from GitHub's latest-release redirect over libsoup 3 + GnuTLS (Leopard's NSURLConnection can't do
 * modern TLS). Checks, in order: the signature (nothing is parsed before it verifies), the format and product,
 * the version (must be newer than this copy: no downgrades, no reinstalls), this build's entry
 * (FROSTBYTE_UPDATE_TARGET from frostbyte/build.sh: t4240 -> e6500, g5 -> g5, generic -> generic); after the
 * download, its size and SHA-256 against the manifest; after mounting it, the app's bundle identifier
 * (this copy's own) and version (the manifest's).
 *
 * Install: the DMG goes to ~/Library/Caches/<bundle id>/Updates, is attached read-only and hidden
 * (hdiutil -nobrowse) on a private mount point, and its app is copied with ditto beside this one as
 * ".<name>.app.new"; the image is detached. A small sh helper then waits for this process to exit, renames
 * this copy to ".<name>.app.old" and the new one into its place, and `open`s it. The new copy confirms it
 * started (fbUpdateStartup writes the marker the helper waits for); then the helper removes the old copy, or,
 * if the new one never came up, puts the old one back and opens that. If FrostByte can't replace itself (a
 * folder the user can't write, a read-only volume such as the disk image it runs from, another user's copy),
 * the verified DMG is opened in the Finder with a short explanation instead. Nothing asks for a password.
 *
 * Test hooks: FROSTBYTE_UPDATE_URL replaces the manifest URL (then, and only then, http:// is allowed, for the
 * manifest and the DMGs, and the launch check runs every launch); FROSTBYTE_UPDATE_PUBKEY (64 hex digits)
 * replaces the public key. FROSTBYTE_UPDATE_CHECK=asked (with FROSTBYTE_UPDATE_URL) makes the launch check behave like
 * Check for Updates (its result shows in the window, which doesn't take focus), so error paths test without input.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"
#include <nettle/eddsa.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <float.h>

#ifndef FROSTBYTE_UPDATE_TARGET
#define FROSTBYTE_UPDATE_TARGET "generic"
#endif

NSString *const PrefCheckForUpdates = @"CheckForUpdates";
static NSString *const PrefUpdateLastCheck = @"UpdateLastCheck";           /* NSDate of the last automatic check */
static NSString *const PrefUpdateSkippedVersion = @"UpdateSkippedVersion"; /* Skip This Version */

static const char kManifestURL[] = "https://github.com/jbettcher-wg/frostbyte/releases/latest/download/frostbyte-update.txt";
/* The release key's public half (tools/make-release-key.sh). The private half never leaves the release machine. */
static const char kUpdatePublicKey[] = "ae6f7dfea20ffad82a2bcd7654ae75d7c46bc923701bfa79d8e437c691a37db0";
static const char kProduct[] = "org.frostbyte.FrostByte";
enum { kManifestMax = 64 * 1024, kReadChunk = 256 * 1024 };
static const NSTimeInterval kCheckInterval = 23 * 3600.0;    /* "about once a day": a launch a day later checks */
static const guint64 kMaxDMG = 1024ULL * 1024 * 1024;

void fbUpdateRegisterDefaults(void)
{
    [prefs() registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:YES], PrefCheckForUpdates, nil]];
}

static void ulog(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *s = [[[NSString alloc] initWithFormat:format arguments:ap] autorelease];
    va_end(ap);
    fprintf(stderr, "frostbyte: update: %s\n", [s UTF8String]);
}

/* ---- versions ---- */

/* Up to four numeric components; lenient (this copy's "0.4-dev" reads as 0.4) unless strict. */
static BOOL parseVersion(NSString *s, long out[4], BOOL strict)
{
    memset(out, 0, 4 * sizeof(long));
    const char *p = [s UTF8String];
    if (!p || !g_ascii_isdigit(*p))
        return NO;
    for (int i = 0; i < 4; i++) {
        char *end;
        out[i] = strtol(p, &end, 10);
        if (end == p || out[i] < 0 || out[i] > 99999)
            return NO;
        p = end;
        if (*p != '.')
            break;
        p++;
        if (!g_ascii_isdigit(*p))
            return NO;
    }
    return !strict || !*p;
}

static int compareVersions(NSString *a, NSString *b)
{
    long va[4], vb[4];
    parseVersion(a, va, NO);
    parseVersion(b, vb, NO);
    for (int i = 0; i < 4; i++)
        if (va[i] != vb[i])
            return va[i] < vb[i] ? -1 : 1;
    return 0;
}

static NSString *currentVersion(void)
{
    NSString *v = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    return [v length] ? v : str(FROSTBYTE_VERSION);
}

static NSString *targetDisplayName(void)
{
    if (!strcmp(FROSTBYTE_UPDATE_TARGET, "g5"))
        return @"G5";
    return str(FROSTBYTE_UPDATE_TARGET);
}

/* ---- paths ---- */

static NSString *bundleID(void)
{
    NSString *b = [[NSBundle mainBundle] bundleIdentifier];
    return [b length] ? b : str(kProduct);
}

static NSString *updatesDir(void)
{
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Library/Caches/%@/Updates", bundleID()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
    return d;
}

static NSString *pendingFile(void) { return [updatesDir() stringByAppendingPathComponent:@"pending.plist"]; }

static BOOL isAppBundle(NSString *path) { return [[path pathExtension] caseInsensitiveCompare:@"app"] == NSOrderedSame; }

/* Why this copy can't replace itself, or nil if it can. */
static NSString *installBlocker(guint64 dmgSize)
{
    NSString *app = [[NSBundle mainBundle] bundlePath];
    NSString *dir = [app stringByDeletingLastPathComponent];
    if (!isAppBundle(app))
        return @"This copy of FrostByte isn't an application bundle, so it can't replace itself.";
    struct statfs fs;
    if (statfs([dir fileSystemRepresentation], &fs) == 0 && (fs.f_flags & MNT_RDONLY))
        return [NSString stringWithFormat:str("FrostByte is running from \xe2\x80\x9c%@\xe2\x80\x9d, which is read-only (a disk image?)."),
                [[NSFileManager defaultManager] displayNameAtPath:dir]];
    if (access([dir fileSystemRepresentation], W_OK) != 0)
        return [NSString stringWithFormat:str("Your account can't change the folder \xe2\x80\x9c%@\xe2\x80\x9d that FrostByte is in."),
                [[NSFileManager defaultManager] displayNameAtPath:dir]];
    if (access([app fileSystemRepresentation], W_OK) != 0
        || access([[app stringByAppendingPathComponent:@"Contents"] fileSystemRepresentation], W_OK) != 0)
        return @"This copy of FrostByte belongs to another user, so your account can't replace it.";
    if (statfs([dir fileSystemRepresentation], &fs) == 0
        && (guint64)fs.f_bavail * fs.f_bsize < dmgSize * 4 + 64ULL * 1024 * 1024)
        return [NSString stringWithFormat:str("There isn't enough free space on \xe2\x80\x9c%@\xe2\x80\x9d to unpack the update."),
                [[NSFileManager defaultManager] displayNameAtPath:dir]];
    return nil;
}

/* ---- the manifest ---- */

static BOOL hexDecode(const char *hex, uint8_t *out, size_t n)
{
    if (!hex || strlen(hex) != 2 * n)
        return NO;
    for (size_t i = 0; i < n; i++) {
        int hi = g_ascii_xdigit_value(hex[2 * i]), lo = g_ascii_xdigit_value(hex[2 * i + 1]);
        if (hi < 0 || lo < 0)
            return NO;
        out[i] = (uint8_t)(hi << 4 | lo);
    }
    return YES;
}

static BOOL testURLOverride(void)
{
    const char *u = getenv("FROSTBYTE_UPDATE_URL");
    return u && *u;
}

/* Test hook: the launch check counts as an explicit Check for Updates. */
static BOOL testLaunchCheckAsked(void)
{
    const char *c = getenv("FROSTBYTE_UPDATE_CHECK");
    return testURLOverride() && c && !strcmp(c, "asked");
}

static BOOL schemeAllowed(const char *url)
{
    if (!g_ascii_strncasecmp(url, "https://", 8))
        return YES;
    return testURLOverride() && !g_ascii_strncasecmp(url, "http://", 7);
}

/* NULL if the signature is good, else why not. */
static NSString *verifySignature(GBytes *manifest, GBytes *signature)
{
    uint8_t key[ED25519_KEY_SIZE];
    const char *override = getenv("FROSTBYTE_UPDATE_PUBKEY");
    const char *hex = override && *override ? override : kUpdatePublicKey;
    if (!hexDecode(hex, key, sizeof key))
        return @"The update key is malformed (FROSTBYTE_UPDATE_PUBKEY).";
    gsize mlen = 0, slen = 0;
    const uint8_t *m = g_bytes_get_data(manifest, &mlen);
    const uint8_t *s = g_bytes_get_data(signature, &slen);
    if (slen != ED25519_SIGNATURE_SIZE)
        return @"The update information has no valid signature.";
    if (!ed25519_sha512_verify(key, mlen, m ? m : (const uint8_t *)"", s))
        return @"The update information's signature is wrong. It may have been tampered with.";
    return nil;
}

/* key=value lines after the signature checked out. Repeated notes= lines collect into "notes" (NSArray). */
static NSDictionary *parseManifest(GBytes *bytes, NSString **why)
{
    gsize len = 0;
    const char *data = g_bytes_get_data(bytes, &len);
    if (!data || !g_utf8_validate(data, len, NULL)) {
        *why = @"The update information isn't readable text.";
        return nil;
    }
    NSString *text = [[[NSString alloc] initWithBytes:data length:len encoding:NSUTF8StringEncoding] autorelease];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSMutableArray *notes = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasSuffix:@"\r"])
            line = [line substringToIndex:[line length] - 1];
        if (![line length] || [line hasPrefix:@"#"])
            continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound || !eq.location) {
            *why = @"The update information is malformed.";
            return nil;
        }
        NSString *key = [line substringToIndex:eq.location], *value = [line substringFromIndex:eq.location + 1];
        if ([key isEqual:@"notes"]) {
            [notes addObject:value];
            continue;
        }
        if ([d objectForKey:key]) {
            *why = @"The update information is malformed (a repeated key).";
            return nil;
        }
        [d setObject:value forKey:key];
    }
    [d setObject:notes forKey:@"notes"];
    if (![[d objectForKey:@"format"] isEqual:@"1"]) {
        *why = @"The update information is in a newer format. Download the new FrostByte from its web site.";
        return nil;
    }
    if (![[d objectForKey:@"product"] isEqual:str(kProduct)]) {
        *why = @"The update information is for a different product.";
        return nil;
    }
    long v[4];
    if (!parseVersion([d objectForKey:@"version"], v, YES)) {
        *why = @"The update information has a malformed version.";
        return nil;
    }
    return d;
}

/* The release notes' Markdown subset (headings, bullets, **bold**, `code`, [text](url)) as attributed text. */
static NSAttributedString *renderNotes(NSArray *lines)
{
    NSMutableAttributedString *out = [[[NSMutableAttributedString alloc] init] autorelease];
    NSFont *body = [NSFont systemFontOfSize:11], *bold = [NSFont boldSystemFontOfSize:11], *head = [NSFont boldSystemFontOfSize:12];
    NSMutableParagraphStyle *bullet = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [bullet setHeadIndent:14];
    [bullet setParagraphSpacing:3];
    NSMutableParagraphStyle *plain = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [plain setParagraphSpacing:5];
    BOOL lastBlank = YES;
    for (NSString *line in lines) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"|"])                       /* tables: not for this window */
            continue;
        if (![t length]) {
            lastBlank = YES;
            continue;
        }
        NSFont *font = body;
        NSParagraphStyle *style = plain;
        NSString *prefix = @"";
        if ([t hasPrefix:@"#"]) {
            while ([t hasPrefix:@"#"])
                t = [t substringFromIndex:1];
            t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            font = head;
            if ([out length])
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n"] autorelease]];
        } else if ([t hasPrefix:@"- "] || [t hasPrefix:@"* "]) {
            t = [t substringFromIndex:2];
            prefix = str("\xe2\x80\xa2 ");
            style = bullet;
        } else if (!lastBlank && [out length]) {
            /* a continuation line of the previous paragraph */
            [[out mutableString] replaceCharactersInRange:NSMakeRange([out length] - 1, 1) withString:@" "];
        }
        lastBlank = NO;
        NSMutableAttributedString *para = [[[NSMutableAttributedString alloc] initWithString:prefix attributes:
            [NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName, style, NSParagraphStyleAttributeName, nil]] autorelease];
        /* inline: **bold** toggles the font, `code` and link targets drop out */
        BOOL strong = NO;
        NSMutableString *run = [NSMutableString string];
        NSUInteger n = [t length];
        for (NSUInteger i = 0; i <= n; i++) {
            BOOL flush = i == n || (i + 1 < n && [t characterAtIndex:i] == '*' && [t characterAtIndex:i + 1] == '*');
            if (flush) {
                if ([run length])
                    [para appendAttributedString:[[[NSAttributedString alloc] initWithString:run attributes:
                        [NSDictionary dictionaryWithObjectsAndKeys:strong || font == head ? (font == head ? head : bold) : font,
                         NSFontAttributeName, style, NSParagraphStyleAttributeName, nil]] autorelease]];
                [run setString:@""];
                strong = !strong;
                i++;
                continue;
            }
            unichar c = [t characterAtIndex:i];
            if (c == '`')
                continue;
            if (c == ']' && i + 1 < n && [t characterAtIndex:i + 1] == '(') {
                NSRange close = [t rangeOfString:@")" options:0 range:NSMakeRange(i, n - i)];
                if (close.location != NSNotFound) {
                    i = close.location;
                    continue;
                }
            }
            if (c == '[')
                continue;
            [run appendFormat:@"%C", c];
        }
        [para appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:
            [NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName, style, NSParagraphStyleAttributeName, nil]] autorelease]];
        [out appendAttributedString:para];
    }
    return out;
}

/* ---- the window ---- */

@interface FBUpdateView : NSView
@end
@implementation FBUpdateView
- (BOOL)isFlipped { return YES; }
@end

typedef enum {
    FBUpdateIdle, FBUpdateChecking, FBUpdateUpToDate, FBUpdateAvailable, FBUpdateDownloading, FBUpdateInstalling,
    FBUpdateRestarting, FBUpdateFailed, FBUpdateManual
} FBUpdateState;

@interface FBUpdater : NSObject {
    NSWindow *window;
    NSImageView *icon;
    NSTextField *title, *message, *notesLabel, *status;
    NSButton *notesLink;
    NSScrollView *notesScroll;
    NSTextView *notesView;
    NSProgressIndicator *bar, *spinner;
    NSButton *leftButton, *middleButton, *rightButton;
    FBUpdateState state;
    BOOL userInitiated, installFailed, spinning;

    SoupSession *session;
    SoupMessage *msg;
    GCancellable *cancel;
    GBytes *manifestBytes;
    NSDictionary *manifest;
    NSString *version, *dmgURL, *dmgName, *dmgSHA, *notesURL;
    guint64 dmgSize;

    /* download / verification */
    GInputStream *stream;
    int fd;
    GChecksum *sum;
    guint64 received;
    NSString *dmgPath;

    /* install */
    NSString *mountPoint, *newApp, *oldApp;
    SEL toolNext;
}
+ (FBUpdater *)shared;
- (void)check:(BOOL)user;
- (void)startupWithPending:(NSDictionary *)pending;
- (BOOL)busy;
@end

@interface FBUpdater (Steps)
- (void)install;
- (void)discardPartial;
- (void)cleanUpDownload;
- (void)verified;
- (void)swapAndRelaunch;
@end

static FBUpdater *s_updater;
static gboolean terminateSoon(gpointer unused);

static NSTextField *makeLabel(NSView *parent, NSFont *font, NSColor *color)
{
    NSTextField *t = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
    [t setFont:font];
    [t setTextColor:color];
    [t setBezeled:NO];
    [t setDrawsBackground:NO];
    [t setEditable:NO];
    [t setSelectable:NO];
    [[t cell] setWraps:YES];
    [parent addSubview:t];
    return t;
}

static NSButton *makeButton(NSView *parent, id target, SEL action)
{
    NSButton *b = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
    [b setBezelStyle:NSRoundedBezelStyle];
    [b setTarget:target];
    [b setAction:action];
    [parent addSubview:b];
    return b;
}

/* GLib callbacks into the updater, inside an autorelease pool. */
static void manifestFetched(GObject *src, GAsyncResult *res, gpointer data);
static void signatureFetched(GObject *src, GAsyncResult *res, gpointer data);
static void dmgResponse(GObject *src, GAsyncResult *res, gpointer data);
static void dmgRead(GObject *src, GAsyncResult *res, gpointer data);
static void toolDone(GObject *src, GAsyncResult *res, gpointer data);

@implementation FBUpdater

+ (FBUpdater *)shared
{
    if (!s_updater)
        s_updater = [[FBUpdater alloc] init];
    return s_updater;
}

- (id)init
{
    if (!(self = [super init]))
        return nil;
    fd = -1;
    cancel = g_cancellable_new();
    return self;
}

- (void)buildWindow
{
    if (window)
        return;
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 160)
                                         styleMask:NSTitledWindowMask | NSClosableWindowMask
                                           backing:NSBackingStoreBuffered defer:YES];
    [window setReleasedWhenClosed:NO];
    [window setTitle:@"Software Update"];
    [window setDelegate:(id)self];
    FBUpdateView *v = [[[FBUpdateView alloc] initWithFrame:NSMakeRect(0, 0, 560, 160)] autorelease];
    [window setContentView:v];
    icon = [[[NSImageView alloc] initWithFrame:NSMakeRect(20, 16, 64, 64)] autorelease];
    [icon setImage:[NSApp applicationIconImage]];
    [icon setImageScaling:NSScaleProportionally];
    [v addSubview:icon];
    title = makeLabel(v, [NSFont boldSystemFontOfSize:14], [NSColor controlTextColor]);
    message = makeLabel(v, [NSFont systemFontOfSize:11], [NSColor controlTextColor]);
    notesLabel = makeLabel(v, [NSFont boldSystemFontOfSize:11], [NSColor controlTextColor]);
    [notesLabel setStringValue:@"Release notes:"];
    notesLink = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
    [notesLink setBordered:NO];
    [notesLink setButtonType:NSMomentaryChangeButton];
    [notesLink setAttributedTitle:[[[NSAttributedString alloc] initWithString:@"On the web" attributes:
        [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:11], NSFontAttributeName,
         [NSColor colorWithCalibratedRed:0.12 green:0.37 blue:0.65 alpha:1], NSForegroundColorAttributeName, nil]] autorelease]];
    [notesLink setTarget:self];
    [notesLink setAction:@selector(openNotes:)];
    [v addSubview:notesLink];
    notesScroll = [[[NSScrollView alloc] initWithFrame:NSZeroRect] autorelease];
    [notesScroll setHasVerticalScroller:YES];
    [notesScroll setBorderType:NSBezelBorder];
    notesView = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 200)] autorelease];
    [notesView setEditable:NO];
    [notesView setTextContainerInset:NSMakeSize(6, 6)];
    [notesView setAutoresizingMask:NSViewWidthSizable];
    [notesScroll setDocumentView:notesView];
    [v addSubview:notesScroll];
    status = makeLabel(v, [NSFont systemFontOfSize:11], [NSColor controlTextColor]);
    bar = [[[NSProgressIndicator alloc] initWithFrame:NSZeroRect] autorelease];
    [bar setStyle:NSProgressIndicatorBarStyle];
    [bar setIndeterminate:NO];
    [bar setMinValue:0];
    [bar setMaxValue:1];
    [v addSubview:bar];
    spinner = [[[NSProgressIndicator alloc] initWithFrame:NSZeroRect] autorelease];
    [spinner setStyle:NSProgressIndicatorSpinningStyle];
    [spinner setControlSize:NSSmallControlSize];
    [spinner setDisplayedWhenStopped:NO];
    [spinner setUsesThreadedAnimation:YES];
    [v addSubview:spinner];
    leftButton = makeButton(v, self, @selector(leftClicked:));
    middleButton = makeButton(v, self, @selector(middleClicked:));
    rightButton = makeButton(v, self, @selector(rightClicked:));
    [rightButton setKeyEquivalent:@"\r"];
}

/* Lay the window out for the state: compact for messages, tall with the notes for an available update. */
- (void)layout
{
    BOOL full = state == FBUpdateAvailable || state == FBUpdateDownloading || state == FBUpdateInstalling
        || state == FBUpdateRestarting || (state == FBUpdateFailed && installFailed);
    CGFloat W = 560, H = full ? 440 : 170, x = 102, w = W - x - 20;
    NSRect old = [window frame];
    NSRect f = [window frameRectForContentRect:NSMakeRect(0, 0, W, H)];
    if ([window isVisible]) {
        f.origin.x = old.origin.x;
        f.origin.y = NSMaxY(old) - NSHeight(f);
    }
    [window setFrame:f display:[window isVisible] animate:NO];
    [[window contentView] setFrame:NSMakeRect(0, 0, W, H)];
    [title setFrame:NSMakeRect(x, 16, w, 20)];
    [message setFrame:NSMakeRect(x, 40, w, 44)];
    [notesLabel setHidden:!full];
    [notesScroll setHidden:!full];
    [notesLink setHidden:!full || ![notesURL length]];
    [notesLabel setFrame:NSMakeRect(x, 84, 200, 16)];
    [notesLink sizeToFit];
    [notesLink setFrame:NSMakeRect(W - 20 - NSWidth([notesLink frame]), 84, NSWidth([notesLink frame]), 16)];
    [notesScroll setFrame:NSMakeRect(x, 104, w, 210)];
    [[notesView textContainer] setContainerSize:NSMakeSize([notesScroll contentSize].width, FLT_MAX)];
    [notesView setFrameSize:NSMakeSize([notesScroll contentSize].width, NSHeight([notesView frame]))];
    CGFloat statusY = full ? 324 : 90;
    [status setFrame:NSMakeRect(spinning ? x + 22 : x, statusY, spinning ? w - 22 : w, 30)];
    [spinner setFrame:NSMakeRect(x, statusY, 16, 16)];
    [bar setFrame:NSMakeRect(x, statusY + 32, w, 12)];
    CGFloat by = H - 14 - 32;
    [rightButton sizeToFit];
    [middleButton sizeToFit];
    [leftButton sizeToFit];
    CGFloat rw = MAX(96, NSWidth([rightButton frame]) + 12), mw = MAX(96, NSWidth([middleButton frame]) + 12);
    [rightButton setFrame:NSMakeRect(W - 14 - rw, by, rw, 32)];
    [middleButton setFrame:NSMakeRect(W - 14 - rw - mw, by, mw, 32)];
    [leftButton setFrame:NSMakeRect(x - 6, by, MAX(96, NSWidth([leftButton frame]) + 12), 32)];
    [[window contentView] setNeedsDisplay:YES];
}

- (void)setButtons:(NSString *)right middle:(NSString *)middle left:(NSString *)left
{
    [rightButton setTitle:right ?: @""];
    [rightButton setHidden:!right];
    [rightButton setEnabled:YES];
    [middleButton setTitle:middle ?: @""];
    [middleButton setHidden:!middle];
    [leftButton setTitle:left ?: @""];
    [leftButton setHidden:!left];
}

- (void)setStatus:(NSString *)text busy:(BOOL)busy error:(BOOL)error
{
    [status setStringValue:text ?: @""];
    [status setTextColor:error ? [NSColor colorWithCalibratedRed:0.70 green:0.10 blue:0.08 alpha:1] : [NSColor controlTextColor]];
    if (busy)
        [spinner startAnimation:nil];
    else
        [spinner stopAnimation:nil];
    spinning = busy;
    NSRect r = [status frame];
    [status setFrame:NSMakeRect(busy ? 124 : 102, r.origin.y, busy ? 416 : 438, 30)];
}

- (void)show:(FBUpdateState)s
{
    [self buildWindow];
    state = s;
    [bar setHidden:YES];
    [self setStatus:nil busy:NO error:NO];
    switch (s) {
    case FBUpdateChecking:
        [title setStringValue:str("Checking for updates\xe2\x80\xa6")];
        [message setStringValue:@""];
        [self setButtons:@"Cancel" middle:nil left:nil];
        break;
    case FBUpdateUpToDate:
        [title setStringValue:@"FrostByte is up to date"];
        [self setButtons:@"OK" middle:nil left:nil];
        break;
    case FBUpdateAvailable:
        [title setStringValue:[NSString stringWithFormat:@"FrostByte %@ is available", version]];
        [message setStringValue:[NSString stringWithFormat:
            @"You have %@. Install downloads the %@ build, checks its signature and checksum, replaces this copy "
             "and restarts FrostByte. Open pages are closed when it restarts.", currentVersion(), targetDisplayName()]];
        [[notesView textStorage] setAttributedString:renderNotes([manifest objectForKey:@"notes"])];
        [notesView scrollRangeToVisible:NSMakeRange(0, 0)];
        [self setButtons:@"Install and Relaunch" middle:@"Later" left:@"Skip This Version"];
        break;
    case FBUpdateDownloading:
        [title setStringValue:[NSString stringWithFormat:str("Updating to FrostByte %@\xe2\x80\xa6"), version]];
        [bar setHidden:NO];
        [bar setDoubleValue:0];
        [self setButtons:@"Cancel" middle:nil left:nil];
        break;
    case FBUpdateInstalling:
    case FBUpdateRestarting:
        [title setStringValue:[NSString stringWithFormat:str("Updating to FrostByte %@\xe2\x80\xa6"), version]];
        [self setButtons:@"Cancel" middle:nil left:nil];
        [rightButton setEnabled:NO];
        break;
    case FBUpdateFailed:
        [self setButtons:installFailed ? @"Try Again" : @"OK" middle:installFailed ? @"Later" : nil left:nil];
        break;
    case FBUpdateManual:
        [title setStringValue:[NSString stringWithFormat:@"Install FrostByte %@ from its disk image", version]];
        [self setButtons:@"OK" middle:nil left:nil];
        break;
    default:
        break;
    }
    [self layout];
    if (![window isVisible]) {
        [window center];
        [window makeKeyAndOrderFront:nil];
        if (userInitiated && !testLaunchCheckAsked())
            [NSApp activateIgnoringOtherApps:YES];
        else
            [NSApp requestUserAttention:NSInformationalRequest];
    }
}

/* ---- checking ---- */

- (SoupSession *)session
{
    if (!session) {
        session = soup_session_new();
        soup_session_set_timeout(session, 60);
        soup_session_set_idle_timeout(session, 60);
        soup_session_set_user_agent(session, "FrostByte/" FROSTBYTE_VERSION " (Software Update; " FROSTBYTE_UPDATE_TARGET ")");
    }
    return session;
}

- (BOOL)busy
{
    return state == FBUpdateChecking || state == FBUpdateDownloading || state == FBUpdateInstalling
        || state == FBUpdateRestarting;
}

- (void)resetCancellable
{
    g_cancellable_cancel(cancel);
    g_object_unref(cancel);
    cancel = g_cancellable_new();
}

- (const char *)manifestURL
{
    const char *u = getenv("FROSTBYTE_UPDATE_URL");
    return u && *u ? u : kManifestURL;
}

- (void)fail:(NSString *)why
{
    ulog(@"%@", why);
    if (!userInitiated && !installFailed && state == FBUpdateChecking) {   /* automatic checks fail quietly */
        state = FBUpdateIdle;
        return;
    }
    if (!window || (![window isVisible] && !userInitiated)) {
        state = FBUpdateIdle;
        return;
    }
    [self show:FBUpdateFailed];
    if (installFailed) {
        [title setStringValue:[NSString stringWithFormat:@"FrostByte %@ wasn't installed", version]];
        [self setStatus:why busy:NO error:YES];
    } else {
        [title setStringValue:@"Couldn't check for updates"];
        [message setStringValue:why];
    }
    ulog(@"shown in the window: %@", [title stringValue]);
}

- (void)check:(BOOL)user
{
    if ([self busy]) {
        if (user && window)
            [window makeKeyAndOrderFront:nil];
        return;
    }
    if (!user && window && [window isVisible])    /* the window is showing something: leave it to the user */
        return;
    userInitiated = user;
    installFailed = NO;
    if (!user) {
        [prefs() setObject:[NSDate date] forKey:PrefUpdateLastCheck];
        [prefs() synchronize];
    }
    const char *url = [self manifestURL];
    ulog(@"checking %s (%s, this copy %@)", url, user ? "asked" : "automatic", currentVersion());
    if (user)
        [self show:FBUpdateChecking];
    else
        state = FBUpdateChecking;
    if (user)
        [self setStatus:@"Contacting the update server" busy:YES error:NO];
    if (!schemeAllowed(url)) {
        [self fail:@"The update address must use https."];
        return;
    }
    if (msg)
        g_object_unref(msg);
    msg = soup_message_new("GET", url);
    if (!msg) {
        [self fail:@"The update address is malformed."];
        return;
    }
    [self resetCancellable];
    soup_session_send_and_read_async([self session], msg, G_PRIORITY_DEFAULT, cancel, manifestFetched, self);
}

/* The body of a finished fetch, or nil after reporting why not. */
- (GBytes *)fetched:(GAsyncResult *)res what:(NSString *)what max:(gsize)max
{
    GError *error = NULL;
    GBytes *bytes = soup_session_send_and_read_finish(session, res, &error);
    if (!bytes) {
        if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            [self fail:[NSString stringWithFormat:@"Couldn't fetch the %@: %@", what, str(error ? error->message : "?")]];
        g_clear_error(&error);
        return NULL;
    }
    guint code = soup_message_get_status(msg);
    char *final = g_uri_to_string(soup_message_get_uri(msg));
    BOOL secure = schemeAllowed(final);
    g_free(final);
    if (code != SOUP_STATUS_OK) {
        [self fail:code != SOUP_STATUS_NOT_FOUND ? [NSString stringWithFormat:@"The update server answered %u for the %@.", code, what]
            : [what isEqual:@"signature"] ? @"The update information isn't signed, so it was ignored."
            : @"The update server has no update information (it answered 404)."];
    } else if (!secure) {
        [self fail:@"The update server redirected to an insecure address."];
    } else if (g_bytes_get_size(bytes) > max) {
        [self fail:[NSString stringWithFormat:@"The %@ is too large.", what]];
    } else
        return bytes;
    g_bytes_unref(bytes);
    return NULL;
}

- (void)manifestDone:(GAsyncResult *)res
{
    GBytes *bytes = [self fetched:res what:@"update information" max:kManifestMax];
    if (!bytes)
        return;
    if (manifestBytes)
        g_bytes_unref(manifestBytes);
    manifestBytes = bytes;
    char *sigURL = g_strconcat([self manifestURL], ".sig", NULL);
    g_object_unref(msg);
    msg = soup_message_new("GET", sigURL);
    g_free(sigURL);
    soup_session_send_and_read_async([self session], msg, G_PRIORITY_DEFAULT, cancel, signatureFetched, self);
}

- (void)signatureDone:(GAsyncResult *)res
{
    GBytes *sig = [self fetched:res what:@"signature" max:4096];
    if (!sig)
        return;
    /* 1. the signature, over the exact bytes; nothing is parsed before it verifies */
    NSString *why = verifySignature(manifestBytes, sig);
    g_bytes_unref(sig);
    if (why) {
        [self fail:why];
        return;
    }
    /* 2. format, product, version */
    NSDictionary *m = parseManifest(manifestBytes, &why);
    if (!m) {
        [self fail:why];
        return;
    }
    [manifest release];
    manifest = [m retain];
    [version release];
    version = [[m objectForKey:@"version"] copy];
    [notesURL release];
    notesURL = [[m objectForKey:@"notes-url"] copy];
    if (notesURL && ![notesURL hasPrefix:@"https://"] && ![notesURL hasPrefix:@"http://"]) {
        [notesURL release];
        notesURL = nil;
    }
    NSString *mine = currentVersion();
    ulog(@"signed manifest OK: version %@ (this copy %@)", version, mine);
    if (compareVersions(version, mine) <= 0) {
        ulog(@"%@ is not newer than %@: nothing to do", version, mine);
        state = FBUpdateIdle;
        if (userInitiated) {
            [self show:FBUpdateUpToDate];
            [message setStringValue:[NSString stringWithFormat:@"FrostByte %@ is the newest version available.", mine]];
        }
        return;
    }
    if (!userInitiated && [[prefs() stringForKey:PrefUpdateSkippedVersion] isEqual:version]) {
        ulog(@"%@ was skipped by the user", version);
        state = FBUpdateIdle;
        return;
    }
    /* 3. this build's entry */
    NSString *t = str(FROSTBYTE_UPDATE_TARGET);
    NSString *url = [m objectForKey:[t stringByAppendingString:@".url"]];
    NSString *sha = [[m objectForKey:[t stringByAppendingString:@".sha256"]] lowercaseString];
    NSString *size = [m objectForKey:[t stringByAppendingString:@".size"]];
    NSString *file = [m objectForKey:[t stringByAppendingString:@".file"]];
    uint8_t digest[32];
    if (!url || !sha || !size) {
        state = FBUpdateIdle;
        ulog(@"%@ has no %@ build", version, t);
        if (userInitiated) {
            [self show:FBUpdateUpToDate];
            [title setStringValue:[NSString stringWithFormat:@"FrostByte %@ has no %@ build", version, targetDisplayName()]];
            [message setStringValue:[NSString stringWithFormat:@"You have %@, the newest version for this build.", mine]];
        }
        return;
    }
    dmgSize = strtoull([size UTF8String], NULL, 10);
    if (!schemeAllowed([url UTF8String]) || !hexDecode([sha UTF8String], digest, sizeof digest) || !dmgSize || dmgSize > kMaxDMG) {
        [self fail:@"The update information for this build is malformed."];
        return;
    }
    [dmgURL release];
    dmgURL = [url copy];
    [dmgSHA release];
    dmgSHA = [sha copy];
    [dmgName release];
    dmgName = [([file length] && [[file lastPathComponent] isEqual:file] && [file hasSuffix:@".dmg"]
                ? file : [NSString stringWithFormat:@"FrostByte-%@-%@.dmg", version, targetDisplayName()]) copy];
    ulog(@"offering %@: %@ (%llu bytes)", version, dmgURL, dmgSize);
    [self show:FBUpdateAvailable];
}

/* ---- buttons ---- */

- (void)close
{
    state = FBUpdateIdle;
    [window orderOut:nil];
}

- (void)rightClicked:(id)sender
{
    (void)sender;
    switch (state) {
    case FBUpdateAvailable:
        [self install];
        break;
    case FBUpdateChecking:
    case FBUpdateDownloading:
        [self resetCancellable];
        [self discardPartial];
        ulog(@"cancelled");
        [self close];
        break;
    case FBUpdateFailed:
        if (installFailed) {
            installFailed = NO;
            [self install];
        } else
            [self close];
        break;
    default:
        [self close];
        break;
    }
}

- (void)middleClicked:(id)sender { (void)sender; [self close]; }   /* Later */

- (void)leftClicked:(id)sender                                      /* Skip This Version */
{
    (void)sender;
    if (state == FBUpdateAvailable && version) {
        [prefs() setObject:version forKey:PrefUpdateSkippedVersion];
        [prefs() synchronize];
        ulog(@"skipping %@", version);
    }
    [self close];
}

- (void)openNotes:(id)sender
{
    (void)sender;
    if (![notesURL length])
        return;
    if ([fbWindows count])
        [(FBWindowController *)[fbWindows objectAtIndex:0] addTabWithURL:[notesURL UTF8String] relatedTo:NULL select:YES];
    else
        openWindow([notesURL UTF8String]);
}

- (BOOL)windowShouldClose:(id)sender
{
    (void)sender;
    if (state == FBUpdateInstalling || state == FBUpdateRestarting)
        return NO;
    if (state == FBUpdateChecking || state == FBUpdateDownloading) {
        [self resetCancellable];
        [self discardPartial];
    }
    state = FBUpdateIdle;
    return YES;
}

/* ---- download and verification ---- */

- (void)cleanUpDownload
{
    if (stream) {
        g_object_unref(stream);
        stream = NULL;
    }
    if (fd >= 0) {
        close(fd);
        fd = -1;
    }
    if (sum) {
        g_checksum_free(sum);
        sum = NULL;
    }
}

- (void)discardPartial
{
    [self cleanUpDownload];
    if (dmgPath)
        unlink([[dmgPath stringByAppendingString:@".part"] fileSystemRepresentation]);
}

- (void)installFail:(NSString *)why
{
    [self discardPartial];
    if (mountPoint) {   /* never leave the image attached */
        const char *argv[] = { "/usr/bin/hdiutil", "detach", "-force", [mountPoint fileSystemRepresentation], NULL };
        GSubprocess *p = g_subprocess_newv(argv, G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_SILENCE, NULL);
        if (p)
            g_object_unref(p);
        [mountPoint release];
        mountPoint = nil;
    }
    if (newApp) {
        [[NSFileManager defaultManager] removeItemAtPath:newApp error:NULL];
        [newApp release];
        newApp = nil;
    }
    installFailed = YES;
    [self fail:why];
}

- (void)install
{
    [dmgPath release];
    dmgPath = [[updatesDir() stringByAppendingPathComponent:dmgName] retain];
    installFailed = NO;
    [self show:FBUpdateDownloading];
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:updatesDir() isDirectory:&isDir] || !isDir
        || access([updatesDir() fileSystemRepresentation], W_OK) != 0) {
        [self installFail:[NSString stringWithFormat:@"FrostByte can't write to its download folder (%@), so it can't "
                           "download the update.", [updatesDir() stringByAbbreviatingWithTildeInPath]]];
        return;
    }
    [self resetCancellable];
    sum = g_checksum_new(G_CHECKSUM_SHA256);
    received = 0;
    struct stat st;
    if (stat([dmgPath fileSystemRepresentation], &st) == 0 && (guint64)st.st_size == dmgSize) {
        /* downloaded before (Later, or a failed install): check it again rather than fetch it again */
        ulog(@"verifying the earlier download %@", dmgPath);
        GFile *f = g_file_new_for_path([dmgPath fileSystemRepresentation]);
        stream = G_INPUT_STREAM(g_file_read(f, NULL, NULL));
        g_object_unref(f);
        if (stream) {
            [self setStatus:@"Checking the downloaded update" busy:YES error:NO];
            g_input_stream_read_bytes_async(stream, kReadChunk, G_PRIORITY_DEFAULT, cancel, dmgRead, self);
            return;
        }
    }
    unlink([dmgPath fileSystemRepresentation]);
    NSString *part = [dmgPath stringByAppendingString:@".part"];
    fd = open([part fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        [self installFail:[NSString stringWithFormat:@"Couldn't save the download: %s", strerror(errno)]];
        return;
    }
    ulog(@"downloading %@", dmgURL);
    [self setStatus:[NSString stringWithFormat:str("Downloading FrostByte %@ (%.1f MB)\xe2\x80\xa6"), version, dmgSize / 1048576.0]
               busy:NO error:NO];
    if (msg)
        g_object_unref(msg);
    msg = soup_message_new("GET", [dmgURL UTF8String]);
    if (!msg) {
        [self installFail:@"The download address is malformed."];
        return;
    }
    soup_session_send_async([self session], msg, G_PRIORITY_DEFAULT, cancel, dmgResponse, self);
}

- (void)dmgResponseDone:(GAsyncResult *)res
{
    GError *error = NULL;
    GInputStream *in = soup_session_send_finish(session, res, &error);
    if (!in) {
        if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            [self installFail:[NSString stringWithFormat:@"The download failed: %@", str(error ? error->message : "?")]];
        g_clear_error(&error);
        return;
    }
    stream = in;
    guint code = soup_message_get_status(msg);
    char *final = g_uri_to_string(soup_message_get_uri(msg));
    BOOL secure = schemeAllowed(final);
    g_free(final);
    goffset length = soup_message_headers_get_content_length(soup_message_get_response_headers(msg));
    if (code != SOUP_STATUS_OK)
        [self installFail:[NSString stringWithFormat:@"The download server answered %u.", code]];
    else if (!secure)
        [self installFail:@"The download was redirected to an insecure address."];
    else if (length > 0 && (guint64)length != dmgSize)
        [self installFail:@"The download isn't the size the update information gives. It was not installed."];
    else
        g_input_stream_read_bytes_async(stream, kReadChunk, G_PRIORITY_DEFAULT, cancel, dmgRead, self);
}

- (void)dmgReadDone:(GAsyncResult *)res
{
    GError *error = NULL;
    GBytes *b = g_input_stream_read_bytes_finish(stream, res, &error);
    if (!b) {
        if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
            [self installFail:[NSString stringWithFormat:@"The download failed: %@", str(error ? error->message : "?")]];
        g_clear_error(&error);
        return;
    }
    gsize n = 0;
    const guchar *data = g_bytes_get_data(b, &n);
    if (n) {
        received += n;
        if (received > dmgSize) {
            g_bytes_unref(b);
            [self installFail:@"The download is larger than the update information says. It was not installed."];
            return;
        }
        g_checksum_update(sum, data, n);
        if (fd >= 0) {
            for (gsize off = 0; off < n; ) {
                ssize_t w = write(fd, data + off, n - off);
                if (w < 0 && errno == EINTR)
                    continue;
                if (w <= 0) {
                    g_bytes_unref(b);
                    [self installFail:[NSString stringWithFormat:@"Couldn't save the download: %s", strerror(errno)]];
                    return;
                }
                off += (gsize)w;
            }
            [self setStatus:[NSString stringWithFormat:str("Downloading\xe2\x80\xa6 %.1f of %.1f MB"),
                             received / 1048576.0, dmgSize / 1048576.0] busy:NO error:NO];
        }
        [bar setDoubleValue:(double)received / dmgSize];
        g_bytes_unref(b);
        g_input_stream_read_bytes_async(stream, kReadChunk, G_PRIORITY_DEFAULT, cancel, dmgRead, self);
        return;
    }
    g_bytes_unref(b);
    /* end of the stream: size and SHA-256 against the signed manifest */
    BOOL downloaded = fd >= 0;
    NSString *got = str(g_checksum_get_string(sum));
    guint64 total = received;
    if (downloaded && fsync(fd) != 0) {
        [self installFail:[NSString stringWithFormat:@"Couldn't save the download: %s", strerror(errno)]];
        return;
    }
    [self cleanUpDownload];
    NSString *part = [dmgPath stringByAppendingString:@".part"];
    if (total != dmgSize || ![got isEqual:dmgSHA]) {
        ulog(@"REFUSED: %@ is %llu bytes, SHA-256 %@; the manifest says %llu bytes, %@", dmgName, total, got, dmgSize, dmgSHA);
        unlink([(downloaded ? part : dmgPath) fileSystemRepresentation]);
        [self installFail:@"The downloaded disk image doesn't match its signed checksum, so it was deleted and not installed."];
        return;
    }
    if (downloaded && rename([part fileSystemRepresentation], [dmgPath fileSystemRepresentation]) != 0) {
        [self installFail:[NSString stringWithFormat:@"Couldn't save the download: %s", strerror(errno)]];
        return;
    }
    ulog(@"%@ verified: %llu bytes, SHA-256 %@", dmgName, total, got);
    [bar setDoubleValue:1];
    [self verified];
}

/* ---- install ---- */

- (void)runTool:(NSArray *)args then:(SEL)next
{
    const char **argv = g_new0(const char *, [args count] + 1);
    for (NSUInteger i = 0; i < [args count]; i++)
        argv[i] = [[args objectAtIndex:i] fileSystemRepresentation];
    GError *error = NULL;
    GSubprocess *p = g_subprocess_newv(argv, G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_MERGE, &error);
    g_free(argv);
    if (!p) {
        [self installFail:[NSString stringWithFormat:@"Couldn't run %@: %@", [args objectAtIndex:0], str(error ? error->message : "?")]];
        g_clear_error(&error);
        return;
    }
    toolNext = next;
    g_subprocess_communicate_utf8_async(p, NULL, NULL, toolDone, self);
}

- (void)toolDone:(GSubprocess *)p result:(GAsyncResult *)res
{
    char *out = NULL;
    GError *error = NULL;
    BOOL ok = g_subprocess_communicate_utf8_finish(p, res, &out, NULL, &error);
    int code = ok && g_subprocess_get_if_exited(p) ? g_subprocess_get_exit_status(p) : -1;
    NSString *output = [str(out ?: (error ? error->message : "")) stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    g_free(out);
    g_clear_error(&error);
    SEL next = toolNext;
    toolNext = NULL;
    if (next)
        [self performSelector:next withObject:[NSArray arrayWithObjects:[NSNumber numberWithInt:code], output, nil]];
}

- (void)verified
{
    NSString *blocker = installBlocker(dmgSize);
    if (blocker) {
        ulog(@"can't replace this copy (%@); opening the verified disk image instead", blocker);
        [[NSWorkspace sharedWorkspace] openFile:dmgPath];
        [self show:FBUpdateManual];
        [message setStringValue:[NSString stringWithFormat:
            @"%@ The update is verified and its disk image is open in the Finder: quit FrostByte, then drag "
             "FrostByte from the disk image to your Applications folder, replacing this copy.", blocker]];
        return;
    }
    [self show:FBUpdateInstalling];
    [self setStatus:@"Opening the disk image" busy:YES error:NO];
    [mountPoint release];
    mountPoint = [[updatesDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"mnt-%d", (int)getpid()]] retain];
    [[NSFileManager defaultManager] createDirectoryAtPath:mountPoint withIntermediateDirectories:YES attributes:nil error:NULL];
    [self runTool:[NSArray arrayWithObjects:@"/usr/bin/hdiutil", @"attach", @"-nobrowse", @"-readonly", @"-noautoopen",
                   @"-noverify", @"-mountpoint", mountPoint, dmgPath, nil] then:@selector(attached:)];
}

- (void)attached:(NSArray *)result
{
    if ([[result objectAtIndex:0] intValue] != 0) {
        NSString *out = [result objectAtIndex:1];
        [mountPoint release];
        mountPoint = nil;
        [self installFail:[NSString stringWithFormat:@"Couldn't open the disk image (hdiutil: %@).", out]];
        return;
    }
    /* the app on the image: this copy's identifier, the manifest's version */
    NSString *found = nil;
    for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:mountPoint error:NULL]) {
        NSString *p = [mountPoint stringByAppendingPathComponent:n];
        if (!isAppBundle(p))
            continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Contents/Info.plist"]];
        if ([[info objectForKey:@"CFBundleIdentifier"] isEqual:bundleID()]) {
            found = p;
            if (![[info objectForKey:@"CFBundleShortVersionString"] isEqual:version]) {
                [self installFail:[NSString stringWithFormat:@"The disk image holds FrostByte %@, not %@.",
                                   [info objectForKey:@"CFBundleShortVersionString"], version]];
                return;
            }
            NSString *exe = [info objectForKey:@"CFBundleExecutable"];
            if (![exe length] || access([[p stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:exe]]
                                        fileSystemRepresentation], X_OK) != 0) {
                [self installFail:@"The application on the disk image is incomplete."];
                return;
            }
            break;
        }
    }
    if (!found) {
        [self installFail:[NSString stringWithFormat:@"The disk image has no %@ application.", bundleID()]];
        return;
    }
    NSString *app = [[NSBundle mainBundle] bundlePath];
    NSString *dir = [app stringByDeletingLastPathComponent], *name = [app lastPathComponent];
    [newApp release];
    newApp = [[dir stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.new", name]] retain];
    [oldApp release];
    oldApp = [[dir stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.old", name]] retain];
    ulog(@"copying %@ to %@", found, newApp);
    [self setStatus:[NSString stringWithFormat:str("Copying FrostByte %@\xe2\x80\xa6"), version] busy:YES error:NO];
    [[NSFileManager defaultManager] removeItemAtPath:newApp error:NULL];
    [self runTool:[NSArray arrayWithObjects:@"/usr/bin/ditto", found, newApp, nil] then:@selector(copied:)];
}

- (void)copied:(NSArray *)result
{
    if ([[result objectAtIndex:0] intValue] != 0) {
        [self installFail:[NSString stringWithFormat:@"Couldn't copy the new FrostByte (ditto: %@).", [result objectAtIndex:1]]];
        return;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[newApp stringByAppendingPathComponent:@"Contents/Info.plist"]];
    if (![[info objectForKey:@"CFBundleShortVersionString"] isEqual:version]) {
        [self installFail:@"The copied application is incomplete."];
        return;
    }
    [self setStatus:@"Closing the disk image" busy:YES error:NO];
    [self runTool:[NSArray arrayWithObjects:@"/usr/bin/hdiutil", @"detach", mountPoint, nil] then:@selector(detached:)];
}

- (void)detached:(NSArray *)result
{
    if ([[result objectAtIndex:0] intValue] != 0) {   /* busy (Spotlight?): force it, but go on either way */
        ulog(@"detach: %@; forcing", [result objectAtIndex:1]);
        const char *argv[] = { "/usr/bin/hdiutil", "detach", "-force", [mountPoint fileSystemRepresentation], NULL };
        GSubprocess *p = g_subprocess_newv(argv, G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_SILENCE, NULL);
        if (p) {
            g_subprocess_wait(p, NULL, NULL);
            g_object_unref(p);
        }
    }
    rmdir([mountPoint fileSystemRepresentation]);
    [mountPoint release];
    mountPoint = nil;
    [self swapAndRelaunch];
}

/* The helper: waits for this process to exit, swaps the copies by renaming, opens the new one, and keeps the
 * old one until the new one confirms it started (else it puts the old one back). Its log: Updates/update.log. */
static const char kHelper[] =
    "pid=$1; app=$2; new=$3; old=$4; marker=$5\n"
    "echo \"$(date): waiting for FrostByte ($pid) to quit\"\n"
    "n=0; while kill -0 \"$pid\" 2>/dev/null; do sleep 1; n=$((n+1)); "
    "if [ $n -ge 120 ]; then echo 'it did not quit; update abandoned'; rm -rf \"$new\"; exit 1; fi; done\n"
    "rm -rf \"$old\"; [ -e \"$old\" ] && old=\"$old.$$\"\n"
    "if ! mv \"$app\" \"$old\"; then echo \"cannot move $app aside\"; rm -rf \"$new\"; open \"$app\"; exit 1; fi\n"
    "if ! mv \"$new\" \"$app\"; then echo 'cannot move the new copy in; restoring'; mv \"$old\" \"$app\"; open \"$app\"; exit 1; fi\n"
    "touch \"$app\"; echo \"$(date): swapped; opening $app\"; open \"$app\"\n"
    "n=0; while [ ! -e \"$marker\" ] && [ $n -lt 300 ]; do sleep 1; n=$((n+1)); done\n"
    "if [ -e \"$marker\" ]; then echo \"$(date): the new copy started; removing the old one\"; rm -f \"$marker\"; rm -rf \"$old\"; exit 0; fi\n"
    "if ps -axww -o command | grep -F \"$app/Contents/MacOS/\" | grep -v grep >/dev/null; then "
    "echo 'no confirmation, but the new copy is running; keeping it and the old one'; exit 0; fi\n"
    "echo \"$(date): the new copy did not start; putting the old one back\"\n"
    "mv \"$app\" \"$new\" && mv \"$old\" \"$app\" && rm -rf \"$new\"; open \"$app\"\n";

- (void)swapAndRelaunch
{
    NSString *app = [[NSBundle mainBundle] bundlePath];
    NSString *marker = [updatesDir() stringByAppendingPathComponent:@"started"];
    unlink([marker fileSystemRepresentation]);
    NSDictionary *pending = [NSDictionary dictionaryWithObjectsAndKeys:app, @"App", version, @"Version",
                             currentVersion(), @"PreviousVersion", marker, @"Marker", dmgPath, @"DiskImage", nil];
    if (![pending writeToFile:pendingFile() atomically:YES]) {
        [self installFail:@"Couldn't record the update in progress."];
        return;
    }
    NSString *log = [updatesDir() stringByAppendingPathComponent:@"update.log"];
    NSString *script = [NSString stringWithFormat:@"exec >>'%@' 2>&1\n%s",
                        [log stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"], kHelper];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:@"-c", script, @"sh",
                        [NSString stringWithFormat:@"%d", (int)getpid()], app, newApp, oldApp, marker, nil]];
    /* a plain environment: nothing this run set up for WebKit (or its bundle paths) reaches the new copy */
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    NSMutableDictionary *clean = [NSMutableDictionary dictionaryWithObject:@"/usr/bin:/bin:/usr/sbin:/sbin" forKey:@"PATH"];
    for (NSString *k in [NSArray arrayWithObjects:@"HOME", @"USER", @"LOGNAME", @"SHELL", @"TMPDIR", @"__CF_USER_TEXT_ENCODING", nil])
        if ([env objectForKey:k])
            [clean setObject:[env objectForKey:k] forKey:k];
    [task setEnvironment:clean];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    [task launch];
    ulog(@"installed %@ beside this copy; restarting into it (helper %d)", version, [task processIdentifier]);
    [self show:FBUpdateRestarting];
    [self setStatus:[NSString stringWithFormat:str("Restarting into FrostByte %@\xe2\x80\xa6"), version] busy:YES error:NO];
    [window displayIfNeeded];
    g_timeout_add(400, (GSourceFunc)terminateSoon, NULL);
}

static gboolean terminateSoon(gpointer unused)
{
    (void)unused;
    FB_POOL_BEGIN;
    [NSApp terminate:nil];
    FB_POOL_END;
    return G_SOURCE_REMOVE;
}

/* ---- after an update: the new copy's first launch ---- */

- (void)startupWithPending:(NSDictionary *)pending
{
    NSString *app = [[NSBundle mainBundle] bundlePath];
    NSString *v = [pending objectForKey:@"Version"], *marker = [pending objectForKey:@"Marker"];
    if (![[pending objectForKey:@"App"] isEqual:app])
        return;                                       /* another copy's update */
    unlink([pendingFile() fileSystemRepresentation]);
    if ([v isEqual:currentVersion()]) {
        ulog(@"now running %@ (updated from %@)", v, [pending objectForKey:@"PreviousVersion"]);
        if (marker)
            close(open([marker fileSystemRepresentation], O_WRONLY | O_CREAT, 0644));
        if ([pending objectForKey:@"DiskImage"])
            unlink([[pending objectForKey:@"DiskImage"] fileSystemRepresentation]);
        [prefs() removeObjectForKey:PrefUpdateSkippedVersion];
    } else {
        ulog(@"the update to %@ did not take; still %@", v, currentVersion());
        userInitiated = YES;
        installFailed = NO;
        [self show:FBUpdateFailed];
        [title setStringValue:[NSString stringWithFormat:@"FrostByte %@ wasn't installed", v]];
        [message setStringValue:[NSString stringWithFormat:
            @"The new copy didn't start, so FrostByte %@ was put back. The update log is in %@.",
            currentVersion(), [[updatesDir() stringByAppendingPathComponent:@"update.log"] stringByAbbreviatingWithTildeInPath]]];
        state = FBUpdateIdle;
    }
}

@end

static void manifestFetched(GObject *src, GAsyncResult *res, gpointer data)
{
    (void)src;
    FB_POOL_BEGIN;
    [(FBUpdater *)data manifestDone:res];
    FB_POOL_END;
}

static void signatureFetched(GObject *src, GAsyncResult *res, gpointer data)
{
    (void)src;
    FB_POOL_BEGIN;
    [(FBUpdater *)data signatureDone:res];
    FB_POOL_END;
}

static void dmgResponse(GObject *src, GAsyncResult *res, gpointer data)
{
    (void)src;
    FB_POOL_BEGIN;
    [(FBUpdater *)data dmgResponseDone:res];
    FB_POOL_END;
}

static void dmgRead(GObject *src, GAsyncResult *res, gpointer data)
{
    (void)src;
    FB_POOL_BEGIN;
    [(FBUpdater *)data dmgReadDone:res];
    FB_POOL_END;
}

static void toolDone(GObject *src, GAsyncResult *res, gpointer data)
{
    FB_POOL_BEGIN;
    [(FBUpdater *)data toolDone:G_SUBPROCESS(src) result:res];
    g_object_unref(src);
    FB_POOL_END;
}

/* ---- entry points ---- */

void fbCheckForUpdates(void) { [[FBUpdater shared] check:YES]; }

static gboolean automaticCheck(gpointer unused)
{
    (void)unused;
    FB_POOL_BEGIN;
    NSDate *last = [prefs() objectForKey:PrefUpdateLastCheck];
    BOOL due = testURLOverride() || ![last isKindOfClass:[NSDate class]] || -[last timeIntervalSinceNow] >= kCheckInterval
        || [last timeIntervalSinceNow] > 3600;      /* a clock set back */
    if ([prefs() boolForKey:PrefCheckForUpdates] && due && !(s_updater && [s_updater busy]))
        [[FBUpdater shared] check:NO];
    FB_POOL_END;
    return G_SOURCE_REMOVE;
}

static gboolean dailyTick(gpointer unused)
{
    (void)unused;
    FB_POOL_BEGIN;
    NSDate *last = [prefs() objectForKey:PrefUpdateLastCheck];
    if ([prefs() boolForKey:PrefCheckForUpdates] && [last isKindOfClass:[NSDate class]]
        && -[last timeIntervalSinceNow] >= kCheckInterval && !(s_updater && [s_updater busy]))
        [[FBUpdater shared] check:NO];
    FB_POOL_END;
    return G_SOURCE_CONTINUE;
}

static gboolean askedCheck(gpointer unused)
{
    (void)unused;
    FB_POOL_BEGIN;
    [[FBUpdater shared] check:YES];
    FB_POOL_END;
    return G_SOURCE_REMOVE;
}

/* Downloads this copy no longer needs: FrostByte-<version>-<build>.dmg(.part) no newer than the running version
 * (left by the Finder fallback, or by an update installed some other way). Newer ones stay for Install. */
static void removeStaleDownloads(void)
{
    NSString *dir = updatesDir(), *mine = currentVersion();
    for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
        if (![n hasPrefix:@"FrostByte-"] || (![n hasSuffix:@".dmg"] && ![n hasSuffix:@".dmg.part"]))
            continue;
        NSString *v = [[[n substringFromIndex:10] componentsSeparatedByString:@"-"] objectAtIndex:0];
        long parsed[4];
        if (parseVersion(v, parsed, YES) && compareVersions(v, mine) <= 0) {
            ulog(@"removing the old download %@", n);
            unlink([[dir stringByAppendingPathComponent:n] fileSystemRepresentation]);
        }
    }
}

/* At launch, after the first window: finish an update that just happened, then schedule the automatic check
 * (a little after start-up, then hourly for a FrostByte left running; each checks only if a day has passed). */
void fbUpdateStartup(void)
{
    NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:pendingFile()];
    if (pending)
        [[FBUpdater shared] startupWithPending:pending];
    removeStaleDownloads();
    if (testLaunchCheckAsked())
        g_timeout_add_seconds(5, (GSourceFunc)askedCheck, NULL);
    else
        g_timeout_add_seconds(testURLOverride() ? 5 : 30, automaticCheck, NULL);
    g_timeout_add_seconds(3600, dailyTick, NULL);
}
