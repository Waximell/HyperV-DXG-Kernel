# HyperV-DXG-Kernel

尝试给普通 Hyper-V 来宾 Linux 虚拟机引入 WSL2 的 GPU-PV 能力，本仓库面向普通 Debian、Ubuntu 发行版，config 取自 debian-6.18.15 (-arm64) .config，合入 6.18.58.1-microsoft-standard-WSL2 部分模块，版本随 microsoft-standard-WSL2。具体工作、修改、kconfig、workflow 由 AI（DeepSeek-V4.1-Flash）执行，如果介意请绕行。

## 对 Debian 默认配置改动

| 项                                                | Debian 默认  | 本仓库                           | 修改原因                      |
| ------------------------------------------------ | ---------- | ----------------------------- | ------------------------- |
| `MODULE_SIG_ALL`                                 | 空          | 关                             | 保留后续签名能力                  |
| `MODULE_COMPRESS`                                | XZ         | NONE                          | 方便后续按需签名                  |
| `DEBUG_INFO` / `DEBUG_INFO_BTF`                  | `y`        | 关                             | 虚拟机来宾系统不需要                |
| `SYSTEM_TRUSTED_KEYS` / `SYSTEM_REVOCATION_KEYS` | 空串         | 显式置空                          | 防止基线或构建环境带入 Debian 证书链    |
| `HYPERV_UTILS` / `BALLOON` / `STORAGE` / `NET`   | `=m`       | `=y`                          | 避免跨发行版 initramfs 模块加载顺序影响 |
| `DXGKRNL`                                        | 无此驱动       | `=y`                          | 本仓库实际工作                   |
| `ANDROID_BINDER_IPC` / `ANDROID_BINDERFS`        | `=m` / 关闭  | `=y` / `=y`                   | Waydroid 相关               |
| `ANDROID_BINDER_DEVICES`                         | `"binder"` | `"binder,hwbinder,vndbinder"` | Waydroid 相关               |
| `LOCALVERSION`                                   | `""`       | `-hyperv-dxg`                 | 与发行版内核共存                  |

## 开源协议

本项目以 **GPL-2.0-only** 发布。

全文见 <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>。
