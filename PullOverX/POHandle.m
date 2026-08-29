//
//  MHHandle.m
//  MessageHub
//
//  Created by Will Smillie on 1/18/19.
//

#import "POHandle.h"
#import <QuartzCore/QuartzCore.h>
#import "PullOverViewController.h"

#import "POApplicationHelper.h"

#define PO_HANDLE_DEFAULT_SIZE 34.0
#define PO_HANDLE_MINIMUM_SIZE 34.0
#define PO_HANDLE_MAXIMUM_SIZE 50.0
#define PO_HANDLE_DEFAULT_NUB_HIDDEN_PERCENTAGE 67.0
#define PO_HANDLE_MAXIMUM_NUB_HIDDEN_PERCENTAGE 80.0
#define PO_HANDLE_MINIMUM_TOUCH_SIZE 52.0

@interface POHandle () <UIGestureRecognizerDelegate> {
    UILabel *messageLabel;
    UIVisualEffectView *blurView;
    UILongPressGestureRecognizer *quickSwitchLongPress;
    UIPanGestureRecognizer *_panelPanGestureRecognizer;
}

-(void)applyCurrentPresentationAnimated:(BOOL)animated;

@end

@implementation POHandle

-(CGFloat)handleSize{
    id configuredValue = [POApplicationHelper settings][@"handleSize"];
    CGFloat size = configuredValue ? [configuredValue doubleValue] : PO_HANDLE_DEFAULT_SIZE;
    if (size <= 0) {
        size = PO_HANDLE_DEFAULT_SIZE;
    }
    return MIN(MAX(size, PO_HANDLE_MINIMUM_SIZE), PO_HANDLE_MAXIMUM_SIZE);
}

-(CGFloat)nubHiddenPercentage{
    id configuredValue = [POApplicationHelper settings][@"nubHiddenPercentage"];
    CGFloat percentage = configuredValue ? [configuredValue doubleValue] : PO_HANDLE_DEFAULT_NUB_HIDDEN_PERCENTAGE;
    if (percentage < 0) {
        percentage = PO_HANDLE_DEFAULT_NUB_HIDDEN_PERCENTAGE;
    }
    return MIN(MAX(percentage, 0), PO_HANDLE_MAXIMUM_NUB_HIDDEN_PERCENTAGE);
}

-(CGFloat)fullCornerRadius{
    return CGRectGetWidth(self.bounds) * (8.0 / PO_HANDLE_DEFAULT_SIZE);
}

-(CGFloat)nubbedCornerRadius{
    return CGRectGetWidth(self.bounds) * (6.0 / PO_HANDLE_DEFAULT_SIZE);
}

-(BOOL)usesNubbedPresentation{
    return self.layoutMode == POHandleLayoutModeVerticalRail && self.isNubbed;
}

-(CGFloat)nubbedOriginX{
    CGFloat containerWidth = CGRectGetWidth(self.superview.bounds);
    if (containerWidth <= 0) {
        containerWidth = 50.0;
    }
    CGFloat visibleWidth = CGRectGetWidth(self.bounds) * (1.0 - [self nubHiddenPercentage] / 100.0);
    return containerWidth - visibleWidth;
}

-(void)applyNubbedPosition{
    CGRect frame = self.frame;
    frame.origin.x = [self nubbedOriginX];
    self.frame = frame;
}

-(void)applyHandleSize{
    CGFloat size = [self handleSize];
    CGRect frame = self.frame;
    frame.size = CGSizeMake(size, size);
    self.frame = frame;
    self.layer.cornerRadius = [self fullCornerRadius];

    CGFloat iconSize = MAX(0, size - 10.0);
    self.imageView.frame = CGRectMake((CGRectGetWidth(self.bounds) - iconSize) / 2.0,
                                      (CGRectGetHeight(self.bounds) - iconSize) / 2.0,
                                      iconSize,
                                      iconSize);
    blurView.frame = self.bounds;
    blurView.layer.cornerRadius = [self usesNubbedPresentation] ? [self nubbedCornerRadius] : [self fullCornerRadius];
}

-(instancetype)initWithController:(id)hubController{
    if (self = [super initWithFrame:CGRectMake(0, 0, PO_HANDLE_DEFAULT_SIZE, PO_HANDLE_DEFAULT_SIZE)]) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
        self.layer.cornerRadius = 8;
        [self.layer setShadowColor:[UIColor blackColor].CGColor];
        [self.layer setShadowOpacity:0.32];
        [self.layer setShadowRadius:3.5];
        [self.layer setShadowOffset:CGSizeMake(0, 0)];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
        tap.delegate = self;
        [self addGestureRecognizer:tap];

        quickSwitchLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
        quickSwitchLongPress.minimumPressDuration = .3f;
        quickSwitchLongPress.delegate = self;
        quickSwitchLongPress.cancelsTouchesInView = NO;
        [self addGestureRecognizer:quickSwitchLongPress];
        [tap requireGestureRecognizerToFail:quickSwitchLongPress];
        _panelPanGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(panelPan:)];
        _panelPanGestureRecognizer.delegate = self;
        _panelPanGestureRecognizer.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:_panelPanGestureRecognizer];
        [_panelPanGestureRecognizer requireGestureRecognizerToFail:quickSwitchLongPress];
        [tap requireGestureRecognizerToFail:_panelPanGestureRecognizer];
        
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.frame = self.bounds;
        blurView.userInteractionEnabled = NO;
        blurView.layer.cornerRadius = 8;
        blurView.layer.cornerCurve = kCACornerCurveContinuous;
        blurView.clipsToBounds = YES;
        [self addSubview:blurView];
        

        self.imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        [self.imageView setBackgroundColor:[UIColor clearColor]];
        self.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.imageView.clipsToBounds = YES;
        self.imageView.tintColor = [UIColor lightGrayColor];
        [self addSubview:self.imageView];
        self.layoutMode = POHandleLayoutModeVerticalRail;
        [self applyHandleSize];
        
        [self setIsNubbed:[[NSUserDefaults standardUserDefaults] boolForKey:@"isNubbed"]];
    }
    return self;
}

