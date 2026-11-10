//
//  main.m
//  WQ Files
//
//  Proof-of-concept file browser for iOS 27 that reaches other containers
//  through the worse_query sandbox escape by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//  This app is GPL-3.0-or-later as well (see LICENSE).
//

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQUI.h"
#import "WQSharing.h"
#import "WQDir.h"
#import "WQApps.h"
#import "WQCache.h"
#import "WQCore.h"
#import "WQPlistEditor.h"
#import "WQPlistEditorSupport.h"
#import "WQHexViewer.h"

static BOOL wq_looks_like_uuid(NSString *name)
{
    return name.length == 36 && [[NSUUID alloc] initWithUUIDString:name] != nil;
}

static BOOL wq_regular_file_for_ui(NSString *path)
{
    struct stat st;
    if (!wq_stat(path, &st)) return NO;
    // Symbolic links are deliberately not followed: the file APIs use
    // O_NOFOLLOW and the UI must offer the same contract.
    return S_ISREG(st.st_mode);
}

#pragma mark - Item

@interface WQItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *bundleID;  // for the app icon
@property (nonatomic) BOOL isDir;
@property (nonatomic) BOOL isLink;
@property (nonatomic) BOOL isRegular;
@property (nonatomic) unsigned long long size;
@property (nonatomic) mode_t mode;
@property (nonatomic) uid_t uid;
@property (nonatomic, strong) NSDate *modified;
@end

@implementation WQItem
@end

#pragma mark - File viewer

typedef NS_ENUM(NSInteger, WQOpenMode) { WQOpenAuto, WQOpenPlist, WQOpenText, WQOpenHex };
// Opens a file in the fitting viewer (Auto: chosen from its first bytes).
static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode);

typedef NS_ENUM(NSInteger, WQViewKind) { WQViewText, WQViewPlist, WQViewImage, WQViewHex };

static const NSUInteger kViewLimit = 4 * 1024 * 1024;
static const NSUInteger kHexLimit = 64 * 1024;

// Parsing and image creation happen on the I/O queue; the main thread only
// installs the prepared display.
@interface WQFileDisplay : NSObject
@property (nonatomic) BOOL truncated;
@property (nonatomic, strong) NSString *plistText;
@property (nonatomic) NSPropertyListFormat plistFormat;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) NSString *text;
@property (nonatomic, strong) NSString *hexText;
@end
@implementation WQFileDisplay
@end

static NSString *wq_file_hex_dump(NSData *data, BOOL truncated)
{
    NSUInteger len = MIN(data.length, kHexLimit);
    const uint8_t *b = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:len * 4];
    for (NSUInteger off = 0; off < len; off += 16) {
        [out appendFormat:@"%08lx  ", (unsigned long)off];
        NSMutableString *ascii = [NSMutableString new];
        for (NSUInteger i = 0; i < 16; i++) {
            if (off + i < len) {
                uint8_t c = b[off + i];
                [out appendFormat:@"%02x ", c];
                [ascii appendFormat:@"%c", (c >= 0x20 && c < 0x7f) ? c : '.'];
            } else {
                [out appendString:@"   "];
            }
        }
        [out appendFormat:@" %@\n", ascii];
    }
    if (data.length > len || truncated) [out appendString:@"\n…（仅显示开头部分）\n"];
    return out;
}

@interface WQFileViewController : UIViewController <UITextViewDelegate, WQUnsavedEditing>
@property (nonatomic) BOOL readOnly;
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation WQFileViewController {
    NSString *_path;
    UITextView *_textView;
    UIImageView *_imageView;
    UIBarButtonItem *_editButton;
    WQViewKind _kind;
    NSPropertyListFormat _plistFormat;
    BOOL _truncated;
    WQEditState *_editState;
    NSDictionary<NSString *, NSNumber *> *_version;
}


- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _path = [path copy];
        _editState = [WQEditState new];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _textView.editable = NO;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.smartQuotesType = UITextSmartQuotesTypeNo;
    _textView.smartDashesType = UITextSmartDashesTypeNo;
    _textView.alwaysBounceVertical = YES;
    _textView.delegate = self;
    [self.view addSubview:_textView];
    __weak typeof(self) weakSelf = self;
    self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
    _imageView = [UIImageView new];
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.hidden = YES;
    [self.view addSubview:_imageView];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    for (UIView *v in @[_textView, _imageView]) {
        [NSLayoutConstraint activateConstraints:@[
            [v.topAnchor constraintEqualToAnchor:g.topAnchor],
            [v.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
            [v.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [v.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        ]];
    }
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                           target:self action:@selector(share:)];
    UIMenu *openAs = [UIMenu menuWithTitle:@"打开方式" children:@[
        [UIAction actionWithTitle:@"属性列表编辑器" image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenPlist]; }],
        [UIAction actionWithTitle:@"十六进制查看器" image:[UIImage systemImageNamed:@"number"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf reopenAs:WQOpenHex]; }],
    ]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:openAs];
    self.navigationItem.rightBarButtonItems = @[share, more];
    _textView.text = @"加载中…";
    [self load];
}

- (void)load
{
    NSString *path = _path;
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        struct stat st;
        BOOL exists = wq_stat(path, &st);
        NSDictionary *__unused before = wq_file_version(path);
        NSData *data = wq_read(path, kViewLimit + 1, &error);
        NSDictionary *version = wq_file_version(path);
        if (data && (!before || !version || ![before isEqualToDictionary:version])) {
            data = nil;
            error = version ? @"读取过程中文件已改变，请重新打开。"
                            : @"无法确定稳定的文件版本，请重新打开。";
        }
        WQFileDisplay *display = nil;
        if (data) {
            display = [WQFileDisplay new];
            display.truncated = data.length > kViewLimit;
            NSData *view = display.truncated ? [data subdataWithRange:NSMakeRange(0, kViewLimit)] : data;
            if (!display.truncated) {
                NSPropertyListFormat format = 0;
                id plist = [NSPropertyListSerialization propertyListWithData:view options:0 format:&format error:nil];
                if (plist) {
                    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                            format:NSPropertyListXMLFormat_v1_0
                                                                           options:0 error:nil];
                    NSString *text = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : nil;
                    if (text) {
                        display.plistFormat = format;
                        display.plistText = text;
                    }
                }
            }
            if (!display.plistText) {
                display.image = [UIImage imageWithData:view];
                if (!display.image) {
                    NSString *text = [[NSString alloc] initWithData:view encoding:NSUTF8StringEncoding];
                    if (text && ![text containsString:@"\0"]) display.text = text;
                    else display.hexText = wq_file_hex_dump(view, display.truncated);
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_version = version;
            if (!display) {
                NSString *hint = wq_permission_hint(path, NO);
                self->_textView.text = [NSString stringWithFormat:@"无法读取此文件。\n\n%@", hint ?: error];
                return;
            }
            NSString *info = exists
                ? [NSString stringWithFormat:@"%@ · 权限 %o · uid %u", wq_size_text((unsigned long long)st.st_size),
                   st.st_mode & 07777, st.st_uid]
                : @"";
            self.navigationItem.prompt = info.length ? info : nil;
            if (wq_permission_hint(path, YES)) self->_readOnly = YES;   // only the owner may write it
            [self showDisplay:display];
        });
    });
}

