#line 1 "PullOverX.mm"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#include <substrate.h>

#import "headers.h"
#import "FBSOrientationObserver.h"
#import "FBSOrientationUpdate.h"
#import "PullOverWindow.h"
#import "POSplitSessionController.h"
#import "POApplicationHelper.h"
#import "POCameraGrantState.h"
#import "ContextHostManager.h"
#import "POExternalActivationCoordinator.h"

static PullOverWindow *window;
static FBSOrientationObserver *POOrientationObserver;

typedef NS_ENUM(NSInteger, POLandscapeBehavior) {
    POLandscapeBehaviorRotate,
    POLandscapeBehaviorLock,
    POLandscapeBehaviorHide,
};

typedef NS_ENUM(NSInteger, POLandscapeVisibility) {
    POLandscapeVisibilityUnresolved,
    POLandscapeVisibilityVisible,
    POLandscapeVisibilityBehaviorHidden,
    POLandscapeVisibilityDisabled,
};

typedef NS_ENUM(NSInteger, PODeviceForm) {
    PODeviceFormPhoneFixedSpringBoard,
    PODeviceFormPadRotatingSpringBoard,
};

typedef NS_ENUM(NSInteger, PODirectionPhase) {
    PODirectionPhaseUnresolved,
    PODirectionPhaseAwaitingScene,
    PODirectionPhaseStable,
    PODirectionPhaseSuppressed,
};

typedef struct {
    POLandscapeVisibility visibility;
    UIInterfaceOrientation sourceOrientation;
    UIInterfaceOrientation targetOrientation;
} POLandscapeDecision;

typedef struct {
    UIInterfaceOrientation physicalOrientation;
    UIInterfaceOrientation springBoardOrientation;
    UIInterfaceOrientation sourceSceneOrientation;
    UIInterfaceOrientation sceneOrientation;
    UIInterfaceOrientation committedOrientation;
    UIInterfaceOrientation windowAppliedOrientation;
    BOOL sceneIsCurrent;
    BOOL committedIsCurrent;
    BOOL enabled;
    POLandscapeBehavior behavior;
    PODeviceForm deviceForm;
    NSTimeInterval requestedDuration;
    NSTimeInterval fallbackDuration;
} PODirectionResolverInput;

typedef struct {
    POLandscapeDecision decision;
    NSTimeInterval duration;
    BOOL shouldCommit;
} PODirectionResolverOutput;

@interface PODirectionState : NSObject
@property (nonatomic, assign) UIInterfaceOrientation physicalOrientation;
@property (nonatomic, assign) UIInterfaceOrientation springBoardOrientation;
@property (nonatomic, assign) UIInterfaceOrientation sceneOrientation;
@property (nonatomic, copy) NSString *sceneIdentifier;
@property (nonatomic, assign) BOOL sceneIsUsable;
@property (nonatomic, assign) UIInterfaceOrientation committedOrientation;
@property (nonatomic, copy) NSString *committedSceneIdentifier;
@property (nonatomic, assign) UIInterfaceOrientation windowAppliedOrientation;
@property (nonatomic, assign) NSTimeInterval pendingAnimationDuration;
@property (nonatomic, assign) CFTimeInterval pendingAnimationTimestamp;
@property (nonatomic, assign) NSUInteger reconcileGeneration;
@property (nonatomic, assign) POLandscapeVisibility visibility;
@property (nonatomic, assign) PODeviceForm deviceForm;
@property (nonatomic, assign) PODirectionPhase phase;
@end

@implementation PODirectionState
@end

static PODirectionState *PODirectionStateOwner(void) {
    static PODirectionState *state;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        state = [PODirectionState new];
        state.physicalOrientation = UIInterfaceOrientationUnknown;
        state.springBoardOrientation = UIInterfaceOrientationUnknown;
        state.sceneOrientation = UIInterfaceOrientationUnknown;
        state.committedOrientation = UIInterfaceOrientationUnknown;
        state.windowAppliedOrientation = UIInterfaceOrientationUnknown;
        state.visibility = POLandscapeVisibilityUnresolved;
        state.deviceForm = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
            ? PODeviceFormPadRotatingSpringBoard
            : PODeviceFormPhoneFixedSpringBoard;
        state.phase = PODirectionPhaseUnresolved;
    });
    return state;
}

static void POReconcileCommittedInterfaceOrientation(NSString *trigger,
                                                      NSTimeInterval duration,
                                                      BOOL applyOrdinarySettings);

static CFStringRef const kPOSettingsChangedNotification = CFSTR("com.mlgm.pulloverx.settings-changed");

static BOOL POSettingsEnabled(NSDictionary *settings) {
    id enabled = settings[@"enabled"];
    return enabled == nil || [enabled boolValue];
}

static BOOL POIsConcreteInterfaceOrientation(UIInterfaceOrientation orientation) {
    return orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
}

