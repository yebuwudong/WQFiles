//
//  WQHealth.h
//  WQ Files
//
//  Startup check of everything WQ Files depends on: the App Group, finding
//  other apps' folders, the sandbox escape (a token that really opens them)
//  and the app database (names, container labels). A new iOS release can
//  break any of these; without this check that shows up as empty or wrong
//  lists. Failures stop the app at a screen that says what failed; problems
//  that leave it partly usable are warnings.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WQHealthState) {
    WQHealthOK = 0,
    WQHealthSkipped,     // not checked (an earlier step failed, or the user declined a scan)
    WQHealthWarning,     // works partly
    WQHealthFailed,      // WQ Files can't do its job
};

@interface WQHealthCheck : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;          // English name, for the Log
@property (nonatomic, copy) NSString *detail;
@property (nonatomic) WQHealthState state;
@end

// Runs every check (blocking; call off the main thread). `stage` gets a short
// description of the step in progress (any thread).
NSArray<WQHealthCheck *> *wq_health_run(void (^_Nullable stage)(NSString *text));

// Whether app bundle folders (/var/containers/Bundle/Application/...) open
// on this device, as found by the last wq_health_run. NO until it ran.
BOOL wq_app_bundles_reachable(void);

// The worst state among the checks.
WQHealthState wq_health_worst(NSArray<WQHealthCheck *> *checks);

// Pure decision for the sandbox sample, for tests: given how many sampled
// folders opened, the state of the "Sandbox access" check.
WQHealthState wq_health_access_state(NSUInteger opened, NSUInteger sampled);
// Same for the app database: labeled = sampled folders that got a valid
// bundle id; namesLoaded / knownName as read.
WQHealthState wq_health_names_state(BOOL namesLoaded, BOOL knownName, NSUInteger labeled, NSUInteger sampled);

NS_ASSUME_NONNULL_END
