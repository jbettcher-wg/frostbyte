/*
 * FrostByte shell: what the shell's files share.
 *   frostbyte-shell.m  application controller, menus, main()
 *   fb-defaults.m      preference keys and defaults, resources, search, typed-URL handling
 *   fb-hardware.m      hardware detection and the startup switches (environment for WebKit)
 *   fb-window.m        FBTab, FBWindowController, the list of browser windows
 *   fb-chrome.m        palettes, drawing helpers and icons, the tab strip, toolbar buttons, the status bar
 *   fb-bookmarks.m     bookmarks and the bookmarks bar
 *   fb-preferences.m   the Preferences window
 *   fb-about.m         the About window (the frosting window onto the pines)
 *   fb-update.m        Software Update: the signed release manifest, download, verify, replace and relaunch
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#ifndef FROSTBYTE_H
#define FROSTBYTE_H

#import <Cocoa/Cocoa.h>
#include <objc/runtime.h>
#include <wpe/webkit.h>
#include <libsoup/soup.h>
#include <stdio.h>
#include <string.h>
#include "../platform/wpe-cocoa.h"

#define FROSTBYTE_VERSION "0.3.3"

/* GLib's loop (WebKit's signals) calls into Cocoa outside any AppKit autorelease pool. */
#define FB_POOL_BEGIN NSAutoreleasePool *fbPool = [[NSAutoreleasePool alloc] init]
#define FB_POOL_END [fbPool release]

static const CGFloat kStripHeight = 40;           /* the tab strip, in the title bar */
static const CGFloat kToolbarHeight = 46;
static const CGFloat kBookmarksBarHeight = 28;
static const CGFloat kStatusBarHeight = 20;
static const CGFloat kChromeFontSize = 12;        /* tab titles */

/* ---- preferences (NSUserDefaults keys, fb-defaults.m; README 20.6) ---- */
extern NSString *const PrefHomePage;
extern NSString *const PrefSearchProvider;             /* Google | DuckDuckGo | Bing | Wikipedia | Startpage | Custom */
extern NSString *const PrefSearchCustomURL;            /* template with %s */
extern NSString *const PrefNewWindowPage;              /* Home | Blank */
extern NSString *const PrefNewTabPage;                 /* Home | Blank */
extern NSString *const PrefNewWindowLinksIn;           /* Tab | Window: target=_blank, window.open */
extern NSString *const PrefCommandClickBackground;
extern NSString *const PrefSelectNewTabs;              /* tabs opened by target=_blank / window.open */
extern NSString *const PrefWarnClosingTabs;
extern NSString *const PrefAppearance;                 /* Light | Dark */
extern NSString *const PrefAccentColor;                /* Default | #rrggbb: focus ring, progress */
extern NSString *const PrefShowBookmarksBar;
extern NSString *const PrefShowStatusBar;              /* NO: a hover-link bubble over the page instead */
extern NSString *const PrefSearchSuggestions;          /* BOOL: ask the search provider while typing */
extern NSString *const PrefGraphics;                   /* Auto | On | Off  (next launch) */
extern NSString *const PrefZeroCopy;                   /* (next launch) */
extern NSString *const PrefVideoDecoding;              /* Auto | On | Off: UVD H.264 decoding (rdnvdh264dec) */
extern NSString *const PrefPreferH264;                 /* BOOL: with hardware decoding on, steer sites to H.264 */
extern NSString *const PrefJIT;                        /* (next launch) */
extern NSString *const PrefRasterThreads;              /* 0 = automatic, 1..16 (next launch) */
extern NSString *const PrefBytecodeCache;              /* BOOL: JSC bytecode cache on disk (next launch) */
extern NSString *const PrefBytecodeCacheMB;            /* its size cap, MB; trimmed at startup */
NSString *fbBytecodeCacheDirectory(void);
unsigned long long fbBytecodeCacheSize(void);
void fbEmptyBytecodeCache(void);

static inline NSString *str(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }
static inline NSUserDefaults *prefs(void) { return [NSUserDefaults standardUserDefaults]; }
static inline BOOL prefIs(NSString *key, NSString *value) { return [[prefs() stringForKey:key] caseInsensitiveCompare:value] == NSOrderedSame; }
static inline BOOL isDark(void) { return prefIs(PrefAppearance, @"Dark"); }
static inline NSColor *gray(CGFloat w) { return [NSColor colorWithCalibratedWhite:w alpha:1]; }
static inline NSColor *grayA(CGFloat w, CGFloat a) { return [NSColor colorWithCalibratedWhite:w alpha:a]; }

