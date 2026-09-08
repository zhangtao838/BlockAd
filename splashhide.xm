/*
 * splashhide.xm — 第 3 层：开屏视图隐藏（"开屏必消失"）
 *
 * 思路：不跟广告数据/网络斗，直接掐掉"展示"这个动作 ——
 *  1) hook 主流广告 SDK 的开屏加载/展示方法 → 使其失效
 *  2) 通用兜底：类名含 splash 的展示控制器自动跳过
 * 对不存在的类/方法，Logos 会安全跳过（类缺失时不安装 hook），不影响其他 App。
 *
 * 覆盖对象（睿博士 DNS 日志实测的 SDK）：优量汇 GDT / 穿山甲 CSJ / 百度。
 */
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static BOOL ba_cls_is_splash(Class cls)
{
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls).lowercaseString;
    /* 开屏相关类名关键词（含各 SDK 的窗口/视图命名习惯） */
    static NSArray *kws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kws = @[ @"splash", @"gdt", @"bdsplash", @"adscreen", @"adwindow",
                 @"adview", @"adscene", @"buadsplash" ];
    });
    for (NSString *kw in kws) {
        if ([name containsString:kw]) return YES;
    }
    return NO;
}

/* 视图（含窗口）是否是开屏：类名或根控制器类名命中即算 */
static BOOL ba_view_is_splash(UIView *view)
{
    if (!view) return NO;
    if (ba_cls_is_splash([view class])) return YES;
    UIViewController *vc = view.window.rootViewController;
    if (vc && ba_cls_is_splash([vc class])) return YES;
    return NO;
}

/* ---- 优量汇 GDT（gdt.qq.com / sdk.e.qq.com / sdkquic.e.qq.com） ---- */
%hook GDTSplashAd
- (void)loadAdAndShowInWindow:(UIWindow *)window {}     /* 不加载不展示 */
- (void)showAdInWindow:(UIWindow *)window {}            /* 新版展示入口 */
%end

%hook GDTSplashAdView
- (void)showInWindow:(UIWindow *)window {}              /* 视图直接展示入口 */
%end

/* ---- 穿山甲 CSJ / GroMore 聚合（pangolin-sdk-toutiao / gromore） ---- */
%hook BUDSplashAd
- (void)loadAdData {}                                   /* 不加载素材 */
- (void)showSplashViewInRootViewController:(UIViewController *)rootViewController {}  /* 不展示 */
%end

/* ---- 百度广告（pos.baidu.com / mobads.baidu.com / feed-image.baidu.com） ---- */
%hook BaiduMobAdSplash
- (void)load {}                                         /* 不加载 */
%end

/* ---- 通用兜底：任何"类名含 splash"的展示控制器自动跳过 ---- */
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated
{
    %orig;
    if (ba_cls_is_splash([self class])) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.presentingViewController) {
                [self dismissViewControllerAnimated:NO completion:nil];
            }
            [self.view removeFromSuperview];
            [self removeFromParentViewController];
        });
    }
}
%end

/* ---- 窗口级：SDK 开屏大多往 UIWindow 里塞视图（如 GDT 的 GDTSplashAdView） ---- */
%hook UIWindow
- (void)makeKeyAndVisible
{
    %orig;
    if (ba_view_is_splash(self)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setHidden:YES];
            self.windowLevel = UIWindowLevelAlert - 1;   /* 压到最底，不再盖住内容 */
        });
    }
}
%end

/* Tweak.xm 构造时调用（确保本文件被链接；hook 随 dylib 加载自动安装） */
void ba_install_splash_hooks(void) { }