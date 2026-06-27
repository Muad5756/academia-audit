// AcademiaAudit.dylib — v2
// Crash fixes: removed manual viewDidLoad call, removed UIWindow category,
//              guarded appendLog against nil logView
// Trigger: UIApplicationDidBecomeActiveNotification (1s delay)
// UI: floating "A" button → tap → full overlay menu, no UIViewController

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <errno.h>
#include <objc/runtime.h>
#include "fishhook.h"

// ─── FORWARD ─────────────────────────────────────────────────────────────────

@class AuditOverlay;
static void audit_log(NSString *tag, NSString *msg);

// ─── OVERLAY — plain NSObject owning UIViews, no UIViewController ─────────────

@interface AuditOverlay : NSObject
@property (nonatomic, strong) UIView    *container;   // full-screen transparent host
@property (nonatomic, strong) UIView    *panel;        // the visible menu card
@property (nonatomic, strong) UIButton  *fab;          // floating trigger button
@property (nonatomic, strong) UITextView *logView;     // log display
@property (nonatomic, strong) UILabel   *statusBypass;
@property (nonatomic, strong) UILabel   *statusDRM;
@property (nonatomic, strong) UILabel   *statusPurchase;
@property (nonatomic, strong) UILabel   *statusWallet;
@property (nonatomic, assign) BOOL       captureEnabled;
@property (nonatomic, assign) CGPoint    fabOrigin;    // drag state
+ (instancetype)shared;
- (void)attachToKeyWindow;
- (void)appendLog:(NSString *)line;
- (void)markActive:(UILabel *)label name:(NSString *)name;
@end

static AuditOverlay *_overlay = nil;

@implementation AuditOverlay

+ (instancetype)shared {
    static dispatch_once_t t;
    dispatch_once(&t, ^{ _overlay = [AuditOverlay new]; });
    return _overlay;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _captureEnabled = YES;
        [self buildViews];
    }
    return self;
}

