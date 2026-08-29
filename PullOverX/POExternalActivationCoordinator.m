#import "POExternalActivationCoordinator.h"

#import <dlfcn.h>
#import <objc/message.h>

#import "ContextHostManager.h"
#import "POApplicationHelper.h"
#import "PullOverWindow.h"

typedef void (^POExternalOpenCompletion)(NSError *error);

static id POExternalReadObject(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *POExternalBundleIdentifier(id object) {
    id value = POExternalReadObject(object, NSSelectorFromString(@"bundleIdentifier"));
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *POExternalBundleIdentifierOrString(id object) {
    if ([object isKindOfClass:[NSString class]]) {
        return object;
    }
    return POExternalBundleIdentifier(object);
}

static NSString *POExternalStringConstant(const char *symbolName) {
    if (!symbolName) {
        return nil;
    }
    void *address = dlsym(RTLD_DEFAULT, symbolName);
    if (!address) {
        return nil;
    }
    NSString * __unsafe_unretained *symbol = (NSString * __unsafe_unretained *)address;
    return [*symbol isKindOfClass:[NSString class]] ? *symbol : nil;
}

static NSString *POExternalActivateSuspendedOptionKey(void) {
    static NSString *key;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        key = POExternalStringConstant("FBSOpenApplicationOptionKeyActivateSuspended");
    });
    return key;
}

static NSString *POExternalPayloadOptionsKey(void) {
    static NSString *key;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        key = POExternalStringConstant("FBSOpenApplicationOptionKeyPayloadOptions");
    });
    return key;
}

static id POExternalOpenOptions(id request) {
    return POExternalReadObject(request, NSSelectorFromString(@"options"));
}

static NSDictionary *POExternalOpenOptionsDictionary(id request) {
    id options = POExternalOpenOptions(request);
    id dictionary = [options isKindOfClass:[NSDictionary class]]
        ? options
        : POExternalReadObject(options, NSSelectorFromString(@"dictionary"));
    return [dictionary isKindOfClass:[NSDictionary class]] ? dictionary : nil;
}

static NSURL *POExternalOpenURL(id request) {
    id options = POExternalOpenOptions(request);
    id value = POExternalReadObject(options, NSSelectorFromString(@"url"));
    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }
    NSDictionary *dictionary = [options isKindOfClass:[NSDictionary class]]
        ? options
        : POExternalReadObject(options, NSSelectorFromString(@"dictionary"));
    value = [dictionary isKindOfClass:[NSDictionary class]] ? dictionary[@"__PayloadURL"] : nil;
    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }
    return [value isKindOfClass:[NSString class]] ? [NSURL URLWithString:value] : nil;
}

static NSDictionary *POExternalOptionsDictionary(id options) {
    if ([options isKindOfClass:[NSDictionary class]]) {
        return options;
    }
    id dictionary = POExternalReadObject(options, NSSelectorFromString(@"dictionary"));
    return [dictionary isKindOfClass:[NSDictionary class]] ? dictionary : nil;
}