- (void)showDisplay:(WQFileDisplay *)display
{
    _truncated = display.truncated;
    if (display.plistText) {
        _kind = WQViewPlist;
        _plistFormat = display.plistFormat;
        _textView.text = display.plistText;
        if (!WQPlistFormatIsWritable(display.plistFormat)) {
            _readOnly = YES;
            NSString *prompt = self.navigationItem.prompt;
            NSString *reason = [NSString stringWithFormat:@"%@ · 只读", WQPlistFormatName(display.plistFormat)];
            self.navigationItem.prompt = prompt.length ? [prompt stringByAppendingFormat:@" · %@", reason] : reason;
        }
        if (!_readOnly) [self enableEditing];
        return;
    }
    if (display.image) {
        _kind = WQViewImage;
        _imageView.image = display.image;
        _imageView.hidden = NO;
        _textView.hidden = YES;
        return;
    }
    if (display.text) {
        _kind = WQViewText;
        _textView.text = display.text;
        if (!_truncated && !_readOnly) [self enableEditing];
        return;
    }
    _kind = WQViewHex;
    _textView.text = display.hexText ?: @"";
}

- (void)updateEditButton
{
    _editButton.title = _textView.editable ? @"保存" : @"编辑";
    _editButton.style = _textView.editable ? wq_primary_button_style() : UIBarButtonItemStylePlain;
    _editButton.enabled = !_editState.saving;
}

- (void)enableEditing
{
    if (_editButton) return;
    _editButton = [[UIBarButtonItem alloc] initWithTitle:@"编辑" style:UIBarButtonItemStylePlain
                                                  target:self action:@selector(toggleEdit:)];
    NSArray *items = self.navigationItem.rightBarButtonItems;
    self.navigationItem.rightBarButtonItems = [items arrayByAddingObject:_editButton];
}

- (void)textViewDidChange:(UITextView *)textView
{
    if (_editState.saving) return;
    [_editState noteChange];
}

- (BOOL)blockWhileSaving
{
    if (!_editState.saving) return NO;
    wq_alert(self, @"正在保存", @"请等待当前保存完成后再离开或继续修改。");
    return YES;
}

- (BOOL)wq_needsLeaveConfirmation
{
    return _editState.dirty || _editState.saving;
}

- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!_editState.dirty) { proceed(); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"放弃更改？"
        message:@"文本更改尚未保存。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self->_editState discard];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        proceed();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)leave
{
    [self confirmLeaveThen:^{ [self.navigationController popViewControllerAnimated:YES]; }];
}

- (void)toggleEdit:(UIBarButtonItem *)sender
{
    if ([self blockWhileSaving]) return;
    if (!_textView.editable) {
        _textView.editable = YES;
        [self updateEditButton];
        [_textView becomeFirstResponder];
        return;
    }
    if (!_editState.dirty) {
        _textView.editable = NO;
        [_textView resignFirstResponder];
        [self updateEditButton];
        return;
    }
    if (!_version) {
        wq_alert(self, @"无法保存", @"此文件没有已验证的版本快照，请重新打开后再保存。");
        return;
    }
    NSData *newData = nil;
    if (_kind == WQViewPlist) {
        NSData *xml = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id plist = xml ? [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:&error] : nil;
        if (!plist) {
            wq_alert(self, @"不是有效的属性列表", error.localizedDescription ?: @"请检查 XML。");
            return;
        }
        newData = [NSPropertyListSerialization dataWithPropertyList:plist format:_plistFormat options:0 error:&error];
        if (!newData) {
            wq_alert(self, @"无法编码", error.localizedDescription ?: @"");
            return;
        }
    } else {
        newData = [_textView.text dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!newData) {
        wq_alert(self, @"无法编码", @"文本无法编码为 UTF-8。");
        return;
    }
    NSString *message = [NSString stringWithFormat:@"%@ 将被就地覆盖，当前版本会先备份到「备份」中。", _path];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"保存更改？" message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        NSUInteger savedRevision = [self->_editState beginSave];
        self->_textView.editable = NO;
        [self->_textView resignFirstResponder];
        [self updateEditButton];
        NSString *path = self->_path;
        NSDictionary *expectedVersion = [self->_version copy];
        dispatch_async(wq_io(), ^{
            NSString *error = nil;
            NSDictionary *newVersion = nil;
            BOOL ok = wq_write_if_unchanged_get_version(path, newData, expectedVersion, &newVersion, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_editState finishSave:ok revision:savedRevision];
                if (ok) self->_version = newVersion;
                self->_textView.editable = self->_editState.dirty;
                [self updateEditButton];
                if (!ok) wq_alert(self, @"保存失败", error ?: wq_permission_hint(path, YES) ?: @"未知错误");
            });
        });
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)share:(UIBarButtonItem *)sender
{
    wq_share(self, _path, nil);
}

- (void)reopenAs:(WQOpenMode)mode
{
    [self confirmLeaveThen:^{
        UINavigationController *nav = self.navigationController;
        NSString *path = self->_path;
        BOOL readOnly = self->_readOnly;
        [nav popViewControllerAnimated:NO];
        wq_open_file(nav, path, readOnly, mode);
    }];
}

@end

#pragma mark - Choosing a viewer

static WQOpenMode wq_sniff(NSData *head)
{
    const uint8_t *b = head.bytes;
    NSUInteger n = head.length;
    if (n >= 7 && memcmp(b, "bplist0", 7) == 0) return WQOpenPlist;
    if ((n >= 8 && memcmp(b, "\x89PNG", 4) == 0) || (n >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) ||
        (n >= 4 && memcmp(b, "GIF8", 4) == 0) || (n >= 12 && memcmp(b + 4, "ftyp", 4) == 0))
        return WQOpenText;   // images: the file viewer renders them
    if (n == 0) return WQOpenText;
    if (memchr(b, 0, n)) return WQOpenHex;
    NSString *text = nil;
    for (NSUInteger cut = 0; cut < 4 && !text && cut < n; cut++)   // the sample may end mid-character
        text = [[NSString alloc] initWithBytes:b length:n - cut encoding:NSUTF8StringEncoding];
    if (!text) return WQOpenHex;
    if ([text containsString:@"<plist"] || [text containsString:@"<!DOCTYPE plist"]) return WQOpenPlist;
    return WQOpenText;
}

static NSUInteger wq_open_generation;

static void wq_open_file(UINavigationController *nav, NSString *path, BOOL readOnly, WQOpenMode mode)
{
    if (!nav || !path.length) return;
    // All calls originate on the main thread. A newer explicit or automatic
    // open invalidates older sniff requests, and leaving the originating screen
    // also prevents a late push.
    NSUInteger request = ++wq_open_generation;
    UIViewController *origin = nav.topViewController;
    void (^push)(WQOpenMode) = ^(WQOpenMode m) {
        if (request != wq_open_generation || nav.topViewController != origin) return;
        UIViewController *vc;
        if (m == WQOpenPlist) {
            WQPlistEditorViewController *editor = [[WQPlistEditorViewController alloc] initWithPath:path readOnly:readOnly];
            __weak UINavigationController *weakNav = nav;
            editor.openAsText = ^{ wq_open_file(weakNav, path, readOnly, WQOpenText); };
            editor.openAsHex = ^{ wq_open_file(weakNav, path, readOnly, WQOpenHex); };
            vc = editor;
        } else if (m == WQOpenHex) {
            vc = [[WQHexViewController alloc] initWithPath:path readOnly:readOnly];
        } else {
            WQFileViewController *file = [[WQFileViewController alloc] initWithPath:path];
            file.readOnly = readOnly;
            vc = file;
        }
        [nav pushViewController:vc animated:YES];
    };
    if (!wq_regular_file_for_ui(path)) {
        UIViewController *host = nav.topViewController;
        struct stat st;
        BOOL link = wq_stat(path, &st) && S_ISLNK(st.st_mode);
        if (host) wq_alert(host, link ? @"符号链接" : @"无法打开此项目",
                           link ? @"WQ 文件在查看、分享或编辑时不会跟随符号链接。"
                                : @"只能查看普通文件。");
        return;
    }
    if (mode != WQOpenAuto) { push(mode); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *head = wq_permission_hint(path, NO) ? nil : wq_read_range(path, 0, 4096, NULL);
        WQOpenMode m = head ? wq_sniff(head) : WQOpenText;   // unreadable: the file viewer shows why
        dispatch_async(dispatch_get_main_queue(), ^{ push(m); });
    });
}

