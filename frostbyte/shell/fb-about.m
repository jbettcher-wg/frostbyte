/*
 * FrostByte shell: the About window.
 *   Left: a view out of a four-pane window onto snowy pines; frost grows in from the edges of the
 *   glass until the view is nearly gone, then thaws (24 s cycle), with light snow falling.
 *   Right: icon, name, version, what this run is built on, Credits / Licences.
 * The scene is drawn on the CPU with CoreGraphics at 15 fps into a 270 x 378 bitmap: no GL, no
 * Core Animation, so it behaves the same on any graphics tier and on a G5. Every buffer is
 * byte-ordered ARGB (kCGBitmapByteOrder32Big), so nothing here depends on the host's endianness.
 * The animation runs only while the window is on screen.
 * Copyright (c) 2026 Jordan Bettcher
 * SPDX-License-Identifier: MIT
 */
#include "frostbyte.h"
#include <math.h>
#include <sys/sysctl.h>
#include <CoreServices/CoreServices.h>

enum { SW = 270, SH = 378, NFLAKES = 14 };
static const double kCycle = 24.0, kFps = 15.0;

/* ---------------------------------------------------------------- noise ---- */

static inline uint32_t hash2(int x, int y, uint32_t seed)
{
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u + seed * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}
static inline double lattice(int x, int y, uint32_t seed) { return (hash2(x, y, seed) & 0xffff) / 65535.0; }
static inline double fade(double t) { return t * t * (3 - 2 * t); }

/* Smooth value noise in [0,1]. */
static double vnoise(double x, double y, uint32_t seed)
{
    int x0 = (int)floor(x), y0 = (int)floor(y);
    double fx = fade(x - x0), fy = fade(y - y0);
    double a = lattice(x0, y0, seed), b = lattice(x0 + 1, y0, seed);
    double c = lattice(x0, y0 + 1, seed), d = lattice(x0 + 1, y0 + 1, seed);
    return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy;
}

/* fBm (turbulence = sum of |2n-1|) normalised to [0,1]. */
static double fbm(double x, double y, int octaves, BOOL turbulence, uint32_t seed)
{
    double sum = 0, amp = 1, norm = 0;
    for (int o = 0; o < octaves; o++) {
        double n = vnoise(x, y, seed + (uint32_t)o * 101u);
        sum += amp * (turbulence ? fabs(2 * n - 1) : n);
        norm += amp;
        amp *= 0.5; x *= 2; y *= 2;
    }
    return sum / norm;
}

static inline double clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

/* ---------------------------------------------------------------- scene ---- */

typedef struct { CGFloat sky[4][4]; CGFloat skyStops[4]; CGFloat hill[3], farTree[3], nearTree[3]; } FBScenePalette;

static const FBScenePalette kDusk = {
    { { 0x2c / 255.0, 0x3e / 255.0, 0x66 / 255.0, 1 }, { 0x5b / 255.0, 0x6f / 255.0, 0x9c / 255.0, 1 },
      { 0xc9 / 255.0, 0xa9 / 255.0, 0xb6 / 255.0, 1 }, { 0xef / 255.0, 0xd5 / 255.0, 0xc4 / 255.0, 1 } },
    { 0, 0.45, 0.78, 1 },
    { 0x87 / 255.0, 0x96 / 255.0, 0xb4 / 255.0 }, { 0x4c / 255.0, 0x5d / 255.0, 0x80 / 255.0 }, { 0x1f / 255.0, 0x2d / 255.0, 0x45 / 255.0 },
};

static void fillPath(CGContextRef c, const CGFloat *pts, int n, const CGFloat rgb[3])
{
    CGContextSetRGBFillColor(c, rgb[0], rgb[1], rgb[2], 1);
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, pts[0], pts[1]);
    for (int i = 1; i < n; i++)
        CGContextAddLineToPoint(c, pts[2 * i], pts[2 * i + 1]);
    CGContextClosePath(c);
    CGContextFillPath(c);
}