/* fb-defaults.m */
extern NSString *fbResourceDir;
void registerDefaults(void);
NSImage *resourceImage(NSString *relativePath);
NSArray *searchProviderNames(void);                     /* the built-in providers, in menu order */
NSString *searchProviderName(void);
const char *homeURL(void);
char *searchURLFor(const char *query);                  /* g_malloc'd */
char *urlForLocationText(const char *text);             /* g_malloc'd, NULL for nothing */
gboolean unrefLater(gpointer object);                   /* a GSourceFunc */

/* fb-hardware.m */
typedef struct {
    BOOL radeon;          /* the RadeonNI accelerated GL renderer is present */
    BOOL sharedBuffers;   /* its LeopardGPU shared-buffer API works (zero-copy frames) */
    char renderer[128];   /* the card: RadeonNI's IORegistry model, else GL_RENDERER; "" if none */
    BOOL uvd;             /* a Radeon framebuffer whose driver carries UVD firmware */
    BOOL uvdSessions;     /* ... and has video decode sessions switched on */
    BOOL accelerated;     /* some accelerated GL renderer, any vendor (G5: Apple's NVIDIA/ATI drivers) */
} FBGraphicsCapabilities;
extern FBGraphicsCapabilities fbGraphics;               /* detected at startup */
/* Build profile (frostbyte/build.sh): the g5/generic builds let Automatic graphics pick the GPU tier on any
 * accelerated renderer (LeopardEGL's gl21 tier presents GLES 2.0 over Apple's GL 2.1 drivers); the t4240
 * build keeps it to the RadeonNI renderer. */
#ifndef FROSTBYTE_GL_ANY_ACCELERATED
#define FROSTBYTE_GL_ANY_ACCELERATED 0
#endif
extern BOOL fbGPUActive, fbZeroCopyActive;              /* what this run uses */
extern BOOL fbHardwareVideoActive;                      /* UVD decoding on in this run */
void applyStartupPreferences(void);
void relaunch(void);

/* fb-chrome.m: the colours of the current appearance (Light / Dark, the accent preference) */
typedef struct {
    NSColor *stripTop, *stripBottom;  /* the tab strip (a gradient in Light) */
    NSColor *bar;                     /* toolbar, bookmarks bar, the selected tab */
    NSColor *page, *field, *fieldBorder;
    NSColor *text, *textSoft, *tabIdleText, *icon, *iconOff;
    NSColor *divider, *popup, *popupBorder, *track, *hover;
    NSColor *buttonHover, *buttonPressed;   /* translucent, over any of the above */
    NSColor *accent;
} FBPalette;
const FBPalette *palette(void);
void paletteChanged(void);                              /* the appearance or the accent changed */
NSColor *colorFromHex(NSString *hex);                   /* "#rrggbb", nil if malformed */
NSArray *accentChoices(void);                           /* { Title, Value } for the Preferences popup */

void fillGradient(NSRect r, NSColor *top, NSColor *bottom);
void hline(CGFloat x0, CGFloat x1, CGFloat y, NSColor *c);
void drawImageUpright(NSImage *image, NSRect r, CGFloat fraction);   /* right way up in flipped views too */
NSImage *appIcon(void);                                 /* the ice cube */
NSImage *genericPageIcon(BOOL dark);                    /* a page with a folded corner, 16 x 16 */
void dragWindow(NSWindow *w, NSEvent *down);            /* move the window with the mouse until it goes up */

/* Vector icons after the design (16 pt grid, drawn in a flipped view). */
typedef enum {
    FBIconNone, FBIconBack, FBIconForward, FBIconReload, FBIconStop, FBIconDownloads, FBIconHistory,
    FBIconStar, FBIconSearch, FBIconLock, FBIconClose, FBIconPlus, FBIconLeft, FBIconRight
} FBIcon;
void drawIcon(FBIcon icon, NSPoint topLeft, NSColor *color, BOOL filled);
NSSize iconSize(FBIcon icon);

/* A borderless toolbar button: hover and pressed plates, an icon (or an image), accessibility label. */
@interface FBToolButton : NSButton {
@public
    FBIcon icon;
    NSImage *picture;                 /* instead of an icon (the menu button's ice cube) */
    CGFloat pictureSize;
    BOOL hover, filled, popsOnMouseDown, round;
    CGFloat progress;                 /* >= 0: a thin progress line along the bottom (downloads) */
    NSTrackingArea *tracking;
}
+ (FBToolButton *)buttonWithIcon:(FBIcon)icon label:(NSString *)label tip:(NSString *)tip
                          target:(id)target action:(SEL)action;
- (void)setLabel:(NSString *)label tip:(NSString *)tip;
@end

