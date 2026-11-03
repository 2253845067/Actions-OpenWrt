# 预置源码包（dl）

这里存放构建时需要、但上游下载很不稳定的源码包。`immorlinwrt/diy-part2.sh`
会把这里的 `*.tar.*` 复制到 `openwrt/dl/`，`make download` 发现文件已存在就会
跳过联网下载，因此构建不再受上游源码站抽风影响。

| 文件 | 版本 | SHA256 | 说明 |
| --- | --- | --- | --- |
| `ndisc6-1.0.8.tar.bz2` | 1.0.8 | `1f2fb2dc1172770aa5a09d39738a44d8b753cc5e2e25e306ca78682f9fea0b4f` | QModem feed 的 `application/ndisc6` 使用。remlab.net 把旧版本移进了 `files/ndisc6/archive/`，且对部分网络返回 403；OpenWrt/ImmortalWrt 源码镜像里没有这个包 |

维护说明：

- 新增文件时请在上表登记版本、SHA256 与来源 URL。
- `SHA256` 必须与对应包 Makefile 里的 `PKG_HASH` 一致。
- 升级版本时同时更新本表与 `immorlinwrt/diy-part2.sh` 里的 `NDISC6_VER` /
  `NDISC6_HASH`（脚本末尾有校验，不一致会直接失败）。