static UIInterfaceOrientation POReadInterfaceOrientation(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return UIInterfaceOrientationUnknown;
    }
    @try {
        return (UIInterfaceOrientation)((long long (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return UIInterfaceOrientationUnknown;
    }
}

static id POReadObject(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSTimeInterval POReadTimeInterval(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return 0;
    }
    @try {
        NSTimeInterval interval = ((NSTimeInterval (*)(id, SEL))objc_msgSend)(object, selector);
        return interval > 0 ? interval : 0;
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static id POFrontmostApplication(void) {
    @try {
        return [(SpringBoard *)UIApplication.sharedApplication _accessibilityFrontMostApplication];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSTimeInterval POSystemOrientationAnimationDuration(void) {
    NSTimeInterval duration = POReadTimeInterval(
        UIApplication.sharedApplication, NSSelectorFromString(@"statusBarOrientationAnimationDuration"));
    if (duration > 0) {
        return duration;
    }

    duration = UIView.inheritedAnimationDuration;
    return duration > 0 ? duration : 0;
}

static NSString *POApplicationIdentifier(id application) {
    id identifier = POReadObject(application, @selector(bundleIdentifier));
    if ([identifier isKindOfClass:[NSString class]]) {
        return identifier;
    }

    identifier = POReadObject(application, @selector(displayIdentifier));
    return [identifier isKindOfClass:[NSString class]] ? identifier : nil;
}

static id POHomeDisplayScene(void) {
    id scene = POReadObject(
        UIApplication.sharedApplication, NSSelectorFromString(@"_mainDisplayWindowScene"));
    if (scene) {
        return scene;
    }

    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)candidate;
        if ([windowScene.session.persistentIdentifier isEqualToString:@"com.apple.springboard"]) {
            return windowScene;
        }
    }
    return nil;
}

static NSString *POSceneIdentifier(id scene) {
    id identifier = POReadObject(scene, @selector(identifier));
    if ([identifier isKindOfClass:[NSString class]]) {
        return identifier;
    }

    if ([scene isKindOfClass:[UIWindowScene class]]) {
        return ((UIWindowScene *)scene).session.persistentIdentifier;
    }
    return nil;
}

static UIInterfaceOrientation POReadSceneInterfaceOrientation(id scene) {
    id settings = POReadObject(scene, @selector(settings));
    UIInterfaceOrientation orientation = POReadInterfaceOrientation(settings, @selector(interfaceOrientation));
    if (!POIsConcreteInterfaceOrientation(orientation)) {
        orientation = POReadInterfaceOrientation(scene, @selector(interfaceOrientation));
    }
    return orientation;
}

static BOOL POHomeScreenIsActive(void) {
    Class workspaceClass = NSClassFromString(@"SBMainWorkspace");
    id workspace = POReadObject(workspaceClass, NSSelectorFromString(@"sharedInstance"));
    SEL activeSelector = NSSelectorFromString(@"isSpringBoardActive");
    return workspace && [workspace respondsToSelector:activeSelector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(workspace, activeSelector);
}

static BOOL POSceneIdentifierMatchesBundleIdentifier(NSString *sceneIdentifier,
                                                      NSString *bundleIdentifier) {
    if (sceneIdentifier.length == 0 || bundleIdentifier.length == 0) {
        return NO;
    }
    if ([sceneIdentifier isEqualToString:bundleIdentifier]) {
        return YES;
    }

    NSString *prefix = [bundleIdentifier stringByAppendingString:@"-"];
    NSRange range = [sceneIdentifier rangeOfString:prefix];
    return range.location == 0 ||
        (range.location != NSNotFound && [sceneIdentifier characterAtIndex:range.location - 1] == ':');
}

static BOOL POSceneIsUsableForOrientation(id scene) {
    id settings = POReadObject(scene, @selector(settings));
    SEL foregroundSelector = NSSelectorFromString(@"isForeground");
    if (settings && [settings respondsToSelector:foregroundSelector]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(settings, foregroundSelector);
    }

    SEL activeSelector = NSSelectorFromString(@"isActive");
    if (scene && [scene respondsToSelector:activeSelector]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(scene, activeSelector);
    }

    SEL validSelector = NSSelectorFromString(@"isValid");
    if (scene && [scene respondsToSelector:validSelector] &&
        !((BOOL (*)(id, SEL))objc_msgSend)(scene, validSelector)) {
        return NO;
    }
    return YES;
}

static id POResolveCurrentOrientationSourceScene(void) {
    id application = POFrontmostApplication();
    NSString *bundleIdentifier = POApplicationIdentifier(application);
    POSplitSessionController *splitSession = [POSplitSessionController sharedInstance];
    if (splitSession.isActive) {
        if (POHomeScreenIsActive()) {
            id homeScene = POHomeDisplayScene();
            if (homeScene && POIsConcreteInterfaceOrientation(POReadSceneInterfaceOrientation(homeScene))) {
                [splitSession updateBaseBundleIdentifier:@"com.apple.springboard" scene:homeScene];
                return homeScene;
            }
        }
        NSString *hostedBundleId = [ContextHostManager activeHostedBundleId];
        if (application && bundleIdentifier.length > 0 &&
            ![bundleIdentifier isEqualToString:hostedBundleId]) {
            for (NSString *selectorName in @[ @"mainScene", @"_mainScene", @"scene" ]) {
                id scene = POReadObject(application, NSSelectorFromString(selectorName));
                if (scene &&
                    POSceneIdentifierMatchesBundleIdentifier(POSceneIdentifier(scene), bundleIdentifier) &&
                    POSceneIsUsableForOrientation(scene)) {
                    [splitSession updateBaseBundleIdentifier:bundleIdentifier scene:scene];
                    return scene;
                }
            }

            FBScene *probedScene = [[ContextHostManager sharedInstance] probeSceneForBundleId:bundleIdentifier];
            if (probedScene &&
                POSceneIdentifierMatchesBundleIdentifier(POSceneIdentifier(probedScene), bundleIdentifier) &&
                POSceneIsUsableForOrientation(probedScene)) {
                [splitSession updateBaseBundleIdentifier:bundleIdentifier scene:probedScene];
                return probedScene;
            }
        }
        if (splitSession.baseScene) {
            return splitSession.baseScene;
        }
    }
    if (application && bundleIdentifier.length > 0) {
        for (NSString *selectorName in @[ @"mainScene", @"_mainScene", @"scene" ]) {
            id scene = POReadObject(application, NSSelectorFromString(selectorName));
            if (scene &&
                POSceneIdentifierMatchesBundleIdentifier(POSceneIdentifier(scene), bundleIdentifier) &&
                POSceneIsUsableForOrientation(scene)) {
                return scene;
            }
        }
        return nil;
    }

    id scene = POHomeDisplayScene();
    if ([POSceneIdentifier(scene) isEqualToString:@"com.apple.springboard"] &&
        POSceneIsUsableForOrientation(scene)) {
        return scene;
    }
    return nil;
}

static BOOL POIsCurrentOrientationSourceSceneIdentifier(NSString *sceneIdentifier);

static UIInterfaceOrientation POCurrentCommittedInterfaceOrientation(NSString **sceneIdentifier) {
    PODirectionState *state = PODirectionStateOwner();
    id sourceScene = POResolveCurrentOrientationSourceScene();
    NSString *currentSceneIdentifier = POSceneIdentifier(sourceScene);
    UIInterfaceOrientation orientation = POReadSceneInterfaceOrientation(sourceScene);
    if (POIsConcreteInterfaceOrientation(orientation)) {
        if (sceneIdentifier) {
            *sceneIdentifier = currentSceneIdentifier;
        }
        return orientation;
    }

    if (POIsCurrentOrientationSourceSceneIdentifier(state.committedSceneIdentifier) &&
        POIsConcreteInterfaceOrientation(state.committedOrientation)) {
        if (sceneIdentifier) {
            *sceneIdentifier = state.committedSceneIdentifier;
        }
        return state.committedOrientation;
    }

    return UIInterfaceOrientationUnknown;
}

static BOOL POIsCurrentOrientationSourceSceneIdentifier(NSString *sceneIdentifier) {
    POSplitSessionController *splitSession = [POSplitSessionController sharedInstance];
    if (splitSession.isActive && splitSession.baseSceneIdentifier.length > 0) {
        return [sceneIdentifier isEqualToString:splitSession.baseSceneIdentifier];
    }
    id application = POFrontmostApplication();
    NSString *bundleIdentifier = POApplicationIdentifier(application);
    if (bundleIdentifier.length > 0) {
        return POSceneIdentifierMatchesBundleIdentifier(sceneIdentifier, bundleIdentifier);
    }
    return [sceneIdentifier isEqualToString:@"com.apple.springboard"];
}

static BOOL POIsCurrentOrientationSourceScene(id scene) {
    return POIsCurrentOrientationSourceSceneIdentifier(POSceneIdentifier(scene));
}

static POLandscapeBehavior POReadLandscapeBehavior(NSDictionary *settings) {
    id value = settings[@"landscapeBehavior"];
    if (!value) {
        return POLandscapeBehaviorRotate;
    }
    if (![value isKindOfClass:[NSString class]]) {
        return POLandscapeBehaviorRotate;
    }
    if ([value isEqualToString:@"lock"]) {
        return POLandscapeBehaviorLock;
    }
    if ([value isEqualToString:@"hide"]) {
        return POLandscapeBehaviorHide;
    }
    if ([value isEqualToString:@"rotate"]) {
        return POLandscapeBehaviorRotate;
    }
    return POLandscapeBehaviorRotate;
}

static POLandscapeDecision POComputeLandscapeDecisionForBehavior(BOOL enabled,
                                                                  POLandscapeBehavior behavior,
                                                                  UIInterfaceOrientation sourceOrientation) {
    POLandscapeDecision decision;
    decision.visibility = POLandscapeVisibilityUnresolved;
    decision.sourceOrientation = sourceOrientation;
    decision.targetOrientation = UIInterfaceOrientationUnknown;
    if (!enabled) {
        decision.visibility = POLandscapeVisibilityDisabled;
        return decision;
    }
    if (!POIsConcreteInterfaceOrientation(sourceOrientation)) {
        return decision;
    }
    if (UIInterfaceOrientationIsLandscape(sourceOrientation) &&
        behavior == POLandscapeBehaviorHide) {
        decision.visibility = POLandscapeVisibilityBehaviorHidden;
        return decision;
    }

    decision.visibility = POLandscapeVisibilityVisible;
    decision.targetOrientation = sourceOrientation;
    if (UIInterfaceOrientationIsLandscape(sourceOrientation) &&
        behavior == POLandscapeBehaviorLock) {
        decision.targetOrientation = UIInterfaceOrientationPortrait;
    }
    return decision;
}

static POLandscapeDecision POComputeLandscapeDecision(NSDictionary *settings,
                                                       UIInterfaceOrientation sourceOrientation) {
    return POComputeLandscapeDecisionForBehavior(POSettingsEnabled(settings),
                                                 POReadLandscapeBehavior(settings),
                                                 sourceOrientation);
}

static PODirectionResolverOutput POResolveDirection(PODirectionResolverInput input) {
    UIInterfaceOrientation sourceOrientation = UIInterfaceOrientationUnknown;
    if (POIsConcreteInterfaceOrientation(input.sourceSceneOrientation)) {
        sourceOrientation = input.sourceSceneOrientation;
    } else if (input.sceneIsCurrent && POIsConcreteInterfaceOrientation(input.sceneOrientation)) {
        sourceOrientation = input.sceneOrientation;
    } else if (input.committedIsCurrent && POIsConcreteInterfaceOrientation(input.committedOrientation)) {
        sourceOrientation = input.committedOrientation;
    } else if (input.deviceForm == PODeviceFormPadRotatingSpringBoard &&
               POIsConcreteInterfaceOrientation(input.springBoardOrientation)) {
        sourceOrientation = input.springBoardOrientation;
    }

    PODirectionResolverOutput output;
    output.decision = POComputeLandscapeDecisionForBehavior(input.enabled, input.behavior, sourceOrientation);
    output.shouldCommit = output.decision.visibility == POLandscapeVisibilityVisible &&
        POIsConcreteInterfaceOrientation(output.decision.targetOrientation) &&
        output.decision.targetOrientation != input.windowAppliedOrientation;
    output.duration = 0;
    if (output.shouldCommit) {
        output.duration = input.requestedDuration > 0
            ? input.requestedDuration
            : MAX(0, input.fallbackDuration);
    }
    return output;
}

static BOOL POIsDirectionPhaseTransitionAllowed(PODirectionPhase from, PODirectionPhase to) {
    switch (from) {
        case PODirectionPhaseUnresolved:
            return to == PODirectionPhaseAwaitingScene ||
                to == PODirectionPhaseStable || to == PODirectionPhaseSuppressed;
        case PODirectionPhaseAwaitingScene:
            return to == PODirectionPhaseAwaitingScene ||
                to == PODirectionPhaseStable || to == PODirectionPhaseSuppressed;
        case PODirectionPhaseStable:
            return to == PODirectionPhaseStable ||
                to == PODirectionPhaseAwaitingScene || to == PODirectionPhaseSuppressed;
        case PODirectionPhaseSuppressed:
            return to == PODirectionPhaseSuppressed ||
                to == PODirectionPhaseAwaitingScene || to == PODirectionPhaseStable;
    }
    return NO;
}

static PODirectionPhase PODirectionPhaseForResolution(PODirectionResolverOutput resolution) {
    switch (resolution.decision.visibility) {
        case POLandscapeVisibilityDisabled:
        case POLandscapeVisibilityBehaviorHidden:
            return PODirectionPhaseSuppressed;
        case POLandscapeVisibilityUnresolved:
            return PODirectionPhaseAwaitingScene;
        case POLandscapeVisibilityVisible:
            if (POIsConcreteInterfaceOrientation(resolution.decision.targetOrientation)) {
                return PODirectionPhaseStable;
            }
            break;
    }
    return PODirectionPhaseAwaitingScene;
}

static void POTransitionDirectionPhase(PODirectionPhase nextPhase) {
    PODirectionState *state = PODirectionStateOwner();
    BOOL legal = POIsDirectionPhaseTransitionAllowed(state.phase, nextPhase);
    if (!legal) {
        nextPhase = PODirectionPhaseAwaitingScene;
    }
    state.phase = nextPhase;
}

static NSUInteger POAdvanceReconcileGeneration(void) {
    PODirectionState *state = PODirectionStateOwner();
    state.reconcileGeneration += 1;
    if (state.reconcileGeneration == 0) {
        state.reconcileGeneration = 1;
    }
    return state.reconcileGeneration;
}

static void POClearTransientDirectionInputs(void) {
    PODirectionState *state = PODirectionStateOwner();
    state.pendingAnimationDuration = 0;
    state.pendingAnimationTimestamp = 0;
}

static void PORecordPendingAnimationDuration(NSTimeInterval duration) {
    if (duration <= 0) {
        return;
    }
    PODirectionState *state = PODirectionStateOwner();
    state.pendingAnimationDuration = duration;
    state.pendingAnimationTimestamp = CACurrentMediaTime();
}

static NSTimeInterval POCurrentPendingAnimationDuration(void) {
    PODirectionState *state = PODirectionStateOwner();
    if (state.pendingAnimationDuration <= 0 || state.pendingAnimationTimestamp <= 0 ||
        CACurrentMediaTime() - state.pendingAnimationTimestamp > 1.0) {
        return 0;
    }
    return state.pendingAnimationDuration;
}

static void POEnsureWindowForEnabledState(void) {
    if (!window) {
        window = [PullOverWindow sharedWindow];
        window.rootViewController.view.alpha = 0;
        window.userInteractionEnabled = NO;
        [window makeKeyAndVisible];
        return;
    }
    if (window.hidden) {
        window.hidden = NO;
        [window makeKeyAndVisible];
    }
}

static void POApplyOrdinarySettings(NSDictionary *settings, BOOL animateSideChange) {
    if (!window) {
        return;
    }

    BOOL leftHanded = [settings[@"leftHanded"] boolValue];
    CGAffineTransform targetTransform = leftHanded
        ? CGAffineTransformMakeScale(-1.0, 1.0)
        : CGAffineTransformIdentity;
    static BOOL hasLastSide = NO;
    static BOOL lastLeftHanded = NO;
    BOOL sideChanged = hasLastSide && (leftHanded != lastLeftHanded);
    hasLastSide = YES;
    lastLeftHanded = leftHanded;
    if (sideChanged && animateSideChange && !window.hidden) {
        CGFloat width = CGRectGetWidth(window.bounds);
        window.transform = CGAffineTransformTranslate(targetTransform, -width, 0);
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.9
              initialSpringVelocity:0.2
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ window.transform = targetTransform; }
                         completion:nil];
    } else {
        window.transform = targetTransform;
    }
    [window.controller applyCurrentSettings];
}

static void POFinishVisibleRecovery(NSUInteger generation) {
    PODirectionState *state = PODirectionStateOwner();
    if (!window || generation != state.reconcileGeneration) {
        return;
    }

    NSDictionary *settings = [POApplicationHelper settings];
    NSString *sceneIdentifier = nil;
    UIInterfaceOrientation source = POCurrentCommittedInterfaceOrientation(&sceneIdentifier);
    POLandscapeDecision decision = POComputeLandscapeDecision(settings, source);
    if (!POSettingsEnabled(settings) || decision.visibility != POLandscapeVisibilityVisible ||
        !POIsConcreteInterfaceOrientation(decision.targetOrientation) ||
        window.pullOverInterfaceOrientation != decision.targetOrientation) {
        POReconcileCommittedInterfaceOrientation(@"visible-recovery", 0, NO);
        return;
    }

    state.visibility = POLandscapeVisibilityVisible;
    state.windowAppliedOrientation = window.pullOverInterfaceOrientation;
    POApplyOrdinarySettings(settings, NO);
    window.rootViewController.view.alpha = 1;
    window.userInteractionEnabled = YES;
}

static void POApplyDecision(PODirectionResolverOutput resolution,
                            NSDictionary *settings,
                            BOOL applyOrdinarySettings,
                            NSUInteger generation) {
    PODirectionState *state = PODirectionStateOwner();
    POLandscapeDecision decision = resolution.decision;
    if (decision.visibility == POLandscapeVisibilityUnresolved) {
        if (window && state.visibility == POLandscapeVisibilityUnresolved) {
            window.rootViewController.view.alpha = 0;
            window.userInteractionEnabled = NO;
        }
        return;
    }

    if (decision.visibility == POLandscapeVisibilityDisabled) {
        if (state.visibility != POLandscapeVisibilityDisabled) {
            state.visibility = POLandscapeVisibilityDisabled;
            POClearTransientDirectionInputs();
            if (window) {
                window.rootViewController.view.alpha = 0;
                window.userInteractionEnabled = NO;
                [window.controller forceCloseAndReleaseImmediately];
            }
        }
        if (window) {
            window.rootViewController.view.alpha = 0;
            window.userInteractionEnabled = NO;
            window.hidden = YES;
        }
        return;
    }

    if (decision.visibility == POLandscapeVisibilityBehaviorHidden) {
        if (state.visibility != POLandscapeVisibilityBehaviorHidden) {
            state.visibility = POLandscapeVisibilityBehaviorHidden;
            POClearTransientDirectionInputs();
            POEnsureWindowForEnabledState();
            window.rootViewController.view.alpha = 0;
            window.userInteractionEnabled = NO;
            [window.controller forceCloseAndReleaseImmediately];
        }
        if (window) {
            window.rootViewController.view.alpha = 0;
            window.userInteractionEnabled = NO;
            window.hidden = NO;
        }
        return;
    }

    if (decision.visibility != POLandscapeVisibilityVisible ||
        !POIsConcreteInterfaceOrientation(decision.targetOrientation)) {
        return;
    }

    POEnsureWindowForEnabledState();
    BOOL recovering = state.visibility != POLandscapeVisibilityVisible;
    BOOL targetChanged = window.pullOverInterfaceOrientation != decision.targetOrientation;
    if (!recovering && targetChanged) {
        [window.controller prepareForOrientationChange];
    }
    if (recovering) {
        window.rootViewController.view.alpha = 0;
        window.userInteractionEnabled = NO;
    } else if (applyOrdinarySettings) {
        POApplyOrdinarySettings(settings, YES);
    }

    if (!resolution.shouldCommit && !recovering) {
        state.visibility = POLandscapeVisibilityVisible;
        state.windowAppliedOrientation = window.pullOverInterfaceOrientation;
        window.rootViewController.view.alpha = 1;
        window.userInteractionEnabled = YES;
        return;
    }

    BOOL accepted = [window applyInterfaceOrientation:decision.targetOrientation
                                             duration:resolution.duration
                                           completion:^{
        if (recovering) {
            POFinishVisibleRecovery(generation);
        }
    }];
    if (!accepted) {
        if (targetChanged) {
            [window.controller handleOrientationChange];
        }
        return;
    }

    state.windowAppliedOrientation = decision.targetOrientation;
    if (!recovering) {
        state.visibility = POLandscapeVisibilityVisible;
        window.rootViewController.view.alpha = 1;
        window.userInteractionEnabled = YES;
    }
}

static void POHandleSceneSettingsUpdate(id scene, id settings) {
    UIInterfaceOrientation orientation = POReadInterfaceOrientation(settings, @selector(interfaceOrientation));
    NSString *sceneIdentifier = POSceneIdentifier(scene);
    BOOL isCurrentSource = POIsCurrentOrientationSourceScene(scene);
    BOOL isUsable = POSceneIsUsableForOrientation(scene);
    if (!isCurrentSource || !isUsable ||
        !POIsConcreteInterfaceOrientation(orientation) || sceneIdentifier.length == 0) {
        return;
    }

    PODirectionState *state = PODirectionStateOwner();
    state.sceneOrientation = orientation;
    state.sceneIdentifier = sceneIdentifier;
    state.sceneIsUsable = YES;
    POReconcileCommittedInterfaceOrientation(@"scene-settings", 0, NO);
}

static void PORecordSystemRotationCandidate(UIInterfaceOrientation orientation,
                                            NSTimeInterval duration) {
    PODirectionState *state = PODirectionStateOwner();
    state.springBoardOrientation = orientation;
    NSTimeInterval effectiveDuration = duration > 0 ? duration : POSystemOrientationAnimationDuration();
    PORecordPendingAnimationDuration(effectiveDuration);
}

static void POReconcileCommittedInterfaceOrientation(NSString *trigger,
                                                      NSTimeInterval duration,
                                                      BOOL applyOrdinarySettings) {
    if (![NSThread isMainThread]) {
        NSString *triggerCopy = [trigger copy] ?: @"unknown";
        dispatch_async(dispatch_get_main_queue(), ^{
            POReconcileCommittedInterfaceOrientation(triggerCopy, duration, applyOrdinarySettings);
        });
        return;
    }

    PODirectionState *state = PODirectionStateOwner();
    NSDictionary *settings = [POApplicationHelper settings];
    id sourceScene = POResolveCurrentOrientationSourceScene();
    NSString *sourceSceneIdentifier = POSceneIdentifier(sourceScene);
    UIInterfaceOrientation sourceSceneOrientation = POReadSceneInterfaceOrientation(sourceScene);
    BOOL sceneIsCurrent = state.sceneIsUsable &&
        POIsCurrentOrientationSourceSceneIdentifier(state.sceneIdentifier);
    BOOL committedIsCurrent =
        POIsCurrentOrientationSourceSceneIdentifier(state.committedSceneIdentifier);
    NSTimeInterval pendingDuration = duration > 0 ? duration : POCurrentPendingAnimationDuration();
    UIInterfaceOrientation windowApplied = window
        ? window.pullOverInterfaceOrientation
        : state.windowAppliedOrientation;

    PODirectionResolverInput input;
    input.physicalOrientation = state.physicalOrientation;
    input.springBoardOrientation = state.springBoardOrientation;
    input.sourceSceneOrientation = sourceSceneOrientation;
    input.sceneOrientation = sceneIsCurrent ? state.sceneOrientation : UIInterfaceOrientationUnknown;
    input.committedOrientation = committedIsCurrent
        ? state.committedOrientation
        : UIInterfaceOrientationUnknown;
    input.windowAppliedOrientation = windowApplied;
    input.sceneIsCurrent = sceneIsCurrent;
    input.committedIsCurrent = committedIsCurrent;
    input.enabled = POSettingsEnabled(settings);
    input.behavior = POReadLandscapeBehavior(settings);
    input.deviceForm = state.deviceForm;
    input.requestedDuration = pendingDuration;
    input.fallbackDuration = POSystemOrientationAnimationDuration();

    PODirectionResolverOutput resolution = POResolveDirection(input);
    POTransitionDirectionPhase(PODirectionPhaseForResolution(resolution));
    NSString *resolvedSceneIdentifier = nil;
    if (POIsConcreteInterfaceOrientation(sourceSceneOrientation)) {
        resolvedSceneIdentifier = sourceSceneIdentifier;
    } else if (sceneIsCurrent && POIsConcreteInterfaceOrientation(state.sceneOrientation)) {
        resolvedSceneIdentifier = state.sceneIdentifier;
    } else if (committedIsCurrent && POIsConcreteInterfaceOrientation(state.committedOrientation)) {
        resolvedSceneIdentifier = state.committedSceneIdentifier;
    }
    if (POIsConcreteInterfaceOrientation(resolution.decision.sourceOrientation)) {
        state.committedOrientation = resolution.decision.sourceOrientation;
        state.committedSceneIdentifier = resolvedSceneIdentifier;
    }

    NSUInteger generation = POAdvanceReconcileGeneration();
    POApplyDecision(resolution, settings, applyOrdinarySettings, generation);
    if (resolution.shouldCommit &&
        state.windowAppliedOrientation == resolution.decision.targetOrientation) {
        POClearTransientDirectionInputs();
    }
}

static void POStartOrientationObserver(void) {
    if (POOrientationObserver) {
        return;
    }

    Class observerClass = NSClassFromString(@"FBSOrientationObserver");
    if (!observerClass) {
        return;
    }

    POOrientationObserver = [[observerClass alloc] init];
    if (!POOrientationObserver) {
        return;
    }

    [POOrientationObserver setHandler:^(FBSOrientationUpdate *orientationUpdate) {
        UIInterfaceOrientation physicalOrientation = [orientationUpdate respondsToSelector:@selector(orientation)]
            ? (UIInterfaceOrientation)orientationUpdate.orientation
            : UIInterfaceOrientationUnknown;
        NSTimeInterval duration = [orientationUpdate respondsToSelector:@selector(duration)]
            ? MAX(0, orientationUpdate.duration)
            : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            PODirectionState *state = PODirectionStateOwner();
            state.physicalOrientation = physicalOrientation;
            PORecordPendingAnimationDuration(duration);
            POReconcileCommittedInterfaceOrientation(@"fbs-observer", duration, NO);
        });
    }];
}

static BOOL POSettingsApplyScheduled;

static void POApplyCurrentSettings(void) {
    POSettingsApplyScheduled = NO;
    [POApplicationHelper reloadSettings];
    POReconcileCommittedInterfaceOrientation(@"settings", 0, YES);
}

static void POSettingsDidChange(CFNotificationCenterRef __unused center,
                                void * __unused observer,
                                CFStringRef __unused name,
                                const void * __unused object,
                                CFDictionaryRef __unused userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (POSettingsApplyScheduled) {
            return;
        }
        POSettingsApplyScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            POApplyCurrentSettings();
        });
    });
}

