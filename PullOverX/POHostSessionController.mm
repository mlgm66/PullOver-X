#import "POHostSessionController.h"

#import <QuartzCore/QuartzCore.h>

#import "POApplicationHelper.h"


static const CFTimeInterval kPOOwnedSceneCapabilityWindow = 1.0;
static const CFTimeInterval kPOOwnedSceneFallbackProcessDrainDelay = 0.12;

@interface POHostSessionController ()
@property (nonatomic, strong) ContextHostManager *manager;
@property (nonatomic, readwrite) POHostSessionState state;
@property (nonatomic, readwrite) NSUInteger currentGeneration;
@property (nonatomic, copy, readwrite) NSString *requestedBundleId;
@property (nonatomic, strong) FBScene *preparedScene;
@property (nonatomic, assign) BOOL activationRequested;
@property (nonatomic, assign) BOOL preparationRequestedForGeneration;
@property (nonatomic, assign) NSUInteger probeScheduleIndex;
@property (nonatomic, assign) NSUInteger probeToken;
@property (nonatomic, copy) NSString *prewarmedBundleId;
@property (nonatomic, assign) CFTimeInterval prewarmTimestamp;
@property (nonatomic, weak) FBScene *ownedSceneCandidate;
@property (nonatomic, assign) CFTimeInterval ownedSceneCandidateActivationTime;
@property (nonatomic, assign) BOOL systemDefaultFallbackActive;
- (BOOL)shouldFallbackOwnedSceneCandidateForBundleId:(NSString *)bundleId
                                          generation:(NSUInteger)generation;
- (void)fallbackOwnedSceneCandidateToSystemDefaultForBundleId:(NSString *)bundleId
                                                    generation:(NSUInteger)generation;
@end

@implementation POHostSessionController

- (instancetype)initWithManager:(ContextHostManager *)manager {
    self = [super init];
    if (self) {
        _manager = manager ?: [ContextHostManager sharedInstance];
        _manager.sceneDelegate = self;
        _state = POHostSessionStateIdle;
    }
    return self;
}

- (void)dealloc {
    if (_manager.sceneDelegate == self) {
        [_manager releaseForegroundLeaseDiscardingOwnedScene];
        _manager.sceneDelegate = nil;
    }
}

- (NSString *)activeBundleId {
    return self.manager.activeHostedBundleId;
}

- (NSUInteger)beginGenerationForBundleId:(NSString *)bundleId activationRequested:(BOOL)activationRequested {
    self.probeToken += 1;

    self.currentGeneration += 1;
    if (self.currentGeneration == 0) {
        self.currentGeneration = 1;
    }
    self.requestedBundleId = [bundleId copy];
    self.activationRequested = activationRequested;
    self.preparationRequestedForGeneration = NO;
    self.probeScheduleIndex = 0;
    self.ownedSceneCandidate = nil;
    self.ownedSceneCandidateActivationTime = 0;
    self.systemDefaultFallbackActive = NO;
    return self.currentGeneration;
}

- (BOOL)isCurrentGeneration:(NSUInteger)generation bundleId:(NSString *)bundleId {
    return generation != 0 && generation == self.currentGeneration &&
        bundleId.length > 0 && [self.requestedBundleId isEqualToString:bundleId];
}

- (void)prepareBundleId:(NSString *)bundleId {
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }
    if (!self.activationRequested && [self.requestedBundleId isEqualToString:bundleId] &&
        (self.state == POHostSessionStatePreparing ||
         self.state == POHostSessionStateWaitingForScene ||
         self.state == POHostSessionStatePrepared)) {
        return;
    }

    self.preparedScene = nil;
    NSUInteger generation = [self beginGenerationForBundleId:bundleId activationRequested:NO];
    self.state = POHostSessionStatePreparing;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isCurrentGeneration:generation bundleId:bundleId] && !self.activationRequested) {
            [self probeBundleId:bundleId generation:generation];
        }
    });
}

- (void)prewarmBundleId:(NSString *)bundleId {
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId] ||
        [bundleId isEqualToString:self.activeBundleId] ||
        [self isFrontmostBundleId:bundleId]) {
        return;
    }

    if ([self.manager requiresOwnedHostedSceneForBundleId:bundleId]) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if ([self.prewarmedBundleId isEqualToString:bundleId] && now - self.prewarmTimestamp < 0.75) {
        return;
    }
    self.prewarmedBundleId = [bundleId copy];
    self.prewarmTimestamp = now;
    [self.manager requestPreparationForBundleId:bundleId];
}