/* A pine: three stacked triangles and a trunk, apex at (x, top). */
static void pine(CGContextRef c, CGFloat x, CGFloat top, CGFloat base, CGFloat halfWidth, const CGFloat rgb[3])
{
    CGFloat h = base - top;
    CGFloat t1[] = { x - halfWidth * 0.53, top + h * 0.95, x + halfWidth * 0.53, top + h * 0.95, x, top };
    CGFloat t2[] = { x - halfWidth * 0.76, top + h * 0.83, x + halfWidth * 0.76, top + h * 0.83, x, top + h * 0.29 };
    CGFloat t3[] = { x - halfWidth, top + h, x + halfWidth, top + h, x, top + h * 0.51 };
    fillPath(c, t1, 3, rgb); fillPath(c, t2, 3, rgb); fillPath(c, t3, 3, rgb);
    CGContextSetRGBFillColor(c, rgb[0], rgb[1], rgb[2], 1);
    CGContextFillRect(c, CGRectMake(x - 4, top + h - 2, 8, 18));
}

/* Paints the view out of the window into an SW x SH ARGB context drawn top-down (y grows downward). */
static void paintScene(CGContextRef c, const FBScenePalette *p)
{
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGGradientRef sky = CGGradientCreateWithColorComponents(rgb, &p->sky[0][0], p->skyStops, 4);
    CGContextDrawLinearGradient(c, sky, CGPointMake(0, 0), CGPointMake(0, SH), 0);
    CGGradientRelease(sky);
    CGColorSpaceRelease(rgb);

    /* Distant ridge. */
    CGContextSetRGBFillColor(c, p->hill[0], p->hill[1], p->hill[2], 1);
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, 0, 250);
    CGContextAddQuadCurveToPoint(c, 60, 215, 130, 235);
    CGContextAddQuadCurveToPoint(c, 200, 255, 270, 225);
    CGContextAddLineToPoint(c, 270, SH); CGContextAddLineToPoint(c, 0, SH);
    CGContextClosePath(c); CGContextFillPath(c);

    /* Far trees. */
    static const CGFloat far[][6] = {
        { 30, 250, 44, 200, 58, 250 }, { 70, 246, 82, 206, 94, 246 }, { 160, 240, 174, 192, 188, 240 },
        { 205, 236, 216, 200, 227, 236 }, { 238, 238, 250, 196, 262, 238 },
    };
    for (unsigned i = 0; i < sizeof far / sizeof far[0]; i++)
        fillPath(c, far[i], 3, p->farTree);

    /* Near pines. */
    pine(c, 64, 140, 334, 34, p->nearTree);
    pine(c, 199, 118, 340, 41, p->nearTree);

    /* Snow banks. */
    CGContextSetRGBFillColor(c, 0xf4 / 255.0, 0xf7 / 255.0, 0xfb / 255.0, 1);
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, 0, 340);
    CGContextAddQuadCurveToPoint(c, 80, 322, 150, 338);
    CGContextAddQuadCurveToPoint(c, 220, 354, 270, 334);
    CGContextAddLineToPoint(c, 270, SH); CGContextAddLineToPoint(c, 0, SH);
    CGContextClosePath(c); CGContextFillPath(c);
    CGContextSetRGBFillColor(c, 0xe3 / 255.0, 0xea / 255.0, 0xf3 / 255.0, 1);
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, 0, 352);
    CGContextAddQuadCurveToPoint(c, 90, 340, 170, 354);
    CGContextAddQuadCurveToPoint(c, 250, 368, 270, 350);
    CGContextAddLineToPoint(c, 270, SH); CGContextAddLineToPoint(c, 0, SH);
    CGContextClosePath(c); CGContextFillPath(c);
}

/* Three passes of a separable box blur (radius r) over an ARGB buffer: close to a Gaussian. */
static void boxBlur(uint8_t *px, int w, int h, int r)
{
    uint8_t *tmp = malloc((size_t)w * h * 4);
    for (int pass = 0; pass < 3; pass++) {
        for (int y = 0; y < h; y++)
            for (int ch = 0; ch < 4; ch++) {
                int sum = 0;
                for (int k = -r; k <= r; k++) sum += px[(y * w + (k < 0 ? 0 : k >= w ? w - 1 : k)) * 4 + ch];
                for (int x = 0; x < w; x++) {
                    tmp[(y * w + x) * 4 + ch] = (uint8_t)(sum / (2 * r + 1));
                    int out = x - r, in = x + r + 1;
                    sum += px[(y * w + (in >= w ? w - 1 : in)) * 4 + ch] - px[(y * w + (out < 0 ? 0 : out)) * 4 + ch];
                }
            }
        for (int x = 0; x < w; x++)
            for (int ch = 0; ch < 4; ch++) {
                int sum = 0;
                for (int k = -r; k <= r; k++) sum += tmp[((k < 0 ? 0 : k >= h ? h - 1 : k) * w + x) * 4 + ch];
                for (int y = 0; y < h; y++) {
                    px[(y * w + x) * 4 + ch] = (uint8_t)(sum / (2 * r + 1));
                    int out = y - r, in = y + r + 1;
                    sum += tmp[((in >= h ? h - 1 : in) * w + x) * 4 + ch] - tmp[((out < 0 ? 0 : out) * w + x) * 4 + ch];
                }
            }
    }
    free(tmp);
}

