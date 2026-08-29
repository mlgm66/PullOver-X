#import <Foundation/Foundation.h>

static NSString * const POCameraGrantDomain = @"com.mlgm.pulloverx";
static NSString * const POCameraGrantBundleIdentifierKey = @"__cameraForegroundGrantBundleId";
static NSString * const POCameraGrantStateChangedNotification = @"com.mlgm.pulloverx.camera-state-changed";
static NSString *POCameraCachedGrantBundleIdentifier;
static CFAbsoluteTime POCameraGrantCacheTimestamp;
static BOOL POCameraGrantCacheValid;

NS_INLINE void POCameraGrantStateInvalidateCaches(void) {
    @synchronized (POCameraGrantDomain) {
        POCameraGrantCacheValid = NO;
    }
}

NS_INLINE void POSetCameraForegroundGrantBundleIdentifier(NSString *bundleIdentifier) {
    @synchronized (POCameraGrantDomain) {
        CFStringRef domain = (__bridge CFStringRef)POCameraGrantDomain;
        CFStringRef key = (__bridge CFStringRef)POCameraGrantBundleIdentifierKey;
        CFPropertyListRef value = bundleIdentifier.length > 0
            ? (__bridge CFPropertyListRef)bundleIdentifier
            : NULL;
        CFPreferencesSetAppValue(key, value, domain);
        CFPreferencesAppSynchronize(domain);
        POCameraCachedGrantBundleIdentifier = [bundleIdentifier copy];
        POCameraGrantCacheTimestamp = CFAbsoluteTimeGetCurrent();
        POCameraGrantCacheValid = YES;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)POCameraGrantStateChangedNotification,
                                         NULL,
                                         NULL,
                                         true);
}

NS_INLINE NSString *POCameraForegroundGrantBundleIdentifier(void) {
    @synchronized (POCameraGrantDomain) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (POCameraGrantCacheValid && now - POCameraGrantCacheTimestamp < 0.25) {
            return POCameraCachedGrantBundleIdentifier;
        }

        CFStringRef domain = (__bridge CFStringRef)POCameraGrantDomain;
        CFStringRef key = (__bridge CFStringRef)POCameraGrantBundleIdentifierKey;
        CFPreferencesAppSynchronize(domain);
        CFPropertyListRef value = CFPreferencesCopyAppValue(key, domain);
        NSString *bundleIdentifier = nil;
        if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
            bundleIdentifier = [(__bridge NSString *)value copy];
        }
        if (value) {
            CFRelease(value);
        }
        POCameraCachedGrantBundleIdentifier = bundleIdentifier.length > 0 ? bundleIdentifier : nil;
        POCameraGrantCacheTimestamp = now;
        POCameraGrantCacheValid = YES;
        return POCameraCachedGrantBundleIdentifier;
    }
}
