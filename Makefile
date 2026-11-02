# NotificationNuke — Per-app notification sound cooldowns + regex text filters. Group chats stop dinging every message; junk reminders blocked entirely. Lock screen keeps showing them.
#
# Device build (CI default):   make package FINALPACKAGE=1        (rootless /var/jb)
# Simulator build (local dev): tools/sim-test.sh NotificationNuke         (Mac, rootful paths)

TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
LDID ?= ldid

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NotificationNuke
NotificationNuke_FILES = NotificationNuke.x
NotificationNuke_CFLAGS = -fobjc-arc
# logos emits MSHookMessageEx/MSHookFunction calls; resolve them at RUNTIME from
# whatever provides `Depends: mobilesubstrate` (libhooker/ElleKit). Never link a
# concrete substrate binary, never hardcode /var/jb paths — see knowledge/packaging.md.
NotificationNuke_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

# Settings pane (PreferenceLoader bundle). Private Preferences classes are
# declared minimally in NNRootController.m and resolved at runtime — no SDK
# stubs needed (dynamic_lookup), so iOS version drift can't break the build.
BUNDLE_NAME = NotificationNukePrefs
NotificationNukePrefs_FILES = NotificationNukePrefs/NNRootController.m
NotificationNukePrefs_INSTALL_PATH = /Library/PreferenceBundles
NotificationNukePrefs_CFLAGS = -fobjc-arc
NotificationNukePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
NotificationNukePrefs_INFO_PLIST = NotificationNukePrefs/Info.plist

include $(THEOS_MAKE_PATH)/bundle.mk

# Sign the FINAL staged bytes (Apple Silicon SIGKILLs stale signatures). Staged
# path is scheme-dependent (rootless=/var/jb/..., sim=rootful) → locate the dylib.
ifneq ($(filter simulator%,$(TARGET)),)
# theos defaults sim signing to `codesign --sign 'Apple Development'` (needs a
# real cert); the JB sim accepts ad-hoc — keep the build cert-free.
TARGET_CODESIGN_FLAGS = --force --sign -
SIGN_CMD = codesign --force --sign -
else
SIGN_CMD = $(shell command -v $(LDID) >/dev/null 2>&1 && echo "$(LDID) -S" || echo "codesign --force --sign -")
endif
after-stage::
	@find "$(THEOS_STAGING_DIR)" -name 'NotificationNuke*.dylib' -type f | while read -r f; do \
	  $(SIGN_CMD) "$$f" && echo "signed: $$f"; done
