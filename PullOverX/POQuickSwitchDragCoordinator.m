#import "POQuickSwitchDragCoordinator.h"
#import "POApplicationHelper.h"
#import "../POLocalization.h"

@implementation POQuickSwitchDragCoordinator {
    __weak UIView *_overlayView;
    UIView *_targetView;
    UIImageView *_targetImageView;
    UILabel *_targetLabel;
    UIImageView *_draggedIconView;
    NSString *_displayName;
    BOOL _targetHighlighted;
}

- (instancetype)initWithOverlayView:(UIView *)overlayView {
    self = [super init];
    if (!self) {
        return nil;
    }

    _overlayView = overlayView;
    _targetView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    _targetView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _targetView.layer.cornerRadius = 20;
    _targetView.layer.cornerCurve = kCACornerCurveContinuous;
    _targetView.alpha = 0;
    [overlayView addSubview:_targetView];

    CAShapeLayer *border = [CAShapeLayer layer];
    border.strokeColor = UIColor.whiteColor.CGColor;
    border.fillColor = nil;
    border.lineWidth = PO_QUICKSWITCH_DROP_BORDER_WIDTH;
    border.lineDashPattern = PO_QUICKSWITCH_DROP_DASH_PATTERN;
    border.lineCap = kCALineCapRound;
    border.frame = _targetView.bounds;
    border.path = [UIBezierPath bezierPathWithRoundedRect:_targetView.bounds cornerRadius:20].CGPath;
    [_targetView.layer addSublayer:border];

    _targetImageView = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"arrowshape.turn.up.forward"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    _targetImageView.tintColor = UIColor.whiteColor;
    _targetImageView.contentMode = UIViewContentModeScaleAspectFit;
    _targetImageView.frame = CGRectMake(0, 0, 30, 30);
    _targetImageView.center = CGPointMake(50, 50);
    [_targetView addSubview:_targetImageView];

    _targetLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 44)];
    _targetLabel.textColor = UIColor.whiteColor;
    _targetLabel.textAlignment = NSTextAlignmentCenter;
    _targetLabel.numberOfLines = 2;
    _targetLabel.text = POLocalizedString(@"Drag QuickSwitch Items\nHere To Open", @"Tweak");
    _targetLabel.alpha = 0;
    [overlayView addSubview:_targetLabel];
    [self refreshLayoutDirection];
    return self;
}

- (BOOL)isDragging {
    return _draggedIconView != nil;
}

- (void)layoutForBounds:(CGRect)bounds safeAreaInsets:(UIEdgeInsets)safeAreaInsets {
    CGFloat minY = CGRectGetMinY(bounds) + safeAreaInsets.top;
    CGFloat maxY = CGRectGetMaxY(bounds) - safeAreaInsets.bottom;
    _targetView.center = CGPointMake(CGRectGetMidX(bounds), (minY + maxY) / 2.0);
    _targetLabel.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMaxY(_targetView.frame) + 16 + CGRectGetMidY(_targetLabel.bounds));
}

- (void)refreshLayoutDirection {
    BOOL leftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGAffineTransform transform = leftHanded ? CGAffineTransformMakeScale(-1, 1) : CGAffineTransformIdentity;
    _targetImageView.transform = transform;
    _targetLabel.transform = transform;
}

