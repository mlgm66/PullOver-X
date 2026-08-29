#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>

#import "POCameraGrantState.h"

extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);

typedef BOOL (*POCameraAccessGetterIMP)(id, SEL);
typedef int (*POCameraResolveApplicationStateIMP)(id, SEL);

static POCameraAccessGetterIMP POOriginalApplicationStateMonitorHasBackgroundCameraAccess;
static POCameraAccessGetterIMP POOriginalSessionMonitorClientHasBackgroundCameraAccess;
static POCameraResolveApplicationStateIMP POOriginalSessionMonitorResolveApplicationState;
static BOOL POApplicationStateMonitorHookInstalled;
static BOOL POSessionMonitorClientHookInstalled;
static BOOL POSessionMonitorResolveStateHookInstalled;

static void POCameraGrantStateDidChange(CFNotificationCenterRef __unused center,
                                         void *__unused observer,
                                         CFStringRef __unused name,
                                         const void *__unused object,
                                         CFDictionaryRef __unused userInfo) {
    POCameraGrantStateInvalidateCaches();
}

static BOOL POIsTargetCameraDaemon(void) {
    NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString;
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
    return [processName isEqualToString:@"mediaserverd"] ||
        [processName containsString:@"cameracaptured"] ||
        [bundleIdentifier isEqualToString:@"com.apple.cameracaptured"];
}

