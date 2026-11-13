/*
 * FrostByte: the Preferences window.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"

/* Preferences window: a toolbar of panes (General, Tabs, Appearance, Hardware), resized to each. */

@interface FBFlippedView : NSView
@end
@implementation FBFlippedView
- (BOOL)isFlipped { return YES; }
@end

static const CGFloat kPaneWidth = 600, kLabelRight = 200, kControlX = 210;

static NSString *const PaneGeneral = @"General", *const PaneTabs = @"Tabs", *const PaneAppearance = @"Appearance",
                *const PaneHardware = @"Hardware";

@implementation FBPreferences

+ (FBPreferences *)shared
{
    static FBPreferences *shared;
    if (!shared)
        shared = [[FBPreferences alloc] init];
    return shared;
}

/* ---- building panes (flipped views, rows from the top) ---- */

- (NSTextField *)text:(NSString *)s in:(NSView *)v frame:(NSRect)r align:(NSTextAlignment)align small:(BOOL)small
{
    NSTextField *t = [[[NSTextField alloc] initWithFrame:r] autorelease];
    [t setStringValue:s];
    [t setEditable:NO];
    [t setSelectable:NO];
    [t setBordered:NO];
    [t setDrawsBackground:NO];
    [t setAlignment:align];
    if (small) {
        [t setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
        [t setTextColor:[NSColor disabledControlTextColor]];
    }
    [v addSubview:t];
    return t;
}

- (void)label:(NSString *)s in:(NSView *)v y:(CGFloat)y
{
    [self text:s in:v frame:NSMakeRect(10, y + 3, kLabelRight - 10, 17) align:NSRightTextAlignment small:NO];
}

- (void)note:(NSString *)s in:(NSView *)v y:(CGFloat)y
{
    NSTextField *t = [self text:s in:v frame:NSMakeRect(kControlX + 2, y, kPaneWidth - kControlX - 20, 30)
                          align:NSLeftTextAlignment small:YES];
    [[t cell] setWraps:YES];
}

- (void)bind:(NSControl *)control key:(NSString *)key value:(id)value
{
    [bound addObject:[NSDictionary dictionaryWithObjectsAndKeys:control, @"control", key, @"key", value, @"value", nil]];
}

- (NSButton *)checkbox:(NSString *)title key:(NSString *)key in:(NSView *)v y:(CGFloat)y
{
    NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(kControlX, y, kPaneWidth - kControlX - 20, 20)] autorelease];
    [b setButtonType:NSSwitchButton];
    [b setTitle:title];
    [b setTarget:self];
    [b setAction:@selector(controlChanged:)];
    [v addSubview:b];
    [self bind:b key:key value:nil];
    return b;
}

- (NSButton *)radio:(NSString *)title key:(NSString *)key value:(NSString *)value in:(NSView *)v y:(CGFloat)y
{
    NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(kControlX, y, 200, 20)] autorelease];
    [b setButtonType:NSRadioButton];
    [b setTitle:title];
    [b setTarget:self];
    [b setAction:@selector(controlChanged:)];
    [v addSubview:b];
    [self bind:b key:key value:value];
    return b;
}

/* titles and the values stored for them (NSString or NSNumber) */
- (NSPopUpButton *)popup:(NSArray *)titles values:(NSArray *)values key:(NSString *)key in:(NSView *)v y:(CGFloat)y width:(CGFloat)w
{
    NSPopUpButton *p = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(kControlX - 2, y - 2, w, 26) pullsDown:NO] autorelease];
    for (NSUInteger i = 0; i < [titles count]; i++) {
        [p addItemWithTitle:[titles objectAtIndex:i]];
        [[p lastItem] setRepresentedObject:[values objectAtIndex:i]];
    }
    [p setTarget:self];
    [p setAction:@selector(controlChanged:)];
    [v addSubview:p];
    if (key)
        [self bind:p key:key value:nil];
    return p;
}

- (NSTextField *)field:(NSString *)key in:(NSView *)v y:(CGFloat)y width:(CGFloat)w
{
    NSTextField *f = [[[NSTextField alloc] initWithFrame:NSMakeRect(kControlX, y, w, 22)] autorelease];
    [[f cell] setScrollable:YES];
    [[f cell] setWraps:NO];
    [f setDelegate:(id)self];
    [v addSubview:f];
    [self bind:f key:key value:nil];
    return f;
}

