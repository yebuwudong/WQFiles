"""Execute the scan disappearance handlers with host-side lifecycle doubles.

This checks cancellation and UI state, not UIKit's delivery of lifecycle events.
The production method bodies are compiled unchanged against Foundation doubles.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def disappearance(source, controller):
    implementation = source.split(f"@implementation {controller}", 1)[1]
    implementation = implementation.split("@end", 1)[0]
    if "- (void)viewWillDisappear:(BOOL)animated" not in implementation:
        return ""  # Inherits the no-op handler; no cancellation on disappearance.
    method = implementation.split("- (void)viewWillDisappear:(BOOL)animated", 1)[1]
    # Each handler ends at the first unindented closing brace.
    return "- (void)viewWillDisappear:(BOOL)animated" + method.split("\n}", 1)[0] + "\n}"


class ScanLifecycleTests(unittest.TestCase):
    def test_navigation_does_not_cancel_scans(self):
        harness = r'''
#import <Foundation/Foundation.h>
@interface Token : NSObject
@property BOOL cancelled;
- (void)cancel;
@end
@implementation Token
- (void)cancel { self.cancelled = YES; }
@end
@interface Refresh : NSObject
@property BOOL ended;
- (void)endRefreshing;
@end
@implementation Refresh
- (void)endRefreshing { self.ended = YES; }
@end
@interface Screen : NSObject
@property BOOL isMovingFromParentViewController, isBeingDismissed;
@property Screen *navigationController, *tabBarController;
@property Refresh *refreshControl;
- (void)viewWillDisappear:(BOOL)animated;
- (void)exitBackupSelection;
- (void)exitFileSelection;
- (void)updateHeader;
@end
@implementation Screen
- (void)viewWillDisappear:(BOOL)animated { (void)animated; }
- (void)exitBackupSelection {}
- (void)exitFileSelection {}
- (void)updateHeader {}
@end
'''
        controllers = [('WQApps.m', 'WQAppsViewController'),
                       ('WQCache.m', 'WQCacheCleanerViewController'),
                       ('main.m', 'WQDirViewController')]
        for filename, controller in controllers:
            method = disappearance((ROOT / filename).read_text(), controller)
            harness += f'''
@interface {controller} : Screen {{
@public
    BOOL _scanning, _scanInFlight, _cleaning, _scanNeedsRefresh;
    BOOL _selectingBackups, _selectingFiles;
    Token *_scanCancellation, *_cleanCancellation;
    NSString *_scanStatus;
}}
@end
@implementation {controller}
{method}
@end
'''
        harness += 'int main(void) { @autoreleasepool {\n'
        for _, controller in controllers:
            harness += f'''
// Hidden tab / pushed child / covering presentation all leave removal flags false.
for (int removal = 0; removal < 5; removal++) {{
    {controller} *screen = [{controller} new];
    screen.navigationController = [Screen new];
    screen.tabBarController = [Screen new];
    screen.refreshControl = [Refresh new];
    screen->_scanning = screen->_scanInFlight = YES;
    screen->_scanCancellation = [Token new];
    screen->_cleanCancellation = [Token new];
    screen->_scanStatus = @"Measuring";
    if (removal == 1) screen.isMovingFromParentViewController = YES;
    if (removal == 2) screen.isBeingDismissed = YES;
    if (removal == 3) screen.navigationController.isBeingDismissed = YES;
    if (removal == 4) screen.tabBarController.isBeingDismissed = YES;
    // Repeated tab switches must keep the same live token and progress.
    for (int visit = 0; visit < 3; visit++) [screen viewWillDisappear:NO];
    NSCAssert(!screen->_scanCancellation.cancelled, @"{controller}: cancellation");
    NSCAssert(!screen.refreshControl.ended, @"hidden scan retains refresh state");
    NSCAssert(!screen->_scanNeedsRefresh, @"hidden scan needs no restart");
    NSCAssert([screen->_scanStatus isEqual:@"Measuring"], @"hidden scan retains progress");
}}
'''
        harness += '''
// Destructive cleaning retains its existing stop-on-disappearance policy.
WQCacheCleanerViewController *clean = [WQCacheCleanerViewController new];
clean->_cleaning = YES;
clean->_cleanCancellation = [Token new];
[clean viewWillDisappear:NO];
NSCAssert(clean->_cleanCancellation.cancelled, @"hidden cleaning still stops");
} return 0; }
'''
        output = ROOT / '.work' / 'tests'
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output) as tmp:
            source = Path(tmp) / 'lifecycle.m'
            binary = Path(tmp) / 'lifecycle'
            source.write_text(harness)
            sdk = subprocess.check_output(
                ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
            subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc',
                            '-Wall', '-Wextra', '-Werror', '-isysroot', sdk,
                            str(source), '-framework', 'Foundation', '-o', str(binary)],
                           check=True, capture_output=True, text=True, timeout=60)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
