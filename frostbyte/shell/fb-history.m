/*
 * FrostByte: history (pages visited, kept as a property list) and downloads (to ~/Downloads, listed
 * by the toolbar's Downloads button).
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"

/* ---- history: ~/Library/Application Support/FrostByte/History.plist, an array of
 *      { URL, Title, Date (NSDate, the last visit), Visits (NSNumber) }, most recent first ---- */

static NSMutableArray *s_history;
static guint s_saveSource;
static const NSUInteger kHistoryLimit = 3000;

static NSString *historyPath(void)
{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *dir = [([dirs count] ? [dirs objectAtIndex:0] : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"])
                     stringByAppendingPathComponent:@"FrostByte"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"History.plist"];
}

void loadHistory(void)
{
    NSArray *saved = [NSArray arrayWithContentsOfFile:historyPath()];
    s_history = [[NSMutableArray alloc] init];
    for (NSDictionary *d in saved)
        [s_history addObject:[[d mutableCopy] autorelease]];
}

static gboolean saveHistory(gpointer data)
{
    (void)data;
    FB_POOL_BEGIN;
    s_saveSource = 0;
    if (![s_history writeToFile:historyPath() atomically:YES])
        fprintf(stderr, "frostbyte: cannot write %s\n", [historyPath() UTF8String]);
    FB_POOL_END;
    return G_SOURCE_REMOVE;
}

NSString *const FBHistoryChangedNotification = @"FBHistoryChanged";

static void saveSoon(void)
{
    [[NSNotificationCenter defaultCenter] postNotificationName:FBHistoryChangedNotification object:nil];
    if (!s_saveSource)
        s_saveSource = g_timeout_add_seconds(3, saveHistory, NULL);
}

void saveHistoryNow(void)
{
    if (s_saveSource) {
        g_source_remove(s_saveSource);
        saveHistory(NULL);
    }
}

static BOOL worthRemembering(const char *uri)
{
    return uri && *uri && (!g_ascii_strncasecmp(uri, "http://", 7) || !g_ascii_strncasecmp(uri, "https://", 8)
                           || !g_ascii_strncasecmp(uri, "file://", 7));
}

static NSMutableDictionary *entryFor(NSString *url)
{
    for (NSMutableDictionary *d in s_history)
        if ([[d objectForKey:@"URL"] isEqual:url])
            return d;
    return nil;
}

void historyNoteVisit(const char *uri, const char *title)
{
    if (!worthRemembering(uri))
        return;
    NSString *url = str(uri);
    NSMutableDictionary *d = entryFor(url);
    if (d) {
        [[d retain] autorelease];
        [s_history removeObjectIdenticalTo:d];
        [d setObject:[NSNumber numberWithInteger:[[d objectForKey:@"Visits"] integerValue] + 1] forKey:@"Visits"];
    } else
        d = [NSMutableDictionary dictionaryWithObjectsAndKeys:url, @"URL", [NSNumber numberWithInteger:1], @"Visits", nil];
    if (title && *title)
        [d setObject:str(title) forKey:@"Title"];
    [d setObject:[NSDate date] forKey:@"Date"];
    [s_history insertObject:d atIndex:0];
    while ([s_history count] > kHistoryLimit)
        [s_history removeLastObject];
    saveSoon();
}

void historyNoteTitle(const char *uri, const char *title)
{
    if (!worthRemembering(uri) || !title || !*title)
        return;
    NSMutableDictionary *d = entryFor(str(uri));
    if (d && ![[d objectForKey:@"Title"] isEqual:str(title)]) {
        [d setObject:str(title) forKey:@"Title"];
        saveSoon();
    }
}

void clearHistory(void)
{
    [s_history removeAllObjects];
    saveSoon();
}

NSArray *allHistory(void) { return s_history; }

void removeHistoryEntries(NSArray *entries)
{
    for (id d in entries)
        [s_history removeObjectIdenticalTo:d];
    saveSoon();
}

NSArray *recentHistory(NSUInteger max)
{
    return [s_history subarrayWithRange:NSMakeRange(0, MIN(max, [s_history count]))];
}

/* The address without its scheme and "www.", for matching and for showing. */
NSString *displayURL(NSString *url)
{
    NSString *s = url;
    NSRange r = [s rangeOfString:@"://"];
    if (r.location != NSNotFound && r.location < 8)
        s = [s substringFromIndex:NSMaxRange(r)];
    if ([s hasPrefix:@"www."])
        s = [s substringFromIndex:4];
    if ([s hasSuffix:@"/"] && [[s componentsSeparatedByString:@"/"] count] == 2)
        s = [s substringToIndex:[s length] - 1];
    return s;
}

/* Entries whose address or title contains every word of text: addresses that start with it first,
 * then by visits and recency. { URL, Title, Score } */
NSArray *historyMatches(NSString *text, NSUInteger max)
{
    NSArray *words = [[text lowercaseString] componentsSeparatedByString:@" "];
    NSMutableArray *found = [NSMutableArray array];
    NSString *lower = [text lowercaseString];
    NSUInteger rank = 0;
    for (NSDictionary *d in s_history) {
        rank++;
        NSString *url = [displayURL([d objectForKey:@"URL"]) lowercaseString];
        NSString *title = [[d objectForKey:@"Title"] lowercaseString] ?: @"";
        BOOL all = YES;
        for (NSString *w in words)
            if ([w length] && [url rangeOfString:w].location == NSNotFound && [title rangeOfString:w].location == NSNotFound) {
                all = NO;
                break;
            }
        if (!all)
            continue;
        double score = [[d objectForKey:@"Visits"] doubleValue] + 50.0 / rank;
        if ([url hasPrefix:lower])
            score += 1000;
        [found addObject:[NSDictionary dictionaryWithObjectsAndKeys:[d objectForKey:@"URL"], @"URL",
                          [d objectForKey:@"Title"] ?: @"", @"Title", [NSNumber numberWithDouble:score], @"Score", nil]];
    }
    [found sortUsingDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"Score" ascending:NO] autorelease]]];
    return [found subarrayWithRange:NSMakeRange(0, MIN(max, [found count]))];
}

