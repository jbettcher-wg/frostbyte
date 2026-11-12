/*
 * FrostByte: the address field's dropdown: search suggestions from the search provider, history and
 * bookmark matches, in a borderless panel under the field.
 *   Up / Down choose a row (the field shows it), Return opens it, Escape closes the dropdown.
 * Suggestions use the provider's OpenSearch suggestion service (JSON ["query", ["s1", "s2", ...]]),
 * fetched with libsoup in this process; Preferences > General can turn them off.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"

static NSString *const KindSearch = @"search", *const KindURL = @"url", *const KindHistory = @"history",
                *const KindBookmark = @"bookmark";
static const CGFloat kRowHeight = 34, kPadTop = 6, kPadBottom = 8;
static const NSUInteger kMaxSuggestions = 4, kMaxHistory = 4, kMaxBookmarks = 2;

/* ---- suggestion services ---- */

static const char *suggestTemplate(void)
{
    if (getenv("FROSTBYTE_SEARCH_URL"))
        return NULL;
    NSString *p = searchProviderName();
    if ([p isEqual:@"Google"]) return "https://suggestqueries.google.com/complete/search?client=firefox&q=%s";
    if ([p isEqual:@"DuckDuckGo"]) return "https://duckduckgo.com/ac/?type=list&q=%s";
    if ([p isEqual:@"Bing"]) return "https://api.bing.com/osjson.aspx?query=%s";
    if ([p isEqual:@"Wikipedia"])
        return "https://en.wikipedia.org/w/api.php?action=opensearch&format=json&namespace=0&limit=6&search=%s";
    return NULL;                                        /* Startpage, Custom: none */
}

/* One JSON string literal at *p (just after its opening quote) -> NSString; *p moves past it. */
static NSString *jsonString(const char **p, const char *end)
{
    GString *out = g_string_new(NULL);
    const char *s = *p;
    while (s < end && *s != '"') {
        if (*s == '\\' && s + 1 < end) {
            s++;
            switch (*s) {
            case 'n': g_string_append_c(out, '\n'); break;
            case 't': g_string_append_c(out, '\t'); break;
            case 'u':
                if (s + 4 < end) {
                    char hexd[5] = { s[1], s[2], s[3], s[4], 0 };
                    gunichar c = (gunichar)strtoul(hexd, NULL, 16);
                    s += 4;
                    if (c >= 0xd800 && c < 0xdc00 && s + 6 < end && s[1] == '\\' && s[2] == 'u') {
                        char lo[5] = { s[3], s[4], s[5], s[6], 0 };
                        gunichar l = (gunichar)strtoul(lo, NULL, 16);
                        if (l >= 0xdc00 && l < 0xe000) {
                            c = 0x10000 + ((c - 0xd800) << 10) + (l - 0xdc00);
                            s += 6;
                        }
                    }
                    if (g_unichar_validate(c))
                        g_string_append_unichar(out, c);
                }
                break;
            default: g_string_append_c(out, *s); break;
            }
        } else
            g_string_append_c(out, *s);
        s++;
    }
    *p = s < end ? s + 1 : end;
    NSString *r = g_utf8_validate(out->str, (gssize)out->len, NULL) ? str(out->str) : nil;
    g_string_free(out, TRUE);
    return r;
}

/* ["query", ["s1", "s2", ...], ...] -> the second element's strings */
static NSArray *parseSuggestions(const char *data, gsize length)
{
    const char *p = data, *end = data + length;
    while (p < end && *p != '[') p++;
    if (p++ >= end)
        return nil;
    while (p < end && *p != '"' && *p != '[') p++;
    if (p < end && *p == '"') {                          /* the echoed query */
        p++;
        jsonString(&p, end);
    }
    while (p < end && *p != '[') p++;
    if (p++ >= end)
        return nil;
    NSMutableArray *out = [NSMutableArray array];
    while (p < end && *p != ']') {
        if (*p == '"') {
            p++;
            NSString *s = jsonString(&p, end);
            if ([s length])
                [out addObject:s];
        } else
            p++;
    }
    return out;
}

/* ---- the panel ---- */

@interface FBOmniboxView : NSView {
@public
    FBOmnibox *box;                   /* not retained */
    NSTrackingArea *tracking;
}
@end

@interface FBOmnibox (Private)
- (void)suggestionsArrived:(NSArray *)list forText:(NSString *)text generation:(unsigned)gen;
- (void)fetchSuggestions;
- (void)rebuild:(NSArray *)suggestions;
@end

typedef struct {
    FBOmnibox *box;                   /* retained */
    unsigned generation;
    char *text;
} FBSuggestRequest;

