//
//  WQHexViewer.m
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import "WQHexViewer.h"
#import "WQHexViewerHelpers.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQUI.h"
#import <sys/stat.h>

static const NSUInteger kPageSize = 64 * 1024;
static const NSUInteger kSearchChunk = 1024 * 1024;

static BOOL wqh_is_visible(UIViewController *host)
{
    if (!host.isViewLoaded || !host.view.window) return NO;
    UINavigationController *navigation = host.navigationController;
    return !navigation || navigation.visibleViewController == host;
}

static void wqh_alert(UIViewController *host, NSString *title, NSString *message)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!wqh_is_visible(host)) return;
        UIViewController *presented = host.presentedViewController;
        if (presented && ![presented isKindOfClass:UIAlertController.class]) return;
        void (^present)(void) = ^{
            if (!wqh_is_visible(host) || host.presentedViewController) return;
            UIAlertController *a = wq_alert_controller(title, message, UIAlertControllerStyleAlert);
            [a addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, nil)];
            [host presentViewController:a animated:YES completion:nil];
        };
        if (presented) [presented dismissViewControllerAnimated:YES completion:present];
        else present();
    });
}

@implementation WQHexViewController {
    NSString *_path;
    BOOL _readOnly;
    unsigned long long _size;
    NSUInteger _perRow;
    int _offsetDigits;     // hex digits in the offset column
    NSCache<NSNumber *, NSData *> *_pages;
    NSMutableSet<NSNumber *> *_loading;
    NSMutableDictionary<NSNumber *, NSNumber *> *_edits;   // offset -> new byte
    WQEditState *_editState;
    NSDictionary<NSString *, NSNumber *> *_version;
    unsigned long long _matchOffset;
    NSUInteger _matchLength;
    NSData *_lastSearchNeedle;
    NSUInteger _searchGeneration;
    NSString *_status;
    dispatch_queue_t _queue;
}

- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = [path copy];
        _readOnly = readOnly;
        _perRow = 8;
        _offsetDigits = 8;
        _pages = [NSCache new];
        _pages.countLimit = 64;   // 4 MB
        _loading = [NSMutableSet new];
        _edits = [NSMutableDictionary new];
        _editState = [WQEditState new];
        _queue = dispatch_queue_create("wqfiles.hex", DISPATCH_QUEUE_SERIAL);
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    // Offsets, hex and ASCII columns read left to right in every language
    // (the rows are forced too, in cellForRow).
    self.tableView.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 20;
    __weak typeof(self) weakSelf = self;
    self.navigationItem.backAction = [UIAction actionWithHandler:^(UIAction *__unused a) { [weakSelf leave]; }];
    NSString *path = _path;
    dispatch_async(_queue, ^{
        struct stat st;
        BOOL ok = wq_stat(path, &st) && S_ISREG(st.st_mode);
        NSDictionary *version = ok ? wq_file_version(path) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_version = version;
            self->_size = ok ? (unsigned long long)st.st_size : 0;
            [self layoutColumns];
            if (wq_permission_hint(path, YES)) self->_readOnly = YES;
            self->_status = ok ? nil : WQLocalized(@"Cannot open this file.");
            [self updateBar];
            [self.tableView reloadData];
        });
    });
    [self updateBar];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    _searchGeneration++;
    _lastSearchNeedle = nil;
    _matchLength = 0;
    _status = nil;
}

- (UIFont *)rowFont
{
    return [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
}

// As many bytes per row as fit (in steps of 4), and an offset column only as
// wide as the file needs.
- (void)layoutColumns
{
    int digits = 4;
    for (unsigned long long last = _size ? _size - 1 : 0; digits < 16 && (last >> (4 * digits)); digits++) {}
    CGFloat charWidth = [@"0" sizeWithAttributes:@{ NSFontAttributeName: self.rowFont }].width;
    CGFloat avail = self.tableView.bounds.size.width - 16;   // 8 pt margins on each side
    if (charWidth <= 0 || avail <= 0) return;
    NSInteger chars = (NSInteger)floor(avail / charWidth);
    // A row is: offset, 2 spaces, "xx " per byte, 1 space, 1 character per byte.
    NSInteger fit = (chars - digits - 3) / 4;
    NSUInteger per = (NSUInteger)MAX(4, MIN(32, fit - fit % 4));
    if (per != _perRow || digits != _offsetDigits) {
        _perRow = per;
        _offsetDigits = digits;
        [self.tableView reloadData];
    }
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    [self layoutColumns];
}

- (void)updateBar
{
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)_size countStyle:NSByteCountFormatterCountStyleFile];
    NSString *prompt = _status ?: WQLocalizedFormat(@"%@ · %llu bytes%@%@", size, _size,
                                   _edits.count ? WQLocalizedFormat(@" · %lu changed", (unsigned long)_edits.count) : @"",
                                   _editState.saving ? WQLocalized(@" · Saving…") : @"");
    self.navigationItem.prompt = prompt;
    NSMutableArray *items = [NSMutableArray array];
    if (!_readOnly) {
        UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:WQLocalizedNullable(@"Save") style:wq_primary_button_style()
                                                                target:self action:@selector(save)];
        save.enabled = _edits.count > 0 && !_editState.saving;
        [items addObject:save];
    }
    __weak typeof(self) weakSelf = self;
    UIAction *discard = [UIAction actionWithTitle:WQLocalizedNullable(@"Discard Changes") image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil
                                      handler:^(UIAction *__unused a) { [weakSelf discard]; }];
    if (_editState.saving) discard.attributes = UIMenuElementAttributesDisabled;
    UIMenu *menu = [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:WQLocalizedNullable(@"Go to Offset…") image:[UIImage systemImageNamed:@"arrow.right.to.line"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf goToOffset]; }],
        [UIAction actionWithTitle:WQLocalizedNullable(@"Find Hex Bytes…") image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf promptFindHex:YES]; }],
        [UIAction actionWithTitle:WQLocalizedNullable(@"Find Text…") image:[UIImage systemImageNamed:@"text.magnifyingglass"] identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf promptFindHex:NO]; }],
        discard,
    ]];
    [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:menu]];
    self.navigationItem.rightBarButtonItems = items;
}