/* ---- downloads ---- */

NSMutableArray *fbDownloads;

@implementation FBDownload

- (void)dealloc
{
    if (download) {
        g_signal_handlers_disconnect_by_data(download, self);
        g_object_unref(download);
    }
    [name release];
    [path release];
    [super dealloc];
}

- (NSString *)status
{
    double mb = received / 1048576.0;
    switch (state) {
    case FBDownloadActive:
        return progress > 0 ? [NSString stringWithFormat:@"%.1f MB, %d%%", mb, (int)(progress * 100)]
                            : [NSString stringWithFormat:@"%.1f MB", mb];
    case FBDownloadDone: return [NSString stringWithFormat:@"%.1f MB, done", mb];
    case FBDownloadCancelled: return @"Cancelled";
    default: return @"Failed";
    }
}

@end

NSString *const FBDownloadsChangedNotification = @"FBDownloadsChanged";

static void downloadsChanged(void)
{
    for (FBWindowController *c in fbWindows)
        [c downloadsChanged];
    [[NSNotificationCenter defaultCenter] postNotificationName:FBDownloadsChangedNotification object:nil];
}

double downloadsProgress(void)
{
    double sum = 0;
    int n = 0;
    for (FBDownload *d in fbDownloads)
        if (d->state == FBDownloadActive) {
            sum += d->progress;
            n++;
        }
    return n ? sum / n : -1;
}

