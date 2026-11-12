/*
 * FrostByte: the History window (searchable, grouped by day) and the Downloads window (progress,
 * Show in Finder, cancel, clear). The toolbar's History and Downloads menus stay the quick view;
 * their "Show All" items, Cmd-Y and Cmd-Option-L open these windows.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"

/* The browser window in front, if any. */
static FBWindowController *frontController(void)
{
    for (NSWindow *w in [NSApp orderedWindows]) {
        FBWindowController *c = controllerForWindow(w);
        if (c && [w isVisible] && ![w isMiniaturized])
            return c;
    }
    return nil;
}

static void openURLInFront(NSString *url, BOOL newTab)
{
    FBWindowController *c = frontController();
    if (!c) {
        openWindow([url UTF8String]);
        return;
    }
    if (newTab)
        [c addTabWithURL:[url UTF8String] relatedTo:NULL select:YES];
    else
        [c loadURL:[url UTF8String]];
    [c show];
}

static NSButton *bottomButton(NSView *parent, NSString *title, CGFloat x, CGFloat width, BOOL right, id target, SEL action)
{
    NSRect b = [parent bounds];
    NSButton *button = [[[NSButton alloc] initWithFrame:NSMakeRect(right ? NSWidth(b) - x - width : x, 12, width, 28)] autorelease];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTitle:title];
    [button setTarget:target];
    [button setAction:action];
    [button setAutoresizingMask:right ? NSViewMinXMargin : NSViewMaxXMargin];
    [parent addSubview:button];
    return button;
}

static NSWindow *libraryWindow(NSString *title, NSString *autosave, NSSize size)
{
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
        styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
        backing:NSBackingStoreBuffered defer:YES];
    [w setReleasedWhenClosed:NO];
    [w setTitle:title];
    [w setMinSize:NSMakeSize(420, 260)];
    [w center];
    [w setFrameAutosaveName:autosave];
    return w;
}

/* Delete / Forward Delete in the list remove the selection. */
@interface FBDeletingOutlineView : NSOutlineView
@end
@implementation FBDeletingOutlineView
- (void)keyDown:(NSEvent *)e
{
    NSString *c = [e charactersIgnoringModifiers];
    unichar k = [c length] ? [c characterAtIndex:0] : 0;
    if ((k == NSDeleteCharacter || k == NSDeleteFunctionKey || k == NSBackspaceCharacter) && [self numberOfSelectedRows])
        [NSApp sendAction:@selector(removeSelected:) to:[self delegate] from:self];
    else if ((k == NSCarriageReturnCharacter || k == NSEnterCharacter) && [self numberOfSelectedRows])
        [NSApp sendAction:@selector(openSelected:) to:[self delegate] from:self];
    else
        [super keyDown:e];
}
@end

/* ---- History ---- */

@interface FBHistoryWindow : NSObject {
    NSWindow *window;
    NSSearchField *search;
    NSOutlineView *historyList;
    NSButton *removeButton, *clearButton;
    NSMutableArray *groups;            /* { Title, Items } */
    NSDateFormatter *dayFormat, *timeFormat;
}
- (void)reload;
- (void)updateButtons;
@end

@implementation FBHistoryWindow

- (NSTableColumn *)column:(NSString *)ident title:(NSString *)title width:(CGFloat)w
{
    NSTableColumn *c = [[[NSTableColumn alloc] initWithIdentifier:ident] autorelease];
    [[c headerCell] setStringValue:title];
    [c setWidth:w];
    [c setEditable:NO];
    [[c dataCell] setLineBreakMode:NSLineBreakByTruncatingTail];
    [c setResizingMask:NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask];
    [historyList addTableColumn:c];
    return c;
}

