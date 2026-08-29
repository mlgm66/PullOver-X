//
//  QuickSwitchTableView.m
//  PullOverX
//

#import "QuickSwitchTableView.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "PullOverWindow.h"
#import "POQuickSwitchMetrics.h"

#define QS_LIST_WIDTH 50.0
#define QS_ROW_HEIGHT POQuickSwitchSlotStride
#define QS_VERTICAL_SCREEN_EDGE_MARGIN 10.0
#define QS_HORIZONTAL_SCREEN_EDGE_MARGIN 5.0
#define QS_CORNER_RADIUS POQuickSwitchMenuCornerRadius
#define QS_PAGE_DWELL_DURATION 0.20
#define QS_PAGE_TRANSITION_DURATION 0.14
#define QS_PAGE_TRANSITION_DISTANCE 12.0
#define QS_HOVER_ANIMATION_DURATION 0.18

@interface POQuickSwitchEntry ()
@property (nonatomic, readwrite) POQuickSwitchEntryKind kind;
@property (nonatomic, copy, readwrite) NSString *bundleIdentifier;
@end

@implementation POQuickSwitchEntry

+ (instancetype)entryWithKind:(POQuickSwitchEntryKind)kind bundleIdentifier:(NSString *)bundleIdentifier{
    POQuickSwitchEntry *entry = [[self alloc] init];
    entry.kind = kind;
    entry.bundleIdentifier = bundleIdentifier;
    return entry;
}

+ (instancetype)applicationEntryWithBundleIdentifier:(NSString *)bundleIdentifier{
    return [self entryWithKind:POQuickSwitchEntryKindApplication bundleIdentifier:bundleIdentifier];
}

+ (instancetype)previousPageEntry{
    return [self entryWithKind:POQuickSwitchEntryKindPreviousPage bundleIdentifier:nil];
}

+ (instancetype)nextPageEntry{
    return [self entryWithKind:POQuickSwitchEntryKindNextPage bundleIdentifier:nil];
}

@end

@interface UIFeedbackGenerator (POPrivateConfiguration)
-(instancetype)initWithConfiguration:(id)configuration;
@end

@interface POQuickSwitchSelectionFeedback () {
    UISelectionFeedbackGenerator *generator;
    BOOL configured;
    BOOL hapticsEnabled;
    BOOL soundEnabled;
}
@end

@implementation POQuickSwitchSelectionFeedback

-(void)configureWithHapticsEnabled:(BOOL)newHapticsEnabled soundEnabled:(BOOL)newSoundEnabled{
    if (configured && hapticsEnabled == newHapticsEnabled && soundEnabled == newSoundEnabled) {
        return;
    }

    configured = YES;
    hapticsEnabled = newHapticsEnabled;
    soundEnabled = newSoundEnabled;
    generator = nil;
    if (!hapticsEnabled && !soundEnabled) {
        return;
    }

    if (!soundEnabled) {
        generator = [[UISelectionFeedbackGenerator alloc] init];
        return;
    }

    Class configurationClass = NSClassFromString(@"_UISelectionFeedbackGeneratorConfiguration");
    SEL pickerConfigurationSelector = NSSelectorFromString(@"pickerConfiguration");
    SEL configurationInitializer = NSSelectorFromString(@"initWithConfiguration:");
    SEL fastHapticVolumeSelector = NSSelectorFromString(@"setFastHapticVolume:");
    SEL slowHapticVolumeSelector = NSSelectorFromString(@"setSlowHapticVolume:");
    if (![configurationClass respondsToSelector:pickerConfigurationSelector] ||
        ![UISelectionFeedbackGenerator instancesRespondToSelector:configurationInitializer]) {
        return;
    }

    id configuration = ((id (*)(id, SEL))objc_msgSend)(configurationClass,
                                                        pickerConfigurationSelector);
    if (!configuration ||
        (!hapticsEnabled && (![configuration respondsToSelector:fastHapticVolumeSelector] ||
                             ![configuration respondsToSelector:slowHapticVolumeSelector]))) {
        return;
    }
    configuration = [configuration copy];
    if (!hapticsEnabled) {
        ((void (*)(id, SEL, double))objc_msgSend)(configuration,
                                                  fastHapticVolumeSelector,
                                                  0);
        ((void (*)(id, SEL, double))objc_msgSend)(configuration,
                                                  slowHapticVolumeSelector,
                                                  0);
    }

    generator = [[UISelectionFeedbackGenerator alloc] initWithConfiguration:configuration];
#if !__has_feature(objc_arc)
    [configuration release];
#endif
}

