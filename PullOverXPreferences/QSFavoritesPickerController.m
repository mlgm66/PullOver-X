//
//  QSFavoritesPickerController.m
//  PullOverXPreferences
//
//  Created by Will Smillie on 11/12/18.
//

#import "QSFavoritesPickerController.h"
#import "../POLocalization.h"

typedef NS_ENUM(NSInteger, QSSection) {
    QSSectionSelected = 0,
    QSSectionUser     = 1,
    QSSectionSystem   = 2,
    QSSectionCount    = 3
};

@interface LSApplicationRecord : NSObject
@property (nonatomic, readonly) NSArray *appTags;
@property (getter=isLaunchProhibited, readonly) BOOL launchProhibited;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly) NSArray *appTags;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (getter=isLaunchProhibited, nonatomic, readonly) BOOL launchProhibited;
- (LSApplicationRecord *)correspondingApplicationRecord;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

@interface UIImage (POPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

static BOOL POTagArrayContainsHidden(NSArray *tags) {
    if (![tags isKindOfClass:[NSArray class]]) {
        return NO;
    }
    for (id tag in tags) {
        if ([tag isKindOfClass:[NSString class]] &&
            [(NSString *)tag rangeOfString:@"hidden" options:0].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static BOOL POApplicationProxyIsHidden(LSApplicationProxy *proxy) {
    NSArray *appTags = nil;
    NSArray *recordAppTags = nil;
    NSArray *sbAppTags = nil;
    BOOL launchProhibited = NO;

    @try {
        if ([proxy respondsToSelector:@selector(correspondingApplicationRecord)]) {
            id record = [proxy correspondingApplicationRecord];
            if ([record respondsToSelector:@selector(appTags)]) {
                recordAppTags = [record appTags];
            }
            if ([record respondsToSelector:@selector(isLaunchProhibited)]) {
                launchProhibited = [record isLaunchProhibited];
            }
        }
        if ([proxy respondsToSelector:@selector(appTags)]) {
            appTags = [proxy appTags];
        }
        if (!launchProhibited && [proxy respondsToSelector:@selector(isLaunchProhibited)]) {
            launchProhibited = [proxy isLaunchProhibited];
        }

        NSURL *bundleURL = [proxy respondsToSelector:@selector(bundleURL)] ? proxy.bundleURL : nil;
        if (bundleURL && [bundleURL checkResourceIsReachableAndReturnError:nil]) {
            NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
            sbAppTags = [bundle objectForInfoDictionaryKey:@"SBAppTags"];
        }
    } @catch (NSException *exception) {
        (void)exception;
    }

    NSString *identifier = [proxy respondsToSelector:@selector(applicationIdentifier)]
        ? proxy.applicationIdentifier : nil;
    BOOL isWebApplication = [identifier rangeOfString:@"com.apple.webapp"
                                               options:NSCaseInsensitiveSearch].location != NSNotFound;

    return POTagArrayContainsHidden(appTags)
        || POTagArrayContainsHidden(recordAppTags)
        || POTagArrayContainsHidden(sbAppTags)
        || isWebApplication
        || launchProhibited;
}

@interface QSFavoritesPickerController () <UITableViewDelegate, UITableViewDataSource, UISearchResultsUpdating, UISearchControllerDelegate> {
    UITableView *favoritesTableView;
    NSMutableDictionary<NSString *, NSString *> *appNamesByIdentifier;
    NSMutableDictionary<NSString *, NSNumber *> *appTypeByIdentifier;

    NSMutableArray<NSString *> *enabledApps;
    NSMutableArray<NSString *> *userApps;
    NSMutableArray<NSString *> *systemApps;
    NSMutableArray<NSString *> *allApps;
    NSUInteger installedAppsLoadGeneration;
    UIActivityIndicatorView *loadingIndicator;
    BOOL isLoadingInstalledApps;

    UISearchController *searchController;
    NSMutableArray<NSString *> *searchResults;
    BOOL isSearching;
}

@end

static void POSortIdentifiersByName(NSMutableArray<NSString *> *identifiers,
                                    NSDictionary<NSString *, NSString *> *names);

@implementation QSFavoritesPickerController

-(instancetype)init{
    return [super init];
}

-(void)loadView{
    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                                           style:UITableViewStyleInsetGrouped];
    tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    favoritesTableView = tableView;
    tableView.delegate = self;

    UIView *loadingView = [[UIView alloc] initWithFrame:CGRectZero];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    indicator.color = [UIColor secondaryLabelColor];
    [loadingView addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:loadingView.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:loadingView.centerYAnchor]
    ]];
    loadingIndicator = indicator;
    isLoadingInstalledApps = YES;
    tableView.backgroundView = loadingView;
    tableView.dataSource = self;
    self.view = tableView;
}

-(void)viewDidLoad{
    self.title = POLocalizedString(@"QuickSwitch Favorites", @"PullOverXPreferences");

    favoritesTableView.allowsSelectionDuringEditing = YES;
    [favoritesTableView setEditing:YES animated:NO];

    appNamesByIdentifier = [NSMutableDictionary dictionary];
    appTypeByIdentifier = [NSMutableDictionary dictionary];
    enabledApps = [NSMutableArray array];
    userApps = [NSMutableArray array];
    systemApps = [NSMutableArray array];
    searchResults = [NSMutableArray array];
    allApps = [NSMutableArray array];
    [loadingIndicator startAnimating];

    [self setupSearchController];
    [self startLoadingInstalledApps];
}

#pragma mark - Data loading

-(void)startLoadingInstalledApps{
    NSUInteger generation = ++installedAppsLoadGeneration;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString *, NSString *> *loadedNames = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *loadedTypes = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *loadedUser = [NSMutableArray array];
        NSMutableArray<NSString *> *loadedSystem = [NSMutableArray array];

        @try {
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            BOOL hasWorkspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)];
            id workspace = hasWorkspace ? [workspaceClass defaultWorkspace] : nil;
            BOOL hasAllApplications = [workspace respondsToSelector:@selector(allApplications)];

            NSArray *installedApps = hasAllApplications ? [workspace allApplications] : nil;

            for (LSApplicationProxy *proxy in installedApps) {
                @try {
                    NSString *identifier = [proxy respondsToSelector:@selector(applicationIdentifier)]
                        ? proxy.applicationIdentifier : nil;
                    NSString *type = [proxy respondsToSelector:@selector(applicationType)]
                        ? proxy.applicationType : nil;
                    NSString *name = [proxy respondsToSelector:@selector(localizedName)]
                        ? proxy.localizedName : nil;
                    if (identifier.length == 0) {
                        continue;
                    }
                    BOOL isUser = [type isEqualToString:@"User"];
                    BOOL isSystem = [type isEqualToString:@"System"];
                    if (!isUser && !isSystem) {
                        continue;
                    }
                    if (POApplicationProxyIsHidden(proxy)) {
                        continue;
                    }

                    loadedNames[identifier] = name ?: identifier;
                    loadedTypes[identifier] = isUser ? @(QSSectionUser) : @(QSSectionSystem);
                    [(isUser ? loadedUser : loadedSystem) addObject:identifier];
                } @catch (NSException *exception) {
                    (void)exception;
                }
            }

            POSortIdentifiersByName(loadedUser, loadedNames);
            POSortIdentifiersByName(loadedSystem, loadedNames);
        } @catch (NSException *exception) {
            (void)exception;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->installedAppsLoadGeneration) {
                return;
            }

            self->appNamesByIdentifier = loadedNames;
            self->appTypeByIdentifier = loadedTypes;
            self->userApps = loadedUser;
            self->systemApps = loadedSystem;
            self->allApps = [NSMutableArray arrayWithArray:loadedUser];
            [self->allApps addObjectsFromArray:loadedSystem];
            [self loadSavedFavorites];
            self->isLoadingInstalledApps = NO;
            [self->favoritesTableView reloadData];
            [self->loadingIndicator stopAnimating];
            self->favoritesTableView.backgroundView = nil;
            self->loadingIndicator = nil;
        });
    });
}