// Build all views exactly once in init — never rebuilt
- (void)buildViews {
    CGRect screen = UIScreen.mainScreen.bounds;

    // ── transparent full-screen container ──
    _container = [[UIView alloc] initWithFrame:screen];
    _container.backgroundColor = [UIColor clearColor];
    _container.userInteractionEnabled = YES;

    // ── floating action button ──
    CGFloat fabSz = 40;
    _fabOrigin = CGPointMake(screen.size.width - fabSz - 16,
                              screen.size.height * 0.35);
    _fab = [UIButton buttonWithType:UIButtonTypeCustom];
    _fab.frame = CGRectMake(_fabOrigin.x, _fabOrigin.y, fabSz, fabSz);
    _fab.backgroundColor = [UIColor colorWithRed:0 green:0.8 blue:0.9 alpha:0.92];
    _fab.layer.cornerRadius = fabSz / 2;
    _fab.layer.shadowColor  = [UIColor blackColor].CGColor;
    _fab.layer.shadowOffset = CGSizeMake(0, 2);
    _fab.layer.shadowOpacity = 0.4;
    _fab.layer.shadowRadius  = 4;
    [_fab setTitle:@"A" forState:UIControlStateNormal];
    _fab.titleLabel.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightBold];
    [_fab setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [_fab addTarget:self action:@selector(fabTapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(fabDragged:)];
    [_fab addGestureRecognizer:drag];
    [_container addSubview:_fab];

    // ── menu panel ──
    CGFloat pw = MIN(screen.size.width - 32, 340);
    CGFloat ph = 570;
    CGFloat px = (screen.size.width - pw) / 2;
    CGFloat py = (screen.size.height - ph) / 2;

    _panel = [[UIView alloc] initWithFrame:CGRectMake(px, py, pw, ph)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.97];
    _panel.layer.cornerRadius = 16;
    _panel.layer.borderColor  = [UIColor colorWithRed:0 green:0.8 blue:0.9 alpha:1].CGColor;
    _panel.layer.borderWidth  = 1.5;
    _panel.layer.shadowColor  = [UIColor blackColor].CGColor;
    _panel.layer.shadowOpacity = 0.5;
    _panel.layer.shadowRadius  = 12;
    _panel.layer.shadowOffset  = CGSizeMake(0, 4);
    _panel.clipsToBounds = YES;
    _panel.hidden = YES;
    [_container addSubview:_panel];

    [self buildPanelContents:pw];
}

- (void)buildPanelContents:(CGFloat)w {
    CGFloat pad = 14;
    CGFloat y   = 0;

    // ── header bar ──
    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 50)];
    hdr.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];

    UILabel *title = [UILabel new];
    title.text  = @"Academia Audit";
    title.font  = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithRed:0 green:0.8 blue:0.9 alpha:1];
    title.frame = CGRectMake(pad, 7, w - 60, 20);
    [hdr addSubview:title];

    UILabel *sub = [UILabel new];
    sub.text  = @"passive capture · read only";
    sub.font  = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    sub.textColor = [UIColor systemGrayColor];
    sub.frame = CGRectMake(pad, 27, w - 60, 16);
    [hdr addSubview:sub];

    // close button — top right
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 44, 8, 36, 36);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:18];
    [close setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:close];

    [_panel addSubview:hdr];
    y = 56;

    // ── status rows ──
    _statusBypass   = [self addStatusRow:@"Jailbreak bypass"   to:_panel y:&y w:w pad:pad];
    _statusDRM      = [self addStatusRow:@"DRM intercept"      to:_panel y:&y w:w pad:pad];
    _statusPurchase = [self addStatusRow:@"Purchase intercept"  to:_panel y:&y w:w pad:pad];
    _statusWallet   = [self addStatusRow:@"Wallet intercept"   to:_panel y:&y w:w pad:pad];

    // ── capture toggle ──
    y += 4;
    UIView *togRow = [[UIView alloc] initWithFrame:CGRectMake(pad, y, w - pad*2, 34)];
    UILabel *togLbl = [UILabel new];
    togLbl.text = @"Capture active";
    togLbl.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    togLbl.textColor = [UIColor systemGreenColor];
    togLbl.frame = CGRectMake(0, 7, 160, 20);
    [togRow addSubview:togLbl];

    UISwitch *sw = [UISwitch new];
    sw.on = YES;
    sw.onTintColor = [UIColor colorWithRed:0 green:0.8 blue:0.9 alpha:1];
    sw.frame = CGRectMake(togRow.bounds.size.width - 52, 5, 52, 24);
    [sw addTarget:self action:@selector(toggleCapture:) forControlEvents:UIControlEventValueChanged];
    [togRow addSubview:sw];
    [_panel addSubview:togRow];
    y += 42;

    // ── log header ──
    UILabel *logHdr = [UILabel new];
    logHdr.text = @"API LOG";
    logHdr.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightBold];
    logHdr.textColor = [UIColor systemGrayColor];
    logHdr.frame = CGRectMake(pad, y, 60, 14);
    [_panel addSubview:logHdr];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(w - 54, y - 1, 40, 16);
    [clearBtn setTitle:@"Clear" forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    clearBtn.tintColor = [UIColor systemGrayColor];
    [clearBtn addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:clearBtn];
    y += 18;

    // ── log text view ──
    _logView = [UITextView new];
    _logView.frame = CGRectMake(pad, y, w - pad*2, 210);
    _logView.backgroundColor = [UIColor colorWithWhite:0.03 alpha:1];
    _logView.textColor = [UIColor systemGreenColor];
    _logView.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    _logView.editable = NO;
    _logView.text = @"[init] ready\n[tip] navigate app to capture API calls";
    _logView.layer.cornerRadius = 6;
    [_panel addSubview:_logView];
    y += 218;

    // ── export button ──
    [self addPanelButton:@"Export Log"
                   color:[UIColor colorWithRed:0 green:0.8 blue:0.9 alpha:1]
                      to:_panel y:&y w:w pad:pad
                  action:@selector(exportLog)];
}

- (UILabel *)addStatusRow:(NSString *)text to:(UIView *)v y:(CGFloat *)y w:(CGFloat)w pad:(CGFloat)pad {
    UILabel *l = [UILabel new];
    l.frame = CGRectMake(pad, *y, w - pad*2, 22);
    l.font  = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    l.textColor = [UIColor systemYellowColor];
    l.text  = [NSString stringWithFormat:@"○  %@ — pending", text];
    [v addSubview:l];
    *y += 24;
    return l;
}

- (void)addPanelButton:(NSString *)title color:(UIColor *)c to:(UIView *)v
                     y:(CGFloat *)y w:(CGFloat)w pad:(CGFloat)pad action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(pad, *y, w - pad*2, 36);
    [btn setTitle:title forState:UIControlStateNormal];
    btn.tintColor = c;
    btn.layer.borderColor = c.CGColor;
    btn.layer.borderWidth = 1;
    btn.layer.cornerRadius = 8;
    btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [v addSubview:btn];
    *y += 44;
}

// ── attach to running app's key window ───────────────────────────────────────

