#import "AccountService.h"
#import "WPAccount.h"
#import "CoreDataStack.h"
#import "Blog.h"
#import "BlogService.h"
#import "TodayExtensionService.h"

@import WordPressKit;
@import WordPressShared;
#import "WordPress-Swift.h"

static NSString * const DefaultDotcomAccountUUIDDefaultsKey = @"AccountDefaultDotcomUUID";
static NSString * const DefaultDotcomAccountPasswordRemovedKey = @"DefaultDotcomAccountPasswordRemovedKey";

static NSString * const WordPressDotcomXMLRPCKey = @"https://wordpress.com/xmlrpc.php";
NSNotificationName const WPAccountDefaultWordPressComAccountChangedNotification = @"WPAccountDefaultWordPressComAccountChangedNotification";
NSString * const WPAccountEmailAndDefaultBlogUpdatedNotification = @"WPAccountEmailAndDefaultBlogUpdatedNotification";

@implementation AccountService

///------------------------------------
/// @name Default WordPress.com account
///------------------------------------

/**
 Sets the default WordPress.com account

 @param account the account to set as default for WordPress.com
 @see defaultWordPressComAccount
 @see removeDefaultWordPressComAccount
 */
- (void)setDefaultWordPressComAccount:(WPAccount *)account
{
    NSParameterAssert(account != nil);
    NSAssert(account.authToken.length > 0, @"Account should have an authToken for WP.com");

    if ([account isDefaultWordPressComAccount]) {
        return;
    }

    [[UserPersistentStoreFactory userDefaultsInstance] setObject:account.uuid forKey:DefaultDotcomAccountUUIDDefaultsKey];

    NSManagedObjectID *accountID = account.objectID;
    void (^notifyAccountChange)(void) = ^{
        NSManagedObjectContext *mainContext = [[ContextManager sharedInstance] mainContext];
        NSManagedObject *accountInContext = [mainContext existingObjectWithID:accountID error:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:WPAccountDefaultWordPressComAccountChangedNotification object:accountInContext];

        [[PushNotificationsManager shared] setupRemoteNotifications];
    };
    if ([NSThread isMainThread]) {
        // This is meant to help with testing account observers.
        // Short version: dispatch_async and XCTest asynchronous helpers don't play nice with each other
        // Long version: see the comment in https://github.com/wordpress-mobile/WordPress-iOS/blob/2f9a2100ca69d8f455acec47a1bbd6cbc5084546/WordPress/WordPressTest/AccountServiceRxTests.swift#L7
        notifyAccountChange();
    } else {
        dispatch_async(dispatch_get_main_queue(), notifyAccountChange);
    }
}

/**
 Removes the default WordPress.com account

 @see defaultWordPressComAccount
 @see setDefaultWordPressComAccount:
 */
- (void)removeDefaultWordPressComAccount
{
    NSAssert([NSThread isMainThread], @"This method should only be called from the main thread");

    [[PushNotificationsManager shared] unregisterDeviceToken];

    WPAccount *account = [WPAccount lookupDefaultWordPressComAccountInContext:self.coreDataStack.mainContext];
    if (account == nil) {
        return;
    }

    [self.coreDataStack performAndSaveUsingBlock:^(NSManagedObjectContext *context) {
        WPAccount *accountInContext = [context existingObjectWithID:account.objectID error:nil];
        [context deleteObject:accountInContext];
    }];
    
    // Clear WordPress.com cookies
    NSArray<id<CookieJar>> *cookieJars = @[
        (id<CookieJar>)[NSHTTPCookieStorage sharedHTTPCookieStorage],
        (id<CookieJar>)[[WKWebsiteDataStore defaultDataStore] httpCookieStore]
    ];

    for (id<CookieJar> cookieJar in cookieJars) {
        [cookieJar removeWordPressComCookiesWithCompletion:^{}];
    }

    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    // Remove defaults
    [[UserPersistentStoreFactory userDefaultsInstance] removeObjectForKey:DefaultDotcomAccountUUIDDefaultsKey];
    
    [WPAnalytics refreshMetadata];
    [[NSNotificationCenter defaultCenter] postNotificationName:WPAccountDefaultWordPressComAccountChangedNotification object:nil];
}

