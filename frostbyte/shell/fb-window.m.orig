/*
 * FrostByte: browser windows. FBTab wraps one WebKitWebView; FBWindowController owns a WPE toplevel
 * (NSWindow) with the tab strip, toolbar, bars and tabs, and the list of open windows.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"

WPEDisplay *fbDisplay;
NSMutableArray *fbWindows;

/* ---- WebKit signals -> FBTab -> its window ---- */

static void tabPropertyChanged(WebKitWebView *v, GParamSpec *p, gpointer d)
{
    (void)p;
    FB_POOL_BEGIN;
    FBTab *tab = d;
    /* FROSTBYTE_LOG_TITLE=1: log title changes (remote tests read them from the run log). */
    static int logTitle = -1;
    if (logTitle < 0)
        logTitle = getenv("FROSTBYTE_LOG_TITLE") && *getenv("FROSTBYTE_LOG_TITLE") == '1';
    if (logTitle && p && !strcmp(g_param_spec_get_name(p), "title"))
        fprintf(stderr, "frostbyte: title: %s\n", webkit_web_view_get_title(v) ? webkit_web_view_get_title(v) : "");
    [tab->owner tabChanged:tab];
    FB_POOL_END;
}

static void tabLoadChanged(WebKitWebView *v, WebKitLoadEvent e, gpointer d)
{
    const char *names[] = { "started", "redirected", "committed", "finished" };
    fprintf(stderr, "frostbyte: load %s: %s\n", names[e], webkit_web_view_get_uri(v));
    /* WebKit keeps page-icons from the previous page until the new page's icons are loaded (and for
     * good if it has none), so a committed load drops the old icon: the generic page icon shows until
     * notify::page-icons brings the new one. */
    if (e == WEBKIT_LOAD_COMMITTED) {
        FB_POOL_BEGIN;
        FBTab *tab = d;
        [tab->icon release];
        tab->icon = nil;
        FB_POOL_END;
    }
    if (e == WEBKIT_LOAD_FINISHED) {
        FB_POOL_BEGIN;
        historyNoteVisit(webkit_web_view_get_uri(v), webkit_web_view_get_title(v));
        FB_POOL_END;
    }
    tabPropertyChanged(v, NULL, d);
}

/* WebKit's page icons (premultiplied 32-bit native-order pixels) -> a 16 x 16 NSImage. The image
 * closest to 16 px (preferring larger, which scale down well) is used. *dark: its visible pixels are
 * mostly dark (average luminance under 0.3), so the dark tab strip puts a light plate behind it. */
NSImage *iconFromPageIcons(WebKitImageList *list, BOOL *dark)
{
    *dark = NO;
    gsize n = list ? webkit_image_list_get_length(list) : 0;
    WebKitImage *best = NULL;
    int bestScore = 0;
    for (gsize i = 0; i < n; i++) {
        WebKitImage *image = webkit_image_list_get(list, i);
        int w = webkit_image_get_width(image);
        int score = w >= 16 ? 10000 - w : w;      /* smallest >= 16, else the largest below */
        if (w > 0 && (!best || score > bestScore)) {
            best = image;
            bestScore = score;
        }
    }
    if (!best)
        return nil;
    GBytes *bytes = webkit_image_as_bytes(best);
    gsize size = 0;
    const void *data = g_bytes_get_data(bytes, &size);
    int w = webkit_image_get_width(best), h = webkit_image_get_height(best);
    guint stride = webkit_image_get_stride(best);
    if (!data || size < (gsize)stride * h)
        return nil;
    /* ARGB in a host-order 32-bit word, premultiplied: luminance of the mostly opaque pixels */
    double lum = 0;
    unsigned counted = 0;
    for (int y = 0; y < h; y++) {
        const uint32_t *row = (const uint32_t *)((const char *)data + (gsize)y * stride);
        for (int x = 0; x < w; x++) {
            uint32_t px = row[x], a = px >> 24;
            if (a < 128)
                continue;
            lum += (0.30 * ((px >> 16) & 0xff) + 0.59 * ((px >> 8) & 0xff) + 0.11 * (px & 0xff)) / a;
            counted++;
        }
    }
    *dark = counted && lum / counted < 0.3;
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, data, (gsize)stride * h, NULL);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(w, h, 8, 32, stride, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                  provider, NULL, true, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    if (!cg)
        return nil;
    /* draw it now (the bytes belong to WebKit) into our own 16 x 16 image */
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithCGImage:cg] autorelease];
    NSImage *icon = [[[NSImage alloc] initWithSize:NSMakeSize(16, 16)] autorelease];
    [icon lockFocus];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [rep drawInRect:NSMakeRect(0, 0, 16, 16)];
    [icon unlockFocus];
    CGImageRelease(cg);
    return icon;
}

static void tabIconsChanged(WebKitWebView *v, GParamSpec *p, gpointer d)
{
    (void)p;
    FB_POOL_BEGIN;
    FBTab *tab = d;
    BOOL dark;
    [tab->icon release];
    tab->icon = [iconFromPageIcons(webkit_web_view_get_page_icons(v), &dark) retain];
    tab->iconIsDark = dark;
    [tab->owner tabChanged:tab];
    bookmarkIconSeen(webkit_web_view_get_uri(v), tab->icon, dark);
    FB_POOL_END;
}

static void tabMouseTargetChanged(WebKitWebView *v, WebKitHitTestResult *hit, guint mods, gpointer d)
{
    (void)mods;
    FB_POOL_BEGIN;
    FBTab *tab = d;
    const char *link = webkit_hit_test_result_context_is_link(hit) ? webkit_hit_test_result_get_link_uri(hit) : NULL;
    NSString *s = link ? str(link) : nil;
    if (!(s == tab->hoverLink || [s isEqualToString:tab->hoverLink])) {
        [tab->hoverLink release];
        tab->hoverLink = [s copy];
        tabPropertyChanged(v, NULL, d);
    }
    FB_POOL_END;
}

/* target=_blank and window.open(): a new tab in the same window (Camino's default) or a new window,
 * as the Tabs preferences say. */
static WebKitWebView *tabCreate(WebKitWebView *v, WebKitNavigationAction *a, gpointer d)
{
    (void)a;
    FB_POOL_BEGIN;
    FBTab *tab = d;
    FBTab *created;
    if (prefIs(PrefNewWindowLinksIn, @"Window")) {
        FBWindowController *c = newBrowserWindow();
        created = [c addTabWithURL:NULL relatedTo:v select:YES];
        [c show];
    } else
        created = [tab->owner addTabWithURL:NULL relatedTo:v select:[prefs() boolForKey:PrefSelectNewTabs]];
    FB_POOL_END;
    return created ? created->webView : NULL;
}

/* Cmd-click or middle-click on a link: open it in a new tab, in the background unless the
 * preferences say otherwise (Shift reverses it, as in Camino). Responses the page can't show: download. */
static gboolean tabDecidePolicy(WebKitWebView *v, WebKitPolicyDecision *decision, WebKitPolicyDecisionType type, gpointer d)
{
    (void)v;
    /* What the page can't show becomes a download (WebKit's default would drop it). */
    if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
        WebKitResponsePolicyDecision *r = WEBKIT_RESPONSE_POLICY_DECISION(decision);
        WebKitURIResponse *response = webkit_response_policy_decision_get_response(r);
        if (webkit_response_policy_decision_is_main_frame_main_resource(r)
            && !webkit_response_policy_decision_is_mime_type_supported(r)
            && webkit_uri_response_get_status_code(response) != 204) {
            webkit_policy_decision_download(decision);
            return TRUE;
        }
        return FALSE;
    }
    if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION && type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION)
        return FALSE;
    WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
    if (webkit_navigation_action_get_navigation_type(action) != WEBKIT_NAVIGATION_TYPE_LINK_CLICKED)
        return FALSE;
    guint mods = webkit_navigation_action_get_modifiers(action);
    gboolean middle = webkit_navigation_action_get_mouse_button(action) == 2;
    gboolean command = (mods & WPE_MODIFIER_KEYBOARD_META) != 0;
    if (!middle && !command)
        return FALSE;
    WebKitURIRequest *request = webkit_navigation_action_get_request(action);
    FB_POOL_BEGIN;
    FBTab *tab = d;
    BOOL background = [prefs() boolForKey:PrefCommandClickBackground];
    if (mods & WPE_MODIFIER_KEYBOARD_SHIFT)
        background = !background;
    [tab->owner addTabWithURL:webkit_uri_request_get_uri(request) relatedTo:NULL select:!background];
    FB_POOL_END;
    webkit_policy_decision_ignore(decision);
    return TRUE;
}

