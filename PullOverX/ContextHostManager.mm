#import "ContextHostManager.h"
#import "POSplitSessionController.h"
#import "POApplicationHelper.h"
#import "POCameraGrantState.h"
#import "FBSOrientationObserver.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>

enum {
    kPOBKSProcessAssertionPreventTaskSuspend = (1 << 0),
    kPOBKSProcessAssertionPreventTaskThrottleDown = (1 << 1),
    kPOBKSProcessAssertionWantsForegroundResourcePriority = (1 << 3),
    kPOBKSProcessAssertionPreventThrottleDownUI = (1 << 5),
    kPOBKSProcessAssertionReasonBackgroundUI = 7,
};

@interface RBSTarget : NSObject
+ (instancetype)targetWithPid:(int)pid;
@end

@interface RBSLegacyAttribute : NSObject
+ (instancetype)attributeWithReason:(NSUInteger)reason flags:(NSUInteger)flags;
@end

@interface RBSAssertion : NSObject
- (instancetype)initWithExplanation:(NSString *)explanation target:(id)target attributes:(NSArray *)attributes;
- (BOOL)acquireWithError:(NSError **)error;
- (void)invalidate;
@end

static NSString * const kPORequester = @"com.mlgm.pulloverx";

static BOOL POIsIOS26SceneLayerHostContainerView(UIView *view) {
    if (!view) {
        return NO;
    }
    Class containerClass = NSClassFromString(@"_UISceneLayerHostContainerView");
    return (containerClass && [view isKindOfClass:containerClass]) ||
        [NSStringFromClass(view.class) isEqualToString:@"_UISceneLayerHostContainerView"];
}

static void POInvalidateIOS26SceneLayerHostContainersInView(UIView *view) {
    if (!view) {
        return;
    }
    if (POIsIOS26SceneLayerHostContainerView(view)) {
        SEL invalidateSelector = NSSelectorFromString(@"invalidate");
        if ([view respondsToSelector:invalidateSelector]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(view, invalidateSelector);
            } @catch (__unused NSException *exception) {
            }
        }
        return;
    }
    NSArray<UIView *> *subviews = [view.subviews copy];
    for (UIView *subview in subviews) {
        POInvalidateIOS26SceneLayerHostContainersInView(subview);
    }
}

static BOOL POIsConcreteInterfaceOrientation(UIInterfaceOrientation orientation) {
    return orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
}

static BOOL POOrientationCategoriesMatch(UIInterfaceOrientation lhs, UIInterfaceOrientation rhs) {
    if (!POIsConcreteInterfaceOrientation(lhs) || !POIsConcreteInterfaceOrientation(rhs)) {
        return NO;
    }
    return UIInterfaceOrientationIsLandscape(lhs) == UIInterfaceOrientationIsLandscape(rhs);
}

static BOOL POOrientationMaskContainsOrientation(UIInterfaceOrientationMask mask,
                                                 UIInterfaceOrientation orientation) {
    if (!POIsConcreteInterfaceOrientation(orientation)) {
        return NO;
    }
    return (mask & (1UL << (NSUInteger)orientation)) != 0;
}

static UIInterfaceOrientation POSoleInterfaceOrientationInMask(UIInterfaceOrientationMask mask) {
    UIInterfaceOrientation resolvedOrientation = UIInterfaceOrientationUnknown;
    const UIInterfaceOrientation candidates[] = {
        UIInterfaceOrientationPortrait,
        UIInterfaceOrientationPortraitUpsideDown,
        UIInterfaceOrientationLandscapeLeft,
        UIInterfaceOrientationLandscapeRight,
    };
    for (UIInterfaceOrientation orientation : candidates) {
        if (!POOrientationMaskContainsOrientation(mask, orientation)) {
            continue;
        }
        if (POIsConcreteInterfaceOrientation(resolvedOrientation)) {
            return UIInterfaceOrientationUnknown;
        }
        resolvedOrientation = orientation;
    }
    return resolvedOrientation;
}

static UIInterfaceOrientation POInterfaceOrientationFromSettings(id settings) {
    SEL selector = NSSelectorFromString(@"interfaceOrientation");
    if (settings && [settings respondsToSelector:selector]) {
        return (UIInterfaceOrientation)((NSInteger (*)(id, SEL))objc_msgSend)(settings, selector);
    }
    return UIInterfaceOrientationUnknown;
}