static void suggestReady(GObject *object, GAsyncResult *result, gpointer data)
{
    FBSuggestRequest *req = data;
    GError *error = NULL;
    GBytes *bytes = soup_session_send_and_read_finish(SOUP_SESSION(object), result, &error);
    FB_POOL_BEGIN;
    if (bytes) {
        gsize n = 0;
        const char *d = g_bytes_get_data(bytes, &n);
        [req->box suggestionsArrived:parseSuggestions(d, n) forText:str(req->text) generation:req->generation];
        g_bytes_unref(bytes);
    } else if (error && !g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        fprintf(stderr, "frostbyte: search suggestions: %s\n", error->message);
    [req->box release];
    FB_POOL_END;
    g_clear_error(&error);
    g_free(req->text);
    g_free(req);
}

static gboolean debounced(gpointer data)
{
    FB_POOL_BEGIN;
    FBOmnibox *box = data;
    box->debounce = 0;
    [box fetchSuggestions];
    FB_POOL_END;
    return G_SOURCE_REMOVE;
}

@implementation FBOmnibox

- (id)initWithOwner:(FBWindowController *)o
{
    if (!(self = [super init]))
        return nil;
    owner = o;
    rows = [[NSMutableArray alloc] init];
    selected = -1;
    panel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 100) styleMask:NSBorderlessWindowMask
                                          backing:NSBackingStoreBuffered defer:YES];
    [panel setReleasedWhenClosed:NO];
    [panel setOpaque:NO];
    [panel setBackgroundColor:[NSColor clearColor]];
    [panel setHasShadow:YES];
    [panel setAcceptsMouseMovedEvents:YES];
    FBOmniboxView *v = [[[FBOmniboxView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)] autorelease];
    v->box = self;
    [panel setContentView:v];
    return self;
}

- (void)dealloc
{
    [self hide];
    [panel release];
    [rows release];
    [typed release];
    if (session)
        g_object_unref(session);
    [super dealloc];
}

- (BOOL)isVisible { return [panel parentWindow] != nil; }

- (void)hide
{
    if (debounce) {
        g_source_remove(debounce);
        debounce = 0;
    }
    if (pending) {
        g_cancellable_cancel(pending);
        g_object_unref(pending);
        pending = NULL;
    }
    generation++;
    if ([panel parentWindow])
        [[panel parentWindow] removeChildWindow:panel];
    [panel orderOut:nil];
    selected = -1;
}

- (void)reposition
{
    if (![self isVisible] && ![rows count])
        return;
    FBAddressField *field = owner->addressField;
    NSRect f = [field convertRect:[field bounds] toView:nil];
    NSPoint bottomLeft = [owner->window convertBaseToScreen:f.origin];
    CGFloat h = kPadTop + kPadBottom + kRowHeight * [rows count];
    NSRect r = NSMakeRect(bottomLeft.x - 4, bottomLeft.y - 4 - h, NSWidth(f) + 8, h);
    [panel setFrame:r display:YES];
}

- (void)show
{
    if (![rows count]) {
        [self hide];
        return;
    }
    [self reposition];
    [[panel contentView] setNeedsDisplay:YES];
    if (![panel parentWindow]) {
        [owner->window addChildWindow:panel ordered:NSWindowAbove];
        [panel orderFront:nil];
    }
}

static NSDictionary *row(NSString *kind, NSString *text, NSString *detail, NSString *url)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:kind, @"Kind", text ?: @"", @"Text", detail ?: @"", @"Detail",
            url ?: @"", @"URL", nil];
}

/* Does what was typed read as an address (not words to search for)? */
static BOOL looksLikeAddress(NSString *text)
{
    char *url = urlForLocationText([text UTF8String]);
    char *search = searchURLFor([text UTF8String]);
    BOOL address = url && strcmp(url, search);
    g_free(url);
    g_free(search);
    return address;
}

- (void)rebuild:(NSArray *)suggestions
{
    NSString *text = typed;
    [rows removeAllObjects];
    NSString *provider = searchProviderName();
    BOOL address = looksLikeAddress(text);
    if (address)
        [rows addObject:row(KindURL, text, str("\xe2\x80\x94 Open address"), nil)];
    else
        [rows addObject:row(KindSearch, text, [NSString stringWithFormat:str("\xe2\x80\x94 Search %@"), provider], nil)];
    NSUInteger n = 0;
    for (NSString *s in suggestions) {
        if (n == kMaxSuggestions)
            break;
        if ([s caseInsensitiveCompare:text] == NSOrderedSame)
            continue;
        [rows addObject:row(KindSearch, s, nil, nil)];
        n++;
    }
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *h in historyMatches(text, kMaxHistory)) {
        NSString *url = [h objectForKey:@"URL"];
        [seen addObject:url];
        NSString *title = [h objectForKey:@"Title"];
        [rows addObject:row(KindHistory, [title length] ? title : displayURL(url), displayURL(url), url)];
    }
    NSString *lower = [text lowercaseString];
    n = 0;
    for (NSDictionary *b in fbBookmarks) {
        if (n == kMaxBookmarks)
            break;
        NSString *url = [b objectForKey:@"URL"], *title = [b objectForKey:@"Title"];
        if ([seen containsObject:url])
            continue;
        if ([[title lowercaseString] rangeOfString:lower].location == NSNotFound
            && [[displayURL(url) lowercaseString] rangeOfString:lower].location == NSNotFound)
            continue;
        [rows addObject:row(KindBookmark, title, displayURL(url), url)];
        n++;
    }
    if (address)                                        /* and the search, last */
        [rows addObject:row(KindSearch, [NSString stringWithFormat:str("Search %@ for \xe2\x80\x9c%@\xe2\x80\x9d"), provider, text],
                            nil, text)];
    selected = 0;
    [self show];
}