#if defined(__clang__)
#if __has_feature(objc_arc)
#define _LOGOS_SELF_TYPE_NORMAL __unsafe_unretained
#define _LOGOS_SELF_CONST const
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_CONST
#endif
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_CONST
#endif

__asm__(".linker_option \"-framework\", \"CydiaSubstrate\"");

#pragma mark - Substrate hook declarations

@class FBScene;
@class SBHomeHardwareButton;
@class UIMutableApplicationSceneSettings;
@class SpringBoard;
static void (*_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$)(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id, id);
static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id, id);
static void (*_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$)(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id);
static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST, SEL, id, id);
static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$)(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, unsigned long long);
static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, unsigned long long);
static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$)(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void (*_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$)(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST, SEL, BOOL);
static void (*_logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$)(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, UIApplication *);
static void _logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, UIApplication *);
static void (
    *_logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$)(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, long long, double, BOOL, BOOL, id);
static void
_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST, SEL, long long, double, BOOL, BOOL, id);
static void (*_logos_orig$_ungrouped$SpringBoard$takeScreenshot)(_LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST,
                                                                 SEL);
static void _logos_method$_ungrouped$SpringBoard$takeScreenshot(_LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST,
                                                                SEL);
static void (*_logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$)(
    _LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton *_LOGOS_SELF_CONST, SEL, id);
