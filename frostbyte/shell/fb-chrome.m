/*
 * FrostByte: the window chrome drawn by hand: the palettes of the two appearances, drawing helpers and
 * vector icons, toolbar buttons, the tab strip (in the title bar), the toolbar row, the combined
 * address + search field, the status bar and the status bubble.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"

/* ---- palettes ---- */

NSColor *colorFromHex(NSString *hex)
{
    unsigned v = 0;
    if ([hex length] != 7 || [hex characterAtIndex:0] != '#'
        || ![[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&v])
        return nil;
    return [NSColor colorWithDeviceRed:((v >> 16) & 0xff) / 255.0 green:((v >> 8) & 0xff) / 255.0
                                  blue:(v & 0xff) / 255.0 alpha:1];
}

static NSColor *hex(const char *s) { return colorFromHex(str(s)); }

NSArray *accentChoices(void)
{
    static NSArray *choices;
    if (!choices) {
        const char *rows[][2] = { { "Blue (default)", "Default" }, { "Teal", "#2f9e9a" }, { "Purple", "#7c5cd6" },
                                  { "Orange", "#d9822b" }, { "Graphite", "#6b7280" } };
        NSMutableArray *a = [NSMutableArray array];
        for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++)
            [a addObject:[NSDictionary dictionaryWithObjectsAndKeys:str(rows[i][0]), @"Title", str(rows[i][1]), @"Value", nil]];
        choices = [a retain];
    }
    return choices;
}

static FBPalette s_palette;
static BOOL s_paletteValid;

static void setColor(NSColor **slot, NSColor *c)
{
    [*slot release];
    *slot = [c retain];
}

const FBPalette *palette(void)
{
    if (s_paletteValid)
        return &s_palette;
    FBPalette *p = &s_palette;
    BOOL dark = isDark();
    if (dark) {
        setColor(&p->stripTop, hex("#0e0f11"));
        setColor(&p->stripBottom, hex("#0e0f11"));
        setColor(&p->bar, hex("#1a1b1e"));
        setColor(&p->page, hex("#121315"));
        setColor(&p->field, hex("#26282c"));
        setColor(&p->fieldBorder, hex("#33363b"));
        setColor(&p->text, hex("#e8eaed"));
        setColor(&p->textSoft, hex("#a3a8b0"));
        setColor(&p->tabIdleText, hex("#a3a8b0"));
        setColor(&p->icon, hex("#c3c7cd"));
        setColor(&p->iconOff, hex("#5d6168"));
        setColor(&p->divider, hex("#2c2e33"));
        setColor(&p->popup, hex("#1f2124"));
        setColor(&p->popupBorder, hex("#34373c"));
        setColor(&p->track, hex("#34373c"));
        setColor(&p->hover, hex("#2a2c30"));
        setColor(&p->buttonHover, grayA(1, 0.08));
        setColor(&p->buttonPressed, grayA(1, 0.15));
    } else {
        setColor(&p->stripTop, hex("#d7d7d7"));
        setColor(&p->stripBottom, hex("#cbcbcb"));
        setColor(&p->bar, hex("#f4f4f5"));
        setColor(&p->page, hex("#ffffff"));
        setColor(&p->field, hex("#ffffff"));
        setColor(&p->fieldBorder, hex("#c9ccd1"));
        setColor(&p->text, hex("#1d1f22"));
        setColor(&p->textSoft, hex("#555b65"));
        setColor(&p->tabIdleText, hex("#4a4f57"));
        setColor(&p->icon, hex("#3f444c"));
        setColor(&p->iconOff, hex("#a9adb3"));
        setColor(&p->divider, hex("#d3d5d9"));
        setColor(&p->popup, hex("#ffffff"));
        setColor(&p->popupBorder, hex("#c9ccd1"));
        setColor(&p->track, hex("#e3e5e8"));
        setColor(&p->hover, hex("#e8eef6"));
        setColor(&p->buttonHover, grayA(0, 0.07));
        setColor(&p->buttonPressed, grayA(0, 0.14));
    }
    NSColor *accent = colorFromHex([prefs() stringForKey:PrefAccentColor]);
    setColor(&p->accent, accent ?: hex(dark ? "#5aa9e6" : "#3b82c4"));
    s_paletteValid = YES;
    return p;
}

void paletteChanged(void) { s_paletteValid = NO; }

/* ---- drawing helpers ---- */

void fillGradient(NSRect r, NSColor *top, NSColor *bottom)
{
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:bottom endingColor:top];
    [g drawInRect:r angle:[[NSGraphicsContext currentContext] isFlipped] ? -90 : 90];
    [g release];
}

void hline(CGFloat x0, CGFloat x1, CGFloat y, NSColor *c)
{
    [c set];
    NSRectFillUsingOperation(NSMakeRect(x0, y, x1 - x0, 1), NSCompositeSourceOver);
}

/* NSImage draws upside down into a flipped view on 10.5. */
void drawImageUpright(NSImage *image, NSRect r, CGFloat fraction)
{
    if (!image)
        return;
    NSGraphicsContext *gc = [NSGraphicsContext currentContext];
    if (![gc isFlipped]) {
        [image drawInRect:r fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:fraction];
        return;
    }
    [gc saveGraphicsState];
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:NSMinX(r) yBy:NSMaxY(r)];
    [t scaleXBy:1 yBy:-1];
    [t concat];
    [image drawInRect:NSMakeRect(0, 0, NSWidth(r), NSHeight(r)) fromRect:NSZeroRect operation:NSCompositeSourceOver
             fraction:fraction];
    [gc restoreGraphicsState];
}

NSImage *appIcon(void)
{
    static NSImage *icon;
    if (!icon)
        icon = [resourceImage(@"FrostByte.icns") retain] ?: [[NSApp applicationIconImage] retain];
    return icon;
}