- (void)textChanged
{
    NSString *text = [[owner->location stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    [typed release];
    typed = [text copy];
    generation++;
    if (![typed length]) {
        [rows removeAllObjects];
        [self hide];
        return;
    }
    [self rebuild:nil];
    if (debounce)
        g_source_remove(debounce);
    debounce = 0;
    if ([prefs() boolForKey:PrefSearchSuggestions] && suggestTemplate() && !looksLikeAddress(typed))
        debounce = g_timeout_add(150, debounced, self);   /* removed by -hide (and so by -dealloc) */
}

- (void)fetchSuggestions
{
    const char *t = suggestTemplate();
    if (!t || ![typed length])
        return;
    if (pending) {
        g_cancellable_cancel(pending);
        g_object_unref(pending);
    }
    pending = g_cancellable_new();
    if (!session) {
        session = soup_session_new();
        soup_session_set_timeout(session, 5);
        soup_session_set_user_agent(session, "FrostByte/" FROSTBYTE_VERSION);
    }
    char *escaped = g_uri_escape_string([typed UTF8String], NULL, FALSE);
    const char *at = strstr(t, "%s");
    char *url = g_strdup_printf("%.*s%s%s", (int)(at - t), t, escaped, at + 2);
    SoupMessage *msg = soup_message_new("GET", url);
    g_free(url);
    g_free(escaped);
    if (!msg)
        return;
    FBSuggestRequest *req = g_new0(FBSuggestRequest, 1);
    req->box = [self retain];
    req->generation = generation;
    req->text = g_strdup([typed UTF8String]);
    soup_session_send_and_read_async(session, msg, G_PRIORITY_DEFAULT, pending, suggestReady, req);
    g_object_unref(msg);
}

- (void)suggestionsArrived:(NSArray *)list forText:(NSString *)text generation:(unsigned)gen
{
    if (!owner || gen != generation || ![text isEqual:typed] || ![owner->addressField isEditing])
        return;
    NSInteger was = selected;
    [self rebuild:list];
    if (was > 0 && was < (NSInteger)[rows count])      /* keep a choice the arrows already made */
        selected = was;
}

/* The field shows the chosen row. */
- (void)select:(NSInteger)i
{
    if (![rows count])
        return;
    selected = MAX(0, MIN(i, (NSInteger)[rows count] - 1));
    NSDictionary *r = [rows objectAtIndex:selected];
    NSString *kind = [r objectForKey:@"Kind"];
    NSString *shown = selected == 0 ? typed
                    : [kind isEqual:KindSearch] ? ([[r objectForKey:@"URL"] length] ? [r objectForKey:@"URL"] : [r objectForKey:@"Text"])
                    : [r objectForKey:@"URL"];
    [owner->location setStringValue:shown];
    NSText *editor = [owner->location currentEditor];
    [editor setSelectedRange:NSMakeRange([shown length], 0)];
    [[panel contentView] setNeedsDisplay:YES];
}

- (BOOL)handleCommand:(SEL)command
{
    if (![self isVisible])
        return NO;
    if (command == @selector(moveDown:)) {
        [self select:selected + 1];
        return YES;
    }
    if (command == @selector(moveUp:)) {
        [self select:selected - 1];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        [owner->location setStringValue:typed ?: @""];
        [self hide];
        return YES;
    }
    return NO;
}

- (BOOL)activateSelection
{
    if (![self isVisible] || selected < 0 || selected >= (NSInteger)[rows count])
        return NO;
    [self activateRow:selected];
    return YES;
}

- (void)activateRow:(NSInteger)i
{
    if (i < 0 || i >= (NSInteger)[rows count])
        return;
    NSDictionary *r = [[[rows objectAtIndex:i] retain] autorelease];
    NSString *kind = [r objectForKey:@"Kind"];
    char *url;
    if ([kind isEqual:KindURL])
        url = urlForLocationText([[r objectForKey:@"Text"] UTF8String]);
    else if ([kind isEqual:KindSearch])
        url = searchURLFor([([[r objectForKey:@"URL"] length] ? [r objectForKey:@"URL"] : [r objectForKey:@"Text"]) UTF8String]);
    else
        url = g_strdup([[r objectForKey:@"URL"] UTF8String]);
    [self hide];
    [rows removeAllObjects];
    [owner loadURL:url];
    g_free(url);
}

@end

@implementation FBOmniboxView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return YES; }

- (void)dealloc
{
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
        options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:tracking];
}