- (id)init
{
    if (!(self = [super init]))
        return nil;
    groups = [[NSMutableArray alloc] init];
    dayFormat = [[NSDateFormatter alloc] init];
    [dayFormat setFormatterBehavior:NSDateFormatterBehavior10_4];
    [dayFormat setDateStyle:NSDateFormatterFullStyle];
    [dayFormat setTimeStyle:NSDateFormatterNoStyle];
    timeFormat = [[NSDateFormatter alloc] init];
    [timeFormat setFormatterBehavior:NSDateFormatterBehavior10_4];
    [timeFormat setDateStyle:NSDateFormatterNoStyle];
    [timeFormat setTimeStyle:NSDateFormatterShortStyle];

    window = libraryWindow(@"History", @"FrostByteHistoryWindow", NSMakeSize(760, 520));
    NSView *content = [window contentView];
    NSRect b = [content bounds];
    search = [[[NSSearchField alloc] initWithFrame:NSMakeRect(NSWidth(b) - 12 - 240, NSHeight(b) - 34, 240, 22)] autorelease];
    [[search cell] setPlaceholderString:@"Search History"];
    [[search cell] setSendsWholeSearchString:NO];
    [search setTarget:self];
    [search setAction:@selector(filter:)];
    [search setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
    [content addSubview:search];

    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(-1, 52, NSWidth(b) + 2, NSHeight(b) - 52 - 44)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    historyList = [[[FBDeletingOutlineView alloc] initWithFrame:[[scroll contentView] bounds]] autorelease];
    [historyList setUsesAlternatingRowBackgroundColors:YES];
    [historyList setAllowsMultipleSelection:YES];
    [historyList setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
    NSTableColumn *title = [self column:@"Title" title:@"Title" width:330];
    [self column:@"Address" title:@"Address" width:300];
    [self column:@"Time" title:@"Visited" width:90];
    [historyList setOutlineTableColumn:title];
    [historyList setDataSource:(id)self];
    [historyList setDelegate:(id)self];
    [historyList setTarget:self];
    [historyList setDoubleAction:@selector(openSelected:)];
    [scroll setDocumentView:historyList];
    [content addSubview:scroll];

    removeButton = bottomButton(content, @"Remove", 14, 100, NO, self, @selector(removeSelected:));
    clearButton = bottomButton(content, str("Clear History\xe2\x80\xa6"), 14, 130, YES, self, @selector(clearAll:));
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(historyChanged:)
                                                 name:FBHistoryChangedNotification object:nil];
    [self reload];
    return self;
}

- (NSString *)titleForDay:(NSDate *)day
{
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *one = [[[NSDateComponents alloc] init] autorelease];
    [one setDay:-1];
    NSDate *today = [NSDate date];
    NSDate *yesterday = [cal dateByAddingComponents:one toDate:today options:0];
    NSUInteger units = NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit;
    NSDateComponents *d = [cal components:units fromDate:day];
    NSDateComponents *t = [cal components:units fromDate:today], *y = [cal components:units fromDate:yesterday];
    if ([d year] == [t year] && [d month] == [t month] && [d day] == [t day])
        return @"Today";
    if ([d year] == [y year] && [d month] == [y month] && [d day] == [y day])
        return @"Yesterday";
    return [dayFormat stringFromDate:day];
}

/* entries (newest first) -> groups by day, filtered by the search words */
- (void)reload
{
    NSArray *words = [[[search stringValue] lowercaseString] componentsSeparatedByString:@" "];
    [groups removeAllObjects];
    NSMutableDictionary *group = nil;
    for (NSMutableDictionary *e in allHistory()) {
        NSString *title = [[e objectForKey:@"Title"] lowercaseString] ?: @"", *url = [[e objectForKey:@"URL"] lowercaseString];
        BOOL match = YES;
        for (NSString *w in words)
            if ([w length] && [title rangeOfString:w].location == NSNotFound && [url rangeOfString:w].location == NSNotFound) {
                match = NO;
                break;
            }
        if (!match)
            continue;
        NSDate *date = [e objectForKey:@"Date"];
        NSString *day = date ? [self titleForDay:date] : @"Earlier";
        if (!group || ![[group objectForKey:@"Title"] isEqual:day]) {
            group = [NSMutableDictionary dictionaryWithObjectsAndKeys:day, @"Title", [NSMutableArray array], @"Items", nil];
            [groups addObject:group];
        }
        [[group objectForKey:@"Items"] addObject:e];
    }
    [historyList reloadData];
    for (NSDictionary *g in groups)
        [historyList expandItem:g];
    [self updateButtons];
}

- (void)updateButtons
{
    [removeButton setEnabled:[historyList numberOfSelectedRows] > 0];
    [clearButton setEnabled:[allHistory() count] > 0];
}

- (void)historyChanged:(NSNotification *)n { (void)n; if ([window isVisible]) [self reload]; }
- (void)filter:(id)s { (void)s; [self reload]; }
- (void)show { [self reload]; [window makeKeyAndOrderFront:nil]; [window makeFirstResponder:search]; }

- (BOOL)isGroup:(id)item { return [item objectForKey:@"Items"] != nil; }

- (NSArray *)selectedEntries
{
    NSMutableArray *out = [NSMutableArray array];
    NSIndexSet *rows = [historyList selectedRowIndexes];
    for (NSUInteger r = [rows firstIndex]; r != NSNotFound; r = [rows indexGreaterThanIndex:r]) {
        id item = [historyList itemAtRow:r];
        if ([self isGroup:item])
            [out addObjectsFromArray:[item objectForKey:@"Items"]];
        else
            [out addObject:item];
    }
    return out;
}

- (void)openSelected:(id)s
{
    (void)s;
    NSArray *entries = [self selectedEntries];
    NSInteger clicked = [historyList clickedRow];
    if (clicked >= 0 && ![self isGroup:[historyList itemAtRow:clicked]])
        entries = [NSArray arrayWithObject:[historyList itemAtRow:clicked]];
    BOOL newTab = ([[NSApp currentEvent] modifierFlags] & NSCommandKeyMask) != 0 || [entries count] > 1;
    NSUInteger n = 0;
    for (NSDictionary *e in entries) {
        if (n++ == 20)
            break;
        openURLInFront([e objectForKey:@"URL"], newTab);
    }
}

- (void)removeSelected:(id)s
{
    (void)s;
    NSArray *entries = [self selectedEntries];
    if ([entries count])
        removeHistoryEntries(entries);
}

- (void)clearAll:(id)s
{
    (void)s;
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Clear all history?"];
    [alert setInformativeText:@"Every page in the history is removed. This can't be undone."];
    [alert addButtonWithTitle:@"Clear History"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(clearAlertDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void)clearAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)code contextInfo:(void *)info
{
    (void)alert; (void)info;
    if (code == NSAlertFirstButtonReturn)
        clearHistory();
}

/* ---- historyList data source and delegate ---- */

- (NSInteger)outlineView:(NSOutlineView *)v numberOfChildrenOfItem:(id)item
{
    (void)v;
    return item ? (NSInteger)[[item objectForKey:@"Items"] count] : (NSInteger)[groups count];
}

- (id)outlineView:(NSOutlineView *)v child:(NSInteger)i ofItem:(id)item
{
    (void)v;
    return item ? [[item objectForKey:@"Items"] objectAtIndex:i] : [groups objectAtIndex:i];
}

- (BOOL)outlineView:(NSOutlineView *)v isItemExpandable:(id)item { (void)v; return [self isGroup:item]; }
- (BOOL)outlineView:(NSOutlineView *)v isGroupItem:(id)item { (void)v; return [self isGroup:item]; }

- (id)outlineView:(NSOutlineView *)v objectValueForTableColumn:(NSTableColumn *)c byItem:(id)item
{
    (void)v;
    NSString *ident = [c identifier];
    if ([self isGroup:item])
        return [ident isEqual:@"Title"] ? [item objectForKey:@"Title"] : @"";
    if ([ident isEqual:@"Title"]) {
        NSString *t = [item objectForKey:@"Title"];
        return [t length] ? t : displayURL([item objectForKey:@"URL"]);
    }
    if ([ident isEqual:@"Address"])
        return displayURL([item objectForKey:@"URL"]);
    NSDate *d = [item objectForKey:@"Date"];
    return d ? [timeFormat stringFromDate:d] : @"";
}

- (NSString *)outlineView:(NSOutlineView *)v toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect
              tableColumn:(NSTableColumn *)c item:(id)item mouseLocation:(NSPoint)p
{
    (void)v; (void)cell; (void)rect; (void)c; (void)p;
    return [self isGroup:item] ? nil : [item objectForKey:@"URL"];
}

- (void)outlineViewSelectionDidChange:(NSNotification *)n { (void)n; [self updateButtons]; }

@end

void fbShowHistoryWindow(void)
{
    static FBHistoryWindow *shared;
    if (!shared)
        shared = [[FBHistoryWindow alloc] init];
    [shared show];
}

/* ---- Downloads ---- */

@interface FBDownloadCell : NSCell
@end

@implementation FBDownloadCell

- (void)drawWithFrame:(NSRect)f inView:(NSView *)view
{
    (void)view;
    FBDownload *d = [self representedObject];
    if (!d)
        return;
    BOOL light = [self backgroundStyle] == NSBackgroundStyleDark;     /* a selected row */
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFileType:[d->name pathExtension]];
    [icon setSize:NSMakeSize(32, 32)];
    drawImageUpright(icon, NSMakeRect(NSMinX(f) + 8, NSMidY(f) - 16, 32, 32), 1);
    CGFloat x = NSMinX(f) + 50, w = NSWidth(f) - 50 - 12;
    NSMutableParagraphStyle *para = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [para setLineBreakMode:NSLineBreakByTruncatingMiddle];
    NSColor *main = light ? [NSColor whiteColor] : [NSColor controlTextColor];
    NSColor *soft = light ? grayA(1, 0.8) : [NSColor disabledControlTextColor];
    [d->name drawInRect:NSMakeRect(x, NSMinY(f) + 5, w, 16) withAttributes:[NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont boldSystemFontOfSize:12], NSFontAttributeName, main, NSForegroundColorAttributeName,
        para, NSParagraphStyleAttributeName, nil]];
    CGFloat y = NSMinY(f) + 24;
    if (d->state == FBDownloadActive) {
        NSRect track = NSMakeRect(x, y, MIN(w, 360), 4);
        [(light ? grayA(1, 0.35) : palette()->track) set];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
        track.size.width = MAX(4, floor(NSWidth(track) * MIN(d->progress, 1)));
        [(light ? [NSColor whiteColor] : palette()->accent) set];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
        y += 7;
    }
    [[d status] drawInRect:NSMakeRect(x, y, w, 14) withAttributes:[NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont systemFontOfSize:11], NSFontAttributeName, soft, NSForegroundColorAttributeName, nil]];
}