void dragWindow(NSWindow *w, NSEvent *down)
{
    NSPoint start = [w convertBaseToScreen:[down locationInWindow]];
    NSPoint origin = [w frame].origin;
    for (;;) {
        NSEvent *e = [w nextEventMatchingMask:NSLeftMouseDraggedMask | NSLeftMouseUpMask];
        if ([e type] == NSLeftMouseUp)
            break;
        NSPoint now = [NSEvent mouseLocation];
        NSRect f = [w frame];
        f.origin = NSMakePoint(origin.x + now.x - start.x, origin.y + now.y - start.y);
        f = [w constrainFrameRect:f toScreen:[w screen]];      /* the top stays below the menu bar */
        [w setFrameOrigin:f.origin];
    }
}

/* ---- vector icons (the design's SVG paths; y grows downwards) ---- */

NSSize iconSize(FBIcon icon)
{
    switch (icon) {
    case FBIconStar: return NSMakeSize(14, 14);
    case FBIconSearch: return NSMakeSize(13, 13);
    case FBIconLock: return NSMakeSize(12, 14);
    case FBIconClose: return NSMakeSize(8, 8);
    case FBIconPlus: return NSMakeSize(12, 12);
    case FBIconNone: return NSZeroSize;
    default: return NSMakeSize(16, 16);
    }
}

static void M(NSBezierPath *p, CGFloat x, CGFloat y) { [p moveToPoint:NSMakePoint(x, y)]; }
static void L(NSBezierPath *p, CGFloat x, CGFloat y) { [p lineToPoint:NSMakePoint(x, y)]; }

static NSBezierPath *iconPath(FBIcon icon, CGFloat *width)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    *width = 1.6;
    switch (icon) {
    case FBIconBack:
        *width = 1.7;
        M(p, 13, 8); L(p, 3, 8); M(p, 7.5, 3.5); L(p, 3, 8); L(p, 7.5, 12.5);
        break;
    case FBIconForward:
        *width = 1.7;
        M(p, 3, 8); L(p, 13, 8); M(p, 8.5, 3.5); L(p, 13, 8); L(p, 8.5, 12.5);
        break;
    case FBIconReload:
        *width = 1.7;
        [p appendBezierPathWithArcWithCenter:NSMakePoint(8, 8) radius:5 startAngle:0 endAngle:312.6 clockwise:NO];
        M(p, 13, 2.5); L(p, 13, 5.5); L(p, 10, 5.5);
        break;
    case FBIconStop:
        *width = 1.7;
        M(p, 4, 4); L(p, 12, 12); M(p, 12, 4); L(p, 4, 12);
        break;
    case FBIconDownloads:
        M(p, 8, 2); L(p, 8, 10); M(p, 4.5, 6.5); L(p, 8, 10); L(p, 11.5, 6.5); M(p, 2.5, 13.5); L(p, 13.5, 13.5);
        break;
    case FBIconHistory:
        [p appendBezierPathWithArcWithCenter:NSMakePoint(8, 8) radius:5.5 startAngle:180 endAngle:225 clockwise:YES];
        M(p, 2.5, 2.5); L(p, 2.5, 4.9); L(p, 4.9, 4.9); M(p, 8, 5); L(p, 8, 8.2); L(p, 10.2, 9.6);
        break;
    case FBIconStar: {
        *width = 1.4;
        static const CGFloat pts[][2] = { { 7, 1.5 }, { 8.7, 5 }, { 12.5, 5.5 }, { 9.7, 8.1 }, { 10.4, 11.9 },
                                          { 7, 10.1 }, { 3.6, 11.9 }, { 4.3, 8.1 }, { 1.5, 5.5 }, { 5.3, 5 } };
        M(p, pts[0][0], pts[0][1]);
        for (int i = 1; i < 10; i++)
            L(p, pts[i][0], pts[i][1]);
        [p closePath];
        break;
    }
    case FBIconSearch:
        *width = 1.5;
        [p appendBezierPathWithOvalInRect:NSMakeRect(1.5, 1.5, 8, 8)];
        M(p, 8.5, 8.5); L(p, 12, 12);
        break;
    case FBIconLock:
        *width = 1.4;
        [p appendBezierPathWithRoundedRect:NSMakeRect(1.5, 6, 9, 7) xRadius:1.5 yRadius:1.5];
        M(p, 3.5, 6); L(p, 3.5, 4.5);
        [p appendBezierPathWithArcWithCenter:NSMakePoint(6, 4.5) radius:2.5 startAngle:180 endAngle:360 clockwise:NO];
        L(p, 8.5, 6);
        break;
    case FBIconClose:
        *width = 1.4;
        M(p, 1, 1); L(p, 7, 7); M(p, 7, 1); L(p, 1, 7);
        break;
    case FBIconPlus:
        M(p, 6, 1); L(p, 6, 11); M(p, 1, 6); L(p, 11, 6);
        break;
    case FBIconLeft:
        M(p, 10, 3); L(p, 5, 8); L(p, 10, 13);
        break;
    case FBIconRight:
        M(p, 6, 3); L(p, 11, 8); L(p, 6, 13);
        break;
    default:
        break;
    }
    return p;
}

/* topLeft: the icon box's top-left corner in the current view (flipped or not). */
void drawIcon(FBIcon icon, NSPoint topLeft, NSColor *color, BOOL filled)
{
    if (icon == FBIconNone)
        return;
    CGFloat width;
    NSBezierPath *p = iconPath(icon, &width);
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:topLeft.x yBy:topLeft.y];
    if (![[NSGraphicsContext currentContext] isFlipped])
        [t scaleXBy:1 yBy:-1];
    [p transformUsingAffineTransform:t];
    [p setLineWidth:width];
    [p setLineCapStyle:NSRoundLineCapStyle];
    [p setLineJoinStyle:NSRoundLineJoinStyle];
    [color set];
    if (filled)
        [p fill];
    [p stroke];
}

/* ---- toolbar buttons ---- */

@implementation FBToolButton

+ (FBToolButton *)buttonWithIcon:(FBIcon)icon label:(NSString *)label tip:(NSString *)tip target:(id)target action:(SEL)action
{
    FBToolButton *b = [[[FBToolButton alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)] autorelease];
    b->icon = icon;
    b->progress = -1;
    [b setButtonType:NSMomentaryChangeButton];
    [b setBordered:NO];
    [b setTitle:@""];
    [b setTarget:target];
    [b setAction:action];
    [b setLabel:label tip:tip];
    return b;
}