- (void)isEmailAvailable:(NSString *)email success:(void (^)(BOOL available))success failure:(void (^)(NSError *error))failure
{
    id<AccountServiceRemote> remote = [self remoteForAnonymous];
    [remote isEmailAvailable:email success:^(BOOL available) {
        if (success) {
            success(available);
        }
    } failure:^(NSError *error) {
        if (failure) {
            failure(error);
        }
    }];
}

- (void)isUsernameAvailable:(NSString *)username
                    success:(void (^)(BOOL available))success
                    failure:(void (^)(NSError *error))failure
{
    id<AccountServiceRemote> remote = [self remoteForAnonymous];
    [remote isUsernameAvailable:username success:^(BOOL available) {
        if (success) {
            success(available);
        }
    } failure:^(NSError *error) {
        if (failure) {
            failure(error);
        }
    }];
}

- (void)requestVerificationEmail:(void (^)(void))success failure:(void (^)(NSError * _Nonnull))failure
{
    NSAssert([NSThread isMainThread], @"This method should only be called from the main thread");

    WPAccount *account = [WPAccount lookupDefaultWordPressComAccountInContext:self.coreDataStack.mainContext];
    id<AccountServiceRemote> remote = [self remoteForAccount:account];
    [remote requestVerificationEmailWithSucccess:^{
        if (success) {
            success();
        }
    } failure:^(NSError *error) {
        if (failure) {
            failure(error);
        }
    }];
}


///-----------------------
/// @name Account creation
///-----------------------

- (NSManagedObjectID *)createOrUpdateAccountWithUserDetails:(RemoteUser *)remoteUser authToken:(NSString *)authToken
{
    NSManagedObjectID * __block accountObjectID = nil;
    [self.coreDataStack.mainContext performBlockAndWait:^{
        accountObjectID = [[WPAccount lookupDefaultWordPressComAccountInContext:self.coreDataStack.mainContext] objectID];
    }];

    if (accountObjectID) {
        [self.coreDataStack performAndSaveUsingBlock:^(NSManagedObjectContext *context) {
            WPAccount *account = [context existingObjectWithID:accountObjectID error:nil];
            // Even if we find an account via its userID we should still update
            // its authtoken, otherwise the Authenticator's authtoken fixer won't
            // work.
            account.authToken = authToken;
        }];
    } else {
        accountObjectID = [self createOrUpdateAccountWithUsername:remoteUser.username authToken:authToken];
    }

    [self updateAccount:accountObjectID withUserDetails:remoteUser];

    return accountObjectID;
}

/**
 Creates a new WordPress.com account or updates the password if there is a matching account

 There can only be one WordPress.com account per username, so if one already exists for the given `username` its password is updated

 Uses a background managed object context.

 @param username the WordPress.com account's username
 @param authToken the OAuth2 token returned by signIntoWordPressDotComWithUsername:authToken:
 @return The ID of the WordPress.com `WPAccount` object for the given `username`
 @see createOrUpdateWordPressComAccountWithUsername:password:authToken:
 */
- (NSManagedObjectID *)createOrUpdateAccountWithUsername:(NSString *)username authToken:(NSString *)authToken
{
    NSManagedObjectID * __block objectID = nil;
    [self.coreDataStack performAndSaveUsingBlock:^(NSManagedObjectContext *context) {
        WPAccount *account = [WPAccount lookupWithUsername:username context:context];
        if (!account) {
            account = [NSEntityDescription insertNewObjectForEntityForName:@"Account" inManagedObjectContext:context];
            account.uuid = [[NSUUID new] UUIDString];
            account.username = username;
        }
        account.authToken = authToken;
        [context obtainPermanentIDsForObjects:@[account] error:nil];
        objectID = account.objectID;
    }];

    [self.coreDataStack.mainContext performBlockAndWait:^{
        WPAccount *defaultAccount = [WPAccount lookupDefaultWordPressComAccountInContext:self.coreDataStack.mainContext];
        if (!defaultAccount) {
            WPAccount *account = [self.coreDataStack.mainContext existingObjectWithID:objectID error:nil];
            [self setDefaultWordPressComAccount:account];
            dispatch_async(dispatch_get_main_queue(), ^{
                [WPAnalytics refreshMetadata];
            });
        }
    }];

    return objectID;
}