- (void)activateBundleId:(NSString *)bundleId {
    if (bundleId.length == 0 ||
        ![POApplicationHelper isUserFacingApplicationBundleId:bundleId]) {
        return;
    }

    if ([self isFrontmostBundleId:bundleId]) {
        NSUInteger generation = [self beginGenerationForBundleId:bundleId activationRequested:NO];
        [self handleCannotHostFrontmostBundleId:bundleId generation:generation];
        return;
    }
    if (self.activationRequested && [self.requestedBundleId isEqualToString:bundleId] &&
        (self.state == POHostSessionStatePreparing ||
         self.state == POHostSessionStateWaitingForScene ||
         self.state == POHostSessionStatePrepared ||
         self.state == POHostSessionStateActivating ||
         self.state == POHostSessionStateLive)) {
        if (self.state != POHostSessionStateLive) {
            return;
        }
        BOOL sceneValid = self.preparedScene != nil &&
            (![self.preparedScene respondsToSelector:@selector(isValid)] || [(id)self.preparedScene isValid]);
        BOOL liveLeaseValid = sceneValid &&
            [self.manager isProcessRunningForBundleId:bundleId] &&
            [self.manager isForegroundLeaseActiveForScene:self.preparedScene
                                                  bundleId:bundleId
                                                generation:self.currentGeneration];
        if (liveLeaseValid) {
            return;
        }
        [self releaseActiveSessionPreservingPresentationDiscardOwnedScene:YES];
    }

    BOOL continuingSamePrepare = !self.activationRequested &&
        [self.requestedBundleId isEqualToString:bundleId] &&
        (self.state == POHostSessionStatePreparing ||
         self.state == POHostSessionStateWaitingForScene ||
         self.state == POHostSessionStatePrepared);
    BOOL prewarmIsFresh = [self.prewarmedBundleId isEqualToString:bundleId] &&
        CACurrentMediaTime() - self.prewarmTimestamp < 1.5;
    BOOL preparationAlreadyRequested = (continuingSamePrepare && self.preparationRequestedForGeneration) || prewarmIsFresh;
    if (prewarmIsFresh) {
        self.prewarmedBundleId = nil;
        self.prewarmTimestamp = 0;
    }

    FBScene *reusablePreparedScene = nil;
    if (continuingSamePrepare && self.preparedScene) {
        BOOL sceneIsValid = YES;
        if ([self.preparedScene respondsToSelector:@selector(isValid)]) {
            sceneIsValid = [(id)self.preparedScene isValid];
        }
        if (sceneIsValid) {
            reusablePreparedScene = self.preparedScene;
        }
    }

    NSUInteger generation = [self beginGenerationForBundleId:bundleId activationRequested:YES];
    BOOL requiresOwnedScene = [self.manager requiresOwnedHostedSceneForBundleId:bundleId];

    [self.manager prepareHostingIntentForBundleId:bundleId];

    self.preparationRequestedForGeneration = preparationAlreadyRequested;
    if (reusablePreparedScene) {
        self.preparedScene = reusablePreparedScene;
        self.state = POHostSessionStatePrepared;
    } else {
        self.preparedScene = nil;
        self.state = POHostSessionStatePreparing;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isCurrentGeneration:generation bundleId:bundleId] || !self.activationRequested) {
            return;
        }
        if ([self isFrontmostBundleId:bundleId]) {
            [self handleCannotHostFrontmostBundleId:bundleId generation:generation];
            return;
        }

        if (!self.preparedScene && [self.manager isProcessRunningForBundleId:bundleId]) {
            FBScene *warmScene = [self.manager probeSceneForBundleId:bundleId];
            if (requiresOwnedScene && !self.systemDefaultFallbackActive && warmScene &&
                ![self.manager isOwnedHostedScene:warmScene bundleId:bundleId]) {
                warmScene = nil;
            }
            if (warmScene) {
                self.preparedScene = warmScene;
                self.state = POHostSessionStatePrepared;
                self.preparationRequestedForGeneration = YES;
            }
        }

        if (self.preparedScene) {
            [self commitPreparedSceneForBundleId:bundleId generation:generation];
            return;
        }

        [self probeBundleId:bundleId generation:generation];
    });
}