static NSURL *POExternalURLFromOptions(id options) {
    id value = POExternalReadObject(options, NSSelectorFromString(@"url"));
    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }
    NSDictionary *dictionary = POExternalOptionsDictionary(options);
    value = dictionary[@"__PayloadURL"];
    if ([value isKindOfClass:[NSURL class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [NSURL URLWithString:value];
    }
    return nil;
}

static NSString *POExternalPayloadSourceBundleIdentifierFromOptions(id options) {
    NSDictionary *dictionary = POExternalOptionsDictionary(options);
    NSString *payloadOptionsKey = POExternalPayloadOptionsKey();
    if (payloadOptionsKey.length == 0) {
        return nil;
    }
    id payloadOptions = dictionary[payloadOptionsKey];
    if (![payloadOptions isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    id sourceBundleId = payloadOptions[UIApplicationLaunchOptionsSourceApplicationKey];
    return [sourceBundleId isKindOfClass:[NSString class]] ? sourceBundleId : nil;
}

static NSString *POExternalPayloadSourceBundleIdentifier(id request) {
    return POExternalPayloadSourceBundleIdentifierFromOptions(POExternalOpenOptions(request));
}

static NSString *POExternalOriginBundleIdentifier(id origin) {
    NSString *bundleId = POExternalBundleIdentifierOrString(origin);
    if (bundleId.length > 0) {
        return bundleId;
    }
    for (NSString *selectorName in @[ @"clientProcess", @"process", @"originatingProcess", @"sourceProcess" ]) {
        id nested = POExternalReadObject(origin, NSSelectorFromString(selectorName));
        bundleId = POExternalBundleIdentifier(nested);
        if (bundleId.length > 0) {
            return bundleId;
        }
    }
    return nil;
}

static NSString *POExternalTargetBundleIdentifierFromRequest(id request) {
    for (NSString *selectorName in @[
        @"bundleIdentifier",
        @"targetBundleIdentifier",
        @"applicationBundleIdentifier",
        @"applicationIdentifier"
    ]) {
        NSString *bundleId = POExternalBundleIdentifierOrString(
            POExternalReadObject(request, NSSelectorFromString(selectorName)));
        if (bundleId.length > 0) {
            return bundleId;
        }
    }

    for (NSString *selectorName in @[@"application", @"targetApplication"]) {
        NSString *bundleId = POExternalBundleIdentifierOrString(
            POExternalReadObject(request, NSSelectorFromString(selectorName)));
        if (bundleId.length > 0) {
            return bundleId;
        }
    }
    return nil;
}

static BOOL POExternalIsUserApplicationBundleIdentifier(NSString *bundleId) {
    return bundleId.length > 0 &&
        [POApplicationHelper isUserFacingApplicationBundleId:bundleId];
}

static NSString *POExternalAttributedUserSourceBundleIdentifier(NSString *directSourceBundleId,
                                                                 NSString *payloadSourceBundleId,
                                                                 NSURL *openURL,
                                                                 BOOL documentOpenRequest) {
    if (POExternalIsUserApplicationBundleIdentifier(directSourceBundleId)) {
        return directSourceBundleId;
    }
    if (POExternalIsUserApplicationBundleIdentifier(payloadSourceBundleId)) {
        return payloadSourceBundleId;
    }
    if (documentOpenRequest && openURL.isFileURL && directSourceBundleId.length > 0 &&
        !POExternalIsUserApplicationBundleIdentifier(directSourceBundleId)) {
        NSString *frontMostBundleId = [POApplicationHelper frontMostBundleId];
        if (POExternalIsUserApplicationBundleIdentifier(frontMostBundleId)) {
            return frontMostBundleId;
        }
    }
    return nil;
}

static BOOL POExternalIsValidURL(NSURL *openURL) {
    return openURL != nil && openURL.scheme.length > 0 && openURL.absoluteString.length > 0;
}

static BOOL POExternalPullOverIsStableClosed(void) {
    PullOverWindow *window = (PullOverWindow *)[PullOverWindow sharedWindow];
    PullOverViewController *controller = window.controller;
    return controller != nil && !controller.isPanelActive && !controller.isPanelTransitioning;
}

static id POExternalOptionsByAddingActivateSuspended(id options) {
    NSDictionary *dictionary = POExternalOptionsDictionary(options);
    NSString *activateSuspendedKey = POExternalActivateSuspendedOptionKey();
    if (!dictionary || activateSuspendedKey.length == 0) {
        return nil;
    }
    NSMutableDictionary *mutableDictionary = [dictionary mutableCopy];
    mutableDictionary[activateSuspendedKey] = @YES;

    SEL setDictionarySelector = NSSelectorFromString(@"setDictionary:");
    if (options && ![options isKindOfClass:[NSDictionary class]] &&
        [options respondsToSelector:setDictionarySelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(options, setDictionarySelector, mutableDictionary);
        return options;
    }
    if ([options isKindOfClass:[NSDictionary class]]) {
        return [mutableDictionary copy];
    }
    return nil;
}

static BOOL POExternalCanPrepareSuspendedOpenRequest(id request) {
    id options = POExternalOpenOptions(request);
    NSDictionary *dictionary = POExternalOpenOptionsDictionary(request);
    NSString *activateSuspendedKey = POExternalActivateSuspendedOptionKey();
    SEL setDictionarySelector = NSSelectorFromString(@"setDictionary:");
    return dictionary != nil && activateSuspendedKey.length > 0 &&
        [options respondsToSelector:setDictionarySelector];
}

static BOOL POExternalPrepareSuspendedOpenRequest(id request) {
    if (!POExternalCanPrepareSuspendedOpenRequest(request)) {
        return NO;
    }
    id options = POExternalOpenOptions(request);
    NSDictionary *dictionary = POExternalOpenOptionsDictionary(request);
    NSMutableDictionary *mutableDictionary = [dictionary mutableCopy];
    mutableDictionary[POExternalActivateSuspendedOptionKey()] = @YES;
    ((void (*)(id, SEL, id))objc_msgSend)(options, NSSelectorFromString(@"setDictionary:"), mutableDictionary);
    return YES;
}

static NSString *POExternalTargetBundleIdentifier(id transitionRequest,
                                                  NSString *hostedBundleId,
                                                  NSString *sourceBundleId) {
    id entities = POExternalReadObject(transitionRequest,
                                       NSSelectorFromString(@"toApplicationSceneEntities"));
    if (![entities respondsToSelector:@selector(objectEnumerator)]) {
        return nil;
    }

    NSString *fallbackTarget = nil;
    NSEnumerator *enumerator = [entities objectEnumerator];
    for (id entity in enumerator) {
        id application = POExternalReadObject(entity, NSSelectorFromString(@"application"));
        NSString *bundleId = POExternalBundleIdentifier(application);
        if (bundleId.length == 0) {
            continue;
        }
        if (![bundleId isEqualToString:sourceBundleId] &&
            [bundleId isEqualToString:hostedBundleId]) {
            return bundleId;
        }
        if (![bundleId isEqualToString:sourceBundleId] && fallbackTarget.length == 0) {
            fallbackTarget = bundleId;
        }
    }
    return fallbackTarget;
}

static BOOL POExternalTransitionContainsBundleIdentifier(id transitionRequest,
                                                          NSString *bundleId) {
    if (bundleId.length == 0) {
        return NO;
    }
    id entities = POExternalReadObject(transitionRequest,
                                       NSSelectorFromString(@"toApplicationSceneEntities"));
    if (![entities respondsToSelector:@selector(objectEnumerator)]) {
        return NO;
    }
    for (id entity in [entities objectEnumerator]) {
        id application = POExternalReadObject(entity, NSSelectorFromString(@"application"));
        if ([POExternalBundleIdentifier(application) isEqualToString:bundleId]) {
            return YES;
        }
    }
    return NO;
}

@interface POExternalActivationCoordinator ()
@property (nonatomic, assign) NSUInteger routeRequestGeneration;
@property (nonatomic, assign) NSUInteger nativeRouteGeneration;
@property (nonatomic, assign) BOOL nativeRouteInFlight;
@property (nonatomic, copy) NSString *pendingNativeTargetBundleId;

- (BOOL)beginNativeRouteForTargetBundleId:(NSString *)targetBundleId
                           sourceBundleId:(NSString *)sourceBundleId;
- (BOOL)isNativeRouteGenerationCurrent:(NSUInteger)generation;
- (void)finishNativeRouteForGeneration:(NSUInteger)generation;
- (void)restoreNativeTargetBundleId:(NSString *)targetBundleId
                         generation:(NSUInteger)generation;
- (void)completeNativeRouteForGeneration:(NSUInteger)generation
                          targetBundleId:(NSString *)targetBundleId
                                   error:(NSError *)error;
@end

@implementation POExternalActivationCoordinator

+ (instancetype)sharedInstance {
    static POExternalActivationCoordinator *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [POExternalActivationCoordinator new];
    });
    return sharedInstance;
}

- (id)prepareOpenApplicationRequestIfNeeded:(id)request completion:(id)completion {
    if (!NSThread.isMainThread || !request || ![POApplicationHelper isEnabled]) {
        return completion;
    }

    NSURL *openURL = POExternalOpenURL(request);
    if (!POExternalIsValidURL(openURL)) {
        return completion;
    }
    NSDictionary *openOptions = POExternalOpenOptionsDictionary(request);
    BOOL documentOpenRequest = [openOptions[@"__DocumentOpen4LS"] boolValue];
    NSString *targetBundleId = POExternalTargetBundleIdentifierFromRequest(request);
    if (!POExternalIsUserApplicationBundleIdentifier(targetBundleId)) {
        return completion;
    }

    ContextHostManager *manager = [ContextHostManager sharedInstance];
    NSString *hostedBundleId = [ContextHostManager activeHostedBundleId];
    PullOverWindow *pullOverWindow = (PullOverWindow *)[PullOverWindow sharedWindow];
    id clientProcess = POExternalReadObject(request, NSSelectorFromString(@"clientProcess"));
    NSString *directSourceBundleId = POExternalBundleIdentifierOrString(clientProcess);
    NSString *payloadSourceBundleId = POExternalPayloadSourceBundleIdentifier(request);

    BOOL hostedRouteAvailable = manager.isForegroundLeaseActive &&
        hostedBundleId.length > 0 && pullOverWindow.controller.isPanelActive;
    if (hostedRouteAvailable) {
        BOOL directHostedSource = [directSourceBundleId isEqualToString:hostedBundleId];
        BOOL payloadHostedSource = [payloadSourceBundleId isEqualToString:hostedBundleId];
        BOOL directSourceIsUserApplication = POExternalIsUserApplicationBundleIdentifier(directSourceBundleId);
        BOOL directSourceIsBroker = directSourceBundleId.length > 0 && !directSourceIsUserApplication;
        BOOL payloadSourceIsBroker = payloadSourceBundleId.length > 0 &&
            !POExternalIsUserApplicationBundleIdentifier(payloadSourceBundleId);
        BOOL payloadHostedBroker = !directHostedSource && payloadHostedSource &&
            !directSourceIsUserApplication;
        BOOL payloadAttributableToHostedFlow = payloadSourceBundleId.length == 0 ||
            payloadHostedSource || payloadSourceIsBroker;
        BOOL brokeredDocumentFromPullOver = !directHostedSource && !payloadHostedBroker &&
            documentOpenRequest && openURL.isFileURL && directSourceIsBroker &&
            payloadAttributableToHostedFlow;

        if (directHostedSource || payloadHostedBroker || brokeredDocumentFromPullOver) {
            NSString *sourceBundleId = hostedBundleId;
            if ([targetBundleId isEqualToString:sourceBundleId]) {
                return completion;
            }

            SEL trustedSelector = NSSelectorFromString(@"isTrusted");
            SEL setTrustedSelector = NSSelectorFromString(@"setTrusted:");
            if (![request respondsToSelector:setTrustedSelector] ||
                ![request respondsToSelector:trustedSelector] ||
                !POExternalCanPrepareSuspendedOpenRequest(request)) {
                return completion;
            }

            BOOL isTrusted = ((BOOL (*)(id, SEL))objc_msgSend)(request, trustedSelector);
            if (!isTrusted && !directHostedSource) {
                return completion;
            }

            if (!POExternalPrepareSuspendedOpenRequest(request)) {
                return completion;
            }
            if (!isTrusted) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(request, setTrustedSelector, YES);
            }

            NSUInteger hostGeneration = manager.activeLeaseGeneration;
            NSUInteger routeGeneration = ++self.routeRequestGeneration;
            POExternalOpenCompletion originalCompletion = completion;
            POExternalOpenCompletion routedCompletion = ^(NSError *error) {
                if (originalCompletion) {
                    originalCompletion(error);
                }
                if (error) {
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    ContextHostManager *currentManager = [ContextHostManager sharedInstance];
                    NSString *currentHostedBundleId = [ContextHostManager activeHostedBundleId];
                    if (routeGeneration != self.routeRequestGeneration ||
                        !currentManager.isForegroundLeaseActive ||
                        currentManager.activeLeaseGeneration != hostGeneration ||
                        ![currentHostedBundleId isEqualToString:sourceBundleId]) {
                        return;
                    }

                    PullOverWindow *currentWindow = (PullOverWindow *)[PullOverWindow sharedWindow];
                    [currentWindow.controller routeExternalApplicationInsidePullOver:targetBundleId];
                });
            };
            return [routedCompletion copy];
        }
    }

    NSString *nativeSourceBundleId = POExternalAttributedUserSourceBundleIdentifier(
        directSourceBundleId, payloadSourceBundleId, openURL, documentOpenRequest);
    SEL trustedSelector = NSSelectorFromString(@"isTrusted");
    if (![POApplicationHelper isExternalURLRoutingTargetBundleId:targetBundleId] ||
        nativeSourceBundleId.length == 0 ||
        [targetBundleId isEqualToString:nativeSourceBundleId] ||
        !POExternalPullOverIsStableClosed() ||
        ![request respondsToSelector:trustedSelector] ||
        !((BOOL (*)(id, SEL))objc_msgSend)(request, trustedSelector) ||
        !POExternalCanPrepareSuspendedOpenRequest(request)) {
        return completion;
    }

    if (![self beginNativeRouteForTargetBundleId:targetBundleId
                                  sourceBundleId:nativeSourceBundleId]) {
        return completion;
    }
    if (!POExternalPrepareSuspendedOpenRequest(request)) {
        [self finishNativeRouteForGeneration:self.nativeRouteGeneration];
        return completion;
    }

    NSUInteger nativeGeneration = self.nativeRouteGeneration;
    POExternalOpenCompletion originalCompletion = completion;
    POExternalOpenCompletion routedCompletion = ^(NSError *error) {
        if (originalCompletion) {
            originalCompletion(error);
        }
        [self completeNativeRouteForGeneration:nativeGeneration
                                targetBundleId:targetBundleId
                                         error:error];
    };
    return [routedCompletion copy];
}