/* ------------------------------------------------------------ the scene view ---- */

@interface FBAboutScene : NSView {
    uint8_t *scene, *blurred, *frost, *work, *out;    /* SW*SH*4, ARGB */
    uint16_t *radius;                                 /* elliptical distance from the clear centre, x1000 */
    CGContextRef workContext;
    double start;
    NSTimer *timer;
@public
    int frostMode;                                    /* 0 cycle, 1 frosted, 2 clear (FROSTBYTE_ABOUT_FROST) */
}
- (void)startAnimating;
- (void)stopAnimating;
@end

@implementation FBAboutScene

static CGContextRef argbContext(void *data)
{
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(data, SW, SH, 8, SW * 4, rgb,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(rgb);
    return c;
}

- (id)initWithFrame:(NSRect)frame
{
    if (!(self = [super initWithFrame:frame]))
        return nil;
    size_t bytes = (size_t)SW * SH * 4;
    scene = calloc(bytes, 1); blurred = malloc(bytes); frost = malloc(bytes);
    work = malloc(bytes); out = malloc(bytes);
    radius = malloc((size_t)SW * SH * sizeof *radius);

    CGContextRef c = argbContext(scene);
    CGContextTranslateCTM(c, 0, SH);
    CGContextScaleCTM(c, 1, -1);                      /* top-down, like the design's SVG */
    paintScene(c, &kDusk);
    CGContextRelease(c);
    memcpy(blurred, scene, bytes);
    boxBlur(blurred, SW, SH, 2);

    /* The frost: a pale tint, long fern-like streaks (anisotropic turbulence), and fine grain. */
    for (int y = 0; y < SH; y++)
        for (int x = 0; x < SW; x++) {
            double tint = 0.38;
            double fern = clamp01(2.2 * fbm(x * 0.018, y * 0.09, 4, YES, 3) - 0.9) * 0.85;
            double fine = clamp01(1.6 * fbm(x * 0.85, y * 0.85, 2, NO, 7) - 0.55) * 0.7;
            /* "over" compositing, back to front: tint, fern (0.93,0.97,1), fine (white) */
            double r = 226 / 255.0, g = 238 / 255.0, b = 250 / 255.0, a = tint;
            r = r * a; g = g * a; b = b * a;                       /* premultiplied */
            r = 0.93 * fern + r * (1 - fern); g = 0.97 * fern + g * (1 - fern); b = 1.0 * fern + b * (1 - fern);
            a = fern + a * (1 - fern);
            r = fine + r * (1 - fine); g = fine + g * (1 - fine); b = fine + b * (1 - fine);
            a = fine + a * (1 - fine);
            uint8_t *p = frost + (y * SW + x) * 4;
            p[0] = (uint8_t)lrint(a * 255); p[1] = (uint8_t)lrint(r * 255);
            p[2] = (uint8_t)lrint(g * 255); p[3] = (uint8_t)lrint(b * 255);
            /* The clear patch is an ellipse 70% x 62% of the pane, centred at (50%, 52%). */
            double dx = (x + 0.5 - SW * 0.5) / (SW * 0.70), dy = (y + 0.5 - SH * 0.52) / (SH * 0.62);
            double d = sqrt(dx * dx + dy * dy);
            radius[y * SW + x] = (uint16_t)(d > 2 ? 2000 : lrint(d * 1000));
        }

    workContext = argbContext(work);
    CGContextTranslateCTM(workContext, 0, SH);
    CGContextScaleCTM(workContext, 1, -1);
    start = [NSDate timeIntervalSinceReferenceDate];
    const char *mode = getenv("FROSTBYTE_ABOUT_FROST");
    frostMode = mode && !strcmp(mode, "frosted") ? 1 : mode && !strcmp(mode, "clear") ? 2 : 0;
    return self;
}

- (void)dealloc
{
    [self stopAnimating];
    CGContextRelease(workContext);
    free(scene); free(blurred); free(frost); free(work); free(out); free(radius);
    [super dealloc];
}

- (BOOL)isOpaque { return YES; }

- (void)startAnimating
{
    if (timer)
        return;
    timer = [[NSTimer timerWithTimeInterval:1.0 / kFps target:self selector:@selector(tick:) userInfo:nil repeats:YES] retain];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)stopAnimating
{
    [timer invalidate];
    [timer release];
    timer = nil;
}

- (void)tick:(NSTimer *)t { (void)t; [self setNeedsDisplay:YES]; }

static double easeInOut(double t) { return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2; }

/* How far the clear patch reaches (fraction of the ellipse), as in the design's keyframes:
 * 0% 0.70, 42% 0.12, 58% 0.12, 100% 0.70, ease-in-out between. */
- (double)clearAt:(double)now
{
    if (frostMode == 1) return 0.08;
    if (frostMode == 2) return 0.95;
    double f = fmod(now - start, kCycle) / kCycle;
    if (f < 0.42) return 0.70 + (0.12 - 0.70) * easeInOut(f / 0.42);
    if (f < 0.58) return 0.12;
    return 0.12 + (0.70 - 0.12) * easeInOut((f - 0.58) / 0.42);
}

- (void)compose
{
    double now = [NSDate timeIntervalSinceReferenceDate];
    size_t n = (size_t)SW * SH;

    /* Snow falls behind the glass. */
    memcpy(work, scene, n * 4);
    for (int i = 0; i < NFLAKES; i++) {
        double left = (i * 53 + 17) % 262, size = 2 + i % 3, dur = 7 + (i * 37) % 9, delay = -((i * 29) % 13);
        double y = fmod(now - start - delay, dur) / dur * 420 - 20;
        CGContextSetRGBFillColor(workContext, 1, 1, 1, 0.55 + (i % 4) * 0.1);
        CGContextFillEllipseInRect(workContext, CGRectMake(left, y, size, size));
    }

    /* Frost mask: 0 inside the clear patch, rising linearly to 1 over 0.26 of the ellipse. */
    double clear = [self clearAt:now];
    uint16_t lut[2001];
    for (int q = 0; q <= 2000; q++)
        lut[q] = (uint16_t)lrint(clamp01((q / 1000.0 - clear) / 0.26) * 256);

    for (size_t i = 0; i < n; i++) {
        unsigned m = lut[radius[i]];
        const uint8_t *s = work + i * 4, *b = blurred + i * 4, *f = frost + i * 4;
        uint8_t *o = out + i * 4;
        unsigned fa = (f[0] * m) >> 8, keep = 255 - fa;
        o[0] = 255;
        for (int ch = 1; ch < 4; ch++) {
            unsigned base = (s[ch] * (256 - m) + b[ch] * m) >> 8;     /* the glass blurs where it is frosted */
            o[ch] = (uint8_t)(((f[ch] * m) >> 8) + (base * keep) / 255);
        }
    }
}

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    [self compose];
    CGContextRef cg = [[NSGraphicsContext currentContext] graphicsPort];
    CGContextRef c = argbContext(out);
    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextDrawImage(cg, CGRectMake(0, 0, SW, SH), image);
    CGImageRelease(image);
    CGContextRelease(c);

    /* The window frame: a cream border with a hairline and a soft inner shadow, and the mullions. */
    NSColor *cream = [NSColor colorWithCalibratedRed:0xf3 / 255.0 green:0xf1 / 255.0 blue:0xec / 255.0 alpha:1];
    NSColor *line = [NSColor colorWithCalibratedRed:0xcf / 255.0 green:0xca / 255.0 blue:0xc0 / 255.0 alpha:1];
    NSRect b = [self bounds];
    for (int i = 0; i < 12; i++) {
        [[NSColor colorWithCalibratedWhite:0 alpha:0.018 * (12 - i) / 12.0] set];
        NSFrameRectWithWidthUsingOperation(NSInsetRect(b, 11 + i, 11 + i), 1, NSCompositeSourceOver);
    }
    [cream set];
    NSFrameRectWithWidth(b, 10);
    [line set];
    NSFrameRectWithWidth(NSInsetRect(b, 10, 10), 1);
    CGFloat mx = 131, my = SH - 170 - 8;   /* the design's top-down y = 170 */
    [cream set];
    NSRectFill(NSMakeRect(mx, 0, 8, SH));
    NSRectFill(NSMakeRect(0, my, SW, 8));
    [line set];
    NSRectFill(NSMakeRect(mx - 1, 0, 1, SH)); NSRectFill(NSMakeRect(mx + 8, 0, 1, SH));
    NSRectFill(NSMakeRect(0, my - 1, SW, 1)); NSRectFill(NSMakeRect(0, my + 8, SW, 1));
}
@end

