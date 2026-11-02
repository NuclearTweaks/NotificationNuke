// NotificationNuke — per-app notification sound cooldowns + regex text filters.
//
// iOS 27 delivers every notification through usernotificationsd, where both
// entry points hand us the request AND its bundle id together:
//
//   push:  -[UNCRemoteNotificationServer _queue_deliverNotificationRequest:
//                                      bundleIdentifier:message:enforcePushType:]
//   local: -[UNUserNotificationServiceConnection addNotificationRequest:
//                                      forBundleIdentifier:withCompletionHandler:]
//
// We run one filter pass at those choke points:
//
//   1. regex filters (per app): title+subtitle+body matches any pattern →
//      the notification is DROPPED entirely (no banner, no lock screen, no
//      badge) — the "daily reminder" kill switch.
//   2. sound cooldown (per app, default 2 min): if the app has made a sound
//      within its window, the request is replaced by an identical copy with
//      sound stripped. It still appears on the lock screen and in
//      Notification Center exactly as before — it just can't ding. When the
//      window expires, the next notification sounds and restarts the timer.
//
// Everything lives inside usernotificationsd (single process sees every
// app), so state is trivial and ordering is guaranteed. Requests are
// immutable, so muting means rebuilding: same identifier, same trigger,
// copied visible content with sound = nil.
//
// Settings pane writes the config to our preference domain and posts a
// Darwin notification; this daemon reloads on the spot — changes apply to
// the next notification, no respring.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <dlfcn.h>

typedef void (*NN_MSHook)(Class, SEL, IMP, IMP *);

static NSString *const kDomain   = @"com.nucleartweaks.notification-nuke";
static NSString *const kChanged  = @"com.nucleartweaks.notification-nuke/changed";

static os_log_t gLog;
static int gBudget = 60;

// config (guarded by @synchronized(gConfig))
static BOOL     gEnabled = YES;
static NSTimeInterval gDefaultCooldown = 120;          // 2 minutes
static NSDictionary *gPerApp;                        // bid -> {cooldown: NSNumber, filters: [str]} (set by NNReload)

// runtime sound timestamps: bid -> @(unixtime)
static NSMutableDictionary *gLastSound;
static NSString *gStatePath;

// compiled regex cache: bid -> [NSRegularExpression]
static NSMutableDictionary *gRegexCache;

// resolved at ctor
static id gServiceConnClass, gRemoteServerClass;

// ─── proof/log ──────────────────────────────────────────────────────────────

static void NNLog(NSString *fmt, ...) {
    if (gBudget <= 0) return;
    gBudget--;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    os_log(gLog, "%{public}@", s);
    NSLog(@"[NotificationNuke] %@", s);
    FILE *pf = fopen("/Users/spencer/notificationnuke-proof.txt", "a");  // JB-sim host FS; absent on device
    if (pf) { fprintf(pf, "%s\n", s.UTF8String); fclose(pf); }
}

// ─── config ─────────────────────────────────────────────────────────────────