/* fb-bookmarks.m: NSDictionary { Title, URL } */
extern NSMutableArray *fbBookmarks;
NSDictionary *makeBookmark(NSString *title, NSString *url);
void loadBookmarks(void);
void bookmarksChanged(void);
NSImage *bookmarkIcon(NSString *url, BOOL *dark);       /* the site's icon, nil until known (it is fetched) */
void bookmarkIconSeen(const char *pageURI, NSImage *icon, BOOL dark);   /* a tab got an icon for a page */
NSImage *iconFromPageIcons(WebKitImageList *list, BOOL *dark);           /* fb-window.m */

/* fb-window.m */
@class FBWindowController, FBOmnibox;
extern WPEDisplay *fbDisplay;
extern NSMutableArray *fbWindows;                       /* FBWindowController, open windows */
FBWindowController *controllerForWindow(NSWindow *w);
FBWindowController *newBrowserWindow(void);             /* no tabs yet: the caller adds them and shows it */
FBWindowController *openWindow(const char *url);        /* NULL: what the preferences say */
void setPageDarkMode(void);
void applyLivePreferences(void);

/* fb-omnibox.m: the address field's dropdown (suggestions, history and bookmark matches) */
@interface FBOmnibox : NSObject {
@public
    FBWindowController *owner;        /* not retained */
    NSWindow *panel;
    NSMutableArray *rows;             /* NSDictionary: Kind, Text, Detail, URL */
    NSInteger selected;
    NSString *typed;
    SoupSession *session;
    GCancellable *pending;
    guint debounce;                   /* GLib timeout before asking for suggestions */
    unsigned generation;
}
- (id)initWithOwner:(FBWindowController *)owner;
- (void)textChanged;
- (BOOL)handleCommand:(SEL)command;
- (BOOL)activateSelection;
- (void)activateRow:(NSInteger)row;
- (void)hide;
- (void)reposition;
@end

/* One tab: a WebKitWebView and what the chrome shows for it. */
@interface FBTab : NSObject {
@public
    FBWindowController *owner;        /* not retained */
    WebKitWebView *webView;
    NSView *pageView;                 /* the backend's FBWPEView */
    NSString *hoverLink;
    NSImage *icon;                    /* the site's icon (16 x 16), nil if none */
    BOOL iconIsDark;                  /* mostly dark pixels: gets a light plate in the dark appearance */
    NSString *titleOverride;          /* a title the page doesn't give (View Source) */
}
- (NSString *)title;
- (NSString *)uri;
- (BOOL)isLoading;
@end

/* The tab strip: a subview of the window's frame view, over the title bar, with the window's own
 * close / minimize / zoom buttons moved into it. */
@interface FBTabBar : NSView {
@public
    FBWindowController *owner;        /* not retained */
    NSInteger hoverTab, hoverClose, pressedClose;
    NSInteger firstVisible;           /* when the tabs overflow: the first one shown */
    FBToolButton *newTabButton;
    NSTrackingArea *tracking;
    guint spinner;                    /* GLib timeout while a tab loads */
    int spinPhase;
    NSInteger dragTab;                /* the tab being dragged, -1 if none */
    CGFloat dragX;
    BOOL tearing;                     /* dragged far enough from the strip to leave it */
}
- (CGFloat)tabsLeft;
- (void)tabsChanged;
- (void)drawTab:(NSInteger)i inRect:(NSRect)r selected:(NSInteger)selected last:(NSInteger)last
           font:(NSFont *)font para:(NSParagraphStyle *)para;
- (void)dragTab:(FBTab *)tab from:(NSEvent *)down;
@end

/* The toolbar row under the strip; empty space drags the window. */
@interface FBToolbar : NSView {
@public
    FBWindowController *owner;        /* not retained */
}
@end

/* The combined address + search field: a rounded plate holding the text field, a search glyph or
 * lock on the left and the bookmark star on the right. */
@interface FBAddressField : NSView {
@public
    FBWindowController *owner;        /* not retained */
    NSTextField *text;
    FBToolButton *star;
    BOOL secure, focused;
}
- (BOOL)isEditing;
- (void)applyAppearance;
@end

@interface FBBookmarksBar : NSView {
@public
    FBWindowController *owner;        /* not retained */
    NSInteger hover, pressed;
    NSTrackingArea *tracking;
}
@end

@interface FBStatusBar : NSView
@end

/* Chrome's status bubble: a small child window at the bottom-left corner of the page. */
@interface FBStatusBubble : NSObject {
    NSWindow *bubble, *parent;        /* parent: not retained */
    NSString *text;
    BOOL onRight;
}
- (id)initWithParent:(NSWindow *)parent;
- (void)setText:(NSString *)text pageFrame:(NSRect)pageInWindow;
- (void)close;
@end