/* ------------------------------------------------------------- the info panel ---- */

@interface FBAboutInfo : NSView
@end
@implementation FBAboutInfo
- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r
{
    (void)r;
    fillGradient([self bounds], [NSColor colorWithCalibratedRed:0xf7 / 255.0 green:0xf8 / 255.0 blue:0xfa / 255.0 alpha:1],
                 [NSColor colorWithCalibratedRed:0xe9 / 255.0 green:0xec / 255.0 blue:0xf0 / 255.0 alpha:1]);
}
@end

@interface FBAboutFlipped : NSView
@end
@implementation FBAboutFlipped
- (BOOL)isFlipped { return YES; }
@end

/* A borderless text link with the pointing-hand cursor. */
@interface FBAboutLink : NSButton
@end
@implementation FBAboutLink
- (void)resetCursorRects { [self addCursorRect:[self bounds] cursor:[NSCursor pointingHandCursor]]; }
@end

static NSColor *rgbHex(unsigned v)
{
    return [NSColor colorWithCalibratedRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
}

static NSTextField *label(NSView *parent, NSRect frame, NSString *text, NSFont *font, NSColor *color)
{
    NSTextField *t = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [t setStringValue:text];
    [t setFont:font];
    [t setTextColor:color];
    [t setBezeled:NO];
    [t setDrawsBackground:NO];
    [t setEditable:NO];
    [t setSelectable:NO];
    [[t cell] setLineBreakMode:NSLineBreakByTruncatingTail];
    [parent addSubview:t];
    return t;
}

static NSString *systemVersion(void)
{
    SInt32 major = 0, minor = 0, bugfix = 0;
    Gestalt(gestaltSystemVersionMajor, &major);
    Gestalt(gestaltSystemVersionMinor, &minor);
    Gestalt(gestaltSystemVersionBugFix, &bugfix);
#if defined(__ppc64__)
    const char *arch = "ppc64";
#else
    const char *arch = "ppc";
#endif
    return [NSString stringWithFormat:str("Mac OS X %d.%d.%d · %s"), (int)major, (int)minor, (int)bugfix, arch];
}

static NSString *javascriptLine(void)
{
    const char *jit = getenv("JSC_useJIT");
    if (jit && (!strcmp(jit, "0") || !g_ascii_strcasecmp(jit, "false")))
        return @"JavaScriptCore, interpreter";
    return @"JavaScriptCore, JIT through FTL";
}

static NSString *graphicsLine(void)
{
    NSString *card = fbGraphics.renderer[0] ? str(fbGraphics.renderer) : @"No accelerated renderer";
    if (!fbGPUActive)
        return [card stringByAppendingString:str(" · CPU rendering")];
    return [card stringByAppendingString:fbZeroCopyActive ? str(" \u00b7 OpenGL, zero-copy") : str(" \u00b7 OpenGL")];
}

static NSString *mediaLine(void)
{
    return fbHardwareVideoActive ? @"GStreamer, UVD H.264 decoding" : @"GStreamer, software decoding";
}

/* ------------------------------------------------------------ the controller ---- */

@interface FBAbout : NSObject {
    NSWindow *window;
    FBAboutScene *sceneView;
    NSView *summary, *details;
    NSTextView *detailsText;
}
+ (FBAbout *)shared;
- (void)show;
@end

void fbShowAbout(void) { [[FBAbout shared] show]; }

@implementation FBAbout

+ (FBAbout *)shared
{
    static FBAbout *about;
    if (!about)
        about = [[FBAbout alloc] init];
    return about;
}

- (FBAboutLink *)link:(NSString *)title at:(NSPoint)p in:(NSView *)parent action:(SEL)action
{
    NSFont *font = [NSFont systemFontOfSize:11];
    NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName,
                           rgbHex(0x1f5fa6), NSForegroundColorAttributeName, nil];
    NSAttributedString *s = [[[NSAttributedString alloc] initWithString:title attributes:attrs] autorelease];
    FBAboutLink *b = [[[FBAboutLink alloc] initWithFrame:NSMakeRect(p.x, p.y, ceil([s size].width) + 2, 16)] autorelease];
    [b setBordered:NO];
    [b setButtonType:NSMomentaryChangeButton];
    [b setAttributedTitle:s];
    [b setTarget:self];
    [b setAction:action];
    [parent addSubview:b];
    return b;
}

