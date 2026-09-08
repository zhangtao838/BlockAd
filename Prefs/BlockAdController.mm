/*
 * BlockAd 设置页控制器
 * 设置项全部程序化构造（PSSpecifier + set/get selector），
 * 参考社区成熟写法，避免 plist specifier 在部分 iOS 版本渲染/点击异常。
 */
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <spawn.h>

extern char **environ;

#define BA_SUITE  @"com.blockad.tweak"
#define BA_NOTIFY "com.blockad.tweak/preferences.changed"

static void ba_post_notify(void)
{
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(BA_NOTIFY), NULL, NULL, YES);
}

@interface BlockAdPrefsListController : PSListController
@end

@implementation BlockAdPrefsListController

#pragma mark - Preferences 读写

- (NSUserDefaults *)ba_defaults
{
    return [[NSUserDefaults alloc] initWithSuiteName:BA_SUITE];
}

- (id)readPref:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:@"key"];
    id v = [[self ba_defaults] objectForKey:key];
    return v ?: [specifier propertyForKey:@"default"];
}

- (void)setPref:(id)value forSpecifier:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:@"key"];
    [[self ba_defaults] setObject:value forKey:key];
    CFPreferencesAppSynchronize((__bridge CFStringRef)BA_SUITE);
    ba_post_notify();
}

#pragma mark - 设置项

- (PSSpecifier *)groupNamed:(NSString *)title footer:(NSString *)footer
{
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title target:self
        set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
    if (footer.length) [sp setProperty:footer forKey:@"footerText"];
    return sp;
}

- (NSArray *)specifiers
{
    if (!_specifiers) {
        NSMutableArray *s = [NSMutableArray array];

        [s addObject:[self groupNamed:@"去广告"
                               footer:@"拦截广告与统计域名，免 VPN、无后台常驻。"]];

        PSSpecifier *enable = [PSSpecifier preferenceSpecifierNamed:@"启用去广告"
            target:self set:@selector(setPref:forSpecifier:)
            get:@selector(readPref:) detail:Nil cell:PSSwitchCell edit:Nil];
        [enable setProperty:@"enabled" forKey:@"key"];
        [enable setProperty:BA_SUITE forKey:@"defaults"];
        [enable setProperty:@YES forKey:@"default"];
        [s addObject:enable];

        [s addObject:[self groupNamed:@"生效范围"
                               footer:@"修改设置后用下方按钮注销生效。"]];

        PSSpecifier *scope = [PSSpecifier preferenceSpecifierNamed:@"生效 App"
            target:self set:@selector(setPref:forSpecifier:)
            get:@selector(readPref:) detail:Nil cell:PSSegmentCell edit:Nil];
        [scope setProperty:@"scope" forKey:@"key"];
        [scope setProperty:BA_SUITE forKey:@"defaults"];
        [scope setProperty:@"all" forKey:@"default"];
        [scope setProperty:@[@"全部 App", @"仅指定 App"] forKey:@"validTitles"];
        [scope setProperty:@[@"all", @"list"] forKey:@"validValues"];
        [s addObject:scope];

        PSSpecifier *cust = [PSSpecifier preferenceSpecifierNamed:@"指定 App 的 Bundle ID"
            target:self set:@selector(setPref:forSpecifier:)
            get:@selector(readPref:) detail:Nil cell:PSEditTextCell edit:Nil];
        [cust setProperty:@"customBundles" forKey:@"key"];
        [cust setProperty:BA_SUITE forKey:@"defaults"];
        [cust setProperty:@"" forKey:@"default"];
        [cust setProperty:@"com.tencent.xin, com.sina.weibo" forKey:@"placeholder"];
        [s addObject:cust];

        [s addObject:[self groupNamed:nil footer:nil]];

        PSSpecifier *rb = [PSSpecifier preferenceSpecifierNamed:@"注销生效（Respring）"
            target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
        [rb setProperty:@YES forKey:@"enabled"];
        rb.buttonAction = @selector(baRespring);
        [s addObject:rb];

        _specifiers = s;
    }
    return _specifiers;
}

#pragma mark - 注销

- (void)baRespring
{
    ba_post_notify();
    NSFileManager *fm = [NSFileManager defaultManager];
    pid_t pid;
    /* /usr/bin 在隐根/有根环境下为工具链路径，sbreload 优先，回退 killall SpringBoard */
    const char *sbreload = "/usr/bin/sbreload";
    if ([fm fileExistsAtPath:[NSString stringWithUTF8String:sbreload]]) {
        const char *argv[] = { sbreload, NULL };
        posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ);
    } else {
        const char *killall = "/usr/bin/killall";
        const char *argv[] = { killall, "-9", "SpringBoard", NULL };
        posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ);
    }
}

#pragma mark - 生命周期

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.title = @"BlockAd 去广告";
}

@end