static void _logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$(
    _LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton *_LOGOS_SELF_CONST, SEL, id);
static void (*POOriginalSBMainWorkspaceHandleOpenApplicationRequest)(id, SEL, id, id, id);
static void (*POOriginalSBMainWorkspaceHandleTrustedOpenApplicationRequest)(id, SEL, id, id, id, id, id);
static id (*POOriginalSBToAppsWorkspaceTransactionInit)(id, SEL, id);
static id (*POOriginalSBAppToAppWorkspaceTransactionInit)(id, SEL, id);
#pragma mark - External native activation hooks

static void POHookSBMainWorkspaceHandleOpenApplicationRequest(id self, SEL _cmd,
                                                               id systemService, id request,
                                                               id completion) {
    if (![POApplicationHelper isEnabled]) {
        POOriginalSBMainWorkspaceHandleOpenApplicationRequest(self, _cmd, systemService, request, completion);
        return;
    }
    id routedCompletion = [[POExternalActivationCoordinator sharedInstance]
        prepareOpenApplicationRequestIfNeeded:request completion:completion];
    POOriginalSBMainWorkspaceHandleOpenApplicationRequest(self, _cmd, systemService, request,
                                                          routedCompletion ?: completion);
}

static void POHookSBMainWorkspaceHandleTrustedOpenApplicationRequest(id self, SEL _cmd,
                                                                      id application, id options,
                                                                      id activationSettings, id origin,
                                                                      id result) {
    if (![POApplicationHelper isEnabled]) {
        POOriginalSBMainWorkspaceHandleTrustedOpenApplicationRequest(self, _cmd, application, options,
                                                                       activationSettings, origin, result);
        return;
    }
    id routedResult = result;
    id routedOptions = [[POExternalActivationCoordinator sharedInstance]
        prepareTrustedWorkspaceOpenApplication:application
                                      options:options
                                       origin:origin
                                       result:result
                                 routedResult:&routedResult];
    POOriginalSBMainWorkspaceHandleTrustedOpenApplicationRequest(self, _cmd, application,
                                                                 routedOptions ?: options,
                                                                 activationSettings, origin,
                                                                 routedResult ?: result);
}

