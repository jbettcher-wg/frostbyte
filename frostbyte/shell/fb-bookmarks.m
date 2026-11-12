/*
 * FrostByte: bookmarks (stored as a property list) and the bookmarks bar.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"

NSMutableArray *fbBookmarks;

/* ---- bookmarks: ~/Library/Application Support/FrostByte/Bookmarks.plist, an array of { Title, URL } ---- */

static NSString *bookmarksPath(void)
{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *dir = [([dirs count] ? [dirs objectAtIndex:0] : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"])
                     stringByAppendingPathComponent:@"FrostByte"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"Bookmarks.plist"];
}

void bookmarksChanged(void)
{
    if (![fbBookmarks writeToFile:bookmarksPath() atomically:YES])
        fprintf(stderr, "frostbyte: cannot write %s\n", [bookmarksPath() UTF8String]);
    for (FBWindowController *c in fbWindows)
        [c->bookmarksBar setNeedsDisplay:YES];
}

NSDictionary *makeBookmark(NSString *title, NSString *url)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:title, @"Title", url, @"URL", nil];
}

void loadBookmarks(void)
{
    NSArray *saved = [NSArray arrayWithContentsOfFile:bookmarksPath()];
    if (saved) {
        fbBookmarks = [saved mutableCopy];
        return;
    }
    fbBookmarks = [[NSMutableArray alloc] initWithObjects:
        makeBookmark(@"PowerPC", @"https://en.wikipedia.org/wiki/PowerPC"),
        makeBookmark(@"Wikipedia", @"https://en.wikipedia.org/"),
        makeBookmark(@"Macintosh Garden", @"https://macintoshgarden.org/"),
        makeBookmark(@"Low End Mac", @"https://lowendmac.com/"),
        makeBookmark(@"MacRumors Forums", @"https://forums.macrumors.com/"),
        makeBookmark(@"Hacker News", @"https://news.ycombinator.com/"),
        makeBookmark(@"WebKit", @"https://webkit.org/"),
        makeBookmark(@"DuckDuckGo", @"https://html.duckduckgo.com/html/"), nil];
    bookmarksChanged();
}

/* ---- the sites' icons, from WebKit's favicon database ----
 * url -> { Icon, Dark } once known, NSNull while asked for or when the database has none (then a tab
 * showing a page on the same host fills it in). */
static NSMutableDictionary *s_icons;

static void redrawBars(void)
{
    for (FBWindowController *c in fbWindows)
        [c->bookmarksBar setNeedsDisplay:YES];
}

static void iconArrived(GObject *object, GAsyncResult *result, gpointer data)
{
    char *url = data;
    GError *error = NULL;
    WebKitImageList *list = webkit_favicon_database_get_page_icons_finish(WEBKIT_FAVICON_DATABASE(object), result, &error);
    FB_POOL_BEGIN;
    BOOL dark = NO;
    NSImage *icon = list ? iconFromPageIcons(list, &dark) : nil;
    if (icon) {
        [s_icons setObject:[NSDictionary dictionaryWithObjectsAndKeys:icon, @"Icon", [NSNumber numberWithBool:dark], @"Dark", nil]
                    forKey:str(url)];
        redrawBars();
    }
    FB_POOL_END;
    if (list)
        webkit_image_list_unref(list);
    g_clear_error(&error);
    g_free(url);
}

NSImage *bookmarkIcon(NSString *url, BOOL *dark)
{
    if (!s_icons)
        s_icons = [[NSMutableDictionary alloc] init];
    id known = [s_icons objectForKey:url];
    if ([known isKindOfClass:[NSDictionary class]]) {
        *dark = [[known objectForKey:@"Dark"] boolValue];
        return [known objectForKey:@"Icon"];
    }
    if (!known) {
        [s_icons setObject:[NSNull null] forKey:url];
        WebKitWebsiteDataManager *m = webkit_network_session_get_website_data_manager(webkit_network_session_get_default());
        WebKitFaviconDatabase *db = m ? webkit_website_data_manager_get_favicon_database(m) : NULL;
        if (db)
            webkit_favicon_database_get_page_icons(db, [url UTF8String], NULL, iconArrived, g_strdup([url UTF8String]));
    }
    *dark = NO;
    return nil;
}

static NSString *hostOf(NSString *url)
{
    NSString *h = [[NSURL URLWithString:url] host];
    return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
}