static NSString *POCameraClientApplicationIdentifier(id object) {
    SEL applicationIDSelector = @selector(applicationID);
    if (![object respondsToSelector:applicationIDSelector]) {
        return nil;
    }

    id value = ((id (*)(id, SEL))objc_msgSend)(object, applicationIDSelector);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL POCameraGrantMatchesClient(id object) {
    NSString *grantedBundleIdentifier = POCameraForegroundGrantBundleIdentifier();
    if (grantedBundleIdentifier.length == 0) {
        return NO;
    }
    NSString *applicationIdentifier = POCameraClientApplicationIdentifier(object);
    return applicationIdentifier.length > 0 &&
        [applicationIdentifier isEqualToString:grantedBundleIdentifier];
}

static BOOL POApplicationStateMonitorHasBackgroundCameraAccess(id self, SEL _cmd) {
    if (POCameraGrantMatchesClient(self)) {
        return YES;
    }
    return POOriginalApplicationStateMonitorHasBackgroundCameraAccess
        ? POOriginalApplicationStateMonitorHasBackgroundCameraAccess(self, _cmd)
        : NO;
}

static BOOL POSessionMonitorClientHasBackgroundCameraAccess(id self, SEL _cmd) {
    if (POCameraGrantMatchesClient(self)) {
        return YES;
    }
    return POOriginalSessionMonitorClientHasBackgroundCameraAccess
        ? POOriginalSessionMonitorClientHasBackgroundCameraAccess(self, _cmd)
        : NO;
}

static BOOL POCanHookCameraMethod(Class targetClass, SEL selector, unsigned int argumentCount) {
    Method method = targetClass ? class_getInstanceMethod(targetClass, selector) : NULL;
    return method && method_getNumberOfArguments(method) == argumentCount;
}

static BOOL POCameraLegacyMonitorFlag(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) {
        return NO;
    }

    uint8_t *address = (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
    return *(BOOL *)address;
}

static unsigned int POCameraLegacyMonitorUnsignedInt(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) {
        return 0;
    }

    uint8_t *address = (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
    return *(unsigned int *)address;
}

static int POCameraLegacyMonitorClientType(id object) {
    SEL selector = @selector(clientType);
    if (!object || ![object respondsToSelector:selector]) {
        return 0;
    }

    return ((int (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL POCameraForegroundApplicationState(id object, int *state) {
    Class monitorClass = object_getClass(object);
    SEL selector = NSSelectorFromString(@"_applicationStateForBKSApplicationState:clientType:");
    Method method = monitorClass ? class_getClassMethod(monitorClass, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 4) {
        return NO;
    }

    int clientType = POCameraLegacyMonitorClientType(object);
    unsigned int bksApplicationState = POCameraLegacyMonitorUnsignedInt(object, "_bksApplicationState");
    int foregroundState = ((int (*)(id, SEL, unsigned int, int))objc_msgSend)(
        (id)monitorClass,
        selector,
        bksApplicationState,
        clientType);
    if (state) {
        *state = foregroundState;
    }
    return YES;
}

static int POSessionMonitorResolveApplicationState(id self, SEL _cmd) {
    int resolvedState = POOriginalSessionMonitorResolveApplicationState
        ? POOriginalSessionMonitorResolveApplicationState(self, _cmd)
        : 0;
    BOOL grantMatches = POCameraGrantMatchesClient(self);
    BOOL canOverride = grantMatches &&
        !POCameraLegacyMonitorFlag(self, "_invalid") &&
        !POCameraLegacyMonitorFlag(self, "_deviceIsLocked");
    int foregroundState = 0;
    BOOL hasForegroundState = canOverride &&
        POCameraForegroundApplicationState(self, &foregroundState);

    return hasForegroundState ? foregroundState : resolvedState;
}

static void POInstallCameraCompatibilityHooks(void) {
    if (!POIsTargetCameraDaemon()) {
        return;
    }

    @synchronized ([NSProcessInfo class]) {
        SEL hasBackgroundCameraAccess = @selector(hasBackgroundCameraAccess);
        if (!POApplicationStateMonitorHookInstalled) {
            Class applicationStateMonitorClient = objc_getClass("FigCaptureClientApplicationStateMonitorClient");
            if (POCanHookCameraMethod(applicationStateMonitorClient, hasBackgroundCameraAccess, 2)) {
                MSHookMessageEx(applicationStateMonitorClient,
                                hasBackgroundCameraAccess,
                                (IMP)POApplicationStateMonitorHasBackgroundCameraAccess,
                                (IMP *)&POOriginalApplicationStateMonitorHasBackgroundCameraAccess);
                POApplicationStateMonitorHookInstalled = YES;
            }
        }

        if (!POSessionMonitorClientHookInstalled) {
            Class sessionMonitorClient = objc_getClass("FigCaptureClientSessionMonitorClient");
            if (POCanHookCameraMethod(sessionMonitorClient, hasBackgroundCameraAccess, 2)) {
                MSHookMessageEx(sessionMonitorClient,
                                hasBackgroundCameraAccess,
                                (IMP)POSessionMonitorClientHasBackgroundCameraAccess,
                                (IMP *)&POOriginalSessionMonitorClientHasBackgroundCameraAccess);
                POSessionMonitorClientHookInstalled = YES;
            }
        }

        if (!POSessionMonitorResolveStateHookInstalled) {
            Class sessionMonitor = objc_getClass("FigCaptureClientSessionMonitor");
            SEL resolveApplicationState = NSSelectorFromString(@"_resolveApplicationState");
            NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
            BOOL usesLegacySessionMonitorStateMachine = version.majorVersion == 14 || version.majorVersion == 15;
            if (usesLegacySessionMonitorStateMachine &&
                POCanHookCameraMethod(sessionMonitor, resolveApplicationState, 2)) {
                MSHookMessageEx(sessionMonitor,
                                resolveApplicationState,
                                (IMP)POSessionMonitorResolveApplicationState,
                                (IMP *)&POOriginalSessionMonitorResolveApplicationState);
                POSessionMonitorResolveStateHookInstalled = YES;
            }
        }

    }
}

static void POCameraRegisterStateObservers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(center, NULL, POCameraGrantStateDidChange,
                                        (__bridge CFStringRef)POCameraGrantStateChangedNotification,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

static void POCameraImageDidLoad(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    POInstallCameraCompatibilityHooks();
}

static __attribute__((constructor)) void POCameraCompatibilityBootstrap(void) {
    if (!POIsTargetCameraDaemon()) {
        return;
    }

    POCameraRegisterStateObservers();
    // Substrate/ElleKit may inject before CMCapture.framework has registered its Objective-C classes,
    // especially on the iOS 14/15 mediaserverd path.  Install once immediately, then retry only when
    // dyld actually adds images.  Per-hook installed flags make this idempotent and avoid time-based retries.
    _dyld_register_func_for_add_image(POCameraImageDidLoad);
    POInstallCameraCompatibilityHooks();
}