static id POHookSBToAppsWorkspaceTransactionInit(id self, SEL _cmd, id transitionRequest) {
    if (![POApplicationHelper isEnabled]) {
        return POOriginalSBToAppsWorkspaceTransactionInit(self, _cmd, transitionRequest);
    }
    [[POExternalActivationCoordinator sharedInstance]
        prepareNativeTakeoverForTransitionRequestIfNeeded:transitionRequest];
    return POOriginalSBToAppsWorkspaceTransactionInit(self, _cmd, transitionRequest);
}

static id POHookSBAppToAppWorkspaceTransactionInit(id self, SEL _cmd, id transitionRequest) {
    if (![POApplicationHelper isEnabled]) {
        return POOriginalSBAppToAppWorkspaceTransactionInit(self, _cmd, transitionRequest);
    }
    [[POExternalActivationCoordinator sharedInstance]
        prepareNativeTakeoverForTransitionRequestIfNeeded:transitionRequest];
    return POOriginalSBAppToAppWorkspaceTransactionInit(self, _cmd, transitionRequest);
}

#pragma mark - Scene state hooks

static FBScene *(*_po_orig_FBSceneManager_createSceneFromRemnant)(id, SEL, id, id, id);
static FBScene *(*_po_orig_FBSceneManager_createLegacySceneFromRemnant)(id, SEL, id, id, id);