- (void)separator:(NSView *)v y:(CGFloat)y
{
    NSBox *box = [[[NSBox alloc] initWithFrame:NSMakeRect(20, y, kPaneWidth - 40, 1)] autorelease];
    [box setBoxType:NSBoxSeparator];
    [v addSubview:box];
}

- (NSView *)paneWithHeight:(CGFloat)h
{
    return [[[FBFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kPaneWidth, h)] autorelease];
}

- (NSView *)generalPane
{
    NSView *v = [self paneWithHeight:296];
    CGFloat y = 20;
    [self label:@"Home page:" in:v y:y];
    homeField = [self field:PrefHomePage in:v y:y width:250];
    NSButton *use = [[[NSButton alloc] initWithFrame:NSMakeRect(kControlX + 256, y - 4, 124, 30)] autorelease];
    [use setBezelStyle:NSRoundedBezelStyle];
    [use setTitle:@"Use Current Page"];
    [[use cell] setControlSize:NSSmallControlSize];
    [use setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [use setTarget:self];
    [use setAction:@selector(useCurrentPage:)];
    [v addSubview:use];
    y += 40;
    [self label:@"Search with:" in:v y:y];
    NSMutableArray *titles = [[searchProviderNames() mutableCopy] autorelease];
    [titles addObject:@"Custom"];
    [self popup:titles values:titles key:PrefSearchProvider in:v y:y width:160];
    y += 30;
    [self label:@"Custom search URL:" in:v y:y];
    customSearchField = [self field:PrefSearchCustomURL in:v y:y width:330];
    y += 24;
    [self note:@"For Custom: the address of a search, with %s where the words go." in:v y:y];
    y += 26;
    [self checkbox:@"Suggest searches while typing an address" key:PrefSearchSuggestions in:v y:y];
    y += 30;
    NSArray *pages = [NSArray arrayWithObjects:@"Home Page", @"Blank Page", nil];
    NSArray *pageValues = [NSArray arrayWithObjects:@"Home", @"Blank", nil];
    [self label:@"New windows open with:" in:v y:y];
    [self popup:pages values:pageValues key:PrefNewWindowPage in:v y:y width:160];
    y += 30;
    [self label:@"New tabs open with:" in:v y:y];
    [self popup:pages values:pageValues key:PrefNewTabPage in:v y:y width:160];
    y += 40;
    [self label:@"Software update:" in:v y:y];
    [self checkbox:@"Check for updates automatically" key:PrefCheckForUpdates in:v y:y];
    NSButton *checkNow = [[[NSButton alloc] initWithFrame:NSMakeRect(kPaneWidth - 140, y - 4, 120, 26)] autorelease];
    [checkNow setBezelStyle:NSRoundedBezelStyle];
    [checkNow setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [checkNow setTitle:@"Check Now"];
    [checkNow setTarget:self];
    [checkNow setAction:@selector(checkForUpdatesNow:)];
    [v addSubview:checkNow];
    y += 20;
    [self note:@"About once a day, when FrostByte starts. Updates are signed, and you choose when to install." in:v y:y];
    return v;
}

- (NSView *)tabsPane
{
    NSView *v = [self paneWithHeight:156];
    CGFloat y = 20;
    [self label:@"Links to new windows:" in:v y:y];
    [self popup:[NSArray arrayWithObjects:@"Open in a new tab", @"Open in a new window", nil]
         values:[NSArray arrayWithObjects:@"Tab", @"Window", nil] key:PrefNewWindowLinksIn in:v y:y width:200];
    y += 30;
    [self checkbox:@"Bring tabs opened by links to the front" key:PrefSelectNewTabs in:v y:y];
    y += 34;
    [self label:@"Command-click:" in:v y:y];
    [self checkbox:@"Opens links in a background tab" key:PrefCommandClickBackground in:v y:y];
    y += 20;
    [self note:@"Hold Shift as well to do the opposite." in:v y:y];
    y += 24;
    [self label:@"Closing:" in:v y:y];
    [self checkbox:@"Warn when closing a window with several tabs" key:PrefWarnClosingTabs in:v y:y];
    return v;
}

- (NSView *)appearancePane
{
    NSView *v = [self paneWithHeight:200];
    CGFloat y = 20;
    [self label:@"Appearance:" in:v y:y];
    [self radio:@"Light" key:PrefAppearance value:@"Light" in:v y:y];
    y += 22;
    [self radio:@"Dark" key:PrefAppearance value:@"Dark" in:v y:y];
    y += 20;
    [self note:@"Dark also asks web pages for their dark style (prefers-color-scheme)." in:v y:y];
    y += 40;
    [self label:@"Accent colour:" in:v y:y];
    NSMutableArray *titles = [NSMutableArray array], *values = [NSMutableArray array];
    for (NSDictionary *c in accentChoices()) {
        [titles addObject:[c objectForKey:@"Title"]];
        [values addObject:[c objectForKey:@"Value"]];
    }
    [self popup:titles values:values key:PrefAccentColor in:v y:y width:160];
    y += 34;
    [self label:@"Show:" in:v y:y];
    [self checkbox:@"Bookmarks bar" key:PrefShowBookmarksBar in:v y:y];
    y += 22;
    [self checkbox:@"Status bar (off: a bubble over the page)" key:PrefShowStatusBar in:v y:y];
    return v;
}

- (NSView *)hardwarePane
{
    NSView *v = [self paneWithHeight:430];
    NSArray *autoOnOff = [NSArray arrayWithObjects:@"Automatic", @"On", @"Off", nil];
    NSArray *autoOnOffValues = [NSArray arrayWithObjects:@"Auto", @"On", @"Off", nil];
    CGFloat y = 20;
    [self label:@"3D graphics acceleration:" in:v y:y];
    NSPopUpButton *graphics = [self popup:autoOnOff values:autoOnOffValues key:PrefGraphics in:v y:y width:120];
    [graphics setAutoenablesItems:NO];
    [[graphics itemAtIndex:1] setEnabled:fbGraphics.radeon || fbGraphics.accelerated];   /* "On" needs a GPU */
    y += 26;
    NSString *detected = fbGraphics.radeon || (FROSTBYTE_GL_ANY_ACCELERATED && fbGraphics.accelerated)
        ? [NSString stringWithFormat:str("%@ \xe2\x80\x94 detected%@. Now: %@."),
           fbGraphics.renderer[0] ? str(fbGraphics.renderer) : fbGraphics.radeon ? @"Radeon (RadeonNI)" : @"Accelerated OpenGL",
           fbGraphics.sharedBuffers ? @", with shared buffers" : @"",
           fbGPUActive ? (fbZeroCopyActive ? @"GPU, zero-copy frames" : @"GPU") : @"CPU rendering"]
        : [NSString stringWithFormat:@"No accelerated GPU detected: CPU rendering. Now: %@.",
           fbGPUActive ? @"GPU (forced)" : @"CPU rendering"];
    [self note:detected in:v y:y];
    y += 32;
    NSButton *zc = [self checkbox:@"Zero-copy frames (GPU frames shown without a copy)" key:PrefZeroCopy in:v y:y];
    [zc setEnabled:fbGraphics.sharedBuffers];
    if (!fbGraphics.sharedBuffers) {
        y += 20;
        [self note:@"Needs the driver's shared buffers, which were not detected." in:v y:y];
    }
    y += 34;
    [self label:@"Hardware video decoding:" in:v y:y];
    NSPopUpButton *video = [self popup:autoOnOff values:autoOnOffValues key:PrefVideoDecoding in:v y:y width:120];
    [video setAutoenablesItems:NO];
    [[video itemAtIndex:1] setEnabled:fbGraphics.uvdSessions];                         /* "On" needs UVD */
    y += 26;
    [self note:[NSString stringWithFormat:@"%@ Now: %@.",
                fbGraphics.uvdSessions ? @"Radeon UVD detected, with decode sessions (H.264)."
                : fbGraphics.uvd ? @"Radeon UVD firmware detected; its driver has decode sessions off."
                : @"No UVD video decoder detected.",
                fbHardwareVideoActive ? @"hardware H.264" : @"CPU decoding"] in:v y:y];
    y += 24;
    [[self checkbox:@"Prefer H.264 so the card decodes it (YouTube)" key:PrefPreferH264 in:v y:y]
        setEnabled:fbGraphics.uvdSessions];
    y += 30;
    [self separator:v y:y];
    y += 14;
    [self text:@"Advanced" in:v frame:NSMakeRect(20, y, 200, 17) align:NSLeftTextAlignment small:NO];
    y += 24;
    [self label:@"JavaScript:" in:v y:y];
    [self checkbox:@"Use the JIT compiler" key:PrefJIT in:v y:y];
    y += 22;
    [self checkbox:@"Keep compiled JavaScript on disk (faster repeat visits)" key:PrefBytecodeCache in:v y:y];
    y += 22;
    cacheNote = [self text:@"" in:v frame:NSMakeRect(kControlX + 18, y + 4, 260, 14) align:NSLeftTextAlignment small:YES];
    NSButton *empty = [[[NSButton alloc] initWithFrame:NSMakeRect(kPaneWidth - 140, y - 2, 120, 26)] autorelease];
    [empty setBezelStyle:NSRoundedBezelStyle];
    [empty setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [empty setTitle:@"Empty Cache"];
    [empty setTarget:self];
    [empty setAction:@selector(emptyBytecodeCache:)];
    [v addSubview:empty];
    [self updateCacheNote];
    y += 34;
    [self label:@"CPU rasterization threads:" in:v y:y];
    NSMutableArray *titles = [NSMutableArray arrayWithObject:@"Automatic"];
    NSMutableArray *values = [NSMutableArray arrayWithObject:[NSNumber numberWithInt:0]];
    for (int i = 1; i <= 16; i++) {
        [titles addObject:[NSString stringWithFormat:@"%d", i]];
        [values addObject:[NSNumber numberWithInt:i]];
    }
    [self popup:titles values:values key:PrefRasterThreads in:v y:y width:120];
    y += 40;
    [self separator:v y:y];
    y += 14;
    [self text:@"Changes in this pane take effect after restarting FrostByte." in:v
         frame:NSMakeRect(20, y + 8, kPaneWidth - 200, 17) align:NSLeftTextAlignment small:YES];
    NSButton *restart = [[[NSButton alloc] initWithFrame:NSMakeRect(kPaneWidth - 160, y, 140, 30)] autorelease];
    [restart setBezelStyle:NSRoundedBezelStyle];
    [restart setTitle:@"Restart FrostByte"];
    [restart setTarget:self];
    [restart setAction:@selector(restart:)];
    [v addSubview:restart];
    return v;
}

- (id)init
{
    if (!(self = [super init]))
        return nil;
    bound = [[NSMutableArray alloc] init];
    panes = [[NSMutableDictionary alloc] init];
    [panes setObject:[self generalPane] forKey:PaneGeneral];
    [panes setObject:[self tabsPane] forKey:PaneTabs];
    [panes setObject:[self appearancePane] forKey:PaneAppearance];
    [panes setObject:[self hardwarePane] forKey:PaneHardware];

    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kPaneWidth, 200)
        styleMask:NSTitledWindowMask | NSClosableWindowMask | NSUnifiedTitleAndToolbarWindowMask
        backing:NSBackingStoreBuffered defer:YES];
    [window setReleasedWhenClosed:NO];
    [window setShowsToolbarButton:NO];
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"FrostBytePreferences"];
    [toolbar setDelegate:(id)self];
    [toolbar setAllowsUserCustomization:NO];
    [toolbar setDisplayMode:NSToolbarDisplayModeIconAndLabel];
    [window setToolbar:toolbar];
    [toolbar release];
    [self selectPane:PaneGeneral animate:NO];
    [window center];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(defaultsChanged:)
                                                 name:NSUserDefaultsDidChangeNotification object:nil];
    return self;
}

