# Openwrt 定制固件

# 目录

[一、简介](#一简介)

[二、源代码地址 ](#二源代码地址)

[三、固件](#三固件)

[四、展示](#四展示)

[五、鸣谢](#五鸣谢)

# 一、简介

该项目从[P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)进行定制，添加5G模块官方支持和一些常用插件

# 二、源代码地址

- LEDE：https://github.com/coolsnowwolf/lede

# 三、固件

## 功能特性

- 添加5G模块官方驱动和官方拨号工具
- 添加5G模块管理插件
- 添加以下插件
  - ddnsto
  - OpenClash
  - modem
  - ttyd
  - ssr-plus
  - mosdns
  - oled

## 默认配置

- IP: `http://192.168.1.1`
- 用户名: `root`
- 密码: `password`
- 如果设备只有一个网口，则此网口就是 `LAN` , 如果大于一个网口, 默认第一个网口是 `WAN` 口, 其它都是 `LAN`
- 如果要修改 `LAN` 口 `IP` , 首页有个内网设置，或者用命令 `quickstart` 修改
- 北京时间每天 `0:00` 定时编译, `Release` 中只保留不同架构的最新版本
- 历史版本在 `Actions` 中选择一个已经运行完成且成功的 `workflow` 在页面底部可以看到 `Artifacts`, `Artifacts` 需要登录 Github 才能下载

# 四、展示

暂无


# 五、鸣谢

- [istoreos](https://github.com/istoreos/istoreos)
- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [Microsoft Azure](https://azure.microsoft.com)
- [GitHub Actions](https://github.com/features/actions)
- [OpenWrt](https://github.com/openwrt/openwrt)
- [Lean&#39;s OpenWrt](https://github.com/coolsnowwolf/lede)
- [tmate](https://github.com/tmate-io/tmate)
- [mxschmitt/action-tmate](https://github.com/mxschmitt/action-tmate)
- [csexton/debugger-action](https://github.com/csexton/debugger-action)
- [Cowtransfer](https://cowtransfer.com)
- [WeTransfer](https://wetransfer.com/)
- [Mikubill/transfer](https://github.com/Mikubill/transfer)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [ActionsRML/delete-workflow-runs](https://github.com/ActionsRML/delete-workflow-runs)
- [dev-drprasad/delete-older-releases](https://github.com/dev-drprasad/delete-older-releases)
- [peter-evans/repository-dispatch](https://github.com/peter-evans/repository-dispatch)