static gboolean tabLoadFailed(WebKitWebView *v, WebKitLoadEvent e, const char *uri, GError *error, gpointer d)
{
    (void)v; (void)e; (void)d;
    fprintf(stderr, "frostbyte: load failed: %s: %s (domain %s, code %d)\n", uri,
            error ? error->message : "?", error ? g_quark_to_string(error->domain) : "?", error ? error->code : 0);
    return FALSE;   /* let WebKit show its error page */
}

static gboolean tabTLSFailed(WebKitWebView *v, const char *uri, GTlsCertificate *cert, GTlsCertificateFlags errors, gpointer d)
{
    (void)v; (void)cert; (void)d;
    fprintf(stderr, "frostbyte: TLS error loading %s: flags 0x%x%s%s%s%s%s%s\n", uri, (unsigned)errors,
            errors & G_TLS_CERTIFICATE_UNKNOWN_CA ? " unknown-CA" : "",
            errors & G_TLS_CERTIFICATE_BAD_IDENTITY ? " bad-identity" : "",
            errors & G_TLS_CERTIFICATE_NOT_ACTIVATED ? " not-yet-valid" : "",
            errors & G_TLS_CERTIFICATE_EXPIRED ? " expired" : "",
            errors & G_TLS_CERTIFICATE_REVOKED ? " revoked" : "",
            errors & G_TLS_CERTIFICATE_INSECURE ? " insecure" : "");
    return FALSE;
}

static void tabCloseRequested(WebKitWebView *v, gpointer d)
{
    (void)v;
    FB_POOL_BEGIN;
    FBTab *tab = d;
    [tab->owner closeTab:tab];
    FB_POOL_END;
}

static void tabViewClosed(WPEView *v, gpointer d) { (void)v; tabCloseRequested(NULL, d); }

static void tabReadyToShow(WebKitWebView *v, gpointer d) { tabPropertyChanged(v, NULL, d); }

static void tabProcessTerminated(WebKitWebView *v, WebKitWebProcessTerminationReason r, gpointer d)
{
    (void)v; (void)d;
    fprintf(stderr, "frostbyte: web process terminated (reason %d)\n", r);
}

@implementation FBTab

- (NSString *)title
{
    if (titleOverride)
        return titleOverride;
    const char *t = webkit_web_view_get_title(webView);
    if (t && *t)
        return str(t);
    const char *u = webkit_web_view_get_uri(webView);
    return u && *u && strcmp(u, "about:blank") ? str(u) : @"New Tab";
}

- (NSString *)uri
{
    const char *u = webkit_web_view_get_uri(webView);
    return u && *u && strcmp(u, "about:blank") ? str(u) : nil;
}

- (BOOL)isLoading { return webkit_web_view_is_loading(webView); }

- (void)dealloc
{
    [hoverLink release];
    [icon release];
    [titleOverride release];
    [super dealloc];
}

@end

/* Debugging: FROSTBYTE_USER_SCRIPT=<file.js> is injected at document start into every frame of every
 * page. Read once; added once per user content manager (related views share their manager). */
static void addDebugUserScript(WebKitWebView *view)
{
    static WebKitUserScript *script;
    static BOOL tried;
    if (!tried) {
        tried = YES;
        const char *path = getenv("FROSTBYTE_USER_SCRIPT");
        char *source = NULL;
        GError *error = NULL;
        if (path && *path) {
            if (g_file_get_contents(path, &source, NULL, &error)) {
                script = webkit_user_script_new(source, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
                                                WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL);
                fprintf(stderr, "frostbyte: user script %s (%zu bytes) injected into every page\n", path, strlen(source));
                g_free(source);
            } else {
                fprintf(stderr, "frostbyte: FROSTBYTE_USER_SCRIPT: %s\n", error->message);
                g_error_free(error);
            }
        }
    }
    if (!script)
        return;
    WebKitUserContentManager *manager = webkit_web_view_get_user_content_manager(view);
    if (manager && !g_object_get_data(G_OBJECT(manager), "frostbyte-user-script")) {
        webkit_user_content_manager_add_script(manager, script);
        g_object_set_data(G_OBJECT(manager), "frostbyte-user-script", script);
    }
}

/* ---- the browser window ---- */

/* The close button: the controller decides (it may ask first) and closes the window itself. */
static gboolean windowShouldClose(WPEToplevelCocoa *t, gpointer data)
{
    (void)t;
    [(FBWindowController *)data requestClose];
    return FALSE;
}

void setPageDarkMode(void)
{
    if (fbDisplay)
        wpe_settings_set_boolean(wpe_display_get_settings(fbDisplay), WPE_SETTING_DARK_MODE, isDark(),
                                 WPE_SETTINGS_SOURCE_APPLICATION, NULL);
}

/* ---- Find in Page: WebKit's find controller ---- */

static void findFound(WebKitFindController *fc, guint count, gpointer d)
{
    (void)fc;
    FB_POOL_BEGIN;
    FBWindowController *c = d;
    [c->findStatus setStringValue:count == 1 ? @"1 match" : [NSString stringWithFormat:@"%u matches", count]];
    FB_POOL_END;
}

static void findFailed(WebKitFindController *fc, gpointer d)
{
    (void)fc;
    FB_POOL_BEGIN;
    FBWindowController *c = d;
    [c->findStatus setStringValue:[[c->findField stringValue] length] ? @"Not found" : @""];
    FB_POOL_END;
}

/* View Source: the main resource's bytes, shown as plain text in a new tab. */
typedef struct {
    FBWindowController *owner;        /* retained */
    char *uri;
} FBSourceRequest;

static void sourceReady(GObject *object, GAsyncResult *result, gpointer data)
{
    FBSourceRequest *req = data;
    gsize length = 0;
    GError *error = NULL;
    guchar *bytes = webkit_web_resource_get_data_finish(WEBKIT_WEB_RESOURCE(object), result, &length, &error);
    FB_POOL_BEGIN;
    if (bytes && !req->owner->closing) {
        char *text = g_utf8_make_valid((const char *)bytes, (gssize)length);
        FBTab *tab = [req->owner addTabWithURL:NULL relatedTo:NULL select:YES];
        tab->titleOverride = [[NSString alloc] initWithFormat:@"Source of %@", str(req->uri)];
        webkit_web_view_load_plain_text(tab->webView, text);
        [req->owner->window makeFirstResponder:tab->pageView];
        g_free(text);
    } else if (error)
        fprintf(stderr, "frostbyte: view source: %s\n", error->message);
    [req->owner release];
    FB_POOL_END;
    g_clear_error(&error);
    g_free(bytes);
    g_free(req->uri);
    g_free(req);
}

/* The FrostByte menu's zoom row: "Zoom   [-] 100% [+]". */
@interface FBZoomMenuView : NSView {
@public
    FBWindowController *owner;        /* not retained */
    NSTextField *percent;
}
- (void)update;
@end

@implementation FBZoomMenuView

- (NSButton *)button:(NSString *)title x:(CGFloat)x action:(SEL)action label:(NSString *)label
{
    NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(x, 3, 32, 22)] autorelease];
    [b setBezelStyle:NSRoundRectBezelStyle];
    [b setTitle:title];
    [b setTarget:self];
    [b setAction:action];
    [[b cell] accessibilitySetOverrideValue:label forAttribute:NSAccessibilityDescriptionAttribute];
    [b setToolTip:label];
    [self addSubview:b];
    return b;
}

- (id)initWithOwner:(FBWindowController *)o
{
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 300, 28)]))
        return nil;
    owner = o;
    NSTextField *label = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 5, 100, 17)] autorelease];
    [label setStringValue:@"Zoom"];
    [label setEditable:NO];
    [label setBordered:NO];
    [label setDrawsBackground:NO];
    [label setFont:[NSFont menuFontOfSize:0]];
    [self addSubview:label];
    [self button:str("\xe2\x88\x92") x:300 - 14 - 32 - 50 - 32 action:@selector(zoomOut:) label:@"Zoom out"];
    percent = [[[NSTextField alloc] initWithFrame:NSMakeRect(300 - 14 - 32 - 50, 5, 50, 17)] autorelease];
    [percent setEditable:NO];
    [percent setBordered:NO];
    [percent setDrawsBackground:NO];
    [percent setAlignment:NSCenterTextAlignment];
    [percent setFont:[NSFont menuFontOfSize:0]];
    [self addSubview:percent];
    [self button:@"+" x:300 - 14 - 32 action:@selector(zoomIn:) label:@"Zoom in"];
    [self update];
    return self;
}