static id POClientSettingsForScene(FBScene *scene) {
    SEL selector = NSSelectorFromString(@"clientSettings");
    return scene && [scene respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(scene, selector)
        : nil;
}

static UIInterfaceOrientation POEffectiveInterfaceOrientationFromClientSettings(id settings) {
    SEL effectiveSelector = NSSelectorFromString(@"sb_effectiveInterfaceOrientation");
    if (settings && [settings respondsToSelector:effectiveSelector]) {
        UIInterfaceOrientation orientation =
            (UIInterfaceOrientation)((NSInteger (*)(id, SEL))objc_msgSend)(settings, effectiveSelector);
        if (POIsConcreteInterfaceOrientation(orientation)) {
            return orientation;
        }
    }
    return POInterfaceOrientationFromSettings(settings);
}

static UIInterfaceOrientation POPreferredInterfaceOrientationFromClientSettings(id settings) {
    SEL selector = NSSelectorFromString(@"preferredInterfaceOrientation");
    if (settings && [settings respondsToSelector:selector]) {
        return (UIInterfaceOrientation)((NSInteger (*)(id, SEL))objc_msgSend)(settings, selector);
    }
    return UIInterfaceOrientationUnknown;
}

static UIInterfaceOrientationMask POSupportedInterfaceOrientationsFromClientSettings(id settings) {
    SEL selector = NSSelectorFromString(@"supportedInterfaceOrientations");
    return settings && [settings respondsToSelector:selector]
        ? (UIInterfaceOrientationMask)((NSUInteger (*)(id, SEL))objc_msgSend)(settings, selector)
        : 0;
}

static UIInterfaceOrientation PORuntimeInterfaceOrientationFromClientSettings(id settings) {
    UIInterfaceOrientation effectiveOrientation =
        POEffectiveInterfaceOrientationFromClientSettings(settings);
    UIInterfaceOrientation preferredOrientation =
        POPreferredInterfaceOrientationFromClientSettings(settings);
    UIInterfaceOrientationMask supportedMask =
        POSupportedInterfaceOrientationsFromClientSettings(settings);

    if (POIsConcreteInterfaceOrientation(effectiveOrientation) &&
        (supportedMask == 0 || POOrientationMaskContainsOrientation(supportedMask, effectiveOrientation))) {
        return effectiveOrientation;
    }
    if (POIsConcreteInterfaceOrientation(preferredOrientation) &&
        (supportedMask == 0 || POOrientationMaskContainsOrientation(supportedMask, preferredOrientation))) {
        return preferredOrientation;
    }
    if (supportedMask != 0) {
        return POSoleInterfaceOrientationInMask(supportedMask);
    }
    return UIInterfaceOrientationUnknown;
}

static BOOL POClientOrientationContractNeedsForegroundReconciliation(
    id settings,
    UIInterfaceOrientation targetOrientation) {
    if (!settings || !POIsConcreteInterfaceOrientation(targetOrientation)) {
        return NO;
    }
    UIInterfaceOrientation effectiveOrientation =
        POEffectiveInterfaceOrientationFromClientSettings(settings);
    if (!POIsConcreteInterfaceOrientation(effectiveOrientation)) {
        effectiveOrientation = POInterfaceOrientationFromSettings(settings);
    }
    UIInterfaceOrientationMask supportedMask =
        POSupportedInterfaceOrientationsFromClientSettings(settings);
    if (!POIsConcreteInterfaceOrientation(effectiveOrientation) || supportedMask == 0 ||
        POOrientationMaskContainsOrientation(supportedMask, effectiveOrientation)) {
        return NO;
    }
    UIInterfaceOrientation resolvedOrientation =
        PORuntimeInterfaceOrientationFromClientSettings(settings);
    return POIsConcreteInterfaceOrientation(resolvedOrientation) &&
        POOrientationCategoriesMatch(resolvedOrientation, targetOrientation);
}

static UIInterfaceOrientation POLiveLeadingInterfaceOrientationFromClientSettings(
    id settings,
    UIInterfaceOrientation currentHostedOrientation) {
    UIInterfaceOrientation interfaceOrientation = POInterfaceOrientationFromSettings(settings);
    UIInterfaceOrientation effectiveOrientation = POEffectiveInterfaceOrientationFromClientSettings(settings);
    UIInterfaceOrientation preferredOrientation = POPreferredInterfaceOrientationFromClientSettings(settings);
    UIInterfaceOrientationMask supportedMask = POSupportedInterfaceOrientationsFromClientSettings(settings);

    if (!POIsConcreteInterfaceOrientation(interfaceOrientation) ||
        !POIsConcreteInterfaceOrientation(effectiveOrientation) ||
        !POOrientationCategoriesMatch(interfaceOrientation, effectiveOrientation) ||
        !POIsConcreteInterfaceOrientation(currentHostedOrientation) ||
        POOrientationCategoriesMatch(effectiveOrientation, currentHostedOrientation) ||
        supportedMask == 0 ||
        POOrientationMaskContainsOrientation(supportedMask, effectiveOrientation)) {
        return UIInterfaceOrientationUnknown;
    }
    if (POIsConcreteInterfaceOrientation(preferredOrientation) &&
        !POOrientationCategoriesMatch(preferredOrientation, effectiveOrientation)) {
        return UIInterfaceOrientationUnknown;
    }
    return effectiveOrientation;
}

static BOOL POSceneIdentifierMatchesBundleIdentifier(NSString *identifier, NSString *bundleIdentifier) {
    if (identifier.length == 0 || bundleIdentifier.length == 0) {
        return NO;
    }
    if ([identifier isEqualToString:bundleIdentifier]) {
        return YES;
    }

    NSString *scenePrefix = [bundleIdentifier stringByAppendingString:@"-"];
    NSRange range = [identifier rangeOfString:scenePrefix];
    if (range.location == NSNotFound) {
        return NO;
    }
    return range.location == 0 || [identifier characterAtIndex:range.location - 1] == ':';
}

static NSString *POSceneIdentityStringFromSettings(id settings) {
    if (!settings) {
        return nil;
    }
    SEL identifierSelector = NSSelectorFromString(@"identifier");
    if ([settings respondsToSelector:identifierSelector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(settings, identifierSelector);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }
    for (NSString *key in @[ @"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier" ]) {
        @try {
            id value = [settings valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return value;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static BOOL POObjectShallowGraphMentionsBundleIdentifier(id object, NSString *bundleIdentifier) {
    if (!object || bundleIdentifier.length == 0) {
        return NO;
    }
    NSString *description = [object description];
    if ([description containsString:bundleIdentifier]) {
        return YES;
    }

    for (Class cls = object_getClass(object); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            Ivar ivar = ivars[index];
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') {
                continue;
            }
            id value = object_getIvar(object, ivar);
            if (!value) {
                continue;
            }
            if ([value isKindOfClass:[NSString class]] &&
                POSceneIdentifierMatchesBundleIdentifier((NSString *)value, bundleIdentifier)) {
                free(ivars);
                return YES;
            }
            NSString *valueDescription = [value description];
            if ([valueDescription containsString:bundleIdentifier]) {
                free(ivars);
                return YES;
            }
        }
        free(ivars);
    }
    return NO;
}

static void POSetDeviceOrientationOnSettings(id settings, UIInterfaceOrientation orientation) {
    SEL selector = NSSelectorFromString(@"setDeviceOrientation:");
    if (!settings || !POIsConcreteInterfaceOrientation(orientation) ||
        ![settings respondsToSelector:selector]) {
        return;
    }

    UIDeviceOrientation deviceOrientation = UIDeviceOrientationPortrait;
    switch (orientation) {
        case UIInterfaceOrientationPortrait:            deviceOrientation = UIDeviceOrientationPortrait; break;
        case UIInterfaceOrientationPortraitUpsideDown:  deviceOrientation = UIDeviceOrientationPortraitUpsideDown; break;
        case UIInterfaceOrientationLandscapeLeft:       deviceOrientation = UIDeviceOrientationLandscapeRight; break;
        case UIInterfaceOrientationLandscapeRight:      deviceOrientation = UIDeviceOrientationLandscapeLeft; break;
        default: break;
    }

    SEL getter = NSSelectorFromString(@"deviceOrientation");
    UIDeviceOrientation currentOrientation = [settings respondsToSelector:getter]
        ? (UIDeviceOrientation)((long long (*)(id, SEL))objc_msgSend)(settings, getter)
        : (UIDeviceOrientation)-1;
    if (currentOrientation != deviceOrientation) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(settings, selector, (NSInteger)deviceOrientation);
    }
}

static BOOL POSetInterfaceOrientationOnSettings(id settings, UIInterfaceOrientation orientation) {
    SEL selector = NSSelectorFromString(@"setInterfaceOrientation:");
    if (!settings || !POIsConcreteInterfaceOrientation(orientation) ||
        ![settings respondsToSelector:selector]) {
        return NO;
    }

    POSetDeviceOrientationOnSettings(settings, orientation);
    if (POInterfaceOrientationFromSettings(settings) == orientation) {
        return NO;
    }
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(settings, selector, (NSInteger)orientation);
    return YES;
}

static UIInterfaceOrientation POCurrentSystemInterfaceOrientation(void) {
    POSplitSessionController *splitSession = [POSplitSessionController sharedInstance];
    if (splitSession.isActive && splitSession.baseScene) {
        id baseScene = splitSession.baseScene;
        id settings = [baseScene respondsToSelector:@selector(settings)] ? [baseScene settings] : nil;
        UIInterfaceOrientation orientation = POInterfaceOrientationFromSettings(settings);
        SEL orientationSelector = NSSelectorFromString(@"interfaceOrientation");
        if (!POIsConcreteInterfaceOrientation(orientation) &&
            [baseScene respondsToSelector:orientationSelector]) {
            orientation = (UIInterfaceOrientation)((NSInteger (*)(id, SEL))objc_msgSend)(baseScene,
                                                                                          orientationSelector);
        }
        if (POIsConcreteInterfaceOrientation(orientation)) {
            return orientation;
        }
    }

    NSString *frontMostBundleId = [POApplicationHelper frontMostBundleId];
    if (frontMostBundleId.length > 0) {
        FBScene *frontMostScene = [[ContextHostManager sharedInstance] probeSceneForBundleId:frontMostBundleId];
        if (frontMostScene) {
            id settings = [frontMostScene respondsToSelector:@selector(settings)] ? [frontMostScene settings] : nil;
            UIInterfaceOrientation orientation = POInterfaceOrientationFromSettings(settings);
            SEL clientSettingsSelector = NSSelectorFromString(@"clientSettings");
            if (!POIsConcreteInterfaceOrientation(orientation) &&
                [frontMostScene respondsToSelector:clientSettingsSelector]) {
                id clientSettings = ((id (*)(id, SEL))objc_msgSend)(frontMostScene, clientSettingsSelector);
                orientation = POInterfaceOrientationFromSettings(clientSettings);
            }
            if (POIsConcreteInterfaceOrientation(orientation)) {
                return orientation;
            }
        }
    }

    id application = UIApplication.sharedApplication;
    SEL mainDisplaySceneSelector = NSSelectorFromString(@"_mainDisplayWindowScene");
    id mainDisplayScene = application && [application respondsToSelector:mainDisplaySceneSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(application, mainDisplaySceneSelector)
        : nil;
    SEL sceneOrientationSelector = NSSelectorFromString(@"interfaceOrientation");
    if (mainDisplayScene && [mainDisplayScene respondsToSelector:sceneOrientationSelector]) {
        UIInterfaceOrientation orientation =
            (UIInterfaceOrientation)((long long (*)(id, SEL))objc_msgSend)(mainDisplayScene,
                                                                           sceneOrientationSelector);
        if (POIsConcreteInterfaceOrientation(orientation)) {
            return orientation;
        }
    }

    SEL springBoardOrientationSelector = NSSelectorFromString(@"activeInterfaceOrientation");
    if (application && [application respondsToSelector:springBoardOrientationSelector]) {
        UIInterfaceOrientation orientation =
            (UIInterfaceOrientation)((long long (*)(id, SEL))objc_msgSend)(application,
                                                                           springBoardOrientationSelector);
        if (POIsConcreteInterfaceOrientation(orientation)) {
            return orientation;
        }
    }

    Class observerClass = NSClassFromString(@"FBSOrientationObserver");
    id observer = observerClass ? [[observerClass alloc] init] : nil;
    SEL activeSelector = NSSelectorFromString(@"activeInterfaceOrientation");
    if (observer && [observer respondsToSelector:activeSelector]) {
        UIInterfaceOrientation orientation =
            (UIInterfaceOrientation)((long long (*)(id, SEL))objc_msgSend)(observer, activeSelector);
        SEL invalidateSelector = NSSelectorFromString(@"invalidate");
        if ([observer respondsToSelector:invalidateSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(observer, invalidateSelector);
        }
        if (POIsConcreteInterfaceOrientation(orientation)) {
            return orientation;
        }
    }
    return UIInterfaceOrientationUnknown;
}

static CGRect POCanonicalApplicationSceneFrame(id settings) {
    id displayConfiguration = nil;
    SEL displaySelector = NSSelectorFromString(@"displayConfiguration");
    if (settings && [settings respondsToSelector:displaySelector]) {
        displayConfiguration = ((id (*)(id, SEL))objc_msgSend)(settings, displaySelector);
    }
    if (!displayConfiguration && [UIScreen.mainScreen respondsToSelector:displaySelector]) {
        displayConfiguration = ((id (*)(id, SEL))objc_msgSend)(UIScreen.mainScreen, displaySelector);
    }
    SEL boundsSelector = NSSelectorFromString(@"bounds");
    if (displayConfiguration && [displayConfiguration respondsToSelector:boundsSelector]) {
        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(displayConfiguration, boundsSelector);
        if (CGRectGetWidth(bounds) > 0 && CGRectGetHeight(bounds) > 0) {
            return CGRectMake(0, 0, CGRectGetWidth(bounds), CGRectGetHeight(bounds));
        }
    }
    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    return CGRectMake(0, 0,
                      MIN(screenSize.width, screenSize.height),
                      MAX(screenSize.width, screenSize.height));
}

static CGSize POHostedCanvasSizeForOrientation(UIInterfaceOrientation orientation) {
    CGRect canonicalFrame = POCanonicalApplicationSceneFrame(nil);
    CGFloat shortSide = MIN(CGRectGetWidth(canonicalFrame), CGRectGetHeight(canonicalFrame));
    CGFloat longSide = MAX(CGRectGetWidth(canonicalFrame), CGRectGetHeight(canonicalFrame));
    if (shortSide <= 0 || longSide <= 0) {
        CGSize screenSize = UIScreen.mainScreen.bounds.size;
        shortSide = MIN(screenSize.width, screenSize.height);
        longSide = MAX(screenSize.width, screenSize.height);
    }
    return UIInterfaceOrientationIsLandscape(orientation)
        ? CGSizeMake(longSide, shortSide)
        : CGSizeMake(shortSide, longSide);
}

static BOOL POSceneSizesMatch(CGSize lhs, CGSize rhs) {
    return fabs(lhs.width - rhs.width) <= 0.5 && fabs(lhs.height - rhs.height) <= 0.5;
}

static CGAffineTransform POKeyboardPresentationTransformForInterfaceOrientation(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return CGAffineTransformMakeRotation((CGFloat)M_PI_2);
        case UIInterfaceOrientationLandscapeRight:
            return CGAffineTransformMakeRotation((CGFloat)-M_PI_2);
        case UIInterfaceOrientationPortraitUpsideDown:
            return CGAffineTransformMakeRotation((CGFloat)M_PI);
        case UIInterfaceOrientationPortrait:
        default:
            return CGAffineTransformIdentity;
    }
}

static NSInteger POOrientationDegrees(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft: return 90;
        case UIInterfaceOrientationLandscapeRight: return -90;
        case UIInterfaceOrientationPortraitUpsideDown: return 180;
        case UIInterfaceOrientationPortrait:
        default: return 0;
    }
}

static void POApplyIOS26HostTransformer(UIView *hostView,
                                       UIInterfaceOrientation sourceOrientation,
                                       UIInterfaceOrientation targetOrientation) {
    if (!hostView || NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 ||
        !POIsConcreteInterfaceOrientation(sourceOrientation) ||
        !POIsConcreteInterfaceOrientation(targetOrientation)) {
        return;
    }

    SEL setTransformerSelector = NSSelectorFromString(@"setTransformer:");
    Class transformClass = NSClassFromString(@"UITransform");
    Class mutableTransformerClass = NSClassFromString(@"UIMutableTransformer");
    SEL rotationSelector = NSSelectorFromString(@"rotationWithDegrees:");
    SEL addTransformSelector = NSSelectorFromString(@"addTransform:reason:");
    if (!transformClass || !mutableTransformerClass || ![hostView respondsToSelector:setTransformerSelector] ||
        ![transformClass respondsToSelector:rotationSelector] ||
        ![mutableTransformerClass instancesRespondToSelector:addTransformSelector]) {
        return;
    }

    NSInteger degrees = POOrientationDegrees(targetOrientation) - POOrientationDegrees(sourceOrientation);
    while (degrees > 180) degrees -= 360;
    while (degrees < -180) degrees += 360;
    id transform = ((id (*)(id, SEL, NSInteger))objc_msgSend)(transformClass,
                                                               rotationSelector,
                                                               degrees);
    id transformer = [[mutableTransformerClass alloc] init];
    if (!transform || !transformer) {
        return;
    }
    ((void (*)(id, SEL, id, id))objc_msgSend)(transformer,
                                             addTransformSelector,
                                             transform,
                                             @"PullOverX presentation orientation");
    ((void (*)(id, SEL, id))objc_msgSend)(hostView, setTransformerSelector, transformer);
}

static void POClearHostedOrientationMapFromSettings(id settings) {
    SEL setResolverSelector = NSSelectorFromString(@"setInterfaceOrientationMapResolver:");
    if (settings && [settings respondsToSelector:setResolverSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(settings, setResolverSelector, nil);
    }
}

static void POApplyCrossOrientationMapToSettings(id settings,
                                                 UIInterfaceOrientation hostedOrientation) {
    UIInterfaceOrientation targetOrientation = POCurrentSystemInterfaceOrientation();
    if (!settings || !POIsConcreteInterfaceOrientation(targetOrientation) ||
        !POIsConcreteInterfaceOrientation(hostedOrientation) ||
        POOrientationCategoriesMatch(targetOrientation, hostedOrientation)) {
        return;
    }

    Class resolverClass = NSClassFromString(@"BSCanonicalOrientationMapResolver");
    SEL initSelector = NSSelectorFromString(@"initWithTargetOrientation:currentOrientation:");
    SEL setModeSelector = NSSelectorFromString(@"setInterfaceOrientationMode:");
    SEL setResolverSelector = NSSelectorFromString(@"setInterfaceOrientationMapResolver:");
    if (!resolverClass || ![resolverClass instancesRespondToSelector:initSelector] ||
        ![settings respondsToSelector:setModeSelector] ||
        ![settings respondsToSelector:setResolverSelector]) {
        return;
    }

    id resolver = ((id (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(
        [resolverClass alloc],
        initSelector,
        (NSInteger)targetOrientation,
        (NSInteger)hostedOrientation);
    if (!resolver) {
        return;
    }

    ((void (*)(id, SEL, NSInteger))objc_msgSend)(settings, setModeSelector, 1);
    ((void (*)(id, SEL, id))objc_msgSend)(settings, setResolverSelector, resolver);
}


static SBApplication *applicationForID(NSString *applicationID);

static void POConfigureIOS26ScenePresentationContext(UIView *hostView) {
    if (!hostView || NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26) {
        return;
    }

    SEL setContextSelector = NSSelectorFromString(@"setCurrentPresentationContext:");
    Class contextClass = NSClassFromString(@"UIScenePresentationContext");
    SEL initSelector = NSSelectorFromString(@"_initWithDefaultValues");
    if (!contextClass || ![hostView respondsToSelector:setContextSelector] ||
        ![contextClass instancesRespondToSelector:initSelector]) {
        return;
    }

    id context = ((id (*)(id, SEL))objc_msgSend)([contextClass alloc], initSelector);
    if (!context) {
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(hostView, setContextSelector, context);

    SEL setStopsHitSelector = NSSelectorFromString(@"setStopsHitTestTransformAccumulation:");
    SEL setStopsSecureSelector = NSSelectorFromString(@"setStopsSecureSuperlayersValidation:");
    SEL setZombifiesSelector = NSSelectorFromString(@"setZombifiesHostedContext:");
    if ([hostView respondsToSelector:setStopsHitSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(hostView, setStopsHitSelector, YES);
    }
    if ([hostView respondsToSelector:setStopsSecureSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(hostView, setStopsSecureSelector, YES);
    }
    if ([hostView respondsToSelector:setZombifiesSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(hostView, setZombifiesSelector, YES);
    }
}

static id POCreateIOS26ScenePresentationContext(UIInterfaceOrientation sourceOrientation,
                                                UIInterfaceOrientation targetOrientation) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26) {
        return nil;
    }
    Class contextClass = NSClassFromString(@"UIScenePresentationContext");
    SEL initSelector = NSSelectorFromString(@"_initWithDefaultValues");
    if (!contextClass || ![contextClass instancesRespondToSelector:initSelector]) {
        return nil;
    }

    id context = ((id (*)(id, SEL))objc_msgSend)([contextClass alloc], initSelector);
    if (!context) {
        return nil;
    }

    SEL setStopsHitSelector = NSSelectorFromString(@"setStopsHitTestTransformAccumulation:");
    SEL setStopsSecureSelector = NSSelectorFromString(@"setStopsSecureSuperlayersValidation:");
    SEL setZombifiesSelector = NSSelectorFromString(@"setZombifiesHostedContext:");
    SEL setResizesSelector = NSSelectorFromString(@"setResizesHostedContext:");
    if ([context respondsToSelector:setStopsHitSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(context, setStopsHitSelector, YES);
    }
    if ([context respondsToSelector:setStopsSecureSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(context, setStopsSecureSelector, YES);
    }
    if ([context respondsToSelector:setZombifiesSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(context, setZombifiesSelector, YES);
    }
    if ([context respondsToSelector:setResizesSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(context, setResizesSelector, YES);
    }

    SEL rotationSelector = NSSelectorFromString(@"rotationWithDegrees:");
    Class transformClass = NSClassFromString(@"UITransform");
    Class mutableTransformerClass = NSClassFromString(@"UIMutableTransformer");
    SEL addTransformSelector = NSSelectorFromString(@"addTransform:reason:");
    if (transformClass && mutableTransformerClass &&
        [transformClass respondsToSelector:rotationSelector] &&
        [mutableTransformerClass instancesRespondToSelector:addTransformSelector] &&
        POIsConcreteInterfaceOrientation(sourceOrientation) &&
        POIsConcreteInterfaceOrientation(targetOrientation)) {
        NSInteger degrees = POOrientationDegrees(targetOrientation) -
            POOrientationDegrees(sourceOrientation);
        while (degrees > 180) degrees -= 360;
        while (degrees < -180) degrees += 360;
        id transform = ((id (*)(id, SEL, NSInteger))objc_msgSend)(transformClass,
                                                                   rotationSelector,
                                                                   degrees);
        id transformer = [[mutableTransformerClass alloc] init];
        if (transform && transformer) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(transformer,
                                                     addTransformSelector,
                                                     transform,
                                                     @"PullOverX presentation orientation");
            id mutableContext = [context respondsToSelector:@selector(mutableCopy)]
                ? [context mutableCopy]
                : nil;
            id configuredContext = mutableContext ?: context;
            if ([configuredContext respondsToSelector:setStopsHitSelector]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(configuredContext, setStopsHitSelector, YES);
            }
            if ([configuredContext respondsToSelector:setStopsSecureSelector]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(configuredContext, setStopsSecureSelector, YES);
            }
            if ([configuredContext respondsToSelector:setZombifiesSelector]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(configuredContext, setZombifiesSelector, YES);
            }
            if ([configuredContext respondsToSelector:setResizesSelector]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(configuredContext, setResizesSelector, YES);
            }
            SEL setHostTransformerSelector = NSSelectorFromString(@"setHostTransformer:");
            if ([configuredContext respondsToSelector:setHostTransformerSelector]) {
                ((void (*)(id, SEL, id))objc_msgSend)(configuredContext,
                                                      setHostTransformerSelector,
                                                      transformer);
            } else {
                @try {
                    [configuredContext setValue:transformer forKey:@"transformer"];
                } @catch (__unused NSException *exception) {
                }
            }
            context = configuredContext;
        }
    }
    return context;
}

static void PONormalizeIOS26PresentationContainerGeometry(UIView *container) {
    if (!container || NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26) {
        return;
    }

    [UIView performWithoutAnimation:^{
        for (UIView *canvasView in container.subviews) {
            canvasView.frame = container.bounds;
            canvasView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                UIViewAutoresizingFlexibleHeight;
            for (UIView *hostView in canvasView.subviews) {
                hostView.frame = canvasView.bounds;
                hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                    UIViewAutoresizingFlexibleHeight;
            }
        }
    }];
}

@interface ContextHostManager ()
@property (nonatomic, strong) FBScene *hostedScene;
@property (nonatomic, strong) FBSceneLayerManager *hostedLayerManager;
@property (nonatomic, strong) FBSceneHostManager *hostedFallbackHostManager;
@property (nonatomic, copy) NSString *hostedBundleId;
@property (nonatomic, assign) BOOL observingLayers;
@property (nonatomic, assign) UIInterfaceOrientation hostedInterfaceOrientation;
@property (nonatomic, assign) UIInterfaceOrientation activeSurfaceSourceOrientation;
@property (nonatomic, assign) BOOL runtimeHostedOrientationAuthorityActive;
@property (nonatomic, assign) BOOL runtimeClientOrientationBaselineEstablished;
@property (nonatomic, assign) BOOL retainedRuntimeSourceRebasePending;
@property (nonatomic, assign) BOOL applyingHostedSettingsInternally;
@property (nonatomic, assign) UIInterfaceOrientation pendingRuntimeOrientationNotification;
@property (nonatomic, assign) NSUInteger pendingRuntimeOrientationNotificationGeneration;
@property (nonatomic, weak) FBScene *observedClientSettingsScene;
@property (nonatomic, weak) FBScene *observedContentStateScene;
@property (nonatomic, assign, getter=isForegroundLeaseActive) BOOL foregroundLeaseActive;
@property (nonatomic, assign) NSUInteger activeLeaseGeneration;
@property (nonatomic, strong) id processAssertion;
@property (nonatomic, strong) FBScene *publishedScene;
@property (nonatomic, strong) UIView *publishedSceneStack;
@property (nonatomic, strong) id ios26PresentationContext;
@property (nonatomic, weak) UIView *ios26PresentationContainer;
@property (nonatomic, copy) NSArray<FBSceneLayer *> *publishedMainLayers;
@property (nonatomic, assign) CGSize publishedSceneStackSize;
@property (nonatomic, assign) UIInterfaceOrientation publishedSceneStackOrientation;
@property (nonatomic, assign) BOOL forceNextPublishedSceneStackRebuild;
@property (nonatomic, strong) FBScene *ownedHostedScene;
@property (nonatomic, copy) NSString *ownedHostedBundleId;
@property (nonatomic, assign) int ownedHostedProcessPID;
@property (nonatomic, assign) BOOL ownedHostedSceneServerFrameCanonicalized;
@property (nonatomic, assign) BOOL ownedHostedSceneCapabilityProven;
@property (nonatomic, weak) FBScene *systemHostedSnapshotScene;
@property (nonatomic, strong) id systemHostedOriginalSettings;
@property (nonatomic, assign) CGRect systemHostedOriginalFrame;
@property (nonatomic, assign) BOOL systemHostedInitialFrameApplied;
@property (nonatomic, assign) BOOL systemHostedServerFrameCanonicalized;
@property (nonatomic, copy) NSString *pendingRemnantReconnectBundleId;
@property (nonatomic, copy) NSString *remnantReconnectClaimBundleId;
@property (nonatomic, copy) NSString *ownedCanonicalSceneAwaitingLeaseBundleId;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *bootstrappedProcessPIDs;
@property (nonatomic, assign) BOOL ios26HostedContentRecoveryPending;
@property (nonatomic, assign) NSUInteger ios26HostedContentRecoveryToken;
@property (nonatomic, assign) BOOL ios26HostedContentAwaitingInvalidation;
@property (nonatomic, assign) BOOL ios26HostedContentUnavailableNotified;
@property (nonatomic, assign) CFTimeInterval ios26HostedContentStableSince;
- (void)acquireProcessAssertionForBundleId:(NSString *)bundleId;
- (void)releaseProcessAssertion;
- (int)pidForBundleId:(NSString *)bundleId;
- (UIInterfaceOrientation)preferredHostedInterfaceOrientation;
- (UIInterfaceOrientation)surfaceSourceOrientationForScene:(FBScene *)scene bundleId:(NSString *)bundleId;
- (BOOL)isHostedGeometryReadyForScene:(FBScene *)scene bundleId:(NSString *)bundleId;
- (BOOL)isHostedSceneContentReadyForPublication:(FBScene *)scene;
- (BOOL)setForeground:(BOOL)foreground forScene:(FBScene *)scene;
- (void)finishForegroundActivationForScene:(FBScene *)scene
                                  bundleId:(NSString *)bundleId
                                generation:(NSUInteger)generation;
- (BOOL)shouldRetainHostedServerFrameForScene:(FBScene *)scene;
- (BOOL)usesIOS15PresentationOnlyRuntimeSourceRebaseForScene:(FBScene *)scene;
- (void)enforceHostedServerFrameOnSettings:(id)settings scene:(FBScene *)scene;
- (void)restoreSystemInterfaceOrientationForScene:(FBScene *)scene bundleId:(NSString *)bundleId;
- (void)captureSystemHostedSettingsIfNeededForScene:(FBScene *)scene;
- (void)prepareSystemHostedInitialGeometryIfNeededForScene:(FBScene *)scene
                                                  bundleId:(NSString *)bundleId;
- (void)canonicalizeSystemHostedSceneServerFrameIfNeededForScene:(FBScene *)scene;
- (BOOL)restoreSystemHostedSettingsSnapshotIfPossibleForScene:(FBScene *)scene;
- (void)clearSystemHostedSettingsSnapshot;
- (void)applySceneSettingsObject:(id)settings toScene:(FBScene *)scene;
- (void)mutateSettingsForScene:(FBScene *)scene
                     withBlock:(void (^)(id settings))block
                    completion:(dispatch_block_t)completion;
- (void)mutateSettingsForScene:(FBScene *)scene
                     withBlock:(void (^)(id settings))block
             transitionContext:(id)transitionContext
                    completion:(dispatch_block_t)completion;
- (void)scheduleHostedOrientationPublicationForScene:(FBScene *)scene;
- (void)handleHostedClientSettingsUpdateForScene:(FBScene *)scene
                               transitionContext:(id)transitionContext;
- (id)systemOrientationAnimationParameters;
- (void)startObservingHostedSceneEvents:(FBScene *)scene;
- (void)stopObservingHostedSceneEvents;
- (void)ensureLeaseResourcesForScene:(FBScene *)scene
                            bundleId:(NSString *)bundleId
                          generation:(NSUInteger)generation;
- (void)canonicalizeOwnedHostedSceneServerFrameIfNeededForScene:(FBScene *)scene;
- (void)publishUpdatedSceneStacks;
- (void)releaseForegroundLeaseForceBackgroundFormerHost:(BOOL)forceBackgroundFormerHost
                                      discardOwnedScene:(BOOL)discardOwnedScene;
- (void)invalidateIOS26PresentationContainersInSceneStack:(UIView *)sceneStack;
- (BOOL)isCanonicalDefaultScene:(FBScene *)scene bundleId:(NSString *)bundleId;
- (FBScene *)canonicalDefaultSceneForBundleId:(NSString *)bundleId;
- (void)relinquishOwnedHostedSceneCacheForBundleId:(NSString *)bundleId;
- (void)invalidateStaleCanonicalSceneWithoutProcess:(FBScene *)scene bundleId:(NSString *)bundleId;
- (void)scheduleIOS26HostedContentRecoveryForScene:(FBScene *)scene
                                          bundleId:(NSString *)bundleId
                                        generation:(NSUInteger)generation
                                             token:(NSUInteger)token
                                           attempt:(NSUInteger)attempt;
@end

@implementation ContextHostManager

static BOOL POMainLayerIdentitiesEqual(NSArray<FBSceneLayer *> *lhs,
                                       NSArray<FBSceneLayer *> *rhs) {
    if (lhs == rhs) {
        return YES;
    }
    if (lhs.count != rhs.count) {
        return NO;
    }
    for (NSUInteger index = 0; index < lhs.count; index++) {
        if (lhs[index] != rhs[index]) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - public methods
+ (instancetype)sharedInstance{
    static dispatch_once_t onceToken;
    static ContextHostManager *sharedInstance = nil;
    dispatch_once(&onceToken, ^{
        sharedInstance = [ContextHostManager new];
    });
    return sharedInstance;
}

- (void)setPresentationInterfaceOrientation:(UIInterfaceOrientation)orientation {
    _presentationInterfaceOrientation = orientation;
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 ||
        !self.publishedSceneStack ||
        !POIsConcreteInterfaceOrientation(self.publishedSceneStackOrientation) ||
        !POIsConcreteInterfaceOrientation(orientation)) {
        return;
    }
    if (self.ios26PresentationContainer) {
        SEL setContextSelector = NSSelectorFromString(@"_setPresentationContext:");
        id context = POCreateIOS26ScenePresentationContext(self.publishedSceneStackOrientation,
                                                           orientation);
        if (context && [self.ios26PresentationContainer respondsToSelector:setContextSelector]) {
            UIView *container = self.ios26PresentationContainer;
            UIView *sceneStack = self.publishedSceneStack;
            [UIView performWithoutAnimation:^{
                self.ios26PresentationContext = context;
                ((void (*)(id, SEL, id))objc_msgSend)(container, setContextSelector, context);
                container.frame = sceneStack.bounds;
                [container setNeedsLayout];
                [container layoutIfNeeded];
                PONormalizeIOS26PresentationContainerGeometry(container);
            }];
            self.forceNextPublishedSceneStackRebuild = NO;
            return;
        }

        self.forceNextPublishedSceneStackRebuild = YES;
        [self refreshPresentationForCurrentOrientation];
        return;
    }
    for (UIView *hostView in self.publishedSceneStack.subviews) {
        POApplyIOS26HostTransformer(hostView, self.publishedSceneStackOrientation, orientation);
    }
}

- (void)refreshPresentationForCurrentOrientation {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 ||
        !self.forceNextPublishedSceneStackRebuild ||
        !self.publishedSceneStack ||
        !self.ios26PresentationContainer) {
        return;
    }
    [self publishUpdatedSceneStacks];
}

- (id)backgroundView {
    return nil;
}

- (id)identifier {
    return self.hostedBundleId ?: kPORequester;
}

- (id)presentationContextForSceneLayerHostContainerView {
    return self.ios26PresentationContext;
}

- (void)invalidateIOS26PresentationContainersInSceneStack:(UIView *)sceneStack {
    if (!sceneStack) {
        return;
    }
    POInvalidateIOS26SceneLayerHostContainersInView(sceneStack);
    UIView *container = self.ios26PresentationContainer;
    if (container && [container isDescendantOfView:sceneStack]) {
        [container removeFromSuperview];
        self.ios26PresentationContainer = nil;
        self.ios26PresentationContext = nil;
    }
}

- (void)recoverIOS26HostedContentAfterOrientationChange {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 ||
        !self.isForegroundLeaseActive || !self.hostedScene ||
        self.activeLeaseGeneration == 0) {
        return;
    }

    FBScene *scene = self.hostedScene;
    NSString *bundleId = [self.hostedBundleId copy];
    NSUInteger generation = self.activeLeaseGeneration;
    if (self.ios26HostedContentRecoveryPending) {
        return;
    }
    if ([self sceneHasRenderableMainLayer:scene] &&
        [self isHostedSceneContentReadyForPublication:scene]) {
        self.ios26HostedContentAwaitingInvalidation = YES;
        return;
    }
    self.ios26HostedContentAwaitingInvalidation = NO;
    self.ios26HostedContentRecoveryPending = YES;
    self.ios26HostedContentStableSince = 0;
    NSUInteger token = ++self.ios26HostedContentRecoveryToken;

    [self setForeground:YES forScene:scene];
    [self scheduleIOS26HostedContentRecoveryForScene:scene
                                             bundleId:bundleId
                                           generation:generation
                                                token:token
                                              attempt:0];
}

- (void)scheduleIOS26HostedContentRecoveryForScene:(FBScene *)scene
                                          bundleId:(NSString *)bundleId
                                        generation:(NSUInteger)generation
                                             token:(NSUInteger)token
                                           attempt:(NSUInteger)attempt {
    static const NSTimeInterval delays[] = {
        0.016, 0.033, 0.066, 0.12, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0
    };
    static const NSUInteger delayCount = sizeof(delays) / sizeof(delays[0]);
    if (attempt >= delayCount) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delays[attempt] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.ios26HostedContentRecoveryPending ||
            strongSelf.ios26HostedContentRecoveryToken != token ||
            !strongSelf.isForegroundLeaseActive || strongSelf.hostedScene != scene ||
            strongSelf.activeLeaseGeneration != generation ||
            ![strongSelf.hostedBundleId isEqualToString:bundleId]) {
            return;
        }

        BOOL hasRenderableMainLayer = [strongSelf sceneHasRenderableMainLayer:scene];
        BOOL contentReady = [strongSelf isHostedSceneContentReadyForPublication:scene];
        if (!hasRenderableMainLayer || !contentReady) {
            [strongSelf scheduleIOS26HostedContentRecoveryForScene:scene
                                                            bundleId:bundleId
                                                          generation:generation
                                                               token:token
                                                             attempt:attempt + 1];
            return;
        }

        [strongSelf publishUpdatedSceneStacks];
    });
}

+ (NSString *)activeHostedBundleId{
    ContextHostManager *manager = [self sharedInstance];
    return manager.isForegroundLeaseActive ? manager.hostedBundleId : nil;
}

- (NSString *)activeHostedBundleId{
    return self.isForegroundLeaseActive ? self.hostedBundleId : nil;
}

+ (BOOL)shouldKeepForegroundForIdentifier:(NSString *)identifier{
    if (identifier.length == 0) {
        return NO;
    }
    POSplitSessionController *splitSession = [POSplitSessionController sharedInstance];
    if (splitSession.isActive && splitSession.baseSceneRequiresForegroundProtection &&
        splitSession.baseSceneIdentifier.length > 0 &&
        [identifier isEqualToString:splitSession.baseSceneIdentifier]) {
        return YES;
    }
    ContextHostManager *manager = [self sharedInstance];
    if (!manager.isForegroundLeaseActive) {
        return NO;
    }
    NSString *bundleId = manager.hostedBundleId;
    if (bundleId.length == 0) {
        return NO;
    }
    return POSceneIdentifierMatchesBundleIdentifier(identifier, bundleId);
}

+ (BOOL)shouldKeepForegroundForScene:(FBScene *)scene{
    if (!scene) {
        return NO;
    }
    POSplitSessionController *splitSession = [POSplitSessionController sharedInstance];
    if (splitSession.baseSceneRequiresForegroundProtection && [splitSession matchesBaseScene:scene]) {
        return YES;
    }
    ContextHostManager *manager = [self sharedInstance];
    if (!manager.isForegroundLeaseActive) {
        return NO;
    }
    if (manager.hostedScene == scene) {
        return YES;
    }
    NSString *identifier = nil;
    if ([scene respondsToSelector:@selector(identifier)]) {
        identifier = [scene identifier];
    }
    return [self shouldKeepForegroundForIdentifier:identifier];
}

+ (id)prepareNativeSceneSettingsIfNeeded:(id)settings forScene:(FBScene *)scene {
    ContextHostManager *manager = [self sharedInstance];
    if (!settings || !scene || manager.isForegroundLeaseActive ||
        scene != manager.ownedHostedScene || manager.ownedHostedBundleId.length == 0) {
        return settings;
    }
    BOOL foreground = NO;
    SEL foregroundSelector = NSSelectorFromString(@"isForeground");
    if ([settings respondsToSelector:foregroundSelector]) {
        foreground = ((BOOL (*)(id, SEL))objc_msgSend)(settings, foregroundSelector);
    }
    if (!foreground) {
        return settings;
    }

    NSString *bundleId = [manager.ownedHostedBundleId copy];
    if (![manager isCanonicalDefaultScene:scene bundleId:bundleId]) {
        return settings;
    }
    if ([manager.ownedCanonicalSceneAwaitingLeaseBundleId isEqualToString:bundleId]) {
        return settings;
    }

    id mutableSettings = [settings mutableCopy] ?: settings;
    CGRect canonicalFrame = POCanonicalApplicationSceneFrame(mutableSettings);
    SEL setFrameSelector = NSSelectorFromString(@"setFrame:");
    if ([mutableSettings respondsToSelector:setFrameSelector]) {
        ((void (*)(id, SEL, CGRect))objc_msgSend)(mutableSettings, setFrameSelector, canonicalFrame);
    }
    POClearHostedOrientationMapFromSettings(mutableSettings);

    UIInterfaceOrientation requestedOrientation = POInterfaceOrientationFromSettings(mutableSettings);
    UIInterfaceOrientationMask supportedMask = [POApplicationHelper supportedInterfaceOrientationsForBundleId:bundleId];
    if (!POOrientationMaskContainsOrientation(supportedMask, requestedOrientation)) {
        UIInterfaceOrientation nativeOrientation = [POApplicationHelper preferredHostedInterfaceOrientationForBundleId:bundleId];
        if (POIsConcreteInterfaceOrientation(nativeOrientation)) {
            POSetInterfaceOrientationOnSettings(mutableSettings, nativeOrientation);
        }
    }

    [manager relinquishOwnedHostedSceneCacheForBundleId:bundleId];
    return mutableSettings;
}

+ (id)primePendingSceneRemnantSettings:(id)settings remnant:(id)remnant {
    ContextHostManager *manager = [self sharedInstance];
    NSString *bundleId = manager.pendingRemnantReconnectBundleId;
    if (!settings || !remnant || bundleId.length == 0) {
        return settings;
    }

    NSString *settingsIdentity = POSceneIdentityStringFromSettings(settings);
    BOOL matches = POSceneIdentifierMatchesBundleIdentifier(settingsIdentity, bundleId) ||
        POObjectShallowGraphMentionsBundleIdentifier(remnant, bundleId);
    if (!matches) {
        return settings;
    }

    UIInterfaceOrientation targetOrientation = [manager preferredHostedInterfaceOrientationForBundleId:bundleId];
    if (!POIsConcreteInterfaceOrientation(targetOrientation) ||
        ![manager requiresOwnedHostedSceneForBundleId:bundleId]) {
        manager.pendingRemnantReconnectBundleId = nil;
        return settings;
    }

    id mutableSettings = [settings mutableCopy] ?: settings;
    CGSize sceneSize = POHostedCanvasSizeForOrientation(targetOrientation);
    CGRect sceneFrame = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15
        ? POCanonicalApplicationSceneFrame(mutableSettings)
        : (CGRect){ CGPointZero, sceneSize };
    SEL setFrameSelector = NSSelectorFromString(@"setFrame:");
    if ([mutableSettings respondsToSelector:setFrameSelector]) {
        ((void (*)(id, SEL, CGRect))objc_msgSend)(mutableSettings, setFrameSelector, sceneFrame);
    }
    if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
        [mutableSettings setForeground:YES];
    }
    if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
        [mutableSettings setBackgrounded:NO];
    }
    if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
        [mutableSettings setDeactivationReasons:0];
    }
    POSetInterfaceOrientationOnSettings(mutableSettings, targetOrientation);
    POApplyCrossOrientationMapToSettings(mutableSettings, targetOrientation);
    manager.remnantReconnectClaimBundleId = [bundleId copy];
    return mutableSettings;
}

+ (void)completePendingSceneRemnantReconnect:(FBScene *)scene {
    ContextHostManager *manager = [self sharedInstance];
    NSString *bundleId = manager.remnantReconnectClaimBundleId;
    if (bundleId.length == 0) {
        return;
    }

    NSString *identifier = scene && [scene respondsToSelector:@selector(identifier)]
        ? [scene identifier]
        : nil;
    BOOL matches = scene && POSceneIdentifierMatchesBundleIdentifier(identifier, bundleId);
    if (matches) {
        if (manager.ownedHostedScene && manager.ownedHostedScene != scene) {
            NSString *oldBundleId = [manager.ownedHostedBundleId copy];
            if ([manager isCanonicalDefaultScene:manager.ownedHostedScene bundleId:oldBundleId]) {
                [manager relinquishOwnedHostedSceneCacheForBundleId:oldBundleId];
            } else {
                [manager abandonOwnedHostedSceneForBundleId:oldBundleId];
            }
        }
        manager.ownedHostedScene = scene;
        manager.ownedHostedBundleId = [bundleId copy];
        manager.ownedHostedSceneServerFrameCanonicalized =
            NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15;
        manager.ownedHostedSceneCapabilityProven = NO;
        manager.ownedHostedProcessPID = [manager pidForBundleId:bundleId];
        manager.ownedCanonicalSceneAwaitingLeaseBundleId = [bundleId copy];
        manager.pendingRemnantReconnectBundleId = nil;
    }
    manager.remnantReconnectClaimBundleId = nil;
}

+ (void)reconcileHostedInterfaceOrientationInSettings:(id)settings forScene:(FBScene *)scene {
    ContextHostManager *manager = [self sharedInstance];
    if (!manager.isForegroundLeaseActive || scene != manager.hostedScene) {
        return;
    }
    UIInterfaceOrientation staticOrientation =
        [manager preferredHostedInterfaceOrientationForBundleId:manager.hostedBundleId];
    UIInterfaceOrientation desiredOrientation = POIsConcreteInterfaceOrientation(manager.hostedInterfaceOrientation)
        ? manager.hostedInterfaceOrientation
        : staticOrientation;

    if (manager.runtimeHostedOrientationAuthorityActive) {
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
            POSetDeviceOrientationOnSettings(settings, POCurrentSystemInterfaceOrientation());
        }
        [manager enforceHostedServerFrameOnSettings:settings scene:scene];
        return;
    }

    if (!POIsConcreteInterfaceOrientation(desiredOrientation)) {
        return;
    }

    BOOL orientationChanged = desiredOrientation != manager.hostedInterfaceOrientation;
    if (orientationChanged) {
        manager.hostedInterfaceOrientation = desiredOrientation;
    }
    POSetInterfaceOrientationOnSettings(settings, desiredOrientation);
    [manager enforceHostedServerFrameOnSettings:settings scene:scene];
    if (!orientationChanged) {
        return;
    }

    [manager scheduleHostedOrientationPublicationForScene:scene];

    NSUInteger generation = manager.activeLeaseGeneration;
    __weak ContextHostManager *weakManager = manager;
    dispatch_async(dispatch_get_main_queue(), ^{
        ContextHostManager *strongManager = weakManager;
        if (!strongManager || !strongManager.isForegroundLeaseActive ||
            strongManager.activeLeaseGeneration != generation || strongManager.hostedScene != scene ||
            strongManager.hostedInterfaceOrientation != desiredOrientation) {
            return;
        }
        id<ContextHostManagerExternalSceneDelegate> delegate = strongManager.sceneDelegate;
        if ([delegate respondsToSelector:@selector(contextManager:scene:hostedInterfaceOrientationDidChange:systemAnimationParameters:hostGeneration:)]) {
            [delegate contextManager:strongManager
                               scene:scene
 hostedInterfaceOrientationDidChange:desiredOrientation
           systemAnimationParameters:nil
                      hostGeneration:generation];
        }
    });
}

- (BOOL)isHostedGeometryReadyForScene:(FBScene *)scene bundleId:(NSString *)bundleId {
    UIInterfaceOrientation desiredOrientation = self.hostedInterfaceOrientation;
    BOOL usesIOS15GeometryContract =
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15;
    UIInterfaceOrientation systemOrientation = POCurrentSystemInterfaceOrientation();
    if (!POIsConcreteInterfaceOrientation(desiredOrientation) ||
        POOrientationCategoriesMatch(systemOrientation, desiredOrientation)) {
        return YES;
    }

    UIInterfaceOrientationMask declaredMask = usesIOS15GeometryContract
        ? 0
        : [POApplicationHelper supportedInterfaceOrientationsForBundleId:bundleId];
    id clientSettings = nil;
    SEL clientSettingsSelector = NSSelectorFromString(@"clientSettings");
    if ([scene respondsToSelector:clientSettingsSelector]) {
        clientSettings = ((id (*)(id, SEL))objc_msgSend)(scene, clientSettingsSelector);
    }
    SEL orientationSelector = NSSelectorFromString(@"sb_effectiveInterfaceOrientation");
    SEL fallbackOrientationSelector = NSSelectorFromString(@"interfaceOrientation");
    SEL supportedSelector = NSSelectorFromString(@"supportedInterfaceOrientations");
    UIInterfaceOrientation effectiveOrientation = UIInterfaceOrientationUnknown;
    if ([clientSettings respondsToSelector:orientationSelector]) {
        effectiveOrientation = (UIInterfaceOrientation)((NSInteger (*)(id, SEL))objc_msgSend)(clientSettings,
                                                                                              orientationSelector);
    }
    if (!POIsConcreteInterfaceOrientation(effectiveOrientation) &&
        [clientSettings respondsToSelector:fallbackOrientationSelector]) {
        effectiveOrientation = (UIInterfaceOrientation)((NSInteger (*)(id, SEL))objc_msgSend)(clientSettings,
                                                                                              fallbackOrientationSelector);
    }
    UIInterfaceOrientationMask clientMask = [clientSettings respondsToSelector:supportedSelector]
        ? (UIInterfaceOrientationMask)((NSUInteger (*)(id, SEL))objc_msgSend)(clientSettings, supportedSelector)
        : 0;
    if (!usesIOS15GeometryContract && clientMask == 0) {
        clientMask = declaredMask;
    }
    UIInterfaceOrientation preferredOrientation =
        POPreferredInterfaceOrientationFromClientSettings(clientSettings);
    UIInterfaceOrientation clientOrientation = UIInterfaceOrientationUnknown;
    if (POIsConcreteInterfaceOrientation(effectiveOrientation) &&
        (clientMask == 0 || POOrientationMaskContainsOrientation(clientMask, effectiveOrientation))) {
        clientOrientation = effectiveOrientation;
    } else if (POIsConcreteInterfaceOrientation(preferredOrientation) &&
               (clientMask == 0 || POOrientationMaskContainsOrientation(clientMask, preferredOrientation))) {
        clientOrientation = preferredOrientation;
    }

    UIInterfaceOrientation serverOrientation = UIInterfaceOrientationUnknown;
    @try {
        id sceneSettings = [scene respondsToSelector:@selector(settings)] ? [scene settings] : nil;
        serverOrientation = POInterfaceOrientationFromSettings(sceneSettings);
    } @catch (NSException *exception) {
    }

    BOOL clientOrientationCompatible =
        POOrientationCategoriesMatch(clientOrientation, desiredOrientation);
    BOOL serverOrientationCompatible = self.runtimeHostedOrientationAuthorityActive ||
        !POIsConcreteInterfaceOrientation(serverOrientation) ||
        POOrientationCategoriesMatch(serverOrientation, desiredOrientation);
    return clientOrientationCompatible && serverOrientationCompatible;
}

- (BOOL)isHostedSceneContentReadyForPublication:(FBScene *)scene {
    if (!scene) {
        return NO;
    }
    SEL contentStateSelector = NSSelectorFromString(@"contentState");
    if (![scene respondsToSelector:contentStateSelector]) {
        return YES;
    }
    NSInteger contentState = ((NSInteger (*)(id, SEL))objc_msgSend)(scene, contentStateSelector);
    if (contentState == 2) {
        return YES;
    }
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 &&
        contentState == 1 && !self.runtimeHostedOrientationAuthorityActive &&
        [self shouldRetainHostedServerFrameForScene:scene] &&
        [self sceneHasRenderableMainLayer:scene]) {
        return YES;
    }
    return NO;
}

-(FBScene *)probeSceneForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return nil;
    }
    if (self.ownedHostedScene && [self.ownedHostedBundleId isEqualToString:bundleId]) {
        BOOL valid = ![self.ownedHostedScene respondsToSelector:@selector(isValid)] ||
            [(id)self.ownedHostedScene isValid];
        BOOL processAlive = [self isProcessRunningForBundleId:bundleId];
        if (valid && processAlive) {
            return self.ownedHostedScene;
        }
        [self abandonOwnedHostedSceneForBundleId:bundleId];
    }
    FBScene *scene = [self sceneForBundleId:bundleId];
    if (scene && [scene respondsToSelector:@selector(isValid)] && ![(id)scene isValid]) {
        return nil;
    }
    if (scene) {
        [self.bootstrappedProcessPIDs removeObjectForKey:bundleId];
    }
    return scene;
}

-(BOOL)isProcessRunningForBundleId:(NSString *)bundleId{
    return bundleId.length > 0 && [self pidForBundleId:bundleId] > 0;
}

-(int)processIdentifierForBundleId:(NSString *)bundleId{
    return bundleId.length > 0 ? [self pidForBundleId:bundleId] : 0;
}

-(UIInterfaceOrientation)preferredHostedInterfaceOrientationForBundleId:(NSString *)bundleId{
    UIInterfaceOrientation systemOrientation = POCurrentSystemInterfaceOrientation();
    UIInterfaceOrientationMask supportedMask = [POApplicationHelper supportedInterfaceOrientationsForBundleId:bundleId];
    BOOL supportsPortrait =
        (supportedMask & (UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown)) != 0;
    BOOL supportsLandscape = (supportedMask & UIInterfaceOrientationMaskLandscape) != 0;
    if (!supportsPortrait && supportsLandscape && UIInterfaceOrientationIsLandscape(systemOrientation) &&
        POOrientationMaskContainsOrientation(supportedMask, systemOrientation)) {
        return systemOrientation;
    }
    return [POApplicationHelper preferredHostedInterfaceOrientationForBundleId:bundleId];
}

-(BOOL)requiresCrossOrientationHostingForBundleId:(NSString *)bundleId{
    UIInterfaceOrientation systemOrientation = POCurrentSystemInterfaceOrientation();
    UIInterfaceOrientation targetOrientation = [self preferredHostedInterfaceOrientationForBundleId:bundleId];
    return POIsConcreteInterfaceOrientation(systemOrientation) &&
        POIsConcreteInterfaceOrientation(targetOrientation) &&
        !POOrientationCategoriesMatch(systemOrientation, targetOrientation);
}

-(BOOL)requiresOwnedHostedSceneForBundleId:(NSString *)bundleId{
    if (![self requiresCrossOrientationHostingForBundleId:bundleId]) {
        return NO;
    }
    UIInterfaceOrientation targetOrientation = [self preferredHostedInterfaceOrientationForBundleId:bundleId];
    if (!POIsConcreteInterfaceOrientation(targetOrientation)) {
        return NO;
    }
    CGSize hostedCanvas = POHostedCanvasSizeForOrientation(targetOrientation);
    CGSize canonicalCanvas = POCanonicalApplicationSceneFrame(nil).size;
    return !POSceneSizesMatch(hostedCanvas, canonicalCanvas);
}

-(void)requestProcessBootstrapForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId] ||
        [self isProcessRunningForBundleId:bundleId]) {
        return;
    }
    @try {
        RBSProcessIdentity *identity = [RBSProcessIdentity identityForEmbeddedApplicationIdentifier:bundleId];
        FBMutableProcessExecutionContext *context = [FBMutableProcessExecutionContext new];
        [context setIdentity:identity];

        FBProcessManager *processManager = [FBProcessManager sharedInstance];
        id process = nil;
        SEL modernBootstrapSelector = NSSelectorFromString(@"_bootstrapProcessWithExecutionContext:synchronously:error:");
        SEL legacyBootstrapSelector = NSSelectorFromString(@"_bootstrapProcessWithIdentity:executionContext:");
        if ([processManager respondsToSelector:modernBootstrapSelector]) {
            NSError *error = nil;
            BOOL synchronousBootstrap =
                NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 15;
            process = ((id (*)(id, SEL, id, BOOL, NSError **))objc_msgSend)(
                processManager, modernBootstrapSelector, context, synchronousBootstrap, &error);
        } else if ([processManager respondsToSelector:legacyBootstrapSelector]) {
            process = ((id (*)(id, SEL, id, id))objc_msgSend)(
                processManager, legacyBootstrapSelector, identity, context);
        }

        int pid = 0;
        SEL pidSelector = NSSelectorFromString(@"pid");
        if ([process respondsToSelector:pidSelector]) {
            pid = ((int (*)(id, SEL))objc_msgSend)(process, pidSelector);
        }
        if (pid <= 0) {
            pid = [self pidForBundleId:bundleId];
        }
        if (process && pid > 0) {
            if (!self.bootstrappedProcessPIDs) {
                self.bootstrappedProcessPIDs = [NSMutableDictionary dictionary];
            }
            self.bootstrappedProcessPIDs[bundleId] = @(pid);
            if (self.ownedHostedScene && [self.ownedHostedBundleId isEqualToString:bundleId]) {
                self.ownedHostedProcessPID = pid;
            }
        }
    } @catch (NSException *exception) {
    }
}

