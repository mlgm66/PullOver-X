//
//  PullOverViewController.h
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#import "BaseScrollView.h"
#import "POHandle.h"
#import "QuickSwitchTableView.h"
#import "ContextHostManager.h"

#import "headers.h"


@interface PullOverViewController : UIViewController <UIScrollViewDelegate, POHandleDelegate, QuickSwitchSelectionDelegate>

-(void)close;
-(void)forceCloseAndReleaseImmediately;
-(void)prepareForNativeApplicationTakeover:(NSString *)bundleId;
-(void)routeExternalApplicationInsidePullOver:(NSString *)bundleId;
-(BOOL)openExternallyActivatedApplicationInPullOver:(NSString *)bundleId;
-(void)applyCurrentSettings;
-(void)prepareForOrientationChange;
-(void)handleOrientationChange;
@property (nonatomic, readonly) BOOL isPanelActive;
@property (nonatomic, readonly) BOOL isPanelFullyOpen;
@property (nonatomic, readonly) BOOL isPanelTransitioning;

- (UIView *)interactiveViewForWindowPoint:(CGPoint)point event:(UIEvent *)event;

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIScrollView *handleScrollView;
@property (nonatomic, strong) POHandle *handle;
@property (nonatomic, strong) UIView *contentView;

@property (nonatomic, strong) QuickSwitchTableView *quickSwitchTableView;


@end