-(void)prepare{
    [generator prepare];
}

-(void)selectionChanged{
    [generator selectionChanged];
}

@end

NSArray<NSArray<POQuickSwitchEntry *> *> *POQuickSwitchBuildPages(
    NSArray<NSString *> *bundleIdentifiers,
    NSUInteger slotCount
) {
    if (bundleIdentifiers.count == 0 || slotCount == 0) {
        return @[];
    }

    NSMutableArray<POQuickSwitchEntry *> *applicationEntries =
        [NSMutableArray arrayWithCapacity:bundleIdentifiers.count];
    for (NSString *bundleIdentifier in bundleIdentifiers) {
        [applicationEntries addObject:
            [POQuickSwitchEntry applicationEntryWithBundleIdentifier:bundleIdentifier]];
    }
    if (applicationEntries.count <= slotCount) {
        return @[[applicationEntries copy]];
    }
    if (slotCount < 3) {
        return @[];
    }

    NSMutableArray<NSArray<POQuickSwitchEntry *> *> *result = [NSMutableArray array];
    NSUInteger cursor = 0;
    NSUInteger firstPageCount = slotCount - 1;
    NSMutableArray<POQuickSwitchEntry *> *firstPage = [NSMutableArray arrayWithCapacity:slotCount];
    [firstPage addObjectsFromArray:
        [applicationEntries subarrayWithRange:NSMakeRange(cursor, firstPageCount)]];
    cursor += firstPageCount;
    [firstPage addObject:[POQuickSwitchEntry nextPageEntry]];
    [result addObject:firstPage];

    while (applicationEntries.count - cursor > slotCount - 1) {
        NSMutableArray<POQuickSwitchEntry *> *middlePage = [NSMutableArray arrayWithCapacity:slotCount];
        [middlePage addObject:[POQuickSwitchEntry previousPageEntry]];
        NSUInteger middlePageCount = slotCount - 2;
        [middlePage addObjectsFromArray:
            [applicationEntries subarrayWithRange:NSMakeRange(cursor, middlePageCount)]];
        cursor += middlePageCount;
        [middlePage addObject:[POQuickSwitchEntry nextPageEntry]];
        [result addObject:middlePage];
    }

    NSMutableArray<POQuickSwitchEntry *> *lastPage = [NSMutableArray arrayWithCapacity:slotCount];
    [lastPage addObject:[POQuickSwitchEntry previousPageEntry]];
    [lastPage addObjectsFromArray:
        [applicationEntries subarrayWithRange:NSMakeRange(cursor, applicationEntries.count - cursor)]];
    [result addObject:lastPage];
    return result;
}

@interface QuickSwitchTableView () {
    NSDictionary *settings;
    NSArray<NSString *> *allBundleIdentifiers;
    NSArray<NSArray<POQuickSwitchEntry *> *> *pages;
    NSArray<POQuickSwitchEntry *> *items;

    NSIndexPath *lastHoveredIndexPath;
    UITableViewCell *lastCellToAnimate;
    UITableViewCell *thisCellToAnimate;
    SBApplication *draggingApp;
    BOOL isPresenting;
    BOOL pageTransitionInProgress;
    NSUInteger presentationGeneration;
    NSUInteger navigationDwellGeneration;
    NSUInteger slotCount;
    NSUInteger currentPageIndex;
    CGFloat presentingHandleHeight;
    NSInteger latchedNavigationRow;
    NSInteger pendingNavigationRow;
    POQuickSwitchEntryKind pendingNavigationKind;
    CGPoint lastGesturePoint;
    BOOL hasLastGesturePoint;
    UIView *pageTransitionSnapshot;
    __weak UIView *presentationCoordinateView;
    CGRect presentingHandleFrame;
    CGPoint presentingHandleCenterInCoordinateView;

    UIImpactFeedbackGenerator *impactGenerator;
    POQuickSwitchSelectionFeedback *selectionFeedback;
}

