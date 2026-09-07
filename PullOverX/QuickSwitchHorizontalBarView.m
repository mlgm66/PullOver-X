//
//  QuickSwitchHorizontalBarView.m
//  PullOverX
//

#import "QuickSwitchHorizontalBarView.h"
#import "POApplicationHelper.h"
#import "POQuickSwitchMetrics.h"
#import <objc/runtime.h>

#define QS_HORIZONTAL_BAR_HEIGHT 50.0
#define QS_HORIZONTAL_ITEM_STRIDE POQuickSwitchSlotStride
#define QS_HORIZONTAL_ICON_SIZE POQuickSwitchIconSize
#define QS_HORIZONTAL_TILE_SIZE POQuickSwitchSelectionTileSize
#define QS_HORIZONTAL_BAR_CORNER_RADIUS POQuickSwitchMenuCornerRadius
#define QS_HORIZONTAL_TILE_CORNER_RADIUS POQuickSwitchSelectionTileCornerRadius
#define QS_HORIZONTAL_EDGE_MARGIN 10.0
#define QS_HORIZONTAL_CARD_GAP 5.0
#define QS_HORIZONTAL_SELECTED_POP 48.0
#define QS_HORIZONTAL_DRAG_EXIT_THRESHOLD 10.0
#define QS_PAGE_DWELL_DURATION 0.20
#define QS_PAGE_TRANSITION_DURATION 0.14
#define QS_PAGE_TRANSITION_DISTANCE 12.0
#define QS_HOVER_ANIMATION_DURATION 0.16

@interface QuickSwitchHorizontalItemView : UIView
@property (nonatomic, strong) UIVisualEffectView *tileView;
@property (nonatomic, strong) UIImageView *imgView;
@property (nonatomic, strong) POQuickSwitchEntry *entry;
@end

@implementation QuickSwitchHorizontalItemView
@end

@interface QuickSwitchHorizontalBarView () {
    NSArray<NSArray<POQuickSwitchEntry *> *> *pages;
    NSArray<POQuickSwitchEntry *> *slotEntries;
    NSMutableArray *itemViews;
    UIVisualEffectView *blurView;
    UIView *itemsContainerView;
    UIView *outgoingItemsContainerView;
    BOOL isPresenting;
    BOOL pageTransitionInProgress;
    BOOL extendsRight;
    BOOL leftHanded;
    NSInteger lastHoveredIndex;
    NSInteger latchedNavigationIndex;
    NSInteger pendingNavigationIndex;
    POQuickSwitchEntryKind pendingNavigationKind;
    NSUInteger slotCount;
    NSUInteger currentPageIndex;
    NSUInteger presentationGeneration;
    NSUInteger navigationDwellGeneration;
    NSDictionary *settings;
    UIImpactFeedbackGenerator *impactGenerator;
    POQuickSwitchSelectionFeedback *selectionFeedback;
    SBApplication *draggingApp;
    CGPoint lastGesturePoint;
    BOOL hasLastGesturePoint;
    CGFloat presentationAnchorX;
    CGFloat presentationOriginY;
}
@end

@implementation QuickSwitchHorizontalBarView

+ (CGFloat)preferredBarHeight {
    return QS_HORIZONTAL_BAR_HEIGHT;
}

-(instancetype)init{
    if (self = [super initWithFrame:CGRectZero]) {
        self.alpha = 0;
        self.hidden = YES;
        self.clipsToBounds = NO;
        self.backgroundColor = [UIColor clearColor];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.30;
        self.layer.shadowRadius = 3.5;
        self.layer.shadowOffset = CGSizeZero;

        blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        blurView.userInteractionEnabled = NO;
        blurView.layer.masksToBounds = YES;
        blurView.layer.cornerRadius = QS_HORIZONTAL_BAR_CORNER_RADIUS;
        blurView.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:blurView];

        itemViews = [NSMutableArray array];
        slotEntries = @[];
        pages = @[];
        lastHoveredIndex = -1;
        latchedNavigationIndex = -1;
        pendingNavigationIndex = -1;
        impactGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        selectionFeedback = [[POQuickSwitchSelectionFeedback alloc] init];
    }
    return self;
}

