//
//  QuickSwitchTableView.h
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import <UIKit/UIKit.h>

#import "POApplicationHelper.h"
#import "QuickSwitchTableViewCell.h"

@protocol QuickSwitchSelectionDelegate;

typedef NS_ENUM(NSUInteger, POQuickSwitchEntryKind) {
    POQuickSwitchEntryKindApplication,
    POQuickSwitchEntryKindPreviousPage,
    POQuickSwitchEntryKindNextPage,
};

@interface POQuickSwitchEntry : NSObject
@property (nonatomic, readonly) POQuickSwitchEntryKind kind;
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
+ (instancetype)applicationEntryWithBundleIdentifier:(NSString *)bundleIdentifier;
+ (instancetype)previousPageEntry;
+ (instancetype)nextPageEntry;
@end

FOUNDATION_EXPORT NSArray<NSArray<POQuickSwitchEntry *> *> *POQuickSwitchBuildPages(
    NSArray<NSString *> *bundleIdentifiers,
    NSUInteger applicationSlotLimit,
    NSUInteger screenSlotLimit
);

@interface POQuickSwitchSelectionFeedback : NSObject
-(void)configureWithHapticsEnabled:(BOOL)hapticsEnabled soundEnabled:(BOOL)soundEnabled;
-(void)prepare;
-(void)selectionChanged;
@end

@protocol POQuickSwitchMenuPresenting <NSObject>
@property (nonatomic, weak) id<QuickSwitchSelectionDelegate> selectionDelegate;
-(BOOL)presentFromHandle:(UIView *)handle withRecognizer:(UILongPressGestureRecognizer *)recognizer;
-(void)dismissImmediately;
-(void)refreshLayoutDirection;
@end

@protocol QuickSwitchSelectionDelegate <NSObject>
@required
-(void)quickSwitchTableViewWillAppear:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView;
-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView didHoverBundleId:(NSString *)bundleId;
-(void)quickSwitchTableViewDidClearHover:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView;
-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView didSelectBundleId:(NSString *)bundleId;
-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView draggingDidChangeForQuickSwitchItem:(id)item withPoint:(CGPoint)point;
-(void)quickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView didDropApp:(SBApplication *)app atPoint:(CGPoint)point;
-(void)draggingDidEnterBoundsOfQuickSwitchTableView:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView;
-(void)quickSwitchTableViewDidDisappear:(UIView<POQuickSwitchMenuPresenting> *)quickSwitchTableView;
@end

@interface QuickSwitchTableView : UITableView <UITableViewDelegate, UITableViewDataSource, POQuickSwitchMenuPresenting>
@property (nonatomic, weak) id<QuickSwitchSelectionDelegate> selectionDelegate;
@end
