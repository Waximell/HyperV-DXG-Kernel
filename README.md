# HyperV-DXG-Kernel

尝试给普通 Hyper-V 来宾 Linux 虚拟机引入 WSL2 的 GPU-PV 能力，本仓库面向普通 Debian、Ubuntu 发行版：config 取自 `linux-image-6.18.15+deb13-amd64`、`linux-image-6.18.15+deb13-arm64`，合入 `6.18.58.1-microsoft-standard-WSL2` 中 Hyper-V 相关的部分。具体工作、修改、kconfig、workflow 由 AI（DeepSeek-V4.1-Flash）执行，如果介意请绕行。

## 

## 对 Debian 默认配置改动

| 项                                                | Debian 默认           | 本仓库                           | 修改目的                                        |
| ------------------------------------------------ | ------------------- | ----------------------------- | ------------------------------------------- |
| `MODULE_SIG_ALL`                                 | 无此行（Kconfig 默认 `y`） | 显式关闭                          | 构建期不签名，以便按需自行签名                             |
| `MODULE_COMPRESS`                                | `y`（XZ）             | 不压缩                           | 未压缩的 `.ko` 可直接 `sign-file`                  |
| `DEBUG_INFO_BTF`                                 | `y`                 | 关闭                            | 虚拟机来宾不需要                                    |
| `SYSTEM_TRUSTED_KEYS` / `SYSTEM_REVOCATION_KEYS` | 无此行（默认空串）           | 显式置空                          | 避免带入 Debian 证书链 |
| `HYPERV_UTILS` / `BALLOON` / `STORAGE` / `NET`   | `=m`                | `=y`                          | 避免跨发行版 initramfs 模块加载顺序带来影响                 |
| `DXGKRNL`                                        | 无此驱动                | `=y`                          | 本仓库实际工作                                     |
| `ANDROID_BINDER_IPC` / `ANDROID_BINDERFS`        | `=m` / 关闭           | `=y` / `=y`                   | Waydroid 相关                                 |
| `ANDROID_BINDER_DEVICES`                         | `"binder"`          | `"binder,hwbinder,vndbinder"` | Waydroid 相关                                 |
| `LOCALVERSION`                                   | `""`                | `-hyperv-dxg`                 | 与发行版内核共存                                    |

## 

## 开源协议

本项目以 **GPL-2.0-only** 发布。

全文见 <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>。
