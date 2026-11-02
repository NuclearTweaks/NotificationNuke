// NotificationNukePrefs — Settings pane (PreferenceLoader bundle).
//
// Same runtime-resolved private-Preferences pattern as AnimationNuke/ScreenNuke:
// minimal @interface declarations, everything bound at runtime via
// -undefined dynamic_lookup. Root page is plist-driven; the Apps list and the
// per-app page are built in code (they're data-driven).
//
// Writes go straight to the tweak's preference domain + a Darwin notification;
// usernotificationsd reloads live.

#import <UIKit/UIKit.h>

static NSString *const kDomain  = @"com.nucleartweaks.notification-nuke";
static NSString *const kChanged = @"com.nucleartweaks.notification-nuke/changed";

// ─── minimal runtime-resolved declarations ──────────────────────────────────

@interface PSSpecifier : NSObject
- (NSMutableDictionary *)properties;
- (void)setProperty:(id)prop forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
- (PSSpecifier *)specifier;              // specifier that pushed this page
- (void)reloadSpecifiers;
@end

// ─── prefs helpers ──────────────────────────────────────────────────────────

static id NNGet(NSString *key) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesAppSynchronize(dom);
    CFTypeRef v = CFPreferencesCopyValue((__bridge CFStringRef)key, dom,
                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return v ? CFBridgingRelease(v) : nil;
}
static void NNSet(NSString *key, id value) {
    CFStringRef dom = (__bridge CFStringRef)kDomain;
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          value ? (__bridge CFTypeRef)value : NULL,
                          dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(dom);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kChanged, NULL, NULL, true);
}