- (NSUInteger)numberOfAccounts
{
    NSFetchRequest *request = [[NSFetchRequest alloc] init];
    [request setEntity:[NSEntityDescription entityForName:@"Account" inManagedObjectContext:self.managedObjectContext]];
    [request setIncludesSubentities:NO];

    NSError *error;
    NSUInteger count = [self.managedObjectContext countForFetchRequest:request error:&error];
    if (count == NSNotFound) {
        count = 0;
    }
    return count;
}

- (NSArray<WPAccount *> *)allAccounts
{
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Account"];
    NSError *error = nil;
    NSArray *fetchedObjects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];
    if (error) {
        return @[];
    }
    return fetchedObjects;
}

/**
 Checks an account to see if it is just used to connect to Jetpack.

 @param account The account to inspect.
 @return True if used only for a Jetpack connection.
 */
- (BOOL)accountHasOnlyJetpackBlogs:(WPAccount *)account
{
    if ([account.blogs count] == 0) {
        // Most likly, this is a blogless account used for the reader or commenting and not Jetpack.
        return NO;
    }

    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF.isHostedAtWPcom = true"];
    NSSet *wpcomBlogs = [account.blogs filteredSetUsingPredicate:predicate];
    if ([wpcomBlogs count] > 0) {
        return NO;
    }

    return YES;
}

- (WPAccount *)accountWithUUID:(NSString *)uuid
{
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Account"];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"uuid == %@", uuid];
    fetchRequest.predicate = predicate;

    NSError *error = nil;
    NSArray *fetchedObjects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];
    if (fetchedObjects.count > 0) {
        WPAccount *defaultAccount = fetchedObjects.firstObject;
        defaultAccount.displayName = [defaultAccount.displayName stringByDecodingXMLCharacters];
        return defaultAccount;
    }
    return nil;
}

- (void)restoreDisassociatedAccountIfNecessary
{
    NSAssert([NSThread isMainThread], @"This method should only be called from the main thread");

    if([WPAccount lookupDefaultWordPressComAccountInContext:self.coreDataStack.mainContext] != nil) {
        return;
    }

    // Attempt to restore a default account that has somehow been disassociated.
    WPAccount *account = [self findDefaultAccountCandidate];
    if (account) {
        // Assume we have a good candidate account and make it the default account in the app.
        // Note that this should be the account with the most blogs.
        // Updates user defaults here vs the setter method to avoid potential side-effects from dispatched notifications.
        [[UserPersistentStoreFactory userDefaultsInstance] setObject:account.uuid forKey:DefaultDotcomAccountUUIDDefaultsKey];
    }
}

- (WPAccount *)findDefaultAccountCandidate
{
    NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"blogs.@count" ascending:NO];
    NSArray *accounts = [[self allAccounts] sortedArrayUsingDescriptors:@[sort]];

    for (WPAccount *account in accounts) {
        // Skip accounts that were likely added to Jetpack-connected self-hosted
        // sites, while there was an existing default wpcom account.
        if ([self accountHasOnlyJetpackBlogs:account]) {
            continue;
        }
        return account;
    }
    return nil;
}

- (void)createOrUpdateAccountWithAuthToken:(NSString *)authToken
                                   success:(void (^)(WPAccount * _Nonnull))success
                                   failure:(void (^)(NSError * _Nonnull))failure
{
    WordPressComRestApi *api = [WordPressComRestApi defaultApiWithOAuthToken:authToken userAgent:[WPUserAgent defaultUserAgent] localeKey:[WordPressComRestApi LocaleKeyDefault]];
    AccountServiceRemoteREST *remote = [[AccountServiceRemoteREST alloc] initWithWordPressComRestApi:api];
    [remote getAccountDetailsWithSuccess:^(RemoteUser *remoteUser) {
        NSManagedObjectID *objectID = [self createOrUpdateAccountWithUserDetails:remoteUser authToken:authToken];
        WPAccount * __block account = nil;
        [self.coreDataStack.mainContext performBlockAndWait:^{
            account = [self.coreDataStack.mainContext existingObjectWithID:objectID error:nil];
        }];
        success(account);
    } failure:^(NSError *error) {
        failure(error);
    }];
}

