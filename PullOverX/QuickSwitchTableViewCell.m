//
//  QuickSwitchTableViewCell.m
//  PullOverX
//
//  Created by Will Smillie on 4/8/19.
//

#import "QuickSwitchTableViewCell.h"
#import "POQuickSwitchMetrics.h"

@implementation QuickSwitchTableViewCell

-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier{
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        UIBlurEffect *tileBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        UIVisualEffectView *tile = [[UIVisualEffectView alloc] initWithEffect:tileBlur];
        tile.translatesAutoresizingMaskIntoConstraints = NO;
        tile.layer.cornerRadius = POQuickSwitchSelectionTileCornerRadius;
        tile.layer.cornerCurve = kCACornerCurveContinuous;
        tile.clipsToBounds = YES;
        tile.userInteractionEnabled = NO;
        tile.alpha = 0;
        self.tileView = tile;
        [self.contentView addSubview:self.tileView];

        self.imgView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.imgView.translatesAutoresizingMaskIntoConstraints = NO;
        self.imgView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:self.imgView];

        [NSLayoutConstraint activateConstraints:@[
            [tile.widthAnchor constraintEqualToConstant:POQuickSwitchSelectionTileSize],
            [tile.heightAnchor constraintEqualToConstant:POQuickSwitchSelectionTileSize],
            [tile.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [tile.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.imgView.widthAnchor constraintEqualToConstant:POQuickSwitchIconSize],
            [self.imgView.heightAnchor constraintEqualToConstant:POQuickSwitchIconSize],
            [self.imgView.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
            [self.imgView.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
        ]];
        
        self.backgroundColor = [UIColor clearColor];
        self.layoutMargins = UIEdgeInsetsZero;
        self.preservesSuperviewLayoutMargins = NO;
        self.contentView.layoutMargins = UIEdgeInsetsZero;
        self.contentView.preservesSuperviewLayoutMargins = NO;
        self.contentView.insetsLayoutMarginsFromSafeArea = NO;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

    }
    return self;
}

-(void)layoutSubviews{
    [super layoutSubviews];
    self.contentView.frame = self.bounds;
    [self.contentView layoutIfNeeded];
}

@end