- (void)setLabel:(NSString *)label tip:(NSString *)tip
{
    [[self cell] accessibilitySetOverrideValue:label forAttribute:NSAccessibilityDescriptionAttribute];
    [self setToolTip:tip ?: label];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)dealloc
{
    [picture release];
    [tracking release];
    [super dealloc];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (tracking) {
        [self removeTrackingArea:tracking];
        [tracking release];
    }
    tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:tracking];
}

- (void)mouseEntered:(NSEvent *)e { (void)e; hover = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e { (void)e; hover = NO; [self setNeedsDisplay:YES]; }

/* Menu buttons open on mouse down, like a pop-up button. */
- (void)mouseDown:(NSEvent *)e
{
    if (!popsOnMouseDown || ![self isEnabled]) {
        [super mouseDown:e];
        return;
    }
    [self setState:NSOnState];
    [self display];
    [self sendAction:[self action] to:[self target]];
    [self setState:NSOffState];
    hover = NSPointInRect([self convertPoint:[[self window] mouseLocationOutsideOfEventStream] fromView:nil], [self bounds]);
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    const FBPalette *t = palette();
    NSRect b = [self bounds];
    BOOL enabled = [self isEnabled];
    BOOL pressed = [[self cell] isHighlighted] || [self state] == NSOnState;
    if (enabled && (pressed || hover)) {
        [(pressed ? t->buttonPressed : t->buttonHover) set];
        CGFloat r = round ? NSHeight(b) / 2 : 7;
        [[NSBezierPath bezierPathWithRoundedRect:b xRadius:r yRadius:r] fill];
    }
    if (picture) {
        CGFloat s = pictureSize ?: 20;
        drawImageUpright(picture, NSMakeRect(floor(NSMidX(b) - s / 2), floor(NSMidY(b) - s / 2), s, s), enabled ? 1 : 0.5);
    } else {
        NSSize s = iconSize(icon);
        NSColor *c = !enabled ? t->iconOff : filled ? t->accent : t->icon;
        drawIcon(icon, NSMakePoint(floor(NSMidX(b) - s.width / 2), floor(NSMidY(b) - s.height / 2)), c, filled);
    }
    if (progress >= 0) {
        NSRect track = NSMakeRect(6, NSHeight(b) - 6, NSWidth(b) - 12, 2);
        [t->track set];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:1 yRadius:1] fill];
        track.size.width = MAX(2, floor(NSWidth(track) * MIN(progress, 1)));
        [t->accent set];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:1 yRadius:1] fill];
    }
}

@end

/* ---- the tab strip ---- */

static const CGFloat kTabHeight = 32, kTabMaxWidth = 216, kTabMinWidth = 84, kTabGap = 2, kTabRadius = 9;
static const CGFloat kStripRightPad = 8, kNewTabSize = 28, kArrowWidth = 20;

/* A plain page with a folded corner (16 x 16), drawn for each appearance. */
NSImage *genericPageIcon(BOOL dark)
{
    static NSImage *icons[2];
    if (icons[dark])
        return icons[dark];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
    [image lockFocus];
    NSBezierPath *page = [NSBezierPath bezierPath];
    [page moveToPoint:NSMakePoint(3.5, 1.5)];
    [page lineToPoint:NSMakePoint(12.5, 1.5)];
    [page lineToPoint:NSMakePoint(12.5, 10.5)];
    [page lineToPoint:NSMakePoint(8.5, 14.5)];
    [page lineToPoint:NSMakePoint(3.5, 14.5)];
    [page closePath];
    [(dark ? gray(0.30) : gray(0.98)) set];
    [page fill];
    [(dark ? gray(0.70) : gray(0.48)) set];
    [page setLineWidth:1];
    [page stroke];
    NSBezierPath *fold = [NSBezierPath bezierPath];
    [fold moveToPoint:NSMakePoint(8.5, 14.5)];
    [fold lineToPoint:NSMakePoint(8.5, 10.5)];
    [fold lineToPoint:NSMakePoint(12.5, 10.5)];
    [fold stroke];
    [(dark ? gray(0.58) : gray(0.70)) set];
    for (int i = 0; i < 3; i++)
        NSRectFill(NSMakeRect(5, 4 + 2 * i, 6, 1));
    [image unlockFocus];
    icons[dark] = image;
    return image;
}

static NSBezierPath *topRoundedRect(NSRect r, CGFloat radius)
{
    /* flipped view: the top is NSMinY */
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(NSMinX(r), NSMaxY(r))];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(NSMinX(r), NSMinY(r)) toPoint:NSMakePoint(NSMaxX(r), NSMinY(r)) radius:radius];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(NSMaxX(r), NSMinY(r)) toPoint:NSMakePoint(NSMaxX(r), NSMaxY(r)) radius:radius];
    [p lineToPoint:NSMakePoint(NSMaxX(r), NSMaxY(r))];
    [p closePath];
    return p;
}

static gboolean spinTick(gpointer data);

@implementation FBTabBar

- (id)initWithFrame:(NSRect)f
{
    if (!(self = [super initWithFrame:f]))
        return nil;
    hoverTab = hoverClose = pressedClose = dragTab = -1;
    newTabButton = [[FBToolButton buttonWithIcon:FBIconPlus label:@"New tab" tip:nil
                                         target:nil action:@selector(newTab:)] retain];
    [newTabButton setToolTip:str("Open a new tab (\xe2\x8c\x98T)")];
    [newTabButton setFrame:NSMakeRect(0, kStripHeight - kTabHeight + floor((kTabHeight - kNewTabSize) / 2), kNewTabSize, kNewTabSize)];
    [self addSubview:newTabButton];
    return self;
}