-(void)requestPreparationForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }
    if ([self requiresOwnedHostedSceneForBundleId:bundleId]) {
        [self requestProcessBootstrapForBundleId:bundleId];
        return;
    }
    [self requestSystemDefaultScenePreparationForBundleId:bundleId];
}

-(void)requestSystemDefaultScenePreparationForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }
    if ([self.pendingRemnantReconnectBundleId isEqualToString:bundleId]) {
        self.pendingRemnantReconnectBundleId = nil;
        self.remnantReconnectClaimBundleId = nil;
    }
    [[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleId suspended:YES];
}

-(void)requestCrossOrientationSystemDefaultScenePreparationForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }
    [self prepareHostingIntentForBundleId:bundleId];
    [[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleId suspended:YES];
}

-(void)prepareHostingIntentForBundleId:(NSString *)bundleId{
    self.pendingRemnantReconnectBundleId = nil;
    self.remnantReconnectClaimBundleId = nil;
    self.ownedCanonicalSceneAwaitingLeaseBundleId = nil;
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }

    if (self.isForegroundLeaseActive && [self.hostedBundleId isEqualToString:bundleId]) {
        BOOL processAlive = [self isProcessRunningForBundleId:bundleId];
        BOOL sceneValid = self.hostedScene != nil &&
            (![self.hostedScene respondsToSelector:@selector(isValid)] || [(id)self.hostedScene isValid]);
        if (!processAlive || !sceneValid) {
            [self releaseForegroundLeaseForceBackgroundFormerHost:YES discardOwnedScene:YES];
        }
    }

    POSetCameraForegroundGrantBundleIdentifier(bundleId);

    if (self.ownedHostedScene && ![self.ownedHostedBundleId isEqualToString:bundleId]) {
        NSString *oldBundleId = [self.ownedHostedBundleId copy];
        if ([self isCanonicalDefaultScene:self.ownedHostedScene bundleId:oldBundleId]) {
            [self relinquishOwnedHostedSceneCacheForBundleId:oldBundleId];
        } else {
            [self abandonOwnedHostedSceneForBundleId:oldBundleId];
        }
    }

    if (![self requiresOwnedHostedSceneForBundleId:bundleId]) {
        return;
    }

    BOOL processRunning = [self isProcessRunningForBundleId:bundleId];
    if (!processRunning) {
        self.pendingRemnantReconnectBundleId = [bundleId copy];
    }
    FBScene *existingScene = [self canonicalDefaultSceneForBundleId:bundleId];
    BOOL validExistingScene = existingScene != nil &&
        (![existingScene respondsToSelector:@selector(isValid)] || [(id)existingScene isValid]);

    if (processRunning && validExistingScene) {
        return;
    }

    if (!processRunning && validExistingScene) {
        [self invalidateStaleCanonicalSceneWithoutProcess:existingScene bundleId:bundleId];
    }
}