- (void)buildSummaryIn:(NSView *)v
{
    NSImage *icon = [NSApp applicationIconImage];
    NSImageView *iv = [[[NSImageView alloc] initWithFrame:NSMakeRect(24, 26, 64, 64)] autorelease];
    [iv setImage:icon];
    [iv setImageScaling:NSScaleProportionally];
    [v addSubview:iv];
    label(v, NSMakeRect(100, 32, 230, 34), @"FrostByte", [NSFont boldSystemFontOfSize:28], rgbHex(0x14304f));
    label(v, NSMakeRect(102, 66, 230, 16), [NSString stringWithFormat:str("Version %s · built %s"), FROSTBYTE_VERSION, __DATE__],
          [NSFont systemFontOfSize:12], rgbHex(0x454b55));
    label(v, NSMakeRect(102, 82, 230, 16), str("\u00a9 2026 Jordan Bettcher"), [NSFont systemFontOfSize:11], rgbHex(0x555b65));

    NSTextField *tag = label(v, NSMakeRect(22, 104, 320, 34),
                             @"A web browser for PowerPC Macs running Mac OS X Leopard, built on WebKit.",
                             [NSFont systemFontOfSize:12], rgbHex(0x2a2e35));
    [[tag cell] setWraps:YES];
    [[tag cell] setLineBreakMode:NSLineBreakByWordWrapping];

    char *engine = g_strdup_printf("WPE WebKit %u.%u.%u", webkit_get_major_version(), webkit_get_minor_version(),
                                   webkit_get_micro_version());
    NSString *rows[][2] = {
        { @"Engine", str(engine) },
        { @"JavaScript", javascriptLine() },
        { @"Media", mediaLine() },
        { @"Graphics", graphicsLine() },
        { @"System", systemVersion() },
    };
    g_free(engine);
    NSFont *small = [NSFont systemFontOfSize:11];
    for (unsigned i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        CGFloat y = 148 + i * 20;
        label(v, NSMakeRect(22, y, 76, 16), rows[i][0], small, rgbHex(0x555b65));
        NSTextField *val = label(v, NSMakeRect(98, y, 250, 16), rows[i][1], small, rgbHex(0x1d1f22));
        [val setToolTip:rows[i][1]];
    }

    FBAboutLink *credits = [self link:@"Credits" at:NSMakePoint(22, 320) in:v action:@selector(showCredits:)];
    [self link:@"Open-Source Licences" at:NSMakePoint(NSMaxX([credits frame]) + 12, 320) in:v action:@selector(showLicences:)];
    label(v, NSMakeRect(22, 340, 330, 28), @"FrostByte uses WebKit, GStreamer and FFmpeg, each under its own open-source licence.",
          [NSFont systemFontOfSize:10], rgbHex(0x555b65));
    [[[[v subviews] lastObject] cell] setWraps:YES];
}