-(CGAffineTransform)iconLayoutTransform{
    return leftHanded ? CGAffineTransformMakeScale(-1.0, 1.0) : CGAffineTransformIdentity;
}

-(void)refreshLayoutDirection{
    leftHanded = [[POApplicationHelper settings][@"leftHanded"] boolValue];
    CGAffineTransform transform = [self iconLayoutTransform];
    for (id value in itemViews) {
        if ([value isKindOfClass:[QuickSwitchHorizontalItemView class]]) {
            ((QuickSwitchHorizontalItemView *)value).imgView.transform = transform;
        }
    }
}

-(UIImage *)imageForEntry:(POQuickSwitchEntry *)entry{
    if (entry.kind == POQuickSwitchEntryKindApplication) {
        return [POApplicationHelper imageForBundleId:entry.bundleIdentifier];
    }

    BOOL screenExtendsRight = extendsRight != leftHanded;
    BOOL pointsRight = entry.kind == POQuickSwitchEntryKindPreviousPage
        ? !screenExtendsRight
        : screenExtendsRight;
    NSString *symbolName = pointsRight ? @"chevron.forward.circle" : @"chevron.backward.circle";
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:QS_HORIZONTAL_ICON_SIZE
                                                        weight:UIImageSymbolWeightRegular];
    return [UIImage systemImageNamed:symbolName withConfiguration:configuration];
}

-(NSArray *)slotEntriesForPage:(NSArray<POQuickSwitchEntry *> *)page{
    POQuickSwitchEntry *previousEntry = nil;
    POQuickSwitchEntry *nextEntry = nil;
    NSMutableArray<POQuickSwitchEntry *> *applications = [NSMutableArray array];
    for (POQuickSwitchEntry *entry in page) {
        if (entry.kind == POQuickSwitchEntryKindApplication) {
            [applications addObject:entry];
        } else if (entry.kind == POQuickSwitchEntryKindPreviousPage) {
            previousEntry = entry;
        } else if (entry.kind == POQuickSwitchEntryKindNextPage) {
            nextEntry = entry;
        }
    }

    NSMutableArray<POQuickSwitchEntry *> *screenSlots = [NSMutableArray arrayWithCapacity:page.count];
    BOOL screenExtendsRight = extendsRight != leftHanded;
    if (pages.count <= 1 || screenExtendsRight) {
        if (pages.count > 1 && previousEntry) {
            [screenSlots addObject:previousEntry];
        }
        [screenSlots addObjectsFromArray:applications];
        if (pages.count > 1 && nextEntry) {
            [screenSlots addObject:nextEntry];
        }
    } else {
        if (pages.count > 1 && nextEntry) {
            [screenSlots addObject:nextEntry];
        }
        [screenSlots addObjectsFromArray:applications];
        if (pages.count > 1 && previousEntry) {
            [screenSlots addObject:previousEntry];
        }
    }

    return leftHanded ? [[screenSlots reverseObjectEnumerator] allObjects] : screenSlots;
}

-(NSUInteger)visibleSlotCountForPageIndex:(NSUInteger)pageIndex{
    return pageIndex < pages.count ? pages[pageIndex].count : 0;
}

-(CGRect)barFrameForPageIndex:(NSUInteger)pageIndex{
    CGFloat width = QS_HORIZONTAL_ITEM_STRIDE * [self visibleSlotCountForPageIndex:pageIndex] +
        POQuickSwitchMenuEdgePadding * 2.0;
    CGFloat originX = extendsRight ? presentationAnchorX : presentationAnchorX - width;
    return CGRectMake(round(originX), round(presentationOriginY), width, QS_HORIZONTAL_BAR_HEIGHT);
}