#pragma mark Data

// The file byte at `offset` (an edit if there is one), or -1 while its page
// is still being read.
- (int)byteAt:(unsigned long long)offset
{
    NSNumber *edit = _edits[@(offset)];
    if (edit) return edit.intValue;
    return [self originalByteAt:offset];
}

- (int)originalByteAt:(unsigned long long)offset
{
    NSNumber *page = @(offset / kPageSize);
    NSData *data = [_pages objectForKey:page];
    if (!data) { [self loadPage:page]; return -1; }
    NSUInteger i = (NSUInteger)(offset % kPageSize);
    return i < data.length ? ((const uint8_t *)data.bytes)[i] : -1;
}

- (void)loadPage:(NSNumber *)page
{
    if ([_loading containsObject:page]) return;
    [_loading addObject:page];
    NSString *path = _path;
    dispatch_async(_queue, ^{
        NSString *error = nil;
        NSData *data = wq_read_range(path, page.unsignedLongLongValue * kPageSize, kPageSize, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_loading removeObject:page];
            if (!data) {
                self->_status = wq_permission_hint(path, NO) ? WQLocalized(@"Only the owner may read this file.") : WQLocalizedFormat(@"Read failed: %@", error);
                [self updateBar];
                return;
            }
            [self->_pages setObject:data forKey:page];
            [self.tableView reloadRowsAtIndexPaths:self.tableView.indexPathsForVisibleRows
                                  withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)((_size + _perRow - 1) / _perRow);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"h"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"h"];
    cell.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    cell.contentView.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    UIFont *font = self.rowFont;
    unsigned long long start = (unsigned long long)indexPath.row * _perRow;
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%0*llx  ", _offsetDigits, start]
            attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor }];
    NSMutableString *ascii = [NSMutableString new];
    NSMutableArray<NSValue *> *asciiMarks = [NSMutableArray new];
    for (NSUInteger i = 0; i < _perRow; i++) {
        unsigned long long off = start + i;
        if (off >= _size) { [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:@{ NSFontAttributeName: font }]]; continue; }
        int b = [self byteAt:off];
        UIColor *color = UIColor.labelColor;
        BOOL edited = _edits[@(off)] != nil;
        BOOL match = _matchLength && off >= _matchOffset && off < _matchOffset + _matchLength;
        if (edited) color = UIColor.systemOrangeColor;
        NSMutableDictionary *attrs = [@{ NSFontAttributeName: font, NSForegroundColorAttributeName: color } mutableCopy];
        if (match) attrs[NSBackgroundColorAttributeName] = [UIColor.systemYellowColor colorWithAlphaComponent:0.45];
        NSString *hex = b < 0 ? @"·· " : [NSString stringWithFormat:@"%02x ", b];
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:hex attributes:attrs]];
        if (edited || match) [asciiMarks addObject:[NSValue valueWithRange:NSMakeRange(ascii.length, 1)]];
        [ascii appendFormat:@"%c", (b >= 0x20 && b < 0x7f) ? b : '.'];
    }
    NSMutableAttributedString *asc = [[NSMutableAttributedString alloc] initWithString:[@" " stringByAppendingString:ascii]
        attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor }];
    for (NSValue *v in asciiMarks) {
        NSRange r = v.rangeValue;
        [asc addAttribute:NSForegroundColorAttributeName value:UIColor.systemOrangeColor range:NSMakeRange(r.location + 1, 1)];
    }
    [line appendAttributedString:asc];
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    c.attributedText = line;
    c.textProperties.numberOfLines = 1;
    c.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 8, 0, 8);
    cell.contentConfiguration = c;
    cell.selectionStyle = _readOnly ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_readOnly || _editState.saving) return;
    unsigned long long start = (unsigned long long)indexPath.row * _perRow;
    NSUInteger count = (NSUInteger)MIN((unsigned long long)_perRow, _size - start);
    NSMutableString *current = [NSMutableString new];
    for (NSUInteger i = 0; i < count; i++) {
        int b = [self byteAt:start + i];
        if (b < 0) return;   // page not loaded yet
        [current appendFormat:i ? @" %02x" : @"%02x", b];
    }
    UIAlertController *a = wq_alert_controller(WQLocalizedFormat(@"Bytes at 0x%llx", start), WQLocalizedFormat(@"Overwrite these %lu bytes (hex). The file size stays the same.", (unsigned long)count), UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = current;
        f.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Set", UIAlertActionStyleDefault, ^(UIAlertAction *__unused x) {
        NSData *bytes = WQParseHex(a.textFields.firstObject.text ?: @"", NO);
        if (bytes.length != count) {
            wqh_alert(self, @"Not changed", WQLocalizedFormat(@"Enter exactly %lu bytes in hex.", (unsigned long)count));
            return;
        }
        const uint8_t *nb = bytes.bytes;
        for (NSUInteger i = 0; i < count; i++) {
            unsigned long long off = start + i;
            if ([self originalByteAt:off] == nb[i]) [self->_edits removeObjectForKey:@(off)];
            else self->_edits[@(off)] = @(nb[i]);
        }
        [self->_editState noteChange];
        [self updateBar];
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Save, discard, leave

- (BOOL)wq_needsLeaveConfirmation
{
    return _edits.count > 0 || _editState.saving;
}

- (NSDictionary<NSNumber *, NSData *> *)runs
{
    NSMutableDictionary *runs = [NSMutableDictionary new];
    NSArray *offsets = [_edits.allKeys sortedArrayUsingSelector:@selector(compare:)];
    unsigned long long runStart = 0;
    NSMutableData *run = nil;
    for (NSNumber *o in offsets) {
        unsigned long long off = o.unsignedLongLongValue;
        uint8_t b = (uint8_t)_edits[o].intValue;
        if (run && off == runStart + run.length) { [run appendBytes:&b length:1]; continue; }
        if (run) runs[@(runStart)] = run;
        runStart = off;
        run = [NSMutableData dataWithBytes:&b length:1];
    }
    if (run) runs[@(runStart)] = run;
    return runs;
}

- (BOOL)blockWhileSaving
{
    if (!_editState.saving) return NO;
    wqh_alert(self, @"Save in progress", @"Wait for the save to finish before leaving or changing these edits.");
    return YES;
}

- (void)save
{
    if (!_edits.count || [self blockWhileSaving]) return;
    if (!_version) {
        wqh_alert(self, @"Save unavailable", @"The file version could not be verified. Close and reopen it before saving.");
        return;
    }
    NSDictionary *runs = [self runs];
    UIAlertController *a = wq_alert_controller(@"Save changes?", WQLocalizedFormat(@"%lu bytes in %@ are overwritten in place. The current file is backed up first.", (unsigned long)_edits.count, _path), UIAlertControllerStyleAlert);
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Save", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused x) {
        NSDictionary *expectedVersion = [self->_version copy];
        if (!expectedVersion) {
            wqh_alert(self, @"Save unavailable", @"The file version could not be verified. Close and reopen it before saving.");
            return;
        }
        NSUInteger savedRevision = [self->_editState beginSave];
        [self updateBar];
        NSString *path = self->_path;
        dispatch_async(self->_queue, ^{
            NSString *error = nil;
            NSDictionary *savedVersion = nil;
            BOOL ok = wq_patch_if_unchanged_get_version(path, runs, expectedVersion, &savedVersion, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_editState finishSave:ok revision:savedRevision];
                if (!ok) {
                    [self updateBar];
                    wqh_alert(self, @"Save failed", error ?: wq_permission_hint(path, YES) ?: @"Unknown error");
                    return;
                }
                self->_version = savedVersion;
                self->_status = nil;
                if (self->_editState.revision == savedRevision) [self->_edits removeAllObjects];
                [self->_pages removeAllObjects];
                [self updateBar];
                [self.tableView reloadData];
            });
        });
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)discard
{
    if ([self blockWhileSaving]) return;
    [_edits removeAllObjects];
    [_editState discard];
    [self updateBar];
    [self.tableView reloadData];
}