static void NNReload(void) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesAppSynchronize(dom);
    CFTypeRef v;
    BOOL enabled = YES;
    v = CFPreferencesCopyValue(CFSTR("enabled"), dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (v) { if (CFGetTypeID(v) == CFBooleanGetTypeID()) enabled = CFBooleanGetValue((CFBooleanRef)v); CFRelease(v); }
    NSTimeInterval dc = 120;
    v = CFPreferencesCopyValue(CFSTR("defaultCooldown"), dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (v) { if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &dc); CFRelease(v); }
    NSDictionary *per = nil;
    v = CFPreferencesCopyValue(CFSTR("perApp"), dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (v) { if (CFGetTypeID(v) == CFDictionaryGetTypeID()) per = CFBridgingRelease(v); else CFRelease(v); }
    @synchronized (gRegexCache) {
        gEnabled = enabled;
        gDefaultCooldown = dc < 0 ? 0 : dc;
        gPerApp = per ?: @{};
        [gRegexCache removeAllObjects];   // filters may have changed
    }
}

static void NNChanged(CFNotificationCenterRef c, void *obs, CFNotificationName n, const void *p, CFDictionaryRef u) {
    NNReload();
}

// ─── cooldown state (persisted best-effort: the daemon sandbox may refuse) ──

static void NNStateLoad(void) {
    gStatePath = [NSHomeDirectory() stringByAppendingPathComponent:
                  @"Library/Caches/com.nucleartweaks.notification-nuke.state.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:gStatePath];
    gLastSound = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}
static void NNStateSave(void) {
    @try { [gLastSound writeToFile:gStatePath atomically:YES]; } @catch (__unused id e) {}
}

// ─── per-app resolution ─────────────────────────────────────────────────────

static id NNAppCfg(NSString *bid, NSString *key) {
    NSDictionary *d = gPerApp[bid];
    return [d isKindOfClass:NSDictionary.class] ? d[key] : nil;
}

static NSArray<NSRegularExpression *> *NNRegexes(NSString *bid) {
    NSArray *cached = gRegexCache[bid];
    if (cached) return cached.count ? cached : nil;
    NSMutableArray *out = [NSMutableArray array];
    NSArray *pats = NNAppCfg(bid, @"filters");
    if ([pats isKindOfClass:NSArray.class]) {
        for (NSString *p in pats) {
            if (![p isKindOfClass:NSString.class] || p.length == 0) continue;
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p
                                    options:NSRegularExpressionCaseInsensitive error:nil];
            if (re) [out addObject:re];
        }
    }
    gRegexCache[bid] = out ?: @[];
    return out.count ? out : nil;
}

// ─── the filter pass ────────────────────────────────────────────────────────
// Returns the (possibly muted) request to deliver, or nil to drop it.

static id NNProcess(id request, NSString *bid) {
    @try {
        if (!gEnabled || !request || bid.length == 0) return request;
        id content = [request valueForKey:@"content"];
        if (!content) return request;
        NSString *title    = [content valueForKey:@"title"]    ?: @"";
        NSString *subtitle = [content valueForKey:@"subtitle"] ?: @"";
        NSString *body     = [content valueForKey:@"body"]     ?: @"";
        NSString *text = [NSString stringWithFormat:@"%@\n%@\n%@", title, subtitle, body];

        @synchronized (gRegexCache) {
            for (NSRegularExpression *re in NNRegexes(bid))
                if ([re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) {
                    NNLog(@"BLOCKED %@ (regex match on: %.60@)", bid, title);
                    return nil;
                }
        }

        id sound = [content valueForKey:@"sound"];
        if (!sound) return request;                       // nothing to cool down

        id cdv = NNAppCfg(bid, @"cooldown");
        NSTimeInterval cd = [cdv isKindOfClass:NSNumber.class] ? [cdv doubleValue] : gDefaultCooldown;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        NSNumber *last = gLastSound[bid];
        if (cd > 0 && last && now - last.doubleValue < cd) {
            // rebuild the request muted — everything else identical.
            // Class-agnostic: works with the real UNNotificationRequest AND any
            // private subclass the pipeline hands us; on the JB sim the public
            // classes are hollow stubs, which is why every step degrades safely.
            id mc = nil;
            @try { mc = [content mutableCopy]; } @catch (id e) { mc = nil; }
            if (!mc) {
                Class MutableContent = NSClassFromString(@"UNMutableNotificationContent");
                if (!MutableContent) return request;
                @try {
                    mc = [[MutableContent alloc] init];
                    for (NSString *k in @[@"title", @"subtitle", @"body", @"badge", @"userInfo",
                                          @"categoryIdentifier", @"threadIdentifier", @"interruptionLevel",
                                          @"relevanceScore", @"targetContentIdentifier", @"summaryArgument",
                                          @"summaryArgumentCount", @"launchImageName", @"peopleIdentifiers",
                                          @"sticky", @"stickyThreadIdentifier"]) {
                        id v = [content valueForKey:k]; if (v) [mc setValue:v forKey:k];
                    }
                } @catch (id e) { return request; }       // stub framework — deliver as-is
            }
            @try { [mc setValue:nil forKey:@"sound"]; } @catch (id e) { return request; }
            id ident  = [request valueForKey:@"identifier"];
            id trigger = [request valueForKey:@"trigger"];
            SEL iinit = NSSelectorFromString(@"initWithIdentifier:content:trigger:");
            Class ReqCls = [[request class] class];
            if (![ReqCls instancesRespondToSelector:iinit]) ReqCls = NSClassFromString(@"UNNotificationRequest");
            if (!ReqCls || ![ReqCls instancesRespondToSelector:iinit]) {
                NNLog(@"cannot rebuild muted request for %@ (class %@)", bid, NSStringFromClass([request class]));
                return request;
            }
            id muted = ((id (*)(id, SEL, id, id, id))objc_msgSend)([ReqCls alloc], iinit, ident, mc, trigger);
            NNLog(@"MUTED %@ (sound silent, %.0fs cooldown left: %.60@)",
                  bid, cd - (now - last.doubleValue), title);
            return muted ?: request;
        }
        gLastSound[bid] = @(now);                          // this one makes noise; timer starts
        NNStateSave();
        return request;
    } @catch (id e) {
        NNLog(@"filter pass error for %@: %@", bid, e);
        return request;                                    // never eat notifications on our own bug
    }
}

// ─── hook installations (plain dlsym-style; no logos for these signatures) ──

static NN_MSHook gHook;

// -[UNUserNotificationServiceConnection addNotificationRequest:forBundleIdentifier:withCompletionHandler:]
typedef void (*NN_AddReq)(id, SEL, id, NSString *, void (^)(id));
static NN_AddReq orig_addReq;
static void rep_addReq(id self, SEL s, id request, NSString *bid, void (^completion)(id)) {
    @try {   // visibility probe: every request reaching the server (dev sim only)
        static int devOnly = -1;
        if (devOnly < 0) devOnly = [[NSFileManager defaultManager] fileExistsAtPath:@"/Users/spencer"];
        if (devOnly && gBudget > 0 && [request valueForKey:@"content"]) {
            id c = [request valueForKey:@"content"];
            NNLog(@"REQ %@ t=%.50@ sound=%d", bid,
                  [c valueForKey:@"title"] ?: @"?", ([c valueForKey:@"sound"] != nil));
        }
    } @catch (id e) {}
    id r = NNProcess(request, bid);
    if (!r) { if (completion) completion(nil); return; }   // dropped: report success, save nothing
    orig_addReq(self, s, r, bid, completion);
}

// -[UNCRemoteNotificationServer _queue_deliverNotificationRequest:bundleIdentifier:message:enforcePushType:]
// enforcePushType scalar width unknown across builds — resolve from the method
// signature at install time and dispatch to the right trampoline.
typedef void (*NN_Deliv_B)(id, SEL, id, NSString *, id, bool);
typedef void (*NN_Deliv_Q)(id, SEL, id, NSString *, id, long long);
static NN_Deliv_B orig_delivB; static NN_Deliv_Q orig_delivQ;
static BOOL gDelivIsBool;
static void rep_delivB(id self, SEL s, id request, NSString *bid, id msg, bool t) {
    id r = NNProcess(request, bid);
    if (!r) return;
    orig_delivB(self, s, r, bid, msg, t);
}
static void rep_delivQ(id self, SEL s, id request, NSString *bid, id msg, long long t) {
    id r = NNProcess(request, bid);
    if (!r) return;
    orig_delivQ(self, s, r, bid, msg, t);
}

static NN_MSHook NNFindSubstrate(void) {
    NN_MSHook h = (NN_MSHook)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (h) return h;
    static const char *homes[] = {
        "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",        // rootful (JB sim)
        "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/var/jb/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libsubstitute.dylib",
        "/var/jb/usr/lib/TweakLoader.dylib",
        "/usr/lib/libsubstitute.dylib",
    };
    for (size_t i = 0; i < sizeof(homes)/sizeof(homes[0]) && !h; i++) {
        void *img = dlopen(homes[i], RTLD_LAZY);
        if (img) h = (NN_MSHook)dlsym(img, "MSHookMessageEx");
    }
    return h;
}

static void NNHookInstance(Class c, SEL sel, IMP rep, IMP *orig) {
    if (gHook && c && class_getInstanceMethod(c, sel)) gHook(c, sel, rep, orig);
}

// ─── dev-only self-test (JB sim: /Users/spencer exists on the host-shared FS,
//     never on a device). On the sim the public UN* classes are hollow stub
//     frameworks (methods missing), so we exercise the DECISION layer against
//     KVC-compatible mock request/content objects — the exact same code path
//     NNProcess runs in production: sound-pass, cooldown-mute (request
//     rebuilt via the request's own class), regex-drop. ──────────────────────

@interface NNMockContent : NSObject
@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) NSString *subtitle;
@property (nonatomic, strong) NSString *body;
@property (nonatomic, strong) id sound;
@end
@implementation NNMockContent
- (id)mutableCopy {
    NNMockContent *m = [NNMockContent new];
    m.title = self.title; m.subtitle = self.subtitle; m.body = self.body; m.sound = self.sound;
    return m;
}
@end

@interface NNMockRequest : NSObject
@property (nonatomic, strong) NSString *identifier;
@property (nonatomic, strong) id content;
@property (nonatomic, strong) id trigger;
- (id)initWithIdentifier:(id)i content:(id)c trigger:(id)t;
@end
@implementation NNMockRequest
- (id)initWithIdentifier:(id)i content:(id)c trigger:(id)t {
    if ((self = [super init])) { self.identifier = i; self.content = c; self.trigger = t; }
    return self;
}
@end

static void NNSelfTest(void) {
    NSString *bid = @"com.nucleartweaks.selftest";
    [gLastSound removeObjectForKey:bid];              // clean slate for pass-1

    id (^mk)(NSString *, NSString *) = ^id(NSString *title, NSString *body) {
        NNMockContent *c = [NNMockContent new];
        c.title = title; c.body = body; c.sound = @"default";
        return [[NNMockRequest alloc] initWithIdentifier:
                    [NSString stringWithFormat:@"st-%f", [NSDate date].timeIntervalSince1970]
                content:c trigger:@"dummy"];
    };

    BOOL ok1 = NO, ok2 = NO, ok3 = NO, ok4 = NO;
    id r1 = mk(@"st 1", @"plain body");
    id o1 = NNProcess(r1, bid);                       // first: should pass through, timestamp set
    ok1 = (o1 == r1);

    id r2 = mk(@"st 2", @"plain body again");
    id o2 = NNProcess(r2, bid);                       // within window: muted copy
    id bc = [o2 valueForKey:@"content"];
    ok2 = (o2 != r2) && ([bc valueForKey:@"sound"] == nil)
          && [[bc valueForKey:@"body"] isEqual:@"plain body again"];

    // inject an in-memory filter for the selftest app, then recompile cache
    @synchronized (gRegexCache) {
        NSMutableDictionary *per = [gPerApp mutableCopy] ?: [NSMutableDictionary dictionary];
        per[bid] = @{ @"filters": @[@"daily reminder"] };
        gPerApp = per;
        [gRegexCache removeAllObjects];
    }
    id r3 = mk(@"st 3", @"Get up! This is your daily reminder");
    ok3 = (NNProcess(r3, bid) == nil);                // regex: dropped

    id r4 = mk(@"st 4", @"not a reminder at all");
    id o4 = NNProcess(r4, bid);
    ok4 = (o4 != nil && o4 != r4);                    // passes filter, muted by cooldown

    NNLog(@"SELFTEST pass1=%d mute2=%d drop3=%d mute4=%d → %@", ok1, ok2, ok3, ok4,
          (ok1 && ok2 && ok3 && ok4) ? @"ALL PASS" : @"FAILURE");

    // restore stock config from disk
    @synchronized (gRegexCache) { [gRegexCache removeAllObjects]; }
    NNReload();
}

%ctor {
    @autoreleasepool {
        gLog = os_log_create("com.nucleartweaks", "NotificationNuke");
        Class server = NSClassFromString(@"UNCRemoteNotificationServer");
        Class conn   = NSClassFromString(@"UNUserNotificationServiceConnection");
        if (!server && !conn) return;              // not usernotificationsd

        gRegexCache = [NSMutableDictionary dictionary];
        NNStateLoad();
        NNReload();
        gHook = NNFindSubstrate();
        if (!gHook) { NSLog(@"[NotificationNuke] no substrate symbol — idle"); return; }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, NNChanged, (__bridge CFStringRef)kChanged, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        NNHookInstance(conn, NSSelectorFromString(@"addNotificationRequest:forBundleIdentifier:withCompletionHandler:"),
                       (IMP)rep_addReq, (IMP *)&orig_addReq);

        SEL delivSel = NSSelectorFromString(@"_queue_deliverNotificationRequest:bundleIdentifier:message:enforcePushType:");
        Method dm = server ? class_getInstanceMethod(server, delivSel) : NULL;
        if (dm && gHook) {
            NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(dm)];
            char c = (sig && sig.numberOfArguments > 5) ? sig.methodReturnType[0] : '?';
            if (sig && sig.numberOfArguments > 5) c = [[NSString stringWithUTF8String:[sig getArgumentTypeAtIndex:5]] UTF8String][0];
            gDelivIsBool = (c == 'B' || c == 'c');      // BOOL encodes as B (or c on old runtimes)
            if (gDelivIsBool)
                gHook(server, delivSel, (IMP)rep_delivB, (IMP *)&orig_delivB);
            else
                gHook(server, delivSel, (IMP)rep_delivQ, (IMP *)&orig_delivQ);
        }
        NNLog(@"installed (enabled=%d default=%.0fs perApp=%lu pushHook=%d connHook=%d)",
              gEnabled, gDefaultCooldown, (unsigned long)gPerApp.count,
              (dm && orig_delivB) || (dm && orig_delivQ), orig_addReq != NULL);
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/Users/spencer"]) {
            @try { NNSelfTest(); } @catch (id e) { NNLog(@"SELFTEST exception: %@", e); }
        }
    }
}