#pragma mark - Folder

static NSString *wq_folder_date_text(NSDate *date)
{
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.locale = NSLocale.autoupdatingCurrentLocale;
    });
    return date ? [formatter stringFromDate:date] : @"";
}

@implementation WQDirViewController {
    NSString *_path;
    NSArray<WQItem *> *_all;     // everything in the folder
    NSArray<WQItem *> *_items;   // what the search lets through (shown)
    NSString *_query;
    UILabel *_pathLabel;
    UIView *_headerBox;
    NSString *_scanStatus;
    CGFloat _headerWidth;
    NSString *_error;
    BOOL _labels;
    BOOL _backupManager;
    BOOL _backupStorage;
    BOOL _selectingBackups;
    NSMutableSet<NSString *> *_selectedBackups;
    UIBarButtonItem *_selectItem;
    UIBarButtonItem *_menuItem;
    UIBarButtonItem *_doneItem;
    UIBarButtonItem *_deleteItem;
    UIBarButtonItem *_allItem;
    NSString *_baseTitle;
    WQScanCancellation *_scanCancellation;
    NSUInteger _scanGeneration;
    BOOL _scanInFlight;
    BOOL _scanNeedsRefresh;
    NSTimeInterval _lastReloadFinished;
}

- (instancetype)initWithPath:(NSString *)path title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = [path copy];
        self.title = title ?: (path.lastPathComponent.length ? path.lastPathComponent : @"/");
        _baseTitle = self.title;
        _selectedBackups = [NSMutableSet new];
        // Container parents: show bundle/group identifiers instead of UUIDs.
        NSString *parent = path.lastPathComponent;
        _labels = [@[@"Application", @"AppGroup", @"PluginKitPlugin", @"InternalDaemon", @"System"] containsObject:parent];
        NSString *appBackups = wq_app_backup_root();
        NSString *fileBackups = wq_backup_root();
        _backupManager = appBackups.length &&
            ([_path isEqualToString:appBackups] || [_path hasPrefix:[appBackups stringByAppendingString:@"/"]]);
        _backupStorage = _backupManager ||
            (fileBackups.length && ([_path isEqualToString:fileBackups] || [_path hasPrefix:[fileBackups stringByAppendingString:@"/"]]));
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];
    __weak typeof(self) weakSelf = self;
    NSString *path = _path;
    NSMutableArray<UIMenuElement *> *menuItems = [NSMutableArray new];
    if (!self.readOnly && !_backupStorage) {
        [menuItems addObject:[UIAction actionWithTitle:@"新建文件夹" image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf promptNewFolder]; }]];
        [menuItems addObject:[UIAction actionWithTitle:@"导入文件" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf importFile]; }]];
    }
    [menuItems addObject:[UIAction actionWithTitle:@"拷贝路径" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                          handler:^(UIAction *__unused a) { UIPasteboard.generalPasteboard.string = path; }]];
    _menuItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                 menu:[UIMenu menuWithChildren:menuItems]];
    if (_backupStorage) {
        _selectItem = [[UIBarButtonItem alloc] initWithTitle:@"选择" style:UIBarButtonItemStylePlain
                                                       target:self action:@selector(enterBackupSelection)];
        _selectItem.enabled = NO;
        self.navigationItem.rightBarButtonItems = @[_selectItem, _menuItem];
    } else {
        self.navigationItem.rightBarButtonItem = _menuItem;
    }
    [self updateHeader];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = _labels ? @"搜索名称和 Bundle ID" : @"搜索此文件夹";
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (_scanInFlight) return;
    NSTimeInterval age = NSDate.date.timeIntervalSinceReferenceDate - _lastReloadFinished;
    if (_scanNeedsRefresh || _lastReloadFinished <= 0 || age > 2.0) [self reload];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (_selectingBackups) [self exitBackupSelection];
    if (_scanInFlight) {
        _scanNeedsRefresh = YES;
        [_scanCancellation cancel];
    }
    _scanStatus = nil;
    [self.refreshControl endRefreshing];
    [self updateHeader];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (!self.presentedViewController && self.navigationController.topViewController != self) {
        wq_share_cancel(self);
    }
}

// Device strip, then the full path in normal-size text that wraps at the
// slashes (the navigation bar's prompt shrank it until unreadable). Tap to copy.
- (void)updateHeader
{
    CGFloat width = self.tableView.bounds.size.width ?: self.view.bounds.size.width;
    if (!_pathLabel) {
        _pathLabel = [UILabel new];
        _pathLabel.numberOfLines = 0;
        _pathLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        _pathLabel.textColor = UIColor.secondaryLabelColor;
        _pathLabel.userInteractionEnabled = YES;
        [_pathLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyPath)]];
    }
    if (!_headerBox) {
        _headerBox = wq_device_header(width);
        [_headerBox addSubview:_pathLabel];
        self.tableView.tableHeaderView = _headerBox;
    }
    // Zero-width spaces after each slash let lines break between components.
    NSString *breakable = [_path stringByReplacingOccurrencesOfString:@"/" withString:@"/\u200B"];
    _pathLabel.text = _scanStatus ? [NSString stringWithFormat:@"%@\n%@", breakable, _scanStatus] : breakable;
    CGFloat side = 16, top = 42;
    CGSize fit = [_pathLabel sizeThatFits:CGSizeMake(width - 2 * side, CGFLOAT_MAX)];
    CGFloat height = top + ceil(fit.height) + 10;
    CGFloat oldHeight = _headerBox.frame.size.height;
    _headerBox.frame = CGRectMake(0, 0, width, height);
    _pathLabel.frame = CGRectMake(side, top, width - 2 * side, ceil(fit.height));
    _headerWidth = width;
    if (fabs(height - oldHeight) > 0.5) self.tableView.tableHeaderView = _headerBox;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (fabs(self.tableView.bounds.size.width - _headerWidth) > 0.5) [self updateHeader];
}

- (void)copyPath
{
    UIPasteboard.generalPasteboard.string = _path;
    _scanStatus = @"已拷贝路径";
    [self updateHeader];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self->_scanStatus isEqualToString:@"已拷贝路径"]) { self->_scanStatus = nil; [self updateHeader]; }
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    _query = q.length ? q : nil;
    [self applyFilter];
    [self.tableView reloadData];
}

