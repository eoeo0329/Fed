ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Fed

Fed_FILES = Tweak.xm
Fed_CFLAGS = -fobjc-arc
Fed_FRAMEWORKS = UIKit Foundation AVFoundation QuartzCore
Fed_PLIST_FILES = Fed.plist

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"
