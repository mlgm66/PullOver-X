//
//  PullOverXPreferencesController.m
//  PullOverXPreferences
//
//  Created by Will Smillie on 4/9/19.
//  Copyright (c) 2019 ___ORGANIZATIONNAME___. All rights reserved.
//

#import "PullOverXPreferencesController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSControlTableCell.h>
#import <math.h>
#import "QSFavoritesPickerController.h"
#import "../POLocalization.h"

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsRestartRenderServer = 1 << 0,
    SBSRelaunchActionOptionsFadeToBlackTransition = 1 << 2
};

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason
                         options:(SBSRelaunchActionOptions)options
                       targetURL:(NSURL *)targetURL;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(void (^)(NSError *error))result;
@end


#define kPrefs_KeyName_Key @"key"
#define kPrefs_KeyName_Defaults @"defaults"

static NSString * const kPOSettingsChangedNotification = @"com.mlgm.pulloverx.settings-changed";
static NSString * const kPOEnabledPendingRespringKey = @"enabled-respring-pending";

#pragma mark - POValueSliderTableCell

@interface POValueSliderTableCell : PSControlTableCell {
    NSString *unit;
    CGFloat increment;
}
@property (nonatomic, retain) UISlider *control;
@property (nonatomic, retain) UILabel *valueLabel;
@property (nonatomic, retain) UIView *accessoryContainer;
@end

@implementation POValueSliderTableCell

@dynamic control;

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier
                     specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 225, 32)];
        self.control.frame = CGRectMake(0, 0, 165, 32);
        [accessory addSubview:self.control];

        self.valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(177, 0, 48, 32)];
        self.valueLabel.font = [UIFont systemFontOfSize:17];
        self.valueLabel.textColor = [UIColor labelColor];
        self.valueLabel.textAlignment = NSTextAlignmentRight;
        [accessory addSubview:self.valueLabel];
        self.accessoryContainer = accessory;
        self.accessoryView = accessory;
        self.detailTextLabel.hidden = YES;
    }
    return self;
}

- (UISlider *)newControl {
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 165, 31)];
    slider.continuous = YES;
    return slider;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    unit = [specifier propertyForKey:@"unit"] ?: @"";
    increment = MAX(0.01, [[specifier propertyForKey:@"increment"] doubleValue]);
    self.control.minimumValue = [[specifier propertyForKey:@"minimumValue"] doubleValue];
    self.control.maximumValue = [[specifier propertyForKey:@"maximumValue"] doubleValue];
    [super refreshCellContentsWithSpecifier:specifier];
    self.accessoryView = self.accessoryContainer;
    [self updateLabel];
}

- (NSNumber *)controlValue {
    return @(self.control.value);
}

- (void)setValue:(NSNumber *)value {
    [super setValue:value];
    self.control.value = value.doubleValue;
    [self updateLabel];
}

- (void)controlChanged:(UISlider *)slider {
    slider.value = round(slider.value / increment) * increment;
    [self updateLabel];
    [super controlChanged:self.control];
}

- (void)updateLabel {
    NSString *suffix = unit.length > 0 ? [NSString stringWithFormat:@"%@", unit] : @"";
    self.valueLabel.text = [NSString stringWithFormat:@"%.0f%@", self.control.value, suffix];
    [self setNeedsLayout];
}

@end

#pragma mark - POCompactSegmentTableCell

@interface POCompactSegmentTableCell : PSControlTableCell
@property (nonatomic, retain) UISegmentedControl *control;
@property (nonatomic, retain) NSArray<NSString *> *segmentValues;
@property (nonatomic, retain) NSArray<NSString *> *segmentTitles;
@end

@implementation POCompactSegmentTableCell

@dynamic control;

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier
                     specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.accessoryView = self.control;
        self.detailTextLabel.hidden = YES;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (UISegmentedControl *)newControl {
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[]];
    control.frame = CGRectMake(0, 0, 220, 32);
    [control addTarget:self action:@selector(controlChanged:) forControlEvents:UIControlEventValueChanged];
    return control;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    NSArray *titles = [specifier propertyForKey:@"validTitles"];
    NSArray *values = [specifier propertyForKey:@"validValues"];
    self.segmentTitles = [titles isKindOfClass:[NSArray class]] ? titles : @[];
    self.segmentValues = [values isKindOfClass:[NSArray class]] ? values : @[];

    [self.control removeAllSegments];
    [self.segmentTitles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
        if ([title isKindOfClass:[NSString class]]) {
            [self.control insertSegmentWithTitle:title atIndex:index animated:NO];
        }
    }];
    [super refreshCellContentsWithSpecifier:specifier];
    self.textLabel.text = [specifier propertyForKey:@"label"] ?: @"";
}