-(BOOL)isOwnedHostedScene:(FBScene *)scene bundleId:(NSString *)bundleId{
    return scene && scene == self.ownedHostedScene && bundleId.length > 0 &&
        [self.ownedHostedBundleId isEqualToString:bundleId];
}

-(FBScene *)createHostedSceneForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId] ||
        ![self requiresOwnedHostedSceneForBundleId:bundleId]) {
        return nil;
    }
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 &&
        ![self isProcessRunningForBundleId:bundleId]) {
        return nil;
    }
    if (self.ownedHostedScene && [self.ownedHostedBundleId isEqualToString:bundleId]) {
        BOOL valid = ![self.ownedHostedScene respondsToSelector:@selector(isValid)] ||
            [(id)self.ownedHostedScene isValid];
        if (valid && [self isProcessRunningForBundleId:bundleId]) {
            return self.ownedHostedScene;
        }
        [self abandonOwnedHostedSceneForBundleId:bundleId];
    }
    if (self.ownedHostedScene) {
        NSString *oldBundleId = [self.ownedHostedBundleId copy];
        if ([self isCanonicalDefaultScene:self.ownedHostedScene bundleId:oldBundleId]) {
            [self relinquishOwnedHostedSceneCacheForBundleId:oldBundleId];
        } else {
            [self abandonOwnedHostedSceneForBundleId:oldBundleId];
        }
    }

    UIInterfaceOrientation orientation = [self preferredHostedInterfaceOrientationForBundleId:bundleId];
    if (!POIsConcreteInterfaceOrientation(orientation)) {
        return nil;
    }

    FBScene *existingScene = [self canonicalDefaultSceneForBundleId:bundleId];
    NSString *existingIdentifier = [existingScene respondsToSelector:@selector(identifier)]
        ? [existingScene identifier]
        : nil;
    BOOL existingSceneValid = existingScene &&
        (![existingScene respondsToSelector:@selector(isValid)] || [(id)existingScene isValid]);
    BOOL existingSceneMatchesBundle =
        POSceneIdentifierMatchesBundleIdentifier(existingIdentifier, bundleId);
    if (existingSceneValid && existingSceneMatchesBundle) {
        id clientSettings = POClientSettingsForScene(existingScene);
        UIInterfaceOrientation clientOrientation = POEffectiveInterfaceOrientationFromClientSettings(clientSettings);
        if (!POIsConcreteInterfaceOrientation(clientOrientation)) {
            clientOrientation = POInterfaceOrientationFromSettings(clientSettings);
        }
        if (!POIsConcreteInterfaceOrientation(clientOrientation)) {
            clientOrientation = POPreferredInterfaceOrientationFromClientSettings(clientSettings);
        }

        BOOL clientCompatible = POIsConcreteInterfaceOrientation(clientOrientation) &&
            POOrientationCategoriesMatch(clientOrientation, orientation);
        if (clientCompatible) {
            BOOL canonicalDefault = [self isCanonicalDefaultScene:existingScene bundleId:bundleId];
            self.ownedHostedScene = existingScene;
            self.ownedHostedBundleId = [bundleId copy];
            self.ownedCanonicalSceneAwaitingLeaseBundleId = canonicalDefault ? [bundleId copy] : nil;
            self.ownedHostedSceneServerFrameCanonicalized =
                NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 && canonicalDefault;
            self.ownedHostedSceneCapabilityProven = NO;
            self.ownedHostedProcessPID = 0;
            return existingScene;
        }

        if (existingScene == self.systemHostedSnapshotScene) {
            [self clearSystemHostedSettingsSnapshot];
        }
        SEL invalidateSelector = NSSelectorFromString(@"invalidate");
        if ([existingScene respondsToSelector:invalidateSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(existingScene, invalidateSelector);
        }
    }

    @try {
        CGSize sceneSize = POHostedCanvasSizeForOrientation(orientation);

        FBSMutableSceneDefinition *definition = [FBSMutableSceneDefinition definition];
        NSString *identifier = [NSString stringWithFormat:@"sceneID:%@-default", bundleId];
        [definition setIdentity:[FBSSceneIdentity identityForIdentifier:identifier]];
        [definition setClientIdentity:[FBSSceneClientIdentity identityForBundleID:bundleId]];
        id specification = [UIApplicationSceneSpecification specification];
        [definition setSpecification:specification];

        FBSMutableSceneParameters *parameters = [FBSMutableSceneParameters parametersForSpecification:specification];
        UIMutableApplicationSceneSettings *settings = [UIMutableApplicationSceneSettings new];
        SEL displayConfigurationSelector = NSSelectorFromString(@"displayConfiguration");
        if ([UIScreen.mainScreen respondsToSelector:displayConfigurationSelector]) {
            id displayConfiguration = ((id (*)(id, SEL))objc_msgSend)(UIScreen.mainScreen,
                                                                      displayConfigurationSelector);
            [settings setDisplayConfiguration:displayConfiguration];
        }
        CGRect serverFrame = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15
            ? POCanonicalApplicationSceneFrame(settings)
            : (CGRect){ CGPointZero, sceneSize };
        [settings setFrame:serverFrame];
        [settings setForeground:YES];
        if ([settings respondsToSelector:@selector(setBackgrounded:)]) {
            [settings setBackgrounded:NO];
        }
        [settings setDeviceOrientationEventsEnabled:YES];
        POSetInterfaceOrientationOnSettings(settings, orientation);
        POApplyCrossOrientationMapToSettings(settings, orientation);
        [parameters setSettings:settings];

        UIMutableApplicationSceneClientSettings *clientSettings =
            [UIMutableApplicationSceneClientSettings new];
        [clientSettings setInterfaceOrientation:orientation];
        [parameters setClientSettings:clientSettings];

        FBScene *scene = [[FBSceneManager sharedInstance] createSceneWithDefinition:definition
                                                                  initialParameters:parameters];
        if (!scene) {
            return nil;
        }
        self.ownedHostedScene = scene;
        self.ownedHostedBundleId = [bundleId copy];
        self.ownedCanonicalSceneAwaitingLeaseBundleId =
            [self isCanonicalDefaultScene:scene bundleId:bundleId] ? [bundleId copy] : nil;
        self.ownedHostedSceneServerFrameCanonicalized =
            NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15;
        self.ownedHostedSceneCapabilityProven = NO;
        NSNumber *bootstrappedPID = self.bootstrappedProcessPIDs[bundleId];
        int currentPID = [self pidForBundleId:bundleId];
        self.ownedHostedProcessPID = bootstrappedPID.intValue == currentPID ? currentPID : 0;
        return scene;
    } @catch (NSException *exception) {
        return nil;
    }
}

-(void)activateScene:(FBScene *)scene
         forBundleId:(NSString *)bundleId
          generation:(NSUInteger)generation{
    if (!scene || bundleId.length == 0 || generation == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }
    if ([self requiresOwnedHostedSceneForBundleId:bundleId] &&
        ![self isCanonicalDefaultScene:scene bundleId:bundleId]) {
        return;
    }
    if ([scene respondsToSelector:@selector(isValid)] && ![(id)scene isValid]) {
        return;
    }

    BOOL sameHostIdentity = self.isForegroundLeaseActive &&
        self.hostedScene == scene && [self.hostedBundleId isEqualToString:bundleId];
    if (sameHostIdentity) {
        BOOL generationChanged = self.activeLeaseGeneration != generation;
        if (generationChanged) {
            self.activeLeaseGeneration = generation;
            self.pendingRuntimeOrientationNotification = UIInterfaceOrientationUnknown;
            self.pendingRuntimeOrientationNotificationGeneration = 0;
        }
        BOOL orientationChanged = NO;
        if (!POIsConcreteInterfaceOrientation(self.hostedInterfaceOrientation)) {
            self.hostedInterfaceOrientation = [self preferredHostedInterfaceOrientation];
            orientationChanged = [self setForeground:YES forScene:scene];
        }

        [self ensureLeaseResourcesForScene:scene bundleId:bundleId generation:generation];
        FBSceneLayerManager *currentLayerManager = [self layerManagerForScene:scene];
        if (currentLayerManager) {
            if (self.hostedFallbackHostManager) {
                [self.hostedFallbackHostManager disableHostingForRequester:kPORequester];
                self.hostedFallbackHostManager = nil;
            }
            [self observeLayerManager:currentLayerManager];
            if (orientationChanged || ![self isHostedGeometryReadyForScene:scene bundleId:bundleId]) {
                [self scheduleHostedOrientationPublicationForScene:scene];
            } else {
                [self publishUpdatedSceneStacks];
            }
            return;
        }

        FBSceneHostManager *hostManager = self.hostedFallbackHostManager ?: [self hostManagerForScene:scene];
        if (hostManager) {
            [hostManager enableHostingForRequester:kPORequester orderFront:YES];
            UIView *hostView = [hostManager hostViewForRequester:kPORequester enableAndOrderFront:YES];
            if (hostView) {
                self.hostedFallbackHostManager = hostManager;
                id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
                if ([delegate respondsToSelector:@selector(contextManager:scene:sceneStackDidChange:hostGeneration:)]) {
                    [delegate contextManager:self scene:scene sceneStackDidChange:hostView hostGeneration:generation];
                }
            }
        }
        return;
    }

    if (self.isForegroundLeaseActive) {
        [self releaseForegroundLeaseForTargetSwitch];
    } else {
        [self releaseProcessAssertion];
        [self stopObservingLayerManager];
        if (self.hostedFallbackHostManager) {
            [self.hostedFallbackHostManager disableHostingForRequester:kPORequester];
        }
    }

    UIInterfaceOrientation activationTargetOrientation = [self preferredHostedInterfaceOrientation];

    self.foregroundLeaseActive = YES;
    self.activeLeaseGeneration = generation;
    self.hostedScene = scene;
    self.hostedBundleId = [bundleId copy];
    if (scene == self.ownedHostedScene &&
        [self.ownedCanonicalSceneAwaitingLeaseBundleId isEqualToString:bundleId]) {
        self.ownedCanonicalSceneAwaitingLeaseBundleId = nil;
    }
    POSetCameraForegroundGrantBundleIdentifier(bundleId);
    [self startObservingHostedSceneEvents:scene];
    self.hostedLayerManager = nil;
    self.hostedFallbackHostManager = nil;
    self.activeSurfaceSourceOrientation =
        [self surfaceSourceOrientationForScene:scene bundleId:bundleId];
    self.hostedInterfaceOrientation = POIsConcreteInterfaceOrientation(activationTargetOrientation)
        ? activationTargetOrientation
        : self.activeSurfaceSourceOrientation;

    BOOL restoringRetainedRuntimeContract =
        POIsConcreteInterfaceOrientation(self.hostedInterfaceOrientation) &&
        POIsConcreteInterfaceOrientation(self.activeSurfaceSourceOrientation) &&
        !POOrientationCategoriesMatch(self.hostedInterfaceOrientation,
                                      self.activeSurfaceSourceOrientation);
    self.runtimeHostedOrientationAuthorityActive = restoringRetainedRuntimeContract;
    self.runtimeClientOrientationBaselineEstablished =
        POIsConcreteInterfaceOrientation(PORuntimeInterfaceOrientationFromClientSettings(
            POClientSettingsForScene(scene)));
    self.retainedRuntimeSourceRebasePending = restoringRetainedRuntimeContract;
    self.pendingRuntimeOrientationNotification = UIInterfaceOrientationUnknown;
    self.pendingRuntimeOrientationNotificationGeneration = 0;
    if (scene == self.ownedHostedScene) {
        self.ownedHostedSceneServerFrameCanonicalized =
            NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15;
        [self clearSystemHostedSettingsSnapshot];
    } else {
        [self captureSystemHostedSettingsIfNeededForScene:scene];
    }

    id activationClientSettings = POClientSettingsForScene(scene);
    BOOL needsForegroundReconciliation =
        POClientOrientationContractNeedsForegroundReconciliation(
            activationClientSettings,
            self.hostedInterfaceOrientation);
    if (needsForegroundReconciliation) {
        __weak typeof(self) weakSelf = self;
        [self mutateSettingsForScene:scene withBlock:^(id settings){
            if ([settings respondsToSelector:@selector(setForeground:)]) {
                [settings setForeground:YES];
            }
            if ([settings respondsToSelector:@selector(setBackgrounded:)]) {
                [settings setBackgrounded:NO];
            }
        } completion:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isForegroundLeaseActive ||
                strongSelf.hostedScene != scene ||
                strongSelf.activeLeaseGeneration != generation ||
                ![strongSelf.hostedBundleId isEqualToString:bundleId]) {
                return;
            }
            [strongSelf finishForegroundActivationForScene:scene
                                                  bundleId:bundleId
                                                generation:generation];
        }];
        return;
    }

    [self finishForegroundActivationForScene:scene bundleId:bundleId generation:generation];
}

