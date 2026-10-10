# KeyScope · 快捷键侦探

**中文** | [English](README_EN.md)

找出 Mac 快捷键的接收应用，并查看配置线索。

[产品官网与下载](https://keyscope.tianli.cyou/) · [版本发布](https://github.com/zengtianli/KeyScope/releases) · [问题反馈](https://github.com/zengtianli/KeyScope/issues)

KeyScope 是为新版 macOS 制作的原生快捷键诊断工具，面向遇到“某个组合键被占用，却不知道是谁接收”的用户。

- 打开检测，再按下快捷键，查看能识别的热键接收进程。
- 手动选择快捷键，查询可读取的系统和常用工具配置。
- 将明确的接收结果、配置匹配和可能监听的进程分别解释。
- 在本机分析，不发送按键或配置内容；仅检测期间观察组合键。

最低 macOS 14，Apple Silicon。当前真实验收环境为 macOS 27；其他系统版本未逐一实测。

<!-- lightweight:start -->
## 资源占用（历史参考：1.0.4）

| 安装包 | 空闲内存 | 空闲 CPU | 冷启动到首屏就绪 |
|---|---|---|---|
| **1.4 MB**（装好后 2.3 MB） | **25.2 MB** | **0%** | **336 ms** |

SwiftUI 与系统框架，零第三方依赖；无后台进程、登录项或定时任务。只在点「开始检测」后建立只读键盘监听，收到组合即停止；检测期间每 2 秒自检一次权限，结束即销毁。

<sub>v1.0.4 (8) · Mac16,12 / Apple M4 / macOS 27.2 · 装机的 1.0.4 (8) 本地验收构建（Developer ID 签名，未公证、未发行）静默启动到首屏布局完成，不建立键盘监听；完整查询只读本机真实快捷键配置。下载大小取公开发行的 1.0.4 (5) DMG。 · 2026-10-07。数字来自所列设备实测，版本更新后重新测量。内存口径为 phys_footprint；CPU 为 60 秒采样窗内 CPU 时间 ÷ 墙钟；大小按十进制 MB。实测口径见[官网资源占用](https://keyscope.tianli.cyou/#light)。</sub>
<!-- lightweight:end -->

以上为 1.0.4（8）的历史实测，下载体积来自公开 1.0.4（5）；不代表当前 1.0.5 的重新实测。

## 安装与使用

1. 从官网直接下载 DMG，将 KeyScope 拖入“应用程序”。
2. 打开 KeyScope，按指引允许“输入监控”。
3. 开始检测，按下要排查的快捷键；快捷键无法录入时使用手动查询。
4. 查看证据等级和对应说明，再去相关软件设置中调整绑定。

正式发行包使用 Apple Developer ID 签名，并经过 Apple 公证和装订。首次运行会显示正常的互联网下载确认；完整授权、常见问题和真实视频见官网。

## 命令行

1.0.3 起，App 内带有命令行 `keyscope`，与窗口是同一个程序，供终端、脚本或 Agent 使用：

```bash
ln -s /Applications/KeyScope.app/Contents/Resources/bin/keyscope ~/.local/bin/keyscope   # 可选：放进 PATH
keyscope scan ctrl+g --json        # 只读查询 ⌃G 的系统绑定与软件配置
keyscope detect --timeout 20       # 等你按下一个组合，报告接收它的软件
keyscope status --json             # 版本、调用方及窗口输入监控权限、安全键盘输入
keyscope update check --json       # 查询最新公开版本和升级方式
keyscope update install --dry-run --json  # 只看升级计划；安装需显式 --yes
keyscope help
```

除 `update install --yes` 外，命令只读：不写文件、不改配置。所有命令都不申请权限、不发送或合成按键；检查更新与安装升级匿名读取 GitHub 公开发行信息，安装另下载发行包。`detect` 需要终端已获“输入监控”权限，没有时立即退出（退出码 77）。

## 配置与更新

当前正式版本以 [最新 Release](https://github.com/zengtianli/KeyScope/releases/latest) 为准。「检查更新」读取最新公开发行，窗口与命令行使用同一个升级安装器。`keyscope update install --yes` 验证包散列和开发者签名后替换 KeyScope，成功后旧应用移入废纸篓。KeyScope 没有可迁移的设置，因此没有 iCloud 配置同步、导入或导出。`status` 可查询运行中窗口的监听和输入监控状态；窗口未运行时明确返回未知。

## 检测范围

macOS 不提供一个覆盖所有事件拦截方式的公开接口。KeyScope 可以识别部分系统派发的全局热键接收应用，但不能保证每个快捷键都有唯一归属；某个进程有键盘监听器，也不等于它吞掉了本次按键。没有足够证据时，界面会保留“未确认”的结果。

## 从源码构建

安装带 Swift 和 macOS SDK 的 Xcode 或 Command Line Tools，选择有效工具链后运行：

```bash
git clone https://github.com/zengtianli/KeyScope.git
cd KeyScope
bash build.sh
bash scripts/test.sh
```

产物在 `build/KeyScope.app`，自包含，不依赖作者的共享工具目录。本地构建默认 ad-hoc 签名，不能当作已公证的正式发行包；自行分发时需设置 `CODESIGN_IDENTITY` 为自己的 Developer ID Application 身份并完成 Apple 公证与装订。`BUILD_JOBS` 控制并行编译数，`BUILD_OUT=build/preview` 保留已有构建。退出 KeyScope 后可运行 `bash scripts/install.sh` 安装并链接命令，旧安装会保留以供回滚。

离线测试使用合成快照覆盖解析、证据规则和自动停止，不发送按键、不监听实际输入、不申请权限；真实按键检测需真人验证。[检测核心说明](Sources/Detection/README.md) 列出证据等级和边界。源码快照可能包含尚未发行的改动，正式包与哈希以 Release 为准。共享层未启用的私有更新目录使用通用示例名；KeyScope 的实际更新渠道仍为公开 GitHub Release。

## 许可证与反馈

本仓提供 [MIT License](LICENSE) 下的源码、资源与二进制发行。使用系统框架，不打包第三方源码。本产品与原 ShortcutDetective 作者无隶属关系。请通过 Issues 提交可复现步骤；不要附上私有配置、密码或个人数据。