-(void)updatePageVisualGeometry{
    blurView.frame = self.bounds;
    self.layer.cornerRadius = QS_HORIZONTAL_BAR_CORNER_RADIUS;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    blurView.layer.cornerRadius = QS_HORIZONTAL_BAR_CORNER_RADIUS;
    blurView.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                       cornerRadius:QS_HORIZONTAL_BAR_CORNER_RADIUS].CGPath;
    itemsContainerView.frame = CGRectMake(POQuickSwitchMenuEdgePadding,
                                           0,
                                           MAX(0, CGRectGetWidth(self.bounds) - POQuickSwitchMenuEdgePadding * 2.0),
                                           CGRectGetHeight(self.bounds));
}

-(void)applyPageGeometryForPageIndex:(NSUInteger)pageIndex animated:(BOOL)animated{
    CGRect targetFrame = [self barFrameForPageIndex:pageIndex];
    void (^changes)(void) = ^{
        self.frame = targetFrame;
        [self updatePageVisualGeometry];
    };
    if (animated) {
        [UIView animateWithDuration:QS_PAGE_TRANSITION_DURATION
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:changes
                         completion:nil];
    } else {
        [UIView performWithoutAnimation:changes];
    }
}

-(UIView *)buildItemsContainerForPageIndex:(NSUInteger)pageIndex{
    NSArray<POQuickSwitchEntry *> *page = pages[pageIndex];
    slotEntries = [self slotEntriesForPage:page];
    itemViews = [NSMutableArray arrayWithCapacity:slotEntries.count];

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(POQuickSwitchMenuEdgePadding,
                                                                  0,
                                                                  QS_HORIZONTAL_ITEM_STRIDE * slotEntries.count,
                                                                  QS_HORIZONTAL_BAR_HEIGHT)];
    container.clipsToBounds = NO;
    CGAffineTransform iconTransform = [self iconLayoutTransform];

    [slotEntries enumerateObjectsUsingBlock:^(POQuickSwitchEntry *entry, NSUInteger index, BOOL *stop) {
        QuickSwitchHorizontalItemView *itemView =
            [[QuickSwitchHorizontalItemView alloc] initWithFrame:CGRectMake(index * QS_HORIZONTAL_ITEM_STRIDE,
                                                                            0,
                                                                            QS_HORIZONTAL_ITEM_STRIDE,
                                                                            QS_HORIZONTAL_BAR_HEIGHT)];
        itemView.entry = entry;
        itemView.clipsToBounds = NO;

        UIVisualEffectView *tileView = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        tileView.translatesAutoresizingMaskIntoConstraints = NO;
        tileView.layer.cornerRadius = QS_HORIZONTAL_TILE_CORNER_RADIUS;
        tileView.layer.cornerCurve = kCACornerCurveContinuous;
        tileView.layer.masksToBounds = YES;
        tileView.alpha = 0;
        tileView.userInteractionEnabled = NO;
        itemView.tileView = tileView;
        [itemView addSubview:tileView];

        UIImageView *imageView = [[UIImageView alloc] initWithImage:[self imageForEntry:entry]];
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.transform = iconTransform;
        imageView.userInteractionEnabled = NO;
        if (entry.kind != POQuickSwitchEntryKindApplication) {
            imageView.tintColor = UIColor.labelColor;
            itemView.isAccessibilityElement = YES;
            itemView.accessibilityLabel = entry.kind == POQuickSwitchEntryKindPreviousPage
                ? @"上一页"
                : @"下一页";
        }
        itemView.imgView = imageView;
        [itemView addSubview:imageView];

        [NSLayoutConstraint activateConstraints:@[
            [tileView.widthAnchor constraintEqualToConstant:QS_HORIZONTAL_TILE_SIZE],
            [tileView.heightAnchor constraintEqualToConstant:QS_HORIZONTAL_TILE_SIZE],
            [tileView.centerXAnchor constraintEqualToAnchor:itemView.centerXAnchor],
            [tileView.centerYAnchor constraintEqualToAnchor:itemView.centerYAnchor],
            [imageView.widthAnchor constraintEqualToConstant:QS_HORIZONTAL_ICON_SIZE],
            [imageView.heightAnchor constraintEqualToConstant:QS_HORIZONTAL_ICON_SIZE],
            [imageView.centerXAnchor constraintEqualToAnchor:tileView.centerXAnchor],
            [imageView.centerYAnchor constraintEqualToAnchor:tileView.centerYAnchor],
        ]];

        [container addSubview:itemView];
        [self->itemViews addObject:itemView];
    }];
    return container;
}