static NSString *downloadsDirectory(void)
{
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

static gboolean downloadDecideDestination(WebKitDownload *download, const char *suggested, gpointer data)
{
    FB_POOL_BEGIN;
    FBDownload *d = data;
    NSString *base = [str(suggested && *suggested ? suggested : "download") lastPathComponent];
    if (![base length] || [base hasPrefix:@"."])
        base = [@"download" stringByAppendingString:base];
    NSString *dir = downloadsDirectory();
    NSString *stem = [base stringByDeletingPathExtension], *ext = [base pathExtension];
    if ([[[stem pathExtension] lowercaseString] isEqual:@"tar"]) {        /* name (2).tar.gz, not name.tar (2).gz */
        ext = [[stem pathExtension] stringByAppendingPathExtension:ext];
        stem = [stem stringByDeletingPathExtension];
    }
    NSString *path = [dir stringByAppendingPathComponent:base];
    for (int i = 2; [[NSFileManager defaultManager] fileExistsAtPath:path] && i < 1000; i++) {
        NSString *n = [NSString stringWithFormat:@"%@ (%d)", stem, i];
        path = [dir stringByAppendingPathComponent:[ext length] ? [n stringByAppendingPathExtension:ext] : n];
    }
    [d->name release];
    d->name = [[path lastPathComponent] retain];
    [d->path release];
    d->path = [path retain];
    webkit_download_set_destination(download, [path fileSystemRepresentation]);
    fprintf(stderr, "frostbyte: download to %s\n", [path fileSystemRepresentation]);
    downloadsChanged();
    FB_POOL_END;
    return TRUE;
}

static void downloadProgress(WebKitDownload *download, GParamSpec *p, gpointer data)
{
    (void)p;
    FB_POOL_BEGIN;
    FBDownload *d = data;
    d->progress = webkit_download_get_estimated_progress(download);
    d->received = webkit_download_get_received_data_length(download);
    downloadsChanged();
    FB_POOL_END;
}

static void downloadFinished(WebKitDownload *download, gpointer data)
{
    FB_POOL_BEGIN;
    FBDownload *d = data;
    d->received = webkit_download_get_received_data_length(download);
    if (d->state == FBDownloadActive) {
        d->state = FBDownloadDone;
        d->progress = 1;
    }
    fprintf(stderr, "frostbyte: download %s: %s\n", d->state == FBDownloadDone ? "finished" : "ended", [d->name UTF8String]);
    downloadsChanged();
    FB_POOL_END;
}

static void downloadFailed(WebKitDownload *download, GError *error, gpointer data)
{
    (void)download;
    FB_POOL_BEGIN;
    FBDownload *d = data;
    d->state = g_error_matches(error, WEBKIT_DOWNLOAD_ERROR, WEBKIT_DOWNLOAD_ERROR_CANCELLED_BY_USER)
        ? FBDownloadCancelled : FBDownloadFailed;
    fprintf(stderr, "frostbyte: download failed: %s\n", error ? error->message : "?");
    downloadsChanged();
    FB_POOL_END;
}

static void downloadStarted(WebKitNetworkSession *session, WebKitDownload *download, gpointer data)
{
    (void)session; (void)data;
    WebKitURIRequest *request = webkit_download_get_request(download);
    fprintf(stderr, "frostbyte: download started: %s\n", request ? webkit_uri_request_get_uri(request) : "?");
    FB_POOL_BEGIN;
    FBDownload *d = [[[FBDownload alloc] init] autorelease];
    d->download = g_object_ref(download);
    d->name = [str("Starting\xe2\x80\xa6") retain];
    d->state = FBDownloadActive;
    [fbDownloads insertObject:d atIndex:0];
    webkit_download_set_allow_overwrite(download, FALSE);
    g_signal_connect(download, "decide-destination", G_CALLBACK(downloadDecideDestination), d);
    g_signal_connect(download, "notify::estimated-progress", G_CALLBACK(downloadProgress), d);
    g_signal_connect(download, "finished", G_CALLBACK(downloadFinished), d);
    g_signal_connect(download, "failed", G_CALLBACK(downloadFailed), d);
    downloadsChanged();
    FB_POOL_END;
}

void setUpDownloads(void)
{
    fbDownloads = [[NSMutableArray alloc] init];
    g_signal_connect(webkit_network_session_get_default(), "download-started", G_CALLBACK(downloadStarted), NULL);
}

void cancelDownload(FBDownload *d)
{
    if (d->state == FBDownloadActive && d->download)
        webkit_download_cancel(d->download);
}

void clearFinishedDownloads(void)
{
    for (FBDownload *d in [[fbDownloads copy] autorelease])
        if (d->state != FBDownloadActive)
            [fbDownloads removeObjectIdenticalTo:d];
    downloadsChanged();
}

void revealDownload(FBDownload *d)
{
    if (d->path && [[NSFileManager defaultManager] fileExistsAtPath:d->path])
        [[NSWorkspace sharedWorkspace] selectFile:d->path inFileViewerRootedAtPath:@""];
    else
        [[NSWorkspace sharedWorkspace] openFile:downloadsDirectory()];
}

void openDownload(FBDownload *d)
{
    if (d->state == FBDownloadDone && d->path && [[NSFileManager defaultManager] fileExistsAtPath:d->path])
        [[NSWorkspace sharedWorkspace] openFile:d->path];
    else
        revealDownload(d);
}

void openDownloadsFolder(void) { [[NSWorkspace sharedWorkspace] openFile:downloadsDirectory()]; }
