/*
 * FrostByte browser shell, after Camino: browser windows with a tab strip in the title bar, a
 * toolbar (back, forward, reload, the combined address + search field, downloads, history, the
 * FrostByte menu), a bookmarks bar, a status bubble or bar, a Light / Dark appearance with an accent
 * colour, a Preferences window and the usual menus.
 *   FrostByte [url]
 * Preferences are NSUserDefaults (org.frostbyte.FrostByte), all registered in registerDefaults().
 * Environment (debugging; each wins over its preference): FROSTBYTE_SEARCH_URL ("%s" = escaped
 * query), FROSTBYTE_HOME_URL (the default home page), LEOPARD_WPE_GL, JSC_useJIT,
 * WEBKIT_CPU_RASTER_THREADS, FROSTBYTE_CONSOLE=1 (JS console to the log), FROSTBYTE_USER_SCRIPT=<file.js>
 * (injected at document start into every frame, for debugging).
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"

static GMainLoop *s_loop;
static void shutDownFrostByte(BOOL releaseDisplay);

/* ---- application controller: menus; actions go to the key window's controller ---- */

@interface FBAppController : NSObject
@end

@implementation FBAppController

- (FBWindowController *)current { return controllerForWindow([NSApp keyWindow]) ?: controllerForWindow([NSApp mainWindow]); }

- (void)newWindow:(id)sender { (void)sender; openWindow(NULL); }

- (void)newTab:(id)sender
{
    FBWindowController *c = [self current];
    if (c)
        [c newTab:sender];
    else
        openWindow(NULL);
}

- (void)showPreferences:(id)sender { (void)sender; [[FBPreferences shared] show]; }

- (void)showAbout:(id)sender { (void)sender; fbShowAbout(); }
- (void)checkForUpdates:(id)sender { (void)sender; fbCheckForUpdates(); }
- (void)showHistoryWindow:(id)sender { (void)sender; fbShowHistoryWindow(); }
- (void)showDownloadsWindow:(id)sender { (void)sender; fbShowDownloadsWindow(); }

- (void)forward:(SEL)action sender:(id)sender
{
    FBWindowController *c = [self current];
    if (c)
        [c performSelector:action withObject:sender];
}

- (void)goBack:(id)s { [self forward:_cmd sender:s]; }
- (void)goForward:(id)s { [self forward:_cmd sender:s]; }
- (void)reload:(id)s { [self forward:_cmd sender:s]; }
- (void)reloadIgnoringCache:(id)s { [self forward:_cmd sender:s]; }
- (void)stopLoading:(id)s { [self forward:_cmd sender:s]; }
- (void)goHome:(id)s { [self forward:_cmd sender:s]; }
- (void)makeTextBigger:(id)s { [self forward:_cmd sender:s]; }
- (void)makeTextSmaller:(id)s { [self forward:_cmd sender:s]; }
- (void)makeTextActualSize:(id)s { [self forward:_cmd sender:s]; }
- (void)focusLocation:(id)s { [self forward:_cmd sender:s]; }
- (void)focusSearch:(id)s { [self forward:_cmd sender:s]; }
- (void)closeCurrentTab:(id)s { [self forward:_cmd sender:s]; }
- (void)closeBrowserWindow:(id)s { [self forward:_cmd sender:s]; }
- (void)nextTab:(id)s { [self forward:_cmd sender:s]; }
- (void)previousTab:(id)s { [self forward:_cmd sender:s]; }
- (void)addBookmark:(id)s { [self forward:_cmd sender:s]; }
- (void)showHistory:(id)s { [self forward:_cmd sender:s]; }
- (void)showDownloads:(id)s { [self forward:_cmd sender:s]; }
- (void)showFind:(id)s { [self forward:_cmd sender:s]; }
- (void)findNext:(id)s { [self forward:_cmd sender:s]; }
- (void)findPrevious:(id)s { [self forward:_cmd sender:s]; }
- (void)viewSource:(id)s { [self forward:_cmd sender:s]; }
- (void)printPage:(id)s { [self forward:_cmd sender:s]; }
- (void)showFrostByteMenu:(id)s { [self forward:_cmd sender:s]; }