- (void)buildDetailsIn:(NSView *)v
{
    [self link:str("‹ Back") at:NSMakePoint(18, 14) in:v action:@selector(showSummary:)];
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(18, 38, 334, 326)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSNoBorder];
    [scroll setDrawsBackground:NO];
    detailsText = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 318, 326)] autorelease];
    [detailsText setEditable:NO];
    [detailsText setDrawsBackground:NO];
    [detailsText setTextContainerInset:NSMakeSize(0, 4)];
    [scroll setDocumentView:detailsText];
    [v addSubview:scroll];
}

- (void)showText:(const char *const (*)[2])lines count:(unsigned)count
{
    NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] init] autorelease];
    NSDictionary *head = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont boldSystemFontOfSize:11], NSFontAttributeName,
                          rgbHex(0x14304f), NSForegroundColorAttributeName, nil];
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:11], NSFontAttributeName,
                          rgbHex(0x2a2e35), NSForegroundColorAttributeName, nil];
    for (unsigned i = 0; i < count; i++) {
        [text appendAttributedString:[[[NSAttributedString alloc] initWithString:
            [NSString stringWithFormat:@"%s\n", lines[i][0]] attributes:head] autorelease]];
        [text appendAttributedString:[[[NSAttributedString alloc] initWithString:
            [NSString stringWithFormat:@"%s\n\n", lines[i][1]] attributes:body] autorelease]];
    }
    [[detailsText textStorage] setAttributedString:text];
    [detailsText scrollRangeToVisible:NSMakeRange(0, 0)];
    [summary setHidden:YES];
    [details setHidden:NO];
}

