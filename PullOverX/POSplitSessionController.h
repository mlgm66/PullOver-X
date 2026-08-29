#import <Foundation/Foundation.h>
#import "ContextInterfaces.h"

@interface POSplitSessionController : NSObject

@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, copy, readonly) NSString *baseBundleIdentifier;
@property (nonatomic, copy, readonly) NSString *baseSceneIdentifier;
@property (nonatomic, weak, readonly) id baseScene;
@property (nonatomic, readonly) BOOL baseSceneRequiresForegroundProtection;

+ (instancetype)sharedInstance;

- (void)beginWithBaseBundleIdentifier:(NSString *)bundleIdentifier scene:(id)scene;
- (void)updateBaseBundleIdentifier:(NSString *)bundleIdentifier scene:(id)scene;
- (void)end;
- (BOOL)matchesBaseScene:(id)scene;

@end