- (void)attachToKeyWindow {
    UIWindow *kw = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)s;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { kw = w; break; }
            }
        }
        if (kw) break;
    }
    if (!kw) return;

    _container.frame = kw.bounds;
    [kw addSubview:_container];
    [kw bringSubviewToFront:_container];
}

// ── fab actions ───────────────────────────────────────────────────────────────

- (void)fabTapped {
    BOOL show = _panel.hidden;
    if (show) {
        _panel.hidden = NO;
        _panel.alpha  = 0;
        _panel.transform = CGAffineTransformMakeScale(0.9, 0.9);
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                             self->_panel.alpha = 1;
                             self->_panel.transform = CGAffineTransformIdentity;
                         } completion:nil];
    }
}

- (void)closePanel {
    [UIView animateWithDuration:0.18 animations:^{
        self->_panel.alpha = 0;
        self->_panel.transform = CGAffineTransformMakeScale(0.9, 0.9);
    } completion:^(BOOL f) {
        self->_panel.hidden = YES;
        self->_panel.alpha  = 1;
        self->_panel.transform = CGAffineTransformIdentity;
    }];
}

- (void)fabDragged:(UIPanGestureRecognizer *)gr {
    CGPoint delta = [gr translationInView:_container];
    CGRect f = _fab.frame;
    f.origin.x += delta.x;
    f.origin.y += delta.y;

    // clamp to screen edges
    CGSize s = _container.bounds.size;
    f.origin.x = MAX(8, MIN(f.origin.x, s.width  - f.size.width  - 8));
    f.origin.y = MAX(8, MIN(f.origin.y, s.height - f.size.height - 8));
    _fab.frame = f;
    [gr setTranslation:CGPointZero inView:_container];
}

// ── log ───────────────────────────────────────────────────────────────────────

- (void)appendLog:(NSString *)line {
    if (!_logView) return;   // guard: logView may not exist yet at load time
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_logView) return;
        NSString *cur = self->_logView.text ?: @"";
        self->_logView.text = [cur stringByAppendingFormat:@"\n%@", line];
        NSUInteger len = self->_logView.text.length;
        if (len > 0) [self->_logView scrollRangeToVisible:NSMakeRange(len - 1, 1)];
    });
}

- (void)markActive:(UILabel *)label name:(NSString *)name {
    if (!label) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        label.text = [NSString stringWithFormat:@"●  %@ — active", name];
        label.textColor = [UIColor systemGreenColor];
    });
}

- (void)toggleCapture:(UISwitch *)sw {
    _captureEnabled = sw.on;
    audit_log(@"CTRL", sw.on ? @"capture ON" : @"capture OFF");
}

- (void)clearLog {
    if (_logView) _logView.text = @"[cleared]";
}

- (void)exportLog {
    if (!_logView) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"academia_audit.txt"];
    NSError *err;
    [_logView.text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) { audit_log(@"EXPORT", err.localizedDescription); return; }

    // find a presented VC to show share sheet from
    UIViewController *root = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]])
            root = ((UIWindowScene *)s).windows.firstObject.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if (!root) return;

    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    share.popoverPresentationController.sourceView = _fab;
    [root presentViewController:share animated:YES completion:nil];
}

@end

// ─── LOG HELPER ──────────────────────────────────────────────────────────────