- (id)prepareTrustedWorkspaceOpenApplication:(id)application
                                     options:(id)options
                                      origin:(id)origin
                                      result:(id)result
                                routedResult:(id __autoreleasing *)routedResult {
    if (routedResult) {
        *routedResult = result;
    }
    if (!NSThread.isMainThread || !application || !options || ![POApplicationHelper isEnabled]) {
        return options;
    }

    NSString *targetBundleId = [application isKindOfClass:[NSString class]]
        ? application
        : POExternalBundleIdentifier(application);
    NSURL *openURL = POExternalURLFromOptions(options);
    if (!POExternalIsUserApplicationBundleIdentifier(targetBundleId) ||
        !POExternalIsValidURL(openURL)) {
        return options;
    }

    NSDictionary *openOptions = POExternalOptionsDictionary(options);
    BOOL documentOpenRequest = [openOptions[@"__DocumentOpen4LS"] boolValue];
    ContextHostManager *manager = [ContextHostManager sharedInstance];
    NSString *hostedBundleId = [ContextHostManager activeHostedBundleId];
    PullOverWindow *pullOverWindow = (PullOverWindow *)[PullOverWindow sharedWindow];
    NSString *originBundleId = POExternalOriginBundleIdentifier(origin);
    NSString *payloadSourceBundleId = POExternalPayloadSourceBundleIdentifierFromOptions(options);

    BOOL hostedRouteAvailable = manager.isForegroundLeaseActive &&
        hostedBundleId.length > 0 && pullOverWindow.controller.isPanelActive;
    if (hostedRouteAvailable && ![targetBundleId isEqualToString:hostedBundleId] &&
        documentOpenRequest && openURL.isFileURL) {
        BOOL originIsUserApplication = POExternalIsUserApplicationBundleIdentifier(originBundleId);
        BOOL originIsBroker = originBundleId.length > 0 && !originIsUserApplication;
        BOOL payloadHostedSource = [payloadSourceBundleId isEqualToString:hostedBundleId];
        BOOL payloadSourceIsBroker = payloadSourceBundleId.length > 0 &&
            !POExternalIsUserApplicationBundleIdentifier(payloadSourceBundleId);
        BOOL payloadAttributableToHostedFlow = payloadSourceBundleId.length == 0 ||
            payloadHostedSource || payloadSourceIsBroker;

        if (!((!originIsBroker && !payloadSourceIsBroker) ||
              originIsUserApplication || !payloadAttributableToHostedFlow)) {
            id preparedOptions = POExternalOptionsByAddingActivateSuspended(options);
            if (!preparedOptions) {
                return options;
            }

            NSUInteger hostGeneration = manager.activeLeaseGeneration;
            NSUInteger routeGeneration = ++self.routeRequestGeneration;
            NSString *sourceBundleId = [hostedBundleId copy];
            POExternalOpenCompletion originalResult = result;
            POExternalOpenCompletion wrappedResult = ^(NSError *error) {
                if (originalResult) {
                    originalResult(error);
                }
                if (error) {
                    return;
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    ContextHostManager *currentManager = [ContextHostManager sharedInstance];
                    NSString *currentHostedBundleId = [ContextHostManager activeHostedBundleId];
                    if (routeGeneration != self.routeRequestGeneration ||
                        !currentManager.isForegroundLeaseActive ||
                        currentManager.activeLeaseGeneration != hostGeneration ||
                        ![currentHostedBundleId isEqualToString:sourceBundleId]) {
                        return;
                    }
                    PullOverWindow *currentWindow = (PullOverWindow *)[PullOverWindow sharedWindow];
                    [currentWindow.controller routeExternalApplicationInsidePullOver:targetBundleId];
                });
            };
            if (routedResult) {
                *routedResult = [wrappedResult copy];
            }

            return preparedOptions;
        }
    }

    NSString *nativeSourceBundleId = POExternalAttributedUserSourceBundleIdentifier(
        originBundleId, payloadSourceBundleId, openURL, documentOpenRequest);
    if (![POApplicationHelper isExternalURLRoutingTargetBundleId:targetBundleId] ||
        nativeSourceBundleId.length == 0 ||
        [targetBundleId isEqualToString:nativeSourceBundleId] ||
        !POExternalPullOverIsStableClosed()) {
        return options;
    }

    if (![self beginNativeRouteForTargetBundleId:targetBundleId
                                  sourceBundleId:nativeSourceBundleId]) {
        return options;
    }

    id preparedOptions = POExternalOptionsByAddingActivateSuspended(options);
    if (!preparedOptions) {
        [self finishNativeRouteForGeneration:self.nativeRouteGeneration];
        return options;
    }

    NSUInteger nativeGeneration = self.nativeRouteGeneration;
    POExternalOpenCompletion originalResult = result;
    POExternalOpenCompletion wrappedResult = ^(NSError *error) {
        if (originalResult) {
            originalResult(error);
        }
        [self completeNativeRouteForGeneration:nativeGeneration
                                targetBundleId:targetBundleId
                                         error:error];
    };
    if (routedResult) {
        *routedResult = [wrappedResult copy];
    }

    return preparedOptions;
}