static FBScene *_po_hook_FBSceneManager_createSceneFromRemnant(id self, SEL _cmd,
                                                               id remnant, id settings,
                                                               id transitionContext) {
    if (![POApplicationHelper isEnabled]) {
        return _po_orig_FBSceneManager_createSceneFromRemnant(self, _cmd, remnant, settings, transitionContext);
    }
    id primedSettings = [ContextHostManager primePendingSceneRemnantSettings:settings
                                                                         remnant:remnant];
    FBScene *scene = _po_orig_FBSceneManager_createSceneFromRemnant(self, _cmd, remnant,
                                                                    primedSettings ?: settings,
                                                                    transitionContext);
    [ContextHostManager completePendingSceneRemnantReconnect:scene];
    return scene;
}

static FBScene *_po_hook_FBSceneManager_createLegacySceneFromRemnant(id self, SEL _cmd,
                                                                     id remnant, id settings,
                                                                     id transitionContext) {
    if (![POApplicationHelper isEnabled]) {
        return _po_orig_FBSceneManager_createLegacySceneFromRemnant(self, _cmd, remnant, settings, transitionContext);
    }
    id primedSettings = [ContextHostManager primePendingSceneRemnantSettings:settings
                                                                         remnant:remnant];
    FBScene *scene = _po_orig_FBSceneManager_createLegacySceneFromRemnant(self, _cmd, remnant,
                                                                          primedSettings ?: settings,
                                                                          transitionContext);
    [ContextHostManager completePendingSceneRemnantReconnect:scene];
    return scene;
}