- (id)controlValue {
    NSInteger index = self.control.selectedSegmentIndex;
    if (index < 0 || index >= (NSInteger)self.segmentValues.count) {
        return nil;
    }
    return self.segmentValues[index];
}

- (void)setValue:(id)value {
    [super setValue:value];
    NSInteger index = [self.segmentValues indexOfObject:value];
    self.control.selectedSegmentIndex = index == NSNotFound ? 0 : index;
}

- (void)controlChanged:(UISegmentedControl *)control {
    [super controlChanged:control];
}

@end

#pragma mark - POHeaderCell

@interface POHeaderCell : PSTableCell
@end

@implementation POHeaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.backgroundColor = [UIColor clearColor];
        self.backgroundColor = [UIColor clearColor];
        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;

        UIImage *icon = [UIImage imageNamed:@"PullOverXPreferencesIcon" inBundle:bundle compatibleWithTraitCollection:nil];
        UIImageView *iconImageView = [[UIImageView alloc] initWithImage:icon];
        iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:iconImageView];

        NSString *titleKey = [specifier propertyForKey:@"headerTitle"] ?: [specifier propertyForKey:@"label"];
        NSString *title = POLocalizedString(titleKey ?: @"", @"PullOverXPreferences");
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = title;
        titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
        titleLabel.textColor = [UIColor labelColor];
        titleLabel.adjustsFontSizeToFitWidth = YES;
        titleLabel.minimumScaleFactor = 0.82;
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:titleLabel];

        NSString *subtitleKey = [specifier propertyForKey:@"headerSubtitle"] ?: [specifier propertyForKey:@"subtitle"];
        NSString *subtitle = POLocalizedString(subtitleKey ?: @"", @"PullOverXPreferences");
        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.text = subtitle;
        subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        subtitleLabel.textColor = [UIColor secondaryLabelColor];
        subtitleLabel.numberOfLines = 2;
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:subtitleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [iconImageView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [iconImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [iconImageView.widthAnchor constraintEqualToConstant:46],
            [iconImageView.heightAnchor constraintEqualToConstant:46],

            [titleLabel.leadingAnchor constraintEqualToAnchor:iconImageView.trailingAnchor constant:13],
            [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:margins.trailingAnchor],
            [titleLabel.topAnchor constraintEqualToAnchor:iconImageView.topAnchor constant:1],

            [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
            [subtitleLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
            [subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:iconImageView.bottomAnchor constant:-1]
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
}

@end

#pragma mark - POLinkCell

@interface POLinkCell : PSTableCell {
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIImageView *_indicatorImageView;
    NSString *_linkURL;
}
@end

@implementation POLinkCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        NSString *title = POLocalizedString([specifier propertyForKey:@"label"] ?: @"", @"PullOverXPreferences");
        NSString *subtitle = POLocalizedString([specifier propertyForKey:@"subtitle"] ?: @"", @"PullOverXPreferences");
        _linkURL = [specifier propertyForKey:@"url"];

        self.selectionStyle = UITableViewCellSelectionStyleNone;

        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;

        _indicatorImageView = [[UIImageView alloc] init];
        _indicatorImageView.image = [UIImage systemImageNamed:@"safari"];
        _indicatorImageView.tintColor = [UIColor tertiaryLabelColor];
        _indicatorImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_indicatorImageView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor systemBlueColor];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.text = subtitle;
        _subtitleLabel.font = [UIFont systemFontOfSize:12];
        _subtitleLabel.textColor = [[UIColor labelColor] colorWithAlphaComponent:0.6];
        _subtitleLabel.hidden = subtitle.length == 0;
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_subtitleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_indicatorImageView.widthAnchor constraintEqualToConstant:20],
            [_indicatorImageView.heightAnchor constraintEqualToConstant:20],
            [_indicatorImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_indicatorImageView.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_indicatorImageView.leadingAnchor constant:-16]
        ]];

        if (subtitle.length > 0) {
            [NSLayoutConstraint activateConstraints:@[
                [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:-9],
                [_subtitleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:10],
                [_subtitleLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_indicatorImageView.leadingAnchor constant:-16]
            ]];
        } else {
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor].active = YES;
        }

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openLink)];
        [self.contentView addGestureRecognizer:tap];
    }
    return self;
}