- (NSInteger)rowAt:(NSPoint)p
{
    NSInteger i = (NSInteger)floor((p.y - kPadTop) / kRowHeight);
    return p.y >= kPadTop && i < (NSInteger)[box->rows count] ? i : -1;
}

- (void)mouseMoved:(NSEvent *)e
{
    NSInteger i = [self rowAt:[self convertPoint:[e locationInWindow] fromView:nil]];
    if (i >= 0 && i != box->selected) {
        box->selected = i;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent *)e { (void)e; }

- (void)mouseUp:(NSEvent *)e
{
    NSInteger i = [self rowAt:[self convertPoint:[e locationInWindow] fromView:nil]];
    if (i >= 0)
        [box activateRow:i];
}

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    const FBPalette *t = palette();
    NSRect b = [self bounds];
    [[NSColor clearColor] set];
    NSRectFill(b);
    NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:12 yRadius:12];
    [t->popup set];
    [plate fill];
    [t->popupBorder set];
    [plate setLineWidth:1];
    [plate stroke];
    NSFont *font = [NSFont systemFontOfSize:13], *bold = [NSFont boldSystemFontOfSize:13];
    NSFont *small = [NSFont systemFontOfSize:12];
    NSString *typed = box->typed ?: @"";
    for (NSInteger i = 0; i < (NSInteger)[box->rows count]; i++) {
        NSDictionary *r = [box->rows objectAtIndex:i];
        NSString *kind = [r objectForKey:@"Kind"];
        NSRect rr = NSMakeRect(1, kPadTop + i * kRowHeight, NSWidth(b) - 2, kRowHeight);
        if (i == box->selected) {
            [t->hover set];
            NSRectFill(rr);
        }
        FBIcon icon = [kind isEqual:KindHistory] ? FBIconHistory : [kind isEqual:KindBookmark] ? FBIconStar
                    : [kind isEqual:KindURL] ? FBIconForward : FBIconSearch;
        NSSize s = iconSize(icon);
        BOOL accentIcon = [kind isEqual:KindBookmark];
        drawIcon(icon, NSMakePoint(16 + floor((16 - s.width) / 2), floor(NSMidY(rr) - s.height / 2)),
                 accentIcon ? t->accent : t->icon, accentIcon);
        /* the text, with the part that was typed in bold */
        NSString *text = [r objectForKey:@"Text"];
        NSMutableAttributedString *a = [[[NSMutableAttributedString alloc] initWithString:text
            attributes:[NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName, t->text, NSForegroundColorAttributeName, nil]] autorelease];
        NSRange m = [typed length] ? [text rangeOfString:typed options:NSCaseInsensitiveSearch] : NSMakeRange(NSNotFound, 0);
        if (m.location != NSNotFound && ![kind isEqual:KindURL])
            [a addAttribute:NSFontAttributeName value:bold range:m];
        CGFloat x = 16 + 16 + 12, maxText = NSWidth(b) * 0.6;
        NSSize ts = [a size];
        CGFloat tw = MIN(ceil(ts.width), maxText);
        NSMutableParagraphStyle *para = [[[NSMutableParagraphStyle alloc] init] autorelease];
        [para setLineBreakMode:NSLineBreakByTruncatingTail];
        [a addAttribute:NSParagraphStyleAttributeName value:para range:NSMakeRange(0, [a length])];
        [a drawInRect:NSMakeRect(x, NSMidY(rr) - 9, tw, 18)];
        NSString *detail = [r objectForKey:@"Detail"];
        if ([detail length]) {
            BOOL link = [kind isEqual:KindHistory] || [kind isEqual:KindBookmark];
            NSDictionary *da = [NSDictionary dictionaryWithObjectsAndKeys:small, NSFontAttributeName,
                link ? t->accent : t->textSoft, NSForegroundColorAttributeName, para, NSParagraphStyleAttributeName, nil];
            CGFloat dx = x + tw + 12;
            [detail drawInRect:NSMakeRect(dx, NSMidY(rr) - 8, MAX(0, NSWidth(b) - 16 - dx), 16) withAttributes:da];
        }
    }
}

@end