- (void)dealloc
{
    if (spinner)
        g_source_remove(spinner);
    [newTabButton release];
    [tracking release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return YES; }

/* Tabs start right of the window's zoom button. */
- (CGFloat)tabsLeft
{
    NSButton *zoom = [[self window] standardWindowButton:NSWindowZoomButton];
    if (!zoom || ![zoom superview])
        return 76;
    NSRect r = [self convertRect:[zoom frame] fromView:[zoom superview]];
    return floor(NSMaxX(r)) + 12;
}

/* Geometry: tab width, the visible range, and whether the overflow arrows show. */
- (void)metricsWidth:(CGFloat *)tabW first:(NSInteger *)first count:(NSInteger *)count overflow:(BOOL *)overflow
{
    NSInteger n = (NSInteger)[owner->tabs count];
    CGFloat avail = NSWidth([self bounds]) - [self tabsLeft] - kStripRightPad - (4 + kNewTabSize);
    CGFloat w = n ? floor(MIN(kTabMaxWidth, (avail + kTabGap) / n - kTabGap)) : kTabMaxWidth;
    *overflow = n > 0 && w < kTabMinWidth;
    if (!*overflow) {
        *tabW = w;
        *first = 0;
        *count = n;
        return;
    }
    avail -= 2 * kArrowWidth;
    NSInteger fit = MAX(1, (NSInteger)floor((avail + kTabGap) / (kTabMinWidth + kTabGap)));
    *tabW = floor((avail + kTabGap) / fit - kTabGap);
    NSInteger sel = (NSInteger)[owner->tabs indexOfObject:owner->current];
    NSInteger f0 = MAX(0, MIN(firstVisible, n - fit));
    if (sel != NSNotFound && sel >= 0) {
        if (sel < f0)
            f0 = sel;
        else if (sel >= f0 + fit)
            f0 = sel - fit + 1;
    }
    *first = f0;
    *count = fit;
}

- (CGFloat)firstTabX:(BOOL)overflow { return [self tabsLeft] + (overflow ? kArrowWidth : 0); }

- (NSRect)rectForTab:(NSInteger)i
{
    CGFloat w = 0;
    NSInteger first = 0, count = 0;
    BOOL overflow = NO;
    [self metricsWidth:&w first:&first count:&count overflow:&overflow];
    if (i < first || i >= first + count)
        return NSZeroRect;
    return NSMakeRect([self firstTabX:overflow] + (i - first) * (w + kTabGap), kStripHeight - kTabHeight, w, kTabHeight);
}

- (NSRect)closeRectForTab:(NSInteger)i
{
    NSRect r = [self rectForTab:i];
    return NSMakeRect(NSMaxX(r) - 6 - 18, NSMinY(r) + 7, 18, 18);
}

- (BOOL)showsCloseForTab:(NSInteger)i
{
    NSRect r = [self rectForTab:i];
    return NSWidth(r) >= 120 || [owner->tabs objectAtIndex:i] == owner->current || i == hoverTab;
}

- (NSRect)leftArrowRect { return NSMakeRect([self tabsLeft], kStripHeight - kTabHeight, kArrowWidth, kTabHeight); }
- (NSRect)rightArrowRect
{
    CGFloat w = 0;
    NSInteger first = 0, count = 0;
    BOOL overflow = NO;
    [self metricsWidth:&w first:&first count:&count overflow:&overflow];
    return NSMakeRect([self firstTabX:overflow] + count * (w + kTabGap), kStripHeight - kTabHeight, kArrowWidth, kTabHeight);
}

- (NSInteger)tabAtPoint:(NSPoint)p
{
    for (NSInteger i = 0; i < (NSInteger)[owner->tabs count]; i++)
        if (NSPointInRect(p, [self rectForTab:i]))
            return i;
    return -1;
}

/* Called whenever tabs come, go, change or the strip resizes: place "+", run the spinner. */
- (void)tabsChanged
{
    CGFloat w = 0;
    NSInteger first = 0, count = 0;
    BOOL overflow = NO;
    [self metricsWidth:&w first:&first count:&count overflow:&overflow];
    firstVisible = first;
    CGFloat x = overflow ? NSMaxX([self rightArrowRect]) : [self firstTabX:NO] + count * (w + kTabGap) - kTabGap;
    /* Centred on the tabs (which fill the bottom kTabHeight of the strip), not on the whole strip: it sat 4 px high. */
    [newTabButton setFrameOrigin:NSMakePoint(x + 4, kStripHeight - kTabHeight + floor((kTabHeight - kNewTabSize) / 2))];
    [newTabButton setTarget:owner];
    BOOL loading = NO;
    for (FBTab *tab in owner->tabs)
        loading |= [tab isLoading];
    if (loading && !spinner)
        spinner = g_timeout_add(80, spinTick, self);
    else if (!loading && spinner) {
        g_source_remove(spinner);
        spinner = 0;
    }
    [self setNeedsDisplay:YES];
}

- (void)resizeWithOldSuperviewSize:(NSSize)old
{
    [super resizeWithOldSuperviewSize:old];
    [self tabsChanged];
}

- (void)spin
{
    spinPhase = (spinPhase + 1) % 12;
    for (NSInteger i = 0; i < (NSInteger)[owner->tabs count]; i++)
        if ([[owner->tabs objectAtIndex:i] isLoading])
            [self setNeedsDisplayInRect:[self rectForTab:i]];
}

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    const FBPalette *t = palette();
    BOOL dark = isDark();
    NSRect bounds = [self bounds];
    BOOL key = [[self window] isMainWindow];

    /* the strip, with the window's rounded top corners */
    NSBezierPath *frame = topRoundedRect(bounds, 5);
    [NSGraphicsContext saveGraphicsState];
    [frame addClip];
    if (dark) {
        [t->stripTop set];
        NSRectFill(bounds);
    } else
        fillGradient(bounds, key ? t->stripTop : gray(0.91), key ? t->stripBottom : gray(0.87));
    if (!dark)
        hline(0, NSWidth(bounds), 0, grayA(1, 0.55));           /* Leopard's top highlight */
    [NSGraphicsContext restoreGraphicsState];

    CGFloat w = 0;
    NSInteger first = 0, count = 0;
    BOOL overflow = NO;
    [self metricsWidth:&w first:&first count:&count overflow:&overflow];
    NSInteger n = (NSInteger)[owner->tabs count];
    NSInteger selected = (NSInteger)[owner->tabs indexOfObject:owner->current];
    NSMutableParagraphStyle *para = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [para setLineBreakMode:NSLineBreakByTruncatingTail];
    NSFont *font = [NSFont systemFontOfSize:kChromeFontSize];

    if (overflow) {
        NSColor *on = t->icon, *off = t->iconOff;
        NSRect l = [self leftArrowRect], r = [self rightArrowRect];
        drawIcon(FBIconLeft, NSMakePoint(NSMinX(l) + 2, NSMidY(l) - 8), first > 0 ? on : off, NO);
        drawIcon(FBIconRight, NSMakePoint(NSMinX(r) + 2, NSMidY(r) - 8), first + count < n ? on : off, NO);
    }

    for (NSInteger i = first; i < first + count && i < n; i++)
        if (i != dragTab)
            [self drawTab:i inRect:[self rectForTab:i] selected:selected last:first + count font:font para:para];
    if (dragTab >= 0 && dragTab < n) {                          /* the tab being dragged, over the others */
        NSRect r = [self rectForTab:dragTab];
        r.origin.x = dragX;
        if (tearing) {
            [NSGraphicsContext saveGraphicsState];
            CGContextSetAlpha([[NSGraphicsContext currentContext] graphicsPort], 0.5);
        }
        [self drawTab:dragTab inRect:r selected:selected last:first + count font:font para:para];
        if (tearing)
            [NSGraphicsContext restoreGraphicsState];
    }
}