@end

@implementation QuickSwitchTableView

-(instancetype)init{
    if (self = [super init]) {
        [self registerClass:[QuickSwitchTableViewCell class] forCellReuseIdentifier:@"QuickSwitchCell"];
        self.alpha = 0;
        self.clipsToBounds = NO;
        self.scrollEnabled = NO;
        self.bounces = NO;
        self.alwaysBounceVertical = NO;
        self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        self.contentInset = UIEdgeInsetsZero;
        self.scrollIndicatorInsets = UIEdgeInsetsZero;
        self.rowHeight = QS_ROW_HEIGHT;
        self.estimatedRowHeight = QS_ROW_HEIGHT;
        self.sectionHeaderHeight = 0;
        self.sectionFooterHeight = 0;
        self.estimatedSectionHeaderHeight = 0;
        self.estimatedSectionFooterHeight = 0;
        self.separatorStyle = UITableViewCellSeparatorStyleNone;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.30;
        self.layer.shadowRadius = 3.5;
        self.layer.shadowOffset = CGSizeZero;
        self.separatorColor = [UIColor clearColor];

        self.delegate = self;
        self.dataSource = self;

        UIBlurEffect *menuBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        UIVisualEffectView *menuBackground = [[UIVisualEffectView alloc] initWithEffect:menuBlur];
        menuBackground.layer.masksToBounds = YES;
        menuBackground.layer.cornerRadius = QS_CORNER_RADIUS;
        menuBackground.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundView = menuBackground;
        self.backgroundColor = [UIColor clearColor];

        UIView *tableHeader = [[UIView alloc] initWithFrame:CGRectMake(0,
                                                                          0,
                                                                          QS_LIST_WIDTH,
                                                                          POQuickSwitchMenuEdgePadding)];
        tableHeader.backgroundColor = UIColor.clearColor;
        self.tableHeaderView = tableHeader;
        UIView *tableFooter = [[UIView alloc] initWithFrame:CGRectMake(0,
                                                                          0,
                                                                          QS_LIST_WIDTH,
                                                                          POQuickSwitchMenuEdgePadding)];
        tableFooter.backgroundColor = UIColor.clearColor;
        self.tableFooterView = tableFooter;

        impactGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        selectionFeedback = [[POQuickSwitchSelectionFeedback alloc] init];
        presentingHandleHeight = 34.0;
        latchedNavigationRow = -1;
        pendingNavigationRow = -1;
        pages = @[];
        items = @[];

        [self refresh];
    }
    return self;
}

-(void)refresh{
    settings = [POApplicationHelper settings];
    [selectionFeedback configureWithHapticsEnabled:[settings[@"hapticFeedback"] boolValue]
                                      soundEnabled:[settings[@"soundFeedback"] boolValue]];
    allBundleIdentifiers = [POApplicationHelper quickSwitchBundleIdentifiers];
    pages = @[];
    items = @[];
    [self reloadData];
}

-(CGAffineTransform)iconLayoutTransform{
    return [[POApplicationHelper settings][@"leftHanded"] boolValue]
        ? CGAffineTransformMakeScale(-1.0, 1.0)
        : CGAffineTransformIdentity;
}

-(void)refreshLayoutDirection{
    CGAffineTransform iconTransform = [self iconLayoutTransform];
    for (UITableViewCell *cell in self.visibleCells) {
        if ([cell isKindOfClass:[QuickSwitchTableViewCell class]]) {
            ((QuickSwitchTableViewCell *)cell).imgView.transform = iconTransform;
        }
    }
}

-(POQuickSwitchEntry *)entryAtIndexPath:(NSIndexPath *)indexPath{
    if (!indexPath || indexPath.row < 0 || indexPath.row >= (NSInteger)items.count) {
        return nil;
    }
    return items[(NSUInteger)indexPath.row];
}

-(UIImage *)imageForEntry:(POQuickSwitchEntry *)entry{
    if (entry.kind == POQuickSwitchEntryKindApplication) {
        return [POApplicationHelper imageForBundleId:entry.bundleIdentifier];
    }
    NSString *symbolName = entry.kind == POQuickSwitchEntryKindPreviousPage
        ? @"chevron.up.circle"
        : @"chevron.down.circle";
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:POQuickSwitchIconSize
                                                        weight:UIImageSymbolWeightRegular];
    return [UIImage systemImageNamed:symbolName withConfiguration:configuration];
}

