# Agent Note: Desktop 打包提供本地 ad-hoc 签名的 macOS 构建

Status: implemented

[English](2026-09-23-desktop-local-unsigned-build.md) | 中文

## Problem

macOS 打包在没有 Developer ID 身份和一套完整公证凭据时拒绝启动，固定目标命令还会对目录构建执行公证和装订。因此没有这些凭据的开发者根本无法为自己的机器生成可运行的应用：唯一的未签名模式 `DSH_DESKTOP_UNSIGNED=1` 对所有非 Windows 目标都被拒绝，而 Apple 芯片拒绝执行完全没有签名的 arm64 代码。[Electron Desktop 打包决策](../architecture/2026-08-25-electron-desktop-packaging-and-updates.zh.md)拥有发布身份与签名，并有意让未签名的 macOS 产物无法产生，以免未签名产物被当作发布产物。

## Decision

`DSH_DESKTOP_LOCAL_UNSIGNED=1` 选择仅在构建主机上运行的本地 macOS 构建。

- `prepare:dsh` 对每个物化的 Mach-O 文件进行 ad-hoc 签名，而不声明发布身份，并保留逐文件标识符和 JIT 权限。
- `package:mac:*:dir` 跳过签名钥匙串、公证、强制更新策略和更新通道；electron-builder 关闭代码签名、强化运行时、公证和 DMG 签名。
- 产物写入 `.desktop-build/targets/mac-arm64/local-artifacts/`，与发布产物目录和 Windows 未签名目录并列。
- 该模式必须使用 `--dir`。磁盘映像和公证票据属于发布产物，本地运行若生成它们，就会模糊该模式本要保持的界限。
- 目标 dotenv 文件可选：应用 ID 和该开关由调用方提供，因为本地构建没有可读取的发布配置。

该开关之外的所有凭据要求保持不变，构建出的应用不携带发布身份、公证票据、更新通道或完成记录。

## Alternatives considered

**让 macOS 复用 `DSH_DESKTOP_UNSIGNED`。** 该开关的含义是“生成未签名的 Windows 产物”：其产物带 `-unsigned` 名称，其命令构建完整安装包。共用会让一个开关表示两种产物，并削弱 Windows 专有的凭据清除逻辑。

**接受登录钥匙串中的证书。** 其中的自签名身份产生的签名在其他机器上会被 Gatekeeper 拒绝，本仓库也无法验证。ad-hoc 签名则如实说明该构建仅限本地。

**支持本地 DMG 或 ZIP。** 两者都需要签名，分发还需要公证票据。在本地生成它们，要么需要该模式本要回避的凭据，要么产出与发布产物无法区分的文件。

**让开发者在构建失败后自行运行 `codesign --deep`。** 构建在打包前就停止，没有可签名的应用；而且 `--deep` 会重新签名嵌套代码，丢失运行时使用的逐文件标识符和权限。

## Consequences

- Apple 芯片上的开发者无需 Apple 凭据即可构建并运行应用；构建仍需常规工具链、Python，以及下载 Electron 和捆绑运行时的网络访问。
- 该模式绝不满足发布验收要求：不写入完成记录，不嵌入更新通道或策略，且签名不含任何身份。
- 单元测试固定了产物目录、被丢弃的身份、公证与更新字段、缺少 dotenv 文件的路径，以及不带 `--dir` 的本地构建会被拒绝。
- 打包命令对非 macOS 目标拒绝该模式，因此该开关不会悄悄削弱 Windows 或 Linux 构建。
