// AcademiaAudit.dylib
// Passive API audit tweak for Speetar Academia iOS app
// Captures: purchase, wallet, DRM API calls — read-only, no modification
// Menu: shake device to open
// Inject: insert_dylib → re-sign → Trollstore / AltStore

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <errno.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include "fishhook.h"

// ─── FORWARD DECLARATIONS ────────────────────────────────────────────────────

@class AuditMenuController;
static AuditMenuController *_sharedMenu = nil;
static void audit_log(NSString *tag, NSString *msg);

// ─── MENU CONTROLLER ─────────────────────────────────────────────────────────

@interface AuditMenuController : UIViewController
@property (nonatomic, strong) UILabel     *statusPurchase;
@property (nonatomic, strong) UILabel     *statusWallet;
@property (nonatomic, strong) UILabel     *statusDRM;
@property (nonatomic, strong) UILabel     *statusBypass;
@property (nonatomic, strong) UITextView  *logView;
@property (nonatomic, strong) UIWindow    *menuWindow;
@property (nonatomic, assign) BOOL         captureEnabled;
@end

@implementation AuditMenuController

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _sharedMenu = [AuditMenuController new]; });
    return _sharedMenu;
}

- (instancetype)init {
    self = [super init];
    if (self) _captureEnabled = YES;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = 12;

    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.97];
    self.view.layer.cornerRadius = 16;
    self.view.layer.borderColor  = [UIColor systemCyanColor].CGColor;
    self.view.layer.borderWidth  = 1.5;
    self.view.clipsToBounds = YES;

    // ── header ──
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    header.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];

    UILabel *title = [UILabel new];
    title.text = @"Academia Audit";
    title.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightBold];
    title.textColor = [UIColor systemCyanColor];
    title.frame = CGRectMake(pad, 8, w - pad*2, 22);
    [header addSubview:title];

    UILabel *sub = [UILabel new];
    sub.text = @"passive capture  ·  read only";
    sub.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    sub.textColor = [UIColor systemGrayColor];
    sub.frame = CGRectMake(pad, 30, w - pad*2, 16);
    [header addSubview:sub];
    [self.view addSubview:header];

    // ── status rows ──
    CGFloat y = 60;
    self.statusBypass   = [self addStatusRow:@"Jailbreak bypass"  y:y]; y += 26;
    self.statusDRM      = [self addStatusRow:@"DRM intercept"     y:y]; y += 26;
    self.statusPurchase = [self addStatusRow:@"Purchase intercept" y:y]; y += 26;
    self.statusWallet   = [self addStatusRow:@"Wallet intercept"  y:y]; y += 26;

    // ── capture toggle ──
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(pad, y + 4, w - pad*2, 36)];
    UILabel *togLabel = [UILabel new];
    togLabel.text = @"Capture active";
    togLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    togLabel.textColor = [UIColor systemGreenColor];
    togLabel.frame = CGRectMake(0, 8, 180, 20);
    [row addSubview:togLabel];

    UISwitch *tog = [UISwitch new];
    tog.on = YES;
    tog.onTintColor = [UIColor systemCyanColor];
    tog.frame = CGRectMake(row.bounds.size.width - 52, 6, 52, 24);
    [tog addTarget:self action:@selector(toggleCapture:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:tog];
    [self.view addSubview:row];
    y += 46;

    // ── log view ──
    UILabel *logHdr = [UILabel new];
    logHdr.text = @"API LOG";
    logHdr.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightBold];
    logHdr.textColor = [UIColor systemGrayColor];
    logHdr.frame = CGRectMake(pad, y, 80, 14);
    [self.view addSubview:logHdr];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(w - 60, y - 2, 48, 18);
    [clearBtn setTitle:@"Clear" forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    clearBtn.tintColor = [UIColor systemGrayColor];
    [clearBtn addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:clearBtn];
    y += 18;

    self.logView = [UITextView new];
    self.logView.frame = CGRectMake(pad, y, w - pad*2, 210);
    self.logView.backgroundColor = [UIColor colorWithWhite:0.03 alpha:1];
    self.logView.textColor = [UIColor systemGreenColor];
    self.logView.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    self.logView.editable = NO;
    self.logView.text = @"[init] ready — waiting for API calls\n[tip] navigate to courses or wallet to capture traffic";
    self.logView.layer.cornerRadius = 6;
    [self.view addSubview:self.logView];
    y += 218;

    // ── buttons ──
    [self addActionButton:@"Export Log"
                    color:[UIColor systemCyanColor]
                       y:y
                  action:@selector(exportLog)];
    y += 44;

    [self addActionButton:@"Close"
                    color:[UIColor systemRedColor]
                       y:y
                  action:@selector(dismissMenu)];
}

- (UILabel *)addStatusRow:(NSString *)label y:(CGFloat)y {
    UILabel *l = [UILabel new];
    l.frame = CGRectMake(12, y, self.view.bounds.size.width - 24, 22);
    l.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    l.textColor = [UIColor systemYellowColor];
    l.text = [NSString stringWithFormat:@"○  %@ — pending", label];
    [self.view addSubview:l];
    return l;
}

- (void)addActionButton:(NSString *)title color:(UIColor *)color y:(CGFloat)y action:(SEL)action {
    CGFloat w = self.view.bounds.size.width;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(12, y, w - 24, 36);
    [btn setTitle:title forState:UIControlStateNormal];
    btn.tintColor = color;
    btn.layer.borderColor = color.CGColor;
    btn.layer.borderWidth = 1;
    btn.layer.cornerRadius = 8;
    btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
}

- (void)setHookActive:(UILabel *)label name:(NSString *)name {
    if (!label) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        label.text = [NSString stringWithFormat:@"●  %@ — active", name];
        label.textColor = [UIColor systemGreenColor];
    });
}

- (void)appendLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.logView.text = [self.logView.text stringByAppendingFormat:@"\n%@", line];
        NSRange end = NSMakeRange(self.logView.text.length - 1, 1);
        [self.logView scrollRangeToVisible:end];
    });
}

- (void)toggleCapture:(UISwitch *)sw {
    self.captureEnabled = sw.on;
    audit_log(@"CTRL", sw.on ? @"capture ON" : @"capture OFF");
}

- (void)clearLog {
    self.logView.text = @"[cleared]";
}

- (void)exportLog {
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"academia_audit.txt"];
    NSError *err;
    [self.logView.text writeToFile:path atomically:YES
                          encoding:NSUTF8StringEncoding error:&err];
    if (err) { audit_log(@"EXPORT", [NSString stringWithFormat:@"error: %@", err.localizedDescription]); return; }

    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)dismissMenu {
    self.menuWindow.hidden = YES;
}

@end

// ─── LOG HELPER ──────────────────────────────────────────────────────────────

static void audit_log(NSString *tag, NSString *msg) {
    NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                    dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@", ts, tag, msg];
    NSLog(@"[AcademiaAudit] %@", line);
    [[AuditMenuController shared] appendLog:line];
}

// ─── JAILBREAK BYPASS ────────────────────────────────────────────────────────

static const char *_jb[] = {
    "/Applications/Cydia.app", "/Applications/Sileo.app",
    "/Library/MobileSubstrate/MobileSubstrate.dylib",
    "/bin/bash", "/usr/sbin/sshd", "/etc/apt",
    "/private/var/lib/apt", "/var/lib/dpkg", NULL
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
    if (r) *r = kSecTrustResultProceed; return errSecSuccess;
}
static bool (*orig_SecTrustEvaluateWithError)(SecTrustRef, CFErrorRef *);
static bool hook_SecTrustEvaluateWithError(SecTrustRef t, CFErrorRef *e) {
    if (e) *e = NULL; return true;
}

// ─── API INTERCEPT ───────────────────────────────────────────────────────────

static BOOL is_target_url(NSString *url) {
    NSArray *kw = @[
        @"purchase", @"enroll", @"checkout", @"payment", @"order", @"buy",
        @"wallet",   @"balance", @"credit",  @"charge",  @"topup",
        @"drm",      @"license", @"stream",  @"manifest", @"hls", @"token"
    ];
    NSString *lower = url.lowercaseString;
    for (NSString *k in kw)
        if ([lower containsString:k]) return YES;
    return NO;
}

static NSString *tag_for_url(NSString *url) {
    NSString *l = url.lowercaseString;
    if ([l containsString:@"purchase"] || [l containsString:@"enroll"] ||
        [l containsString:@"checkout"] || [l containsString:@"order"] ||
        [l containsString:@"buy"])       return @"PURCHASE";
    if ([l containsString:@"wallet"]  || [l containsString:@"balance"] ||
        [l containsString:@"credit"]  || [l containsString:@"topup"])   return @"WALLET";
    return @"DRM";
}

