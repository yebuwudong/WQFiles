// Runs real UIKit controllers against an application-owned task with fixture
// results. No sandbox exploit, real app-container scan or destructive action.
#import <UIKit/UIKit.h>
#import "../WQApps.h"
#import "../WQCache.h"
#import "../WQScanTask.h"
#import "../WQUI.h"
#import "../WQAccess.h"

static void mark(NSString *name)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    [NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    [@"ok" writeToFile:[documents stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"TEST: %@", name);
}
static void require(BOOL condition, NSString *name)
{
    if (!condition) { mark([@"FAIL-" stringByAppendingString:name]); abort(); }
    NSLog(@"PASS: %@", name);
}
static NSDictionary *result(void)
{
    return @{@"rows": @[@{@"name": @"Fixture", @"containerPath": @"/fixture", @"container": @"/fixture",
                          @"limited": @YES, @"bytes": @123, @"cacheBytes": @123}], @"note": @"", @"complete": @YES};
}
@interface TestScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property UITabBarController *tabs;
@property WQScanTask *appsTask, *cleanTask;
@property NSUInteger appsGeneration, cleanGeneration;
@property BOOL waitingForBackground;
@end
@implementation TestScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)session; (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    (void)wq_scan_queue();
    self.appsTask = [WQScanTask taskNamed:@"apps"];
    self.cleanTask = [WQScanTask taskNamed:@"clean"];
    BOOL recovery = [NSProcessInfo.processInfo.arguments containsObject:@"recover"];
    if (recovery) {
        require(self.cleanTask.interrupted, @"interrupted-job-found-after-termination");
        require(self.cleanTask.result != nil, @"previous-result-survived-termination");
        NSString *identifier = self.cleanTask.identifier;
        self.cleanGeneration = [self.cleanTask beginFresh:NO cancel:^{}];
        require([identifier isEqual:self.cleanTask.identifier], @"same-job-resumed");
    } else {
        self.appsGeneration = [self.appsTask beginFresh:YES cancel:^{}];
        self.cleanGeneration = [self.cleanTask beginFresh:YES cancel:^{}];
    }
    self.tabs = [UITabBarController new];
    self.tabs.viewControllers = @[[[UINavigationController alloc] initWithRootViewController:[UIViewController new]],
        [[UINavigationController alloc] initWithRootViewController:[[WQAppsViewController alloc] initRestoringBundleID:@"com.example.fixture"]],
        [[UINavigationController alloc] initWithRootViewController:[WQCacheCleanerViewController new]],
        [[UINavigationController alloc] initWithRootViewController:[UIViewController new]]];
    self.window.rootViewController = self.tabs;
    [self.window makeKeyAndVisible];
    __weak TestScene *weakSelf = self;
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *__unused note) {
        TestScene *self = weakSelf;
        if (!self.waitingForBackground) return;
        require(self.cleanTask.paused && self.cleanTask.running, @"background-pauses-without-cancelling");
        mark(@"background-paused");
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *__unused note) {
        TestScene *self = weakSelf;
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!self.waitingForBackground || ![NSFileManager.defaultManager fileExistsAtPath:[documents stringByAppendingPathComponent:@"background-paused"]]) return;
        require(!self.cleanTask.paused && self.cleanTask.running, @"foreground-keeps-same-job");
        self.waitingForBackground = NO;
        [self.cleanTask finish:result() generation:self.cleanGeneration];
        [self.cleanTask beginFresh:YES cancel:^{}];
        mark(@"ready-to-terminate");
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (recovery) {
            [self.cleanTask finish:result() generation:self.cleanGeneration];
            self.tabs.selectedIndex = 2;
            WQCacheCleanerViewController *clean = (id)((UINavigationController *)self.tabs.selectedViewController).topViewController;
            [clean loadViewIfNeeded];
            require([[clean valueForKey:@"items"] count] == 1, @"recovered-result-displayed");
            mark(@"recovery-passed");
        } else [self checkIOYield];
    });
}
- (void)checkIOYield
{
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:@"yield-fixture"];
    for (int i = 0; i < 20; i++) {
        NSString *dir = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", i]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [@"x" writeToFile:[dir stringByAppendingPathComponent:@"file"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    dispatch_async(wq_scan_queue(), ^{
        __block NSUInteger steps = 0;
        __block BOOL foregroundRan = NO, yielded = NO;
        unsigned long long bytes = 0;
        WQMeasureResult measured = wq_measure_tree_resumable(base, @"ui-fixture", NSUUID.UUID.UUIDString, nil, &bytes, ^(void (^work)(void)) {
            wq_scan_read(^{
                steps++;
                if (steps > 2 && foregroundRan) yielded = YES;
                work();
            });
            if (steps == 2) dispatch_async(wq_io(), ^{ foregroundRan = YES; });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            require(measured == WQMeasureResultKnown && bytes == 20, @"real-resumable-measurement-finishes");
            require(yielded, @"foreground-io-runs-between-scan-directories");
            [self switchTab:0];
        });
    });
}
- (void)switchTab:(NSUInteger)step
{
    if (step < 12) {
        self.tabs.selectedIndex = step % 4;
        require(self.appsTask.running && self.cleanTask.running, @"tab-switch-keeps-tasks-running");
        require(self.appsTask.generation == self.appsGeneration && self.cleanTask.generation == self.cleanGeneration, @"tab-switch-does-not-restart");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self switchTab:step + 1]; });
        return;
    }
    WQAppsViewController *apps = (id)((UINavigationController *)self.tabs.viewControllers[1]).topViewController;
    // During a transition a covered controller can still be in the window.
    // Keep that state until the asynchronous backup refresh has also completed.
    [self.window addSubview:apps.view];
    require(apps.view.window != nil && self.tabs.selectedIndex != 1, @"covered-apps-still-attached-to-window");
    [self.appsTask finish:result() generation:self.appsGeneration];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        require(![[apps valueForKey:@"refreshingBackups"] boolValue], @"backup-refresh-completed-before-visibility-check");
        require([[apps valueForKey:@"restoreBundleID"] isEqual:@"com.example.fixture"], @"covered-apps-retains-pending-restore");
        [apps.view removeFromSuperview];
        [self checkRebuiltScreen];
    });
}
- (void)checkRebuiltScreen
{
    [self.cleanTask finish:result() generation:self.cleanGeneration];
    // Rebuild a screen: it must render saved results without starting a worker.
    WQCacheCleanerViewController *replacement = [WQCacheCleanerViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:replacement];
    self.tabs.viewControllers = @[nav];
    self.tabs.selectedIndex = 0;
    [replacement loadViewIfNeeded];
    require(!self.cleanTask.running && self.cleanTask.generation == self.cleanGeneration, @"rebuilt-screen-does-not-rescan");
    require([[replacement valueForKey:@"items"] count] == 1, @"rebuilt-screen-renders-results");
    require(replacement.navigationItem.prompt.length > 0, @"result-timestamp-visible");
    self.cleanGeneration = [self.cleanTask beginFresh:YES cancel:^{}];
    NSString *identifier = self.cleanTask.identifier;
    [self.cleanTask pause];
    require(self.cleanTask.userPaused && !self.cleanTask.running, @"explicit-pause-keeps-job");
    require([replacement.navigationItem.rightBarButtonItems.firstObject.title isEqual:@"Resume Scan"], @"resume-control-visible");
    self.cleanGeneration = [self.cleanTask beginFresh:NO cancel:^{}];
    require([identifier isEqual:self.cleanTask.identifier], @"explicit-resume-keeps-checkpoints");
    self.waitingForBackground = YES;
    mark(@"ready-for-background");
}
@end
@interface TestApp : UIResponder <UIApplicationDelegate>
@end
@implementation TestApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)app; (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Tests" sessionRole:session.role];
    configuration.delegateClass = TestScene.class;
    return configuration;
}
@end
int main(int argc, char *argv[])
{
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TestApp.class)); }
}