-(NSUInteger)visibleSlotCountForPageIndex:(NSUInteger)pageIndex{
    return pageIndex < pages.count ? pages[pageIndex].count : 0;
}

-(CGRect)menuFrameForPageIndex:(NSUInteger)pageIndex{
    UIView *hostView = self.superview;
    UIView *coordinateView = presentationCoordinateView ?: self.window ?: hostView.superview ?: hostView;
    NSUInteger pageSlotCount = [self visibleSlotCountForPageIndex:pageIndex];
    CGFloat height = QS_ROW_HEIGHT * pageSlotCount + POQuickSwitchMenuEdgePadding * 2.0;
    CGFloat listX = CGRectGetMaxX(presentingHandleFrame) - QS_LIST_WIDTH;
    CGPoint handleCenter = [coordinateView convertPoint:presentingHandleCenterInCoordinateView
                                                   toView:hostView];
    CGRect menuFrame = CGRectMake(listX,
                                  handleCenter.y - height / 2.0,
                                  QS_LIST_WIDTH,
                                  height);

    CGRect menuFrameInCoordinateView = [hostView convertRect:menuFrame toView:coordinateView];
    CGRect allowedFrame = UIEdgeInsetsInsetRect(coordinateView.bounds,
                                                UIEdgeInsetsMake(QS_VERTICAL_SCREEN_EDGE_MARGIN,
                                                                 QS_HORIZONTAL_SCREEN_EDGE_MARGIN,
                                                                 QS_VERTICAL_SCREEN_EDGE_MARGIN,
                                                                 QS_HORIZONTAL_SCREEN_EDGE_MARGIN));
    CGFloat horizontalAdjustment = 0;
    CGFloat verticalAdjustment = 0;
    if (CGRectGetMinX(menuFrameInCoordinateView) < CGRectGetMinX(allowedFrame)) {
        horizontalAdjustment = CGRectGetMinX(allowedFrame) - CGRectGetMinX(menuFrameInCoordinateView);
    } else if (CGRectGetMaxX(menuFrameInCoordinateView) > CGRectGetMaxX(allowedFrame)) {
        horizontalAdjustment = CGRectGetMaxX(allowedFrame) - CGRectGetMaxX(menuFrameInCoordinateView);
    }
    if (CGRectGetMinY(menuFrameInCoordinateView) < CGRectGetMinY(allowedFrame)) {
        verticalAdjustment = CGRectGetMinY(allowedFrame) - CGRectGetMinY(menuFrameInCoordinateView);
    } else if (CGRectGetMaxY(menuFrameInCoordinateView) > CGRectGetMaxY(allowedFrame)) {
        verticalAdjustment = CGRectGetMaxY(allowedFrame) - CGRectGetMaxY(menuFrameInCoordinateView);
    }
    if (horizontalAdjustment != 0 || verticalAdjustment != 0) {
        CGPoint adjustedOrigin = CGPointMake(CGRectGetMinX(menuFrameInCoordinateView) + horizontalAdjustment,
                                             CGRectGetMinY(menuFrameInCoordinateView) + verticalAdjustment);
        menuFrame.origin = [coordinateView convertPoint:adjustedOrigin toView:hostView];
    }
    return menuFrame;
}

-(void)updatePageVisualGeometry{
    self.backgroundView.frame = self.bounds;
    self.layer.cornerRadius = QS_CORNER_RADIUS;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.backgroundView.layer.cornerRadius = QS_CORNER_RADIUS;
    self.backgroundView.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                       cornerRadius:QS_CORNER_RADIUS].CGPath;
}

