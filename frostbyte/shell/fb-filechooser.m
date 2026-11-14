/*
 * FrostByte: <input type=file>. WebKit's run-file-chooser becomes an NSOpenPanel sheet on the tab's window.
 *
 * The input's 'accept' list (MIME types, image/-style wildcards and ".ext" extensions) greys out the files that
 * don't match, as Safari does; "Show all files" lifts that, since 'accept' is only a hint and Leopard's type
 * database predates many formats. The panel opens where the input's previous choice was, else where the
 * last panel was.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#import "frostbyte.h"

/* Formats Leopard's LaunchServices doesn't know (no UTI, so no MIME type to compare with). */
static NSString *fallbackMIMEType(NSString *extension)
{
    static NSDictionary *types;
    if (!types)
        types = [[NSDictionary alloc] initWithObjectsAndKeys:
            @"image/webp", @"webp", @"image/avif", @"avif", @"image/heic", @"heic", @"image/heif", @"heif",
            @"image/jxl", @"jxl", @"image/svg+xml", @"svg", @"image/x-icon", @"ico",
            @"video/webm", @"webm", @"video/x-matroska", @"mkv", @"video/ogg", @"ogv", @"video/mp4", @"m4v",
            @"audio/ogg", @"ogg", @"audio/ogg", @"oga", @"audio/opus", @"opus", @"audio/flac", @"flac",
            @"audio/webm", @"weba", @"audio/mp4", @"m4a", @"application/json", @"json", nil];
    return [types objectForKey:extension];
}

/* The UTI a wildcard such as image/ stands for. */
static CFStringRef wildcardUTI(NSString *prefix)
{
    if ([prefix isEqualToString:@"image/"]) return kUTTypeImage;
    if ([prefix isEqualToString:@"video/"]) return kUTTypeMovie;
    if ([prefix isEqualToString:@"audio/"]) return kUTTypeAudio;
    if ([prefix isEqualToString:@"text/"]) return kUTTypeText;
    return NULL;
}

@interface FBFileChooser : NSObject {
    WebKitFileChooserRequest *request;
    NSMutableArray *extensions;       /* lowercase, no dot */
    NSMutableArray *mimeTypes;        /* exact types, lowercase */
    NSMutableArray *wildcards;        /* "image/" for image/ * */
    NSButton *showAll;
}
- (id)initWithRequest:(WebKitFileChooserRequest *)r;
- (void)runSheetOnWindow:(NSWindow *)window;
@end

@implementation FBFileChooser

- (id)initWithRequest:(WebKitFileChooserRequest *)r
{
    if (!(self = [super init]))
        return nil;
    request = g_object_ref(r);
    extensions = [[NSMutableArray alloc] init];
    mimeTypes = [[NSMutableArray alloc] init];
    wildcards = [[NSMutableArray alloc] init];
    const gchar *const *list = webkit_file_chooser_request_get_file_extensions(request);
    for (; list && *list; list++)
        [extensions addObject:[[NSString stringWithUTF8String:*list] lowercaseString]];
    for (list = webkit_file_chooser_request_get_mime_types(request); list && *list; list++) {
        NSString *type = [[NSString stringWithUTF8String:*list] lowercaseString];
        if ([type hasSuffix:@"/*"])
            [wildcards addObject:[type substringToIndex:[type length] - 1]];
        else if ([type length])
            [mimeTypes addObject:type];
    }
    return self;
}

- (void)dealloc
{
    g_object_unref(request);
    [extensions release];
    [mimeTypes release];
    [wildcards release];
    [super dealloc];
}

- (BOOL)filtering { return [extensions count] || [mimeTypes count] || [wildcards count]; }

- (BOOL)acceptsMIMEType:(NSString *)type
{
    if (!type)
        return NO;
    type = [type lowercaseString];
    if ([mimeTypes containsObject:type])
        return YES;
    for (NSString *prefix in wildcards) {
        if ([type hasPrefix:prefix])
            return YES;
    }
    return NO;
}

- (BOOL)acceptsFile:(NSString *)path
{
    NSString *extension = [[path pathExtension] lowercaseString];
    if ([extension length] && [extensions containsObject:extension])
        return YES;
    if (![mimeTypes count] && ![wildcards count])
        return NO;
    if ([self acceptsMIMEType:fallbackMIMEType(extension)])
        return YES;
    if (![extension length])
        return NO;
    /* LaunchServices: the file's type, then conformance (public.jpeg is an image; image/jpg finds public.jpeg). */
    BOOL accepted = NO;
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (CFStringRef)extension, NULL);
    if (!uti)
        return NO;
    CFStringRef mime = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType);
    if (mime) {
        accepted = [self acceptsMIMEType:(NSString *)mime];
        CFRelease(mime);
    }
    for (NSString *type in mimeTypes) {
        if (accepted)
            break;
        CFStringRef wanted = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (CFStringRef)type, NULL);
        if (wanted) {
            accepted = ![(NSString *)wanted hasPrefix:@"dyn."] && UTTypeConformsTo(uti, wanted);
            CFRelease(wanted);
        }
    }
    for (NSString *prefix in wildcards) {
        if (accepted)
            break;
        CFStringRef wanted = wildcardUTI(prefix);
        accepted = wanted && UTTypeConformsTo(uti, wanted);
    }
    CFRelease(uti);
    return accepted;
}

