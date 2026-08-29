//
//  MHHandle.h
//  MessageHub
//
//  Created by Will Smillie on 1/18/19.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSUInteger, POHandleLayoutMode) {
    POHandleLayoutModeVerticalRail,
    POHandleLayoutModeLandscapeFixedBottomLeft,
};

@class POHandle;
@protocol POHandleDelegate <NSObject>
- (void)handle:(POHandle *)handle didReceiveTap:(UIGestureRecognizer*)recognizer;
- (void)handle:(POHandle *)handle didLongPress:(UIGestureRecognizer*)recognizer;
- (void)handle:(POHandle *)handle didPanPanel:(UIPanGestureRecognizer *)recognizer;
@end


@interface POHandle : UIView

@property (nonatomic, weak) id <POHandleDelegate> delegate;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic) BOOL isNubbed;
@property (nonatomic) CGFloat restingOriginX;
@property (nonatomic) POHandleLayoutMode layoutMode;

-(instancetype)initWithController:(id)controller;
-(void)refreshHandleSizeAnimated:(BOOL)animated;
-(void)refreshNubbedPositionAnimated:(BOOL)animated;


@end