- (void)showCredits:(id)sender
{
    (void)sender;
    static const char *const lines[][2] = {
        { "FrostByte", "By Jordan Bettcher: the browser, its port of WebKit and JavaScriptCore to big-endian PowerPC, "
                       "and the Mac OS X kernel and driver work it runs on." },
        { "Engine", "WPE WebKit with JavaScriptCore (LLInt, Baseline, DFG and FTL tiers, WebAssembly IPInt and BBQ), "
                    "ported to 64-bit PowerPC Mac OS X 10.5, big-endian." },
        { "Interface", "After Camino, the Mac browser of the Mozilla project. Toolbar and tab artwork from Camino." },
        { "Media", "GStreamer with FFmpeg and dav1d for software decoding, AltiVec colour conversion, and UVD "
                   "H.264 decoding through the RadeonNI driver where the card has it." },
        { "Icon", "The FrostByte ice cube." },
        { "Libraries", "GLib, libsoup, GnuTLS, HarfBuzz, FreeType, Fontconfig, ICU, Skia, libxml2, SQLite and friends." },
    };
    [self showText:lines count:sizeof lines / sizeof lines[0]];
}

- (void)showLicences:(id)sender
{
    (void)sender;
    static const char *const lines[][2] = {
        { "WebKit", "GNU LGPL 2.1 and BSD licences." },
        { "Camino artwork", "Mozilla Public License 2.0." },
        { "GStreamer, GLib, libsoup", "GNU LGPL 2.1 or later." },
        { "FFmpeg", "GNU LGPL 2.1 or later, as built here." },
        { "dav1d, Skia", "BSD licences." },
        { "GnuTLS", "GNU LGPL 2.1 or later." },
        { "HarfBuzz, Fontconfig, libxml2", "MIT-style licences." },
        { "FreeType", "FreeType License (BSD-style)." },
        { "ICU", "Unicode License." },
        { "SQLite", "Public domain." },
        { "FrostByte", "MIT License, copyright (c) 2026 Jordan Bettcher." },
    };
    [self showText:lines count:sizeof lines / sizeof lines[0]];
}

- (void)showSummary:(id)sender
{
    (void)sender;
    [details setHidden:YES];
    [summary setHidden:NO];
}

- (id)init
{
    if (!(self = [super init]))
        return nil;
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 378)
                                         styleMask:NSTitledWindowMask | NSClosableWindowMask
                                           backing:NSBackingStoreBuffered defer:YES];
    [window setReleasedWhenClosed:NO];
    [window setTitle:@""];
    [window setDelegate:(id)self];
    NSView *content = [window contentView];

    sceneView = [[[FBAboutScene alloc] initWithFrame:NSMakeRect(0, 0, SW, SH)] autorelease];
    [content addSubview:sceneView];

    FBAboutInfo *info = [[[FBAboutInfo alloc] initWithFrame:NSMakeRect(SW, 0, 640 - SW, SH)] autorelease];
    [content addSubview:info];
    summary = [[[FBAboutFlipped alloc] initWithFrame:[info bounds]] autorelease];
    details = [[[FBAboutFlipped alloc] initWithFrame:[info bounds]] autorelease];
    [info addSubview:summary];
    [info addSubview:details];
    [details setHidden:YES];
    /* The panels are flipped, so the layout below reads top-down like the design. */
    [self buildSummaryIn:summary];
    [self buildDetailsIn:details];
    [window center];
    return self;
}

- (void)show
{
    [self showSummary:nil];
    [window makeKeyAndOrderFront:nil];
    [sceneView startAnimating];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)windowWillClose:(NSNotification *)n { (void)n; [sceneView stopAnimating]; }
@end