- (void)beginDraggingBundleId:(NSString *)bundleId
                   displayName:(NSString *)displayName
                    sourceView:(UIView *)sourceView
                   sourcePoint:(CGPoint)sourcePoint {
    if (bundleId.length == 0 || !sourceView || !_overlayView) {
        return;
    }

    if (!_draggedIconView) {
        _displayName = [displayName copy];
        CGPoint overlayPoint = [_overlayView convertPoint:sourcePoint fromView:sourceView];
        _draggedIconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 80, 80)];
        _draggedIconView.image = [POApplicationHelper imageForBundleId:bundleId];
        _draggedIconView.contentMode = UIViewContentModeScaleAspectFill;
        _draggedIconView.center = overlayPoint;
        [_overlayView addSubview:_draggedIconView];

        BOOL leftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
        CGAffineTransform contentTransform = leftHanded ? CGAffineTransformMakeScale(-1.0, 1.0) : CGAffineTransformIdentity;
        _draggedIconView.transform = CGAffineTransformScale(contentTransform, 0.01, 0.01);
        [UIView animateWithDuration:0.18 animations:^{
            self->_draggedIconView.transform = contentTransform;
            self->_targetView.alpha = 1;
            if (![[POApplicationHelper settings][@"hideLabels"] boolValue]) {
                self->_targetLabel.alpha = 1;
            }
        }];
    }
    [self updateDraggingFromView:sourceView atPoint:sourcePoint];
}

- (void)updateDraggingFromView:(UIView *)sourceView atPoint:(CGPoint)point {
    if (!_draggedIconView || !sourceView || !_overlayView) {
        return;
    }
    _draggedIconView.center = [_overlayView convertPoint:point fromView:sourceView];
    CGPoint targetPoint = [_targetView convertPoint:point fromView:sourceView];
    BOOL highlighted = CGRectContainsPoint(_targetView.bounds, targetPoint);
    if (_targetHighlighted == highlighted) {
        return;
    }
    _targetHighlighted = highlighted;
    [UIView animateWithDuration:0.16
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        NSString *format = POLocalizedString(@"Open %@", @"Tweak");
        self->_targetLabel.text = highlighted && self->_displayName.length > 0
            ? [NSString stringWithFormat:format, self->_displayName]
            : POLocalizedString(@"Drag QuickSwitch Items\nHere To Open", @"Tweak");
        self->_targetView.transform = highlighted ? CGAffineTransformMakeScale(1.3, 1.3) : CGAffineTransformIdentity;
        self->_targetView.backgroundColor = [UIColor colorWithWhite:1 alpha:highlighted ? 0.22 : 0.08];
    } completion:nil];
}

- (BOOL)finishDraggingFromView:(UIView *)sourceView atPoint:(CGPoint)point {
    if (!_draggedIconView || !sourceView) {
        return NO;
    }
    CGPoint targetPoint = [_targetView convertPoint:point fromView:sourceView];
    BOOL shouldOpen = CGRectContainsPoint(_targetView.bounds, targetPoint);
    [self cancelAnimated:!shouldOpen];
    return shouldOpen;
}

- (void)cancelAnimated:(BOOL)animated {
    UIImageView *draggedIconView = _draggedIconView;
    _draggedIconView = nil;
    _displayName = nil;
    _targetHighlighted = NO;
    [_targetView.layer removeAllAnimations];
    [_targetLabel.layer removeAllAnimations];

    void (^resetTarget)(void) = ^{
        self->_targetView.alpha = 0;
        self->_targetLabel.alpha = 0;
        self->_targetView.transform = CGAffineTransformIdentity;
        self->_targetView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self->_targetLabel.text = POLocalizedString(@"Drag QuickSwitch Items\nHere To Open", @"Tweak");
    };
    if (!draggedIconView) {
        resetTarget();
        return;
    }

    BOOL leftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGAffineTransform contentTransform = leftHanded ? CGAffineTransformMakeScale(-1.0, 1.0) : CGAffineTransformIdentity;
    draggedIconView.transform = contentTransform;
    void (^removeIcon)(void) = ^{
        draggedIconView.transform = CGAffineTransformScale(contentTransform, 0.01, 0.01);
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        [draggedIconView removeFromSuperview];
    };
    if (animated) {
        [UIView animateWithDuration:0.18 animations:removeIcon completion:completion];
        [UIView animateWithDuration:0.16 animations:resetTarget];
    } else {
        removeIcon();
        resetTarget();
        completion(YES);
    }
}

@end