- (void)show
{
    [self refresh];
    [window makeKeyAndOrderFront:nil];
}

/* controls <- defaults */
- (void)refresh
{
    NSUserDefaults *d = prefs();
    for (NSDictionary *b in bound) {
        id control = [b objectForKey:@"control"];
        NSString *key = [b objectForKey:@"key"];
        id value = [b objectForKey:@"value"];
        if ([control isKindOfClass:[NSPopUpButton class]]) {
            id stored = [d objectForKey:key];
            NSInteger i = [control indexOfItemWithRepresentedObject:stored];
            if (i < 0 && [stored isKindOfClass:[NSString class]])     /* tolerate "auto" / "AUTO" */
                for (NSMenuItem *item in [control itemArray])
                    if ([[item representedObject] isKindOfClass:[NSString class]]
                        && [[item representedObject] caseInsensitiveCompare:stored] == NSOrderedSame)
                        i = [control indexOfItem:item];
            if (i >= 0)
                [control selectItemAtIndex:i];
        } else if ([control isKindOfClass:[NSButton class]]) {
            BOOL on = value ? [[d stringForKey:key] caseInsensitiveCompare:value] == NSOrderedSame : [d boolForKey:key];
            [control setState:on ? NSOnState : NSOffState];
        } else if ([control isKindOfClass:[NSTextField class]]) {
            if ([window firstResponder] != [control currentEditor])
                [control setStringValue:[d stringForKey:key] ?: @""];
        }
    }
    [customSearchField setEnabled:prefIs(PrefSearchProvider, @"Custom")];
}