// Home button: ask before throwing away unsaved changes.
- (void)confirmLeaveThen:(void (^)(void))proceed
{
    if ([self blockWhileSaving]) return;
    if (!_edits.count) { proceed(); return; }
    UIAlertController *a = wq_alert_controller(@"Discard changes?", @"Your byte changes have not been saved.", UIAlertControllerStyleAlert);
    [a addAction:wq_alert_action(@"Keep Editing", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Discard", UIAlertActionStyleDestructive, ^(UIAlertAction *__unused x) {
        [self->_edits removeAllObjects];
        [self->_editState discard];
        proceed();
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)leave
{
    [self confirmLeaveThen:^{
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

#pragma mark Navigation and search

- (void)scrollToOffset:(unsigned long long)offset
{
    if (_size == 0) return;
    if (offset >= _size) offset = _size - 1;
    NSInteger row = (NSInteger)(offset / _perRow);
    [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
                          atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
}

- (void)goToOffset
{
    UIAlertController *a = wq_alert_controller(@"Go to Offset", @"Hex (0x1a2b) or decimal", UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"0x0";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Go", UIAlertActionStyleDefault, ^(UIAlertAction *__unused x) {
        NSString *t = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        unsigned long long off = 0;
        if (!WQHexParseOffset(t, &off)) {
            wqh_alert(self, @"Invalid offset", @"Enter a complete non-negative decimal value or a 0x-prefixed hexadecimal value.");
            return;
        }
        if (_size == 0) {
            wqh_alert(self, @"Offset unavailable", @"The file is empty or its size is still loading.");
            return;
        }
        if (off >= _size) {
            wqh_alert(self, @"Offset out of range", WQLocalizedFormat(@"Enter an offset from 0x0 through 0x%llx.", _size - 1));
            return;
        }
        [self scrollToOffset:off];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptFindHex:(BOOL)hex
{
    UIAlertController *a = wq_alert_controller(hex ? @"Find Hex Bytes" : @"Find Text", @"Searches the saved file forward from the top of the screen.", UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = hex ? @"de ad be ef" : WQLocalized(@"text");
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Find", UIAlertActionStyleDefault, ^(UIAlertAction *__unused x) {
        NSString *t = a.textFields.firstObject.text ?: @"";
        if (!WQHexSearchInputWithinLimit(t)) {
            wqh_alert(self, @"Search too large", @"Use at most 1 MiB of UTF-8 search input.");
            return;
        }
        NSData *needle = hex ? WQParseHex(t, NO) : [t dataUsingEncoding:NSUTF8StringEncoding];
        if (needle.length == 0) { wqh_alert(self, @"Nothing to find", hex ? @"Enter hex bytes, e.g. de ad be ef." : @"Enter some text."); return; }
        BOOL sameNeedle = self->_lastSearchNeedle && [self->_lastSearchNeedle isEqualToData:needle];
        NSInteger topRow = NSIntegerMax;
        for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
            if (indexPath.section == 0) topRow = MIN(topRow, indexPath.row);
        }
        if (topRow == NSIntegerMax) topRow = 0;
        unsigned long long from = (sameNeedle && self->_matchLength && self->_matchOffset < ULLONG_MAX)
            ? self->_matchOffset + 1 : (unsigned long long)topRow * self->_perRow;
        if (!sameNeedle) self->_matchLength = 0;
        self->_lastSearchNeedle = [needle copy];
        [self search:needle from:from];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)search:(NSData *)needle from:(unsigned long long)from
{
    NSUInteger generation = ++_searchGeneration;
    _status = WQLocalized(@"Searching…");
    [self updateBar];
    NSString *path = _path;
    unsigned long long size = _size;
    NSUInteger requestLength = kSearchChunk + needle.length - 1;
    dispatch_async(_queue, ^{
        unsigned long long found = ULLONG_MAX;
        NSString *error = nil;
        for (unsigned long long pos = from; pos < size && found == ULLONG_MAX; ) {
            NSUInteger length = (NSUInteger)MIN((unsigned long long)requestLength, size - pos);
            NSData *chunk = wq_read_range(path, pos, length, &error);
            if (!chunk || chunk.length < needle.length) break;
            NSRange r = [chunk rangeOfData:needle options:0 range:NSMakeRange(0, chunk.length)];
            if (r.location != NSNotFound) found = pos + r.location;
            if (size - pos <= kSearchChunk) break;
            pos += kSearchChunk;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_searchGeneration || !wqh_is_visible(self)) return;
            self->_status = nil;
            [self updateBar];
            if (found == ULLONG_MAX) {
                self->_matchLength = 0;
                [self.tableView reloadData];
                wqh_alert(self, @"Not found", error ?: WQLocalizedFormat(@"No match after offset 0x%llx.", from));
                return;
            }
            self->_matchOffset = found;
            self->_matchLength = needle.length;
            [self.tableView reloadData];
            [self scrollToOffset:found];
        });
    });
}

@end
