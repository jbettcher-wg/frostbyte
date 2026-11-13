/*
 * FrostByte: preferences (NSUserDefaults keys and defaults), resources, search and typed-URL handling.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"

NSString *fbResourceDir;

NSString *const PrefHomePage = @"HomePage";
NSString *const PrefSearchProvider = @"SearchProvider";
NSString *const PrefSearchCustomURL = @"SearchCustomURL";
NSString *const PrefNewWindowPage = @"NewWindowsOpenWith";
NSString *const PrefNewTabPage = @"NewTabsOpenWith";
NSString *const PrefNewWindowLinksIn = @"OpenNewWindowLinksIn";
NSString *const PrefCommandClickBackground = @"CommandClickOpensInBackground";
NSString *const PrefSelectNewTabs = @"SelectNewTabs";
NSString *const PrefWarnClosingTabs = @"WarnWhenClosingWindowWithTabs";
NSString *const PrefAppearance = @"Appearance";
NSString *const PrefAccentColor = @"AccentColor";
NSString *const PrefSearchSuggestions = @"SearchSuggestions";
NSString *const PrefShowBookmarksBar = @"ShowBookmarksBar";
NSString *const PrefShowStatusBar = @"ShowStatusBar";
NSString *const PrefGraphics = @"GraphicsAcceleration";
NSString *const PrefZeroCopy = @"ZeroCopyFrames";
NSString *const PrefVideoDecoding = @"HardwareVideoDecoding";
NSString *const PrefWebGL = @"WebGL";
NSString *const PrefPreferH264 = @"PreferH264WithHardwareDecoding";
NSString *const PrefJIT = @"JavaScriptJIT";
NSString *const PrefRasterThreads = @"CPURasterThreads";
NSString *const PrefBytecodeCache = @"CacheCompiledJavaScript";
NSString *const PrefBytecodeCacheMB = @"CompiledJavaScriptCacheMB";

static const char *const kDefaultHome = "https://en.wikipedia.org/wiki/PowerPC";

void registerDefaults(void)
{
    const char *home = getenv("FROSTBYTE_HOME_URL");
    [prefs() registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
        str(home && *home ? home : kDefaultHome), PrefHomePage,
        @"Google", PrefSearchProvider,
        @"https://www.google.com/search?q=%s", PrefSearchCustomURL,
        @"Home", PrefNewWindowPage,
        @"Blank", PrefNewTabPage,
        @"Tab", PrefNewWindowLinksIn,
        [NSNumber numberWithBool:YES], PrefCommandClickBackground,
        [NSNumber numberWithBool:YES], PrefSelectNewTabs,
        [NSNumber numberWithBool:YES], PrefWarnClosingTabs,
        @"Light", PrefAppearance,
        @"Default", PrefAccentColor,
        [NSNumber numberWithBool:YES], PrefSearchSuggestions,
        [NSNumber numberWithBool:YES], PrefShowBookmarksBar,
        [NSNumber numberWithBool:NO], PrefShowStatusBar,
        @"Auto", PrefGraphics,
        [NSNumber numberWithBool:YES], PrefZeroCopy,
        @"Auto", PrefVideoDecoding,
        @"Off", PrefWebGL,
        [NSNumber numberWithBool:YES], PrefPreferH264,
        [NSNumber numberWithBool:YES], PrefJIT,
        [NSNumber numberWithInt:0], PrefRasterThreads,
        [NSNumber numberWithBool:YES], PrefBytecodeCache,
        [NSNumber numberWithInt:512], PrefBytecodeCacheMB, nil]];
    fbUpdateRegisterDefaults();
}

NSImage *resourceImage(NSString *relativePath)
{
    static NSMutableDictionary *cache;
    if (!cache)
        cache = [[NSMutableDictionary alloc] init];
    NSImage *image = [cache objectForKey:relativePath];
    if (!image) {
        image = [[[NSImage alloc] initWithContentsOfFile:[fbResourceDir stringByAppendingPathComponent:relativePath]] autorelease];
        if (image)
            [cache setObject:image forKey:relativePath];
    }
    return image;
}

/* ---- search providers ---- */