-(void)applyPageGeometryForPageIndex:(NSUInteger)pageIndex animated:(BOOL)animated{
    CGRect targetFrame = [self menuFrameForPageIndex:pageIndex];
    void (^changes)(void) = ^{
        self.frame = targetFrame;
        [self layoutIfNeeded];
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

-(void)cancelNavigationDwell{
    navigationDwellGeneration += 1;
    pendingNavigationRow = -1;
}

-(void)resetCellImmediately:(UITableViewCell *)cell{
    if (!cell) {
        return;
    }
    [cell.layer removeAllAnimations];
    cell.layer.zPosition = 0;
    cell.transform = CGAffineTransformIdentity;
    cell.alpha = 1;
    if ([cell isKindOfClass:[QuickSwitchTableViewCell class]]) {
        ((QuickSwitchTableViewCell *)cell).tileView.alpha = 0;
    }
}

-(void)setHoveredIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated{
    if ((!indexPath && !lastHoveredIndexPath) || [indexPath isEqual:lastHoveredIndexPath]) {
        return;
    }
    UITableViewCell *oldCell = [self cellForRowAtIndexPath:lastHoveredIndexPath];
    UITableViewCell *newCell = [self cellForRowAtIndexPath:indexPath];
    if (animated) {
        [self animateZoomforCellremove:oldCell];
        [self animateZoomforCell:newCell];
    } else {
        [self resetCellImmediately:oldCell];
        if (newCell) {
            newCell.layer.zPosition = 3;
            QuickSwitchTableViewCell *quickCell = (QuickSwitchTableViewCell *)newCell;
            quickCell.tileView.alpha = 1;
        }
    }
    lastCellToAnimate = oldCell;
    thisCellToAnimate = newCell;
    lastHoveredIndexPath = indexPath;
}

-(void)clearHoverAnimated:(BOOL)animated notifyDelegate:(BOOL)notifyDelegate{
    [self cancelNavigationDwell];
    [self setHoveredIndexPath:nil animated:animated];
    lastCellToAnimate = nil;
    thisCellToAnimate = nil;
    if (notifyDelegate) {
        [self.selectionDelegate quickSwitchTableViewDidClearHover:self];
    }
}

-(UIView *)snapshotOfVisibleCells{
    UIView *snapshot = [[UIView alloc] initWithFrame:self.bounds];
    snapshot.backgroundColor = UIColor.clearColor;
    snapshot.userInteractionEnabled = NO;
    snapshot.clipsToBounds = NO;
    for (UITableViewCell *cell in self.visibleCells) {
        UIView *cellSnapshot = [cell snapshotViewAfterScreenUpdates:NO];
        if (!cellSnapshot) {
            continue;
        }
        cellSnapshot.frame = [cell convertRect:cell.bounds toView:self];
        [snapshot addSubview:cellSnapshot];
    }
    return snapshot;
}

-(void)cancelPageTransition{
    pageTransitionInProgress = NO;
    [pageTransitionSnapshot.layer removeAllAnimations];
    [pageTransitionSnapshot removeFromSuperview];
    pageTransitionSnapshot = nil;
    for (UITableViewCell *cell in self.visibleCells) {
        [self resetCellImmediately:cell];
    }
}

-(void)finishPageTransitionForGeneration:(NSUInteger)generation{
    [pageTransitionSnapshot removeFromSuperview];
    pageTransitionSnapshot = nil;
    if (generation != presentationGeneration || !isPresenting) {
        return;
    }
    pageTransitionInProgress = NO;
    for (UITableViewCell *cell in self.visibleCells) {
        [self resetCellImmediately:cell];
    }
    if (hasLastGesturePoint) {
        [self updateInteractionForPoint:lastGesturePoint];
    }
}

-(void)turnPageForEntryKind:(POQuickSwitchEntryKind)kind triggeringRow:(NSInteger)row{
    NSInteger targetPage = kind == POQuickSwitchEntryKindNextPage
        ? (NSInteger)currentPageIndex + 1
        : (NSInteger)currentPageIndex - 1;
    if (pageTransitionInProgress || targetPage < 0 || targetPage >= (NSInteger)pages.count) {
        return;
    }

    [self cancelNavigationDwell];
    latchedNavigationRow = row;
    [self clearHoverAnimated:NO notifyDelegate:YES];
    draggingApp = nil;
    pageTransitionInProgress = YES;
    [selectionFeedback selectionChanged];
    [selectionFeedback prepare];

    pageTransitionSnapshot = [self snapshotOfVisibleCells];
    currentPageIndex = (NSUInteger)targetPage;
    items = pages[currentPageIndex];
    [self reloadData];
    [self layoutIfNeeded];
    hasLastGesturePoint = NO;
    [self applyPageGeometryForPageIndex:currentPageIndex animated:YES];

    CGFloat oldDirection = kind == POQuickSwitchEntryKindNextPage ? -1.0 : 1.0;
    for (UITableViewCell *cell in self.visibleCells) {
        cell.alpha = 0;
        cell.transform = CGAffineTransformMakeTranslation(0, -oldDirection * QS_PAGE_TRANSITION_DISTANCE);
    }
    [self addSubview:pageTransitionSnapshot];
    NSUInteger generation = presentationGeneration;
    UIView *oldSnapshot = pageTransitionSnapshot;
    [UIView animateWithDuration:QS_PAGE_TRANSITION_DURATION
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        oldSnapshot.alpha = 0;
        oldSnapshot.transform = CGAffineTransformMakeTranslation(0, oldDirection * QS_PAGE_TRANSITION_DISTANCE);
        for (UITableViewCell *cell in self.visibleCells) {
            cell.alpha = 1;
            cell.transform = CGAffineTransformIdentity;
        }
    } completion:^(BOOL finished) {
        [self finishPageTransitionForGeneration:generation];
    }];
}

-(void)schedulePageTurnForEntry:(POQuickSwitchEntry *)entry atRow:(NSInteger)row{
    [self cancelNavigationDwell];
    pendingNavigationKind = entry.kind;
    pendingNavigationRow = row;
    NSUInteger dwellGeneration = navigationDwellGeneration;
    NSUInteger menuGeneration = presentationGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(QS_PAGE_DWELL_DURATION * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSIndexPath *currentIndexPath = [self indexPathForRowAtPoint:self->lastGesturePoint];
        if (dwellGeneration != self->navigationDwellGeneration ||
            menuGeneration != self->presentationGeneration ||
            !self->isPresenting || self->pageTransitionInProgress ||
            self->pendingNavigationRow != row || !self->lastHoveredIndexPath ||
            self->lastHoveredIndexPath.row != row || !currentIndexPath ||
            currentIndexPath.row != row) {
            return;
        }
        POQuickSwitchEntry *currentEntry = [self entryAtIndexPath:currentIndexPath];
        if (!currentEntry || currentEntry.kind != self->pendingNavigationKind) {
            return;
        }
        [self turnPageForEntryKind:currentEntry.kind triggeringRow:row];
    });
}