- (BOOL)beginNativeRouteForTargetBundleId:(NSString *)targetBundleId
                           sourceBundleId:(NSString *)sourceBundleId {
    if (!NSThread.isMainThread || self.nativeRouteInFlight ||
        targetBundleId.length == 0 || sourceBundleId.length == 0) {
        return NO;
    }

    self.nativeRouteGeneration += 1;
    NSUInteger generation = self.nativeRouteGeneration;
    self.nativeRouteInFlight = YES;
    self.pendingNativeTargetBundleId = [targetBundleId copy];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![self isNativeRouteGenerationCurrent:generation]) {
            return;
        }
        [self restoreNativeTargetBundleId:targetBundleId
                               generation:generation];
    });
    return YES;
}

- (BOOL)isNativeRouteGenerationCurrent:(NSUInteger)generation {
    return self.nativeRouteInFlight && self.nativeRouteGeneration == generation;
}

- (void)finishNativeRouteForGeneration:(NSUInteger)generation {
    if (!self.nativeRouteInFlight || self.nativeRouteGeneration != generation) {
        return;
    }
    self.nativeRouteInFlight = NO;
    self.pendingNativeTargetBundleId = nil;
    self.nativeRouteGeneration += 1;
}

- (void)restoreNativeTargetBundleId:(NSString *)targetBundleId
                         generation:(NSUInteger)generation {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self restoreNativeTargetBundleId:targetBundleId
                                   generation:generation];
        });
        return;
    }
    if (![self isNativeRouteGenerationCurrent:generation]) {
        return;
    }

    PullOverWindow *pullOverWindow = (PullOverWindow *)[PullOverWindow sharedWindow];
    [pullOverWindow.controller prepareForNativeApplicationTakeover:targetBundleId];
    [[UIApplication sharedApplication] launchApplicationWithIdentifier:targetBundleId suspended:NO];
    [self finishNativeRouteForGeneration:generation];
}