- (void)beginClosingPreservingActiveLease {
    self.currentGeneration += 1;
    if (self.currentGeneration == 0) {
        self.currentGeneration = 1;
    }
    self.probeToken += 1;
    self.activationRequested = NO;
    self.requestedBundleId = nil;
    self.preparedScene = nil;
    self.preparationRequestedForGeneration = NO;
    self.ownedSceneCandidate = nil;
    self.ownedSceneCandidateActivationTime = 0;
    self.systemDefaultFallbackActive = NO;
    self.state = self.manager.isForegroundLeaseActive ? POHostSessionStateReleasing : POHostSessionStateIdle;
}

- (void)releaseActiveSessionPreservingPresentationDiscardOwnedScene:(BOOL)discardOwnedScene {
    self.state = POHostSessionStateReleasing;
    self.currentGeneration += 1;
    if (self.currentGeneration == 0) {
        self.currentGeneration = 1;
    }
    self.probeToken += 1;
    self.activationRequested = NO;
    self.requestedBundleId = nil;
    self.preparedScene = nil;
    self.preparationRequestedForGeneration = NO;
    self.ownedSceneCandidate = nil;
    self.ownedSceneCandidateActivationTime = 0;
    self.systemDefaultFallbackActive = NO;

    if (discardOwnedScene) {
        [self.manager releaseForegroundLeaseDiscardingOwnedScene];
    } else {
        [self.manager releaseForegroundLease];
    }
    self.state = POHostSessionStateIdle;
}

- (void)releaseActiveSessionPreservingPresentation {
    [self releaseActiveSessionPreservingPresentationDiscardOwnedScene:NO];
}

- (void)releaseActiveSessionForExternalTakeoverPreservingPresentation {
    [self releaseActiveSessionPreservingPresentationDiscardOwnedScene:YES];
}

- (void)invalidate {
    [self releaseActiveSessionPreservingPresentationDiscardOwnedScene:YES];
    self.prewarmedBundleId = nil;
    self.prewarmTimestamp = 0;
    self.probeToken += 1;
}

- (BOOL)shouldFallbackOwnedSceneCandidateForBundleId:(NSString *)bundleId
                                          generation:(NSUInteger)generation {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
        return NO;
    }
    FBScene *candidate = self.ownedSceneCandidate;
    if (!candidate || self.systemDefaultFallbackActive || !self.activationRequested ||
        self.ownedSceneCandidateActivationTime <= 0 ||
        ![self isCurrentGeneration:generation bundleId:bundleId] ||
        ![self.manager isOwnedHostedScene:candidate bundleId:bundleId] ||
        ![self.manager isForegroundLeaseActiveForScene:candidate
                                              bundleId:bundleId
                                            generation:generation]) {
        return NO;
    }

    if ([self.manager isOwnedHostedSceneCapabilityProven:candidate bundleId:bundleId]) {
        return NO;
    }
    return CACurrentMediaTime() - self.ownedSceneCandidateActivationTime >=
        kPOOwnedSceneCapabilityWindow;
}

- (void)fallbackOwnedSceneCandidateToSystemDefaultForBundleId:(NSString *)bundleId
                                                    generation:(NSUInteger)generation {
    if (![self isCurrentGeneration:generation bundleId:bundleId] ||
        self.systemDefaultFallbackActive) {
        return;
    }

    self.systemDefaultFallbackActive = YES;
    self.probeToken += 1;
    self.preparedScene = nil;
    self.ownedSceneCandidate = nil;
    self.ownedSceneCandidateActivationTime = 0;
    self.state = POHostSessionStatePreparing;
    self.preparationRequestedForGeneration = YES;
    self.probeScheduleIndex = 0;

    [self.manager abandonOwnedHostedSceneForBundleId:bundleId];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kPOOwnedSceneFallbackProcessDrainDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![self isCurrentGeneration:generation bundleId:bundleId] ||
            !self.activationRequested || !self.systemDefaultFallbackActive) {
            return;
        }
        [self.manager requestCrossOrientationSystemDefaultScenePreparationForBundleId:bundleId];
        [self scheduleNextProbeForBundleId:bundleId generation:generation];
    });
}

#pragma mark - Probe