- (void)drawTab:(NSInteger)i inRect:(NSRect)r selected:(NSInteger)selected last:(NSInteger)last
           font:(NSFont *)font para:(NSParagraphStyle *)para
{
    const FBPalette *t = palette();
    BOOL dark = isDark();
    BOOL key = [[self window] isMainWindow];
    FBTab *tab = [owner->tabs objectAtIndex:i];
    {
        BOOL isSelected = i == selected;
        NSColor *textColor;
        if (isSelected) {
            [t->bar set];
            [topRoundedRect(r, kTabRadius) fill];
            if (!dark) {                                            /* a hairline so it reads on the aluminium */
                NSBezierPath *edge = topRoundedRect(NSInsetRect(r, 0.5, 0), kTabRadius);
                [edge setLineWidth:1];
                [grayA(0, 0.10) set];
                [edge stroke];
                [t->bar set];
                NSRectFill(NSMakeRect(NSMinX(r) + 1, NSMaxY(r) - 1, NSWidth(r) - 2, 1));
            }
            textColor = key ? t->text : t->textSoft;
        } else {
            if (i == hoverTab && dragTab < 0) {
                [t->buttonHover set];
                [topRoundedRect(NSInsetRect(r, 0, 2), kTabRadius - 2) fill];
            }
            if (i + 1 != selected && i + 1 < last && i != hoverTab && i + 1 != hoverTab && i != dragTab && i + 1 != dragTab) {
                [t->divider set];
                if (!dark)
                    [grayA(0, 0.16) set];
                NSRectFillUsingOperation(NSMakeRect(NSMaxX(r) + kTabGap / 2 - 0.5, NSMinY(r) + 9, 1, NSHeight(r) - 16),
                                         NSCompositeSourceOver);
            }
            textColor = key ? t->tabIdleText : t->iconOff;
        }
        /* icon: the site's, a spinner while loading, the ice cube for a new tab, else a page */
        NSRect iconRect = NSMakeRect(NSMinX(r) + 12, NSMinY(r) + 8, 16, 16);
        if ([tab isLoading]) {
            NSBezierPath *ring = [NSBezierPath bezierPath];
            CGFloat a = spinPhase * 30;
            [ring appendBezierPathWithArcWithCenter:NSMakePoint(NSMidX(iconRect), NSMidY(iconRect)) radius:6
                                         startAngle:a endAngle:a + 270 clockwise:NO];
            [ring setLineWidth:2];
            [ring setLineCapStyle:NSRoundLineCapStyle];
            [t->accent set];
            [ring stroke];
        } else if (tab->icon) {
            if (dark && tab->iconIsDark) {
                [grayA(0.88, 0.9) set];
                [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(iconRect, -1, -1) xRadius:3 yRadius:3] fill];
            }
            drawImageUpright(tab->icon, iconRect, 1);
        } else if (![tab uri])
            drawImageUpright(appIcon(), iconRect, 1);
        else
            drawImageUpright(genericPageIcon(dark), iconRect, 1);

        BOOL showClose = [self showsCloseForTab:i];
        NSRect close = NSMakeRect(NSMaxX(r) - 6 - 18, NSMinY(r) + 7, 18, 18);
        CGFloat labelX = NSMaxX(iconRect) + 8;
        CGFloat labelRight = showClose ? NSMinX(close) - 2 : NSMaxX(r) - 8;
        NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName,
            para, NSParagraphStyleAttributeName, textColor, NSForegroundColorAttributeName, nil];
        [[tab title] drawInRect:NSMakeRect(labelX, NSMinY(r) + 8, MAX(0, labelRight - labelX), 16) withAttributes:attrs];
        if (showClose) {
            if (i == hoverClose || i == pressedClose) {
                [(i == pressedClose ? t->buttonPressed : t->buttonHover) set];
                [[NSBezierPath bezierPathWithOvalInRect:close] fill];
            }
            drawIcon(FBIconClose, NSMakePoint(NSMinX(close) + 5, NSMinY(close) + 5), t->icon, NO);
        }
    }
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (tracking) {
        [self removeTrackingArea:tracking];
        [tracking release];
    }
    tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:tracking];
}