- (void)completeNativeRouteForGeneration:(NSUInteger)generation
                          targetBundleId:(NSString *)targetBundleId
                                   error:(NSError *)error {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self completeNativeRouteForGeneration:generation
                                    targetBundleId:targetBundleId
                                             error:error];
        });
        return;
    }
    if (![self isNativeRouteGenerationCurrent:generation]) {
        return;
    }
    if (error) {
        [self finishNativeRouteForGeneration:generation];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isNativeRouteGenerationCurrent:generation]) {
            return;
        }
        PullOverWindow *pullOverWindow = (PullOverWindow *)[PullOverWindow sharedWindow];
        BOOL accepted = [pullOverWindow.controller
            openExternallyActivatedApplicationInPullOver:targetBundleId];
        if (accepted) {
            [self finishNativeRouteForGeneration:generation];
            return;
        }
        [self restoreNativeTargetBundleId:targetBundleId
                               generation:generation];
    });
}

- (void)prepareNativeTakeoverForTransitionRequestIfNeeded:(id)transitionRequest {
    if (!NSThread.isMainThread || !transitionRequest || ![POApplicationHelper isEnabled]) {
        return;
    }

    NSString *pendingTargetBundleId = self.pendingNativeTargetBundleId;
    if (self.nativeRouteInFlight &&
        POExternalTransitionContainsBundleIdentifier(transitionRequest, pendingTargetBundleId)) {
        return;
    }

    ContextHostManager *manager = [ContextHostManager sharedInstance];
    NSString *hostedBundleId = [ContextHostManager activeHostedBundleId];
    if (!manager.isForegroundLeaseActive || hostedBundleId.length == 0) {
        return;
    }

    id originatingProcess = POExternalReadObject(transitionRequest,
                                                 NSSelectorFromString(@"originatingProcess"));
    NSString *sourceBundleId = POExternalBundleIdentifierOrString(originatingProcess);
    NSString *targetBundleId = POExternalTargetBundleIdentifier(transitionRequest,
                                                                hostedBundleId,
                                                                sourceBundleId);
    if (targetBundleId.length == 0 || [targetBundleId isEqualToString:sourceBundleId]) {
        return;
    }

    BOOL hostedIsTarget = [hostedBundleId isEqualToString:targetBundleId];
    BOOL hostedIsSource = [hostedBundleId isEqualToString:sourceBundleId];
    if (!hostedIsTarget || hostedIsSource) {
        return;
    }

    PullOverWindow *pullOverWindow = (PullOverWindow *)[PullOverWindow sharedWindow];
    [pullOverWindow.controller prepareForNativeApplicationTakeover:targetBundleId];
}

@end