- (void)finishForegroundActivationForScene:(FBScene *)scene
                                  bundleId:(NSString *)bundleId
                                generation:(NSUInteger)generation {
    if (!scene || bundleId.length == 0 || generation == 0 ||
        !self.isForegroundLeaseActive || self.hostedScene != scene ||
        self.activeLeaseGeneration != generation ||
        ![self.hostedBundleId isEqualToString:bundleId]) {
        return;
    }

    BOOL orientationChanged = [self setForeground:YES forScene:scene];
    [self ensureLeaseResourcesForScene:scene bundleId:bundleId generation:generation];

    FBSceneLayerManager *layerManager = [self layerManagerForScene:scene];
    if (layerManager) {
        [self observeLayerManager:layerManager];
        if (orientationChanged || ![self isHostedGeometryReadyForScene:scene bundleId:bundleId]) {
            [self scheduleHostedOrientationPublicationForScene:scene];
        } else {
            [self publishUpdatedSceneStacks];
        }
        return;
    }

    FBSceneHostManager *hostManager = [self hostManagerForScene:scene];
    if (hostManager) {
        [hostManager enableHostingForRequester:kPORequester orderFront:YES];
        UIView *hostView = [hostManager hostViewForRequester:kPORequester enableAndOrderFront:YES];
        if (hostView) {
            self.hostedFallbackHostManager = hostManager;
            id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
            if ([delegate respondsToSelector:@selector(contextManager:scene:sceneStackDidChange:hostGeneration:)]) {
                [delegate contextManager:self scene:scene sceneStackDidChange:hostView hostGeneration:generation];
            }
            [self ensureLeaseResourcesForScene:scene bundleId:bundleId generation:generation];
        }
    }
}

-(BOOL)isForegroundLeaseActiveForScene:(FBScene *)scene
                              bundleId:(NSString *)bundleId
                            generation:(NSUInteger)generation{
    return self.isForegroundLeaseActive && generation != 0 &&
        generation == self.activeLeaseGeneration && scene == self.hostedScene &&
        [self.hostedBundleId isEqualToString:bundleId];
}

-(void)releaseForegroundLease{
    [self releaseForegroundLeaseForceBackgroundFormerHost:NO discardOwnedScene:NO];
}

-(void)releaseForegroundLeaseDiscardingOwnedScene{
    self.pendingRemnantReconnectBundleId = nil;
    self.remnantReconnectClaimBundleId = nil;
    self.ownedCanonicalSceneAwaitingLeaseBundleId = nil;
    NSString *cachedOwnedBundleId = [self.ownedHostedBundleId copy];
    [self releaseForegroundLeaseForceBackgroundFormerHost:YES discardOwnedScene:YES];
    if (cachedOwnedBundleId.length > 0 && self.ownedHostedScene) {
        if ([self isCanonicalDefaultScene:self.ownedHostedScene bundleId:cachedOwnedBundleId]) {
            [self relinquishOwnedHostedSceneCacheForBundleId:cachedOwnedBundleId];
        } else {
            [self abandonOwnedHostedSceneForBundleId:cachedOwnedBundleId];
        }
    }
}

-(void)releaseForegroundLeaseForTargetSwitch{
    [self releaseForegroundLeaseForceBackgroundFormerHost:YES discardOwnedScene:YES];
}

-(BOOL)isCanonicalDefaultScene:(FBScene *)scene bundleId:(NSString *)bundleId{
    if (!scene || bundleId.length == 0) {
        return NO;
    }
    NSString *identifier = [scene respondsToSelector:@selector(identifier)] ? [scene identifier] : nil;
    if (identifier.length == 0) {
        return NO;
    }
    NSString *canonicalIdentifier = [NSString stringWithFormat:@"sceneID:%@-default", bundleId];
    NSString *bareCanonicalIdentifier = [NSString stringWithFormat:@"%@-default", bundleId];
    return [identifier isEqualToString:canonicalIdentifier] ||
        [identifier isEqualToString:bareCanonicalIdentifier];
}

- (FBScene *)canonicalDefaultSceneForBundleId:(NSString *)bundleId {
    if (bundleId.length == 0) {
        return nil;
    }

    Class sceneManagerClass = NSClassFromString(@"FBSceneManager");
    id sceneManager = [sceneManagerClass respondsToSelector:@selector(sharedInstance)]
        ? [sceneManagerClass sharedInstance]
        : nil;
    SEL lookupSelector = NSSelectorFromString(@"sceneWithIdentifier:");
    if (!sceneManager || ![sceneManager respondsToSelector:lookupSelector]) {
        return nil;
    }

    NSString *identifier = [NSString stringWithFormat:@"sceneID:%@-default", bundleId];
    FBScene *scene = ((FBScene *(*)(id, SEL, id))objc_msgSend)(sceneManager,
                                                                lookupSelector,
                                                                identifier);
    if (!scene || ![self isCanonicalDefaultScene:scene bundleId:bundleId]) {
        return nil;
    }
    if ([scene respondsToSelector:@selector(isValid)] && ![(id)scene isValid]) {
        return nil;
    }
    return scene;
}

-(void)relinquishOwnedHostedSceneCacheForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 || !self.ownedHostedScene ||
        ![self.ownedHostedBundleId isEqualToString:bundleId]) {
        return;
    }
    FBScene *scene = self.ownedHostedScene;
    if (![self isCanonicalDefaultScene:scene bundleId:bundleId]) {
        return;
    }

    self.ownedHostedScene = nil;
    self.ownedHostedBundleId = nil;
    self.ownedHostedProcessPID = 0;
    self.ownedHostedSceneServerFrameCanonicalized = NO;
    self.ownedHostedSceneCapabilityProven = NO;
    if ([self.ownedCanonicalSceneAwaitingLeaseBundleId isEqualToString:bundleId]) {
        self.ownedCanonicalSceneAwaitingLeaseBundleId = nil;
    }
    [self.bootstrappedProcessPIDs removeObjectForKey:bundleId];
    if (!self.isForegroundLeaseActive) {
        [self releaseProcessAssertion];
    }
}

-(void)invalidateStaleCanonicalSceneWithoutProcess:(FBScene *)scene bundleId:(NSString *)bundleId{
    if (!scene || bundleId.length == 0 || [self isProcessRunningForBundleId:bundleId]) {
        return;
    }
    if (scene == self.ownedHostedScene && [self.ownedHostedBundleId isEqualToString:bundleId]) {
        self.ownedHostedScene = nil;
        self.ownedHostedBundleId = nil;
        self.ownedHostedProcessPID = 0;
        self.ownedHostedSceneServerFrameCanonicalized = NO;
        self.ownedHostedSceneCapabilityProven = NO;
        [self releaseProcessAssertion];
    }
    [self.bootstrappedProcessPIDs removeObjectForKey:bundleId];
    SEL invalidateSelector = NSSelectorFromString(@"invalidate");
    if ([scene respondsToSelector:invalidateSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(scene, invalidateSelector);
    }
}

-(void)abandonOwnedHostedSceneForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0 || !self.ownedHostedScene ||
        ![self.ownedHostedBundleId isEqualToString:bundleId]) {
        return;
    }

    if (self.isForegroundLeaseActive && self.hostedScene == self.ownedHostedScene) {
        [self releaseForegroundLeaseForceBackgroundFormerHost:YES discardOwnedScene:YES];
        return;
    }

    FBScene *scene = self.ownedHostedScene;
    int ownedProcessPID = self.ownedHostedProcessPID;
    self.ownedHostedScene = nil;
    self.ownedHostedBundleId = nil;
    self.ownedHostedProcessPID = 0;
    self.ownedHostedSceneServerFrameCanonicalized = NO;
    self.ownedHostedSceneCapabilityProven = NO;
    if ([self.ownedCanonicalSceneAwaitingLeaseBundleId isEqualToString:bundleId]) {
        self.ownedCanonicalSceneAwaitingLeaseBundleId = nil;
    }

    NSNumber *bootstrappedPID = self.bootstrappedProcessPIDs[bundleId];
    if (bootstrappedPID.intValue == ownedProcessPID) {
        [self.bootstrappedProcessPIDs removeObjectForKey:bundleId];
    }

    SEL invalidateSelector = NSSelectorFromString(@"invalidate");
    if ([scene respondsToSelector:invalidateSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(scene, invalidateSelector);
    }
    if (ownedProcessPID > 0 && [self pidForBundleId:bundleId] == ownedProcessPID) {
        kill(ownedProcessPID, SIGKILL);
    }
}

- (void)releaseForegroundLeaseForceBackgroundFormerHost:(BOOL)forceBackgroundFormerHost
                                      discardOwnedScene:(BOOL)discardOwnedScene{
    FBScene *scene = self.hostedScene;
    NSString *hostedId = [self.hostedBundleId copy];
    self.ios26HostedContentRecoveryPending = NO;
    self.ios26HostedContentRecoveryToken += 1;
    self.ios26HostedContentAwaitingInvalidation = NO;
    self.ios26HostedContentUnavailableNotified = NO;
    if (forceBackgroundFormerHost || discardOwnedScene) {
        [self invalidateIOS26PresentationContainersInSceneStack:self.publishedSceneStack];
    }
    if ([self.pendingRemnantReconnectBundleId isEqualToString:hostedId]) {
        self.pendingRemnantReconnectBundleId = nil;
    }
    if ([self.remnantReconnectClaimBundleId isEqualToString:hostedId]) {
        self.remnantReconnectClaimBundleId = nil;
    }
    if ([self.ownedCanonicalSceneAwaitingLeaseBundleId isEqualToString:hostedId]) {
        self.ownedCanonicalSceneAwaitingLeaseBundleId = nil;
    }
    BOOL ownsScene = scene && scene == self.ownedHostedScene;
    int ownedProcessPID = ownsScene ? self.ownedHostedProcessPID : 0;
    POSetCameraForegroundGrantBundleIdentifier(nil);
    self.foregroundLeaseActive = NO;
    self.activeLeaseGeneration = 0;
    [self releaseProcessAssertion];
    [self stopObservingLayerManager];
    [self stopObservingHostedSceneEvents];
    if (self.hostedFallbackHostManager) {
        [self.hostedFallbackHostManager disableHostingForRequester:kPORequester];
    }

    self.hostedScene = nil;
    self.hostedLayerManager = nil;
    self.hostedFallbackHostManager = nil;
    self.hostedBundleId = nil;
    self.hostedInterfaceOrientation = UIInterfaceOrientationUnknown;
    self.activeSurfaceSourceOrientation = UIInterfaceOrientationUnknown;
    self.runtimeHostedOrientationAuthorityActive = NO;
    self.runtimeClientOrientationBaselineEstablished = NO;
    self.retainedRuntimeSourceRebasePending = NO;
    self.pendingRuntimeOrientationNotification = UIInterfaceOrientationUnknown;
    self.pendingRuntimeOrientationNotificationGeneration = 0;
    self.forceNextPublishedSceneStackRebuild = NO;
    BOOL shouldRestoreSystemSnapshot = !ownsScene &&
        (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 ||
         forceBackgroundFormerHost || discardOwnedScene);
    BOOL restoredSystemSnapshot = shouldRestoreSystemSnapshot &&
        [self restoreSystemHostedSettingsSnapshotIfPossibleForScene:scene];
    if (shouldRestoreSystemSnapshot && !restoredSystemSnapshot) {
        [self restoreSystemInterfaceOrientationForScene:scene bundleId:hostedId];
    }

    NSString *frontId = [POApplicationHelper frontMostBundleId];
    BOOL hostedIsFrontmost = hostedId.length > 0 && frontId.length > 0 &&
        ([hostedId isEqualToString:frontId] || [frontId isEqualToString:hostedId]);
    if (scene && (ownsScene || forceBackgroundFormerHost || !hostedIsFrontmost)) {
        [self setForeground:NO forScene:scene];
    }
    if (ownsScene && discardOwnedScene) {
        BOOL canonicalDefault = [self isCanonicalDefaultScene:scene bundleId:hostedId];
        self.ownedHostedScene = nil;
        self.ownedHostedBundleId = nil;
        self.ownedHostedProcessPID = 0;
        self.ownedHostedSceneServerFrameCanonicalized = NO;
        self.ownedHostedSceneCapabilityProven = NO;
        [self.bootstrappedProcessPIDs removeObjectForKey:hostedId];
        if (canonicalDefault) {

            [self mutateSettingsForScene:scene withBlock:^(id settings){
                CGRect canonicalFrame = POCanonicalApplicationSceneFrame(settings);
                SEL setFrameSelector = NSSelectorFromString(@"setFrame:");
                if ([settings respondsToSelector:setFrameSelector]) {
                    ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, setFrameSelector, canonicalFrame);
                }
                POClearHostedOrientationMapFromSettings(settings);
            }];
        } else {
            SEL invalidateSelector = NSSelectorFromString(@"invalidate");
            if ([scene respondsToSelector:invalidateSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(scene, invalidateSelector);
            }
            if (ownedProcessPID > 0 && [self pidForBundleId:hostedId] == ownedProcessPID) {
                kill(ownedProcessPID, SIGKILL);
            }
        }
    }
}

#pragma mark - scene helpers

- (FBScene *)sceneForBundleId:(NSString *)bundleId{
    Class fbm = NSClassFromString(@"FBSceneManager");
    id mgr = [fbm respondsToSelector:@selector(sharedInstance)] ? [fbm sharedInstance] : nil;
    __block FBScene *bestScene = nil;
    __block NSInteger bestScore = NSIntegerMin;

    if (mgr && [mgr respondsToSelector:@selector(enumerateScenesWithBlock:)] && bundleId) {
        [mgr enumerateScenesWithBlock:^(id scene, BOOL *stop) {
            NSString *ident = nil;
            if ([scene respondsToSelector:@selector(identifier)]) {
                ident = [scene identifier];
            }
            if (!POSceneIdentifierMatchesBundleIdentifier(ident, bundleId)) {
                return;
            }

            BOOL canonicalDefault = [self isCanonicalDefaultScene:scene bundleId:bundleId];
            NSInteger score = canonicalDefault
                ? 1000
                : ([ident hasPrefix:[bundleId stringByAppendingString:@"-"]] ? 100 : 10);
            if ([scene respondsToSelector:@selector(isValid)] && [scene isValid]) {
                score += 10;
            }
            if ([scene respondsToSelector:@selector(isActive)] && [scene isActive]) {
                score += 5;
            }
            if (score > bestScore) {
                bestScore = score;
                bestScene = scene;
            }
        }];
    }
    if (bestScene) {
        return bestScene;
    }

    SBApplication *app = applicationForID(bundleId);
    id appObject = app;
    if ([appObject respondsToSelector:@selector(mainScene)]) {
        FBScene *s = (FBScene *)[appObject mainScene];
        if (s) return s;
    }
    SEL mainSceneSelector = NSSelectorFromString(@"_mainScene");
    if ([appObject respondsToSelector:mainSceneSelector]) {
        FBScene *s = ((FBScene *(*)(id, SEL))objc_msgSend)(appObject, mainSceneSelector);
        if (s) return s;
    }
    if ([appObject respondsToSelector:@selector(scene)]) {
        return (FBScene *)[appObject performSelector:@selector(scene)];
    }
    return nil;
}

- (FBSceneHostManager *)hostManagerForScene:(FBScene *)scene{
    @try {
        id hm = [scene hostManager];
        if (hm) return (FBSceneHostManager *)hm;
    } @catch (NSException *e) {
    }
    return nil;
}

- (FBSceneLayerManager *)layerManagerForScene:(FBScene *)scene{
    if (!scene) return nil;
    @try {
        if ([scene respondsToSelector:@selector(layerManager)]) {
            return [scene layerManager];
        }
        return [scene valueForKey:@"_layerManager"];
    } @catch (NSException *exception) {
        return nil;
    }
}

-(BOOL)sceneHasRenderableMainLayer:(FBScene *)scene{
    FBSceneLayerManager *layerManager = [self layerManagerForScene:scene];
    if (!layerManager) {
        return NO;
    }

    NSArray *layers = nil;
    @try {
        id rawLayers = [layerManager layers];
        if ([rawLayers respondsToSelector:@selector(array)]) {
            layers = [rawLayers array];
        } else if ([rawLayers isKindOfClass:[NSArray class]]) {
            layers = rawLayers;
        }
    } @catch (NSException *exception) {
        return NO;
    }

    for (FBSceneLayer *layer in layers) {
        @try {
            id sceneLayer = (id)layer;
            NSString *externalSceneId = [sceneLayer respondsToSelector:@selector(externalSceneID)]
                ? [sceneLayer externalSceneID]
                : nil;
            BOOL isKeyboardLayer = [sceneLayer respondsToSelector:@selector(isKeyboardLayer)] &&
                [sceneLayer isKeyboardLayer];
            if (!isKeyboardLayer && externalSceneId == nil) {
                return YES;
            }
        } @catch (NSException *exception) {
        }
    }
    return NO;
}

-(BOOL)isHostedPresentationContentStableForBundleId:(NSString *)bundleId
                                    minimumDuration:(NSTimeInterval)minimumDuration{
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26) {
        return YES;
    }

    FBScene *scene = self.hostedScene;
    BOOL ready = bundleId.length > 0 && self.isForegroundLeaseActive &&
        [self.hostedBundleId isEqualToString:bundleId] && scene &&
        [self sceneHasRenderableMainLayer:scene] &&
        [self isHostedSceneContentReadyForPublication:scene];
    UIView *container = self.ios26PresentationContainer;
    if (ready && (!container || container.hidden || container.alpha <= 0.0 || !container.window)) {
        ready = NO;
    }
    if (ready && container) {
        SEL hasContentSelector = NSSelectorFromString(@"hasContent");
        if ([container respondsToSelector:hasContentSelector]) {
            @try {
                ready = ((BOOL (*)(id, SEL))objc_msgSend)(container, hasContentSelector);
            } @catch (__unused NSException *exception) {
                ready = NO;
            }
        }
    }

    if (!ready) {
        self.ios26HostedContentStableSince = 0;
        return NO;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (self.ios26HostedContentStableSince <= 0) {
        self.ios26HostedContentStableSince = now;
        return minimumDuration <= 0;
    }
    return minimumDuration <= 0 || now - self.ios26HostedContentStableSince >= minimumDuration;
}

-(UIImage *)captureSnapshotImageForActiveBundleId:(NSString *)bundleId{
    return [self captureSnapshotImageForActiveBundleId:bundleId
                                      sourceOrientation:[self hostedPresentationSourceOrientation]];
}

