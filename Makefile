# BlockAd — 免VPN DNS去广告插件（Relaxin/roothide 隐根环境）
#
# 本地/CI 构建（rootful 有根式，适配隐根）：
#   THEOS=<theos路径> make package FINALPACKAGE=1
#   .deb 产物在 packages/
#
# 构建前需要先生成拦截表：python3 scripts/make-blocklist.py
# （CI 已在 workflow 里自动执行）

# SDK 用 latest（macos runner 自带的 Xcode iOS SDK 26.x，已验证可出包）。
# -fno-modules 关闭 clang 模块机制，规避 theos vendor/include 模块映射与 SDK 的重名冲突
TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
DEBUG := 0
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BlockAd
BlockAd_FILES = Tweak.xm blocklist.c blocklist_embedded.c splashhide.xm
BlockAd_CFLAGS = -fobjc-arc -fno-modules
# 零外部链接依赖：MSHookFunction 由 ellekit 运行时提供，动态查找避免 dylib 加载失败
BlockAd_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

# 设置页子工程
SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

# 生成拦截表（可直接 make blocklist 单独调用）
blocklist:
	python3 scripts/make-blocklist.py

# 本地跑核心逻辑单元测试（无需 iOS 设备）
test:
	$(MAKE) -C test