- (void)probeBundleId:(NSString *)bundleId generation:(NSUInteger)generation {
    if (![self isCurrentGeneration:generation bundleId:bundleId]) {
        return;
    }

    BOOL targetIsFrontmost = [self isFrontmostBundleId:bundleId];

    BOOL preparedSceneInvalid = self.preparedScene &&
        [self.preparedScene respondsToSelector:@selector(isValid)] &&
        ![(id)self.preparedScene isValid];
    if (preparedSceneInvalid && self.activationRequested && !self.systemDefaultFallbackActive &&
        [self.manager requiresOwnedHostedSceneForBundleId:bundleId]) {
        [self fallbackOwnedSceneCandidateToSystemDefaultForBundleId:bundleId generation:generation];
        return;
    }
    if (self.activationRequested && targetIsFrontmost) {
        [self handleCannotHostFrontmostBundleId:bundleId generation:generation];
        return;
    }

    BOOL requiresHostedGeometryLease = [self.manager requiresOwnedHostedSceneForBundleId:bundleId];
    if (!self.activationRequested && requiresHostedGeometryLease) {
        self.preparedScene = nil;
        self.preparationRequestedForGeneration = NO;
        self.state = POHostSessionStatePrepared;
        return;
    }

    if ([self shouldFallbackOwnedSceneCandidateForBundleId:bundleId generation:generation]) {
        [self fallbackOwnedSceneCandidateToSystemDefaultForBundleId:bundleId generation:generation];
        return;
    }

    BOOL requiresOwnedScene = !self.systemDefaultFallbackActive &&
        [self.manager requiresOwnedHostedSceneForBundleId:bundleId];
    BOOL requiresProcessFirstOwnedScene = requiresOwnedScene &&
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26;

    FBScene *scene = [self.manager probeSceneForBundleId:bundleId];
    if (requiresOwnedScene && scene && ![self.manager isOwnedHostedScene:scene bundleId:bundleId]) {
        scene = nil;
    }
    if (!scene && self.activationRequested && requiresOwnedScene && !requiresProcessFirstOwnedScene) {
        scene = [self.manager createHostedSceneForBundleId:bundleId];
    }

    if (!targetIsFrontmost && !self.preparationRequestedForGeneration) {
        self.preparationRequestedForGeneration = YES;
        [self.manager requestPreparationForBundleId:bundleId];
    } else if (!self.activationRequested && targetIsFrontmost) {
        self.preparedScene = nil;
        self.state = POHostSessionStateWaitingForScene;
        return;
    }

    if (!scene) {
        scene = [self.manager probeSceneForBundleId:bundleId];
        if (requiresOwnedScene && scene && ![self.manager isOwnedHostedScene:scene bundleId:bundleId]) {
            scene = nil;
        }
    }
    if (!scene && self.activationRequested && requiresOwnedScene &&
        [self.manager isProcessRunningForBundleId:bundleId]) {
        scene = [self.manager createHostedSceneForBundleId:bundleId];
    }
    if (!scene) {
        self.preparedScene = nil;
        BOOL processRunning = [self.manager isProcessRunningForBundleId:bundleId];
        if (!self.activationRequested && requiresOwnedScene && processRunning) {
            self.state = POHostSessionStatePrepared;
            return;
        }
        if (self.activationRequested && !processRunning &&
            self.preparationRequestedForGeneration && self.probeScheduleIndex >= 7) {
            [self.manager requestPreparationForBundleId:bundleId];
        }
        self.state = POHostSessionStateWaitingForScene;
        [self scheduleNextProbeForBundleId:bundleId generation:generation];
        return;
    }

    if (self.preparedScene != scene) {
        self.preparedScene = scene;
    }

    if (!self.activationRequested) {
        self.state = POHostSessionStatePrepared;
        return;
    }
    if (self.state != POHostSessionStateActivating) {
        self.state = POHostSessionStatePrepared;
    }
    [self commitPreparedSceneForBundleId:bundleId generation:generation];
}

- (void)scheduleNextProbeForBundleId:(NSString *)bundleId generation:(NSUInteger)generation {
    static const NSTimeInterval intervals[] = { 0.016, 0.017, 0.033, 0.054, 0.130, 0.250, 0.500 };
    const NSUInteger count = sizeof(intervals) / sizeof(intervals[0]);
    NSTimeInterval delay = self.probeScheduleIndex < count ? intervals[self.probeScheduleIndex++] : 1.0;
    NSUInteger token = ++self.probeToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self.probeToken || ![self isCurrentGeneration:generation bundleId:bundleId]) {
            return;
        }
        [self probeBundleId:bundleId generation:generation];
    });
}