static void POSortIdentifiersByName(NSMutableArray<NSString *> *identifiers,
                                    NSDictionary<NSString *, NSString *> *names) {
    [identifiers sortUsingComparator:^NSComparisonResult(NSString *id1, NSString *id2){
        NSString *n1 = names[id1] ?: id1;
        NSString *n2 = names[id2] ?: id2;
        return [n1 localizedCaseInsensitiveCompare:n2];
    }];
}

-(void)loadSavedFavorites{
    NSUserDefaults *defaults = [self settingsDefaults];
    NSArray *savedFavorites = [[defaults objectForKey:@"favorites"] isKindOfClass:[NSArray class]] ? [defaults objectForKey:@"favorites"] : @[];
    for (NSString *identifier in savedFavorites) {
        if (![identifier isKindOfClass:[NSString class]]) {
            continue;
        }
        if (appTypeByIdentifier[identifier] == nil) {
            continue;
        }
        if ([enabledApps containsObject:identifier]) {
            continue;
        }
        [enabledApps addObject:identifier];
        [userApps removeObject:identifier];
        [systemApps removeObject:identifier];
    }
}

-(void)sortIdentifiersByName:(NSMutableArray<NSString *> *)identifiers{
    POSortIdentifiersByName(identifiers, appNamesByIdentifier);
}

-(void)persistFavorites{
    NSUserDefaults *defaults = [self settingsDefaults];
    [defaults setObject:enabledApps forKey:@"favorites"];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.mlgm.pulloverx.settings-changed"),
                                         NULL,
                                         NULL,
                                         true);
}

#pragma mark - Search

