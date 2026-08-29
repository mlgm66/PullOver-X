//
//  POPPath.h
//  PullOver X
//

#import <Foundation/Foundation.h>

#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
#import <roothide.h>
#elif defined(POP_PACKAGE_SCHEME_ROOTLESS)
#import <rootless.h>
#endif

NS_ASSUME_NONNULL_BEGIN

NS_INLINE NSString *POPPath(NSString *path) {
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    return jbroot(path);
#elif defined(POP_PACKAGE_SCHEME_ROOTLESS)
    return ROOT_PATH_NS(path);
#else
    return path;
#endif
}

NS_ASSUME_NONNULL_END