- (void)togglePreference:(NSString *)key
{
    [prefs() setBool:![prefs() boolForKey:key] forKey:key];
    applyLivePreferences();
}
- (void)toggleBookmarksBar:(id)s { (void)s; [self togglePreference:PrefShowBookmarksBar]; }
- (void)toggleStatusBar:(id)s { (void)s; [self togglePreference:PrefShowStatusBar]; }
- (void)setAppearanceLight:(id)s { (void)s; [prefs() setObject:@"Light" forKey:PrefAppearance]; applyLivePreferences(); }
- (void)setAppearanceDark:(id)s { (void)s; [prefs() setObject:@"Dark" forKey:PrefAppearance]; applyLivePreferences(); }

- (void)openBookmark:(NSMenuItem *)item
{
    const char *url = [[[item representedObject] objectForKey:@"URL"] UTF8String];
    FBWindowController *c = [self current];
    if (c)
        [c loadURL:url];
    else
        openWindow(url);
}

/* Bookmarks menu: the fixed items, then one item per bookmark. */
- (void)menuNeedsUpdate:(NSMenu *)menu
{
    while ([menu numberOfItems] > 3)
        [menu removeItemAtIndex:3];
    for (NSDictionary *b in fbBookmarks) {
        NSMenuItem *it = [menu addItemWithTitle:[b objectForKey:@"Title"] action:@selector(openBookmark:) keyEquivalent:@""];
        [it setTarget:self];
        [it setRepresentedObject:b];
    }
}

/* Edit menu items reach here only when no text field handled them, i.e. the page has focus. */
- (void)editing:(const char *)command
{
    FBWindowController *c = [self current];
    if (c && [c pageHasFocus])
        [c editingCommand:command];
}
- (void)copy:(id)s { (void)s; [self editing:WEBKIT_EDITING_COMMAND_COPY]; }
- (void)cut:(id)s { (void)s; [self editing:WEBKIT_EDITING_COMMAND_CUT]; }
- (void)paste:(id)s { (void)s; [self editing:WEBKIT_EDITING_COMMAND_PASTE]; }
- (void)selectAll:(id)s { (void)s; [self editing:WEBKIT_EDITING_COMMAND_SELECT_ALL]; }
- (void)undo:(id)s { (void)s; [self editing:WEBKIT_EDITING_COMMAND_UNDO]; }
- (void)redo:(id)s { (void)s; [self editing:WEBKIT_EDITING_COMMAND_REDO]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL a = [item action];
    if (a == @selector(toggleBookmarksBar:)) {
        [item setTitle:[prefs() boolForKey:PrefShowBookmarksBar] ? @"Hide Bookmarks Bar" : @"Show Bookmarks Bar"];
        return YES;
    }
    if (a == @selector(toggleStatusBar:)) {
        [item setTitle:[prefs() boolForKey:PrefShowStatusBar] ? @"Hide Status Bar" : @"Show Status Bar"];
        return YES;
    }
    if (a == @selector(setAppearanceLight:)) { [item setState:isDark() ? NSOffState : NSOnState]; return YES; }
    if (a == @selector(setAppearanceDark:)) { [item setState:isDark() ? NSOnState : NSOffState]; return YES; }
    if (a == @selector(newWindow:) || a == @selector(newTab:) || a == @selector(showAbout:)
        || a == @selector(showPreferences:) || a == @selector(openBookmark:)
        || a == @selector(showHistoryWindow:) || a == @selector(showDownloadsWindow:)
        || a == @selector(checkForUpdates:))
        return YES;
    FBWindowController *c = [self current];
    if (!c)
        return NO;
    if (a == @selector(copy:) || a == @selector(cut:) || a == @selector(paste:) || a == @selector(selectAll:)
        || a == @selector(undo:) || a == @selector(redo:))
        return [c pageHasFocus];
    return [c validateAction:a];
}

/* Dock icon clicked with no windows open. */
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible
{
    (void)app;
    if (!visible && ![fbWindows count])
        openWindow(NULL);
    return YES;
}