- (void)defaultsChanged:(NSNotification *)n { (void)n; if ([window isVisible]) [self refresh]; }

/* defaults <- a control */
- (void)controlChanged:(id)sender
{
    for (NSDictionary *b in bound) {
        if ([b objectForKey:@"control"] != sender)
            continue;
        NSString *key = [b objectForKey:@"key"];
        id value = [b objectForKey:@"value"];
        if ([sender isKindOfClass:[NSPopUpButton class]])
            [prefs() setObject:[[sender selectedItem] representedObject] forKey:key];
        else if ([sender isKindOfClass:[NSButton class]]) {
            if (value)
                [prefs() setObject:value forKey:key];
            else
                [prefs() setBool:[sender state] == NSOnState forKey:key];
        } else if ([sender isKindOfClass:[NSTextField class]])
            [prefs() setObject:[sender stringValue] forKey:key];
    }
    [self refresh];
    applyLivePreferences();
}

- (void)controlTextDidChange:(NSNotification *)n { [self controlChanged:[n object]]; }

- (void)useCurrentPage:(id)sender
{
    (void)sender;
    FBWindowController *c = nil;
    for (NSWindow *w in [NSApp orderedWindows])
        if ((c = controllerForWindow(w)))
            break;
    NSString *uri = c && c->current ? [c->current uri] : nil;
    if (!uri)
        return;
    [prefs() setObject:uri forKey:PrefHomePage];
    [homeField setStringValue:uri];
}