static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id settings, id ctx,
    id completion) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, settings, ctx,
                                                                                          completion);
        return;
    }
    settings = [ContextHostManager prepareNativeSceneSettingsIfNeeded:settings
                                                              forScene:(FBScene *)self] ?: settings;
    if ([ContextHostManager shouldKeepForegroundForScene:(FBScene *)self]) {
        @try {
            id mutableSettings = [settings mutableCopy] ?: settings;
            if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
                [mutableSettings setForeground:YES];
            }
            if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
                [mutableSettings setBackgrounded:NO];
            }
            if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
                [mutableSettings setDeactivationReasons:0];
            }
            [ContextHostManager reconcileHostedInterfaceOrientationInSettings:mutableSettings forScene:(FBScene *)self];
            POHandleSceneSettingsUpdate(self, mutableSettings);
            _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, mutableSettings,
                                                                                            ctx, completion);
            return;
        } @catch (__unused NSException *exception) {
        }
    }
    POHandleSceneSettingsUpdate(self, settings);
    _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$(self, _cmd, settings, ctx,
                                                                                    completion);
}

static void _logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$(
    _LOGOS_SELF_TYPE_NORMAL FBScene *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id settings, id ctx) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, settings, ctx);
        return;
    }
    settings = [ContextHostManager prepareNativeSceneSettingsIfNeeded:settings
                                                              forScene:(FBScene *)self] ?: settings;
    if ([ContextHostManager shouldKeepForegroundForScene:(FBScene *)self]) {
        @try {
            id mutableSettings = [settings mutableCopy] ?: settings;
            if ([mutableSettings respondsToSelector:@selector(setForeground:)]) {
                [mutableSettings setForeground:YES];
            }
            if ([mutableSettings respondsToSelector:@selector(setBackgrounded:)]) {
                [mutableSettings setBackgrounded:NO];
            }
            if ([mutableSettings respondsToSelector:@selector(setDeactivationReasons:)]) {
                [mutableSettings setDeactivationReasons:0];
            }
            [ContextHostManager reconcileHostedInterfaceOrientationInSettings:mutableSettings forScene:(FBScene *)self];
            POHandleSceneSettingsUpdate(self, mutableSettings);
            _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, mutableSettings, ctx);
            return;
        } @catch (__unused NSException *exception) {
        }
    }
    POHandleSceneSettingsUpdate(self, settings);
    _logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$(self, _cmd, settings, ctx);
}

#pragma mark - Application scene settings hooks

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    unsigned long long reasons) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(self, _cmd, reasons);
        return;
    }
    if (reasons != 0) {
        NSString *identifier = nil;
        id settings = (id)self;
        @try {
            for (NSString *key in
                 @[ @"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier" ]) {
                id value = [settings valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    identifier = value;
                    break;
                }
            }
        } @catch (__unused NSException *exception) {
        }
        if (!identifier && [settings respondsToSelector:@selector(identifier)]) {
            identifier = [settings identifier];
        }
        if ([ContextHostManager shouldKeepForegroundForIdentifier:identifier]) {
            _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(self, _cmd, 0);
            return;
        }
    }
    _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$(self, _cmd, reasons);
}

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    BOOL foreground) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(self, _cmd, foreground);
        return;
    }
    if (!foreground) {
        NSString *identifier = nil;
        id settings = (id)self;
        @try {
            for (NSString *key in
                 @[ @"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier" ]) {
                id value = [settings valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    identifier = value;
                    break;
                }
            }
        } @catch (__unused NSException *exception) {
        }
        if ([ContextHostManager shouldKeepForegroundForIdentifier:identifier]) {
            _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(self, _cmd, YES);
            return;
        }
    }
    _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$(self, _cmd, foreground);
}

static void _logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(
    _LOGOS_SELF_TYPE_NORMAL UIMutableApplicationSceneSettings *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd,
    BOOL backgrounded) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(self, _cmd, backgrounded);
        return;
    }
    if (backgrounded) {
        NSString *identifier = nil;
        id settings = (id)self;
        @try {
            for (NSString *key in
                 @[ @"_identifier", @"_sceneIdentifier", @"_bundleIdentifier", @"_persistentIdentifier" ]) {
                id value = [settings valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    identifier = value;
                    break;
                }
            }
        } @catch (__unused NSException *exception) {
        }
        if ([ContextHostManager shouldKeepForegroundForIdentifier:identifier]) {
            _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(self, _cmd, NO);
            return;
        }
    }
    _logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$(self, _cmd, backgrounded);
}

#pragma mark - SpringBoard hooks

static void _logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, UIApplication *arg1) {
    _logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$(self, _cmd, arg1);

    NSDictionary *settings = [POApplicationHelper settings];
    if (!POSettingsEnabled(settings)) {
        return;
    }

    POStartOrientationObserver();
    POReconcileCommittedInterfaceOrientation(@"launch", 0, NO);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      POApplyCurrentSettings();
    });
}

static void
_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, long long arg1,
    double arg2, BOOL arg3, BOOL arg4, id arg5) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
            self, _cmd, arg1, arg2, arg3, arg4, arg5);
        return;
    }
    PORecordSystemRotationCandidate((UIInterfaceOrientation)arg1, arg2);
    _logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$(
        self, _cmd, arg1, arg2, arg3, arg4, arg5);
    POReconcileCommittedInterfaceOrientation(@"springboard-commit", MAX(0, arg2), NO);
}

static void _logos_method$_ungrouped$SpringBoard$takeScreenshot(
    _LOGOS_SELF_TYPE_NORMAL SpringBoard *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$SpringBoard$takeScreenshot(self, _cmd);
        return;
    }
    BOOL enabled = [[POApplicationHelper settings][@"hideOnScreenshot"] boolValue];
    POHandle *handle = window.controller.handle;
    if (handle && enabled && !handle.hidden) {
        CGFloat previousAlpha = handle.alpha;
        handle.hidden = YES;
        handle.alpha = 0;

        [CATransaction flush];
        _logos_orig$_ungrouped$SpringBoard$takeScreenshot(self, _cmd);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          handle.hidden = NO;
          handle.alpha = previousAlpha;
        });
        return;
    }
    _logos_orig$_ungrouped$SpringBoard$takeScreenshot(self, _cmd);
}

#pragma mark - Hardware and screen-state handling

static void _logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$(
    _LOGOS_SELF_TYPE_NORMAL SBHomeHardwareButton *_LOGOS_SELF_CONST __unused self, SEL __unused _cmd, id arg1) {
    if (![POApplicationHelper isEnabled]) {
        _logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$(self, _cmd, arg1);
        return;
    }
    if ([window.controller isPanelActive]) {
        [window.controller close];
    } else {
        _logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$(self, _cmd, arg1);
    }
}

static void PORegisterScreenBlankObserver(void) {
    static dispatch_once_t onceToken;
    static int token = 0;
    dispatch_once(&onceToken, ^{
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t state = 0;
            if (notify_get_state(t, &state) != NOTIFY_STATUS_OK || state == 0) {
                return;
            }
            [window.controller forceCloseAndReleaseImmediately];
        });
    });
}