/* NSOpenPanel delegate (10.5): files that don't match are shown greyed out. Folders stay open to browse into;
 * packages (.app, .rtfd) count as files. */
- (BOOL)panel:(id)sender shouldShowFilename:(NSString *)filename
{
    (void)sender;
    if ([showAll state] == NSOnState)
        return YES;
    BOOL directory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:filename isDirectory:&directory] && directory
        && ![[NSWorkspace sharedWorkspace] isFilePackageAtPath:filename])
        return YES;
    return [self acceptsFile:filename];
}

- (void)showAllChanged:(id)sender
{
    (void)sender;
    NSWindow *panel = [showAll window];   /* the accessory view's window is the panel */
    if ([panel isKindOfClass:[NSSavePanel class]])
        [(NSSavePanel *)panel validateVisibleColumns];
}

- (void)runSheetOnWindow:(NSWindow *)window
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setResolvesAliases:YES];
    [panel setAllowsMultipleSelection:webkit_file_chooser_request_get_select_multiple(request)];
    [panel setPrompt:@"Choose"];
    [panel setDelegate:nil];          /* in case AppKit hands back a panel used before */
    [panel setAccessoryView:nil];
    if ([self filtering]) {
        [panel setDelegate:self];
        showAll = [[[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)] autorelease];
        [showAll setButtonType:NSSwitchButton];
        [showAll setTitle:@"Show all files"];
        [showAll setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
        [[showAll cell] setControlSize:NSSmallControlSize];
        [showAll sizeToFit];
        [showAll setTarget:self];
        [showAll setAction:@selector(showAllChanged:)];
        NSView *accessory = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth([showAll frame]) + 40, 32)] autorelease];
        [showAll setFrameOrigin:NSMakePoint(20, 6)];
        [accessory addSubview:showAll];
        [panel setAccessoryView:accessory];
    }
    /* Start where the input's previous choice was (nil: where the last panel was). */
    NSString *directory = nil, *file = nil;
    const gchar *const *previous = webkit_file_chooser_request_get_selected_files(request);
    if (previous && previous[0]) {
        NSString *path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:previous[0]
                                                                                    length:strlen(previous[0])];
        directory = [path stringByDeletingLastPathComponent];
        file = [path lastPathComponent];
    }
    [self retain];   /* until the sheet ends */
    [panel beginSheetForDirectory:directory file:file types:nil modalForWindow:window modalDelegate:self
                   didEndSelector:@selector(openPanelDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void)openPanelDidEnd:(NSOpenPanel *)panel returnCode:(int)code contextInfo:(void *)info
{
    (void)info;
    [panel orderOut:nil];
    [panel setDelegate:nil];
    [showAll setTarget:nil];
    NSArray *chosen = code == NSOKButton ? [panel filenames] : nil;
    if ([chosen count]) {
        /* WebKit URL-decodes what it is given (%XX), so a literal % in a file name goes in as %25. */
        GPtrArray *paths = g_ptr_array_new_with_free_func(g_free);
        for (NSString *path in chosen) {
            gchar **parts = g_strsplit([path fileSystemRepresentation], "%", -1);
            g_ptr_array_add(paths, g_strjoinv("%25", parts));
            g_strfreev(parts);
        }
        g_ptr_array_add(paths, NULL);
        webkit_file_chooser_request_select_files(request, (const gchar *const *)paths->pdata);
        g_ptr_array_unref(paths);
    } else
        webkit_file_chooser_request_cancel(request);
    [self release];
}

@end

/* WebKitWebView::run-file-chooser for a tab (the signal's user data). */
gboolean fbRunFileChooser(WebKitWebView *view, WebKitFileChooserRequest *request, gpointer data)
{
    (void)view;
    FB_POOL_BEGIN;
    FBTab *tab = data;
    FBWindowController *owner = tab->owner;
    NSWindow *window = owner ? owner->window : nil;
    if (!window || [window attachedSheet]) {
        /* Another sheet (a file panel for another tab, a close-window question) is up: say no rather than queue. */
        webkit_file_chooser_request_cancel(request);
    } else {
        if (owner->current != tab)
            [owner selectTab:tab];    /* show the page that asked */
        FBFileChooser *chooser = [[FBFileChooser alloc] initWithRequest:request];
        [chooser runSheetOnWindow:window];
        [chooser release];
    }
    FB_POOL_END;
    return TRUE;
}