- (void)updateHover:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    NSInteger tab = [self tabAtPoint:p];
    NSInteger c = (tab >= 0 && [self showsCloseForTab:tab] && NSPointInRect(p, [self closeRectForTab:tab])) ? tab : -1;
    if (tab != hoverTab || c != hoverClose) {
        hoverTab = tab;
        hoverClose = c;
        [self setToolTip:c >= 0 ? @"Close tab" : tab >= 0 ? [[owner->tabs objectAtIndex:tab] title] : nil];
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseMoved:(NSEvent *)e { [self updateHover:e]; }
- (void)mouseEntered:(NSEvent *)e { [self updateHover:e]; }
- (void)mouseExited:(NSEvent *)e
{
    (void)e;
    hoverTab = hoverClose = -1;
    [self setNeedsDisplay:YES];
}

- (void)scrollBy:(NSInteger)delta
{
    CGFloat w = 0;
    NSInteger first = 0, count = 0;
    BOOL overflow = NO;
    [self metricsWidth:&w first:&first count:&count overflow:&overflow];
    if (!overflow)
        return;
    NSInteger n = (NSInteger)[owner->tabs count];
    firstVisible = MAX(0, MIN(first + delta, n - count));
    /* keep the selection inside the visible range by moving it with the scroll */
    NSInteger sel = (NSInteger)[owner->tabs indexOfObject:owner->current];
    if (sel < firstVisible)
        [owner selectTab:[owner->tabs objectAtIndex:firstVisible]];
    else if (sel >= firstVisible + count)
        [owner selectTab:[owner->tabs objectAtIndex:firstVisible + count - 1]];
    [self tabsChanged];
}

- (void)scrollWheel:(NSEvent *)e
{
    CGFloat d = [e deltaY] != 0 ? [e deltaY] : -[e deltaX];
    if (d != 0)
        [self scrollBy:d > 0 ? -1 : 1];
}

- (void)mouseDown:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    NSInteger tab = [self tabAtPoint:p];
    if (tab < 0) {
        CGFloat w;
        NSInteger first, count;
        BOOL overflow;
        [self metricsWidth:&w first:&first count:&count overflow:&overflow];
        if (overflow && NSPointInRect(p, [self leftArrowRect])) {
            [self scrollBy:-1];
            return;
        }
        if (overflow && NSPointInRect(p, [self rightArrowRect])) {
            [self scrollBy:1];
            return;
        }
        if ([e clickCount] == 2)
            [[self window] performZoom:nil];
        else
            dragWindow([self window], e);
        return;
    }
    if ([self showsCloseForTab:tab] && NSPointInRect(p, [self closeRectForTab:tab])) {
        pressedClose = tab;
        [self setNeedsDisplay:YES];
        return;
    }
    FBTab *grabbed = [owner->tabs objectAtIndex:tab];
    [owner selectTab:grabbed];
    [self dragTab:grabbed from:e];
}

/* Drag a tab: along the strip it moves between the others; dropped well above or below the strip it
 * becomes a window of its own, or joins the window whose strip it is dropped on. A window's only tab
 * drags the window, as in Chrome. */
- (void)dragTab:(FBTab *)grabbed from:(NSEvent *)down
{
    NSWindow *w = [self window];
    if ([owner->tabs count] < 2) {
        dragWindow(w, down);
        return;
    }
    [[grabbed retain] autorelease];             /* -tabs is its only owner, and it moves in and out of it */
    NSPoint p = [self convertPoint:[down locationInWindow] fromView:nil];
    NSInteger index = (NSInteger)[owner->tabs indexOfObject:grabbed];
    CGFloat grab = p.x - NSMinX([self rectForTab:index]);
    BOOL moved = NO;
    for (;;) {
        NSEvent *e = [w nextEventMatchingMask:NSLeftMouseDraggedMask | NSLeftMouseUpMask];
        if ([e type] == NSLeftMouseUp)
            break;
        NSPoint q = [self convertPoint:[e locationInWindow] fromView:nil];
        if (!moved && fabs(q.x - p.x) < 4 && fabs(q.y - p.y) < 4)
            continue;
        moved = YES;
        CGFloat tw = 0;
        NSInteger first = 0, count = 0;
        BOOL overflow = NO;
        [self metricsWidth:&tw first:&first count:&count overflow:&overflow];
        CGFloat x0 = [self firstTabX:overflow];
        tearing = q.y < -30 || q.y > kStripHeight + 30;
        dragX = MAX(x0, MIN(q.x - grab, x0 + (count - 1) * (tw + kTabGap)));
        NSInteger target = first + MAX(0, MIN(count - 1, (NSInteger)floor((dragX + tw / 2 - x0) / (tw + kTabGap))));
        index = (NSInteger)[owner->tabs indexOfObject:grabbed];
        if (target != index && !tearing) {
            [owner->tabs removeObjectAtIndex:index];
            [owner->tabs insertObject:grabbed atIndex:target];
            index = target;
        }
        dragTab = index;
        hoverTab = hoverClose = -1;
        [self display];
    }
    BOOL tore = tearing;
    dragTab = -1;
    tearing = NO;
    [self tabsChanged];
    if (moved && tore)
        [owner tearOffTab:grabbed atScreenPoint:[NSEvent mouseLocation]];
}