/* Quit (menu, Dock, and the kAEQuitApplication loginwindow sends for Log Out, Restart and Shut Down): shut
 * down here, synchronously, and answer Now. Answering Cancel (and leaving the GLib loop to finish later)
 * made AppKit reply userCanceledErr to the quit event, so loginwindow abandoned the restart even though
 * FrostByte then exited. Later is no option either: AppKit would spin a modal run loop beneath the GLib
 * loop that drives this process. The helpers (WPEWebProcess, WPENetworkProcess) leave when this process
 * exits (AuxiliaryProcessMain's parent watchdog). */
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{
    (void)app;
    shutDownFrostByte(NO);   /* AppKit exits the process next; the display stays for its notifications */
    return NSTerminateNow;
}

@end

static NSMenuItem *addItem(NSMenu *menu, NSString *title, SEL action, NSString *key, NSUInteger mods)
{
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:key];
    [item setKeyEquivalentModifierMask:mods];
    return item;
}

static NSMenu *addMenu(NSMenu *bar, NSString *title)
{
    NSMenuItem *holder = [bar addItemWithTitle:title action:NULL keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    [holder setSubmenu:menu];
    [menu release];
    return menu;
}

static void buildMenus(id controller)
{
    const NSUInteger cmd = NSCommandKeyMask, cmdShift = NSCommandKeyMask | NSShiftKeyMask;
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];

    NSMenu *app = addMenu(bar, @"FrostByte");
    addItem(app, @"About FrostByte", @selector(showAbout:), @"", 0);
    addItem(app, str("Check for Updates\xe2\x80\xa6"), @selector(checkForUpdates:), @"", 0);
    [app addItem:[NSMenuItem separatorItem]];
    addItem(app, str("Preferences\xe2\x80\xa6"), @selector(showPreferences:), @",", cmd);
    [app addItem:[NSMenuItem separatorItem]];
    NSMenu *services = [[[NSMenu alloc] initWithTitle:@"Services"] autorelease];
    [[app addItemWithTitle:@"Services" action:NULL keyEquivalent:@""] setSubmenu:services];
    [NSApp setServicesMenu:services];
    [app addItem:[NSMenuItem separatorItem]];
    addItem(app, @"Hide FrostByte", @selector(hide:), @"h", cmd);
    addItem(app, @"Hide Others", @selector(hideOtherApplications:), @"h", cmd | NSAlternateKeyMask);
    addItem(app, @"Show All", @selector(unhideAllApplications:), @"", 0);
    [app addItem:[NSMenuItem separatorItem]];
    addItem(app, @"Quit FrostByte", @selector(terminate:), @"q", cmd);
    if ([NSApp respondsToSelector:@selector(setAppleMenu:)])   /* still in AppKit, gone from the headers */
        [NSApp performSelector:@selector(setAppleMenu:) withObject:app];

    NSMenu *file = addMenu(bar, @"File");
    addItem(file, @"New Window", @selector(newWindow:), @"n", cmd);
    addItem(file, @"New Tab", @selector(newTab:), @"t", cmd);
    addItem(file, str("Open Location\xe2\x80\xa6"), @selector(focusLocation:), @"l", cmd);
    addItem(file, str("Search the Web\xe2\x80\xa6"), @selector(focusSearch:), @"k", cmd);
    [file addItem:[NSMenuItem separatorItem]];
    addItem(file, @"Close Window", @selector(closeBrowserWindow:), @"w", cmdShift);
    addItem(file, @"Close Tab", @selector(closeCurrentTab:), @"w", cmd);
    [file addItem:[NSMenuItem separatorItem]];
    addItem(file, str("Print\xe2\x80\xa6"), @selector(printPage:), @"p", cmd);

    NSMenu *edit = addMenu(bar, @"Edit");
    addItem(edit, @"Undo", @selector(undo:), @"z", cmd);
    addItem(edit, @"Redo", @selector(redo:), @"z", cmdShift);
    [edit addItem:[NSMenuItem separatorItem]];
    addItem(edit, @"Cut", @selector(cut:), @"x", cmd);
    addItem(edit, @"Copy", @selector(copy:), @"c", cmd);
    addItem(edit, @"Paste", @selector(paste:), @"v", cmd);
    addItem(edit, @"Select All", @selector(selectAll:), @"a", cmd);
    [edit addItem:[NSMenuItem separatorItem]];
    addItem(edit, str("Find in Page\xe2\x80\xa6"), @selector(showFind:), @"f", cmd);
    addItem(edit, @"Find Next", @selector(findNext:), @"g", cmd);
    addItem(edit, @"Find Previous", @selector(findPrevious:), @"g", cmdShift);

    NSMenu *view = addMenu(bar, @"View");
    addItem(view, @"Stop", @selector(stopLoading:), @".", cmd);
    addItem(view, @"Reload Page", @selector(reload:), @"r", cmd);
    addItem(view, @"Reload Ignoring Cache", @selector(reloadIgnoringCache:), @"r", cmdShift);
    [view addItem:[NSMenuItem separatorItem]];
    addItem(view, @"Make Page Bigger", @selector(makeTextBigger:), @"+", cmd);
    addItem(view, @"Make Page Smaller", @selector(makeTextSmaller:), @"-", cmd);
    addItem(view, @"Actual Size", @selector(makeTextActualSize:), @"0", cmd);
    [view addItem:[NSMenuItem separatorItem]];
    addItem(view, @"View Source", @selector(viewSource:), @"u", cmd | NSAlternateKeyMask);
    [view addItem:[NSMenuItem separatorItem]];
    addItem(view, @"Hide Bookmarks Bar", @selector(toggleBookmarksBar:), @"b", cmdShift);
    addItem(view, @"Hide Status Bar", @selector(toggleStatusBar:), @"/", cmd);
    NSMenuItem *appearanceItem = [view addItemWithTitle:@"Appearance" action:NULL keyEquivalent:@""];
    NSMenu *appearance = [[[NSMenu alloc] initWithTitle:@"Appearance"] autorelease];
    addItem(appearance, @"Light", @selector(setAppearanceLight:), @"", 0);
    addItem(appearance, @"Dark", @selector(setAppearanceDark:), @"", 0);
    [appearanceItem setSubmenu:appearance];

    NSMenu *go = addMenu(bar, @"Go");
    addItem(go, @"Back", @selector(goBack:), @"[", cmd);
    addItem(go, @"Forward", @selector(goForward:), @"]", cmd);
    addItem(go, @"Home", @selector(goHome:), @"h", cmdShift);
    [go addItem:[NSMenuItem separatorItem]];
    addItem(go, @"History", @selector(showHistoryWindow:), @"y", cmd);
    addItem(go, @"Downloads", @selector(showDownloadsWindow:), @"l", cmd | NSAlternateKeyMask);

    NSMenu *bookmarks = addMenu(bar, @"Bookmarks");
    addItem(bookmarks, @"Add Bookmark", @selector(addBookmark:), @"d", cmd);
    addItem(bookmarks, @"Show/Hide Bookmarks Bar", @selector(toggleBookmarksBar:), @"", 0);
    [bookmarks addItem:[NSMenuItem separatorItem]];
    [bookmarks setDelegate:controller];

    NSMenu *window = addMenu(bar, @"Window");
    addItem(window, @"Minimize", @selector(performMiniaturize:), @"m", cmd);
    addItem(window, @"Zoom", @selector(performZoom:), @"", 0);
    [window addItem:[NSMenuItem separatorItem]];
    addItem(window, @"Select Previous Tab", @selector(previousTab:), @"{", cmd);
    addItem(window, @"Select Next Tab", @selector(nextTab:), @"}", cmd);
    [window addItem:[NSMenuItem separatorItem]];
    addItem(window, @"Bring All to Front", @selector(arrangeInFront:), @"", 0);
    [NSApp setWindowsMenu:window];

    NSMenu *help = addMenu(bar, @"Help");
    addItem(help, @"PowerPC on Wikipedia", @selector(goHome:), @"", 0);

    [NSApp setMainMenu:bar];
    [bar release];
}