static void audit_log(NSString *tag, NSString *msg) {
    NSString *ts   = [NSDateFormatter localizedStringFromDate:[NSDate date]
                      dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@", ts, tag, msg];
    NSLog(@"[AcademiaAudit] %@", line);
    [[AuditOverlay shared] appendLog:line];
}

// ─── JAILBREAK BYPASS ────────────────────────────────────────────────────────

static const char *_jb[] = {
    "/Applications/Cydia.app",
    "/Applications/Sileo.app",
    "/Applications/Zebra.app",
    "/Library/MobileSubstrate/MobileSubstrate.dylib",
    "/Library/MobileSubstrate/DynamicLibraries",
    "/bin/bash",
    "/bin/sh",
    "/usr/sbin/sshd",
    "/usr/bin/ssh",
    "/etc/apt",
    "/private/var/lib/apt",
    "/var/lib/dpkg",
    "/var/lib/cydia",
    "/var/cache/apt",
    "/tmp/cydia.log",
    NULL
};

static bool is_jb(const char *p) {
    if (!p) return false;
    for (int i = 0; _jb[i]; i++)
        if (strncmp(p, _jb[i], strlen(_jb[i])) == 0) return true;
    return false;
}

static int (*orig_stat)(const char *, struct stat *);
static int hook_stat(const char *p, struct stat *b) {
    if (is_jb(p)) { errno = ENOENT; return -1; }
    return orig_stat(p, b);
}

static int (*orig_lstat)(const char *, struct stat *);
static int hook_lstat(const char *p, struct stat *b) {
    if (is_jb(p)) { errno = ENOENT; return -1; }
    return orig_lstat(p, b);
}

static int (*orig_access)(const char *, int);
static int hook_access(const char *p, int m) {
    if (is_jb(p)) { errno = ENOENT; return -1; }
    return orig_access(p, m);
}

static FILE *(*orig_fopen)(const char *, const char *);
static FILE *hook_fopen(const char *p, const char *m) {
    if (is_jb(p)) { errno = ENOENT; return NULL; }
    return orig_fopen(p, m);
}

typedef int (*ptrace_fn)(int, pid_t, caddr_t, int);
static ptrace_fn orig_ptrace;
static int hook_ptrace(int req, pid_t pid, caddr_t addr, int data) {
    if (req == 31) return 0;
    return orig_ptrace(req, pid, addr, data);
}

static OSStatus (*orig_SecTrustEvaluate)(SecTrustRef, SecTrustResultType *);
static OSStatus hook_SecTrustEvaluate(SecTrustRef t, SecTrustResultType *r) {
    if (r) *r = kSecTrustResultProceed;
    return errSecSuccess;
}

static bool (*orig_SecTrustEvaluateWithError)(SecTrustRef, CFErrorRef *);
static bool hook_SecTrustEvaluateWithError(SecTrustRef t, CFErrorRef *e) {
    if (e) *e = NULL;
    return true;
}

// NSFileManager swizzles
static BOOL (*orig_fileExists)(id, SEL, NSString *);
static BOOL hook_fileExists(id self, SEL _cmd, NSString *path) {
    if (path && is_jb(path.UTF8String)) return NO;
    return orig_fileExists(self, _cmd, path);
}

static BOOL (*orig_fileExistsDir)(id, SEL, NSString *, BOOL *);
static BOOL hook_fileExistsDir(id self, SEL _cmd, NSString *path, BOOL *isDir) {
    if (path && is_jb(path.UTF8String)) return NO;
    return orig_fileExistsDir(self, _cmd, path, isDir);
}

static BOOL (*orig_canOpenURL)(id, SEL, NSURL *);
static BOOL hook_canOpenURL(id self, SEL _cmd, NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"cydia"]  ||
        [scheme isEqualToString:@"sileo"]  ||
        [scheme isEqualToString:@"zbra"]   ||
        [scheme isEqualToString:@"installer5"]) return NO;
    return orig_canOpenURL(self, _cmd, url);
}

// ─── API INTERCEPT ───────────────────────────────────────────────────────────

static BOOL is_target(NSString *url) {
    static NSArray *kw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kw = @[@"purchase",@"enroll",@"checkout",@"payment",@"order",@"buy",
                @"wallet",@"balance",@"credit",@"charge",@"topup",
                @"drm",@"license",@"stream",@"manifest",@"hls"];
    });
    NSString *l = url.lowercaseString;
    for (NSString *k in kw) if ([l containsString:k]) return YES;
    return NO;
}

static NSString *url_tag(NSString *url) {
    NSString *l = url.lowercaseString;
    if ([l containsString:@"purchase"]||[l containsString:@"enroll"]||
        [l containsString:@"checkout"]||[l containsString:@"order"]||
        [l containsString:@"buy"])    return @"PURCHASE";
    if ([l containsString:@"wallet"] ||[l containsString:@"balance"]||
        [l containsString:@"credit"] ||[l containsString:@"topup"]) return @"WALLET";
    return @"DRM";
}