#pragma mark - Activate / release

- (void)commitPreparedSceneForBundleId:(NSString *)bundleId generation:(NSUInteger)generation {
    if (![self isCurrentGeneration:generation bundleId:bundleId] || !self.activationRequested ||
        !self.preparedScene) {
        return;
    }

    BOOL enteringActivating = self.state != POHostSessionStateActivating;
    self.probeToken += 1;
    if (enteringActivating) {
        self.probeScheduleIndex = 0;
    }
    self.state = POHostSessionStateActivating;

    BOOL alreadyActiveLease =
        [self.manager isForegroundLeaseActiveForScene:self.preparedScene
                                              bundleId:bundleId
                                            generation:generation];
    if (!alreadyActiveLease) {
        if (![self.manager isOwnedHostedScene:self.preparedScene bundleId:bundleId]) {
            [self.manager prepareSystemDefaultSceneForHosting:self.preparedScene bundleId:bundleId];
        }
        [self.manager activateScene:self.preparedScene
                        forBundleId:bundleId
                         generation:generation];
    } else if ([self.manager sceneHasRenderableMainLayer:self.preparedScene]) {
        [self.manager activateScene:self.preparedScene
                        forBundleId:bundleId
                         generation:generation];
    }
    BOOL leaseActive = [self.manager isForegroundLeaseActiveForScene:self.preparedScene
                                                             bundleId:bundleId
                                                           generation:generation];
    if (leaseActive && !self.systemDefaultFallbackActive &&
        [self.manager isOwnedHostedScene:self.preparedScene bundleId:bundleId]) {
        if (self.ownedSceneCandidate != self.preparedScene ||
            self.ownedSceneCandidateActivationTime <= 0) {
            self.ownedSceneCandidate = self.preparedScene;
            self.ownedSceneCandidateActivationTime = CACurrentMediaTime();
        }
    } else if (self.ownedSceneCandidate == self.preparedScene) {
        self.ownedSceneCandidate = nil;
        self.ownedSceneCandidateActivationTime = 0;
    }

    if ([self isCurrentGeneration:generation bundleId:bundleId] &&
        self.state != POHostSessionStateLive) {
        [self scheduleNextProbeForBundleId:bundleId generation:generation];
    }
}

- (BOOL)isFrontmostBundleId:(NSString *)bundleId {
    NSString *frontId = [POApplicationHelper frontMostBundleId];
    return bundleId.length > 0 && frontId.length > 0 && [bundleId isEqualToString:frontId];
}

- (void)handleCannotHostFrontmostBundleId:(NSString *)bundleId generation:(NSUInteger)generation {
    if (![self isCurrentGeneration:generation bundleId:bundleId]) {
        return;
    }
    self.probeToken += 1;
    [self.manager releaseForegroundLeaseDiscardingOwnedScene];

    self.currentGeneration += 1;
    if (self.currentGeneration == 0) {
        self.currentGeneration = 1;
    }
    self.activationRequested = NO;
    self.requestedBundleId = nil;
    self.preparedScene = nil;
    self.preparationRequestedForGeneration = NO;
    self.state = POHostSessionStateIdle;
    id<POHostSessionControllerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(hostSessionController:cannotHostFrontmostBundleId:generation:)]) {
        [delegate hostSessionController:self cannotHostFrontmostBundleId:bundleId generation:generation];
    }
}

#pragma mark - ContextHostManagerExternalSceneDelegate

- (CGSize)contextManagerPreferredSceneStackSize:(id)manager {
    id<POHostSessionControllerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(hostSessionPreferredSceneStackSize:)]) {
        return [delegate hostSessionPreferredSceneStackSize:self];
    }
    return [UIScreen mainScreen].bounds.size;
}

- (CGSize)contextManagerPreferredSystemSceneStackSize:(id)manager {
    id<POHostSessionControllerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(hostSessionPreferredSystemSceneStackSize:)]) {
        return [delegate hostSessionPreferredSystemSceneStackSize:self];
    }
    return CGSizeZero;
}