// App name, bundle or group ID, or file name; case and accents ignored.
- (void)applyFilter
{
    if (!_query) { _items = _all; return; }
    NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSString *q = _query;
    _items = [_all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WQItem *item, NSDictionary *__unused b) {
        for (NSString *field in @[item.label ?: @"", item.name ?: @"", item.bundleID ?: @""])
            if ([field rangeOfString:q options:opts].location != NSNotFound) return YES;
        return NO;
    }]];
}

#pragma mark Backup multi-selection

- (NSArray<NSString *> *)backupUnitPathsInItems
{
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    for (WQItem *item in _items)
        if (wq_backup_unit_deletable(item.path)) [paths addObject:item.path];
    return paths;
}

- (void)updateBackupSelectionAvailability
{
    _selectItem.enabled = !_selectingBackups && [self backupUnitPathsInItems].count > 0;
}

- (void)updateBackupSelectionBar
{
    _deleteItem.enabled = _selectedBackups.count > 0;
    _allItem.enabled = _selectedBackups.count < [self backupUnitPathsInItems].count;
}

- (void)enterBackupSelection
{
    if ([self backupUnitPathsInItems].count == 0) {
        wq_alert(self, @"没有可选择的项目", @"此处只能选择完整的备份文件夹。");
        return;
    }
    _selectingBackups = YES;
    [_selectedBackups removeAllObjects];
    if (!_doneItem) {
        _doneItem = [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleProminent
                                                       target:self action:@selector(exitBackupSelection)];
        _deleteItem = [[UIBarButtonItem alloc] initWithTitle:@"删除" style:UIBarButtonItemStylePlain
                                                       target:self action:@selector(deleteSelectedBackups)];
        _deleteItem.tintColor = UIColor.systemRedColor;
        _allItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle"]
                                                     style:UIBarButtonItemStylePlain
                                                    target:self action:@selector(selectAllBackups)];
        _allItem.accessibilityLabel = @"全选";
    }
    self.refreshControl.enabled = NO;
    self.tableView.allowsMultipleSelection = YES;
    self.title = @"选择备份";
    self.navigationItem.rightBarButtonItems = @[_allItem, _deleteItem, _doneItem];
    [self updateBackupSelectionBar];
    [self.tableView reloadData];
}

- (void)exitBackupSelection
{
    if (!_selectingBackups) return;
    _selectingBackups = NO;
    [_selectedBackups removeAllObjects];
    self.tableView.allowsMultipleSelection = NO;
    self.refreshControl.enabled = YES;
    self.title = _baseTitle;
    self.navigationItem.rightBarButtonItems = _backupStorage ? @[_selectItem, _menuItem] : nil;
    if (!_backupStorage) self.navigationItem.rightBarButtonItem = _menuItem;
    [self.tableView reloadData];
    [self updateBackupSelectionAvailability];
}

- (void)selectAllBackups
{
    NSArray<NSString *> *paths = [self backupUnitPathsInItems];
    [_selectedBackups addObjectsFromArray:paths];
    [self updateBackupSelectionBar];
    [self.tableView reloadData];
}