- (void)updateUserDetailsForAccount:(WPAccount *)account
                           success:(nullable void (^)(void))success
                           failure:(nullable void (^)(NSError * _Nonnull))failure
{
    NSAssert(account, @"Account can not be nil");
    NSAssert(account.username, @"account.username can not be nil");

    id<AccountServiceRemote> remote = [self remoteForAccount:account];
    [remote getAccountDetailsWithSuccess:^(RemoteUser *remoteUser) {
        // account.objectID can be temporary, so fetch via username/xmlrpc instead.
        [self updateAccount:account.objectID withUserDetails:remoteUser];
        dispatch_async(dispatch_get_main_queue(), ^{
            [WPAnalytics refreshMetadata];
            if (success) {
                success();
            }
        });
    } failure:^(NSError *error) {
        DDLogError(@"Failed to fetch user details for account %@.  %@", account, error);
        if (failure) {
            failure(error);
        }
    }];
}

- (id<AccountServiceRemote>)remoteForAnonymous
{
    WordPressComRestApi *api = [WordPressComRestApi defaultApiWithOAuthToken:nil
                                                                   userAgent:nil
                                                                   localeKey:[WordPressComRestApi LocaleKeyDefault]];
    return [[AccountServiceRemoteREST alloc] initWithWordPressComRestApi:api];
}

- (id<AccountServiceRemote>)remoteForAccount:(WPAccount *)account
{
    if (account.wordPressComRestApi == nil) {
        return nil;
    }

    return [[AccountServiceRemoteREST alloc] initWithWordPressComRestApi:account.wordPressComRestApi];
}

- (void)updateAccount:(NSManagedObjectID *)objectID withUserDetails:(RemoteUser *)userDetails
{
    NSParameterAssert(![objectID isTemporaryID]);

    [self.coreDataStack performAndSaveUsingBlock:^(NSManagedObjectContext *context) {
        WPAccount *account = [context existingObjectWithID:objectID error:nil];
        account.userID = userDetails.userID;
        account.username = userDetails.username;
        account.email = userDetails.email;
        account.avatarURL = userDetails.avatarURL;
        account.displayName = userDetails.displayName;
        account.dateCreated = userDetails.dateCreated;
        account.emailVerified = @(userDetails.emailVerified);
        account.primaryBlogID = userDetails.primaryBlogID;
    }];

    // Make sure the account is saved before updating its default blog.
    [self.coreDataStack performAndSaveUsingBlock:^(NSManagedObjectContext *context) {
        WPAccount *account = [context existingObjectWithID:objectID error:nil];
        [self updateDefaultBlogIfNeeded:account];
    }];
}

- (void)updateDefaultBlogIfNeeded:(WPAccount *)account
{
    if (!account.primaryBlogID || [account.primaryBlogID intValue] == 0) {
        return;
    }

    // Load the Default Blog
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"blogID = %@", account.primaryBlogID];
    Blog *defaultBlog = [[account.blogs filteredSetUsingPredicate:predicate] anyObject];

    if (!defaultBlog) {
        DDLogError(@"Error: The Default Blog could not be loaded");
        return;
    }

    // Setup the Account
    account.defaultBlog = defaultBlog;

    // Update app extensions if needed.
    if ([account isDefaultWordPressComAccount]) {
        [self setupAppExtensionsWithDefaultAccount];
    }
}

