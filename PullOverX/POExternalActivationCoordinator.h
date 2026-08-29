#import <Foundation/Foundation.h>

@interface POExternalActivationCoordinator : NSObject

+ (instancetype)sharedInstance;

- (id)prepareOpenApplicationRequestIfNeeded:(id)request completion:(id)completion;
- (id)prepareTrustedWorkspaceOpenApplication:(id)application
                                     options:(id)options
                                      origin:(id)origin
                                      result:(id)result
                                routedResult:(id __autoreleasing *)routedResult;
- (void)prepareNativeTakeoverForTransitionRequestIfNeeded:(id)transitionRequest;

@end