-(QuickSwitchHorizontalItemView *)itemViewAtIndex:(NSInteger)index{
    if (index < 0 || index >= (NSInteger)itemViews.count) {
        return nil;
    }
    return itemViews[(NSUInteger)index];
}

-(POQuickSwitchEntry *)entryAtIndex:(NSInteger)index{
    if (index < 0 || index >= (NSInteger)slotEntries.count) {
        return nil;
    }
    return slotEntries[(NSUInteger)index];
}

-(void)setHoveredIndex:(NSInteger)index animated:(BOOL)animated{
    if (index == lastHoveredIndex) {
        return;
    }

    QuickSwitchHorizontalItemView *oldItem = [self itemViewAtIndex:lastHoveredIndex];
    QuickSwitchHorizontalItemView *newItem = [self itemViewAtIndex:index];
    void (^changes)(void) = ^{
        if (oldItem) {
            oldItem.layer.zPosition = 0;
            oldItem.transform = CGAffineTransformIdentity;
            oldItem.tileView.alpha = 0;
        }
        if (newItem) {
            newItem.layer.zPosition = 3;
            newItem.transform = CGAffineTransformMakeTranslation(0, -QS_HORIZONTAL_SELECTED_POP);
            newItem.tileView.alpha = 1;
        }
    };
    if (animated) {
        [UIView animateWithDuration:QS_HOVER_ANIMATION_DURATION
                              delay:0
                            options:(UIViewAnimationOptionCurveEaseOut |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction)
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
    lastHoveredIndex = index;
}

-(void)cancelNavigationDwell{
    navigationDwellGeneration += 1;
    pendingNavigationIndex = -1;
}

-(void)clearHoverAnimated:(BOOL)animated notifyDelegate:(BOOL)notifyDelegate{
    [self cancelNavigationDwell];
    [self setHoveredIndex:-1 animated:animated];
    if (notifyDelegate) {
        [self.selectionDelegate quickSwitchTableViewDidClearHover:self];
    }
}

-(NSInteger)hoveredIndexForPoint:(CGPoint)point{
    if (point.x < POQuickSwitchMenuEdgePadding ||
        point.x >= CGRectGetWidth(self.bounds) - POQuickSwitchMenuEdgePadding ||
        point.y < 0 || point.y > CGRectGetHeight(self.bounds) + QS_HORIZONTAL_SELECTED_POP) {
        return -1;
    }
    NSInteger index = (NSInteger)floor((point.x - POQuickSwitchMenuEdgePadding) /
                                        QS_HORIZONTAL_ITEM_STRIDE);
    return [self entryAtIndex:index] ? index : -1;
}

-(void)finishPageTransitionForGeneration:(NSUInteger)generation oldContainer:(UIView *)oldContainer{
    [oldContainer removeFromSuperview];
    if (outgoingItemsContainerView == oldContainer) {
        outgoingItemsContainerView = nil;
    }
    if (generation != presentationGeneration || !isPresenting) {
        return;
    }

    pageTransitionInProgress = NO;
    itemsContainerView.alpha = 1;
    itemsContainerView.transform = CGAffineTransformIdentity;
    if (hasLastGesturePoint) {
        [self updateInteractionForPoint:lastGesturePoint];
    }
}

-(void)turnPageForEntryKind:(POQuickSwitchEntryKind)kind triggeringIndex:(NSInteger)index{
    NSInteger targetPage = kind == POQuickSwitchEntryKindNextPage
        ? (NSInteger)currentPageIndex + 1
        : (NSInteger)currentPageIndex - 1;
    if (pageTransitionInProgress || targetPage < 0 || targetPage >= (NSInteger)pages.count) {
        return;
    }

    [self cancelNavigationDwell];
    latchedNavigationIndex = index;
    [self clearHoverAnimated:NO notifyDelegate:YES];
    draggingApp = nil;
    pageTransitionInProgress = YES;

    [selectionFeedback selectionChanged];
    [selectionFeedback prepare];

    UIView *oldContainer = itemsContainerView;
    outgoingItemsContainerView = oldContainer;
    currentPageIndex = (NSUInteger)targetPage;
    UIView *newContainer = [self buildItemsContainerForPageIndex:currentPageIndex];
    itemsContainerView = newContainer;
    [self addSubview:newContainer];
    hasLastGesturePoint = NO;
    [self applyPageGeometryForPageIndex:currentPageIndex animated:YES];

    CGFloat outwardDirection = extendsRight ? 1.0 : -1.0;
    CGFloat oldDirection = kind == POQuickSwitchEntryKindNextPage
        ? -outwardDirection
        : outwardDirection;
    newContainer.alpha = 0;
    newContainer.transform = CGAffineTransformMakeTranslation(-oldDirection * QS_PAGE_TRANSITION_DISTANCE, 0);
    NSUInteger generation = presentationGeneration;
    [UIView animateWithDuration:QS_PAGE_TRANSITION_DURATION
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        oldContainer.alpha = 0;
        oldContainer.transform = CGAffineTransformMakeTranslation(oldDirection * QS_PAGE_TRANSITION_DISTANCE, 0);
        newContainer.alpha = 1;
        newContainer.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [self finishPageTransitionForGeneration:generation oldContainer:oldContainer];
    }];
}

-(void)schedulePageTurnForEntry:(POQuickSwitchEntry *)entry atIndex:(NSInteger)index{
    [self cancelNavigationDwell];
    pendingNavigationKind = entry.kind;
    pendingNavigationIndex = index;
    NSUInteger dwellGeneration = navigationDwellGeneration;
    NSUInteger menuGeneration = presentationGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(QS_PAGE_DWELL_DURATION * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (dwellGeneration != self->navigationDwellGeneration ||
            menuGeneration != self->presentationGeneration ||
            !self->isPresenting || self->pageTransitionInProgress ||
            self->pendingNavigationIndex != index || self->lastHoveredIndex != index ||
            [self hoveredIndexForPoint:self->lastGesturePoint] != index) {
            return;
        }
        POQuickSwitchEntry *currentEntry = [self entryAtIndex:index];
        if (!currentEntry || currentEntry.kind != self->pendingNavigationKind) {
            return;
        }
        [self turnPageForEntryKind:currentEntry.kind triggeringIndex:index];
    });
}

-(void)updateInteractionForPoint:(CGPoint)point{
    lastGesturePoint = point;
    hasLastGesturePoint = YES;
    if (pageTransitionInProgress) {
        return;
    }

    NSInteger index = [self hoveredIndexForPoint:point];
    if (latchedNavigationIndex >= 0) {
        if (index == latchedNavigationIndex) {
            return;
        }
        latchedNavigationIndex = -1;
    }

    CGRect dragExitBounds = CGRectInset(self.bounds,
                                        -QS_HORIZONTAL_DRAG_EXIT_THRESHOLD,
                                        -QS_HORIZONTAL_DRAG_EXIT_THRESHOLD);
    if (draggingApp) {
        if (!CGRectContainsPoint(self.bounds, point)) {
            [self.selectionDelegate quickSwitchTableView:self
                     draggingDidChangeForQuickSwitchItem:draggingApp
                                              withPoint:point];
            return;
        }

        draggingApp = nil;
        [self.selectionDelegate draggingDidEnterBoundsOfQuickSwitchTableView:self];
    }

    if (lastHoveredIndex >= 0 && !CGRectContainsPoint(dragExitBounds, point)) {
        POQuickSwitchEntry *hoveredEntry = [self entryAtIndex:lastHoveredIndex];
        [self clearHoverAnimated:YES notifyDelegate:YES];
        if (hoveredEntry && hoveredEntry.kind == POQuickSwitchEntryKindApplication) {
            draggingApp = [[objc_getClass("SBApplicationController") sharedInstance]
                applicationWithBundleIdentifier:hoveredEntry.bundleIdentifier];
        }
        if (draggingApp) {
            [self.selectionDelegate quickSwitchTableView:self
                     draggingDidChangeForQuickSwitchItem:draggingApp
                                              withPoint:point];
        }
        return;
    }

    if (!CGRectContainsPoint(self.bounds, point)) {
        POQuickSwitchEntry *hoveredEntry = [self entryAtIndex:lastHoveredIndex];
        if (hoveredEntry && hoveredEntry.kind == POQuickSwitchEntryKindApplication) {
            return;
        }
        if (lastHoveredIndex >= 0) {
            [self clearHoverAnimated:YES notifyDelegate:YES];
        } else {
            [self cancelNavigationDwell];
        }
        return;
    }

    POQuickSwitchEntry *entry = [self entryAtIndex:index];
    if (!entry) {
        if (lastHoveredIndex >= 0) {
            [self clearHoverAnimated:YES notifyDelegate:YES];
        } else {
            [self cancelNavigationDwell];
        }
        return;
    }
    if (index == lastHoveredIndex) {
        return;
    }

    [self cancelNavigationDwell];
    [self setHoveredIndex:index animated:YES];
    draggingApp = nil;
    if (entry.kind == POQuickSwitchEntryKindApplication) {
        [selectionFeedback selectionChanged];
        [selectionFeedback prepare];
        [self.selectionDelegate quickSwitchTableView:self didHoverBundleId:entry.bundleIdentifier];
    } else {
        [self.selectionDelegate quickSwitchTableViewDidClearHover:self];
        [self schedulePageTurnForEntry:entry atIndex:index];
    }
}

