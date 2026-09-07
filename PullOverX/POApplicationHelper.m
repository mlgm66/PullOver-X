//
//  POApplicationHelper.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import "POApplicationHelper.h"
#import <objc/message.h>

@interface UIImage (POApplicationIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID
                                               format:(int)format
                                                scale:(CGFloat)scale;
@end

static NSString * const POEnabledPendingRespringKey = @"enabled-respring-pending";
static NSDictionary *POCachedSettings;
static NSSet<NSString *> *POExternalURLRoutingWhitelist;
static BOOL PORuntimeEnabled;
static BOOL PORuntimeEnabledInitialized;

static UIImage *POIconServicesImageForIdentifier(NSString *identifier) {
    if (identifier.length == 0 ||
        ![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        return nil;
    }

    @try {
        return [UIImage _applicationIconImageForBundleIdentifier:identifier
                                                          format:0
                                                           scale:UIScreen.mainScreen.scale];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id POValueForKeySafely(id object, NSString *key) {
    if (!object || key.length == 0) {
        return nil;
    }
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

static BOOL POApplicationHasHiddenTag(id application) {
    SEL infoSelector = NSSelectorFromString(@"info");
    if (!application || ![application respondsToSelector:infoSelector]) {
        return NO;
    }

    id info = ((id (*)(id, SEL))objc_msgSend)(application, infoSelector);
    SEL hiddenSelector = NSSelectorFromString(@"hasHiddenTag");
    return [info respondsToSelector:hiddenSelector]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(info, hiddenSelector)
        : NO;
}

static NSDictionary *POInfoDictionaryForBundleIdentifier(NSString *bundleId) {
    if (bundleId.length == 0) {
        return nil;
    }
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySelector = NSSelectorFromString(@"bundleProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySelector]) {
        return nil;
    }
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySelector, bundleId);
    NSURL *bundleURL = POValueForKeySafely(proxy, @"bundleURL");
    if (![bundleURL isKindOfClass:[NSURL class]]) {
        return nil;
    }
    return [NSBundle bundleWithURL:bundleURL].infoDictionary;
}

static UIInterfaceOrientationMask POOrientationMaskFromStrings(NSArray *orientations) {
    UIInterfaceOrientationMask mask = 0;
    for (id value in orientations) {
        if (![value isKindOfClass:[NSString class]]) {
            continue;
        }
        if ([value isEqualToString:@"UIInterfaceOrientationPortrait"]) {
            mask |= UIInterfaceOrientationMaskPortrait;
        } else if ([value isEqualToString:@"UIInterfaceOrientationPortraitUpsideDown"]) {
            mask |= UIInterfaceOrientationMaskPortraitUpsideDown;
        } else if ([value isEqualToString:@"UIInterfaceOrientationLandscapeLeft"]) {
            mask |= UIInterfaceOrientationMaskLandscapeLeft;
        } else if ([value isEqualToString:@"UIInterfaceOrientationLandscapeRight"]) {
            mask |= UIInterfaceOrientationMaskLandscapeRight;
        }
    }
    return mask;
}

static void POCollectRecentBundleIdentifiers(id object, NSMutableOrderedSet *bundleIds, NSInteger depth) {
    if (!object || depth > 4 || bundleIds.count >= 30) {
        return;
    }

    if ([object isKindOfClass:[NSString class]]) {
        if ([(NSString *)object containsString:@"."]) {
            [bundleIds addObject:object];
        }
        return;
    }
    if ([object isKindOfClass:[NSArray class]] || [object isKindOfClass:[NSSet class]] || [object isKindOfClass:[NSOrderedSet class]]) {
        for (id value in object) {
            POCollectRecentBundleIdentifiers(value, bundleIds, depth + 1);
        }
        return;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        POCollectRecentBundleIdentifiers([(NSDictionary *)object allValues], bundleIds, depth + 1);
        return;
    }

    for (NSString *key in @[@"bundleIdentifier", @"displayIdentifier", @"applicationBundleIdentifier", @"applicationIdentifier", @"identifier", @"allItems", @"items", @"displayItems", @"application", @"app"]) {
        id value = POValueForKeySafely(object, key);
        if (value && value != object) {
            POCollectRecentBundleIdentifiers(value, bundleIds, depth + 1);
        }
    }
}

static id POSharedObjectForClass(Class cls) {
    for (NSString *selectorName in @[@"sharedInstance", @"sharedController", @"sharedModel", @"defaultInstance", @"defaultManager"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([cls respondsToSelector:selector]) {
            return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
        }
    }
    return nil;
}

@implementation POApplicationHelper

+ (void)updateExternalURLRoutingCacheWithSettings:(NSDictionary *)settings {
    id rawWhitelist = settings[@"externalURLRoutingWhitelist"];
    NSMutableSet<NSString *> *whitelist = [NSMutableSet set];
    if ([rawWhitelist isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)rawWhitelist) {
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                [whitelist addObject:value];
            }
        }
    }
    POExternalURLRoutingWhitelist = [whitelist copy];
}

+(NSArray<NSString *> *)recentAppsWithCount:(int)count{
    if (count <= 0) {
        return @[];
    }

    NSMutableOrderedSet *bundleIds = [NSMutableOrderedSet orderedSet];
    NSArray *layoutKeys = @[@"recentAppLayouts", @"appLayouts", @"recentLayouts", @"layouts", @"displayItems", @"items"];
    NSArray *classNames = @[@"SBMainSwitcherViewController", @"SBMainSwitcherControllerCoordinator",
                            @"SBRecentDisplayManager", @"SBFluidSwitcherViewController",
                            @"SBAppSwitcherModel", @"SBRecentAppsController"];

    for (NSString *className in classNames) {
        id source = POSharedObjectForClass(NSClassFromString(className));
        if (!source) {
            continue;
        }

        NSUInteger before = bundleIds.count;
        for (NSString *key in layoutKeys) {
            POCollectRecentBundleIdentifiers(POValueForKeySafely(source, key), bundleIds, 0);
        }
        if (bundleIds.count == before) {
            POCollectRecentBundleIdentifiers(source, bundleIds, 0);
        }
        if (bundleIds.count >= (NSUInteger)count) {
            break;
        }
    }

    NSArray *recent = bundleIds.array;
    if (recent.count > (NSUInteger)count) {
        recent = [recent subarrayWithRange:NSMakeRange(0, count)];
    }
    return recent;
}

+(NSArray<NSString *> *)quickSwitchBundleIdentifiers{
    NSDictionary *settings = [self settings];
    NSArray *sourceBundleIds = nil;
    NSInteger requestedRecentCount = 0;
    if ([settings[@"style"] isEqualToString:@"Recent Apps"]) {
        requestedRecentCount = [settings[@"recentAppsCount"] integerValue];
        NSInteger fetchCount = requestedRecentCount > 0 ? requestedRecentCount + 1 : 0;
        sourceBundleIds = fetchCount > 0 ? [self recentAppsWithCount:(int)fetchCount] : @[];
    } else {
        sourceBundleIds = [settings[@"favorites"] isKindOfClass:[NSArray class]] ? settings[@"favorites"] : @[];
    }

    NSString *frontMostBundleId = [self frontMostBundleId];
    NSMutableOrderedSet<NSString *> *bundleIds = [NSMutableOrderedSet orderedSet];
    for (id value in sourceBundleIds) {
        if (![value isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *bundleId = (NSString *)value;
        if ([self isUserFacingApplicationBundleId:bundleId] &&
            ![bundleId isEqualToString:frontMostBundleId]) {
            [bundleIds addObject:bundleId];
        }
    }
    NSArray<NSString *> *result = bundleIds.array;
    if (requestedRecentCount > 0 && result.count > (NSUInteger)requestedRecentCount) {
        result = [result subarrayWithRange:NSMakeRange(0, (NSUInteger)requestedRecentCount)];
    }
    return result;
}

+(UIImage *)imageForBundleId:(NSString *)bundleId{
    return [self iconImageForIdentifier:bundleId];
}


+(NSString *)frontMostBundleId{
    id app = ((SpringBoard *)[UIApplication sharedApplication])._accessibilityFrontMostApplication;
    if ([app respondsToSelector:@selector(bundleIdentifier)]) {
        return [app bundleIdentifier];
    }
    if ([app respondsToSelector:@selector(displayIdentifier)]) {
        return [app displayIdentifier];
    }
    return nil;
}

+ (BOOL)isUserFacingApplicationBundleId:(NSString *)bundleId {
    if (bundleId.length == 0) {
        return NO;
    }

    SBApplicationController *controller = [NSClassFromString(@"SBApplicationController") sharedInstance];
    SBApplication *application = [controller applicationWithBundleIdentifier:bundleId];
    if (!application) {
        return NO;
    }

    return !POApplicationHasHiddenTag(application);
}

+ (UIInterfaceOrientationMask)supportedInterfaceOrientationsForBundleId:(NSString *)bundleId {
    if (bundleId.length == 0) {
        return UIInterfaceOrientationMaskPortrait;
    }
    static NSCache<NSString *, NSNumber *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 64;
    });
    NSNumber *cached = [cache objectForKey:bundleId];
    if (cached) {
        return (UIInterfaceOrientationMask)cached.unsignedIntegerValue;
    }

    NSDictionary *info = POInfoDictionaryForBundleIdentifier(bundleId);
    if (!info) {
        return UIInterfaceOrientationMaskPortrait;
    }
    NSString *idiomKey = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
        ? @"UISupportedInterfaceOrientations~ipad"
        : @"UISupportedInterfaceOrientations~iphone";
    NSArray *orientations = [info[idiomKey] isKindOfClass:[NSArray class]] ? info[idiomKey] : nil;
    if (orientations.count == 0) {
        orientations = [info[@"UISupportedInterfaceOrientations"] isKindOfClass:[NSArray class]]
            ? info[@"UISupportedInterfaceOrientations"]
            : nil;
    }
    UIInterfaceOrientationMask mask = POOrientationMaskFromStrings(orientations);
    if (mask == 0) {
        mask = UIInterfaceOrientationMaskPortrait;
    }
    [cache setObject:@(mask) forKey:bundleId];
    return mask;
}

+ (UIInterfaceOrientation)preferredHostedInterfaceOrientationForBundleId:(NSString *)bundleId {
    UIInterfaceOrientationMask mask = [self supportedInterfaceOrientationsForBundleId:bundleId];
    if (mask & UIInterfaceOrientationMaskPortrait) {
        return UIInterfaceOrientationPortrait;
    }
    if (mask & UIInterfaceOrientationMaskPortraitUpsideDown) {
        return UIInterfaceOrientationPortraitUpsideDown;
    }
    if (mask & UIInterfaceOrientationMaskLandscapeRight) {
        return UIInterfaceOrientationLandscapeRight;
    }
    if (mask & UIInterfaceOrientationMaskLandscapeLeft) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    return UIInterfaceOrientationPortrait;
}


+(NSUserDefaults *)settingsDefaults{
    static NSUserDefaults *defaults;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.mlgm.pulloverx"];
        [defaults registerDefaults:@{
            @"enabled": @YES,
            @"favorites": @[],
            @"recentAppsCount": @12,
            @"quickSwitchAppSlots": @12,
            @"style": @"Recent Apps",
            @"leftHanded": @NO,
            @"hideOnScreenshot": @YES,
            @"hideLabels": @NO,
            @"handleSize": @34,
            @"nubHiddenPercentage": @67,
            @"landscapeBehavior": @"rotate",
            @"externalURLRoutingEnabled": @NO,
            @"externalURLRoutingWhitelist": @[],
            @"hapticFeedback": @YES,
            @"soundFeedback": @YES,
            @"keyboardAvoiding": @YES,
            @"landscapeKeyboardZoom": @YES,
            @"autoNub": @NO,
            @"autoNub-time": @0,
            @"handleActivationGuard": @NO,
            POEnabledPendingRespringKey: @NO,
        }];
    });
    return defaults;
}
+(NSDictionary<NSString *, id> *)settings{
    @synchronized (self) {
        if (!POCachedSettings) {
            NSDictionary *snapshot = [[self settingsDefaults] dictionaryRepresentation];
            PORuntimeEnabled = [snapshot[@"enabled"] boolValue];
            PORuntimeEnabledInitialized = YES;
            POCachedSettings = [snapshot copy];
            [self updateExternalURLRoutingCacheWithSettings:POCachedSettings];
        }
        return POCachedSettings;
    }
}
+ (void)reloadSettings {
    @synchronized (self) {
        NSDictionary *snapshot = [[self settingsDefaults] dictionaryRepresentation];
        BOOL pendingRespring = [snapshot[POEnabledPendingRespringKey] boolValue];
        if (!PORuntimeEnabledInitialized) {
            PORuntimeEnabled = [snapshot[@"enabled"] boolValue];
            PORuntimeEnabledInitialized = YES;
        } else if (!pendingRespring) {
            PORuntimeEnabled = [snapshot[@"enabled"] boolValue];
        }

        NSMutableDictionary *effectiveSettings = [snapshot mutableCopy];
        effectiveSettings[@"enabled"] = @(PORuntimeEnabled);
        POCachedSettings = [effectiveSettings copy];
        [self updateExternalURLRoutingCacheWithSettings:POCachedSettings];
    }
}
+ (BOOL)isEnabled {
    return [[self settings][@"enabled"] boolValue];
}

+ (BOOL)isExternalURLRoutingEnabled {
    return [[self settings][@"externalURLRoutingEnabled"] boolValue];
}

+ (BOOL)isExternalURLRoutingTargetBundleId:(NSString *)bundleId {
    if (bundleId.length == 0 || ![self isExternalURLRoutingEnabled]) {
        return NO;
    }
    @synchronized (self) {
        return [POExternalURLRoutingWhitelist containsObject:bundleId];
    }
}

+ (UIImage *)iconImageForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }

    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26) {
        UIImage *iconServicesImage = POIconServicesImageForIdentifier(identifier);
        if (iconServicesImage) {
            return iconServicesImage;
        }
    }

    Class iconControllerClass = NSClassFromString(@"SBIconController");
    if (!iconControllerClass || ![iconControllerClass respondsToSelector:@selector(sharedInstance)]) {
        return POIconServicesImageForIdentifier(identifier);
    }

    SBIconController *iconController = [iconControllerClass sharedInstance];
    if (!iconController) {
        return POIconServicesImageForIdentifier(identifier);
    }

    SBIconModel *iconModel = nil;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26) {
        if (![iconController respondsToSelector:@selector(iconModel)]) {
            return POIconServicesImageForIdentifier(identifier);
        }
        iconModel = iconController.iconModel;
    } else {
        if (![iconController respondsToSelector:@selector(model)]) {
            return POIconServicesImageForIdentifier(identifier);
        }
        iconModel = iconController.model;
    }
    if (!iconModel || ![iconModel respondsToSelector:@selector(applicationIconForBundleIdentifier:)]) {
        return POIconServicesImageForIdentifier(identifier);
    }

    SBIcon *icon = [iconModel applicationIconForBundleIdentifier:identifier];
    SBHIconImageCache *cache = iconController.tableUIIconImageCache;
    if (!icon || !cache || ![cache respondsToSelector:@selector(imageForIcon:)]) {
        return POIconServicesImageForIdentifier(identifier);
    }
    UIImage *cachedImage = [cache imageForIcon:icon];
    return cachedImage ?: POIconServicesImageForIdentifier(identifier);
}


@end