@interface FBWindowController : NSObject {
@public
    WPEToplevel *toplevel;
    NSWindow *window;
    NSView *contentHost;              /* the tabs' page views live here */
    FBTabBar *tabBar;
    FBToolbar *toolbar;
    FBAddressField *addressField;
    NSTextField *location;            /* addressField->text */
    FBToolButton *backButton, *forwardButton, *reloadButton, *downloadsButton, *historyButton, *menuButton;
    FBBookmarksBar *bookmarksBar;
    FBStatusBar *statusBar;
    NSTextField *statusText;
    FBStatusBubble *bubble;
    double loadProgress;              /* < 0: not loading (the toolbar's progress line) */
    NSView *findBar;                  /* Find in Page */
    NSSearchField *findField;
    NSTextField *findStatus;
    FBTab *findTab;                   /* the tab being searched (not retained) */
    BOOL placingButtons;
    FBOmnibox *omnibox;               /* the address field's dropdown */
    NSMutableArray *tabs;
    FBTab *current;                   /* not retained (held by tabs) */
    BOOL closing;
}
- (FBTab *)addTabWithURL:(const char *)url relatedTo:(WebKitWebView *)related select:(BOOL)select;
- (void)selectTab:(FBTab *)tab;
- (void)closeTab:(FBTab *)tab;
- (void)closeWindow;
- (void)requestClose;
- (void)tabChanged:(FBTab *)tab;
- (void)show;
- (void)placeWindow;
- (void)layoutChrome;
- (void)applyAppearance;
- (void)updateChrome;
- (void)updateChromeForcingLocation;
- (void)focusLocation:(id)sender;
- (void)newTab:(id)sender;
- (void)loadURL:(const char *)url;
- (BOOL)validateAction:(SEL)action;
- (BOOL)pageHasFocus;
- (void)editingCommand:(const char *)command;
- (void)downloadsChanged;
- (void)tearOffTab:(FBTab *)tab atScreenPoint:(NSPoint)point;
- (NSRect)stripRectOnScreen;
- (void)placeWindowButtons;
- (void)updateStatus;
- (void)makeTextBigger:(id)sender;
- (void)makeTextSmaller:(id)sender;
- (void)hideFindBar;
- (void)findTextChanged;
- (void)findNext:(id)sender;
- (void)findPrevious:(id)sender;
@end

/* fb-history.m: history and downloads */
void loadHistory(void);
void saveHistoryNow(void);
void historyNoteVisit(const char *uri, const char *title);
void historyNoteTitle(const char *uri, const char *title);
void clearHistory(void);
extern NSString *const FBHistoryChangedNotification;
NSArray *allHistory(void);                              /* the entries themselves (mutable dictionaries) */
void removeHistoryEntries(NSArray *entries);            /* entries from allHistory() */
NSArray *recentHistory(NSUInteger max);                 /* { URL, Title, Date, Visits }, newest first */
NSArray *historyMatches(NSString *text, NSUInteger max);/* { URL, Title, Score }, best first */
NSString *displayURL(NSString *url);                    /* without the scheme and "www." */

enum { FBDownloadActive, FBDownloadDone, FBDownloadFailed, FBDownloadCancelled };
@interface FBDownload : NSObject {
@public
    WebKitDownload *download;
    NSString *name, *path;
    double progress;
    guint64 received;
    int state;
}
- (NSString *)status;
@end
extern NSMutableArray *fbDownloads;                     /* FBDownload, newest first */
void setUpDownloads(void);
double downloadsProgress(void);                         /* the active downloads together, -1 if none */
void cancelDownload(FBDownload *d);
void clearFinishedDownloads(void);
void revealDownload(FBDownload *d);
void openDownloadsFolder(void);
void openDownload(FBDownload *d);                       /* a finished file: open it; else show it in Finder */
extern NSString *const FBDownloadsChangedNotification;

/* fb-library.m: the History and Downloads windows */
void fbShowHistoryWindow(void);
void fbShowDownloadsWindow(void);

/* fb-about.m */
void fbShowAbout(void);

/* fb-update.m: Software Update */
extern NSString *const PrefCheckForUpdates;             /* BOOL: check about once a day at launch */
void fbUpdateRegisterDefaults(void);                    /* from registerDefaults() */
void fbUpdateStartup(void);                             /* after the first window: finish an update, schedule checks */
void fbCheckForUpdates(void);                           /* Check for Updates... */

/* fb-preferences.m */
@interface FBPreferences : NSObject {
    NSWindow *window;
    NSMutableDictionary *panes;          /* identifier -> view */
    NSMutableArray *bound;               /* { control, key, value? } */
    NSTextField *cacheNote;              /* Hardware pane: bytecode cache size */
    NSTextField *homeField, *customSearchField;
    NSString *currentPane;
}
+ (FBPreferences *)shared;
- (void)show;
- (void)refresh;
- (void)selectPane:(NSString *)ident animate:(BOOL)animate;
- (void)updateCacheNote;
@end

#endif