#pragma mark - Hook registration

static __attribute__((constructor)) void POInstallSpringBoardHooks(int __unused argc, char __unused **argv,
                                                                    char __unused **envp) {
    if (!objc_getClass("SpringBoard")) {
        return;
    }
    POSetCameraForegroundGrantBundleIdentifier(nil);
    if (POSettingsEnabled([POApplicationHelper settings])) {
        PORegisterScreenBlankObserver();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, POSettingsDidChange,
                                        kPOSettingsChangedNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    {
        Class sceneManagerClass = objc_getClass("FBSceneManager");
        SEL remnantSelector = NSSelectorFromString(@"createSceneFromRemnant:withSettings:transitionContext:");
        if ([sceneManagerClass instancesRespondToSelector:remnantSelector]) {
            MSHookMessageEx(sceneManagerClass,
                            remnantSelector,
                            (IMP)&_po_hook_FBSceneManager_createSceneFromRemnant,
                            (IMP *)&_po_orig_FBSceneManager_createSceneFromRemnant);
        }
        SEL legacyRemnantSelector = NSSelectorFromString(@"createLegacySceneFromRemnant:withSettings:transitionContext:");
        if ([sceneManagerClass instancesRespondToSelector:legacyRemnantSelector]) {
            MSHookMessageEx(sceneManagerClass,
                            legacyRemnantSelector,
                            (IMP)&_po_hook_FBSceneManager_createLegacySceneFromRemnant,
                            (IMP *)&_po_orig_FBSceneManager_createLegacySceneFromRemnant);
        }

        Class _logos_class$_ungrouped$FBScene = objc_getClass("FBScene");
        {
            MSHookMessageEx(_logos_class$_ungrouped$FBScene,
                            @selector(updateSettings:withTransitionContext:completion:),
                            (IMP)&_logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$,
                            (IMP *)&_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$completion$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$FBScene, @selector(updateSettings:withTransitionContext:),
                            (IMP)&_logos_method$_ungrouped$FBScene$updateSettings$withTransitionContext$,
                            (IMP *)&_logos_orig$_ungrouped$FBScene$updateSettings$withTransitionContext$);
        }
        Class _logos_class$_ungrouped$UIMutableApplicationSceneSettings =
            objc_getClass("UIMutableApplicationSceneSettings");
        {
            MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings,
                            @selector(setDeactivationReasons:),
                            (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$,
                            (IMP *)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setDeactivationReasons$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings, @selector(setForeground:),
                            (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setForeground$,
                            (IMP *)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setForeground$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$UIMutableApplicationSceneSettings, @selector(setBackgrounded:),
                            (IMP)&_logos_method$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$,
                            (IMP *)&_logos_orig$_ungrouped$UIMutableApplicationSceneSettings$setBackgrounded$);
        }
        Class mainWorkspaceClass = objc_getClass("SBMainWorkspace");
        SEL handleOpenSelector = NSSelectorFromString(@"systemService:handleOpenApplicationRequest:withCompletion:");
        if ([mainWorkspaceClass instancesRespondToSelector:handleOpenSelector]) {
            MSHookMessageEx(mainWorkspaceClass,
                            handleOpenSelector,
                            (IMP)&POHookSBMainWorkspaceHandleOpenApplicationRequest,
                            (IMP *)&POOriginalSBMainWorkspaceHandleOpenApplicationRequest);
        }
        SEL trustedOpenSelector = NSSelectorFromString(@"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:");
        if ([mainWorkspaceClass instancesRespondToSelector:trustedOpenSelector]) {
            MSHookMessageEx(mainWorkspaceClass,
                            trustedOpenSelector,
                            (IMP)&POHookSBMainWorkspaceHandleTrustedOpenApplicationRequest,
                            (IMP *)&POOriginalSBMainWorkspaceHandleTrustedOpenApplicationRequest);
        }
        SEL toAppsInitSelector = NSSelectorFromString(@"initWithTransitionRequest:");
        Class toAppsTransactionClass = objc_getClass("SBToAppsWorkspaceTransaction");
        if ([toAppsTransactionClass instancesRespondToSelector:toAppsInitSelector]) {
            MSHookMessageEx(toAppsTransactionClass,
                            toAppsInitSelector,
                            (IMP)&POHookSBToAppsWorkspaceTransactionInit,
                            (IMP *)&POOriginalSBToAppsWorkspaceTransactionInit);
        }
        Class appToAppTransactionClass = objc_getClass("SBAppToAppWorkspaceTransaction");
        if ([appToAppTransactionClass instancesRespondToSelector:toAppsInitSelector]) {
            MSHookMessageEx(appToAppTransactionClass,
                            toAppsInitSelector,
                            (IMP)&POHookSBAppToAppWorkspaceTransactionInit,
                            (IMP *)&POOriginalSBAppToAppWorkspaceTransactionInit);
        }

        Class _logos_class$_ungrouped$SpringBoard = objc_getClass("SpringBoard");
        {
            MSHookMessageEx(_logos_class$_ungrouped$SpringBoard, @selector(applicationDidFinishLaunching:),
                            (IMP)&_logos_method$_ungrouped$SpringBoard$applicationDidFinishLaunching$,
                            (IMP *)&_logos_orig$_ungrouped$SpringBoard$applicationDidFinishLaunching$);
        }
        {
            MSHookMessageEx(
                _logos_class$_ungrouped$SpringBoard,
                NSSelectorFromString(@"noteInterfaceOrientationChanged:duration:updateMirroredDisplays:force:logMessage:"),
                (IMP)&_logos_method$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$,
                (IMP *)&_logos_orig$_ungrouped$SpringBoard$noteInterfaceOrientationChanged$duration$updateMirroredDisplays$force$logMessage$);
        }
        {
            MSHookMessageEx(_logos_class$_ungrouped$SpringBoard, NSSelectorFromString(@"takeScreenshot"),
                            (IMP)&_logos_method$_ungrouped$SpringBoard$takeScreenshot,
                            (IMP *)&_logos_orig$_ungrouped$SpringBoard$takeScreenshot);
        }
        Class _logos_class$_ungrouped$SBHomeHardwareButton = objc_getClass("SBHomeHardwareButton");
        {
            MSHookMessageEx(_logos_class$_ungrouped$SBHomeHardwareButton, NSSelectorFromString(@"singlePressUp:"),
                            (IMP)&_logos_method$_ungrouped$SBHomeHardwareButton$singlePressUp$,
                            (IMP *)&_logos_orig$_ungrouped$SBHomeHardwareButton$singlePressUp$);
        }
    }
}
