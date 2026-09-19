# ShadowsocksX-NG2

ShadowsocksX-NG 的现代化重写版本。新工程的全部源码与构建配置放在本目录下。

依赖的二进制工具（ss-local、privoxy、kcptun、v2ray-plugin 等）不再以子模块方式在仓库内构建，而是直接复制外部项目发布好的可执行文件。

旧版工程源码位于仓库根目录的 [`Legacy/`](../Legacy) 下，仅供参考，不保证可构建。