static NSDictionary *NNPerApp(void) {
    id v = NNGet(@"perApp");
    return [v isKindOfClass:NSDictionary.class] ? v : @{};
}
static NSDictionary *NNAppDict(NSString *bid) {
    id d = NNPerApp()[bid];
    return [d isKindOfClass:NSDictionary.class] ? d : nil;
}
static void NNAppSet(NSString *bid, NSString *key, id value) {
    NSMutableDictionary *per = [NNPerApp() mutableCopy];
    NSMutableDictionary *d = [per[bid] isKindOfClass:NSDictionary.class]
                           ? [per[bid] mutableCopy] : [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    if (d.count) per[bid] = d; else [per removeObjectForKey:bid];
    NNSet(@"perApp", per);
}

static PSSpecifier *NNSpec(Class cls, NSString *cellClass, NSString *label) {
    PSSpecifier *s = [[cls alloc] init];
    if (cellClass) { [s setProperty:cellClass forKey:@"Cell"]; [s setProperty:cellClass forKey:@"cell"]; }
    if (label)     { [s setProperty:label forKey:@"label"];    [s setProperty:label forKey:@"Title"];
                     [s setProperty:label forKey:@"title"]; }
    return s;
}
static void NNSpecGetSet(PSSpecifier *s, NSString *get, NSString *set) {
    [s setProperty:get forKey:@"get"]; [s setProperty:get forKey:@"Get"];
    [s setProperty:set forKey:@"set"]; [s setProperty:set forKey:@"Set"];
}

// ─── root ───────────────────────────────────────────────────────────────────

@interface NNRootController : PSListController
@end

@implementation NNRootController

- (NSArray *)specifiers {
    return [self loadSpecifiersFromPlistName:@"Root" target:self];
}

- (id)readEnabled:(id)spec {
    id v = NNGet(@"enabled");
    return (v && [v isKindOfClass:NSNumber.class]) ? v : @YES;
}
- (void)writeEnabled:(id)val forSpecifier:(id)spec {
    NNSet(@"enabled", [val boolValue] ? (id)kCFBooleanTrue : (id)kCFBooleanFalse);
}

- (id)readDefaultMin:(id)spec {
    id v = NNGet(@"defaultCooldown");
    double s = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 120.0;
    return @(s / 60.0);
}
- (void)writeDefaultMin:(id)val forSpecifier:(id)spec {
    double s = [val doubleValue] * 60.0;
    NNSet(@"defaultCooldown", @(s));
}

@end

// ─── apps list ──────────────────────────────────────────────────────────────

@interface NNAppListController : PSListController
@end

@implementation NNAppListController

- (NSArray *)specifiers {
    NSMutableArray *out = [NSMutableArray array];
    Class WS = NSClassFromString(@"LSApplicationWorkspace");
    id ws = [WS performSelector:@selector(defaultWorkspace)];
    NSArray *apps = [ws performSelector:@selector(deviceApplications)];
    NSMutableArray *rows = [NSMutableArray array];
    for (id app in apps) {
        NSString *bid = [app performSelector:@selector(bundleIdentifier)];
        if (!bid.length) continue;
        NSString *name = nil;
        @try { name = [app performSelector:@selector(localizedName)]; } @catch (id e) {}
        if (!name.length) name = [app valueForKey:@"displayName"] ?: bid;
        // User apps only (skip system daemons/apps without display names)
        NSDictionary *d = NNAppDict(bid);
        NSString *detail = nil;
        if ([d[@"cooldown"] isKindOfClass:NSNumber.class]) {
            double cd = [d[@"cooldown"] doubleValue];
            detail = cd <= 0 ? @"cooldown: off"
                             : [NSString stringWithFormat:@"cooldown: %.0fm", cd / 60.0];
        }
        NSArray *f = d[@"filters"];
        if ([f isKindOfClass:NSArray.class] && f.count)
            detail = detail ? [detail stringByAppendingFormat:@" · %lu filters", (unsigned long)f.count]
                            : [NSString stringWithFormat:@"%lu filters", (unsigned long)f.count];
        [rows addObject:@{ @"bid": bid, @"name": name, @"detail": detail ?: @"" }];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    for (NSDictionary *r in rows) {
        PSSpecifier *s = NNSpec(NSClassFromString(@"PSSpecifier"), @"PSLinkListCell", r[@"name"]);
        [s setProperty:r[@"detail"] forKey:@"detailText"];
        [s setProperty:@"NNAppDetailController" forKey:@"detail"];
        [s setProperty:r[@"bid"] forKey:@"nnBid"];
        [out addObject:s];
    }
    return out;
}

@end

// ─── per-app page ───────────────────────────────────────────────────────────

@interface NNAppDetailController : PSListController
@end

@implementation NNAppDetailController

- (NSString *)bid {
    return [[self specifier] propertyForKey:@"nnBid"] ?: @"";
}

- (NSArray *)specifiers {
    NSMutableArray *out = [NSMutableArray array];
    NSString *bid = [self bid];
    NSString *appName = [[self specifier] propertyForKey:@"label"];

    Class Group = NSClassFromString(@"PSGroupSpecifier");
    Class Spec  = NSClassFromString(@"PSSpecifier");

    PSSpecifier *g1 = NNSpec(Group, nil, nil);
    [g1 setProperty:[NSString stringWithFormat:
        @"%@ — mute repeats for a while after one notification makes noise (0 = never mute; leave the switch off to use the global default). Notifications stay visible the whole time — only the sound is affected.",
        appName ?: bid] forKey:@"footerText"];
    [out addObject:g1];

    PSSpecifier *ovr = NNSpec(Spec, @"PSSwitchCell", @"Custom cooldown");
    NNSpecGetSet(ovr, @"readHasOverride:", @"writeHasOverride:forSpecifier:");
    [out addObject:ovr];

    PSSpecifier *cd = NNSpec(Spec, @"PSSliderCell", @"Cooldown (min)");
    [cd setProperty:@0 forKey:@"min"]; [cd setProperty:@60 forKey:@"max"];
    [cd setProperty:@1 forKey:@"step"]; [cd setProperty:(id)kCFBooleanTrue forKey:@"ShowValue"];
    NNSpecGetSet(cd, @"readAppMin:", @"writeAppMin:forSpecifier:");
    [out addObject:cd];

    PSSpecifier *g2 = NNSpec(Group, nil, nil);
    [g2 setProperty:@"Regex filters — a notification matching ANY filter is blocked completely (no banner, no lock screen, no badge). Matched case-insensitively against title + subtitle + body." forKey:@"footerText"];
    [out addObject:g2];

    for (int i = 0; i < 3; i++) {
        PSSpecifier *f = NNSpec(Spec, @"PSEditTextCell",
                                [NSString stringWithFormat:@"Filter %d", i + 1]);
        [f setProperty:[NSString stringWithFormat:@"placeholder: e.g. Get up|daily"] forKey:@"placeholder"];
        [f setProperty:@(i) forKey:@"nnIndex"];
        NNSpecGetSet(f, @"readFilter:", @"writeFilter:forSpecifier:");
        [out addObject:f];
    }
    return out;
}

// cooldown override switch: ON = app has its own stored cooldown
- (id)readHasOverride:(id)spec {
    id cd = NNAppDict([self bid])[@"cooldown"];
    return [cd isKindOfClass:NSNumber.class] ? @YES : @NO;
}
- (void)writeHasOverride:(id)val forSpecifier:(id)spec {
    if ([val boolValue]) {
        if (![NNAppDict([self bid])[@"cooldown"] isKindOfClass:NSNumber.class])
            NNAppSet([self bid], @"cooldown", @120);   // seed at 2 min
    } else {
        NNAppSet([self bid], @"cooldown", nil);        // back to global default
    }
    [self reloadSpecifiers];
}

- (id)readAppMin:(id)spec {
    id cd = NNAppDict([self bid])[@"cooldown"];
    double s = [cd isKindOfClass:NSNumber.class] ? [cd doubleValue] : 120.0;
    return @(s / 60.0);
}
- (void)writeAppMin:(id)val forSpecifier:(id)spec {
    NNAppSet([self bid], @"cooldown", @([val doubleValue] * 60.0));
}

- (id)readFilter:(id)spec {
    NSInteger i = [[(PSSpecifier *)spec propertyForKey:@"nnIndex"] integerValue];
    NSArray *f = NNAppDict([self bid])[@"filters"];
    if (![f isKindOfClass:NSArray.class] || i >= (NSInteger)f.count) return @"";
    return f[i] ?: @"";
}
- (void)writeFilter:(id)val forSpecifier:(id)spec {
    NSInteger i = [[(PSSpecifier *)spec propertyForKey:@"nnIndex"] integerValue];
    NSString *s = [val isKindOfClass:NSString.class] ? [val stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
    NSMutableArray *f = [NNAppDict([self bid])[@"filters"] mutableCopy];
    if (![f isKindOfClass:NSMutableArray.class]) f = [NSMutableArray array];
    while ((NSInteger)f.count <= i) [f addObject:@""];
    f[i] = s;
    while (f.count && [f.lastObject isEqualToString:@""]) [f removeLastObject];
    NNAppSet([self bid], @"filters", f.count ? f : nil);
}

@end
