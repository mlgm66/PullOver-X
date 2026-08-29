#import "POSplitSessionController.h"

@interface POSplitSessionController ()
@property (nonatomic, readwrite, getter=isActive) BOOL active;
@property (nonatomic, copy, readwrite) NSString *baseBundleIdentifier;
@property (nonatomic, copy, readwrite) NSString *baseSceneIdentifier;
@property (nonatomic, weak, readwrite) id baseScene;
@property (nonatomic, readwrite) BOOL baseSceneRequiresForegroundProtection;
@end

@implementation POSplitSessionController

+ (instancetype)sharedInstance {
    static POSplitSessionController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [POSplitSessionController new];
    });
    return controller;
}

- (void)beginWithBaseBundleIdentifier:(NSString *)bundleIdentifier scene:(id)scene {
    if (bundleIdentifier.length == 0 || !scene) {
        return;
    }
    self.active = YES;
    [self updateBaseBundleIdentifier:bundleIdentifier scene:scene];
}

- (void)updateBaseBundleIdentifier:(NSString *)bundleIdentifier scene:(id)scene {
    if (!self.active || bundleIdentifier.length == 0 || !scene) {
        return;
    }
    self.baseBundleIdentifier = [bundleIdentifier copy];
    self.baseScene = scene;
    NSString *identifier = [scene respondsToSelector:@selector(identifier)] ? [scene identifier] : nil;
    if (identifier.length == 0 && [scene isKindOfClass:[UIWindowScene class]]) {
        identifier = ((UIWindowScene *)scene).session.persistentIdentifier;
    }
    self.baseSceneIdentifier = [identifier copy];
    self.baseSceneRequiresForegroundProtection =
        ![bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

- (void)end {
    self.active = NO;
    self.baseBundleIdentifier = nil;
    self.baseSceneIdentifier = nil;
    self.baseScene = nil;
    self.baseSceneRequiresForegroundProtection = NO;
}

- (BOOL)matchesBaseScene:(id)scene {
    if (!self.active || !scene) {
        return NO;
    }
    if (scene == self.baseScene) {
        return YES;
    }
    NSString *identifier = [scene respondsToSelector:@selector(identifier)] ? [scene identifier] : nil;
    if (identifier.length == 0 && [scene isKindOfClass:[UIWindowScene class]]) {
        identifier = ((UIWindowScene *)scene).session.persistentIdentifier;
    }
    return identifier.length > 0 && [identifier isEqualToString:self.baseSceneIdentifier];
}

@end