static const struct { const char *name, *url; } kSearchProviders[] = {
    { "Google", "https://www.google.com/search?q=%s" },
    { "DuckDuckGo", "https://html.duckduckgo.com/html/?q=%s" },
    { "Bing", "https://www.bing.com/search?q=%s" },
    { "Wikipedia", "https://en.wikipedia.org/w/index.php?search=%s" },
    { "Startpage", "https://www.startpage.com/do/search?q=%s" },
};
#define FB_SEARCH_PROVIDERS (sizeof kSearchProviders / sizeof kSearchProviders[0])

NSArray *searchProviderNames(void)
{
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned i = 0; i < FB_SEARCH_PROVIDERS; i++)
        [names addObject:str(kSearchProviders[i].name)];
    return names;
}

NSString *searchProviderName(void)
{
    if (getenv("FROSTBYTE_SEARCH_URL"))
        return @"Search";
    NSString *p = [prefs() stringForKey:PrefSearchProvider];
    for (unsigned i = 0; i < FB_SEARCH_PROVIDERS; i++)
        if ([p isEqual:str(kSearchProviders[i].name)])
            return p;
    return [p isEqual:@"Custom"] ? @"Search" : @"Google";
}

/* The search URL template ("%s" = query): FROSTBYTE_SEARCH_URL, else the chosen provider. */
static NSString *searchTemplate(void)
{
    const char *t = getenv("FROSTBYTE_SEARCH_URL");
    if (t && strstr(t, "%s"))
        return str(t);
    NSString *p = [prefs() stringForKey:PrefSearchProvider];
    if ([p isEqual:@"Custom"]) {
        NSString *custom = [prefs() stringForKey:PrefSearchCustomURL];
        if ([custom rangeOfString:@"%s"].location != NSNotFound)
            return custom;
    }
    for (unsigned i = 0; i < FB_SEARCH_PROVIDERS; i++)
        if ([p isEqual:str(kSearchProviders[i].name)])
            return str(kSearchProviders[i].url);
    return str(kSearchProviders[0].url);
}

const char *homeURL(void)
{
    NSString *h = [prefs() stringForKey:PrefHomePage];
    return [h length] ? [h UTF8String] : kDefaultHome;
}

/* "%s" in the search template -> escaped query. Returns a g_malloc'd string. */
char *searchURLFor(const char *query)
{
    char *escaped = g_uri_escape_string(query, NULL, FALSE);
    char *t = g_strdup([searchTemplate() UTF8String]);
    char *at = strstr(t, "%s");
    char *url = at ? g_strdup_printf("%.*s%s%s", (int)(at - t), t, escaped, at + 2) : g_strdup(t);
    g_free(t);
    g_free(escaped);
    return url;
}

/* What the user typed into the location field -> a URL; plain words become a search. */
char *urlForLocationText(const char *text)
{
    while (*text == ' ') text++;
    if (!*text) return NULL;
    if (strstr(text, "://") || !g_ascii_strncasecmp(text, "about:", 6) || !g_ascii_strncasecmp(text, "data:", 5)
        || !g_ascii_strncasecmp(text, "javascript:", 11) || !g_ascii_strncasecmp(text, "file:", 5))
        return g_strdup(text);
    if (text[0] == '/')
        return g_strconcat("file://", text, NULL);
    gboolean hasSpace = strchr(text, ' ') != NULL;
    gboolean looksLikeHost = strchr(text, '.') || !g_ascii_strncasecmp(text, "localhost", 9) || strchr(text, ':');
    if (!hasSpace && looksLikeHost)
        return g_strconcat("https://", text, NULL);
    return searchURLFor(text);
}

gboolean unrefLater(gpointer object)
{
    g_object_unref(object);
    return G_SOURCE_REMOVE;
}
