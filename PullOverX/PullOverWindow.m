//
//  PullOverWindow.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import "PullOverWindow.h"
#import "ContextHostManager.h"
#import <objc/message.h>

@interface UIWindow (PORotationPrivate)
- (void)_rotateWindowToOrientation:(long long)orientation
                   updateStatusBar:(BOOL)updateStatusBar
                          duration:(double)duration
                     skipCallbacks:(BOOL)skipCallbacks;
@end

@interface PullOverWindow ()
@property (nonatomic, assign, readwrite) UIInterfaceOrientation pullOverInterfaceOrientation;
@property (nonatomic, assign) NSUInteger orientationLayoutGeneration;
@property (nonatomic, assign) BOOL orientationTransitionInFlight;
- (void)applyPreferredWindowLevel;
- (BOOL)ensureBoundToMainScene;
- (void)normalizeWindowPlacement;
@end

static CGRect POSceneBoundsForRotation(UIWindowScene *scene) {
    if (!scene) {
        return CGRectZero;
    }
    SEL boundsSelector = NSSelectorFromString(@"bounds");
    if ([scene respondsToSelector:boundsSelector]) {
        return ((CGRect (*)(id, SEL))objc_msgSend)(scene, boundsSelector);
    }
    return scene.coordinateSpace.bounds;
}

static BOOL POUseSceneCompatibleWindowGeometry(UIWindowScene *scene) {
    (void)scene;
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26;
}

static BOOL POIsConcreteWindowOrientation(UIInterfaceOrientation orientation) {
    return orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
}

static UIInterfaceOrientation POCurrentWindowOrientation(UIWindowScene *scene,
                                                         UIInterfaceOrientation fallback) {
    if (POIsConcreteWindowOrientation(fallback)) {
        return fallback;
    }
    UIInterfaceOrientation orientation =
        [[ContextHostManager sharedInstance] currentSystemInterfaceOrientation];
    if (POIsConcreteWindowOrientation(orientation)) {
        return orientation;
    }
    CGRect screenBounds = scene.screen.bounds;
    return CGRectGetWidth(screenBounds) > CGRectGetHeight(screenBounds)
        ? UIInterfaceOrientationLandscapeRight
        : UIInterfaceOrientationPortrait;
}

static CGAffineTransform POOrientationTransform(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeRight:
            return CGAffineTransformMakeRotation((CGFloat)M_PI_2);
        case UIInterfaceOrientationLandscapeLeft:
            return CGAffineTransformMakeRotation((CGFloat)-M_PI_2);
        case UIInterfaceOrientationPortraitUpsideDown:
            return CGAffineTransformMakeRotation((CGFloat)M_PI);
        case UIInterfaceOrientationPortrait:
        default:
            return CGAffineTransformIdentity;
    }
}

@implementation PullOverWindow
@synthesize controller;

- (void)applyPreferredWindowLevel {
    // 主 scene 内参考：
    // SBStatusBarWindow=999、SBControlCenterWindow=1080。
    // 100 盖过 App，且明确低于状态栏 / 控制中心。
    self.windowLevel = 100.0;
}

+ (id)sharedWindow {
    static PullOverWindow *window = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        window = [[self alloc] init];
    });
    return window;
}