- (void)deleteSelectedBackups
{
    NSArray<NSString *> *paths = [_selectedBackups.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (paths.count == 0) return;
    NSString *message = [NSString stringWithFormat:
        @"这将永久删除 %lu 个完整备份及其中的全部内容，且无法撤销。",
        (unsigned long)paths.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除备份？"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                              handler:^(UIAlertAction *__unused a) {
        [self exitBackupSelection];
        [self runIO:^BOOL(NSString **error) {
            NSString *first = nil;
            for (NSString *path in paths) {
                NSString *failure = nil;
                if (!wq_delete_backup(path, &failure) && first == nil)
                    first = failure ?: @"无法删除某个备份。";
            }
            if (first) {
                if (error) *error = [NSString stringWithFormat:@"%@ 部分已选备份可能仍然存在。", first];
                return NO;
            }
            return YES;
        } failure:@"无法删除备份"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Pull to refresh: container lists are scanned again instead of reused.
- (void)userRefresh
{
    wq_enumerate_invalidate();
    wq_display_names_reset_miss();
    [self reload];
}

- (void)reload
{
    [_scanCancellation cancel];
    WQScanCancellation *cancellation = [WQScanCancellation new];
    _scanCancellation = cancellation;
    NSUInteger generation = ++_scanGeneration;
    _scanInFlight = YES;
    _scanNeedsRefresh = NO;
    _scanStatus = nil;
    [self.refreshControl endRefreshing];
    [self updateHeader];
    NSString *path = _path;
    BOOL labels = _labels;
    BOOL enumerable = [@[@"/private/var/mobile/Containers/Data/Application",
                         @"/var/mobile/Containers/Data/Application",
                         @"/private/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/var/mobile/Containers/Data/PluginKitPlugin",
                         @"/private/var/mobile/Containers/Data/InternalDaemon",
                         @"/var/mobile/Containers/Data/InternalDaemon",
                         // Listable on iOS 27; on iOS 26 only by scanning.
                         @"/private/var/mobile/Containers/Shared/AppGroup",
                         @"/var/mobile/Containers/Shared/AppGroup"] containsObject:path];
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        NSArray *names = wq_list(path, &error);
        NSArray *childPaths = nil;
        // Parent gives no token on 27.x: discover children with fsgetpath.
        if (!names && enumerable && !cancellation.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = @"正在扫描 inode…";
                [self updateHeader];
            });
            CFAbsoluteTime scanStarted = CFAbsoluteTimeGetCurrent();
            childPaths = wq_enumerate(path, 0, cancellation, ^(int64_t done, int64_t total, NSUInteger __unused f) {
                // Time left, once the rate is known: an iOS 26 id scan can take most of an hour.
                double elapsed = CFAbsoluteTimeGetCurrent() - scanStarted;
                NSString *left = @"";
                if (elapsed > 5 && done > 0 && done < total) {
                    double remaining = elapsed * (double)(total - done) / (double)done;
                    left = remaining >= 90 ? [NSString stringWithFormat:@" · 预计还需 %.0f 分钟", ceil(remaining / 60)]
                                           : @" · 剩余不到 2 分钟";
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_scanStatus = [NSString stringWithFormat:@"正在扫描 inode… %lld%% · 已找到 %lu 个%@",
                                         total ? (long long)(done * 100 / total) : 0, (unsigned long)f, left];
                    [self updateHeader];
                });
            });
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                self->_scanStatus = nil;
                [self updateHeader];
            });
        }
        if (cancellation.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_scanGeneration) return;
                self->_scanInFlight = NO;
                self->_scanNeedsRefresh = YES;
                self->_scanStatus = nil;
                [self.refreshControl endRefreshing];
                [self updateHeader];
            });
            return;
        }
        NSMutableArray<WQItem *> *items = [NSMutableArray new];
        NSUInteger labelIssues = 0;
        NSArray *entries = names ?: childPaths;
        BOOL haveFullPaths = names == nil;
        NSUInteger entryIndex = 0, entryCount = entries.count;
        for (NSString *entry in entries) {
            entryIndex++;
            // Each container needs a token and its identifier: hundreds take a
            // few seconds, so show where it is.
            if (haveFullPaths && (entryIndex == 1 || entryIndex % 10 == 0)) {
                NSUInteger shown = entryIndex;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration || cancellation.isCancelled) return;
                    self->_scanStatus = [NSString stringWithFormat:@"正在读取容器… %lu / %lu",
                                         (unsigned long)shown, (unsigned long)entryCount];
                    [self updateHeader];
                });
            }
            if (cancellation.isCancelled) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_scanGeneration) return;
                    self->_scanInFlight = NO;
                    self->_scanNeedsRefresh = YES;
                    self->_scanStatus = nil;
                    [self.refreshControl endRefreshing];
                    [self updateHeader];
                });
                return;
            }
            WQItem *item = [WQItem new];
            item.name = haveFullPaths ? entry.lastPathComponent : entry;
            item.path = haveFullPaths ? entry : [path stringByAppendingPathComponent:entry];
            NSString *name = item.name;
            // Enumerated containers need a token before they can be stat'd.
            if (haveFullPaths) {
                item.isDir = YES;
                BOOL token = wq_grant(item.path);
                NSString *bid = token ? wq_container_label(item.path) : nil;
                item.bundleID = bid;
                if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                item.label = token ? (wq_display_name(bid) ?: bid ?: @"（无标签）") : @"无令牌";
                if (!token && labelIssues < 3) {
                    wq_log(@"label: no token for %@", item.path);
                    labelIssues++;
                } else if (token && !bid.length && labelIssues < 3) {
                    wq_log(@"label: no container identifier for %@", item.path);
                    labelIssues++;
                }
            }
            struct stat st;
            if (lstat(item.path.fileSystemRepresentation, &st) == 0) {
                item.isLink = S_ISLNK(st.st_mode);
                item.isDir = S_ISDIR(st.st_mode);
                item.isRegular = S_ISREG(st.st_mode);
                item.size = (unsigned long long)st.st_size;
                item.mode = st.st_mode;
                item.uid = st.st_uid;
                item.modified = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec];
            }
            if (!haveFullPaths && labels && item.isDir && wq_looks_like_uuid(name)) {
                NSString *bid = wq_container_label(item.path);
                item.bundleID = bid;
                if (bid) (void)wq_app_icon(bid);   // warm the icon off the main thread
                item.label = wq_display_name(bid) ?: bid;
            }
            if (!haveFullPaths && item.isDir && !item.bundleID) {
                // App backups: AppBackups/<bundle id>/...
                if ([path.lastPathComponent isEqualToString:@"AppBackups"]) {
                    item.bundleID = name;
                    item.label = wq_display_name(name) ?: name;
                }
                // File backups mirror the original path; label container UUIDs
                // from the live container they came from.
                NSString *live = wq_backup_original_path(item.path);
                if (live && wq_looks_like_uuid(name)) {
                    NSString *bid = wq_container_label(live);
                    if (bid) { item.bundleID = bid; item.label = wq_display_name(bid) ?: bid; (void)wq_app_icon(bid); }
                }
                if ([path isEqualToString:wq_backup_root().stringByDeletingLastPathComponent]) {
                    if ([name isEqualToString:@"Backups"]) item.label = @"文件备份";
                    if ([name isEqualToString:@"AppBackups"]) item.label = @"App 备份";
                }
            }
            [items addObject:item];
        }
        [items sortUsingComparator:^NSComparisonResult(WQItem *a, WQItem *b) {
            if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
            return [(a.label ?: a.name) localizedCaseInsensitiveCompare:(b.label ?: b.name)];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_scanGeneration) return;
            self->_scanInFlight = NO;
            if (cancellation.isCancelled) {
                self->_scanNeedsRefresh = YES;
                self->_scanStatus = nil;
                [self.refreshControl endRefreshing];
                [self updateHeader];
                return;
            }
            self->_all = items;
            [self applyFilter];
            self->_error = (names || childPaths != nil) ? nil
                : (error.length ? error : @"无法列出此文件夹：容器枚举失败，请查看日志。");
            self->_scanStatus = nil;
            self->_lastReloadFinished = NSDate.date.timeIntervalSinceReferenceDate;
            [self.refreshControl endRefreshing];
            [self updateHeader];
            [self.tableView reloadData];
            [self updateBackupSelectionAvailability];
            if (self->_selectingBackups) [self updateBackupSelectionBar];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return _error ? 1 : (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (_error) {
        c.text = @"无法打开此文件夹";
        BOOL container = [_path containsString:@"/Containers/"] || [_path containsString:@"/SystemGroup/"];
        c.secondaryText = container ? _error
            : [NSString stringWithFormat:@"%@\n\n此方式只能打开容器。要访问 /private/var 内的文件夹，"
               "请使用「App 数据」「App 群组」「扩展数据」「内部守护进程」或「系统群组」。", _error];
        c.secondaryTextProperties.numberOfLines = 0;
        c.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQItem *item = _items[(NSUInteger)indexPath.row];
    c.text = item.label ?: item.name;
    NSString *date = wq_folder_date_text(item.modified);
    NSString *detail = item.isDir ? date : [NSString stringWithFormat:@"%@ · %@", wq_size_text(item.size), date];
    if (item.label) detail = [NSString stringWithFormat:@"%@\n%@", item.name, detail];
    if (item.isLink) detail = [@"符号链接 · " stringByAppendingString:detail];
    c.secondaryText = detail;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    UIImage *appIcon = item.bundleID ? wq_app_icon(item.bundleID) : nil;
    c.image = appIcon ?: [UIImage systemImageNamed:item.isDir ? @"folder.fill" : (item.isLink ? @"link" : @"doc")];
    if (appIcon) c.imageProperties.maximumSize = CGSizeMake(36, 36);
    cell.contentConfiguration = c;
    if (_selectingBackups) {
        BOOL selectable = wq_backup_unit_deletable(item.path);
        cell.accessoryType = selectable && [_selectedBackups containsObject:item.path]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryType = item.isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_error || indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    if (!_selectingBackups) return indexPath;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    return wq_backup_unit_deletable(item.path) ? indexPath : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_selectingBackups) {
        if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
        WQItem *selected = _items[(NSUInteger)indexPath.row];
        if (!wq_backup_unit_deletable(selected.path)) return;
        [_selectedBackups addObject:selected.path];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [self updateBackupSelectionBar];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_error) return;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    UIViewController *next;
    if (item.isLink) {
        wq_alert(self, @"符号链接",
                 @"WQ 文件在查看、分享或编辑时不会跟随符号链接。可先「拷贝路径」再显式打开目标。");
        return;
    }
    if (item.isDir) {
        WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:item.path title:item.label ?: item.name];
        dir.readOnly = self.readOnly;
        next = dir;
    } else {
        if (!item.isRegular) {
            wq_alert(self, @"无法打开此项目", item.isLink
                     ? @"查看、分享或编辑时不会跟随符号链接。"
                     : @"只能查看普通文件。");
            return;
        }
        _scanNeedsRefresh = YES;
        wq_open_file(self.navigationController, item.path, self.readOnly, WQOpenAuto);
        return;
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_selectingBackups) return;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    [_selectedBackups removeObject:item.path];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateBackupSelectionBar];
}

