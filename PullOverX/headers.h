//
//  headers.h
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

@interface SpringBoard
-(id)_accessibilityFrontMostApplication;
@end


@interface SBApplication
@property NSString *bundleIdentifier;
@property NSString *displayIdentifier;
@property NSString *displayName;
- (id)mainScene;
@end

@interface SBApplicationController
+ (id)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bid;
- (SBApplication *)applicationWithDisplayIdentifier:(NSString *)identifier;
@end

@interface SBFluidSwitcherGestureManager
-(void)grabberTongueBeganPulling:(id)arg1 withDistance:(double)arg2 andVelocity:(double)arg3 ;
-(void)grabberTongueCanceledPulling:(id)arg1 withDistance:(double)arg2 andVelocity:(double)arg3 ;
@end

@class SBIcon;
@class SBIconModel;
@class SBHIconImageCache;

@interface SBIconModel : NSObject
- (SBIcon *)applicationIconForBundleIdentifier:(NSString *)identifier;
@end

@interface SBHIconImageCache : NSObject
- (UIImage *)imageForIcon:(SBIcon *)icon;
@end

@interface SBIconController : NSObject
+(id)sharedInstance;
@property (readonly, nonatomic) SBIconModel *iconModel;
@property (nonatomic, retain) SBIconModel *model;
@property (readonly, nonatomic) SBHIconImageCache *tableUIIconImageCache;
@end