void bookmarkIconSeen(const char *pageURI, NSImage *icon, BOOL dark)
{
    if (!icon || !pageURI || !s_icons)
        return;
    NSString *host = hostOf(str(pageURI));
    BOOL changed = NO;
    for (NSDictionary *b in fbBookmarks) {
        NSString *url = [b objectForKey:@"URL"];
        if (![[s_icons objectForKey:url] isKindOfClass:[NSDictionary class]] && [hostOf(url) isEqual:host]) {
            [s_icons setObject:[NSDictionary dictionaryWithObjectsAndKeys:icon, @"Icon", [NSNumber numberWithBool:dark], @"Dark", nil]
                        forKey:url];
            changed = YES;
        }
    }
    if (changed)
        redrawBars();
}

static NSDictionary *bookmarkAttrs(void)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont systemFontOfSize:11], NSFontAttributeName, palette()->textSoft, NSForegroundColorAttributeName, nil];
}

static const CGFloat kBookmarkPad = 8, kChevronWidth = 20, kBookmarkIcon = 14, kBookmarkIconGap = 6;

@implementation FBBookmarksBar

- (BOOL)isOpaque { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (NSRect)rectForItem:(NSUInteger)i
{
    NSDictionary *attrs = bookmarkAttrs();
    CGFloat x = 10;
    for (NSUInteger k = 0; k <= i && k < [fbBookmarks count]; k++) {
        CGFloat w = ceil([[[fbBookmarks objectAtIndex:k] objectForKey:@"Title"] sizeWithAttributes:attrs].width) + 2 * kBookmarkPad
                    + kBookmarkIcon + kBookmarkIconGap;
        w = MIN(w, 220);
        if (k == i)
            return NSMakeRect(x, 4, w, kBookmarksBarHeight - 8);
        x += w + 2;
    }
    return NSZeroRect;
}

/* how many items fit before the overflow chevron */
- (NSUInteger)visibleCount
{
    NSUInteger n = [fbBookmarks count];
    CGFloat limit = NSWidth([self bounds]) - 4;
    if (n && NSMaxX([self rectForItem:n - 1]) <= limit)
        return n;
    limit -= kChevronWidth;
    NSUInteger i = 0;
    while (i < n && NSMaxX([self rectForItem:i]) <= limit)
        i++;
    return i;
}

- (NSRect)chevronRect { return NSMakeRect(NSWidth([self bounds]) - kChevronWidth - 8, 4, kChevronWidth, kBookmarksBarHeight - 8); }

- (NSInteger)itemAtPoint:(NSPoint)p
{
    NSUInteger n = [self visibleCount];
    for (NSUInteger i = 0; i < n; i++)
        if (NSPointInRect(p, [self rectForItem:i]))
            return (NSInteger)i;
    if (n < [fbBookmarks count] && NSPointInRect(p, [self chevronRect]))
        return -2;
    return -1;
}

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    const FBPalette *t = palette();
    NSRect b = [self bounds];
    [t->bar set];
    NSRectFill(b);
    hline(0, NSWidth(b), 0, t->divider);
    NSDictionary *attrs = bookmarkAttrs();
    NSMutableParagraphStyle *para = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [para setLineBreakMode:NSLineBreakByTruncatingTail];
    NSMutableDictionary *itemAttrs = [[attrs mutableCopy] autorelease];
    [itemAttrs setObject:para forKey:NSParagraphStyleAttributeName];
    NSUInteger n = [self visibleCount];
    for (NSUInteger i = 0; i < n; i++) {
        NSRect r = [self rectForItem:i];
        if ((NSInteger)i == hover || (NSInteger)i == pressed) {
            [((NSInteger)i == pressed ? t->buttonPressed : t->buttonHover) set];
            [[NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5] fill];
        }
        NSString *title = [[fbBookmarks objectAtIndex:i] objectForKey:@"Title"];
        NSString *url = [[fbBookmarks objectAtIndex:i] objectForKey:@"URL"];
        BOOL darkIcon = NO;
        NSImage *icon = bookmarkIcon(url, &darkIcon);
        NSRect iconRect = NSMakeRect(NSMinX(r) + kBookmarkPad, floor(NSMidY(r) - kBookmarkIcon / 2), kBookmarkIcon, kBookmarkIcon);
        if (icon && darkIcon && isDark()) {
            [grayA(0.88, 0.9) set];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(iconRect, -1, -1) xRadius:3 yRadius:3] fill];
        }
        drawImageUpright(icon ?: genericPageIcon(isDark()), iconRect, 1);
        CGFloat tx = NSMaxX(iconRect) + kBookmarkIconGap;
        [title drawInRect:NSMakeRect(tx, NSMinY(r) + 3, NSMaxX(r) - kBookmarkPad - tx, 15) withAttributes:itemAttrs];
    }
    if (n < [fbBookmarks count]) {
        NSDictionary *bold = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSFont boldSystemFontOfSize:12], NSFontAttributeName,
            [attrs objectForKey:NSForegroundColorAttributeName], NSForegroundColorAttributeName, nil];
        NSRect c = [self chevronRect];
        if (hover == -2) {
            [t->buttonHover set];
            [[NSBezierPath bezierPathWithRoundedRect:c xRadius:5 yRadius:5] fill];
        }
        [str("\xc2\xbb") drawAtPoint:NSMakePoint(NSMinX(c) + 6, NSMinY(c) + 1) withAttributes:bold];
    }
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (tracking) {
        [self removeTrackingArea:tracking];
        [tracking release];
    }
    tracking = [[NSTrackingArea alloc] initWithRect:[self bounds]
        options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:tracking];
}