// Swipe left or right to delete, with the same rules and confirmation as the
// long-press menu (files are backed up first; backups only as whole units).
- (UISwipeActionsConfiguration *)deleteSwipeForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_selectingBackups || _error) return nil;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    BOOL backupUnit = item.isDir && wq_backup_unit_deletable(item.path);
    BOOL regular = !self.readOnly && !_backupStorage;
    if (!backupUnit && !regular) return nil;
    NSString *itemPath = [item.path copy];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *__unused a, UIView *__unused view, void (^done)(BOOL)) {
        WQDirViewController *strongSelf = weakSelf;
        WQItem *current = nil;
        if (strongSelf && (NSUInteger)indexPath.row < strongSelf->_items.count &&
            [strongSelf->_items[(NSUInteger)indexPath.row].path isEqualToString:itemPath])
            current = strongSelf->_items[(NSUInteger)indexPath.row];
        // The row stays until the confirmed delete reloads the folder.
        done(NO);
        if (!current) return;
        if (backupUnit) [strongSelf confirmDeleteBackup:current];
        else [strongSelf confirmDelete:current];
    }];
    action.image = [UIImage systemImageNamed:@"trash"];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self deleteSwipeForRowAtIndexPath:indexPath];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [self deleteSwipeForRowAtIndexPath:indexPath];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (_selectingBackups || _error) return nil;
    if (indexPath.section != 0 || (NSUInteger)indexPath.row >= _items.count) return nil;
    WQItem *item = _items[(NSUInteger)indexPath.row];
    NSString *itemPath = [item.path copy];
    __weak typeof(self) weakSelf = self;
    WQItem *(^currentItem)(void) = ^WQItem *{
        WQDirViewController *strongSelf = weakSelf;
        if (!strongSelf || indexPath.section != 0 || (NSUInteger)indexPath.row >= strongSelf->_items.count) return nil;
        WQItem *current = strongSelf->_items[(NSUInteger)indexPath.row];
        return [current.path isEqualToString:itemPath] ? current : nil;
    };
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *__unused suggested) {
        WQItem *current = currentItem();
        WQDirViewController *strongSelf = weakSelf;
        if (!current || !strongSelf) return nil;
        NSMutableArray *actions = [NSMutableArray new];
        if (current.isDir) {
            [actions addObject:[UIAction actionWithTitle:@"以 ZIP 分享（AirDrop…）" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (latest && weakSelf) wq_share_folder(weakSelf, latest.path, nil, cell);
            }]];
        }
        if (!current.isDir && current.isRegular) {
            [actions addObject:[UIAction actionWithTitle:@"分享" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                UITableViewCell *cell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if (latest && weakSelf) wq_share(weakSelf, latest.path, cell);
            }]];
            NSString *original = wq_backup_original_path(current.path);
            if (original) {
                [actions addObject:[UIAction actionWithTitle:@"还原到原位置"
                                                       image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                                  identifier:nil handler:^(UIAction *__unused a) {
                    WQItem *latest = currentItem();
                    if (latest && weakSelf) [weakSelf restoreBackup:latest.path to:original];
                }]];
            }
        }
        if (!current.isDir && current.isRegular) {
            BOOL ro = weakSelf.readOnly;
            [actions addObject:[UIMenu menuWithTitle:@"打开方式" image:[UIImage systemImageNamed:@"arrow.up.forward.app"] identifier:nil
                                             options:0 children:@[
                [UIAction actionWithTitle:@"属性列表编辑器" image:[UIImage systemImageNamed:@"list.bullet.indent"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenPlist); }],
                [UIAction actionWithTitle:@"文本 / 图片" image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenText); }],
                [UIAction actionWithTitle:@"十六进制查看器" image:[UIImage systemImageNamed:@"number"] identifier:nil
                                  handler:^(UIAction *__unused a) { WQDirViewController *strongSelf = weakSelf; WQItem *latest = currentItem(); if (strongSelf && latest) wq_open_file(strongSelf.navigationController, latest.path, ro, WQOpenHex); }],
            ]]];
        }
        [actions addObject:[UIAction actionWithTitle:@"拷贝路径" image:[UIImage systemImageNamed:@"doc.on.doc"]
                                          identifier:nil handler:^(UIAction *__unused a) {
            WQItem *latest = currentItem();
            if (latest) UIPasteboard.generalPasteboard.string = latest.path;
        }]];
        if (current.label) {
            [actions addObject:[UIAction actionWithTitle:@"拷贝标识符" image:[UIImage systemImageNamed:@"tag"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) UIPasteboard.generalPasteboard.string = latest.bundleID ?: latest.label;
            }]];
        }
        if (current.isDir && wq_backup_unit_deletable(current.path)) {
            UIAction *remove = [UIAction actionWithTitle:@"删除备份…" image:[UIImage systemImageNamed:@"trash"]
                                              identifier:nil handler:^(UIAction *__unused a) {
                WQItem *latest = currentItem();
                if (latest) [weakSelf confirmDeleteBackup:latest];
            }];
            remove.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:remove];
        }
        if (!strongSelf.readOnly && !strongSelf->_backupStorage) {
            [actions addObject:[UIAction actionWithTitle:@"重命名" image:[UIImage systemImageNamed:@"pencil"]
                                              identifier:nil handler:^(UIAction *__unused a) { WQItem *latest = currentItem(); if (latest) [weakSelf promptRename:latest]; }]];
            UIAction *del = [UIAction actionWithTitle:@"删除" image:[UIImage systemImageNamed:@"trash"]
                                           identifier:nil handler:^(UIAction *__unused a) { WQItem *latest = currentItem(); if (latest) [weakSelf confirmDelete:latest]; }];
            del.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:del];
        }
        return [UIMenu menuWithChildren:actions];
    }];
}

#pragma mark Actions

- (void)runIO:(BOOL (^)(NSString **error))work failure:(NSString *)failureTitle
{
    dispatch_async(wq_io(), ^{
        NSString *error = nil;
        BOOL ok = work(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) wq_alert(self, failureTitle, error ?: @"未知错误");
            [self reload];
        });
    });
}