- (void)openLink {
    if (_linkURL.length > 0) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:_linkURL] options:@{} completionHandler:nil];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
}

@end

#pragma mark - POProfileLinkCell

@interface POProfileLinkCell : PSTableCell {
    UIImageView *_avatarImageView;
    UILabel *_titleLabel;
    UIImageView *_indicatorImageView;
    NSString *_linkURL;
}
@end

@implementation POProfileLinkCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        NSString *title = POLocalizedString([specifier propertyForKey:@"label"] ?: @"", @"PullOverXPreferences");
        NSString *iconName = [specifier propertyForKey:@"icon"];
        _linkURL = [specifier propertyForKey:@"url"];

        self.selectionStyle = UITableViewCellSelectionStyleNone;

        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSString *resourceName = [iconName stringByDeletingPathExtension];
        UIImage *avatar = [UIImage imageNamed:resourceName inBundle:bundle compatibleWithTraitCollection:nil];
        if (!avatar) {
            avatar = [UIImage imageNamed:iconName inBundle:bundle compatibleWithTraitCollection:nil];
        }

        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;

        _avatarImageView = [[UIImageView alloc] initWithImage:avatar];
        _avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
        _avatarImageView.clipsToBounds = YES;
        _avatarImageView.layer.masksToBounds = YES;
        _avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_avatarImageView];

        _indicatorImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"safari"]];
        _indicatorImageView.tintColor = [UIColor tertiaryLabelColor];
        _indicatorImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_indicatorImageView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor systemBlueColor];
        _titleLabel.numberOfLines = 1;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.78;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_avatarImageView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_avatarImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_avatarImageView.widthAnchor constraintEqualToConstant:30],
            [_avatarImageView.heightAnchor constraintEqualToConstant:30],

            [_indicatorImageView.widthAnchor constraintEqualToConstant:20],
            [_indicatorImageView.heightAnchor constraintEqualToConstant:20],
            [_indicatorImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_indicatorImageView.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_avatarImageView.trailingAnchor constant:12],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_indicatorImageView.leadingAnchor constant:-16]
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openLink)];
        [self.contentView addGestureRecognizer:tap];
    }
    return self;
}

- (void)openLink {
    if (_linkURL.length > 0) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:_linkURL] options:@{} completionHandler:nil];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    self.imageView.hidden = YES;
    _avatarImageView.layer.cornerRadius = CGRectGetHeight(_avatarImageView.bounds) * 0.5;
}

@end

@implementation PullOverXPreferencesController

-(void)viewDidLoad{
    [super viewDidLoad];

    UIBarButtonItem* respringButton = [[UIBarButtonItem alloc] initWithTitle:POLocalizedString(@"Respring", @"PullOverXPreferences") style:UIBarButtonItemStylePlain target:self action:@selector(confirmRespring:)];
    self.navigationItem.rightBarButtonItem = respringButton;
}

-(IBAction)confirmRespring:(id)sender{
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:POLocalizedString(@"Alert", @"PullOverXPreferences") message:POLocalizedString(@"Are you sure you want to respring?", @"PullOverXPreferences") preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:POLocalizedString(@"Cancel", @"PullOverXPreferences") style:UIAlertActionStyleCancel handler:nil];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:POLocalizedString(@"Respring", @"PullOverXPreferences") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        [self respring];
    }];
    [alertController addAction:cancelAction];
    [alertController addAction:okAction];
    
    [self presentViewController:alertController animated:YES completion:nil];
}

-(void)respring{
    Class actionClass = NSClassFromString(@"SBSRelaunchAction");
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    if (![actionClass respondsToSelector:@selector(actionWithReason:options:targetURL:)] ||
        ![serviceClass respondsToSelector:@selector(sharedService)]) {
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SBSRelaunchActionOptions options = SBSRelaunchActionOptionsRestartRenderServer |
                                           SBSRelaunchActionOptionsFadeToBlackTransition;
        SBSRelaunchAction *action = [(id)actionClass actionWithReason:@"PullOverX" options:options targetURL:nil];
        FBSSystemService *service = [(id)serviceClass sharedService];
        if (action && [service respondsToSelector:@selector(sendActions:withResult:)]) {
            [service sendActions:[NSSet setWithObject:action] withResult:nil];
        }
    });
}