@end

@interface FBDeletingTableView : NSTableView
@end
@implementation FBDeletingTableView
- (void)keyDown:(NSEvent *)e
{
    NSString *c = [e charactersIgnoringModifiers];
    unichar k = [c length] ? [c characterAtIndex:0] : 0;
    if ((k == NSDeleteCharacter || k == NSDeleteFunctionKey || k == NSBackspaceCharacter) && [self numberOfSelectedRows])
        [NSApp sendAction:@selector(removeSelected:) to:[self delegate] from:self];
    else
        [super keyDown:e];
}
@end

@interface FBDownloadsWindow : NSObject {
    NSWindow *window;
    NSTableView *table;
    NSButton *showButton, *cancelButton, *clearButton;
}
- (void)updateButtons;
- (void)refresh;
@end

@implementation FBDownloadsWindow

- (id)init
{
    if (!(self = [super init]))
        return nil;
    window = libraryWindow(@"Downloads", @"FrostByteDownloadsWindow", NSMakeSize(520, 400));
    NSView *content = [window contentView];
    NSRect b = [content bounds];
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(-1, 52, NSWidth(b) + 2, NSHeight(b) - 52 + 1)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    table = [[[FBDeletingTableView alloc] initWithFrame:[[scroll contentView] bounds]] autorelease];
    NSTableColumn *c = [[[NSTableColumn alloc] initWithIdentifier:@"Download"] autorelease];
    [c setDataCell:[[[FBDownloadCell alloc] init] autorelease]];
    [c setEditable:NO];
    [c setResizingMask:NSTableColumnAutoresizingMask];
    [table addTableColumn:c];
    [table setHeaderView:nil];
    [table setRowHeight:48];
    [table setUsesAlternatingRowBackgroundColors:YES];
    [table setAllowsMultipleSelection:YES];
    [table setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
    [table setDataSource:(id)self];
    [table setDelegate:(id)self];
    [table setTarget:self];
    [table setDoubleAction:@selector(openSelected:)];
    [scroll setDocumentView:table];
    [content addSubview:scroll];
    [c setWidth:NSWidth([[scroll contentView] bounds])];

    showButton = bottomButton(content, @"Show in Finder", 14, 130, NO, self, @selector(showSelected:));
    cancelButton = bottomButton(content, @"Cancel", 148, 90, NO, self, @selector(cancelSelected:));
    clearButton = bottomButton(content, @"Clear Completed", 14, 140, YES, self, @selector(clearCompleted:));
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadsChanged:)
                                                 name:FBDownloadsChangedNotification object:nil];
    return self;
}