- (void)promptNewFolder
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件夹" message:_path
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"名称"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [self->_path stringByAppendingPathComponent:name];
        [self runIO:^BOOL(NSString **error) { return wq_create_dir(path, error); } failure:@"无法创建文件夹"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptRename:(WQItem *)item
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名" message:item.path
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = item.name; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        [self runIO:^BOOL(NSString **error) { return wq_rename(item.path, name, error); } failure:@"无法重命名"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteBackup:(WQItem *)item
{
    BOOL bundle = [item.path.stringByDeletingLastPathComponent isEqualToString:wq_app_backup_root()];
    NSString *message = bundle
        ? [NSString stringWithFormat:@"%@\n\n这将删除此应用的所有备份，且无法撤销。", item.path]
        : [NSString stringWithFormat:@"%@\n\n这将删除所选备份，且无法撤销。", item.path];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除备份？"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) { return wq_delete_backup(item.path, error); } failure:@"无法删除备份"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDelete:(WQItem *)item
{
    NSString *message;
    if (item.isLink) {
        message = [NSString stringWithFormat:@"%@\n\n仅删除符号链接本身，不会改动其目标。", item.path];
    } else if (item.isDir) {
        message = [NSString stringWithFormat:@"%@\n\n只能删除空文件夹。", item.path];
    } else if (item.isRegular) {
        message = [NSString stringWithFormat:@"%@\n\nA copy is kept in Backups.", item.path];
    } else {
        message = [NSString stringWithFormat:@"%@\n\n这个特殊文件将被删除，不会保留备份。", item.path];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"删除「%@」？", item.name]
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) { return wq_delete(item.path, error); } failure:@"无法删除"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreBackup:(NSString *)backup to:(NSString *)original
{
    NSString *message = [NSString stringWithFormat:@"将此备份写回\n%@？\n\n若该位置现有文件，会先备份。", original];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"还原" message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"还原" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
        [self runIO:^BOOL(NSString **error) {
            struct stat st;
            return wq_stat(original, &st) ? wq_write_from_file(original, backup, error)
                                          : wq_create_file_from(original, backup, error);
        } failure:@"还原失败"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importFile
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    // The picker hands over a local copy (asCopy). It is streamed into place,
    // never read into memory, and the existence check runs off the main thread.
    NSString *source = urls.firstObject.path;
    if (!source) return;
    NSString *dest = [_path stringByAppendingPathComponent:source.lastPathComponent];
    void (^cleanup)(void) = ^{ [NSFileManager.defaultManager removeItemAtPath:source error:nil]; };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct stat st;
        BOOL exists = wq_stat(dest, &st);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!exists) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_create_file_from(dest, source, error);
                    cleanup();
                    return ok;
                } failure:@"导入失败"];
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"替换现有文件？"
                message:[NSString stringWithFormat:@"%@ 已存在，替换前会先备份。", dest]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction *__unused a) { cleanup(); }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"替换" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *__unused a) {
                [self runIO:^BOOL(NSString **error) {
                    BOOL ok = wq_write_from_file(dest, source, error);
                    cleanup();
                    return ok;
                } failure:@"导入失败"];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end

#pragma mark - System groups

// The SystemGroup parent gets no token on 27.0.1, so it cannot be listed.
// Known container names are checked one by one (lstat works without access).
@interface WQSystemGroupsViewController : UITableViewController
@end

@implementation WQSystemGroupsViewController {
    NSArray<NSString *> *_names;
    BOOL _listed;
}

static NSString *const kSystemGroupRoot = @"/private/var/containers/Shared/SystemGroup";

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"系统群组";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self action:@selector(tryName)];
    dispatch_async(wq_io(), ^{
        NSArray *listed = wq_list(kSystemGroupRoot, NULL);
        NSArray *names = listed;
        if (!names) {
            NSArray *known = @[
                @"systemgroup.com.apple.configurationprofiles", @"systemgroup.com.apple.mobilegestaltcache",
                @"systemgroup.com.apple.osanalytics", @"systemgroup.com.apple.lsd.iconscache",
                @"systemgroup.com.apple.lsd.identifiers", @"systemgroup.com.apple.ManagedSettings",
                @"systemgroup.com.apple.sharedpclogging", @"systemgroup.com.apple.media.shared.books",
                @"systemgroup.com.apple.nsurlstoragedresources", @"systemgroup.com.apple.pisco.suinfo",
                @"systemgroup.com.apple.icloud.findmydevice.managed", @"systemgroup.com.apple.mobilestoragemounter",
                @"systemgroup.com.apple.mobileactivationd", @"systemgroup.com.apple.sensorkit",
                @"systemgroup.com.apple.powerlog", @"systemgroup.com.apple.diagnosticextensionsd",
                @"systemgroup.com.apple.mediaanalysisd", @"systemgroup.com.apple.translationd",
                @"systemgroup.com.apple.chronod", @"systemgroup.com.apple.coreaudio",
                @"systemgroup.com.apple.ManagedConfiguration.ExternalTrust", @"systemgroup.com.apple.cfprefsd",
            ];
            NSMutableArray *found = [NSMutableArray new];
            for (NSString *name in known) {
                struct stat st;
                NSString *p = [kSystemGroupRoot stringByAppendingPathComponent:name];
                if (lstat(p.fileSystemRepresentation, &st) == 0) [found addObject:name];
            }
            names = found;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_listed = listed != nil;
            self->_names = [names sortedArrayUsingSelector:@selector(compare:)];
            [self.tableView reloadData];
        });
    });
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (!_names) return @"加载中…";
    return _listed ? nil : @"此 iOS 版本无法列出该文件夹。下方显示已确认存在的名称，点 + 可尝试其他名称。";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_names.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"g"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"g"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.text = [_names[(NSUInteger)indexPath.row] stringByReplacingOccurrencesOfString:@"systemgroup." withString:@""];
    c.image = [UIImage systemImageNamed:@"folder.fill"];
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = _names[(NSUInteger)indexPath.row];
    [self.navigationController pushViewController:[[WQDirViewController alloc]
        initWithPath:[kSystemGroupRoot stringByAppendingPathComponent:name] title:nil] animated:YES];
}

- (void)tryName
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"打开系统群组" message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = @"systemgroup.com.apple.";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0 || [name containsString:@"/"]) return;
        NSString *path = [kSystemGroupRoot stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0) {
            wq_alert(self, @"未找到", path);
            return;
        }
        [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil] animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Log

@interface WQLogViewController : UIViewController
@end

@implementation WQLogViewController {
    UITextView *_textView;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"日志";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:_textView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                           target:self action:@selector(share:)];
}

// App version, device and iOS first, so a Log someone sends in says where it
// came from.
- (NSString *)fullLog
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"WQ Files %@ (%@)\n%@\n\n%@",
            info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?", wq_device_line(), wq_log_text()];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _textView.text = [self fullLog];
}

- (void)share:(UIBarButtonItem *)sender
{
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[self fullLog]]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

@end

#pragma mark - Navigation

// Adds a Home button next to Back on screens two or more levels deep. Editors
// guard Back, Home and the interactive edge swipe through WQUnsavedEditing.
@interface WQNavigationController : UINavigationController <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@end

@implementation WQNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.delegate = self;
    self.interactivePopGestureRecognizer.delegate = self;
}

- (void)navigationController:(UINavigationController *)nav willShowViewController:(UIViewController *)vc animated:(BOOL)animated
{
    NSUInteger depth = [nav.viewControllers indexOfObject:vc];
    if (depth == NSNotFound || depth < 2) {
        if (vc.navigationItem.leftBarButtonItem.tag == 0x484f4d45) vc.navigationItem.leftBarButtonItem = nil;
        return;
    }
    if (vc.navigationItem.leftBarButtonItem) return;
    UIBarButtonItem *home = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"house"]
                                                             style:UIBarButtonItemStylePlain target:self action:@selector(goHome)];
    home.tag = 0x484f4d45;   // "HOME"
    home.accessibilityLabel = @"主目录";
    vc.navigationItem.leftItemsSupplementBackButton = YES;
    vc.navigationItem.leftBarButtonItem = home;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer != self.interactivePopGestureRecognizer) return YES;
    if (self.viewControllers.count <= 1) return NO;
    UIViewController<WQUnsavedEditing> *editor = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    if (![editor conformsToProtocol:@protocol(WQUnsavedEditing)] || !editor.wq_needsLeaveConfirmation) return YES;
    __weak typeof(self) weakSelf = self;
    [editor confirmLeaveThen:^{ [weakSelf popViewControllerAnimated:YES]; }];
    return NO;
}

- (void)goHome
{
    UIViewController<WQUnsavedEditing> *top = (UIViewController<WQUnsavedEditing> *)self.topViewController;
    __weak typeof(self) weakSelf = self;
    void (^home)(void) = ^{ [weakSelf popToRootViewControllerAnimated:YES]; };
    if ([top conformsToProtocol:@protocol(WQUnsavedEditing)]) [top confirmLeaveThen:home];
    else home();
}

