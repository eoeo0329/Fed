ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdSkipTweak
AdSkipTweak_FILES = Tweak.xm
AdSkipTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AdSkipTweak_FRAMEWORKS = UIKit Foundation QuartzCore AVFoundation MediaPlayer

include $(THEOS_MAKE_PATH)/tweak.mk

# 仅输出 dylib，不打包 deb
after-all::
	@echo "[AdSkipTweak] dylib 输出路径: $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib"