-(void)updateInteractionForPoint:(CGPoint)point{
    lastGesturePoint = point;
    hasLastGesturePoint = YES;
    if (pageTransitionInProgress) {
        return;
    }

    NSIndexPath *indexPath = [self indexPathForRowAtPoint:point];
    POQuickSwitchEntry *entry = [self entryAtIndexPath:indexPath];
    NSInteger row = entry ? indexPath.row : -1;
    if (latchedNavigationRow >= 0) {
        if (row == latchedNavigationRow) {
            return;
        }
        latchedNavigationRow = -1;
    }

    CGRect dragExitBounds = CGRectInset(self.bounds, -10.0, -10.0);
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

    if (lastHoveredIndexPath && !CGRectContainsPoint(dragExitBounds, point)) {
        POQuickSwitchEntry *hoveredEntry = [self entryAtIndexPath:lastHoveredIndexPath];
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
        POQuickSwitchEntry *hoveredEntry = [self entryAtIndexPath:lastHoveredIndexPath];
        if (hoveredEntry && hoveredEntry.kind == POQuickSwitchEntryKindApplication) {
            return;
        }
        if (lastHoveredIndexPath) {
            [self clearHoverAnimated:YES notifyDelegate:YES];
        } else {
            [self cancelNavigationDwell];
        }
        return;
    }

    if (!entry) {
        if (lastHoveredIndexPath) {
            [self clearHoverAnimated:YES notifyDelegate:YES];
        } else {
            [self cancelNavigationDwell];
        }
        return;
    }
    if ([indexPath isEqual:lastHoveredIndexPath]) {
        return;
    }

    [self.selectionDelegate draggingDidEnterBoundsOfQuickSwitchTableView:self];
    [self cancelNavigationDwell];
    [self setHoveredIndexPath:indexPath animated:YES];
    draggingApp = nil;
    if (entry.kind == POQuickSwitchEntryKindApplication) {
        [selectionFeedback selectionChanged];
        [selectionFeedback prepare];
        [self.selectionDelegate quickSwitchTableView:self didHoverBundleId:entry.bundleIdentifier];
    } else {
        [self.selectionDelegate quickSwitchTableViewDidClearHover:self];
        [self schedulePageTurnForEntry:entry atRow:indexPath.row];
    }
}