-(UIImage *)captureSnapshotImageForActiveBundleId:(NSString *)bundleId
                                 sourceOrientation:(UIInterfaceOrientation)sourceOrientation{
    if (bundleId.length == 0 || !self.isForegroundLeaseActive || !self.hostedScene ||
        ![self.hostedBundleId isEqualToString:bundleId]) {
        return nil;
    }

    FBScene *scene = self.hostedScene;
    BOOL hasRenderableMainLayer = [self sceneHasRenderableMainLayer:scene];
    BOOL contentReady = [self isHostedSceneContentReadyForPublication:scene];
    if (!hasRenderableMainLayer || !contentReady) {
        return nil;
    }

    @try {

        Class snapshotContextClass = NSClassFromString(@"FBSceneSnapshotContext");
        SEL initContextSelector = NSSelectorFromString(@"initWithScene:");
        SEL createSnapshotSelector = NSSelectorFromString(@"createSnapshotWithContext:");
        SEL prefixedCreateSnapshotSelector = NSSelectorFromString(@"prui_createSnapshotWithContext:");
        SEL alternatePrefixedCreateSnapshotSelector = NSSelectorFromString(@"pruis_createSnapshotWithContext:");
        SEL configuredContextSelector = NSSelectorFromString(@"prui_snapshotContextConfiguredWithOptions:");
        SEL sceneSnapshotContextSelector = NSSelectorFromString(@"snapshotContext");
        BOOL usesIOS26SnapshotSelector =
            NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26;
        if (usesIOS26SnapshotSelector && [scene respondsToSelector:prefixedCreateSnapshotSelector]) {
            createSnapshotSelector = prefixedCreateSnapshotSelector;
        } else if (usesIOS26SnapshotSelector &&
                   [scene respondsToSelector:alternatePrefixedCreateSnapshotSelector]) {
            createSnapshotSelector = alternatePrefixedCreateSnapshotSelector;
        }
        if (![scene respondsToSelector:createSnapshotSelector]) {
            return nil;
        }

        id snapshotContext = nil;
        if (usesIOS26SnapshotSelector) {
            if ([scene respondsToSelector:configuredContextSelector]) {
                snapshotContext = ((id (*)(id, SEL, NSInteger))objc_msgSend)(scene,
                                                                              configuredContextSelector,
                                                                              0);
            }
            if (!snapshotContext && [scene respondsToSelector:sceneSnapshotContextSelector]) {
                snapshotContext = ((id (*)(id, SEL))objc_msgSend)(scene, sceneSnapshotContextSelector);
            }
        } else {
            if (!snapshotContextClass ||
                ![snapshotContextClass instancesRespondToSelector:initContextSelector]) {
                return nil;
            }
            snapshotContext = ((id (*)(id, SEL, id))objc_msgSend)([snapshotContextClass alloc],
                                                                  initContextSelector,
                                                                  scene);
            SEL setOrientationSelector = NSSelectorFromString(@"setOrientation:");
            if (snapshotContext && [snapshotContext respondsToSelector:setOrientationSelector]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(snapshotContext,
                                                             setOrientationSelector,
                                                             1);
            }
        }
        if (!snapshotContext) {
            return nil;
        }

        CGSize logicalSize = POIsConcreteInterfaceOrientation(sourceOrientation)
            ? POHostedCanvasSizeForOrientation(sourceOrientation)
            : CGSizeZero;
        id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
        if ((logicalSize.width <= 0 || logicalSize.height <= 0) &&
            [delegate respondsToSelector:@selector(contextManagerPreferredSceneStackSize:)]) {
            logicalSize = [delegate contextManagerPreferredSceneStackSize:self];
        }
        if (logicalSize.width <= 0 || logicalSize.height <= 0) {
            id sceneSettings = [scene respondsToSelector:@selector(settings)] ? [scene settings] : nil;
            SEL sceneFrameSelector = NSSelectorFromString(@"frame");
            if ([sceneSettings respondsToSelector:sceneFrameSelector]) {
                logicalSize = ((CGRect (*)(id, SEL))objc_msgSend)(sceneSettings, sceneFrameSelector).size;
            }
        }
        SEL setSnapshotFrameSelector = NSSelectorFromString(@"setFrame:");
        if (logicalSize.width > 0 && logicalSize.height > 0 &&
            [snapshotContext respondsToSelector:setSnapshotFrameSelector]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(snapshotContext,
                                                      setSnapshotFrameSelector,
                                                      (CGRect){ CGPointZero, logicalSize });
        }

        SEL settingsSelector = NSSelectorFromString(@"settings");
        SEL setSettingsSelector = NSSelectorFromString(@"setSettings:");
        if ([snapshotContext respondsToSelector:settingsSelector] &&
            [snapshotContext respondsToSelector:setSettingsSelector]) {
            id contextSettings = ((id (*)(id, SEL))objc_msgSend)(snapshotContext, settingsSelector);
            id referenceSettings = [contextSettings mutableCopy];
            SEL setInterfaceOrientationSelector = NSSelectorFromString(@"setInterfaceOrientation:");
            if (referenceSettings && [referenceSettings respondsToSelector:setInterfaceOrientationSelector]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(referenceSettings,
                                                             setInterfaceOrientationSelector,
                                                             (NSInteger)UIInterfaceOrientationPortrait);
                ((void (*)(id, SEL, id))objc_msgSend)(snapshotContext,
                                                       setSettingsSelector,
                                                       referenceSettings);
            }
        }

        id snapshot = ((id (*)(id, SEL, id))objc_msgSend)(scene,
                                                          createSnapshotSelector,
                                                          snapshotContext);
        if (!snapshot && usesIOS26SnapshotSelector &&
            createSnapshotSelector != alternatePrefixedCreateSnapshotSelector &&
            [scene respondsToSelector:alternatePrefixedCreateSnapshotSelector]) {
            snapshot = ((id (*)(id, SEL, id))objc_msgSend)(scene,
                                                            alternatePrefixedCreateSnapshotSelector,
                                                            snapshotContext);
        }
        if (!snapshot && usesIOS26SnapshotSelector &&
            createSnapshotSelector != NSSelectorFromString(@"createSnapshotWithContext:") &&
            [scene respondsToSelector:NSSelectorFromString(@"createSnapshotWithContext:")]) {
            snapshot = ((id (*)(id, SEL, id))objc_msgSend)(scene,
                                                            NSSelectorFromString(@"createSnapshotWithContext:"),
                                                            snapshotContext);
        }
        if (!snapshot) {
            return nil;
        }

        SEL protectedSelector = NSSelectorFromString(@"hasProtectedContent");
        if ([snapshot respondsToSelector:protectedSelector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(snapshot, protectedSelector)) {
            return nil;
        }

        SEL captureSelector = NSSelectorFromString(@"capture");
        if (![snapshot respondsToSelector:captureSelector] ||
            !((BOOL (*)(id, SEL))objc_msgSend)(snapshot, captureSelector)) {
            return nil;
        }

        SEL imageSelector = NSSelectorFromString(@"CGImage");
        if (![snapshot respondsToSelector:imageSelector]) {
            return nil;
        }
        CGImageRef imageRef = ((CGImageRef (*)(id, SEL))objc_msgSend)(snapshot, imageSelector);
        if (!imageRef) {
            return nil;
        }

        CGFloat pixelWidth = (CGFloat)CGImageGetWidth(imageRef);
        CGFloat pixelHeight = (CGFloat)CGImageGetHeight(imageRef);
        CGFloat imageScale = UIScreen.mainScreen.scale;
        if (logicalSize.width > 0 && logicalSize.height > 0) {
            CGFloat scaleX = pixelWidth / logicalSize.width;
            CGFloat scaleY = pixelHeight / logicalSize.height;
            CGFloat tolerance = MAX(0.05, MIN(scaleX, scaleY) * 0.03);
            if (isfinite(scaleX) && isfinite(scaleY) && scaleX > 0 && scaleY > 0 &&
                fabs(scaleX - scaleY) <= tolerance) {
                imageScale = (scaleX + scaleY) * 0.5;
            }
        }
        if (!isfinite(imageScale) || imageScale <= 0) {
            imageScale = 1.0;
        }

        UIImage *image = [UIImage imageWithCGImage:imageRef
                                             scale:imageScale
                                       orientation:UIImageOrientationUp];
        return image;
    } @catch (NSException *exception) {
        return nil;
    }
}

-(BOOL)isOwnedHostedSceneCapabilityProven:(FBScene *)scene bundleId:(NSString *)bundleId{
    return scene && scene == self.ownedHostedScene && bundleId.length > 0 &&
        [self.ownedHostedBundleId isEqualToString:bundleId] && self.ownedHostedSceneCapabilityProven;
}

-(UIInterfaceOrientation)publishedSourceOrientationForScene:(FBScene *)scene{
    return scene && self.publishedScene == scene &&
        POIsConcreteInterfaceOrientation(self.publishedSceneStackOrientation)
        ? self.publishedSceneStackOrientation
        : UIInterfaceOrientationUnknown;
}

-(CGSize)publishedSourceCanvasSizeForScene:(FBScene *)scene{
    return scene && self.publishedScene == scene
        ? self.publishedSceneStackSize
        : CGSizeZero;
}

-(UIInterfaceOrientation)currentHostedPresentationSourceOrientation{
    return [self hostedPresentationSourceOrientation];
}

-(UIInterfaceOrientation)currentSystemInterfaceOrientation{
    return POCurrentSystemInterfaceOrientation();
}

-(BOOL)canonicalizeHostedSourceForCurrentOrientationWithGeneration:(NSUInteger)generation{
    if (!self.isForegroundLeaseActive || !self.hostedScene || generation == 0 ||
        generation != self.activeLeaseGeneration ||
        !POIsConcreteInterfaceOrientation(self.hostedInterfaceOrientation) ||
        !POIsConcreteInterfaceOrientation(self.activeSurfaceSourceOrientation) ||
        POOrientationCategoriesMatch(self.activeSurfaceSourceOrientation,
                                     self.hostedInterfaceOrientation)) {
        return NO;
    }

    FBScene *scene = self.hostedScene;
    UIInterfaceOrientation targetOrientation = self.hostedInterfaceOrientation;
    CGSize targetCanvas = POHostedCanvasSizeForOrientation(targetOrientation);
    if (targetCanvas.width <= 0 || targetCanvas.height <= 0) {
        return NO;
    }

    BOOL presentationOnlyRuntimeRebase =
        [self usesIOS15PresentationOnlyRuntimeSourceRebaseForScene:scene];
    self.activeSurfaceSourceOrientation = targetOrientation;
    self.retainedRuntimeSourceRebasePending = NO;
    if (scene == self.ownedHostedScene) {
        self.ownedHostedSceneServerFrameCanonicalized = presentationOnlyRuntimeRebase;
    } else if (scene == self.systemHostedSnapshotScene && !presentationOnlyRuntimeRebase) {
        self.systemHostedInitialFrameApplied = YES;
        self.systemHostedServerFrameCanonicalized = NO;
    }

    if (presentationOnlyRuntimeRebase) {
        if (scene == self.ownedHostedScene) {
            self.ownedHostedSceneServerFrameCanonicalized = YES;
        } else if (scene == self.systemHostedSnapshotScene) {
            self.systemHostedInitialFrameApplied = NO;
            self.systemHostedServerFrameCanonicalized = YES;
        }
        [self publishUpdatedSceneStacks];
        return YES;
    }

    __weak typeof(self) weakSelf = self;
    [self mutateSettingsForScene:scene withBlock:^(id settings){
        POSetInterfaceOrientationOnSettings(settings, targetOrientation);
        SEL setFrameSelector = NSSelectorFromString(@"setFrame:");
        if ([settings respondsToSelector:setFrameSelector]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(settings,
                                                     setFrameSelector,
                                                     (CGRect){ CGPointZero, targetCanvas });
        }
    } completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isForegroundLeaseActive ||
            strongSelf.hostedScene != scene || strongSelf.activeLeaseGeneration != generation) {
            return;
        }
        [strongSelf publishUpdatedSceneStacks];
    }];
    return YES;
}

-(BOOL)hasPendingRuntimeOrientationHandoffForScene:(FBScene *)scene
                                        generation:(NSUInteger)generation{
    return scene && scene == self.hostedScene && self.isForegroundLeaseActive &&
        generation != 0 && generation == self.activeLeaseGeneration &&
        self.pendingRuntimeOrientationNotificationGeneration == generation &&
        POIsConcreteInterfaceOrientation(self.pendingRuntimeOrientationNotification) &&
        self.pendingRuntimeOrientationNotification == self.hostedInterfaceOrientation;
}

- (UIInterfaceOrientation)preferredHostedInterfaceOrientation {
    id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
    UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
    if ([delegate respondsToSelector:@selector(contextManagerPreferredHostedInterfaceOrientation:)]) {
        orientation = [delegate contextManagerPreferredHostedInterfaceOrientation:self];
    }
    return POIsConcreteInterfaceOrientation(orientation)
        ? orientation
        : UIInterfaceOrientationPortrait;
}

- (UIInterfaceOrientation)surfaceSourceOrientationForScene:(FBScene *)scene bundleId:(NSString *)bundleId {
    (void)scene;
    UIInterfaceOrientation staticOrientation =
        [self preferredHostedInterfaceOrientationForBundleId:bundleId];
    return POIsConcreteInterfaceOrientation(staticOrientation)
        ? staticOrientation
        : UIInterfaceOrientationPortrait;
}

- (UIInterfaceOrientation)hostedPresentationSourceOrientation {
    if (POIsConcreteInterfaceOrientation(self.activeSurfaceSourceOrientation)) {
        return self.activeSurfaceSourceOrientation;
    }
    UIInterfaceOrientation sourceOrientation =
        [self preferredHostedInterfaceOrientationForBundleId:self.hostedBundleId];
    if (POIsConcreteInterfaceOrientation(sourceOrientation)) {
        return sourceOrientation;
    }
    return POIsConcreteInterfaceOrientation(self.hostedInterfaceOrientation)
        ? self.hostedInterfaceOrientation
        : UIInterfaceOrientationPortrait;
}

- (BOOL)shouldRetainHostedServerFrameForScene:(FBScene *)scene {
    if (!scene || !self.isForegroundLeaseActive || scene != self.hostedScene ||
        self.hostedBundleId.length == 0 || !POIsConcreteInterfaceOrientation(self.hostedInterfaceOrientation)) {
        return NO;
    }

    UIInterfaceOrientation sourceOrientation = [self hostedPresentationSourceOrientation];
    CGSize hostedCanvas = POHostedCanvasSizeForOrientation(sourceOrientation);

    if (scene == self.ownedHostedScene) {
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
            return NO;
        }
        return !self.ownedHostedSceneServerFrameCanonicalized &&
            !POSceneSizesMatch(hostedCanvas, POCanonicalApplicationSceneFrame(nil).size);
    }
    if (scene == self.systemHostedSnapshotScene && self.systemHostedOriginalSettings &&
        self.systemHostedInitialFrameApplied) {
        return !self.systemHostedServerFrameCanonicalized &&
            !POSceneSizesMatch(hostedCanvas, self.systemHostedOriginalFrame.size);
    }
    return NO;
}

- (BOOL)usesIOS15PresentationOnlyRuntimeSourceRebaseForScene:(FBScene *)scene {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 15 ||
        !self.runtimeHostedOrientationAuthorityActive || !scene || self.hostedBundleId.length == 0) {
        return NO;
    }
    return scene == self.ownedHostedScene || scene == self.systemHostedSnapshotScene;
}

- (void)enforceHostedServerFrameOnSettings:(id)settings scene:(FBScene *)scene {
    if (!settings) {
        return;
    }
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 &&
        scene == self.ownedHostedScene) {
        CGRect canonicalFrame = POCanonicalApplicationSceneFrame(settings);
        CGRect currentFrame = CGRectZero;
        SEL frameSelector = NSSelectorFromString(@"frame");
        if ([settings respondsToSelector:frameSelector]) {
            currentFrame = ((CGRect (*)(id, SEL))objc_msgSend)(settings, frameSelector);
        }
        if (!POSceneSizesMatch(currentFrame.size, canonicalFrame.size)) {
            SEL setFrameSelector = NSSelectorFromString(@"setFrame:");
            if ([settings respondsToSelector:setFrameSelector]) {
                ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, setFrameSelector, canonicalFrame);
            }
        }
        self.ownedHostedSceneServerFrameCanonicalized = YES;
        return;
    }
    if (![self shouldRetainHostedServerFrameForScene:scene]) {
        return;
    }

    UIInterfaceOrientation sourceOrientation = [self hostedPresentationSourceOrientation];
    CGSize hostedCanvas = POHostedCanvasSizeForOrientation(sourceOrientation);

    CGRect hostedFrame = (CGRect){ CGPointZero, hostedCanvas };
    CGRect currentFrame = CGRectZero;
    SEL frameSelector = NSSelectorFromString(@"frame");
    if ([settings respondsToSelector:frameSelector]) {
        currentFrame = ((CGRect (*)(id, SEL))objc_msgSend)(settings, frameSelector);
    }
    if (!POSceneSizesMatch(currentFrame.size, hostedCanvas)) {
        SEL setFrameSelector = NSSelectorFromString(@"setFrame:");
        if ([settings respondsToSelector:setFrameSelector]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, setFrameSelector, hostedFrame);
        }
    }

    if (scene == self.ownedHostedScene) {
        self.ownedHostedSceneServerFrameCanonicalized = NO;
    } else if (scene == self.systemHostedSnapshotScene) {
        self.systemHostedServerFrameCanonicalized = NO;
    }
}

- (BOOL)setForeground:(BOOL)foreground forScene:(FBScene *)scene{
    __block BOOL orientationChanged = NO;
    [self mutateSettingsForScene:scene withBlock:^(id settings){
        if (foreground && self.isForegroundLeaseActive && scene == self.hostedScene) {
            UIInterfaceOrientation sourceOrientation = [self hostedPresentationSourceOrientation];
            UIInterfaceOrientation targetOrientation = self.hostedInterfaceOrientation;
            BOOL restoringRuntimeCrossOrientation =
                self.runtimeHostedOrientationAuthorityActive &&
                POIsConcreteInterfaceOrientation(sourceOrientation) &&
                POIsConcreteInterfaceOrientation(targetOrientation) &&
                !POOrientationCategoriesMatch(sourceOrientation, targetOrientation);

            if (restoringRuntimeCrossOrientation) {
                orientationChanged = POSetInterfaceOrientationOnSettings(settings, targetOrientation);
                POApplyCrossOrientationMapToSettings(settings, targetOrientation);
            } else if (!self.runtimeHostedOrientationAuthorityActive) {
                orientationChanged = POSetInterfaceOrientationOnSettings(settings, sourceOrientation);
            }
            if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
                UIInterfaceOrientation mappedOrientation = restoringRuntimeCrossOrientation
                    ? targetOrientation
                    : sourceOrientation;
                POApplyCrossOrientationMapToSettings(settings, mappedOrientation);
            }
            [self enforceHostedServerFrameOnSettings:settings scene:scene];
        }
        if ([settings respondsToSelector:@selector(setForeground:)]) {
            [settings setForeground:foreground];
        }
        if ([settings respondsToSelector:@selector(setBackgrounded:)]) {
            [settings setBackgrounded:!foreground];
        }
    }];
    return orientationChanged;
}

- (void)restoreSystemInterfaceOrientationForScene:(FBScene *)scene bundleId:(NSString *)bundleId {
    UIInterfaceOrientation targetOrientation = POCurrentSystemInterfaceOrientation();
    UIInterfaceOrientationMask supportedMask = [POApplicationHelper supportedInterfaceOrientationsForBundleId:bundleId];
    if (!POOrientationMaskContainsOrientation(supportedMask, targetOrientation)) {
        targetOrientation = [POApplicationHelper preferredHostedInterfaceOrientationForBundleId:bundleId];
    }

    [self mutateSettingsForScene:scene withBlock:^(id settings){
        SEL setOrientationSelector = NSSelectorFromString(@"setInterfaceOrientation:");
        if (POIsConcreteInterfaceOrientation(targetOrientation) &&
            [settings respondsToSelector:setOrientationSelector]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(settings, setOrientationSelector,
                                                         (NSInteger)targetOrientation);
        }
    }];
}

- (void)clearSystemHostedSettingsSnapshot {
    self.systemHostedSnapshotScene = nil;
    self.systemHostedOriginalSettings = nil;
    self.systemHostedOriginalFrame = CGRectZero;
    self.systemHostedInitialFrameApplied = NO;
    self.systemHostedServerFrameCanonicalized = NO;
}