- (void)setupAppExtensionsWithDefaultAccount
{
    WPAccount * __block defaultAccount = nil;
    [self.coreDataStack.mainContext performBlockAndWait:^{
        defaultAccount = [WPAccount lookupDefaultWordPressComAccountInContext:self.coreDataStack.mainContext];
    }];

    Blog *defaultBlog = [defaultAccount defaultBlog];
    NSNumber *siteId    = defaultBlog.dotComID;
    NSString *blogName  = defaultBlog.settings.name;
    NSString *blogUrl   = defaultBlog.displayURL;
    
    if (defaultBlog == nil || defaultBlog.isDeleted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TodayExtensionService *service = [TodayExtensionService new];
            [service removeTodayWidgetConfiguration];

            [ShareExtensionService removeShareExtensionConfiguration];

            [NotificationSupportService deleteContentExtensionToken];
            [NotificationSupportService deleteServiceExtensionToken];
        });
    } else {
        // Required Attributes

        NSString *oauth2Token       = defaultAccount.authToken;

        // For the Today Extensions, if the user has set a non-primary site, use that.
        NSUserDefaults *sharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:WPAppGroupName];
        NSNumber *todayExtensionSiteID = [sharedDefaults objectForKey:AppConfigurationWidgetStatsToday.userDefaultsSiteIdKey];
        NSString *todayExtensionBlogName = [sharedDefaults objectForKey:AppConfigurationWidgetStatsToday.userDefaultsSiteNameKey];
        NSString *todayExtensionBlogUrl = [sharedDefaults objectForKey:AppConfigurationWidgetStatsToday.userDefaultsSiteUrlKey];

        Blog *todayExtensionBlog = [Blog lookupWithID:todayExtensionSiteID in:self.coreDataStack.mainContext];
        NSTimeZone *timeZone = [todayExtensionBlog timeZone];

        if (todayExtensionSiteID == NULL || todayExtensionBlog == nil) {
            todayExtensionSiteID = siteId;
            todayExtensionBlogName = blogName;
            todayExtensionBlogUrl = blogUrl;
            timeZone = [defaultBlog timeZone];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // set the default site ID for iOS 14 Stats Widgets
            [sharedDefaults setObject:siteId forKey:AppConfigurationWidgetStats.userDefaultsSiteIdKey];

            TodayExtensionService *service = [TodayExtensionService new];
            [service configureTodayWidgetWithSiteID:todayExtensionSiteID
                                           blogName:todayExtensionBlogName
                                            blogUrl:todayExtensionBlogUrl
                                       siteTimeZone:timeZone
                                     andOAuth2Token:oauth2Token];

            [ShareExtensionService configureShareExtensionDefaultSiteID:siteId.integerValue defaultSiteName:blogName];
            [ShareExtensionService configureShareExtensionToken:defaultAccount.authToken];
            [ShareExtensionService configureShareExtensionUsername:defaultAccount.username];

            [NotificationSupportService insertContentExtensionToken:defaultAccount.authToken];
            [NotificationSupportService insertContentExtensionUsername:defaultAccount.username];

            [NotificationSupportService insertServiceExtensionToken:defaultAccount.authToken];
            [NotificationSupportService insertServiceExtensionUsername:defaultAccount.username];
            [NotificationSupportService insertServiceExtensionUserID:defaultAccount.userID.stringValue];
        });
    }
    
}

- (void)purgeAccountIfUnused:(WPAccount *)account
{
    NSParameterAssert(account);

    [self.coreDataStack performAndSaveUsingBlock:^(NSManagedObjectContext *context) {
        BOOL purge = NO;
        WPAccount *defaultAccount = [WPAccount lookupDefaultWordPressComAccountInContext:context];
        if ([account.blogs count] == 0
            && ![defaultAccount isEqual:account]) {
            purge = YES;
        }

        if (purge) {
            DDLogWarn(@"Removing account since it has no blogs associated and it's not the default account: %@", account);
            WPAccount *accountInContext = [context existingObjectWithID:account.objectID error:nil];
            [context deleteObject:accountInContext];
        }
    }];
}

///--------------------
/// @name Visible blogs
///--------------------

- (void)setVisibility:(BOOL)visible forBlogs:(NSArray *)blogs
{
    WPAccount *defaultAccount = [WPAccount lookupDefaultWordPressComAccountInContext:self.managedObjectContext];
    NSMutableDictionary *blogVisibility = [NSMutableDictionary dictionaryWithCapacity:blogs.count];
    for (Blog *blog in blogs) {
        NSAssert(blog.dotComID.unsignedIntegerValue > 0, @"blog should have a wp.com ID");
        NSAssert([blog.account isEqual:defaultAccount], @"blog should belong to the default account");
        // This shouldn't happen, but just in case, let's not crash if
        // something tries to change visibility for a self hosted
        if (blog.dotComID) {
            blogVisibility[blog.dotComID] = @(visible);
        }
        blog.visible = visible;
    }
    AccountServiceRemoteREST *remote = [self remoteForAccount:defaultAccount];
    [remote updateBlogsVisibility:blogVisibility success:nil failure:^(NSError *error) {
        DDLogError(@"Error setting blog visibility: %@", error);
    }];
}

@end
