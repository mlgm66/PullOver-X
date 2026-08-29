//
//  QuickSwitchHorizontalBarView.h
//  PullOverX
//

#import <UIKit/UIKit.h>
#import "QuickSwitchTableView.h"

@interface QuickSwitchHorizontalBarView : UIView <POQuickSwitchMenuPresenting>
@property (nonatomic, weak) id<QuickSwitchSelectionDelegate> selectionDelegate;
@property (nonatomic) CGRect presentationAnchorFrame;
+ (CGFloat)preferredBarHeight;
@end