-(void)resetPagingInteraction{
    [self cancelNavigationDwell];
    [self cancelPageTransition];
    latchedNavigationRow = -1;
    hasLastGesturePoint = NO;
}

-(BOOL)presentFromHandle:(UIView *)handle withRecognizer:(UILongPressGestureRecognizer *)recognizer{
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        presentationGeneration += 1;
        [self.layer removeAllAnimations];
        [self resetPagingInteraction];
        [self refresh];
        presentingHandleHeight = MAX(0, CGRectGetHeight(handle.bounds));
        if (allBundleIdentifiers.count == 0) {
            isPresenting = NO;
            return NO;
        }

        lastHoveredIndexPath = nil;
        draggingApp = nil;

        UIScrollView *hostScrollView = (UIScrollView *)self.superview;
        UIView *coordinateView = self.window ?: hostScrollView.superview ?: hostScrollView;
        presentationCoordinateView = coordinateView;
        presentingHandleFrame = handle.frame;
        CGRect handleFrameInCoordinateView = [handle convertRect:handle.bounds toView:coordinateView];
        presentingHandleCenterInCoordinateView = CGPointMake(CGRectGetMidX(handleFrameInCoordinateView),
                                                             CGRectGetMidY(handleFrameInCoordinateView));
        CGFloat verticalMargin = QS_VERTICAL_SCREEN_EDGE_MARGIN;
        CGFloat availableHeight = MAX(0, CGRectGetHeight(coordinateView.bounds) - verticalMargin * 2);
        NSUInteger screenSlotCount = (NSUInteger)floor(MAX(0,
            availableHeight - POQuickSwitchMenuEdgePadding * 2.0) / QS_ROW_HEIGHT);
        slotCount = screenSlotCount;
        pages = POQuickSwitchBuildPages(allBundleIdentifiers, slotCount);
        if (pages.count == 0) {
            isPresenting = NO;
            return NO;
        }

        currentPageIndex = 0;
        items = pages.firstObject;
        [self reloadData];
        if ([settings[@"hapticFeedback"] boolValue]) {
            [impactGenerator prepare];
            [impactGenerator impactOccurred];
        }
        [selectionFeedback prepare];
        [self setContentOffset:CGPointZero animated:NO];
        [self applyPageGeometryForPageIndex:currentPageIndex animated:NO];
        self.contentInset = UIEdgeInsetsZero;
        self.contentOffset = CGPointZero;
        isPresenting = YES;
        [self present];
        [self.selectionDelegate quickSwitchTableViewWillAppear:self];
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
    } else if (recognizer.state == UIGestureRecognizerStateEnded) {
        NSIndexPath *indexPath = [self indexPathForRowAtPoint:point];
        POQuickSwitchEntry *entry = [self entryAtIndexPath:indexPath];
        if (draggingApp) {
            [self.selectionDelegate quickSwitchTableView:self didDropApp:draggingApp atPoint:point];
        } else if (!pageTransitionInProgress && entry.kind == POQuickSwitchEntryKindApplication &&
                   [indexPath isEqual:lastHoveredIndexPath] &&
                   indexPath.row != latchedNavigationRow && CGRectContainsPoint(self.bounds, point)) {
            if ([settings[@"hapticFeedback"] boolValue]) {
                [impactGenerator impactOccurred];
            }
            [self.selectionDelegate quickSwitchTableView:self didSelectBundleId:entry.bundleIdentifier];
        }
        [self dismissImmediately];
    } else {
        [self.selectionDelegate draggingDidEnterBoundsOfQuickSwitchTableView:self];
        [self dismissImmediately];
    }
    return YES;
}

#pragma mark - TableView

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{
    return 1;
}

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    return (NSInteger)items.count;
}