-(void)setupSearchController{
    searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.delegate = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchBar.placeholder = POLocalizedString(@"Search", @"PullOverXPreferences");

    self.navigationItem.searchController = searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

-(void)updateSearchResultsForSearchController:(UISearchController *)controller{
    NSString *query = [controller.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    BOOL nowSearching = (query.length > 0);
    if (nowSearching != isSearching) {
        isSearching = nowSearching;
        [favoritesTableView setEditing:!isSearching animated:NO];
    }

    [searchResults removeAllObjects];
    if (isSearching) {
        for (NSString *identifier in allApps) {
            if ([enabledApps containsObject:identifier]) {
                continue;
            }
            NSString *name = appNamesByIdentifier[identifier] ?: identifier;
            if ([name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [identifier rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [searchResults addObject:identifier];
            }
        }
    }

    [favoritesTableView reloadData];
}

#pragma mark - Helpers

-(NSMutableArray<NSString *> *)arrayForSection:(NSInteger)section{
    switch (section) {
        case QSSectionSelected: return enabledApps;
        case QSSectionUser:     return userApps;
        case QSSectionSystem:   return systemApps;
        default:                return nil;
    }
}

-(NSString *)identifierAtIndexPath:(NSIndexPath *)indexPath{
    if (isSearching) {
        return (indexPath.row < (NSInteger)searchResults.count) ? searchResults[indexPath.row] : nil;
    }
    NSMutableArray<NSString *> *array = [self arrayForSection:indexPath.section];
    return (indexPath.row < (NSInteger)array.count) ? array[indexPath.row] : nil;
}

#pragma mark - Table view data source

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{
    if (isLoadingInstalledApps) {
        return 0;
    }
    return isSearching ? 1 : QSSectionCount;
}

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    if (isLoadingInstalledApps) {
        return 0;
    }
    if (isSearching) {
        return searchResults.count;
    }
    return [self arrayForSection:section].count;
}

-(NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{
    if (isLoadingInstalledApps || isSearching) {
        return nil;
    }
    switch (section) {
        case QSSectionSelected:
            return (enabledApps.count == 0)
                ? POLocalizedString(@"Tap an app below to select", @"PullOverXPreferences")
                : POLocalizedString(@"Selected Apps", @"PullOverXPreferences");
        case QSSectionUser:
            return POLocalizedString(@"User Apps", @"PullOverXPreferences");
        case QSSectionSystem:
            return POLocalizedString(@"System Apps", @"PullOverXPreferences");
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSString *identifier = [self identifierAtIndexPath:indexPath];
    if (identifier == nil) {
        cell.textLabel.text = nil;
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
        return cell;
    }

    cell.textLabel.text = appNamesByIdentifier[identifier] ?: identifier;
    cell.detailTextLabel.text = identifier;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    @try {
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:identifier format:0 scale:[UIScreen mainScreen].scale];
        cell.imageView.image = icon;
    } @catch (NSException *exception) {
        cell.imageView.image = nil;
    }

    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *identifier = [self identifierAtIndexPath:indexPath];
    if (identifier == nil) {
        return;
    }

    if (isSearching) {
        [searchResults removeObject:identifier];
        [userApps removeObject:identifier];
        [systemApps removeObject:identifier];
        [enabledApps addObject:identifier];
        [self persistFavorites];
        [favoritesTableView reloadData];
        return;
    }

    if (indexPath.section == QSSectionSelected) {
        [enabledApps removeObject:identifier];
        QSSection origin = (QSSection)[appTypeByIdentifier[identifier] integerValue];
        NSMutableArray<NSString *> *pool = (origin == QSSectionSystem) ? systemApps : userApps;
        [pool addObject:identifier];
        [self sortIdentifiersByName:pool];
    } else {
        [[self arrayForSection:indexPath.section] removeObject:identifier];
        [enabledApps addObject:identifier];
    }

    [self persistFavorites];
    [favoritesTableView reloadData];
}

#pragma mark - Reordering (drag handles on the Selected section)

-(BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath{
    return !isSearching && indexPath.section == QSSectionSelected && enabledApps.count > 0;
}

-(NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath{
    if (proposedDestinationIndexPath.section != QSSectionSelected) {
        return [NSIndexPath indexPathForRow:enabledApps.count - 1 inSection:QSSectionSelected];
    }
    return proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath{
    if (sourceIndexPath.section != QSSectionSelected || destinationIndexPath.section != QSSectionSelected) {
        return;
    }
    NSString *element = [enabledApps[sourceIndexPath.row] copy];
    [enabledApps removeObjectAtIndex:sourceIndexPath.row];
    [enabledApps insertObject:element atIndex:destinationIndexPath.row];
    [self persistFavorites];
}

-(UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath{
    return UITableViewCellEditingStyleNone;
}

-(BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath{
    return NO;
}

#pragma mark - Persistence helper

- (NSUserDefaults *)settingsDefaults{
    return [[NSUserDefaults alloc] initWithSuiteName:@"com.mlgm.pulloverx"];
}

@end