- (void)mouseDragged:(NSEvent *)e
{
    if (pressedClose < 0)
        return;
    NSInteger was = hoverClose;
    hoverClose = NSPointInRect([self convertPoint:[e locationInWindow] fromView:nil], [self closeRectForTab:pressedClose])
        ? pressedClose : -1;
    if (was != hoverClose)
        [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e
{
    NSInteger tab = pressedClose;
    pressedClose = -1;
    [self setNeedsDisplay:YES];
    if (tab >= 0 && tab < (NSInteger)[owner->tabs count]
        && NSPointInRect([self convertPoint:[e locationInWindow] fromView:nil], [self closeRectForTab:tab]))
        [owner closeTab:[owner->tabs objectAtIndex:tab]];
}

- (void)otherMouseUp:(NSEvent *)e                        /* middle-click closes a tab */
{
    NSInteger tab = [self tabAtPoint:[self convertPoint:[e locationInWindow] fromView:nil]];
    if (tab >= 0)
        [owner closeTab:[owner->tabs objectAtIndex:tab]];
}

- (void)closeTabFromMenu:(NSMenuItem *)item { [owner closeTab:[item representedObject]]; }
- (void)reloadTabFromMenu:(NSMenuItem *)item { webkit_web_view_reload(((FBTab *)[item representedObject])->webView); }
- (void)closeOtherTabsFromMenu:(NSMenuItem *)item
{
    FBTab *keep = [item representedObject];
    for (FBTab *tab in [[owner->tabs copy] autorelease])
        if (tab != keep)
            [owner closeTab:tab];
}

- (void)rightMouseDown:(NSEvent *)e
{
    NSInteger i = [self tabAtPoint:[self convertPoint:[e locationInWindow] fromView:nil]];
    if (i < 0)
        return;
    FBTab *tab = [owner->tabs objectAtIndex:i];
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    NSMenuItem *it = [menu addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@""];
    [it setTarget:owner];
    [menu addItem:[NSMenuItem separatorItem]];
    it = [menu addItemWithTitle:@"Reload Tab" action:@selector(reloadTabFromMenu:) keyEquivalent:@""];
    [it setTarget:self];
    [it setRepresentedObject:tab];
    it = [menu addItemWithTitle:@"Close Tab" action:@selector(closeTabFromMenu:) keyEquivalent:@""];
    [it setTarget:self];
    [it setRepresentedObject:tab];
    it = [menu addItemWithTitle:@"Close Other Tabs" action:@selector(closeOtherTabsFromMenu:) keyEquivalent:@""];
    [it setTarget:self];
    [it setRepresentedObject:tab];
    [NSMenu popUpContextMenu:menu withEvent:e forView:self];
}

@end

static gboolean spinTick(gpointer data)
{
    FB_POOL_BEGIN;
    [(FBTabBar *)data spin];
    FB_POOL_END;
    return G_SOURCE_CONTINUE;
}

/* ---- the toolbar row ---- */

@implementation FBToolbar

- (BOOL)isOpaque { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    const FBPalette *t = palette();
    NSRect b = [self bounds];
    [t->bar set];
    NSRectFill(b);
    hline(0, NSWidth(b), 0, t->divider);
    if (owner && owner->menuButton) {                           /* between History and the menu button */
        [t->divider set];
        NSRectFill(NSMakeRect(NSMinX([owner->menuButton frame]) - 9, floor(NSMidY(b)) - 10, 1, 20));
    }
    /* the page's load progress: a thin accent line along the bottom edge */
    if (owner && owner->loadProgress >= 0) {
        [t->accent set];
        NSRectFill(NSMakeRect(0, 0, floor(NSWidth(b) * MAX(0.04, MIN(owner->loadProgress, 1))), 2));
    }
}

- (void)mouseDown:(NSEvent *)e { dragWindow([self window], e); }

@end

/* ---- the address + search field ---- */

@interface FBLocationTextField : NSTextField
@end

@implementation FBLocationTextField
/* The caret and selection in the accent colour, light text in the dark appearance. */
- (BOOL)becomeFirstResponder
{
    BOOL ok = [super becomeFirstResponder];
    NSText *editor = [self currentEditor];
    if (ok && [editor isKindOfClass:[NSTextView class]]) {
        const FBPalette *t = palette();
        [(NSTextView *)editor setInsertionPointColor:t->accent];
        [(NSTextView *)editor setSelectedTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:
            [t->accent colorWithAlphaComponent:isDark() ? 0.45 : 0.28], NSBackgroundColorAttributeName,
            t->text, NSForegroundColorAttributeName, nil]];
    }
    return ok;
}
@end

@implementation FBAddressField

- (id)initWithFrame:(NSRect)f
{
    if (!(self = [super initWithFrame:f]))
        return nil;
    text = [[FBLocationTextField alloc] initWithFrame:NSMakeRect(33, 7, NSWidth(f) - 33 - 36, 18)];
    [text setAutoresizingMask:NSViewWidthSizable];
    [text setBezeled:NO];
    [text setBordered:NO];
    [text setDrawsBackground:NO];
    [text setFocusRingType:NSFocusRingTypeNone];
    [text setFont:[NSFont systemFontOfSize:13]];
    [[text cell] setScrollable:YES];
    [[text cell] setWraps:NO];
    [[text cell] accessibilitySetOverrideValue:@"Address and search" forAttribute:NSAccessibilityDescriptionAttribute];
    [self addSubview:text];
    star = [[FBToolButton buttonWithIcon:FBIconStar label:@"Bookmark this page" tip:nil target:nil action:@selector(toggleBookmark:)] retain];
    [star setFrame:NSMakeRect(NSWidth(f) - 6 - 26, 3, 26, 26)];
    [star setAutoresizingMask:NSViewMinXMargin];
    star->round = YES;
    [self addSubview:star];
    return self;
}

- (void)dealloc
{
    [text release];
    [star release];
    [super dealloc];
}

- (BOOL)isOpaque { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (BOOL)isEditing
{
    NSResponder *r = [[self window] firstResponder];
    return [r isKindOfClass:[NSTextView class]] && [(NSTextView *)r delegate] == (id)text;
}

/* A click on the plate (the glyph, the padding) edits the text. */
- (void)mouseDown:(NSEvent *)e
{
    (void)e;
    if (![self isEditing]) {
        [[self window] makeFirstResponder:text];
        [text selectText:nil];
    }
}

- (void)applyAppearance
{
    const FBPalette *t = palette();
    [text setTextColor:t->text];
    NSString *placeholder = [NSString stringWithFormat:@"Search %@ or type an address", searchProviderName()];
    [[text cell] setPlaceholderAttributedString:[[[NSAttributedString alloc] initWithString:placeholder
        attributes:[NSDictionary dictionaryWithObjectsAndKeys:t->textSoft, NSForegroundColorAttributeName,
                    [NSFont systemFontOfSize:13], NSFontAttributeName, nil]] autorelease]];
    [self setNeedsDisplay:YES];
    [text setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    const FBPalette *t = palette();
    NSRect b = [self bounds];
    CGFloat r = NSHeight(b) / 2;
    [t->field set];
    [[NSBezierPath bezierPathWithRoundedRect:b xRadius:r yRadius:r] fill];
    NSBezierPath *edge;
    if (focused) {
        edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 1, 1) xRadius:r - 1 yRadius:r - 1];
        [edge setLineWidth:2];
        [t->accent set];
    } else {
        edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:r - 0.5 yRadius:r - 0.5];
        [edge setLineWidth:1];
        [t->fieldBorder set];
    }
    [edge stroke];
    FBIcon glyph = secure && !focused ? FBIconLock : FBIconSearch;
    NSSize s = iconSize(glyph);
    drawIcon(glyph, NSMakePoint(12 + floor((13 - s.width) / 2), floor(NSMidY(b) + s.height / 2)), t->icon, NO);
}