- (void)dealloc
{
    [tracking release];
    [super dealloc];
}

- (void)setHoverFrom:(NSEvent *)e
{
    NSInteger h = [self itemAtPoint:[self convertPoint:[e locationInWindow] fromView:nil]];
    if (h != hover) {
        hover = h;
        [self setToolTip:h >= 0 ? [[fbBookmarks objectAtIndex:h] objectForKey:@"URL"] : nil];
        [self setNeedsDisplay:YES];
    }
}
- (void)mouseMoved:(NSEvent *)e { [self setHoverFrom:e]; }
- (void)mouseEntered:(NSEvent *)e { [self setHoverFrom:e]; }
- (void)mouseExited:(NSEvent *)e { (void)e; hover = -1; [self setNeedsDisplay:YES]; }

- (void)openBookmark:(NSDictionary *)b inNewTab:(BOOL)newTab select:(BOOL)select
{
    const char *url = [[b objectForKey:@"URL"] UTF8String];
    if (newTab)
        [owner addTabWithURL:url relatedTo:NULL select:select];
    else
        [owner loadURL:url];
}

- (void)openBookmarkFromMenu:(NSMenuItem *)item { [self openBookmark:[item representedObject] inNewTab:NO select:YES]; }
- (void)openInNewTab:(NSMenuItem *)item { [self openBookmark:[item representedObject] inNewTab:YES select:YES]; }

- (void)removeBookmark:(NSMenuItem *)item
{
    [fbBookmarks removeObjectIdenticalTo:[item representedObject]];
    bookmarksChanged();
}

- (void)mouseDown:(NSEvent *)e
{
    NSInteger i = [self itemAtPoint:[self convertPoint:[e locationInWindow] fromView:nil]];
    if (i == -2) {                                   /* overflow chevron: the rest as a menu */
        NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
        for (NSUInteger k = [self visibleCount]; k < [fbBookmarks count]; k++) {
            NSDictionary *b = [fbBookmarks objectAtIndex:k];
            NSMenuItem *it = [menu addItemWithTitle:[b objectForKey:@"Title"] action:@selector(openBookmarkFromMenu:) keyEquivalent:@""];
            [it setTarget:self];
            [it setRepresentedObject:b];
        }
        [NSMenu popUpContextMenu:menu withEvent:e forView:self];
        return;
    }
    if (i < 0)
        return;
    if ([e modifierFlags] & NSControlKeyMask) {
        [self rightMouseDown:e];
        return;
    }
    pressed = i;
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e
{
    NSInteger i = pressed;
    pressed = -1;
    [self setNeedsDisplay:YES];
    if (i >= 0 && i == [self itemAtPoint:[self convertPoint:[e locationInWindow] fromView:nil]]) {
        NSUInteger mods = [e modifierFlags];
        BOOL background = [prefs() boolForKey:PrefCommandClickBackground];
        if (mods & NSShiftKeyMask)
            background = !background;
        [self openBookmark:[fbBookmarks objectAtIndex:i] inNewTab:(mods & NSCommandKeyMask) != 0 select:!background];
    }
}

- (void)otherMouseUp:(NSEvent *)e                        /* middle-click: a background tab */
{
    NSInteger i = [self itemAtPoint:[self convertPoint:[e locationInWindow] fromView:nil]];
    if (i >= 0)
        [self openBookmark:[fbBookmarks objectAtIndex:i] inNewTab:YES select:NO];
}

- (void)rightMouseDown:(NSEvent *)e
{
    NSInteger i = [self itemAtPoint:[self convertPoint:[e locationInWindow] fromView:nil]];
    if (i < 0)
        return;
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    NSMenuItem *it = [menu addItemWithTitle:@"Open in New Tab" action:@selector(openInNewTab:) keyEquivalent:@""];
    [it setTarget:self];
    [it setRepresentedObject:[fbBookmarks objectAtIndex:i]];
    it = [menu addItemWithTitle:@"Remove Bookmark" action:@selector(removeBookmark:) keyEquivalent:@""];
    [it setTarget:self];
    [it setRepresentedObject:[fbBookmarks objectAtIndex:i]];
    [NSMenu popUpContextMenu:menu withEvent:e forView:self];
}

@end

