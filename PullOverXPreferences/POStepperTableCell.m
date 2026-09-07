#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSControlTableCell.h>
#import "../POLocalization.h"

@interface POStepperTableCell : PSControlTableCell
@property (nonatomic, retain) UIStepper *control;
@property (nonatomic, copy) NSString *singularLabelFormat;
@property (nonatomic, copy) NSString *pluralLabelFormat;
@end

@implementation POStepperTableCell

@dynamic control;

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
	if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier]) {
		self.accessoryView = self.control;
        [self.detailTextLabel setHidden:YES];
	}
	return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
	NSNumber *minimumValue = [specifier propertyForKey:@"minimumValue"];
	NSNumber *maximumValue = [specifier propertyForKey:@"maximumValue"];
	NSNumber *stepValue = [specifier propertyForKey:@"stepValue"];
	self.control.minimumValue = minimumValue ? minimumValue.doubleValue : 1;
	self.control.maximumValue = maximumValue ? maximumValue.doubleValue : 99;
	self.control.stepValue = stepValue ? stepValue.doubleValue : 1;
	self.singularLabelFormat = [specifier propertyForKey:@"singularLabelFormat"];
	self.pluralLabelFormat = [specifier propertyForKey:@"pluralLabelFormat"]
		?: [specifier propertyForKey:@"labelFormat"];
	[super refreshCellContentsWithSpecifier:specifier];
	self.control.frame = CGRectMake(0, 0, 96, 32);
	self.accessoryView = self.control;
	[self _updateLabel];
}

- (UIStepper *)newControl {
	UIStepper *stepper = [[UIStepper alloc] initWithFrame:CGRectMake(0, 0, 96, 32)];
	stepper.continuous = NO;
	stepper.value = 1;
	stepper.minimumValue = 1;
	stepper.maximumValue = 99;
	stepper.autoresizingMask = UIViewAutoresizingNone;
	return stepper;
}

- (NSNumber *)controlValue {
	return @(self.control.value);
}

- (void)setValue:(NSNumber *)value {
	[super setValue:value];
	self.control.value = value.doubleValue;
	[self _updateLabel];
}

- (void)controlChanged:(UIStepper *)stepper {
	[super controlChanged:stepper];
	[self _updateLabel];
}

- (void)_updateLabel {
	if (!self.control) {
		return;
	}

	int value = (int)self.control.value;
	NSString *key = value == 1 && self.singularLabelFormat.length > 0
		? self.singularLabelFormat
		: self.pluralLabelFormat;
	if (key.length == 0) {
		key = @"%d";
	}
	NSString *format = POLocalizedString(key, @"Tweak");
	self.textLabel.text = [NSString stringWithFormat:format, value];

	[self setNeedsLayout];
}

@end