-(CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath{
    return QS_ROW_HEIGHT;
}

-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{
    static NSString *CellIdentifier = @"QuickSwitchCell";
    QuickSwitchTableViewCell *cell = [self dequeueReusableCellWithIdentifier:CellIdentifier];
    if (!cell) {
        cell = [[QuickSwitchTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                               reuseIdentifier:CellIdentifier];
    }

    POQuickSwitchEntry *entry = [self entryAtIndexPath:indexPath];
    cell.imgView.image = entry ? [self imageForEntry:entry] : nil;
    cell.imgView.tintColor = entry && entry.kind == POQuickSwitchEntryKindApplication ? nil : UIColor.labelColor;
    cell.imgView.transform = [self iconLayoutTransform];
    cell.isAccessibilityElement = entry && entry.kind != POQuickSwitchEntryKindApplication;
    cell.accessibilityLabel = entry && entry.kind == POQuickSwitchEntryKindPreviousPage
        ? @"上一页"
        : (entry && entry.kind == POQuickSwitchEntryKindNextPage ? @"下一页" : nil);
    [self resetCellImmediately:cell];
    return cell;
}

#pragma mark - Animations

-(void)present{
    CGFloat fullHeight = self.bounds.size.height;
    CGFloat handleHeight = MIN(presentingHandleHeight, fullHeight);
    CGFloat startScaleY = fullHeight > handleHeight ? handleHeight / fullHeight : 1.0;

    self.transform = CGAffineTransformMakeScale(1.12, startScaleY);
    self.alpha = 0;
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
}

-(void)dismissImmediately{
    BOOL wasVisible = isPresenting || self.alpha > 0.01 || self.layer.animationKeys.count > 0;
    if (!wasVisible) {
        return;
    }

    presentationGeneration += 1;
    [self.layer removeAllAnimations];
    [self clearHoverAnimated:NO notifyDelegate:NO];
    [self resetPagingInteraction];
    self.alpha = 0;
    self.transform = CGAffineTransformIdentity;
    isPresenting = NO;
    draggingApp = nil;
    [self.selectionDelegate quickSwitchTableViewDidDisappear:self];
}

-(void)animateZoomforCell:(UITableViewCell *)zoomCell{
    if (!zoomCell) {
        return;
    }
    zoomCell.layer.zPosition = 3;

    CGFloat tileSize = 36.0;
    CGFloat desiredOffset = QS_LIST_WIDTH / 2.0 + tileSize / 2.0 + 5.0;
    UIView *coordinateView = self.window ?: self.superview.superview ?: self.superview;
    CGRect cellInCoordinate = [zoomCell convertRect:zoomCell.bounds toView:coordinateView];
    CGFloat midX = CGRectGetMidX(cellInCoordinate);
    CGFloat minCenterX = CGRectGetMinX(coordinateView.bounds) + tileSize / 2.0 + 1.0;
    CGFloat maxCenterX = CGRectGetMaxX(coordinateView.bounds) - tileSize / 2.0 - 1.0;
    CGFloat availableLeft = MAX(0, midX - minCenterX);
    CGFloat availableRight = MAX(0, maxCenterX - midX);

    CGFloat translationX = -MIN(desiredOffset, availableLeft);
    if (availableLeft < desiredOffset * 0.55 && availableRight > availableLeft) {
        translationX = MIN(desiredOffset, availableRight);
    }
    CGAffineTransform transform = fabs(translationX) > 0.5
        ? CGAffineTransformMakeTranslation(translationX, 0)
        : CGAffineTransformIdentity;

    QuickSwitchTableViewCell *cell = (QuickSwitchTableViewCell *)zoomCell;
    [UIView animateWithDuration:QS_HOVER_ANIMATION_DURATION
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        zoomCell.transform = transform;
        cell.tileView.alpha = 1;
    } completion:nil];
}

-(void)animateZoomforCellremove:(UITableViewCell *)zoomCell{
    if (!zoomCell) {
        return;
    }
    zoomCell.layer.zPosition = 2;
    QuickSwitchTableViewCell *cell = (QuickSwitchTableViewCell *)zoomCell;
    [UIView animateWithDuration:QS_HOVER_ANIMATION_DURATION
                          delay:0
                        options:(UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        zoomCell.transform = CGAffineTransformIdentity;
        cell.tileView.alpha = 0;
    } completion:nil];
}

@end