- (void)restart:(id)sender { (void)sender; relaunch(); }
- (void)checkForUpdatesNow:(id)sender { (void)sender; fbCheckForUpdates(); }

- (void)updateCacheNote
{
    [cacheNote setStringValue:[NSString stringWithFormat:@"Using %.1f MB of %d MB.",
        fbBytecodeCacheSize() / 1048576.0, (int)[prefs() integerForKey:PrefBytecodeCacheMB]]];
}

- (void)emptyBytecodeCache:(id)sender
{
    (void)sender;
    fbEmptyBytecodeCache();
    [self updateCacheNote];
}

/* ---- panes ---- */

- (void)selectPane:(NSString *)ident animate:(BOOL)animate
{
    NSView *pane = [panes objectForKey:ident];
    if (!pane)
        return;
    [currentPane release];
    currentPane = [ident copy];
    [[window toolbar] setSelectedItemIdentifier:ident];
    [window setTitle:ident];
    /* resize to the pane, keeping the top edge */
    NSRect old = [window frame];
    NSRect f = [window frameRectForContentRect:NSMakeRect(0, 0, NSWidth([pane frame]), NSHeight([pane frame]))];
    f.origin.x = old.origin.x;
    f.origin.y = NSMaxY(old) - NSHeight(f);
    NSView *blank = [[[NSView alloc] initWithFrame:[[window contentView] frame]] autorelease];
    [window setContentView:blank];
    [window setFrame:f display:YES animate:animate];
    [window setContentView:pane];
    [self refresh];
}

- (void)paneClicked:(NSToolbarItem *)item { [self selectPane:[item itemIdentifier] animate:YES]; }

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)ident willBeInsertedIntoToolbar:(BOOL)inserted
{
    (void)toolbar; (void)inserted;
    NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:ident] autorelease];
    [item setLabel:ident];
    NSImage *image = nil;
    if ([ident isEqual:PaneGeneral]) image = [NSImage imageNamed:NSImageNamePreferencesGeneral];
    else if ([ident isEqual:PaneTabs]) image = resourceImage(@"toolbar/newTab.tiff");
    else if ([ident isEqual:PaneAppearance]) image = [NSImage imageNamed:NSImageNameColorPanel];
    else if ([ident isEqual:PaneHardware]) image = [NSImage imageNamed:NSImageNameComputer];
    [item setImage:image];
    [item setTarget:self];
    [item setAction:@selector(paneClicked:)];
    return item;
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
    (void)toolbar;
    return [NSArray arrayWithObjects:PaneGeneral, PaneTabs, PaneAppearance, PaneHardware, nil];
}
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return [self toolbarDefaultItemIdentifiers:toolbar]; }
- (NSArray *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar { return [self toolbarDefaultItemIdentifiers:toolbar]; }

@end

