#import <UIKit/UIKit.h>

#define PO_QUICKSWITCH_DROP_BORDER_WIDTH 1.5
#define PO_QUICKSWITCH_DROP_DASH_PATTERN @[@5.0, @3.0]

@interface POQuickSwitchDragCoordinator : NSObject

@property (nonatomic, readonly) BOOL isDragging;

- (instancetype)initWithOverlayView:(UIView *)overlayView;
- (void)layoutForBounds:(CGRect)bounds safeAreaInsets:(UIEdgeInsets)safeAreaInsets;
- (void)refreshLayoutDirection;
- (void)beginDraggingBundleId:(NSString *)bundleId
                   displayName:(NSString *)displayName
                    sourceView:(UIView *)sourceView
                    sourcePoint:(CGPoint)sourcePoint;
- (void)updateDraggingFromView:(UIView *)sourceView atPoint:(CGPoint)point;
- (BOOL)finishDraggingFromView:(UIView *)sourceView atPoint:(CGPoint)point;
- (void)cancelAnimated:(BOOL)animated;

@end