static id (*orig_dataTask)(id, SEL, NSURLRequest *, void(^)(NSData*,NSURLResponse*,NSError*));
static id hook_dataTask(id self, SEL _cmd, NSURLRequest *req,
                         void(^handler)(NSData*,NSURLResponse*,NSError*)) {
    NSString *urlStr = req.URL.absoluteString ?: @"";
    if ([AuditOverlay shared].captureEnabled && is_target(urlStr)) {
        NSString *tag = url_tag(urlStr);
        audit_log(tag, [NSString stringWithFormat:@"→ %@ %@", req.HTTPMethod?:@"GET", urlStr]);

        [req.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *s){
            NSString *kl = k.lowercaseString;
            if ([kl containsString:@"auth"]||[kl containsString:@"token"]||[kl containsString:@"key"])
                audit_log(tag, [NSString stringWithFormat:@"  hdr %@: %@", k, v]);
        }];

        if (req.HTTPBody.length > 0) {
            NSString *b = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding];
            if (b) audit_log(tag, [NSString stringWithFormat:@"  body: %@", b]);
        }

        void(^wrapped)(NSData*,NSURLResponse*,NSError*) = ^(NSData *data, NSURLResponse *resp, NSError *err){
            NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
            audit_log(tag, [NSString stringWithFormat:@"← %ld", (long)h.statusCode]);
            if (data.length > 0 && data.length < 8192) {
                id json = [NSJSONSerialization JSONObjectWithData:data
                            options:NSJSONReadingMutableContainers error:nil];
                if (json) {
                    NSData *pretty = [NSJSONSerialization dataWithJSONObject:json
                                      options:NSJSONWritingPrettyPrinted error:nil];
                    NSString *s = [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
                    if (s.length > 800) s = [[s substringToIndex:800] stringByAppendingString:@"…"];
                    audit_log(tag, [NSString stringWithFormat:@"  res: %@", s]);
                }
            }
            if (handler) handler(data, resp, err);
        };
        return orig_dataTask(self, _cmd, req, wrapped);
    }
    return orig_dataTask(self, _cmd, req, handler);
}

// ─── CONSTRUCTOR ─────────────────────────────────────────────────────────────

__attribute__((constructor))
static void academia_audit_init(void) {

    // ── C function hooks via fishhook ──
    struct rebinding c_hooks[] = {
        {"stat",    (void*)hook_stat,    (void**)&orig_stat},
        {"lstat",   (void*)hook_lstat,   (void**)&orig_lstat},
        {"access",  (void*)hook_access,  (void**)&orig_access},
        {"fopen",   (void*)hook_fopen,   (void**)&orig_fopen},
    };
    rebind_symbols(c_hooks, 4);

    orig_ptrace = (ptrace_fn)dlsym(RTLD_DEFAULT, "ptrace");
    if (orig_ptrace) {
        struct rebinding pt[] = {{"ptrace",(void*)hook_ptrace,(void**)&orig_ptrace}};
        rebind_symbols(pt, 1);
    }

    struct rebinding ssl[] = {
        {"SecTrustEvaluate",          (void*)hook_SecTrustEvaluate,
         (void**)&orig_SecTrustEvaluate},
        {"SecTrustEvaluateWithError", (void*)hook_SecTrustEvaluateWithError,
         (void**)&orig_SecTrustEvaluateWithError},
    };
    rebind_symbols(ssl, 2);

    // ── ObjC swizzles ──
    Method m;
    Class fmCls = [NSFileManager class];

    m = class_getInstanceMethod(fmCls, @selector(fileExistsAtPath:));
    if (m) { orig_fileExists = (BOOL(*)(id,SEL,NSString*))method_getImplementation(m);
             method_setImplementation(m, (IMP)hook_fileExists); }

    m = class_getInstanceMethod(fmCls, @selector(fileExistsAtPath:isDirectory:));
    if (m) { orig_fileExistsDir = (BOOL(*)(id,SEL,NSString*,BOOL*))method_getImplementation(m);
             method_setImplementation(m, (IMP)hook_fileExistsDir); }

    m = class_getInstanceMethod([UIApplication class], @selector(canOpenURL:));
    if (m) { orig_canOpenURL = (BOOL(*)(id,SEL,NSURL*))method_getImplementation(m);
             method_setImplementation(m, (IMP)hook_canOpenURL); }

    // ── NSURLSession hook ──
    m = class_getInstanceMethod([NSURLSession class],
        @selector(dataTaskWithRequest:completionHandler:));
    if (m) {
        orig_dataTask = (id(*)(id,SEL,NSURLRequest*,void(^)(NSData*,NSURLResponse*,NSError*)))
            method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_dataTask);
    }

    // ── register for first-foreground notification ──
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *n) {
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                // 1s delay — lets host app finish loading its root VC
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        AuditOverlay *ov = [AuditOverlay shared];
                        [ov attachToKeyWindow];
                        [ov markActive:ov.statusBypass   name:@"Jailbreak bypass"];
                        [ov markActive:ov.statusDRM      name:@"DRM intercept"];
                        [ov markActive:ov.statusPurchase name:@"Purchase intercept"];
                        [ov markActive:ov.statusWallet   name:@"Wallet intercept"];
                        audit_log(@"INIT", @"overlay attached — tap A to open menu");
                    });
            });
        }];

    NSLog(@"[AcademiaAudit] v2 loaded — waiting for UIApplicationDidBecomeActive");
}