- (void)captureSystemHostedSettingsIfNeededForScene:(FBScene *)scene {
    if (!scene || scene == self.ownedHostedScene) {
        return;
    }
    if (self.systemHostedSnapshotScene == scene && self.systemHostedOriginalSettings) {
        return;
    }

    [self clearSystemHostedSettingsSnapshot];
    @try {
        id settings = [scene respondsToSelector:@selector(settings)] ? [scene settings] : nil;
        id snapshot = [settings copy];
        if (!snapshot) {
            return;
        }
        CGRect originalFrame = CGRectZero;
        SEL frameSelector = NSSelectorFromString(@"frame");
        if ([settings respondsToSelector:frameSelector]) {
            originalFrame = ((CGRect (*)(id, SEL))objc_msgSend)(settings, frameSelector);
        }
        self.systemHostedSnapshotScene = scene;
        self.systemHostedOriginalSettings = snapshot;
        self.systemHostedOriginalFrame = originalFrame;
    } @catch (NSException *exception) {
        [self clearSystemHostedSettingsSnapshot];
    }
}

- (void)prepareSystemHostedInitialGeometryIfNeededForScene:(FBScene *)scene
                                                  bundleId:(NSString *)bundleId {
    if (!scene || bundleId.length == 0 || scene != self.systemHostedSnapshotScene ||
        !self.systemHostedOriginalSettings || self.systemHostedInitialFrameApplied ||
        scene == self.ownedHostedScene ||
        (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion != 15 &&
         ![self requiresCrossOrientationHostingForBundleId:bundleId])) {
        return;
    }

    UIInterfaceOrientation hostedOrientation =
        [self surfaceSourceOrientationForScene:scene bundleId:bundleId];
    if (!POIsConcreteInterfaceOrientation(hostedOrientation)) {
        return;
    }
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
        self.systemHostedInitialFrameApplied = NO;
        self.systemHostedServerFrameCanonicalized = YES;
        return;
    }

    CGSize hostedCanvas = CGSizeZero;
    id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
    if ([delegate respondsToSelector:@selector(contextManagerPreferredSceneStackSize:)]) {
        hostedCanvas = [delegate contextManagerPreferredSceneStackSize:self];
    }
    BOOL canvasMatchesOrientation = hostedCanvas.width > 0 && hostedCanvas.height > 0 &&
        (UIInterfaceOrientationIsLandscape(hostedOrientation)
            ? hostedCanvas.width >= hostedCanvas.height
            : hostedCanvas.height >= hostedCanvas.width);
    if (!canvasMatchesOrientation) {
        hostedCanvas = POHostedCanvasSizeForOrientation(hostedOrientation);
    }
    if (POSceneSizesMatch(hostedCanvas, self.systemHostedOriginalFrame.size)) {
        return;
    }

    CGRect initialFrame = (CGRect){ CGPointZero, hostedCanvas };
    self.systemHostedInitialFrameApplied = YES;
    self.systemHostedServerFrameCanonicalized = NO;
    [self mutateSettingsForScene:scene withBlock:^(id settings){
        SEL frameSelector = NSSelectorFromString(@"setFrame:");
        if ([settings respondsToSelector:frameSelector]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, frameSelector, initialFrame);
        }
    }];
}

-(void)prepareSystemDefaultSceneForHosting:(FBScene *)scene bundleId:(NSString *)bundleId{
    if (!scene || bundleId.length == 0 || scene == self.ownedHostedScene) {
        return;
    }
    [self captureSystemHostedSettingsIfNeededForScene:scene];
    [self prepareSystemHostedInitialGeometryIfNeededForScene:scene bundleId:bundleId];
}

- (void)canonicalizeSystemHostedSceneServerFrameIfNeededForScene:(FBScene *)scene {
    if (!scene || scene != self.systemHostedSnapshotScene || !self.systemHostedOriginalSettings ||
        !self.systemHostedInitialFrameApplied || self.systemHostedServerFrameCanonicalized ||
        !self.isForegroundLeaseActive || scene != self.hostedScene ||
        CGRectGetWidth(self.systemHostedOriginalFrame) <= 0 ||
        CGRectGetHeight(self.systemHostedOriginalFrame) <= 0) {
        return;
    }

    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 &&
        [self shouldRetainHostedServerFrameForScene:scene]) {
        return;
    }

    CGRect canonicalFrame = self.systemHostedOriginalFrame;
    self.systemHostedServerFrameCanonicalized = YES;
    [self mutateSettingsForScene:scene withBlock:^(id settings){
        SEL frameSelector = NSSelectorFromString(@"setFrame:");
        if ([settings respondsToSelector:frameSelector]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, frameSelector, canonicalFrame);
        }
    }];
}

- (void)applySceneSettingsObject:(id)settings toScene:(FBScene *)scene {
    if (!scene || !settings) {
        return;
    }
    @try {
        id mutableSettings = [settings mutableCopy] ?: settings;
        BOOL previousInternalMutation = self.applyingHostedSettingsInternally;
        self.applyingHostedSettingsInternally = YES;
        if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:completion:)]) {
            [scene updateSettings:mutableSettings withTransitionContext:nil completion:nil];
        } else if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
            [scene updateSettings:mutableSettings withTransitionContext:nil];
        }
        self.applyingHostedSettingsInternally = previousInternalMutation;
    } @catch (NSException *exception) {
    }
}

- (BOOL)restoreSystemHostedSettingsSnapshotIfPossibleForScene:(FBScene *)scene {
    if (!scene || scene != self.systemHostedSnapshotScene || !self.systemHostedOriginalSettings) {
        return NO;
    }
    id snapshot = self.systemHostedOriginalSettings;
    [self applySceneSettingsObject:snapshot toScene:scene];
    [self clearSystemHostedSettingsSnapshot];
    return YES;
}

- (void)scheduleHostedOrientationPublicationForScene:(FBScene *)scene {
    if (!scene || !self.isForegroundLeaseActive || self.hostedScene != scene) {
        return;
    }
    [self publishUpdatedSceneStacks];
}

- (id)systemOrientationAnimationParameters {
    Class parametersClass = NSClassFromString(@"UIStatusBarOrientationAnimationParameters");
    return parametersClass ? [parametersClass new] : nil;
}

- (void)startObservingHostedSceneEvents:(FBScene *)scene {
    if (!scene) {
        return;
    }
    [self stopObservingHostedSceneEvents];

    SEL addObserverSelector = NSSelectorFromString(@"addObserver:");
    if ([scene respondsToSelector:addObserverSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(scene, addObserverSelector, self);
        self.observedClientSettingsScene = scene;
    }

    SEL contentStateSelector = NSSelectorFromString(@"contentState");
    if ([scene respondsToSelector:contentStateSelector]) {
        @try {
            [scene addObserver:self
                    forKeyPath:@"contentState"
                       options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionPrior)
                       context:NULL];
            self.observedContentStateScene = scene;
        } @catch (__unused NSException *exception) {
            self.observedContentStateScene = nil;
        }
    }
}

- (void)stopObservingHostedSceneEvents {
    FBScene *clientScene = self.observedClientSettingsScene;
    if (clientScene) {
        SEL removeObserverSelector = NSSelectorFromString(@"removeObserver:");
        if ([clientScene respondsToSelector:removeObserverSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(clientScene, removeObserverSelector, self);
        }
    }
    self.observedClientSettingsScene = nil;

    FBScene *contentScene = self.observedContentStateScene;
    if (contentScene) {
        @try {
            [contentScene removeObserver:self forKeyPath:@"contentState"];
        } @catch (__unused NSException *exception) {
        }
    }
    self.observedContentStateScene = nil;
}

- (void)scene:(FBScene *)scene
    didUpdateClientSettingsWithDiff:(id)__unused diff
    oldClientSettings:(id)__unused oldClientSettings
    transitionContext:(id)transitionContext {
    [self handleHostedClientSettingsUpdateForScene:scene transitionContext:transitionContext];
}

- (void)handleHostedClientSettingsUpdateForScene:(FBScene *)scene
                               transitionContext:(id)transitionContext {
    if (!scene || !self.isForegroundLeaseActive || self.hostedScene != scene ||
        self.activeLeaseGeneration == 0) {
        return;
    }

    if (!self.runtimeHostedOrientationAuthorityActive) {
        [self publishUpdatedSceneStacks];
        return;
    }

    id clientSettings = POClientSettingsForScene(scene);
    UIInterfaceOrientation observedOrientation =
        PORuntimeInterfaceOrientationFromClientSettings(clientSettings);
    if (POIsConcreteInterfaceOrientation(observedOrientation)) {
        self.runtimeClientOrientationBaselineEstablished = YES;
    } else if (self.runtimeClientOrientationBaselineEstablished) {
        observedOrientation = POLiveLeadingInterfaceOrientationFromClientSettings(
            clientSettings, self.hostedInterfaceOrientation);
    }

    if (!POIsConcreteInterfaceOrientation(observedOrientation)) {
        [self publishUpdatedSceneStacks];
        return;
    }

    BOOL sourceCategoryDiffers =
        POIsConcreteInterfaceOrientation(self.activeSurfaceSourceOrientation) &&
        !POOrientationCategoriesMatch(self.activeSurfaceSourceOrientation, observedOrientation);
    BOOL sameCategory = POIsConcreteInterfaceOrientation(self.hostedInterfaceOrientation) &&
        POOrientationCategoriesMatch(observedOrientation, self.hostedInterfaceOrientation);
    if (sameCategory) {
        UIInterfaceOrientation interfaceOrientation = POInterfaceOrientationFromSettings(clientSettings);
        UIInterfaceOrientation effectiveOrientation =
            POEffectiveInterfaceOrientationFromClientSettings(clientSettings);
        BOOL clientConfirmedRetainedSource =
            self.retainedRuntimeSourceRebasePending &&
            POIsConcreteInterfaceOrientation(interfaceOrientation) &&
            POIsConcreteInterfaceOrientation(effectiveOrientation) &&
            POOrientationCategoriesMatch(interfaceOrientation, effectiveOrientation) &&
            POOrientationCategoriesMatch(effectiveOrientation, observedOrientation) &&
            sourceCategoryDiffers;

        self.hostedInterfaceOrientation = observedOrientation;
        if (clientConfirmedRetainedSource) {
            self.activeSurfaceSourceOrientation = effectiveOrientation;
            self.retainedRuntimeSourceRebasePending = NO;
            sourceCategoryDiffers = NO;
        } else if (self.retainedRuntimeSourceRebasePending && !sourceCategoryDiffers) {
            self.retainedRuntimeSourceRebasePending = NO;
        }
        [self publishUpdatedSceneStacks];
        return;
    }

    self.hostedInterfaceOrientation = observedOrientation;
    NSUInteger generation = self.activeLeaseGeneration;
    id systemAnimationParameters = [self systemOrientationAnimationParameters];

    UIInterfaceOrientation baseOrientation =
        [self preferredHostedInterfaceOrientationForBundleId:self.hostedBundleId];

    BOOL shouldRebaseSourceToBase =
        POIsConcreteInterfaceOrientation(baseOrientation) &&
        POOrientationCategoriesMatch(observedOrientation, baseOrientation) &&
        sourceCategoryDiffers;

    if (shouldRebaseSourceToBase) {
        self.pendingRuntimeOrientationNotification = observedOrientation;
        self.pendingRuntimeOrientationNotificationGeneration = generation;
        id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
        if ([delegate respondsToSelector:@selector(contextManager:scene:hostedInterfaceOrientationDidChange:systemAnimationParameters:hostGeneration:)]) {
            [delegate contextManager:self
                               scene:scene
 hostedInterfaceOrientationDidChange:observedOrientation
           systemAnimationParameters:systemAnimationParameters
                      hostGeneration:generation];
        } else {
            [self canonicalizeHostedSourceForCurrentOrientationWithGeneration:generation];
        }
    } else {
        id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
        if ([delegate respondsToSelector:@selector(contextManager:scene:hostedInterfaceOrientationDidChange:systemAnimationParameters:hostGeneration:)]) {
            [delegate contextManager:self
                               scene:scene
 hostedInterfaceOrientationDidChange:observedOrientation
           systemAnimationParameters:systemAnimationParameters
                      hostGeneration:generation];
        }
    }

}

- (void)ensureLeaseResourcesForScene:(FBScene *)scene
                            bundleId:(NSString *)bundleId
                          generation:(NSUInteger)generation{
    if (!scene || bundleId.length == 0 || generation == 0 ||
        !self.isForegroundLeaseActive || self.activeLeaseGeneration != generation ||
        self.hostedScene != scene || ![self.hostedBundleId isEqualToString:bundleId]) {
        return;
    }
    if (!self.processAssertion) {
        [self acquireProcessAssertionForBundleId:bundleId];
    }
}

- (void)canonicalizeOwnedHostedSceneServerFrameIfNeededForScene:(FBScene *)scene {
    if (!scene || scene != self.ownedHostedScene ||
        self.ownedHostedSceneServerFrameCanonicalized ||
        !self.isForegroundLeaseActive || scene != self.hostedScene) {
        return;
    }
    CGRect canonicalFrame = CGRectZero;
    @try {
        id sceneSettings = [scene respondsToSelector:@selector(settings)] ? [scene settings] : nil;
        SEL displaySelector = NSSelectorFromString(@"displayConfiguration");
        id displayConfiguration = sceneSettings && [sceneSettings respondsToSelector:displaySelector]
            ? ((id (*)(id, SEL))objc_msgSend)(sceneSettings, displaySelector)
            : nil;
        SEL boundsSelector = NSSelectorFromString(@"bounds");
        if (displayConfiguration && [displayConfiguration respondsToSelector:boundsSelector]) {
            canonicalFrame = ((CGRect (*)(id, SEL))objc_msgSend)(displayConfiguration, boundsSelector);
        }
    } @catch (NSException *exception) {
    }

    if (CGRectGetWidth(canonicalFrame) <= 0 || CGRectGetHeight(canonicalFrame) <= 0) {
        CGSize screenSize = UIScreen.mainScreen.bounds.size;
        canonicalFrame = CGRectMake(0, 0,
                                    MIN(screenSize.width, screenSize.height),
                                    MAX(screenSize.width, screenSize.height));
    }

    self.ownedHostedSceneServerFrameCanonicalized = YES;
    [self mutateSettingsForScene:scene withBlock:^(id settings){
        SEL frameSelector = NSSelectorFromString(@"setFrame:");
        if ([settings respondsToSelector:frameSelector]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, frameSelector, canonicalFrame);
        }
    }];
}

- (void)mutateSettingsForScene:(FBScene *)scene withBlock:(void (^)(id settings))block{
    [self mutateSettingsForScene:scene withBlock:block completion:nil];
}

- (void)mutateSettingsForScene:(FBScene *)scene
                     withBlock:(void (^)(id settings))block
                    completion:(dispatch_block_t)completion {
    [self mutateSettingsForScene:scene
                       withBlock:block
               transitionContext:nil
                      completion:completion];
}

- (void)mutateSettingsForScene:(FBScene *)scene
                     withBlock:(void (^)(id settings))block
             transitionContext:(id)transitionContext
                    completion:(dispatch_block_t)completion {
    if (!scene || !block) return;
    @try {
        id settings = nil;
        if ([scene respondsToSelector:@selector(mutableSettings)]) {
            settings = [[scene mutableSettings] mutableCopy];
        }
        if (!settings && [scene respondsToSelector:@selector(settings)]) {
            settings = [[scene settings] mutableCopy];
        }
        if (!settings) {
            settings = [[scene valueForKey:@"_mutableSettings"] mutableCopy];
        }
        if (!settings) {
            settings = [[scene valueForKey:@"_settings"] mutableCopy];
        }
        if (!settings) {
            return;
        }
        block(settings);
        BOOL previousInternalMutation = self.applyingHostedSettingsInternally;
        self.applyingHostedSettingsInternally = YES;
        if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:completion:)]) {
            [scene updateSettings:settings withTransitionContext:transitionContext completion:completion];
        } else {
            [scene updateSettings:settings withTransitionContext:transitionContext];
            if (completion) {
                completion();
            }
        }
        self.applyingHostedSettingsInternally = previousInternalMutation;
    } @catch (__unused NSException *exception) {
    }
}

- (void)observeLayerManager:(FBSceneLayerManager *)layerManager{
    if (self.observingLayers && self.hostedLayerManager == layerManager) {
        return;
    }
    [self stopObservingLayerManager];
    self.hostedLayerManager = layerManager;
    @try {
        [layerManager addObserver:self
                       forKeyPath:@"layers"
                          options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionPrior)
                           context:NULL];
        self.observingLayers = YES;
    } @catch (NSException *exception) {
    }
}

- (void)stopObservingLayerManager{
    if (!self.observingLayers || !self.hostedLayerManager) {
        self.observingLayers = NO;
        return;
    }
    @try {
        [self.hostedLayerManager removeObserver:self forKeyPath:@"layers"];
    } @catch (NSException *exception) {
    }
    self.observingLayers = NO;
}

