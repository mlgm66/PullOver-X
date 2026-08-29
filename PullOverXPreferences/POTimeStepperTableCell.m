#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSControlTableCell.h>
#import "../POLocalization.h"

@interface POTimeStepperTableCell : PSControlTableCell
@property (nonatomic, retain) UIStepper *control;
@end

@implementation POTimeStepperTableCell

@dynamic control;

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
	if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier]) {
		self.accessoryView = self.control;
        [self.detailTextLabel setHidden:YES];
	}
	return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
	[super refreshCellContentsWithSpecifier:specifier];
	self.control.frame = CGRectMake(0, 0, 96, 32);
	self.accessoryView = self.control;
	[self _updateLabel];
}

- (UIStepper *)newControl {
	UIStepper *stepper = [[UIStepper alloc] initWithFrame:CGRectMake(0, 0, 96, 32)];
	stepper.continuous = NO;
	stepper.value = 0;
	stepper.minimumValue = 0;
	stepper.maximumValue = 10;
	stepper.autoresizingMask = UIViewAutoresizingNone;
	return stepper;
}

- (NSNumber *)controlValue {
	return @(self.control.value);
}

- (void)setValue:(NSNumber *)value {
	[super setValue:value];
    self.control.value = value.doubleValue;
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
	NSString *pointStr = POLocalizedString(value == 1 ? @"Second" : @"Seconds", @"Tweak");
    NSString *valString = [NSString stringWithFormat:@"%i", value];
	NSString *format = POLocalizedString(@"Nub After %@ %@", @"Tweak");
    self.textLabel.text = [NSString stringWithFormat:format, valString, pointStr];

	[self setNeedsLayout];
}

@end