- (void)presentRespringRequiredAlert {
    UIAlertController *alertController = [UIAlertController
        alertControllerWithTitle:POLocalizedString(@"Requires SpringBoard Restart", @"PullOverXPreferences")
        message:POLocalizedString(@"This option requires restarting SpringBoard to take effect. Restart now?", @"PullOverXPreferences")
        preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *laterAction = [UIAlertAction actionWithTitle:POLocalizedString(@"Later", @"PullOverXPreferences")
                                                            style:UIAlertActionStyleCancel
                                                          handler:nil];
    UIAlertAction *restartAction = [UIAlertAction actionWithTitle:POLocalizedString(@"Restart Now", @"PullOverXPreferences")
                                                              style:UIAlertActionStyleDestructive
                                                            handler:^(__unused UIAlertAction *action) {
        [self respring];
    }];
    [alertController addAction:laterAction];
    [alertController addAction:restartAction];
    [self presentViewController:alertController animated:YES completion:nil];
}


- (id)getValueForSpecifier:(PSSpecifier*)specifier
{
    NSDictionary *properties = specifier.properties;
    NSString *key = properties[kPrefs_KeyName_Key];
    NSString *suiteName = properties[kPrefs_KeyName_Defaults];
    if (key.length == 0 || suiteName.length == 0) {
        return nil;
    }

    id value = [[self userDefaultsForSuite:suiteName] objectForKey:key];
    return value ?: properties[@"default"];
}

- (void)setValue:(id)value forSpecifier:(PSSpecifier*)specifier
{
    NSDictionary *properties = specifier.properties;
    NSString *key = properties[kPrefs_KeyName_Key];
    NSString *suiteName = properties[kPrefs_KeyName_Defaults];
    if (key.length == 0 || suiteName.length == 0) {
        return;
    }

    NSUserDefaults *defaults = [self userDefaultsForSuite:suiteName];
    if (value) {
        [defaults setObject:value forKey:key];
    } else {
        [defaults removeObjectForKey:key];
    }
    [defaults synchronize];

    if ([properties[@"requiresRespring"] boolValue]) {
        [defaults setBool:YES forKey:kPOEnabledPendingRespringKey];
        [defaults synchronize];
        [POApplicationHelper reloadSettings];
        [self presentRespringRequiredAlert];
        return;
    }

    [POApplicationHelper reloadSettings];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kPOSettingsChangedNotification,
                                         NULL,
                                         NULL,
                                         true);

}

- (NSUserDefaults *)userDefaultsForSuite:(NSString *)suiteName
{
	return [[NSUserDefaults alloc] initWithSuiteName:suiteName];
}


- (id)specifiers
{
	if (_specifiers == nil) {
		_specifiers = [self loadSpecifiersFromPlistName:@"PullOverXPreferences" target:self];
		self.title = POLocalizedString(@"PullOver X", @"PullOverXPreferences");

        for (PSSpecifier *specifier in _specifiers) {
            NSString *label = [specifier propertyForKey:@"label"];
            if (label.length > 0) {
                [specifier setProperty:POLocalizedString(label, @"PullOverXPreferences") forKey:@"label"];
            }
			NSString *footer = [specifier propertyForKey:@"footerText"];
            if (footer.length > 0) {
                [specifier setProperty:POLocalizedString(footer, @"PullOverXPreferences") forKey:@"footerText"];
            }

            NSString *key = [specifier propertyForKey:@"key"];
            if ([key isEqualToString:@"style"]) {
                [specifier setProperty:@[
                    POLocalizedString(@"Recently Used", @"PullOverXPreferences"),
                    POLocalizedString(@"Favorite Apps", @"PullOverXPreferences")
                ] forKey:@"validTitles"];
                [specifier setProperty:@[@"Recent Apps", @"Favorite Apps"] forKey:@"validValues"];
            } else if ([key isEqualToString:@"landscapeBehavior"]) {
                [specifier setProperty:@[
                    POLocalizedString(@"Rotate", @"PullOverXPreferences"),
                    POLocalizedString(@"Lock", @"PullOverXPreferences"),
                    POLocalizedString(@"Hide", @"PullOverXPreferences")
                ] forKey:@"validTitles"];
                [specifier setProperty:@[@"rotate", @"lock", @"hide"] forKey:@"validValues"];
            }
        }
	}
    
    return _specifiers;
}

-(void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *identifier = [specifier propertyForKey:@"id"];
    if ([identifier isEqualToString:@"favoriteApps"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self selectFavorites:specifier];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

-(void)selectFavorites:(PSSpecifier *)specifier{
    QSFavoritesPickerController *c = [[QSFavoritesPickerController alloc] init];
    [self.navigationController pushViewController:c animated:YES];
}

@end