- (NSArray *)selected
{
    NSMutableArray *out = [NSMutableArray array];
    NSIndexSet *rows = [table selectedRowIndexes];
    for (NSUInteger r = [rows firstIndex]; r != NSNotFound; r = [rows indexGreaterThanIndex:r])
        if (r < [fbDownloads count])
            [out addObject:[fbDownloads objectAtIndex:r]];
    return out;
}

- (void)updateButtons
{
    BOOL anyActive = NO, anyEnded = NO, anyShowable = NO;
    for (FBDownload *d in [self selected]) {
        anyActive |= d->state == FBDownloadActive;
        anyShowable |= d->path != nil;
    }
    for (FBDownload *d in fbDownloads)
        anyEnded |= d->state != FBDownloadActive;
    [showButton setEnabled:anyShowable];
    [cancelButton setEnabled:anyActive];
    [clearButton setEnabled:anyEnded];
}

- (void)refresh
{
    /* keep the selection by object across reloads (new downloads are inserted at the top) */
    NSArray *sel = [self selected];
    [table reloadData];
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (FBDownload *d in sel) {
        NSUInteger i = [fbDownloads indexOfObjectIdenticalTo:d];
        if (i != NSNotFound)
            [rows addIndex:i];
    }
    [table selectRowIndexes:rows byExtendingSelection:NO];
    [self updateButtons];
}