-(void)setIsNubbed:(BOOL)isNubbed{
    _isNubbed = isNubbed;
    [[NSUserDefaults standardUserDefaults] setBool:isNubbed forKey:@"isNubbed"];
    [self applyCurrentPresentationAnimated:YES];
}

-(void)setLayoutMode:(POHandleLayoutMode)layoutMode{
    if (_layoutMode == layoutMode) {
        return;
    }
    _layoutMode = layoutMode;
    [self applyCurrentPresentationAnimated:NO];
}

-(void)applyCurrentPresentationAnimated:(BOOL)animated{
    void (^changes)(void) = ^{
        if ([self usesNubbedPresentation]) {
            [self applyNubbedPosition];
            self->blurView.layer.cornerRadius = [self nubbedCornerRadius];
        } else {
            CGRect frame = self.frame;
            frame.origin.x = self.restingOriginX;
            self.frame = frame;
            self->blurView.layer.cornerRadius = [self fullCornerRadius];
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.3 animations:changes];
    } else {
        changes();
    }
}

-(void)refreshHandleSizeAnimated:(BOOL)animated{
    void (^changes)(void) = ^{
        [self applyHandleSize];
    };
    if (animated) {
        [UIView animateWithDuration:0.2 animations:changes];
    } else {
        changes();
    }
}

-(void)refreshNubbedPositionAnimated:(BOOL)animated{
    [self applyCurrentPresentationAnimated:animated];
}

-(void)layoutSubviews{
    [super layoutSubviews];
    blurView.frame = self.bounds;
}

-(BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event{
    if (self.layoutMode == POHandleLayoutModeLandscapeFixedBottomLeft) {
        CGFloat horizontalInset = MAX(5.0, (PO_HANDLE_MINIMUM_TOUCH_SIZE - CGRectGetWidth(self.bounds)) / 2.0);
        CGFloat verticalInset = MAX(5.0, (PO_HANDLE_MINIMUM_TOUCH_SIZE - CGRectGetHeight(self.bounds)) / 2.0);
        CGRect hitRect = CGRectInset(self.bounds, -horizontalInset, -verticalInset);
        return CGRectContainsPoint(hitRect, point);
    }

    CGFloat containerWidth = CGRectGetWidth(self.superview.bounds);
    if (containerWidth <= 0) {
        containerWidth = 50.0;
    }

    CGFloat desiredHitLeftInContainer = containerWidth - PO_HANDLE_MINIMUM_TOUCH_SIZE;
    CGFloat leadingInset = MAX(5.0, CGRectGetMinX(self.frame) - desiredHitLeftInContainer);
    CGFloat verticalInset = MAX(5.0, (PO_HANDLE_MINIMUM_TOUCH_SIZE - CGRectGetHeight(self.bounds)) / 2.0);
    CGRect hitRect = CGRectMake(-leadingInset,
                                -verticalInset,
                                CGRectGetWidth(self.bounds) + leadingInset + 5.0,
                                CGRectGetHeight(self.bounds) + verticalInset * 2.0);
    return CGRectContainsPoint(hitRect, point);
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if ([self.superview isKindOfClass:[UIScrollView class]]) {
        UIPanGestureRecognizer *railPan = ((UIScrollView *)self.superview).panGestureRecognizer;
        [railPan requireGestureRecognizerToFail:quickSwitchLongPress];
        [railPan requireGestureRecognizerToFail:_panelPanGestureRecognizer];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == _panelPanGestureRecognizer) {
        CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self];
        CGFloat absX = fabs(velocity.x);
        CGFloat absY = fabs(velocity.y);
        if (self.layoutMode == POHandleLayoutModeLandscapeFixedBottomLeft) {
            return MAX(absX, absY) > 0.0 && fabs(absX - absY) > 0.01;
        }
        return absX > absY;
    }
    return YES;
}


-(void)tap:(UIGestureRecognizer *)recognizer{
    [self.delegate handle:self didReceiveTap:recognizer];
}

-(void)longPress:(UIGestureRecognizer *)recognizer{
    [self.delegate handle:self didLongPress:recognizer];
}

-(void)panelPan:(UIPanGestureRecognizer *)recognizer{
    [self.delegate handle:self didPanPanel:recognizer];
}


@end