- (void)update
{
    double z = owner->current ? webkit_web_view_get_zoom_level(owner->current->webView) : 1;
    [percent setStringValue:[NSString stringWithFormat:@"%d%%", (int)floor(z * 100 + 0.5)]];
}

- (void)zoomOut:(id)s { [owner makeTextSmaller:s]; [self update]; }
- (void)zoomIn:(id)s { [owner makeTextBigger:s]; [self update]; }

@end

@implementation FBWindowController

static FBToolButton *toolButton(FBWindowController *self, NSView *bar, FBIcon icon, NSString *label, NSString *tip,
                                SEL action, CGFloat x, BOOL right)
{
    FBToolButton *b = [FBToolButton buttonWithIcon:icon label:label tip:tip target:self action:action];
    [b setFrame:NSMakeRect(right ? NSWidth([bar bounds]) - x : x, 7, 32, 32)];
    [b setAutoresizingMask:right ? NSViewMinXMargin : NSViewMaxXMargin];
    [bar addSubview:b];
    return [b retain];
}

- (id)init
{
    if (!(self = [super init]))
        return nil;
    tabs = [[NSMutableArray alloc] init];
    loadProgress = -1;
    toplevel = WPE_TOPLEVEL(g_object_new(WPE_TYPE_TOPLEVEL_COCOA, "display", fbDisplay, "max-views", 1000, NULL));
    wpe_toplevel_cocoa_set_should_close_func(WPE_TOPLEVEL_COCOA(toplevel), windowShouldClose, self);
    window = (NSWindow *)wpe_toplevel_cocoa_get_window(WPE_TOPLEVEL_COCOA(toplevel));
    [window setReleasedWhenClosed:NO];
    [window setShowsToolbarButton:NO];

    /* Content, top to bottom: (the strip's overhang), toolbar, bookmarks bar, find bar, pages, status bar. */
    NSRect content = [[window contentView] frame];
    CGFloat W = content.size.width;
    NSView *container = [[NSView alloc] initWithFrame:content];
    [container setAutoresizesSubviews:YES];
    [window setContentView:container];
    [container release];

    statusBar = [[FBStatusBar alloc] initWithFrame:NSMakeRect(0, 0, W, kStatusBarHeight)];
    [statusBar setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    statusText = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 2, W - 16, 15)];
    [statusText setEditable:NO];
    [statusText setSelectable:NO];
    [statusText setBordered:NO];
    [statusText setDrawsBackground:NO];
    [[statusText cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [statusText setFont:[NSFont systemFontOfSize:11]];
    [statusText setAutoresizingMask:NSViewWidthSizable];
    [statusBar addSubview:statusText];
    [container addSubview:statusBar];
    bubble = [[FBStatusBubble alloc] initWithParent:window];

    bookmarksBar = [[FBBookmarksBar alloc] initWithFrame:NSMakeRect(0, 0, W, kBookmarksBarHeight)];
    bookmarksBar->owner = self;
    bookmarksBar->hover = bookmarksBar->pressed = -1;
    [bookmarksBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [container addSubview:bookmarksBar];

    contentHost = [[NSView alloc] initWithFrame:NSMakeRect(0, kStatusBarHeight, W, content.size.height - kStatusBarHeight)];
    [contentHost setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [contentHost setAutoresizesSubviews:YES];
    [container addSubview:contentHost];
    wpe_toplevel_cocoa_set_view_host(WPE_TOPLEVEL_COCOA(toplevel), contentHost);

    /* The toolbar row: back, forward, reload | address + search | downloads, history | FrostByte menu */
    toolbar = [[FBToolbar alloc] initWithFrame:NSMakeRect(0, 0, W, kToolbarHeight)];
    toolbar->owner = self;
    [toolbar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [container addSubview:toolbar];
    backButton = toolButton(self, toolbar, FBIconBack, @"Back", str("Go back (\xe2\x8c\x98[)"), @selector(goBack:), 10, NO);
    forwardButton = toolButton(self, toolbar, FBIconForward, @"Forward", str("Go forward (\xe2\x8c\x98])"), @selector(goForward:), 46, NO);
    reloadButton = toolButton(self, toolbar, FBIconReload, @"Reload", str("Reload this page (\xe2\x8c\x98R)"), @selector(reload:), 82, NO);
    downloadsButton = toolButton(self, toolbar, FBIconDownloads, @"Downloads", str("Downloads (\xe2\x8c\xa5\xe2\x8c\x98L)"),
                                 @selector(showDownloads:), 127, YES);
    downloadsButton->popsOnMouseDown = YES;
    historyButton = toolButton(self, toolbar, FBIconHistory, @"History", str("History (\xe2\x8c\x98Y)"), @selector(showHistory:), 91, YES);
    historyButton->popsOnMouseDown = YES;
    menuButton = toolButton(self, toolbar, FBIconNone, @"FrostByte menu", @"FrostByte menu", @selector(showFrostByteMenu:), 42, YES);
    menuButton->picture = [appIcon() retain];
    menuButton->popsOnMouseDown = YES;
    addressField = [[FBAddressField alloc] initWithFrame:NSMakeRect(126, 7, W - 139 - 126, 32)];
    addressField->owner = self;
    [addressField setAutoresizingMask:NSViewWidthSizable];
    [toolbar addSubview:addressField];
    location = [addressField->text retain];
    [location setTarget:self];
    [location setAction:@selector(locationEntered:)];
    [location setDelegate:(id)self];
    [addressField->star setTarget:self];

    /* The tab strip goes into the window's frame view, over the title bar; the window's own buttons
     * stay above it (moved into it by placeWindowButtons). */
    NSView *frameView = [container superview];
    NSRect fb = [frameView bounds];
    tabBar = [[FBTabBar alloc] initWithFrame:NSMakeRect(0, NSHeight(fb) - kStripHeight, NSWidth(fb), kStripHeight)];
    tabBar->owner = self;
    [tabBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [frameView addSubview:tabBar positioned:NSWindowAbove relativeTo:container];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSWindowButton kinds[] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton };
    for (int i = 0; i < 3; i++) {
        NSButton *b = [window standardWindowButton:kinds[i]];
        if (!b || [b superview] != frameView)
            continue;
        if ([[frameView subviews] indexOfObjectIdenticalTo:b] < [[frameView subviews] indexOfObjectIdenticalTo:tabBar]) {
            [b retain];
            [b removeFromSuperview];
            [frameView addSubview:b positioned:NSWindowAbove relativeTo:tabBar];
            [b release];
        }
        [b setPostsFrameChangedNotifications:YES];
        [nc addObserver:self selector:@selector(windowButtonMoved:) name:NSViewFrameDidChangeNotification object:b];
    }
    [self placeWindowButtons];
    [window setMinSize:NSMakeSize(480, 260)];

    [nc addObserver:self selector:@selector(windowDidResize:) name:NSWindowDidResizeNotification object:window];
    [nc addObserver:self selector:@selector(windowKeyChanged:) name:NSWindowDidBecomeMainNotification object:window];
    [nc addObserver:self selector:@selector(windowKeyChanged:) name:NSWindowDidResignMainNotification object:window];
    [nc addObserver:self selector:@selector(windowKeyChanged:) name:NSWindowDidBecomeKeyNotification object:window];
    [nc addObserver:self selector:@selector(windowKeyChanged:) name:NSWindowDidResignKeyNotification object:window];
    [nc addObserver:self selector:@selector(windowUpdated:) name:NSWindowDidUpdateNotification object:window];
    [nc addObserver:self selector:@selector(windowMoved:) name:NSWindowDidMoveNotification object:window];
    [self placeWindow];
    [self applyAppearance];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [tabs release];
    [tabBar release];
    [toolbar release];
    [addressField release];
    [location release];
    [backButton release];
    [forwardButton release];
    [reloadButton release];
    [downloadsButton release];
    [historyButton release];
    [menuButton release];
    [bookmarksBar release];
    [statusBar release];
    [statusText release];
    [bubble release];
    [findBar release];
    [findField release];
    [findStatus release];
    [contentHost release];
    [omnibox release];
    [super dealloc];
}

/* The close, minimize and zoom buttons, centred vertically in the strip. The frame view puts them
 * back on every relayout (resize, key changes), so they are moved again whenever they move. */
- (void)placeWindowButtons
{
    if (placingButtons)
        return;
    placingButtons = YES;
    NSWindowButton kinds[] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton };
    CGFloat x = 12;
    for (int i = 0; i < 3; i++) {
        NSButton *b = [window standardWindowButton:kinds[i]];
        if (!b)
            continue;
        NSView *frameView = [b superview];
        NSRect f = [b frame];
        NSPoint o = NSMakePoint(x, floor(NSHeight([frameView bounds]) - kStripHeight / 2 - NSHeight(f) / 2));
        if (!NSEqualPoints(o, f.origin))
            [b setFrameOrigin:o];
        x += NSWidth(f) + 6;
    }
    placingButtons = NO;
}

- (void)windowButtonMoved:(NSNotification *)n
{
    (void)n;
    if (!placingButtons)
        [self performSelector:@selector(placeWindowButtons) withObject:nil afterDelay:0];
    [self placeWindowButtons];
}

/* First window: centred, near the top of the screen, sized to it. Later windows cascade. */
- (void)placeWindow
{
    static NSPoint cascade;
    NSRect screen = [([window screen] ?: [NSScreen mainScreen]) visibleFrame];
    NSRect f = [window frame];
    f.size.width = MIN(1240, screen.size.width - 40);
    f.size.height = MIN(screen.size.height - 60, MAX(600, screen.size.height * 0.8));
    if (![fbWindows count] || NSEqualPoints(cascade, NSZeroPoint)) {
        f.origin.x = screen.origin.x + (screen.size.width - f.size.width) / 2;
        f.origin.y = NSMaxY(screen) - 30 - f.size.height;
        [window setFrame:f display:NO];
        cascade = NSMakePoint(f.origin.x, NSMaxY(f));
    } else
        [window setFrame:f display:NO];
    cascade = [window cascadeTopLeftFromPoint:cascade];
}

- (void)show
{
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self placeWindowButtons];
}

/* ---- layout and appearance ---- */

/* The one place that decides which bars show and where the pages go. */
- (void)layoutChrome
{
    BOOL showBookmarks = [prefs() boolForKey:PrefShowBookmarksBar];
    BOOL showStatus = [prefs() boolForKey:PrefShowStatusBar];
    NSView *container = [window contentView];
    NSView *frameView = [container superview];
    NSRect bounds = [container bounds];
    /* the strip covers the title bar and overhangs the top of the content view */
    CGFloat titlebar = NSHeight([frameView bounds]) - NSMaxY([container frame]);
    CGFloat w = NSWidth(bounds), top = NSHeight(bounds) - MAX(0, kStripHeight - titlebar);
    CGFloat bottom = showStatus ? kStatusBarHeight : 0;
    NSRect strip = NSMakeRect(0, NSHeight([frameView bounds]) - kStripHeight, NSWidth([frameView bounds]), kStripHeight);
    if (!NSEqualRects([tabBar frame], strip))
        [tabBar setFrame:strip];
    top -= kToolbarHeight;
    [toolbar setFrame:NSMakeRect(0, top, w, kToolbarHeight)];
    [bookmarksBar setHidden:!showBookmarks];
    if (showBookmarks) {
        top -= kBookmarksBarHeight;
        [bookmarksBar setFrame:NSMakeRect(0, top, w, kBookmarksBarHeight)];
    }
    if (findBar && ![findBar isHidden]) {
        top -= NSHeight([findBar frame]);
        [findBar setFrame:NSMakeRect(0, top, w, NSHeight([findBar frame]))];
    }
    [statusBar setHidden:!showStatus];
    [statusBar setFrame:NSMakeRect(0, 0, w, kStatusBarHeight)];
    NSRect page = NSMakeRect(0, bottom, w, MAX(0, top - bottom));
    if (!NSEqualRects([contentHost frame], page))
        [contentHost setFrame:page];
    [tabBar tabsChanged];
    [bookmarksBar setNeedsDisplay:YES];
    [toolbar setNeedsDisplay:YES];
    [self updateStatus];
}

- (void)applyAppearance
{
    const FBPalette *t = palette();
    [window setBackgroundColor:t->page];
    [statusText setTextColor:t->textSoft];
    [addressField applyAppearance];
    [self layoutChrome];
    [[[window contentView] superview] setNeedsDisplay:YES];
    for (NSView *v in [toolbar subviews])
        [v setNeedsDisplay:YES];
    [tabBar->newTabButton setNeedsDisplay:YES];
    [statusBar setNeedsDisplay:YES];
    [findBar setNeedsDisplay:YES];
}

- (void)windowDidResize:(NSNotification *)n
{
    (void)n;
    [self placeWindowButtons];
    [self layoutChrome];
    [omnibox reposition];
}

- (void)windowMoved:(NSNotification *)n { (void)n; [self updateStatus]; }

- (void)windowKeyChanged:(NSNotification *)n
{
    (void)n;
    [self placeWindowButtons];
    [tabBar setNeedsDisplay:YES];
    if (![window isKeyWindow])
        [omnibox hide];
}

/* Focus ring on the address field (there is no notification for the field editor coming and going). */
- (void)windowUpdated:(NSNotification *)n
{
    (void)n;
    BOOL editing = [addressField isEditing];
    if (editing != addressField->focused) {
        addressField->focused = editing;
        [addressField setNeedsDisplay:YES];
        if (!editing) {
            [omnibox hide];
            [self updateChromeForcingLocation];
        }
    }
}

/* ---- tabs ---- */

- (FBTab *)addTabWithURL:(const char *)url relatedTo:(WebKitWebView *)related select:(BOOL)select
{
    WebKitWebView *view = related
        ? WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", fbDisplay, "related-view", related, NULL))
        : WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", fbDisplay, NULL));
    WPEView *wpeView = webkit_web_view_get_wpe_view(view);
    const char *console = getenv("FROSTBYTE_CONSOLE");   /* JS console messages to stdout (the run log) */
    if (console && *console && strcmp(console, "0"))
        webkit_settings_set_enable_write_console_messages_to_stdout(webkit_web_view_get_settings(view), TRUE);
    addDebugUserScript(view);
    /* With UVD decoding on, codecs only a hardware decoder may play are the ones UVD lacks: sites (YouTube)
     * then see VP9/VP8/AV1 as unsupported in MSE/canPlayType and send H.264, which the card decodes. */
    if (fbHardwareVideoActive && [prefs() boolForKey:PrefPreferH264])
        webkit_settings_set_media_content_types_requiring_hardware_support(webkit_web_view_get_settings(view),
            "video/*; codecs=\"vp09*\":video/*; codecs=\"vp9*\":video/*; codecs=\"vp8*\":video/*; codecs=\"av01*\"");
    FBTab *tab = [[FBTab alloc] init];
    tab->owner = self;
    tab->webView = view;            /* WPE's WebKitWebView is a plain GObject: this ref is ours */
    tab->pageView = (NSView *)wpe_view_cocoa_get_nsview(WPE_VIEW_COCOA(wpeView));
    /* New tabs go next to the current one. */
    NSUInteger at = current ? [tabs indexOfObject:current] + 1 : [tabs count];
    [tabs insertObject:tab atIndex:MIN(at, [tabs count])];
    [tab release];

    g_signal_connect(view, "notify::title", G_CALLBACK(tabPropertyChanged), tab);
    g_signal_connect(view, "notify::uri", G_CALLBACK(tabPropertyChanged), tab);
    g_signal_connect(view, "notify::estimated-load-progress", G_CALLBACK(tabPropertyChanged), tab);
    g_signal_connect(view, "notify::is-loading", G_CALLBACK(tabPropertyChanged), tab);
    g_signal_connect(view, "notify::page-icons", G_CALLBACK(tabIconsChanged), tab);
    g_signal_connect(view, "load-changed", G_CALLBACK(tabLoadChanged), tab);
    g_signal_connect(view, "load-failed", G_CALLBACK(tabLoadFailed), tab);
    g_signal_connect(view, "load-failed-with-tls-errors", G_CALLBACK(tabTLSFailed), tab);
    g_signal_connect(view, "mouse-target-changed", G_CALLBACK(tabMouseTargetChanged), tab);
    g_signal_connect(view, "create", G_CALLBACK(tabCreate), tab);
    g_signal_connect(view, "decide-policy", G_CALLBACK(tabDecidePolicy), tab);
    g_signal_connect(view, "ready-to-show", G_CALLBACK(tabReadyToShow), tab);
    g_signal_connect(view, "close", G_CALLBACK(tabCloseRequested), tab);
    g_signal_connect(view, "web-process-terminated", G_CALLBACK(tabProcessTerminated), tab);
    g_signal_connect(wpeView, "closed", G_CALLBACK(tabViewClosed), tab);

    wpe_view_set_visible(wpeView, FALSE);
    wpe_view_set_toplevel(wpeView, toplevel);
    if (url)
        webkit_web_view_load_uri(view, url);
    if (select || !current)
        [self selectTab:tab];
    [self layoutChrome];
    return tab;
}

- (void)selectTab:(FBTab *)tab
{
    if (tab == current)
        return;
    [self hideFindBar];
    if (current)
        wpe_view_set_visible(webkit_web_view_get_wpe_view(current->webView), FALSE);
    current = tab;
    wpe_view_set_visible(webkit_web_view_get_wpe_view(tab->webView), TRUE);
    [window makeFirstResponder:tab->pageView];
    [self updateChromeForcingLocation];
    /* A blank new tab starts in the location field, ready for typing. */
    if (![tab uri] && !tab->titleOverride)
        [self focusLocation:nil];
    [self updateChrome];
    [tabBar tabsChanged];
}

- (void)closeTab:(FBTab *)tab
{
    NSUInteger i = [tabs indexOfObject:tab];
    if (i == NSNotFound)
        return;
    if (tab == findTab)
        [self hideFindBar];
    WebKitWebView *view = tab->webView;
    WPEView *wpeView = webkit_web_view_get_wpe_view(view);
    g_signal_handlers_disconnect_by_data(view, tab);
    g_signal_handlers_disconnect_by_data(wpeView, tab);
    if (tab == current) {
        current = nil;
        wpe_view_set_visible(wpeView, FALSE);
    }
    [tabs removeObjectAtIndex:i];
    /* Often inside an AppKit event or a WebKit signal from this view: unref on the next idle. */
    g_idle_add(unrefLater, view);

    if (![tabs count]) {
        [self closeWindow];
        return;
    }
    if (!current)
        [self selectTab:[tabs objectAtIndex:MIN(i, [tabs count] - 1)]];
    [self layoutChrome];
}

/* Moving tabs between windows: the tab (its WebKitWebView and its signal handlers, which point at the
 * FBTab) stays alive; only its WPEView changes toplevel, and the backend moves its NSView along. */
- (FBTab *)releaseTab:(FBTab *)tab
{
    NSUInteger i = [tabs indexOfObject:tab];
    if (i == NSNotFound || [tabs count] < 2)
        return nil;
    [[tab retain] autorelease];
    if (tab == findTab)
        [self hideFindBar];
    if (tab == current) {
        current = nil;
        wpe_view_set_visible(webkit_web_view_get_wpe_view(tab->webView), FALSE);
    }
    [tabs removeObjectAtIndex:i];
    if (!current)
        [self selectTab:[tabs objectAtIndex:MIN(i, [tabs count] - 1)]];
    [self layoutChrome];
    return tab;
}

/* A view moved to another window shows nothing until WebKit sends its next frame, and a page that
 * isn't changing sends none (the zero-copy surface starts empty in the new window). A one-point
 * resize, undone a moment later, makes it paint. */
static gboolean restorePageSize(gpointer data)
{
    FB_POOL_BEGIN;
    FBTab *tab = data;
    if (tab->owner && [tab->pageView superview])
        [tab->pageView setFrame:[[tab->pageView superview] bounds]];
    [tab release];
    FB_POOL_END;
    return G_SOURCE_REMOVE;
}

static void nudgeRepaint(FBTab *tab)
{
    NSRect f = [tab->pageView frame];
    if (NSHeight(f) < 2)
        return;
    f.size.height -= 1;
    [tab->pageView setFrame:f];
    g_timeout_add(60, restorePageSize, [tab retain]);
}

- (void)adoptTab:(FBTab *)tab
{
    tab->owner = self;
    NSUInteger at = current ? [tabs indexOfObject:current] + 1 : [tabs count];
    [tabs insertObject:tab atIndex:MIN(at, [tabs count])];
    WPEView *wpeView = webkit_web_view_get_wpe_view(tab->webView);
    wpe_view_set_visible(wpeView, FALSE);
    wpe_view_set_toplevel(wpeView, toplevel);
    [self selectTab:tab];
    [self layoutChrome];
    nudgeRepaint(tab);
}

- (NSRect)stripRectOnScreen
{
    NSRect r = [tabBar convertRect:[tabBar bounds] toView:nil];
    r.origin = [window convertBaseToScreen:r.origin];
    return r;
}

/* A tab dropped away from the strip: onto another window's strip, or into a window of its own there. */
- (void)tearOffTab:(FBTab *)tab atScreenPoint:(NSPoint)point
{
    FBWindowController *dest = nil;
    for (NSWindow *w in [NSApp orderedWindows]) {
        FBWindowController *c = controllerForWindow(w);
        if (c && c != self && [w isVisible] && ![w isMiniaturized] && NSPointInRect(point, NSInsetRect([c stripRectOnScreen], 0, -8))) {
            dest = c;
            break;
        }
    }
    if (!(tab = [self releaseTab:tab]))
        return;
    if (!dest) {
        dest = newBrowserWindow();
        NSRect f = [dest->window frame];
        f.size = [window frame].size;
        f.origin = NSMakePoint(point.x - 120, point.y + 20 - NSHeight(f));
        [dest->window setFrame:[dest->window constrainFrameRect:f toScreen:[window screen]] display:NO];
    }
    [dest adoptTab:tab];
    [dest show];
}

- (void)closeWindow
{
    if (closing)
        return;
    closing = YES;
    [self retain];
    [omnibox hide];
    if (omnibox)
        omnibox->owner = nil;               /* a suggestion request may still be on its way */
    [bubble close];
    if (tabBar->spinner) {
        g_source_remove(tabBar->spinner);
        tabBar->spinner = 0;
    }
    while ([tabs count])
        [self closeTab:[tabs lastObject]];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [location setDelegate:nil];
    [location setTarget:nil];
    for (NSView *v in [toolbar subviews])
        if ([v isKindOfClass:[NSControl class]])
            [(NSControl *)v setTarget:nil];
    [addressField->star setTarget:nil];
    [tabBar->newTabButton setTarget:nil];
    [findField setTarget:nil];
    [findField setDelegate:nil];
    BOOL wasKey = [window isKeyWindow];
    [window orderOut:nil];
    if (wasKey)                             /* orderOut: leaves the application with no key window */
        for (NSWindow *w in [NSApp orderedWindows])
            if (w != window && controllerForWindow(w) && [w isVisible] && ![w isMiniaturized]) {
                [w makeKeyAndOrderFront:nil];
                break;
            }
    tabBar->owner = nil;                    /* the frame view outlives this controller */
    toolbar->owner = nil;
    bookmarksBar->owner = nil;
    [tabBar removeFromSuperview];
    if (toplevel) {
        wpe_toplevel_cocoa_set_should_close_func(WPE_TOPLEVEL_COCOA(toplevel), NULL, NULL);
        g_idle_add(unrefLater, toplevel);   /* releases the NSWindow once AppKit is done with it */
        toplevel = NULL;
    }
    [fbWindows removeObject:self];          /* like Camino, the application keeps running with no windows */
    [self autorelease];
}

/* Close button, Cmd-Shift-W: with several tabs, ask first (Tabs preferences). */
- (void)requestClose
{
    if (closing || [window attachedSheet])
        return;
    if ([tabs count] < 2 || ![prefs() boolForKey:PrefWarnClosingTabs]) {
        [self closeWindow];
        return;
    }
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:[NSString stringWithFormat:@"Close %lu tabs?", (unsigned long)[tabs count]]];
    [alert setInformativeText:@"This window has several tabs open. Closing it closes all of them."];
    [alert addButtonWithTitle:@"Close Window"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert setShowsSuppressionButton:YES];
    [[alert suppressionButton] setTitle:@"Don't ask again"];
    [alert beginSheetModalForWindow:window modalDelegate:self
                     didEndSelector:@selector(closeAlertDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void)closeAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)code contextInfo:(void *)info
{
    (void)info;
    [[alert window] orderOut:nil];
    if (code != NSAlertFirstButtonReturn)
        return;
    if ([[alert suppressionButton] state] == NSOnState)
        [prefs() setBool:NO forKey:PrefWarnClosingTabs];
    [self closeWindow];
}

- (void)tabChanged:(FBTab *)tab
{
    [tabBar tabsChanged];
    if (tab == current)
        [self updateChrome];
}

/* ---- current tab -> chrome ---- */

- (BOOL)locationIsBeingEdited { return [addressField isEditing]; }

- (void)updateChromeForcingLocation
{
    NSString *uri = current ? [current uri] : nil;
    [location setStringValue:uri ?: @""];
}

- (BOOL)isBookmarked:(NSString *)uri
{
    for (NSDictionary *b in fbBookmarks)
        if ([[b objectForKey:@"URL"] isEqual:uri])
            return YES;
    return NO;
}

- (void)updateStatus
{
    NSString *s = nil;
    if (current) {
        if (current->hoverLink)
            s = current->hoverLink;
        else if ([current isLoading]) {
            const char *uri = webkit_web_view_get_uri(current->webView);
            GUri *parsed = uri ? g_uri_parse(uri, G_URI_FLAGS_NONE, NULL) : NULL;
            const char *h = parsed ? g_uri_get_host(parsed) : NULL;
            s = h && *h ? [NSString stringWithFormat:str("Loading %@\xe2\x80\xa6"), str(h)] : str("Loading\xe2\x80\xa6");
            if (parsed)
                g_uri_unref(parsed);
        }
    }
    if ([prefs() boolForKey:PrefShowStatusBar]) {
        [bubble setText:nil pageFrame:NSZeroRect];
        [statusText setStringValue:s ?: @""];
    } else
        [bubble setText:s pageFrame:[contentHost convertRect:[contentHost bounds] toView:nil]];
}

- (void)updateChrome
{
    if (!current)
        return;
    WebKitWebView *v = current->webView;
    if (![self locationIsBeingEdited])
        [self updateChromeForcingLocation];
    [window setTitle:[current title]];
    BOOL loading = webkit_web_view_is_loading(v);
    double p = loading ? webkit_web_view_get_estimated_load_progress(v) : -1;
    if (p != loadProgress) {
        loadProgress = p;
        [toolbar setNeedsDisplayInRect:NSMakeRect(0, 0, NSWidth([toolbar bounds]), 2)];
    }
    [backButton setEnabled:webkit_web_view_can_go_back(v)];
    [forwardButton setEnabled:webkit_web_view_can_go_forward(v)];
    FBIcon reloadIcon = loading ? FBIconStop : FBIconReload;
    if (reloadButton->icon != reloadIcon) {
        reloadButton->icon = reloadIcon;
        [reloadButton setAction:loading ? @selector(stopLoading:) : @selector(reload:)];
        [reloadButton setLabel:loading ? @"Stop" : @"Reload"
                           tip:loading ? str("Stop loading this page (\xe2\x8c\x98.)") : str("Reload this page (\xe2\x8c\x98R)")];
        [reloadButton setNeedsDisplay:YES];
    }
    GTlsCertificate *cert = NULL;
    GTlsCertificateFlags errors = 0;
    const char *uri = webkit_web_view_get_uri(v);
    BOOL secure = uri && !g_ascii_strncasecmp(uri, "https://", 8) && webkit_web_view_get_tls_info(v, &cert, &errors) && !errors;
    if (secure != addressField->secure) {
        addressField->secure = secure;
        [addressField setNeedsDisplay:YES];
    }
    NSString *u = [current uri];
    BOOL marked = u && [self isBookmarked:u];
    if (marked != addressField->star->filled || [addressField->star isEnabled] != (u != nil)) {
        addressField->star->filled = marked;
        [addressField->star setEnabled:u != nil];
        [addressField->star setLabel:marked ? @"Remove bookmark" : @"Bookmark this page"
                                 tip:marked ? @"Remove this page from the bookmarks" : str("Bookmark this page (\xe2\x8c\x98" "D)")];
        [addressField->star setNeedsDisplay:YES];
    }
    [self updateStatus];
}

- (void)downloadsChanged
{
    double p = downloadsProgress();
    if (p != downloadsButton->progress) {
        downloadsButton->progress = p;
        [downloadsButton setNeedsDisplay:YES];
    }
}

/* ---- user actions ---- */

- (void)loadURL:(const char *)url
{
    if (!url || !current)
        return;
    webkit_web_view_load_uri(current->webView, url);
    [window makeFirstResponder:current->pageView];
}

- (void)locationEntered:(id)sender
{
    (void)sender;
    if ([omnibox activateSelection])
        return;
    char *url = urlForLocationText([[location stringValue] UTF8String]);
    [self loadURL:url];
    g_free(url);
}

- (void)controlTextDidChange:(NSNotification *)n
{
    if ([n object] == location) {
        if (!omnibox)
            omnibox = [[FBOmnibox alloc] initWithOwner:self];
        [omnibox textChanged];
    }
    else if ([n object] == findField)
        [self findTextChanged];
}

/* Escape puts the page's address back; arrows move through the dropdown. */
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
    (void)textView;
    if (control == location) {
        if ([omnibox handleCommand:command])
            return YES;
        if (command == @selector(cancelOperation:)) {
            [self updateChromeForcingLocation];
            if (current)
                [window makeFirstResponder:current->pageView];
            return YES;
        }
    }
    if (control == findField) {
        if (command == @selector(cancelOperation:)) {
            [self hideFindBar];
            return YES;
        }
        if (command == @selector(insertNewline:)) {
            if ([[NSApp currentEvent] modifierFlags] & NSShiftKeyMask)
                [self findPrevious:nil];
            else
                [self findNext:nil];
            return YES;
        }
    }
    return NO;
}

#define CURRENT_VIEW (current ? current->webView : NULL)
- (void)goBack:(id)s { (void)s; if (current) webkit_web_view_go_back(current->webView); }
- (void)goForward:(id)s { (void)s; if (current) webkit_web_view_go_forward(current->webView); }
- (void)reload:(id)s { (void)s; if (current) webkit_web_view_reload(current->webView); }
- (void)reloadIgnoringCache:(id)s { (void)s; if (current) webkit_web_view_reload_bypass_cache(current->webView); }
- (void)stopLoading:(id)s { (void)s; if (current) webkit_web_view_stop_loading(current->webView); }
- (void)goHome:(id)s { (void)s; [self loadURL:homeURL()]; }
- (void)makeTextBigger:(id)s
{
    (void)s;
    if (current)
        webkit_web_view_set_zoom_level(current->webView, MIN(webkit_web_view_get_zoom_level(current->webView) * 1.1, 4.0));
}
- (void)makeTextSmaller:(id)s
{
    (void)s;
    if (current)
        webkit_web_view_set_zoom_level(current->webView, MAX(webkit_web_view_get_zoom_level(current->webView) / 1.1, 0.25));
}
- (void)makeTextActualSize:(id)s { (void)s; if (current) webkit_web_view_set_zoom_level(current->webView, 1.0); }

- (void)newTab:(id)s
{
    (void)s;
    [self addTabWithURL:prefIs(PrefNewTabPage, @"Home") ? homeURL() : "about:blank" relatedTo:NULL select:YES];
}
- (void)closeCurrentTab:(id)s { (void)s; if (current) [self closeTab:current]; }
- (void)closeBrowserWindow:(id)s { (void)s; [self requestClose]; }

- (void)selectTabOffset:(NSInteger)delta
{
    NSInteger n = (NSInteger)[tabs count];
    if (n < 2 || !current)
        return;
    NSInteger i = ((NSInteger)[tabs indexOfObject:current] + delta + n) % n;
    [self selectTab:[tabs objectAtIndex:i]];
}
- (void)nextTab:(id)s { (void)s; [self selectTabOffset:1]; }
- (void)previousTab:(id)s { (void)s; [self selectTabOffset:-1]; }

- (void)focusLocation:(id)s
{
    (void)s;
    [window makeFirstResponder:location];
    [location selectText:nil];
}

- (void)focusSearch:(id)s { [self focusLocation:s]; }

- (void)addBookmark:(id)s
{
    (void)s;
    NSString *uri = current ? [current uri] : nil;
    if (!uri || [self isBookmarked:uri])
        return;
    [fbBookmarks addObject:makeBookmark([current title], uri)];
    bookmarksChanged();
    [self updateChrome];
}

/* The star: bookmark the page, or take it out of the bookmarks again. */
- (void)toggleBookmark:(id)s
{
    NSString *uri = current ? [current uri] : nil;
    if (!uri)
        return;
    if (![self isBookmarked:uri]) {
        [self addBookmark:s];
        return;
    }
    for (NSDictionary *b in [[fbBookmarks copy] autorelease])
        if ([[b objectForKey:@"URL"] isEqual:uri])
            [fbBookmarks removeObjectIdenticalTo:b];
    bookmarksChanged();
    [self updateChrome];
}

/* ---- the FrostByte, History and Downloads menus ---- */

/* Pop a menu under a toolbar button (10.5 has no -popUpMenuPositioningItem:), right-aligned to it
 * when alignRight, through a pull-down cell. */
- (void)popMenu:(NSMenu *)menu under:(NSView *)button width:(CGFloat)width alignRight:(BOOL)alignRight
{
    [menu insertItemWithTitle:@"" action:NULL keyEquivalent:@"" atIndex:0];   /* a pull-down's title item */
    NSPopUpButtonCell *cell = [[[NSPopUpButtonCell alloc] initTextCell:@"" pullsDown:YES] autorelease];
    [cell setMenu:menu];
    [cell setAltersStateOfSelectedItem:NO];
    NSRect b = [button bounds];
    NSRect r = NSMakeRect(alignRight ? NSMaxX(b) - width : NSMinX(b), NSMinY(b) - 2, width, NSHeight(b) + 4);
    [cell performClickWithFrame:r inView:button];
}

static NSMenuItem *menuItem(NSMenu *m, NSString *title, id target, SEL action, NSString *key, NSUInteger mods)
{
    NSMenuItem *it = [m addItemWithTitle:title action:action keyEquivalent:key ?: @""];
    [it setKeyEquivalentModifierMask:mods];
    [it setTarget:target];
    return it;
}

- (void)openMenuURL:(NSMenuItem *)item
{
    const char *url = [[item representedObject] UTF8String];
    NSUInteger mods = [[NSApp currentEvent] modifierFlags];
    if (mods & NSCommandKeyMask)
        [self addTabWithURL:url relatedTo:NULL select:!(mods & NSShiftKeyMask)];
    else
        [self loadURL:url];
}

static NSString *menuTitle(NSString *title, NSString *url)
{
    NSString *t = [title length] ? title : displayURL(url);
    return [t length] > 52 ? [[t substringToIndex:50] stringByAppendingString:str("\xe2\x80\xa6")] : t;
}

- (NSMenu *)bookmarksMenu
{
    NSMenu *m = [[[NSMenu alloc] initWithTitle:@"Bookmarks"] autorelease];
    menuItem(m, @"Bookmark This Page", self, @selector(addBookmark:), @"d", NSCommandKeyMask);
    [m addItem:[NSMenuItem separatorItem]];
    for (NSDictionary *b in fbBookmarks) {
        NSMenuItem *it = menuItem(m, menuTitle([b objectForKey:@"Title"], [b objectForKey:@"URL"]), self,
                                  @selector(openMenuURL:), nil, 0);
        [it setRepresentedObject:[b objectForKey:@"URL"]];
        [it setToolTip:[b objectForKey:@"URL"]];
    }
    return m;
}

- (void)showFrostByteMenu:(id)s
{
    (void)s;
    const NSUInteger cmd = NSCommandKeyMask, optCmd = NSCommandKeyMask | NSAlternateKeyMask;
    NSMenu *m = [[[NSMenu alloc] initWithTitle:@"FrostByte"] autorelease];
    menuItem(m, @"New Tab", self, @selector(newTab:), @"t", cmd);
    menuItem(m, @"New Window", nil, @selector(newWindow:), @"n", cmd);
    [m addItem:[NSMenuItem separatorItem]];
    menuItem(m, @"History", nil, @selector(showHistoryWindow:), @"y", cmd);
    menuItem(m, @"Downloads", nil, @selector(showDownloadsWindow:), @"l", optCmd);
    [[m addItemWithTitle:@"Bookmarks" action:NULL keyEquivalent:@""] setSubmenu:[self bookmarksMenu]];
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *zoom = [m addItemWithTitle:@"Zoom" action:NULL keyEquivalent:@""];
    [zoom setView:[[[FBZoomMenuView alloc] initWithOwner:self] autorelease]];
    [m addItem:[NSMenuItem separatorItem]];
    menuItem(m, str("Find in Page\xe2\x80\xa6"), self, @selector(showFind:), @"f", cmd);
    menuItem(m, str("Print\xe2\x80\xa6"), self, @selector(printPage:), @"p", cmd);
    menuItem(m, @"View Source", self, @selector(viewSource:), @"u", optCmd);
    [m addItem:[NSMenuItem separatorItem]];
    menuItem(m, str("Preferences\xe2\x80\xa6"), nil, @selector(showPreferences:), @",", cmd);
    menuItem(m, @"About FrostByte", nil, @selector(showAbout:), nil, 0);
    menuItem(m, str("Check for Updates\xe2\x80\xa6"), nil, @selector(checkForUpdates:), nil, 0);   /* the app delegate (fb-update.m) */
    [self popMenu:m under:menuButton width:300 alignRight:YES];
}

- (void)clearHistory:(id)s
{
    (void)s;
    clearHistory();
}

- (void)showHistory:(id)s
{
    (void)s;
    NSMenu *m = [[[NSMenu alloc] initWithTitle:@"History"] autorelease];
    NSArray *recent = recentHistory(20);
    if (![recent count])
        [[m addItemWithTitle:@"No history yet" action:NULL keyEquivalent:@""] setEnabled:NO];
    for (NSDictionary *d in recent) {
        NSMenuItem *it = menuItem(m, menuTitle([d objectForKey:@"Title"], [d objectForKey:@"URL"]), self,
                                  @selector(openMenuURL:), nil, 0);
        [it setRepresentedObject:[d objectForKey:@"URL"]];
        [it setToolTip:[d objectForKey:@"URL"]];
    }
    [m addItem:[NSMenuItem separatorItem]];
    menuItem(m, str("Show All History\xe2\x80\xa6"), nil, @selector(showHistoryWindow:), @"y", NSCommandKeyMask);
    menuItem(m, @"Clear History", self, @selector(clearHistory:), nil, 0);
    [self popMenu:m under:historyButton width:320 alignRight:YES];
}

- (void)downloadClicked:(NSMenuItem *)item
{
    FBDownload *d = [item representedObject];
    if (d->state == FBDownloadActive)
        cancelDownload(d);
    else
        revealDownload(d);
}
- (void)openDownloadsFolder:(id)s { (void)s; openDownloadsFolder(); }
- (void)clearDownloads:(id)s { (void)s; clearFinishedDownloads(); }

- (void)showDownloads:(id)s
{
    (void)s;
    NSMenu *m = [[[NSMenu alloc] initWithTitle:@"Downloads"] autorelease];
    if (![fbDownloads count])
        [[m addItemWithTitle:@"No downloads" action:NULL keyEquivalent:@""] setEnabled:NO];
    NSUInteger n = 0;
    for (FBDownload *d in fbDownloads) {
        if (n++ == 15)
            break;
        NSString *title = [NSString stringWithFormat:str("%@ \xe2\x80\x94 %@"), d->name, [d status]];
        NSMenuItem *it = menuItem(m, title, self, @selector(downloadClicked:), nil, 0);
        [it setRepresentedObject:d];
        [it setToolTip:d->state == FBDownloadActive ? @"Click to cancel" : @"Show in Finder"];
    }
    [m addItem:[NSMenuItem separatorItem]];
    menuItem(m, str("Show All Downloads\xe2\x80\xa6"), nil, @selector(showDownloadsWindow:), @"l",
             NSCommandKeyMask | NSAlternateKeyMask);
    menuItem(m, @"Open Downloads Folder", self, @selector(openDownloadsFolder:), nil, 0);
    menuItem(m, @"Clear Finished", self, @selector(clearDownloads:), nil, 0);
    [self popMenu:m under:downloadsButton width:360 alignRight:YES];
}

- (void)printPage:(id)s { (void)s; }   /* WPE has no print operation: the item stays disabled */

- (void)viewSource:(id)s
{
    (void)s;
    WebKitWebResource *r = current ? webkit_web_view_get_main_resource(current->webView) : NULL;
    if (!r)
        return;
    FBSourceRequest *req = g_new0(FBSourceRequest, 1);
    req->owner = [self retain];
    req->uri = g_strdup(webkit_web_resource_get_uri(r));
    webkit_web_resource_get_data(r, NULL, sourceReady, req);
}

/* ---- Find in Page ---- */

- (void)buildFindBar
{
    CGFloat w = NSWidth([[window contentView] bounds]);
    findBar = [[FBStatusBar alloc] initWithFrame:NSMakeRect(0, 0, w, 34)];
    [findBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    findField = [[NSSearchField alloc] initWithFrame:NSMakeRect(10, 6, 240, 22)];
    [[findField cell] setPlaceholderString:@"Find in page"];
    [[findField cell] setSendsWholeSearchString:NO];
    [[findField cell] setSendsSearchStringImmediately:YES];
    [findField setDelegate:(id)self];
    [findBar addSubview:findField];
    FBToolButton *prev = [FBToolButton buttonWithIcon:FBIconLeft label:@"Previous match" tip:str("Previous match (\xe2\x87\xa7\xe2\x8c\x98G)")
                                               target:self action:@selector(findPrevious:)];
    [prev setFrame:NSMakeRect(256, 3, 28, 28)];
    [findBar addSubview:prev];
    FBToolButton *next = [FBToolButton buttonWithIcon:FBIconRight label:@"Next match" tip:str("Next match (\xe2\x8c\x98G)")
                                               target:self action:@selector(findNext:)];
    [next setFrame:NSMakeRect(286, 3, 28, 28)];
    [findBar addSubview:next];
    findStatus = [[NSTextField alloc] initWithFrame:NSMakeRect(322, 9, 200, 15)];
    [findStatus setEditable:NO];
    [findStatus setBordered:NO];
    [findStatus setDrawsBackground:NO];
    [findStatus setFont:[NSFont systemFontOfSize:11]];
    [findBar addSubview:findStatus];
    FBToolButton *done = [FBToolButton buttonWithIcon:FBIconClose label:@"Close find bar" tip:@"Done (Escape)"
                                               target:self action:@selector(hideFindBar)];
    [done setFrame:NSMakeRect(w - 34, 5, 24, 24)];
    done->round = YES;
    [done setAutoresizingMask:NSViewMinXMargin];
    [findBar addSubview:done];
    [findBar setHidden:YES];
    [[window contentView] addSubview:findBar];
}

- (void)showFind:(id)s
{
    (void)s;
    if (!current)
        return;
    if (!findBar)
        [self buildFindBar];
    [findStatus setTextColor:palette()->textSoft];
    if ([findBar isHidden]) {
        [findBar setHidden:NO];
        [self layoutChrome];
    }
    [window makeFirstResponder:findField];
    [findField selectText:nil];
    if ([[findField stringValue] length])
        [self findTextChanged];
}

- (void)hideFindBar
{
    if (findTab) {
        WebKitFindController *fc = webkit_web_view_get_find_controller(findTab->webView);
        g_signal_handlers_disconnect_by_data(fc, self);
        webkit_find_controller_search_finish(fc);
        findTab = nil;
    }
    if (findBar && ![findBar isHidden]) {
        BOOL hadFocus = [[window firstResponder] isKindOfClass:[NSTextView class]]
                        && [(NSTextView *)[window firstResponder] delegate] == (id)findField;
        [findBar setHidden:YES];
        [self layoutChrome];
        if (hadFocus && current)
            [window makeFirstResponder:current->pageView];
    }
}

- (WebKitFindController *)findController
{
    if (!current)
        return NULL;
    WebKitFindController *fc = webkit_web_view_get_find_controller(current->webView);
    if (findTab != current) {
        if (findTab)
            g_signal_handlers_disconnect_by_data(webkit_web_view_get_find_controller(findTab->webView), self);
        findTab = current;
        g_signal_connect(fc, "found-text", G_CALLBACK(findFound), self);
        g_signal_connect(fc, "failed-to-find-text", G_CALLBACK(findFailed), self);
    }
    return fc;
}

- (void)findTextChanged
{
    WebKitFindController *fc = [self findController];
    const char *q = [[findField stringValue] UTF8String];
    if (!fc)
        return;
    if (!q || !*q) {
        webkit_find_controller_search_finish(fc);
        [findStatus setStringValue:@""];
        return;
    }
    webkit_find_controller_search(fc, q, WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE | WEBKIT_FIND_OPTIONS_WRAP_AROUND, 1000);
}

- (void)findNext:(id)s
{
    (void)s;
    if (!findBar || [findBar isHidden] || ![[findField stringValue] length]) {
        [self showFind:nil];
        return;
    }
    WebKitFindController *fc = [self findController];
    if (fc && webkit_find_controller_get_search_text(fc))
        webkit_find_controller_search_next(fc);
    else
        [self findTextChanged];
}

- (void)findPrevious:(id)s
{
    (void)s;
    if (!findBar || [findBar isHidden] || ![[findField stringValue] length]) {
        [self showFind:nil];
        return;
    }
    WebKitFindController *fc = [self findController];
    if (fc && webkit_find_controller_get_search_text(fc))
        webkit_find_controller_search_previous(fc);
    else
        [self findTextChanged];
}

- (BOOL)pageHasFocus { return current && [window firstResponder] == current->pageView; }

- (void)editingCommand:(const char *)command
{
    if (current)
        webkit_web_view_execute_editing_command(current->webView, command);
}

- (BOOL)validateAction:(SEL)action
{
    WebKitWebView *v = CURRENT_VIEW;
    if (action == @selector(goBack:)) return v && webkit_web_view_can_go_back(v);
    if (action == @selector(goForward:)) return v && webkit_web_view_can_go_forward(v);
    if (action == @selector(stopLoading:)) return v && webkit_web_view_is_loading(v);
    if (action == @selector(nextTab:) || action == @selector(previousTab:)) return [tabs count] > 1;
    if (action == @selector(addBookmark:)) return current && [current uri] != nil && ![self isBookmarked:[current uri]];
    if (action == @selector(toggleBookmark:)) return current && [current uri] != nil;
    if (action == @selector(printPage:)) return NO;
    if (action == @selector(viewSource:)) return v && webkit_web_view_get_main_resource(v) && [current uri];
    if (action == @selector(showHistory:) || action == @selector(showDownloads:) || action == @selector(clearHistory:)
        || action == @selector(openDownloadsFolder:) || action == @selector(clearDownloads:) || action == @selector(downloadClicked:)
        || action == @selector(openMenuURL:) || action == @selector(newTab:))
        return YES;
    return v != NULL;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item { return [self validateAction:[item action]]; }

@end

/* ------------------------------------------------------------------------------------------ */

FBWindowController *controllerForWindow(NSWindow *w)
{
    for (FBWindowController *c in fbWindows)
        if (c->window == w)
            return c;
    return nil;
}

/* A browser window with no tabs yet (the caller adds them and shows it). */
FBWindowController *newBrowserWindow(void)
{
    FBWindowController *c = [[FBWindowController alloc] init];
    [fbWindows addObject:c];
    [c release];
    return c;
}

/* url NULL: what the General preferences say new windows open with. */
FBWindowController *openWindow(const char *url)
{
    FBWindowController *c = newBrowserWindow();
    if (!url)
        url = prefIs(PrefNewWindowPage, @"Blank") ? "about:blank" : homeURL();
    [c addTabWithURL:url relatedTo:NULL select:YES];
    [c show];
    return c;
}

/* Everything that can follow a preference change while running. */
void applyLivePreferences(void)
{
    paletteChanged();
    setPageDarkMode();
    for (FBWindowController *c in fbWindows)
        [c applyAppearance];
}