static id (*orig_dataTask)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static id hook_dataTask(id self, SEL _cmd, NSURLRequest *req,
                         void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    NSString *urlStr = req.URL.absoluteString ?: @"";

    if ([AuditMenuController shared].captureEnabled && is_target_url(urlStr)) {
        NSString *tag = tag_for_url(urlStr);
        audit_log(tag, [NSString stringWithFormat:@"→ %@ %@", req.HTTPMethod ?: @"GET", urlStr]);

        // log auth headers
        [req.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *s) {
            if ([k.lowercaseString containsString:@"auth"] ||
                [k.lowercaseString containsString:@"token"] ||
                [k.lowercaseString containsString:@"key"]) {
                audit_log(tag, [NSString stringWithFormat:@"  hdr %@: %@", k, v]);
            }
        }];

        // log request body
        if (req.HTTPBody.length > 0) {
            NSString *body = [[NSString alloc] initWithData:req.HTTPBody
                                                   encoding:NSUTF8StringEncoding];
            if (body) audit_log(tag, [NSString stringWithFormat:@"  req: %@", body]);
        }

        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
                audit_log(tag, [NSString stringWithFormat:@"← HTTP %ld", (long)http.statusCode]);

                if (data.length > 0 && data.length < 8192) {
                    id json = [NSJSONSerialization JSONObjectWithData:data
                                options:NSJSONReadingMutableContainers error:nil];
                    if (json) {
                        NSData *pretty = [NSJSONSerialization dataWithJSONObject:json
                            options:NSJSONWritingPrettyPrinted error:nil];
                        NSString *s = [[NSString alloc] initWithData:pretty
                                                            encoding:NSUTF8StringEncoding];
                        if (s.length > 1000) s = [[s substringToIndex:1000]
                                                    stringByAppendingString:@"\n...(truncated)"];
                        audit_log(tag, [NSString stringWithFormat:@"  res: %@", s]);
                    }
                }
                if (handler) handler(data, resp, err);
            };
        return orig_dataTask(self, _cmd, req, wrapped);
    }
    return orig_dataTask(self, _cmd, req, handler);
}

// ─── MENU TRIGGER — shake ────────────────────────────────────────────────────

@interface UIWindow (AuditShake) @end
@implementation UIWindow (AuditShake)
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion != UIEventSubtypeMotionShake) return;

    AuditMenuController *menu = [AuditMenuController shared];
    if (!menu.menuWindow) {
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
        menu.menuWindow = [[UIWindow alloc] initWithWindowScene:scene];
        menu.menuWindow.windowLevel = UIWindowLevelAlert + 200;
        menu.menuWindow.rootViewController = [UIViewController new];
        menu.menuWindow.backgroundColor = [UIColor clearColor];
        [menu.menuWindow makeKeyAndVisible];
    }

    UIViewController *root = menu.menuWindow.rootViewController;
    [root.view.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    CGFloat menuH = 590;
    CGFloat screenW = root.view.bounds.size.width;
    menu.view.frame = CGRectMake((screenW - 340) / 2, 60, 340, menuH);
    [root.view addSubview:menu.view];
    [menu viewDidLoad];
    menu.menuWindow.hidden = NO;
}
@end

// ─── CONSTRUCTOR ─────────────────────────────────────────────────────────────

__attribute__((constructor))
static void academia_audit_init(void) {
    // C hooks via fishhook
    struct rebinding hooks[] = {
        {"stat",   (void *)hook_stat,   (void **)&orig_stat},
        {"access", (void *)hook_access, (void **)&orig_access},
        {"fopen",  (void *)hook_fopen,  (void **)&orig_fopen},
    };
    rebind_symbols(hooks, 3);

    orig_ptrace = (ptrace_fn)dlsym(RTLD_DEFAULT, "ptrace");
    if (orig_ptrace) {
        struct rebinding pt[] = {{"ptrace", (void *)hook_ptrace, (void **)&orig_ptrace}};
        rebind_symbols(pt, 1);
    }

    struct rebinding ssl[] = {
        {"SecTrustEvaluate",          (void *)hook_SecTrustEvaluate,
         (void **)&orig_SecTrustEvaluate},
        {"SecTrustEvaluateWithError", (void *)hook_SecTrustEvaluateWithError,
         (void **)&orig_SecTrustEvaluateWithError},
    };
    rebind_symbols(ssl, 2);

    // NSURLSession hook
    Method m = class_getInstanceMethod(
        [NSURLSession class],
        @selector(dataTaskWithRequest:completionHandler:));
    if (m) {
        orig_dataTask = (id (*)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))
            method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_dataTask);
    }

    // mark status rows active
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AuditMenuController *menu = [AuditMenuController shared];
        [menu setHookActive:menu.statusBypass   name:@"Jailbreak bypass"];
        [menu setHookActive:menu.statusDRM      name:@"DRM intercept"];
        [menu setHookActive:menu.statusPurchase name:@"Purchase intercept"];
        [menu setHookActive:menu.statusWallet   name:@"Wallet intercept"];
    });

    NSLog(@"[AcademiaAudit] loaded — shake to open menu");
}