+ (UIWindowScene *)activeWindowScene {
    UIWindowScene *springboardClassScene = nil;
    UIWindowScene *fallback = nil;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        NSString *sceneID = windowScene.session.persistentIdentifier ?: @"";
        if ([sceneID isEqualToString:@"com.apple.springboard"]) {
            return windowScene;
        }

        NSString *role = windowScene.session.role ?: @"";
        NSString *className = NSStringFromClass([windowScene class]);
        BOOL isApertureOrKeyboard =
            [sceneID rangeOfString:@"SystemAperture" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [sceneID rangeOfString:@"keyboard" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [role rangeOfString:@"SystemAperture" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [role rangeOfString:@"Keyboard" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [className rangeOfString:@"SystemAperture" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (isApertureOrKeyboard) {
            continue;
        }

        if (!springboardClassScene && [className isEqualToString:@"SBWindowScene"]) {
            springboardClassScene = windowScene;
            continue;
        }

        if (!fallback && windowScene.activationState == UISceneActivationStateForegroundActive) {
            fallback = windowScene;
        }
    }

    return springboardClassScene ?: fallback;
}

- (BOOL)ensureBoundToMainScene {
    UIWindowScene *mainScene = [PullOverWindow activeWindowScene];
    if (!mainScene || self.windowScene == mainScene) {
        return NO;
    }

    self.windowScene = mainScene;
    CGRect bounds = mainScene.coordinateSpace.bounds;
    if (!CGRectIsEmpty(bounds)) {
        self.frame = bounds;
    }
    return YES;
}

- (void)normalizeWindowPlacement {
    UIWindowScene *scene = self.windowScene ?: [PullOverWindow activeWindowScene];
    if (POUseSceneCompatibleWindowGeometry(scene) && !scene) {
        return;
    }
    CGRect sceneBounds = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    if (CGRectIsEmpty(sceneBounds)) {
        return;
    }

    CGRect bounds = self.bounds;
    UIInterfaceOrientation orientation = self.pullOverInterfaceOrientation;
    BOOL concreteOrientation = orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
    if (POUseSceneCompatibleWindowGeometry(scene)) {
        bounds.size = sceneBounds.size;
    } else if (concreteOrientation) {
        CGFloat shortSide = MIN(CGRectGetWidth(sceneBounds), CGRectGetHeight(sceneBounds));
        CGFloat longSide = MAX(CGRectGetWidth(sceneBounds), CGRectGetHeight(sceneBounds));
        CGSize expectedSize = UIInterfaceOrientationIsLandscape(orientation)
            ? CGSizeMake(longSide, shortSide)
            : CGSizeMake(shortSide, longSide);
        if (fabs(bounds.size.width - expectedSize.width) > 0.25 ||
            fabs(bounds.size.height - expectedSize.height) > 0.25) {
            bounds.size = expectedSize;
        }
    }
    bounds.origin = CGPointZero;
    if (!CGRectEqualToRect(self.bounds, bounds)) {
        self.bounds = bounds;
    }

    CGPoint targetCenter = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGPoint center = self.center;
    if (fabs(center.x - targetCenter.x) > 0.25 || fabs(center.y - targetCenter.y) > 0.25) {
        self.center = targetCenter;
    }
}

- (void)applySceneCompatibleRootGeometryAnimated:(BOOL)animated
                                         duration:(NSTimeInterval)duration
                                       completion:(void (^)(BOOL finished))completion {
    if (!POUseSceneCompatibleWindowGeometry(self.windowScene) || !self.rootViewController.isViewLoaded) {
        if (completion) {
            completion(NO);
        }
        return;
    }

    CGRect sceneBounds = POSceneBoundsForRotation(self.windowScene);
    if (CGRectIsEmpty(sceneBounds)) {
        if (completion) {
            completion(NO);
        }
        return;
    }

    UIInterfaceOrientation orientation = POCurrentWindowOrientation(self.windowScene,
                                                                     self.pullOverInterfaceOrientation);
    CGFloat shortSide = MIN(CGRectGetWidth(sceneBounds), CGRectGetHeight(sceneBounds));
    CGFloat longSide = MAX(CGRectGetWidth(sceneBounds), CGRectGetHeight(sceneBounds));
    CGSize contentSize = UIInterfaceOrientationIsLandscape(orientation)
        ? CGSizeMake(longSide, shortSide)
        : CGSizeMake(shortSide, longSide);

    UIView *rootView = self.rootViewController.view;
    void (^changes)(void) = ^{
        [self normalizeWindowPlacement];
        rootView.transform = POOrientationTransform(orientation);
        rootView.bounds = (CGRect){ CGPointZero, contentSize };
        rootView.center = CGPointMake(CGRectGetMidX(sceneBounds), CGRectGetMidY(sceneBounds));
    };

    if (!animated || duration <= 0) {
        [UIView performWithoutAnimation:changes];
        if (completion) {
            completion(YES);
        }
        return;
    }

    Class animatorClass = NSClassFromString(@"UIStatusBarAnimationParameters");
    Class parametersClass = NSClassFromString(@"UIStatusBarOrientationAnimationParameters");
    SEL animateSelector = NSSelectorFromString(@"animateWithParameters:fromCurrentState:animations:completion:");
    id parameters = parametersClass ? [parametersClass new] : nil;
    if (animatorClass && parameters && [animatorClass respondsToSelector:animateSelector]) {
        ((void (*)(id, SEL, id, BOOL, id, id))objc_msgSend)(
            animatorClass,
            animateSelector,
            parameters,
            YES,
            changes,
            completion);
        return;
    }

    [UIView animateWithDuration:duration
                          delay:0
                        options:(UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction |
                                 UIViewAnimationOptionCurveEaseInOut)
                     animations:changes
                     completion:completion];
}

- (void)applySceneCompatibleRootGeometry {
    [self applySceneCompatibleRootGeometryAnimated:NO duration:0 completion:nil];
}

- (id)init {
    UIWindowScene *scene = [PullOverWindow activeWindowScene];
    if (scene) {
        self = [super initWithWindowScene:scene];
        if (self) {
            self.frame = scene.coordinateSpace.bounds;
        }
    } else {
        self = [super initWithFrame:[UIScreen mainScreen].bounds];
    }

    if (self) {
        self.pullOverInterfaceOrientation = UIInterfaceOrientationUnknown;
        self.orientationLayoutGeneration = 0;
        self.orientationTransitionInFlight = NO;
        [self applyPreferredWindowLevel];
        self.rootViewController = controller = [[PullOverViewController alloc] init];
        [self setHidden:YES];
        self.rootViewController.view.alpha = 0;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (BOOL)applyInterfaceOrientation:(UIInterfaceOrientation)orientation
                         duration:(NSTimeInterval)duration
                       completion:(void (^)(void))completion {
    BOOL validOrientation = orientation == UIInterfaceOrientationPortrait ||
        orientation == UIInterfaceOrientationPortraitUpsideDown ||
        orientation == UIInterfaceOrientationLandscapeLeft ||
        orientation == UIInterfaceOrientationLandscapeRight;
    if (!validOrientation) {
        return NO;
    }

    BOOL sceneRebound = [self ensureBoundToMainScene];
    BOOL orientationChanged = self.pullOverInterfaceOrientation != orientation;

    if (!orientationChanged && !sceneRebound) {
        if (!self.orientationTransitionInFlight) {
            [self normalizeWindowPlacement];
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
        return YES;
    }

    SEL rotateSelector = @selector(_rotateWindowToOrientation:updateStatusBar:duration:skipCallbacks:);
    if ((orientationChanged || sceneRebound) &&
        !POUseSceneCompatibleWindowGeometry(self.windowScene) &&
        ![UIWindow instancesRespondToSelector:rotateSelector]) {
        return NO;
    }

    NSUInteger generation = ++self.orientationLayoutGeneration;
    BOOL visible = !self.hidden && self.rootViewController.view.alpha > 0.01;
    NSTimeInterval animationDuration = duration > 0
        ? duration
        : (visible ? 0.25 : 0);
    if (orientationChanged || sceneRebound) {
        self.orientationTransitionInFlight = YES;
        self.pullOverInterfaceOrientation = orientation;
        [ContextHostManager sharedInstance].presentationInterfaceOrientation = orientation;
        if (POUseSceneCompatibleWindowGeometry(self.windowScene)) {
            [self applySceneCompatibleRootGeometryAnimated:animationDuration > 0
                                                   duration:animationDuration
                                                 completion:nil];
        } else {
            [super _rotateWindowToOrientation:orientation
                             updateStatusBar:NO
                                    duration:animationDuration
                               skipCallbacks:NO];
        }
    }

    __weak typeof(self) weakSelf = self;
    dispatch_block_t finishLayout = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.orientationLayoutGeneration) {
            return;
        }
        strongSelf.orientationTransitionInFlight = NO;
        [strongSelf requestLayoutFromCurrentScene];
        if (completion) {
            completion();
        }
    };
    if (animationDuration > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(animationDuration * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), finishLayout);
    } else {
        dispatch_async(dispatch_get_main_queue(), finishLayout);
    }
    return YES;
}

- (void)_rotateWindowToOrientation:(long long)__unused orientation
                   updateStatusBar:(BOOL)__unused updateStatusBar
                          duration:(double)__unused duration
                     skipCallbacks:(BOOL)__unused skipCallbacks {
}

- (void)requestLayoutFromCurrentScene {
    [self ensureBoundToMainScene];
    [self applyPreferredWindowLevel];
    [self normalizeWindowPlacement];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self.rootViewController.view setNeedsLayout];
    [self.rootViewController.view layoutIfNeeded];
    [self applySceneCompatibleRootGeometry];
    [[ContextHostManager sharedInstance] refreshPresentationForCurrentOrientation];
    [self.controller handleOrientationChange];
}

- (void)makeKeyAndVisible {
    [self ensureBoundToMainScene];
    [self applyPreferredWindowLevel];
    [super makeKeyAndVisible];
    [self applySceneCompatibleRootGeometry];
    if (!self.orientationTransitionInFlight) {
        [self normalizeWindowPlacement];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.orientationTransitionInFlight) {
        [self applySceneCompatibleRootGeometry];
        [self normalizeWindowPlacement];
    }
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    if (!self.orientationTransitionInFlight) {
        [self applySceneCompatibleRootGeometry];
        [self normalizeWindowPlacement];
    }
}

- (bool)_shouldCreateContextAsSecure {
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return [controller interactiveViewForWindowPoint:point event:event];
}

@end
