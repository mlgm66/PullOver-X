//
//  PullOverWindow.h
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "PullOverViewController.h"

@interface PullOverWindow : UIWindow

@property (nonatomic, strong) PullOverViewController *controller;
@property (nonatomic, assign, readonly) UIInterfaceOrientation pullOverInterfaceOrientation;

+ (id)sharedWindow;
- (void)requestLayoutFromCurrentScene;
- (BOOL)applyInterfaceOrientation:(UIInterfaceOrientation)orientation
                         duration:(NSTimeInterval)duration
                       completion:(void (^)(void))completion;

@end
