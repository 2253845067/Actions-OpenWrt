include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fan
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=OpenWrt LuCI community
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-fan
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Cyber 3588 AIB fan control dashboard
  DEPENDS:=+luci-base +coreutils-stat
endef

define Package/luci-app-fan/description
  Modern LuCI fan control dashboard for Cyber 3588 AIB pwm-fan
  control and thermal telemetry.
endef

define Build/Compile
endef

define Package/luci-app-fan/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/luci-fan $(1)/etc/config/luci-fan

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/luci-fan $(1)/etc/init.d/luci-fan

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-fan $(1)/etc/uci-defaults/luci-fan

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./root/usr/libexec/fan-control $(1)/usr/libexec/fan-control
	$(INSTALL_BIN) ./root/usr/libexec/fan-diagnostics $(1)/usr/libexec/fan-diagnostics
	$(INSTALL_DATA) ./root/usr/libexec/fan-lib.sh $(1)/usr/libexec/fan-lib.sh

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/luci.fan $(1)/usr/libexec/rpcd/luci.fan

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-fan.json $(1)/usr/share/luci/menu.d/luci-app-fan.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-fan.json $(1)/usr/share/rpcd/acl.d/luci-app-fan.json

	$(INSTALL_DIR) $(1)/usr/share/ucitrack
	$(INSTALL_DATA) ./root/usr/share/ucitrack/luci-app-fan.json $(1)/usr/share/ucitrack/luci-app-fan.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/fan.js $(1)/www/luci-static/resources/view/fan.js
endef

$(eval $(call BuildPackage,luci-app-fan))
