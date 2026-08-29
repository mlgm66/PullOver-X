//
//  POApplicationHelper.h
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "headers.h"

@interface POApplicationHelper : NSObject

+ (NSArray<NSString *> *)recentAppsWithCount:(int)count;
+ (NSArray<NSString *> *)quickSwitchBundleIdentifiers;
+ (UIImage *)imageForBundleId:(NSString *)bundleId;
+ (NSString *)frontMostBundleId;
+ (BOOL)isUserFacingApplicationBundleId:(NSString *)bundleId;
+ (UIInterfaceOrientationMask)supportedInterfaceOrientationsForBundleId:(NSString *)bundleId;
+ (UIInterfaceOrientation)preferredHostedInterfaceOrientationForBundleId:(NSString *)bundleId;

+ (NSUserDefaults *)settingsDefaults;
+ (NSDictionary<NSString *, id> *)settings;
+ (void)reloadSettings;
+ (BOOL)isEnabled;
+ (BOOL)isExternalURLRoutingEnabled;
+ (BOOL)isExternalURLRoutingTargetBundleId:(NSString *)bundleId;

+ (UIImage *)iconImageForIdentifier:(NSString *)identifier;

@end
