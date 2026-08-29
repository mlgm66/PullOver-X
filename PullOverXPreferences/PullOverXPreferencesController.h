//
//  PullOverXPreferencesController.h
//  PullOverXPreferences
//
//  Created by Will Smillie on 4/9/19.
//  Copyright (c) 2019 ___ORGANIZATIONNAME___. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import "POApplicationHelper.h"

@interface PullOverXPreferencesController : PSListController

- (id)getValueForSpecifier:(PSSpecifier*)specifier;
- (void)setValue:(id)value forSpecifier:(PSSpecifier*)specifier;

@end
