/*
 * BlockAd — 免VPN DNS去广告插件（Relaxin/roothide 隐根环境）
 *
 * 原理：注入目标 App 进程，hook libsystem 的 getaddrinfo()。
 * 当 App 发起域名解析时，若命中广告/统计域名表，直接返回 EAI_NONAME
 * （"域名不存在"），应用即认为该广告主机解析失败 → 广告请求发不出去。
 *
 * 特点：
 *  - 不依赖 VPN / 代理 / 常驻后台，耗电极低（每进程一次 list 加载 + 每查询一次二分）
 *  - 只拦截 DNS 解析这一环，对 App 其余行为零侵入，失败是"解析不到"，优雅降级
 *  - 生效范围由设置页控制（设置 → BlockAd）：总开关 / 全部 App / 指定 Bundle ID 列表
 *  - 拦截表在 /Library/BlockAd/blocklist.txt，由 GitHub Actions 每次构建时
 *    从 yhosts / OISD 等开源列表现场生成
 */
#import <Foundation/Foundation.h>

#import <errno.h>
#import <netdb.h>

#import "blocklist.h"

/* substrate 兼容运行时（ElleKit / Substrate）在设备上提供该符号，仅需声明即可链接。
 * 注意：Tweak.xm 按 Objective-C++ 编译，必须用 extern "C" 保持 C 链接，
 * 否则符号会被 C++ 名字改编成 MSHookFunction(void*,void*,void**) 而匹配不到 _MSHookFunction。 */
#ifdef __cplusplus
extern "C" {
#endif
void MSHookFunction(void *symbol, void *hook, void **orig);
#ifdef __cplusplus
}
#endif

/* 不依赖 libroothide：jbroot() 用恒等实现，真实路径靠多候选探测兜底（见 ba_try_load_list）。
 * 目的：让 dylib 零外部链接依赖、一定能被 ellekit 加载，避免加载失败被静默跳过。 */
static inline const char *ba_jbroot(const char *p) { return p; }
#define jbroot(p) ba_jbroot(p)

#define BA_LIST_PATH  "/Library/BlockAd/blocklist.txt"
#define BA_PREFS_DOMAIN       @"com.blockad.tweak"
#define BA_PREFS_NOTIFICATION "com.blockad.tweak/preferences.changed"

static int (*orig_getaddrinfo)(const char *node, const char *service,
                               const struct addrinfo *hints,
                               struct addrinfo **res);

static int ba_process_enabled(void);
static void ba_try_load_list(void);
static void ba_write_status(void);
static void ba_log_dns(const char *host, int blocked);
static void ba_refresh_rules_async(void);
static int g_triedLoad = 0;
static int g_blocksBlocked = 0;

/* 自动更新的规则下载地址（由 CI 发布到本仓库的 GitHub Release） */
#define BA_RULES_URL \
    "https://github.com/zhangtao838/BlockAd/releases/latest/download/blocklist.txt"

/* 内置拦截表（blocklist_embedded.c，随包编译进 dylib，规避沙盒读文件失败） */
extern const char *const kBaDomains[];
extern const size_t kBaDomainCount;

/* 第 3 层：开屏视图隐藏（splashhide.xm） */
extern void ba_install_splash_hooks(void);

/* ------------------------------------------------------------------ */
#pragma mark - getaddrinfo hook

static int ba_hooked_getaddrinfo(const char *node, const char *service,
                                 const struct addrinfo *hints,
                                 struct addrinfo **res)
{
    /* 列表首次未加载成功时，借第一个 DNS 查询再补一次（文件可能稍晚出现） */
    if (!bl_loaded() && !g_triedLoad) {
        g_triedLoad = 1;
        ba_try_load_list();
    }
    /* 只对"纯主机名"做拦截；IP 字面量/空节点一律放行 */
    if (node != NULL && node[0] != '\0') {
        int blocked = bl_host_blocked(node);
        ba_log_dns(node, blocked);                 /* 调试日志：找出名单外的广告域名 */
        if (blocked) {
            errno = ECONNREFUSED;
            if (++g_blocksBlocked % 100 == 0) ba_write_status();
            return EAI_NONAME;
        }
    }
    return orig_getaddrinfo(node, service, hints, res);
}

/* ------------------------------------------------------------------ */
#pragma mark - 生效范围判定（读设置页 NSUserDefaults）

static int g_enabled = -1;

/* 拦截表加载：优先内置列表（编译进 dylib，沙盒读不到文件也不影响），再兜底文件路径 */
static void ba_try_load_list(void)
{
    bl_use_array(kBaDomains, kBaDomainCount);  /* 内置只读数组：零拷贝、共享内存 */
    if (bl_loaded()) return;

    const char *candidates[] = {
        jbroot(BA_LIST_PATH),
        "/Library/BlockAd/blocklist.txt",
        "/var/jb/Library/BlockAd/blocklist.txt",
    };
    for (size_t i = 0;
         i < sizeof(candidates) / sizeof(candidates[0]) && !bl_loaded();
         i++) {
        bl_load_path(candidates[i]);
    }
}

/* 设置变更通知：让已运行的 App 进程刷新启用状态（由设置页发出） */
static void ba_prefs_changed(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo)
{
    g_enabled = -1;
}