@end

/* ---- the status bar (Preferences: Status bar on) ---- */

@implementation FBStatusBar
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    const FBPalette *t = palette();
    NSRect b = [self bounds];
    [t->bar set];
    NSRectFill(b);
    hline(0, NSWidth(b), NSHeight(b) - 1, t->divider);
}
@end

/* ---- the status bubble (Status bar off) ---- */

@interface FBBubbleView : NSView {
@public
    NSString *text;
    BOOL onRight;
}
@end

@implementation FBBubbleView

- (void)dealloc
{
    [text release];
    [super dealloc];
}

+ (NSDictionary *)attributes
{
    NSMutableParagraphStyle *para = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [para setLineBreakMode:NSLineBreakByTruncatingMiddle];
    return [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:11], NSFontAttributeName,
            palette()->textSoft, NSForegroundColorAttributeName, para, NSParagraphStyleAttributeName, nil];
}

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    const FBPalette *t = palette();
    NSRect b = [self bounds];
    [[NSColor clearColor] set];
    NSRectFill(b);
    /* square against the window's edge and bottom, rounded at the free top corner */
    NSRect r = NSInsetRect(b, 0.5, 0.5);
    r.origin.y -= 1;
    r.size.height += 1;
    if (onRight)
        r.size.width += 1;
    else {
        r.origin.x -= 1;
        r.size.width += 1;
    }
    NSBezierPath *p = [NSBezierPath bezierPath];
    CGFloat rad = 6;
    if (onRight) {
        [p moveToPoint:NSMakePoint(NSMaxX(r), NSMaxY(r))];
        [p appendBezierPathWithArcFromPoint:NSMakePoint(NSMinX(r), NSMaxY(r)) toPoint:NSMakePoint(NSMinX(r), NSMinY(r)) radius:rad];
        [p lineToPoint:NSMakePoint(NSMinX(r), NSMinY(r))];
        [p lineToPoint:NSMakePoint(NSMaxX(r), NSMinY(r))];
    } else {
        [p moveToPoint:NSMakePoint(NSMinX(r), NSMaxY(r))];
        [p appendBezierPathWithArcFromPoint:NSMakePoint(NSMaxX(r), NSMaxY(r)) toPoint:NSMakePoint(NSMaxX(r), NSMinY(r)) radius:rad];
        [p lineToPoint:NSMakePoint(NSMaxX(r), NSMinY(r))];
        [p lineToPoint:NSMakePoint(NSMinX(r), NSMinY(r))];
    }
    [p closePath];
    [t->bar set];
    [p fill];
    [t->divider set];
    [p setLineWidth:1];
    [p stroke];
    [text drawInRect:NSMakeRect(10, 3, NSWidth(b) - 20, 15) withAttributes:[FBBubbleView attributes]];
}

@end

@implementation FBStatusBubble

- (id)initWithParent:(NSWindow *)p
{
    if (!(self = [super init]))
        return nil;
    parent = p;
    bubble = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 21) styleMask:NSBorderlessWindowMask
                                           backing:NSBackingStoreBuffered defer:YES];
    [bubble setReleasedWhenClosed:NO];
    [bubble setOpaque:NO];
    [bubble setBackgroundColor:[NSColor clearColor]];
    [bubble setHasShadow:NO];
    [bubble setIgnoresMouseEvents:YES];
    FBBubbleView *v = [[[FBBubbleView alloc] initWithFrame:NSMakeRect(0, 0, 100, 21)] autorelease];
    [bubble setContentView:v];
    return self;
}

- (void)dealloc
{
    [self close];
    [bubble release];
    [text release];
    [super dealloc];
}

- (void)close
{
    if ([bubble parentWindow])
        [[bubble parentWindow] removeChildWindow:bubble];
    [bubble orderOut:nil];
}

/* pageInWindow: the page area in the parent's base coordinates. */
- (void)setText:(NSString *)s pageFrame:(NSRect)page
{
    if (![s length] || ![parent isVisible] || [parent isMiniaturized] || NSWidth(page) < 40 || NSHeight(page) < 30) {
        [self close];
        [text release];
        text = nil;
        return;
    }
    if (![s isEqual:text]) {
        [text release];
        text = [s copy];
    }
    CGFloat w = ceil([text sizeWithAttributes:[FBBubbleView attributes]].width) + 22;
    w = MIN(w, MAX(160, floor(NSWidth(page) / 3)));
    NSPoint origin = [parent convertBaseToScreen:page.origin];
    NSRect left = NSMakeRect(origin.x, origin.y, w, 21);
    /* Chrome: the bubble gets out of the way of the mouse, to the other corner */
    NSPoint mouse = [NSEvent mouseLocation];
    if (NSPointInRect(mouse, NSInsetRect(left, 0, -20)))
        onRight = YES;
    else if (onRight && !NSPointInRect(mouse, NSInsetRect(left, -40, -40)))
        onRight = NO;
    NSRect f = onRight ? NSMakeRect(origin.x + NSWidth(page) - w, origin.y, w, 21) : left;
    FBBubbleView *v = (FBBubbleView *)[bubble contentView];
    [v->text release];
    v->text = [text retain];
    v->onRight = onRight;
    [bubble setFrame:f display:NO];
    [v setNeedsDisplay:YES];
    if (![bubble parentWindow]) {
        [parent addChildWindow:bubble ordered:NSWindowAbove];
        [bubble orderFront:nil];
    }
}

@end