- (UIView *)sceneStackForScene:(FBScene *)scene
             keyboardSceneStack:(UIView **)keyboardStackOut
            hasKeyboardLayerOut:(BOOL *)hasKeyboardLayerOut{
    FBSceneLayerManager *manager = [self layerManagerForScene:scene];
    NSArray *layers = nil;
    @try {
        id rawLayers = [manager layers];
        if ([rawLayers respondsToSelector:@selector(array)]) {
            layers = [rawLayers array];
        } else if ([rawLayers isKindOfClass:[NSArray class]]) {
            layers = rawLayers;
        }
    } @catch (NSException *exception) {
    }

    CGSize targetStackSize = CGSizeZero;
    id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
    if ([delegate respondsToSelector:@selector(contextManagerPreferredSceneStackSize:)]) {
        targetStackSize = [delegate contextManagerPreferredSceneStackSize:self];
    }
    if (targetStackSize.width <= 0 || targetStackSize.height <= 0) {
        targetStackSize = [UIScreen mainScreen].bounds.size;
    }

    CGSize systemStackSize = CGSizeZero;
    if ([delegate respondsToSelector:@selector(contextManagerPreferredSystemSceneStackSize:)]) {
        systemStackSize = [delegate contextManagerPreferredSystemSceneStackSize:self];
    }
    if (systemStackSize.width <= 0 || systemStackSize.height <= 0) {
        systemStackSize = targetStackSize;
    }

    BOOL systemCanvasValid = systemStackSize.width > 0 && systemStackSize.height > 0;
    CGSize keyboardPresentationCanvasSize = POHostedCanvasSizeForOrientation(UIInterfaceOrientationPortrait);
    CGSize canonicalLandscapeCanvasSize = CGSizeMake(keyboardPresentationCanvasSize.height,
                                                     keyboardPresentationCanvasSize.width);
    BOOL hostedCanvasIsCanonicalLandscape =
        POSceneSizesMatch(targetStackSize, canonicalLandscapeCanvasSize) &&
        targetStackSize.width > targetStackSize.height;
    BOOL shellUsesSupportedFullscreenCanvas = systemCanvasValid &&
        (POSceneSizesMatch(systemStackSize, keyboardPresentationCanvasSize) ||
         POSceneSizesMatch(systemStackSize, canonicalLandscapeCanvasSize));
    BOOL needsLandscapeKeyboardBridge =
        UIInterfaceOrientationIsLandscape(self.hostedInterfaceOrientation) &&
        hostedCanvasIsCanonicalLandscape && shellUsesSupportedFullscreenCanvas;

    UIInterfaceOrientation sourceOrientation = [self hostedPresentationSourceOrientation];
    CGSize mainStackSize = POHostedCanvasSizeForOrientation(sourceOrientation);
    if (mainStackSize.width <= 0 || mainStackSize.height <= 0) {
        mainStackSize = targetStackSize;
    }
    CGRect mainStackFrame = (CGRect){ CGPointZero, mainStackSize };
    CGRect targetStackFrame = (CGRect){ CGPointZero, targetStackSize };
    CGRect systemStackFrame = (CGRect){ CGPointZero, systemStackSize };

    NSMutableArray<FBSceneLayer *> *mainLayers = [NSMutableArray array];
    BOOL hasKeyboardLayer = NO;
    for (FBSceneLayer *layer in layers) {
        @try {
            id sceneLayer = (id)layer;
            NSString *externalSceneId = [sceneLayer respondsToSelector:@selector(externalSceneID)] ? [sceneLayer externalSceneID] : nil;
            BOOL isKeyboardLayer = [sceneLayer respondsToSelector:@selector(isKeyboardLayer)] && [sceneLayer isKeyboardLayer];
            if (isKeyboardLayer) {
                hasKeyboardLayer = YES;
            } else if (externalSceneId == nil) {
                [mainLayers addObject:layer];
            }
        } @catch (NSException *exception) {
        }
    }

    BOOL hasMainLayers = mainLayers.count > 0;
    BOOL forceSceneStackRebuild = hasMainLayers && self.forceNextPublishedSceneStackRebuild;
    if (forceSceneStackRebuild) {
        self.forceNextPublishedSceneStackRebuild = NO;
    }
    BOOL samePublishedContract = CGSizeEqualToSize(self.publishedSceneStackSize, mainStackSize) &&
        self.publishedSceneStackOrientation == sourceOrientation;
    BOOL samePublishedLayers = hasMainLayers && self.publishedScene == scene && self.publishedSceneStack &&
        POMainLayerIdentitiesEqual(self.publishedMainLayers, mainLayers);
    BOOL ios15LiveContractRebase =
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 &&
        samePublishedLayers && !samePublishedContract;
    BOOL ios26LiveContractRebase =
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        samePublishedLayers && !samePublishedContract && self.ios26PresentationContainer;
    BOOL reuseMainStack = !forceSceneStackRebuild && samePublishedLayers &&
        (samePublishedContract || ios15LiveContractRebase || ios26LiveContractRebase);

    Class ios26ContainerClass = NSClassFromString(@"_UISceneLayerHostContainerView");
    SEL ios26ContainerInitSelector = NSSelectorFromString(@"initWithScene:debugDescription:");
    BOOL canCreateIOS26Container = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        ios26ContainerClass && [ios26ContainerClass instancesRespondToSelector:ios26ContainerInitSelector];
    if (hasMainLayers && !reuseMainStack && self.publishedSceneStack &&
        !self.publishedSceneStack.superview) {
        [self invalidateIOS26PresentationContainersInSceneStack:self.publishedSceneStack];
    }
    UIView *sceneStack = reuseMainStack
        ? self.publishedSceneStack
        : [[UIView alloc] initWithFrame:mainStackFrame];

    if (ios15LiveContractRebase || ios26LiveContractRebase) {
        [UIView performWithoutAnimation:^{
            sceneStack.bounds = (CGRect){ CGPointZero, mainStackSize };
            for (UIView *hostView in sceneStack.subviews) {
                hostView.frame = sceneStack.bounds;
                hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            }
            if (ios26LiveContractRebase) {
                UIView *container = self.ios26PresentationContainer;
                id context = POCreateIOS26ScenePresentationContext(sourceOrientation,
                                                                   self.presentationInterfaceOrientation);
                SEL setContextSelector = NSSelectorFromString(@"_setPresentationContext:");
                if (context && [container respondsToSelector:setContextSelector]) {
                    self.ios26PresentationContext = context;
                    ((void (*)(id, SEL, id))objc_msgSend)(container,
                                                          setContextSelector,
                                                          context);
                }
                container.frame = sceneStack.bounds;
                PONormalizeIOS26PresentationContainerGeometry(container);
            }
        }];
    } else if (!reuseMainStack) {
        sceneStack.frame = mainStackFrame;
        for (UIView *hostView in sceneStack.subviews) {
            hostView.frame = sceneStack.bounds;
        }
    }

    UIView *keyboardSceneStack = [[UIView alloc]
        initWithFrame:(hasKeyboardLayer ? targetStackFrame : systemStackFrame)];
    UIView *keyboardPresentationCanvas = nil;
    UIView *ios26PresentationContainer = nil;

    if (!reuseMainStack && canCreateIOS26Container) {
        Class containerClass = ios26ContainerClass;
        SEL initSelector = NSSelectorFromString(@"initWithScene:debugDescription:");
        SEL setDataSourceSelector = NSSelectorFromString(@"_setDataSource:");
        SEL setContextSelector = NSSelectorFromString(@"_setPresentationContext:");
        if (containerClass && [containerClass instancesRespondToSelector:initSelector]) {
            ios26PresentationContainer = ((id (*)(id, SEL, id, id))objc_msgSend)(
                [containerClass alloc],
                initSelector,
                scene,
                [NSString stringWithFormat:@"PullOverX %@", self.hostedBundleId ?: kPORequester]);
            id context = POCreateIOS26ScenePresentationContext(sourceOrientation,
                                                               self.presentationInterfaceOrientation);
            if (ios26PresentationContainer && context) {
                self.ios26PresentationContext = context;
                if ([ios26PresentationContainer respondsToSelector:setContextSelector]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(ios26PresentationContainer,
                                                           setContextSelector,
                                                           context);
                }
                if ([ios26PresentationContainer respondsToSelector:setDataSourceSelector]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(ios26PresentationContainer,
                                                           setDataSourceSelector,
                                                           self);
                }
                ios26PresentationContainer.frame = sceneStack.bounds;
                ios26PresentationContainer.autoresizingMask =
                    UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [sceneStack addSubview:ios26PresentationContainer];
                [sceneStack layoutIfNeeded];
                PONormalizeIOS26PresentationContainerGeometry(ios26PresentationContainer);
                self.ios26PresentationContainer = ios26PresentationContainer;
            } else {
                ios26PresentationContainer = nil;
            }
        }
    }

    for (FBSceneLayer *layer in layers) {
        @try {
            id sceneLayer = (id)layer;
            NSString *externalSceneId = [sceneLayer respondsToSelector:@selector(externalSceneID)] ? [sceneLayer externalSceneID] : nil;
            BOOL isKeyboardLayer = [sceneLayer respondsToSelector:@selector(isKeyboardLayer)] && [sceneLayer isKeyboardLayer];
            if (isKeyboardLayer) {
                UIView *keyboardHostContainer = keyboardSceneStack;
                if (needsLandscapeKeyboardBridge) {
                    if (!keyboardPresentationCanvas) {
                        keyboardPresentationCanvas = [[UIView alloc]
                            initWithFrame:(CGRect){ CGPointZero, keyboardPresentationCanvasSize }];
                        keyboardPresentationCanvas.bounds = (CGRect){ CGPointZero, keyboardPresentationCanvasSize };
                        keyboardPresentationCanvas.center = CGPointMake(CGRectGetMidX(keyboardSceneStack.bounds),
                                                                        CGRectGetMidY(keyboardSceneStack.bounds));
                        keyboardPresentationCanvas.transform =
                            POKeyboardPresentationTransformForInterfaceOrientation(self.hostedInterfaceOrientation);
                        [keyboardSceneStack addSubview:keyboardPresentationCanvas];
                    }
                    keyboardHostContainer = keyboardPresentationCanvas;
                }
                Class keyboardHostClass = objc_getClass("_UIKeyboardLayerHostView");
                _UIKeyboardLayerHostView *hostView = [[keyboardHostClass alloc] initWithKeyboardLayer:layer owningScene:scene];
                hostView.frame = keyboardHostContainer.bounds;
                hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [keyboardHostContainer addSubview:hostView];
            } else if (externalSceneId != nil) {
                Class externalHostClass = objc_getClass("_UIExternalSceneLayerHostView");
                _UIExternalSceneLayerHostView *hostView = [[externalHostClass alloc] initWithSceneLayer:layer parentScene:scene];
                hostView.frame = keyboardSceneStack.bounds;
                [keyboardSceneStack addSubview:hostView];
            } else if (!reuseMainStack && !ios26PresentationContainer) {
                UIView *hostView = [[NSClassFromString(@"_UIContextLayerHostView") alloc]
                    initWithSceneLayer:layer];
                if (!hostView) {
                    continue;
                }
                POConfigureIOS26ScenePresentationContext(hostView);
                POApplyIOS26HostTransformer(hostView,
                                            sourceOrientation,
                                            self.presentationInterfaceOrientation);
                hostView.frame = sceneStack.bounds;
                [sceneStack addSubview:hostView];
            }
        } @catch (NSException *exception) {
        }
    }

    if (hasMainLayers && (!reuseMainStack || ios15LiveContractRebase || ios26LiveContractRebase)) {
        self.publishedScene = scene;
        self.publishedSceneStack = sceneStack;
        self.publishedMainLayers = [mainLayers copy];
        self.publishedSceneStackSize = mainStackSize;
        self.publishedSceneStackOrientation = sourceOrientation;
    }

    if (keyboardStackOut) {
        *keyboardStackOut = keyboardSceneStack;
    }
    if (hasKeyboardLayerOut) {
        *hasKeyboardLayerOut = hasKeyboardLayer;
    }
    return sceneStack;
}

- (void)publishUpdatedSceneStacks{
    if (!self.isForegroundLeaseActive) {
        return;
    }
    FBScene *scene = self.hostedScene;
    NSUInteger generation = self.activeLeaseGeneration;
    if (!scene || generation == 0) {
        return;
    }
    BOOL sceneValid = ![scene respondsToSelector:@selector(isValid)] || [(id)scene isValid];
    if (!sceneValid) {
        id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
        if ([delegate respondsToSelector:@selector(contextManager:sceneDidBecomeInvalid:hostGeneration:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.isForegroundLeaseActive || self.hostedScene != scene ||
                    self.activeLeaseGeneration != generation) {
                    return;
                }
                [delegate contextManager:self sceneDidBecomeInvalid:scene hostGeneration:generation];
            });
        }
        return;
    }
    if (![self isHostedGeometryReadyForScene:scene bundleId:self.hostedBundleId]) {
        return;
    }

    BOOL hasRenderableMainLayer = [self sceneHasRenderableMainLayer:scene];
    if (scene == self.ownedHostedScene && hasRenderableMainLayer) {
        self.ownedHostedSceneCapabilityProven = YES;
    }
    if (!hasRenderableMainLayer) {
        return;
    }
    if (![self isHostedSceneContentReadyForPublication:scene]) {
        return;
    }
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
        self.ios26HostedContentRecoveryPending) {
        self.publishedScene = nil;
        self.publishedSceneStack = nil;
        self.publishedMainLayers = nil;
        self.publishedSceneStackSize = CGSizeZero;
        self.publishedSceneStackOrientation = UIInterfaceOrientationUnknown;
        self.ios26HostedContentRecoveryPending = NO;
        self.ios26HostedContentAwaitingInvalidation = NO;
        self.ios26HostedContentUnavailableNotified = NO;
    }
    UIView *keyboardSceneStack = nil;
    BOOL hasKeyboardLayer = NO;
    UIView *sceneStack = [self sceneStackForScene:scene
                                keyboardSceneStack:&keyboardSceneStack
                                           hasKeyboardLayerOut:&hasKeyboardLayer];

    id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
    if (sceneStack.subviews.count == 0) {
        if ([delegate respondsToSelector:@selector(contextManager:scene:externalSceneStackDidChange:containsKeyboardLayer:hostGeneration:)]) {
            [delegate contextManager:self
                               scene:scene
         externalSceneStackDidChange:keyboardSceneStack
                 containsKeyboardLayer:hasKeyboardLayer
                     hostGeneration:generation];
        }
        return;
    }

    BOOL runtimeAuthorityBecameActive = !self.runtimeHostedOrientationAuthorityActive;
    self.runtimeHostedOrientationAuthorityActive = YES;
    if (scene == self.ownedHostedScene &&
        [self.pendingRemnantReconnectBundleId isEqualToString:self.hostedBundleId]) {
        self.pendingRemnantReconnectBundleId = nil;
        self.remnantReconnectClaimBundleId = nil;
    }
    if ([delegate respondsToSelector:@selector(contextManager:scene:sceneStackDidChange:hostGeneration:)]) {
        [delegate contextManager:self scene:scene sceneStackDidChange:sceneStack hostGeneration:generation];
    }
    if (runtimeAuthorityBecameActive) {
        [self handleHostedClientSettingsUpdateForScene:scene transitionContext:nil];
    }
    if ([delegate respondsToSelector:@selector(contextManager:scene:externalSceneStackDidChange:containsKeyboardLayer:hostGeneration:)]) {
        [delegate contextManager:self
                           scene:scene
     externalSceneStackDidChange:keyboardSceneStack
             containsKeyboardLayer:hasKeyboardLayer
                 hostGeneration:generation];
    }
    UIInterfaceOrientation pendingRuntimeOrientation = self.pendingRuntimeOrientationNotification;
    BOOL shouldFlushRuntimeOrientation =
        POIsConcreteInterfaceOrientation(pendingRuntimeOrientation) &&
        self.pendingRuntimeOrientationNotificationGeneration == generation &&
        pendingRuntimeOrientation == self.hostedInterfaceOrientation;
    if (shouldFlushRuntimeOrientation) {
        self.pendingRuntimeOrientationNotification = UIInterfaceOrientationUnknown;
        self.pendingRuntimeOrientationNotificationGeneration = 0;
    }
    [self canonicalizeOwnedHostedSceneServerFrameIfNeededForScene:scene];
    [self canonicalizeSystemHostedSceneServerFrameIfNeededForScene:scene];
    [self ensureLeaseResourcesForScene:scene bundleId:self.hostedBundleId generation:generation];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)__unused context{
    BOOL layerEvent = [keyPath isEqualToString:@"layers"] && object == self.hostedLayerManager;
    BOOL contentStateEvent = [keyPath isEqualToString:@"contentState"] && object == self.observedContentStateScene;
    if (!layerEvent && !contentStateEvent) {
        return;
    }
    BOOL isPrior = [change[NSKeyValueChangeNotificationIsPriorKey] boolValue];
    void (^notifyUnavailable)(void) = ^{
        if (self.ios26HostedContentUnavailableNotified) {
            return;
        }
        id<ContextHostManagerExternalSceneDelegate> delegate = self.sceneDelegate;
        if ([delegate respondsToSelector:@selector(contextManager:scene:hostedPresentationContentDidBecomeUnavailableForBundleId:hostGeneration:)]) {
            self.ios26HostedContentUnavailableNotified = YES;
            [delegate contextManager:self
                               scene:self.hostedScene
hostedPresentationContentDidBecomeUnavailableForBundleId:self.hostedBundleId
                          hostGeneration:self.activeLeaseGeneration];
        }
    };
    void (^publish)(void) = ^{
        if (isPrior) {
            if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
                self.isForegroundLeaseActive && self.hostedScene &&
                !self.ios26HostedContentRecoveryPending &&
                self.ios26HostedContentAwaitingInvalidation) {
                notifyUnavailable();
            }
            return;
        }
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
            self.isForegroundLeaseActive && self.hostedScene &&
            !self.ios26HostedContentRecoveryPending &&
            (![self isHostedSceneContentReadyForPublication:self.hostedScene] ||
             ![self sceneHasRenderableMainLayer:self.hostedScene])) {
            self.ios26HostedContentAwaitingInvalidation = NO;
            notifyUnavailable();
            [self recoverIOS26HostedContentAfterOrientationChange];
        } else if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
                   self.isForegroundLeaseActive && self.hostedScene &&
                   !self.ios26HostedContentRecoveryPending &&
                   self.ios26HostedContentAwaitingInvalidation) {
            self.ios26HostedContentAwaitingInvalidation = NO;
            self.ios26HostedContentUnavailableNotified = NO;
        }
        [self publishUpdatedSceneStacks];
    };
    if ([NSThread isMainThread]) {
        publish();
    } else {
        dispatch_async(dispatch_get_main_queue(), publish);
    }
}

- (int)pidForBundleId:(NSString *)bundleId{
    id app = applicationForID(bundleId);
    if (!app) {
        return 0;
    }
    int pid = 0;
    SEL pidSelector = NSSelectorFromString(@"pid");
    SEL processStateSelector = NSSelectorFromString(@"processState");
    @try {
        if ([app respondsToSelector:pidSelector]) {
            NSMethodSignature *sig = [app methodSignatureForSelector:pidSelector];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:pidSelector];
                [inv setTarget:app];
                [inv invoke];
                [inv getReturnValue:&pid];
            }
        }
        if (pid <= 0 && [app respondsToSelector:processStateSelector]) {
            id processState = ((id (*)(id, SEL))objc_msgSend)(app, processStateSelector);
            if ([processState respondsToSelector:pidSelector]) {
                NSMethodSignature *sig = [processState methodSignatureForSelector:pidSelector];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setSelector:pidSelector];
                    [inv setTarget:processState];
                    [inv invoke];
                    [inv getReturnValue:&pid];
                }
            }
        }
    } @catch (__unused NSException *exception) {
        pid = 0;
    }
    return pid;
}

- (void)acquireProcessAssertionForBundleId:(NSString *)bundleId{
    if (bundleId.length == 0) {
        return;
    }
    int pid = [self pidForBundleId:bundleId];
    if (pid <= 0) {
        return;
    }

    Class targetClass = NSClassFromString(@"RBSTarget");
    Class attrClass = NSClassFromString(@"RBSLegacyAttribute");
    Class assertionClass = NSClassFromString(@"RBSAssertion");
    if (!targetClass || !attrClass || !assertionClass) {
        return;
    }

    @try {
        id target = [targetClass targetWithPid:pid];
        NSUInteger flags = kPOBKSProcessAssertionPreventTaskSuspend |
            kPOBKSProcessAssertionPreventTaskThrottleDown |
            kPOBKSProcessAssertionWantsForegroundResourcePriority |
            kPOBKSProcessAssertionPreventThrottleDownUI;
        id attr = [attrClass attributeWithReason:kPOBKSProcessAssertionReasonBackgroundUI flags:flags];
        NSString *explanation = @"PullOverX live hosted app";
        id assertion = [[assertionClass alloc] initWithExplanation:explanation
                                                            target:target
                                                        attributes:attr ? @[attr] : @[]];
        NSError *error = nil;
        BOOL acquired = [assertion acquireWithError:&error];
        if (acquired) {
            [self releaseProcessAssertion];
            self.processAssertion = assertion;
        }
    } @catch (__unused NSException *exception) {
    }
}

- (void)releaseProcessAssertion{
    id assertion = self.processAssertion;
    self.processAssertion = nil;
    if (assertion && [assertion respondsToSelector:@selector(invalidate)]) {
        @try {
            [assertion invalidate];
        } @catch (__unused NSException *exception) {
        }
    }
}

static SBApplication *applicationForID(NSString *applicationID){
    id controller = [objc_getClass("SBApplicationController") sharedInstance];
    if ([controller respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
        return [controller applicationWithBundleIdentifier:applicationID];
    }
    if ([controller respondsToSelector:@selector(applicationWithDisplayIdentifier:)]) {
        return [controller applicationWithDisplayIdentifier:applicationID];
    }
    return nil;
}

@end