@end

#pragma mark - Root

@interface WQRootViewController : UITableViewController
@end

@implementation WQRootViewController {
    NSArray<NSArray<NSString *> *> *_locations;  // title, path, symbol
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"WQ 文件";
        _locations = @[
            @[@"App 数据", @"/private/var/mobile/Containers/Data/Application", @"square.grid.2x2"],
            @[@"App 群组", @"/private/var/mobile/Containers/Shared/AppGroup", @"square.stack.3d.up"],
            @[@"扩展数据", @"/private/var/mobile/Containers/Data/PluginKitPlugin", @"puzzlepiece.extension"],
            @[@"内部守护进程", @"/private/var/mobile/Containers/Data/InternalDaemon", @"gearshape.2"],
        ];
        if (wq_system_areas_reachable())
            _locations = [_locations arrayByAddingObject:@[@"系统数据", @"/private/var/containers/Data/System", @"cpu"]];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.tableFooterView = [self authorFooter];
    dispatch_async(wq_io(), ^{
        NSString *recovery = wq_recover_interrupted_restore();
        if (recovery) {
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_alert(self, @"还原恢复", recovery);
            });
        }
        NSString *group = wq_app_group();
        if (!group) {
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_alert(self, @"缺少 App 群组",
                         @"本应用需要 App 群组权限才能访问其他文件夹。请使用会保留 App Group 权限的工具重新签名。");
            });
        }
    });
}

// "by kolbicz" with GitHub and X links, under the last section.
- (UIView *)authorFooter
{
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 128)];
    UILabel *by = [UILabel new];
    by.text = @"WQ Files · 原作者 kolbicz";
    by.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    by.textColor = UIColor.secondaryLabelColor;

    UIButton *(^link)(NSString *, NSString *, NSString *) = ^UIButton *(NSString *title, NSString *symbol, NSString *url) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration tintedButtonConfiguration];
        cfg.title = title;
        cfg.image = [UIImage systemImageNamed:symbol];
        cfg.imagePadding = 6;
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        cfg.buttonSize = UIButtonConfigurationSizeSmall;
        return [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
        }]];
    };
    UIStackView *links = [[UIStackView alloc] initWithArrangedSubviews:@[
        link(@"GitHub", @"chevron.left.forwardslash.chevron.right", @"https://github.com/kolbicz"),
        link(@"@_kolbicz", @"at", @"https://x.com/_kolbicz"),
    ]];
    links.spacing = 12;

    UIButtonConfiguration *creditCfg = [UIButtonConfiguration plainButtonConfiguration];
    creditCfg.attributedTitle = [[NSAttributedString alloc] initWithString:@"沙盒利用：worse_query（作者 @forcequitOS）"
        attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]}];
    creditCfg.buttonSize = UIButtonConfigurationSizeSmall;
    UIButton *credit = [UIButton buttonWithConfiguration:creditCfg primaryAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://x.com/forcequitOS"] options:@{} completionHandler:nil];
    }]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[by, links, credit]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
    ]];
    return footer;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // System Groups is the extra last row, on iOS 27 only.
    return section == 0 ? (NSInteger)_locations.count + (wq_system_areas_reachable() ? 1 : 0) : 6;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? @"容器" : @"工具";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0 && !wq_system_areas_reachable())
        return @"在 iOS 26 上无法访问系统数据和系统群组（worse_query 仅在 iOS 27 上覆盖），而内部守护进程需要扫描每个文件 id：设备使用较多时首次扫描可能接近一小时，之后只检查新文件。";
    return section == 1
        ? @"被覆盖和删除的文件会先复制到「备份」（在「文件」App 中也能看到）。长按某个备份即可还原。"
        : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"r"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"r"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            c.text = loc[0];
            c.image = [UIImage systemImageNamed:loc[2]];
        } else {
            c.text = @"系统群组";
            c.image = [UIImage systemImageNamed:@"lock.square.stack"];
        }
    } else {
        NSArray *tools = @[@[@"App 列表", @"square.grid.3x3"], @[@"缓存清理", @"trash"], @[@"前往路径…", @"arrow.right.circle"],
                           @[@"App 备份", @"clock.arrow.circlepath"], @[@"备份", @"clock.arrow.circlepath"], @[@"日志", @"doc.plaintext"]];
        c.text = tools[(NSUInteger)indexPath.row][0];
        c.image = [UIImage systemImageNamed:tools[(NSUInteger)indexPath.row][1]];
    }
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _locations.count) {
            NSArray *loc = _locations[(NSUInteger)indexPath.row];
            next = [[WQDirViewController alloc] initWithPath:loc[1] title:loc[0]];
        } else {
            next = [WQSystemGroupsViewController new];
        }
    } else if (indexPath.row == 0) {
        next = [WQAppsViewController new];
    } else if (indexPath.row == 1) {
        next = [WQCacheCleanerViewController new];
    } else if (indexPath.row == 2) {
        [self goToPath];
        return;
    } else if (indexPath.row == 3) {
        [NSFileManager.defaultManager createDirectoryAtPath:wq_app_backup_root() withIntermediateDirectories:YES attributes:nil error:nil];
        next = [[WQDirViewController alloc] initWithPath:wq_app_backup_root() title:@"App 备份"];
    } else if (indexPath.row == 4) {
        [NSFileManager.defaultManager createDirectoryAtPath:wq_backup_root() withIntermediateDirectories:YES attributes:nil error:nil];
        next = [[WQDirViewController alloc] initWithPath:wq_backup_root() title:@"备份"];
    } else {
        next = [WQLogViewController new];
    }
    [self.navigationController pushViewController:next animated:YES];
}

- (void)goToPath
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"前往路径" message:@"文件夹或文件路径"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = UIPasteboard.generalPasteboard.hasStrings && [UIPasteboard.generalPasteboard.string hasPrefix:@"/"]
            ? UIPasteboard.generalPasteboard.string : @"/private/var/";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *__unused a) {
        NSString *path = alert.textFields.firstObject.text.stringByStandardizingPath;
        if (![path hasPrefix:@"/"]) return;
        dispatch_async(wq_io(), ^{
            struct stat st;
            BOOL exists = wq_stat(path, &st);
            BOOL isDir = exists && S_ISDIR(st.st_mode);
            if (exists && S_ISLNK(st.st_mode)) {
                struct stat target;
                isDir = stat(path.fileSystemRepresentation, &target) == 0 && S_ISDIR(target.st_mode);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!exists) {
                    wq_alert(self, @"未找到", path);
                    return;
                }
                if (!isDir) { wq_open_file(self.navigationController, path, NO, WQOpenAuto); return; }
                [self.navigationController pushViewController:[[WQDirViewController alloc] initWithPath:path title:nil]
                                                     animated:YES];
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - App

@interface WQSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WQSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.rootViewController = [[WQNavigationController alloc] initWithRootViewController:[WQRootViewController new]];
    [window makeKeyAndVisible];
    self.window = window;
}

@end

@interface WQAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation WQAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"默认" sessionRole:session.role];
    config.delegateClass = WQSceneDelegate.class;
    return config;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        // Container folders get their bundle id from the LaunchServices database
        // when the identifier attribute can't be read (iOS 27.2).
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_set_container_list_provider(wq_ls_container_paths);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WQAppDelegate.class));
    }
}