- (UIInterfaceOrientation)contextManagerPreferredHostedInterfaceOrientation:(id)manager {
    id<POHostSessionControllerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(hostSessionPreferredHostedInterfaceOrientation:)]) {
        return [delegate hostSessionPreferredHostedInterfaceOrientation:self];
    }
    return UIInterfaceOrientationPortrait;
}

- (void)contextManager:(id)manager
                 scene:(FBScene *)scene
   sceneStackDidChange:(UIView *)sceneStack
        hostGeneration:(NSUInteger)generation {
    NSString *bundleId = self.requestedBundleId;
    if (![self isCurrentGeneration:generation bundleId:bundleId] ||
        ![self.manager isForegroundLeaseActiveForScene:scene bundleId:bundleId generation:generation] ||
        !sceneStack) {
        return;
    }

    self.state = POHostSessionStateLive;
    self.probeToken += 1;

    id<POHostSessionControllerDelegate> delegate = self.delegate;
    [delegate hostSessionController:self
                    didPublishScene:scene
                        sceneStack:sceneStack
                          bundleId:bundleId
                        generation:generation];
}

- (void)contextManager:(id)manager
                 scene:(FBScene *)scene
hostedInterfaceOrientationDidChange:(UIInterfaceOrientation)orientation
systemAnimationParameters:(id)animationParameters
        hostGeneration:(NSUInteger)generation {
    NSString *bundleId = self.requestedBundleId;
    if (![self isCurrentGeneration:generation bundleId:bundleId] ||
        ![self.manager isForegroundLeaseActiveForScene:scene bundleId:bundleId generation:generation]) {
        return;
    }
    id<POHostSessionControllerDelegate> delegate = self.delegate;
    [delegate hostSessionController:self
 hostedInterfaceOrientationDidChange:orientation
            systemAnimationParameters:animationParameters
                           bundleId:bundleId
                         generation:generation];
}

- (void)contextManager:(id)manager
                 scene:(FBScene *)scene
hostedPresentationContentDidBecomeUnavailableForBundleId:(NSString *)bundleId
        hostGeneration:(NSUInteger)generation {
    if (![self isCurrentGeneration:generation bundleId:bundleId] ||
        ![self.manager isForegroundLeaseActiveForScene:scene bundleId:bundleId generation:generation]) {
        return;
    }
    id<POHostSessionControllerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(hostSessionController:hostedPresentationContentDidBecomeUnavailableForBundleId:generation:)]) {
        [delegate hostSessionController:self
         hostedPresentationContentDidBecomeUnavailableForBundleId:bundleId
                              generation:generation];
    }
}

- (void)contextManager:(id)manager
 sceneDidBecomeInvalid:(FBScene *)scene
        hostGeneration:(NSUInteger)generation {
    NSString *bundleId = [self.requestedBundleId copy];
    if (!self.activationRequested || bundleId.length == 0 ||
        ![self isCurrentGeneration:generation bundleId:bundleId] ||
        scene != self.preparedScene) {
        return;
    }

    if (!self.systemDefaultFallbackActive &&
        [self.manager requiresOwnedHostedSceneForBundleId:bundleId]) {
        [self fallbackOwnedSceneCandidateToSystemDefaultForBundleId:bundleId
                                                            generation:generation];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.activationRequested ||
            ![self isCurrentGeneration:generation bundleId:bundleId] ||
            scene != self.preparedScene) {
            return;
        }
        [self releaseActiveSessionPreservingPresentationDiscardOwnedScene:YES];
        [self activateBundleId:bundleId];
    });
}

- (void)contextManager:(id)manager
                 scene:(FBScene *)scene
externalSceneStackDidChange:(UIView *)sceneStack
 containsKeyboardLayer:(BOOL)containsKeyboardLayer
        hostGeneration:(NSUInteger)generation {
    NSString *bundleId = self.requestedBundleId;
    if (![self isCurrentGeneration:generation bundleId:bundleId] ||
        ![self.manager isForegroundLeaseActiveForScene:scene bundleId:bundleId generation:generation]) {
        return;
    }
    id<POHostSessionControllerDelegate> delegate = self.delegate;
    [delegate hostSessionController:self
                    didPublishScene:scene
                 externalSceneStack:sceneStack
              containsKeyboardLayer:containsKeyboardLayer
                          bundleId:bundleId
                        generation:generation];
}

@end
