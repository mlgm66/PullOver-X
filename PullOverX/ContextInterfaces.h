#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "headers.h"


@interface FBSceneLayerManager : NSObject
@property (nonatomic,readonly) NSOrderedSet * layers;
@end

@interface FBSceneHostManager : NSObject
-(id)hostViewForRequester:(id)arg1 enableAndOrderFront:(BOOL)arg2 ;
-(void)enableHostingForRequester:(id)arg1 orderFront:(BOOL)arg2 ;
-(void)disableHostingForRequester:(id)arg1 ;
@end

@interface _UIContextLayerHostView : UIView
-(id)initWithSceneLayer:(id)arg1 ;
@end

@interface _UIKeyboardLayerHostView : UIView
-(id)initWithKeyboardLayer:(id)arg1 owningScene:(id)arg2;
@end

@interface _UIExternalSceneLayerHostView : UIView
-(id)initWithSceneLayer:(id)arg1 parentScene:(id)arg2;
@end

@interface FBSceneLayer
-(NSString *)externalSceneID;
-(BOOL)isKeyboardLayer;
@end

@interface FBSMutableSceneSettings : NSObject
- (void)setBackgrounded:(bool)arg1;
@property (assign,getter=isForeground,nonatomic) BOOL foreground;
- (NSInteger)interfaceOrientation;
- (void)setInterfaceOrientation:(NSInteger)orientation;
- (void)setDeactivationReasons:(unsigned long long)arg1;
@end

@interface UIMutableApplicationSceneSettings : FBSMutableSceneSettings
- (void)setDisplayConfiguration:(id)configuration;
- (void)setFrame:(CGRect)frame;
- (void)setDeviceOrientationEventsEnabled:(BOOL)enabled;
@end

@interface UIMutableApplicationSceneClientSettings : NSObject
- (void)setInterfaceOrientation:(NSInteger)orientation;
@end

@interface FBSSceneClientIdentity : NSObject
+ (instancetype)identityForBundleID:(NSString *)bundleId;
@end

@interface FBSSceneIdentity : NSObject
+ (instancetype)identityForIdentifier:(NSString *)identifier;
@end

@interface UIApplicationSceneSpecification : NSObject
+ (instancetype)specification;
@end

@interface FBSMutableSceneDefinition : NSObject
+ (instancetype)definition;
- (void)setIdentity:(FBSSceneIdentity *)identity;
- (void)setClientIdentity:(FBSSceneClientIdentity *)identity;
- (void)setSpecification:(id)specification;
@end

@interface FBSMutableSceneParameters : NSObject
+ (instancetype)parametersForSpecification:(id)specification;
- (void)setSettings:(id)settings;
- (void)setClientSettings:(id)settings;
@end

@interface RBSProcessIdentity : NSObject
+ (instancetype)identityForEmbeddedApplicationIdentifier:(NSString *)identifier;
@end

@interface FBMutableProcessExecutionContext : NSObject
- (void)setIdentity:(RBSProcessIdentity *)identity;
@end

@interface FBProcessManager : NSObject
+ (instancetype)sharedInstance;
@end

@interface FBScene : NSObject
-(NSString *)identifier;
- (FBSceneHostManager *)hostManager;
- (FBSceneLayerManager *)layerManager;
- (id)settings;
- (id)mutableSettings;
-(void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 completion:(/*^block*/id)arg3 ;
-(void)updateSettings:(id)arg1 withTransitionContext:(id)arg2 ;
@end

@interface FBSceneManager
+(id)sharedInstance;
-(void)enumerateScenesWithBlock:(void (^)(id scene, BOOL *stop))arg1 ;
-(FBScene *)createSceneWithDefinition:(id)definition initialParameters:(id)parameters;
@end

@interface FBWindowContextHostView : UIView
- (BOOL)isHosting;
@end



@interface UIApplication (Private)
- (void)launchApplicationWithIdentifier: (NSString*)identifier suspended: (BOOL)suspended;
@end