static int ba_process_enabled(void)
{
    if (g_enabled >= 0) return g_enabled;
    g_enabled = 0;

    /* 守护进程等无 Bundle ID 的进程直接跳过 */
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid == nil || bid.length == 0) return 0;

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:BA_PREFS_DOMAIN];

    /* 从未配置过设置页：默认对所有 App 生效 */
    if (![d objectForKey:@"enabled"] && ![d objectForKey:@"scope"]) {
        g_enabled = 1;
        return 1;
    }
    if (![d boolForKey:@"enabled"]) return 0;

    NSString *scope = [d stringForKey:@"scope"];
    if (scope == nil || [scope isEqualToString:@"all"]) {
        g_enabled = 1;
        return 1;
    }

    /* 仅指定 App 模式：按逗号分隔的 Bundle ID 列表匹配 */
    NSString *custom = [d stringForKey:@"customBundles"] ?: @"";
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *part in [custom componentsSeparatedByString:@","]) {
        NSString *t = [[part stringByTrimmingCharactersInSet:ws] lowercaseString];
        if (t.length > 0 && [t isEqualToString:bid]) {
            g_enabled = 1;
            return 1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
#pragma mark - 自检诊断：把运行状态写进该 App 的数据目录

static void ba_write_status(void)
{
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        /* 守护进程等无 bundle 的不写（避免噪音）；App 进程必写 */
        if (home.length == 0 || bid.length == 0) return;

        NSString *dir = [home stringByAppendingPathComponent:@"tmp"];
        NSString *path = [dir stringByAppendingPathComponent:@"blockad_status.txt"];
        const char *lp = bl_path();
        NSFileManager *fm = [NSFileManager defaultManager];

        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"BlockAd 自检\n"];
        [s appendFormat:@"进程(bundle): %@\n", bid];
        [s appendFormat:@"已启用: %d\n", ba_process_enabled()];
        [s appendFormat:@"拦截表已加载: %@\n", bl_loaded() ? @"是" : @"否"];
        [s appendFormat:@"拦截表条数: %zu\n", bl_count()];
        const char *lpText = lp ? lp : (bl_count() > 0 ? "(内置)" : "(未加载)");
        [s appendFormat:@"拦截表路径: %s\n", lpText];
        [s appendFormat:@"已拦截域名次数: %d\n", g_blocksBlocked];

        /* 逐个候选路径报告"文件在不在"，判断是未装包还是沙盒读不到 */
        const char *cand[] = {
            jbroot(BA_LIST_PATH),
            "/Library/BlockAd/blocklist.txt",
            "/var/jb/Library/BlockAd/blocklist.txt",
        };
        [s appendFormat:@"候选路径:\n"];
        for (size_t i = 0; i < sizeof(cand) / sizeof(cand[0]); i++) {
            BOOL ex = [fm fileExistsAtPath:[NSString stringWithUTF8String:cand[i]]];
            [s appendFormat:@"  %s : %@\n", cand[i], ex ? @"存在" : @"无"];
        }

        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

/* ------------------------------------------------------------------ */
#pragma mark - DNS 调试日志：找出名单外的广告域名

static void ba_log_dns(const char *host, int blocked)
{
    static int n = 0;
    if (host == NULL || *host == '\0') return;
    if (n >= 1500) return;             /* 只记前 1500 条，防刷屏 */
    n++;
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        if (home.length == 0) return;
        NSString *path = [[home stringByAppendingPathComponent:@"tmp"]
                          stringByAppendingPathComponent:@"blockad_dns.txt"];
        NSString *line = [NSString stringWithFormat:@"%d\t%@\t%s\n", n,
                          blocked ? @"BLOCK" : @"pass", host];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

/* ------------------------------------------------------------------ */
#pragma mark - 自动更新规则：后台拉最新拦截表并热替换（24h 节流，失败静默）

static void ba_refresh_rules_async(void)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @autoreleasepool {
            NSString *home = NSHomeDirectory();
            if (home.length == 0) return;
            NSString *tsPath = [[home stringByAppendingPathComponent:@"tmp"]
                                stringByAppendingPathComponent:@"blockad_rules_ts"];
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            double last = [[NSString stringWithContentsOfFile:tsPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil] doubleValue];
            if (last > 0 && (now - last) < 24 * 3600.0) return;   /* 24h 内跳过 */

            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:@BA_RULES_URL]
                                                 options:NSDataReadingMappedIfSafe
                                                   error:nil];
            if (!data || data.length < 1024) return;

            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (text.length < 1024) return;

            if (bl_load_text(text.UTF8String)) {   /* 热替换（读路径并发安全） */
                [[NSString stringWithFormat:@"%.0f", now]
                    writeToFile:tsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                ba_write_status();
            }
        }
    });
}

/* ------------------------------------------------------------------ */
#pragma mark - 构造：按设置决定是否安装 hook

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, &ba_prefs_changed,
                                    CFSTR(BA_PREFS_NOTIFICATION),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    /* 只要注入成功就先写自检（无 bundle 的进程会跳过）——文件不存在 = 没注入 */
    ba_write_status();
    if (!ba_process_enabled()) return;      /* 未启用：不装 hook，零开销 */

    ba_try_load_list();                     /* 尽力加载，失败也不阻塞后面的 hook 安装 */
    ba_write_status();                      /* 启用后刷新一次（带列表状态） */
    MSHookFunction((void *)getaddrinfo,
                   (void *)&ba_hooked_getaddrinfo,
                   (void **)&orig_getaddrinfo);

    ba_install_splash_hooks();              /* 第 3 层：开屏视图隐藏（开屏必消失） */

    ba_refresh_rules_async();               /* 后台自动更新规则（24h 节流） */
}