-(void)resetPagingInteraction{
    [self cancelNavigationDwell];
    latchedNavigationIndex = -1;
    pageTransitionInProgress = NO;
    hasLastGesturePoint = NO;
    [outgoingItemsContainerView.layer removeAllAnimations];
    [outgoingItemsContainerView removeFromSuperview];
    outgoingItemsContainerView = nil;
    [itemsContainerView.layer removeAllAnimations];
    itemsContainerView.alpha = 1;
    itemsContainerView.transform = CGAffineTransformIdentity;
}

-(BOOL)presentFromHandle:(UIView *)handle withRecognizer:(UILongPressGestureRecognizer *)recognizer{
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        presentationGeneration += 1;
        settings = [POApplicationHelper settings];
        [selectionFeedback configureWithHapticsEnabled:[settings[@"hapticFeedback"] boolValue]
                                          soundEnabled:[settings[@"soundFeedback"] boolValue]];
        leftHanded = [settings[@"leftHanded"] boolValue];
        draggingApp = nil;
        [self resetPagingInteraction];
        [self setHoveredIndex:-1 animated:NO];

        UIView *coordinateView = self.superview;
        CGRect anchorFrame = CGRectIsEmpty(self.presentationAnchorFrame)
            ? UIEdgeInsetsInsetRect(coordinateView.bounds,
                                    UIEdgeInsetsMake(0, QS_HORIZONTAL_EDGE_MARGIN, 0, QS_HORIZONTAL_EDGE_MARGIN))
            : self.presentationAnchorFrame;
        CGRect handleFrame = [handle convertRect:handle.bounds toView:coordinateView];
        extendsRight = CGRectGetMidX(handleFrame) <= CGRectGetMidX(anchorFrame);
        CGFloat availableWidth = extendsRight
            ? CGRectGetMaxX(anchorFrame) - CGRectGetMinX(handleFrame)
            : CGRectGetMaxX(handleFrame) - CGRectGetMinX(anchorFrame);
        NSUInteger anchorSlotCount = (NSUInteger)floor(MAX(0,
            availableWidth - POQuickSwitchMenuEdgePadding * 2.0) / QS_HORIZONTAL_ITEM_STRIDE);
        slotCount = anchorSlotCount;
        NSArray<NSString *> *allItems = [POApplicationHelper quickSwitchBundleIdentifiers];
        NSUInteger applicationSlotLimit = (NSUInteger)MAX(1,
            [settings[@"quickSwitchAppSlots"] integerValue]);
        pages = POQuickSwitchBuildPages(allItems,
                                        applicationSlotLimit,
                                        slotCount);
        if (pages.count == 0) {
            isPresenting = NO;
            return NO;
        }

        currentPageIndex = MIN(currentPageIndex, pages.count - 1);
        presentationAnchorX = extendsRight ? CGRectGetMinX(handleFrame) : CGRectGetMaxX(handleFrame);
        presentationOriginY = CGRectGetMaxY(anchorFrame) + QS_HORIZONTAL_CARD_GAP;
        CGFloat width = QS_HORIZONTAL_ITEM_STRIDE * [self visibleSlotCountForPageIndex:currentPageIndex] +
            POQuickSwitchMenuEdgePadding * 2.0;
        self.layer.anchorPoint = CGPointMake(extendsRight ? 0.0 : 1.0, 0.5);
        [self applyPageGeometryForPageIndex:currentPageIndex animated:NO];

        [itemsContainerView removeFromSuperview];
        itemsContainerView = [self buildItemsContainerForPageIndex:currentPageIndex];
        [self addSubview:itemsContainerView];

        if ([settings[@"hapticFeedback"] boolValue]) {
            [impactGenerator prepare];
            [impactGenerator impactOccurred];
        }
        [selectionFeedback prepare];
        self.hidden = NO;
        self.alpha = 0;
        CGFloat handleWidth = MIN(CGRectGetWidth(handleFrame), width);
        CGFloat startScaleX = width > 0 ? MAX(0.01, handleWidth / width) : 1.0;
        self.transform = CGAffineTransformMakeScale(startScaleX, 1.12);
        isPresenting = YES;
        [self.selectionDelegate quickSwitchTableViewWillAppear:self];
        [UIView animateWithDuration:0.12 animations:^{
            self.alpha = 1;
        }];
        [UIView animateWithDuration:0.62
                              delay:0
             usingSpringWithDamping:0.58
              initialSpringVelocity:0.9
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.transform = CGAffineTransformIdentity;
        } completion:nil];
        return YES;
    }

    if (!isPresenting) {
        return NO;
    }

    CGPoint point = [recognizer locationInView:self];
    lastGesturePoint = point;
    hasLastGesturePoint = YES;
    if (recognizer.state == UIGestureRecognizerStateChanged) {
        [self updateInteractionForPoint:point];
        return YES;
    }

    if (recognizer.state == UIGestureRecognizerStateEnded) {
        NSInteger index = [self hoveredIndexForPoint:point];
        POQuickSwitchEntry *entry = [self entryAtIndex:index];
        if (draggingApp) {
            [self.selectionDelegate quickSwitchTableView:self didDropApp:draggingApp atPoint:point];
        } else if (!pageTransitionInProgress && index >= 0 && index == lastHoveredIndex &&
                   index != latchedNavigationIndex &&
                   entry.kind == POQuickSwitchEntryKindApplication) {
            if ([settings[@"hapticFeedback"] boolValue]) {
                [impactGenerator impactOccurred];
            }
            [self.selectionDelegate quickSwitchTableView:self didSelectBundleId:entry.bundleIdentifier];
        }
        [self dismissImmediately];
        return YES;
    }

    if (recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        [self dismissImmediately];
    }
    return YES;
}

-(void)dismissImmediately{
    if (!isPresenting && self.hidden) {
        return;
    }
    presentationGeneration += 1;
    [self.layer removeAllAnimations];
    [self clearHoverAnimated:NO notifyDelegate:NO];
    [self resetPagingInteraction];
    draggingApp = nil;
    self.alpha = 0;
    self.transform = CGAffineTransformIdentity;
    self.hidden = YES;
    isPresenting = NO;
    [self.selectionDelegate quickSwitchTableViewDidDisappear:self];
}

@end