static gboolean reapplyIcon(gpointer icon)
{
    FB_POOL_BEGIN;
    [NSApp setApplicationIconImage:(NSImage *)icon];
    [(NSImage *)icon release];
    FB_POOL_END;
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv)
{
    /* First non-option argument is a URL to open. Skip the Finder/Dock's -psn_0_<n> process serial
     * number and any other -options, so a normal launch opens the homepage. */
    /* The WebGL capability probe (fb-webgl-probe.c): a helper run of this executable, without AppKit. */
    if (argc > 1 && !strcmp(argv[1], "--gl33-probe"))
        return fbWebGLProbeMain();
    const char *url = NULL;
    for (int i = 1; i < argc && !url; i++)
        if (argv[i][0] && argv[i][0] != '-')
            url = argv[i];
    {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        registerDefaults();
        applyStartupPreferences();   /* before any WebKit process exists */
        [pool release];
    }
    s_loop = g_main_loop_new(NULL, FALSE);

    GError *error = NULL;
    fbDisplay = wpe_display_cocoa_new();
    if (!wpe_display_connect(fbDisplay, &error)) {
        fprintf(stderr, "frostbyte: cannot connect the Cocoa display: %s\n", error ? error->message : "?");
        return 1;
    }
    /* Browser windows own their toplevels and hold several views (tabs) each. */
    if (!wpe_settings_set_boolean(wpe_display_get_settings(fbDisplay), WPE_SETTING_CREATE_VIEWS_WITH_A_TOPLEVEL,
                                  FALSE, WPE_SETTINGS_SOURCE_APPLICATION, &error)) {
        fprintf(stderr, "frostbyte: cannot turn off per-view toplevels: %s\n", error ? error->message : "?");
        return 1;
    }

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    setPageDarkMode();               /* prefers-color-scheme follows the appearance */
    /* site icons for the tabs (off by default in WebKit) */
    webkit_website_data_manager_set_favicons_enabled(
        webkit_network_session_get_website_data_manager(webkit_network_session_get_default()), TRUE);
    /* Resources: Contents/Resources in FrostByte.app, or a Resources directory beside a bare binary. */
    NSString *exe = [[NSString stringWithUTF8String:argv[0]] stringByStandardizingPath];
    NSString *beside = [[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Resources"];
    BOOL isDir = NO;
    BOOL besideExists = [[NSFileManager defaultManager] fileExistsAtPath:beside isDirectory:&isDir] && isDir;
    fbResourceDir = [(besideExists ? beside : [[NSBundle mainBundle] resourcePath]) retain];

    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:[fbResourceDir stringByAppendingPathComponent:@"FrostByte.icns"]];
    if (icon) {
        /* Bundled, the Dock takes CFBundleIconFile; for a bare binary this is the best effort. */
        [NSApp setApplicationIconImage:icon];
        g_timeout_add(1500, reapplyIcon, icon);
    }
    fbWindows = [[NSMutableArray alloc] init];
    loadBookmarks();
    loadHistory();
    setUpDownloads();
    FBAppController *controller = [[FBAppController alloc] init];
    [NSApp setDelegate:controller];
    buildMenus(controller);
    openWindow(url);
    fbUpdateStartup();
    [pool release];

    g_main_loop_run(s_loop);
    shutDownFrostByte(YES);
    return 0;
}

/* Close the windows (their WebKit views), save state, and let WebKit's deferred work run. Called from
 * applicationShouldTerminate: before AppKit exits the process, or after the main loop ends; runs once. */
static void shutDownFrostByte(BOOL releaseDisplay)
{
    static BOOL done;
    if (done)
        return;
    done = YES;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    while ([fbWindows count])
        [(FBWindowController *)[fbWindows lastObject] closeWindow];
    [prefs() synchronize];
    saveHistoryNow();
    [pool release];
    for (int i = 0; i < 1000 && g_main_context_iteration(NULL, FALSE); i++)   /* run the deferred unrefs */
        ;
    if (s_loop && g_main_loop_is_running(s_loop))
        g_main_loop_quit(s_loop);
    if (releaseDisplay && fbDisplay) {
        g_object_unref(fbDisplay);
        fbDisplay = NULL;
    }
}