- (void)downloadsChanged:(NSNotification *)n { (void)n; if ([window isVisible]) [self refresh]; }
- (void)show { [self refresh]; [window makeKeyAndOrderFront:nil]; }

- (void)showSelected:(id)s { (void)s; for (FBDownload *d in [self selected]) revealDownload(d); }
- (void)cancelSelected:(id)s { (void)s; for (FBDownload *d in [self selected]) cancelDownload(d); }
- (void)clearCompleted:(id)s { (void)s; clearFinishedDownloads(); }
- (void)removeSelected:(id)s
{
    (void)s;
    for (FBDownload *d in [self selected])
        if (d->state != FBDownloadActive)
            [fbDownloads removeObjectIdenticalTo:d];
    [self refresh];
    for (FBWindowController *c in fbWindows)
        [c downloadsChanged];
}
- (void)openSelected:(id)s
{
    (void)s;
    NSInteger r = [table clickedRow];
    if (r >= 0 && r < (NSInteger)[fbDownloads count])
        openDownload([fbDownloads objectAtIndex:r]);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)v { (void)v; return (NSInteger)[fbDownloads count]; }
- (id)tableView:(NSTableView *)v objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r { (void)v; (void)c; (void)r; return nil; }
- (void)tableView:(NSTableView *)v willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)c row:(NSInteger)r
{
    (void)v; (void)c;
    [cell setRepresentedObject:r < (NSInteger)[fbDownloads count] ? [fbDownloads objectAtIndex:r] : nil];
}
- (NSString *)tableView:(NSTableView *)v toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect
            tableColumn:(NSTableColumn *)c row:(NSInteger)r mouseLocation:(NSPoint)p
{
    (void)v; (void)cell; (void)rect; (void)c; (void)p;
    FBDownload *d = r < (NSInteger)[fbDownloads count] ? [fbDownloads objectAtIndex:r] : nil;
    return d->path;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n { (void)n; [self updateButtons]; }

@end

void fbShowDownloadsWindow(void)
{
    static FBDownloadsWindow *shared;
    if (!shared)
        shared = [[FBDownloadsWindow alloc] init];
    [shared show];
}
