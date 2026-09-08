# BlockAd 设置页（PreferenceBundle）
# 产物：
#   /Library/PreferenceBundles/BlockAdPrefs.bundle/   设置页控制器
#   （Resources/ 目录内容自动打进 bundle：Info.plist、设置项、图标）
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = BlockAdPrefs

BlockAdPrefs_FILES = BlockAdController.mm
BlockAdPrefs_INSTALL_PATH = /Library/PreferenceBundles
BlockAdPrefs_FRAMEWORKS = UIKit
# SDK 里没有 Preferences 私有框架，符号留待 Settings 运行时解析（动态查找）
BlockAdPrefs_PRIVATE_FRAMEWORKS = MobileCoreServices
BlockAdPrefs_CFLAGS = -fobjc-arc -fno-modules -I$(THEOS)/include
BlockAdPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
# Resources/ 内容（含 Info.plist / BlockAdSpec.plist / 图标）会被 Theos 自动收进 bundle
BlockAdPrefs_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk