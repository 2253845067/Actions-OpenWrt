#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Modify default IP
sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Modify hostname
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# Fix Cyber 3588 AIB thermal zone registration on newer kernels.
# Linux rejects thermal zones when passive_delay is greater than polling_delay,
# which makes rockchip-thermal fail with -EINVAL and removes CPU temp sysfs nodes.
CYBER_DTS="target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/rk3588-cyber3588-aib.dts"
if [ -f "$CYBER_DTS" ]; then
    sed -i '/&package_thermal {/,/};/s/polling-delay-passive = <2000>;/polling-delay-passive = <1000>;/' "$CYBER_DTS"
fi

# Embed install_fan_control.sh into the firmware's /bin directory.
# After flashing, just run: sh /bin/install_fan_control.sh
FAN_SCRIPT="${GITHUB_WORKSPACE}/install_fan_control.sh"
if [ -f "$FAN_SCRIPT" ]; then
    mkdir -p files/bin
    cp "$FAN_SCRIPT" files/bin/install_fan_control.sh
    chmod +x files/bin/install_fan_control.sh
fi

# --- ndisc6（QModem feed 自带包）---------------------------------------------
# 这个包的源码地址一直不稳定：remlab.net 会把旧版本移进 archive/、对部分网络
# 直接返回 403，OpenWrt/ImmortalWrt 源码镜像里又查不到它，任何一次下载失败都
# 会让整次构建白跑（2026-10-31、11-01、11-03 都是栽在 ndisc6 上）。所以：
#   1) 用仓库自带的源码包 immorlinwrt/dl/ndisc6-1.0.8.tar.bz2 预填充 dl/，
#      构建阶段根本不需要联网下载；
#   2) 把 Makefile 的版本/文件名/校验值/编译标准固定下来并做校验，不再依赖
#      上游 QModem 的具体写法（它已经改过一次，导致补丁只生效一半）。
NDISC6_DIR="feeds/qmodem/application/ndisc6"
NDISC6_VER="1.0.8"
NDISC6_HASH="1f2fb2dc1172770aa5a09d39738a44d8b753cc5e2e25e306ca78682f9fea0b4f"

mkdir -p dl
if [ -d "$GITHUB_WORKSPACE/immorlinwrt/dl" ]; then
    cp -f "$GITHUB_WORKSPACE/immorlinwrt/dl/"*.tar.* dl/ 2>/dev/null || true
fi

if [ -f "$NDISC6_DIR/Makefile" ]; then
    ndisc6_mk="$NDISC6_DIR/Makefile"

    # 把已有的定义改成固定值。1.0.8 用 C11 的 alignas()，而原 Makefile 里的
    # -std=c99 会让 musl 的 <stdalign.h> 把它展开成
    # __attribute__((aligned(struct tcphdr)))，报 "expected expression before 'struct'"
    sed -i \
        -e "s|^PKG_VERSION:=.*$|PKG_VERSION:=$NDISC6_VER|" \
        -e "s|^PKG_SOURCE:=.*$|PKG_SOURCE:=ndisc6-\$(PKG_VERSION).tar.bz2|" \
        -e "s|^PKG_SOURCE_URL:=.*$|PKG_SOURCE_URL:=https://www.remlab.net/files/ndisc6/archive|" \
        -e "s|^PKG_MD5SUM:=.*$|PKG_HASH:=$NDISC6_HASH|" \
        -e "s|^PKG_HASH:=.*$|PKG_HASH:=$NDISC6_HASH|" \
        -e "s|^TARGET_CFLAGS += -std=c99$|TARGET_CFLAGS += -std=gnu11|" \
        "$ndisc6_mk"

    # 两个旧补丁只适用于 1.0.2（1.0.8 重写了 traceroute 代码，rdnssd/ 也改名 rdnss/）
    rm -f "$NDISC6_DIR/patches/100-favor_bsd.patch" \
          "$NDISC6_DIR/patches/110-strverscmp.patch"

    # 上游若删掉/改写了某个定义，这里补齐（make 中后赋值生效）
    add_if_missing() {
        grep -qxF "$1" "$ndisc6_mk" && return 0
        # Makefile 末尾可能没有换行符，先补齐再追加，避免与最后一行粘连
        if [ -n "$(tail -c 1 "$ndisc6_mk")" ]; then
            echo >> "$ndisc6_mk"
        fi
        echo "$1" >> "$ndisc6_mk"
    }
    add_if_missing "PKG_VERSION:=$NDISC6_VER"
    add_if_missing "PKG_SOURCE:=ndisc6-\$(PKG_VERSION).tar.bz2"
    add_if_missing "PKG_SOURCE_URL:=https://www.remlab.net/files/ndisc6/archive"
    add_if_missing "PKG_HASH:=$NDISC6_HASH"
    add_if_missing "TARGET_CFLAGS += -std=gnu11"
    # 关闭 NLS，避免依赖 target 侧的 gettext/intl 支持
    add_if_missing "CONFIGURE_ARGS += --disable-nls"

    # 兜底校验：任何一项没落实就立刻失败，不要拖到几十分钟后的编译阶段
    for ndisc6_expect in "PKG_VERSION:=$NDISC6_VER" "PKG_HASH:=$NDISC6_HASH" \
                         "PKG_SOURCE:=ndisc6-\$(PKG_VERSION).tar.bz2" \
                         "TARGET_CFLAGS += -std=gnu11" \
                         "CONFIGURE_ARGS += --disable-nls"; do
        if ! grep -qxF "$ndisc6_expect" "$ndisc6_mk"; then
            echo "::error::ndisc6 Makefile 修补失败，缺少: $ndisc6_expect"
            exit 1
        fi
    done
    if [ ! -f "dl/ndisc6-$NDISC6_VER.tar.bz2" ]; then
        echo "::error::缺少仓库自带源码包 immorlinwrt/dl/ndisc6-$NDISC6_VER.tar.bz2"
        exit 1
    fi

    echo "qmodem: ndisc6 固定为 $NDISC6_VER，并使用仓库自带源码包（构建时不联网下载）"
fi

# qmodem强制安装以覆盖现有的驱动程序/应用
./scripts/feeds install -a -f -p qmodem
