# 检测核心

`ShortcutDetector` 的公开调用及回调都在主线程。`start(nil)` 开始自由观察，首次含 Control / Option / Command 的组合或 F 功能键会锁定为本次目标；`start(spec)` 只观察选定组合；`stop()` 立即释放事件监听器并清空锁定。没有输入监控权限时 `start` 在创建监听器前返回 false，不会触发系统授权弹窗。收到组合后每次更新都重新计时，0.25 秒内没有新证据即自行停止，并通过 `onComplete` 回报最终结果（窗口的“检测完成”与 `keyscope detect` 共用）。`scan(spec)` 读取配置和系统状态，不安装监听器。

`ShortcutSpec.parse` 把 `ctrl+g`、`cmd+shift+4`、`⌃⇧G`、`ctrl+0x05` 等写法解析为同一个快捷键；它在配置解析用的 `keyAliases` / `modifierAliases` 之上只增加命令行输入的便利写法，不改变扫描结果。`hyper` 在不同工具中含义不同，命令行拒绝。`DetectionSnapshot.verdict` 是窗口标题与命令行共用的结论规则：有观察到的接收者为 recipientObserved，否则有主要证据为 relatedBinding，只剩监听器或相邻事件线索为 unconfirmed。

两个 CGEvent 监听器都是 `listenOnly`，不注册热键，不发送、消费或改写事件。回调只保留组合键、时间戳与热键事件的目标进程，文件扫描和 UI 通知延后执行。普通文字、字符内容、窗口标题及其他应用的数据不进入实时记录。

证据级别：

- `observedRecipient`：session keyDown 与 annotated-session systemDefined/subtype 6 的时间戳完全一致，且目标 PID 是有效的其他进程。这是系统派发目标，不表示目标内部功能执行成功。
- `systemBinding`：公开 Carbon `CopySymbolicHotKeys` API 返回启用的相同组合。该接口包含系统快捷键，不枚举所有第三方注册。
- `configuration`：对应格式中的键位及修饰键精确匹配。未声称进程已经加载配置。
- `conditionalConfiguration`：匹配存在，但应用、变量、设备、左右修饰键或动态 Lua 加载条件未求值。
- `nearbyEvent`：在按键之后 250 毫秒内观察到不同时间戳的系统热键事件，只能当作相邻线索。
- `listener`：`CGGetEventTapList` 显示正在运行、能过滤键盘按下/松开的进程。纯 `listenOnly` 进程、禁用监听器及 KeyScope 自己不会列入候选。

任一后续 keyDown 都会使之前的时间关联失效；重复事件、零时间戳、零 PID、过期事件和自己的 UI 事件不会被确认为接收者。停止、监听器中断会清空关联。

静态解析支持系统热键、Keyboard Maestro 启用宏及组、Karabiner 当前选定配置、skhd 常用声明、Hammerspoon 字面量绑定/键表、Raycast 的全局唤起快捷键，以及 Rectangle / Maccy / Raycast / MonitorControl 中的通用 keyCode/modifierFlags 偏好结构。不会执行 Lua、读取任意应用数据库，或宣称这些工具的每种格式均可覆盖。源文件缺失与读取错误有不同处理；扫描超过大小/数量边界时明确说明。

## 核验

```sh
xcrun swiftc -swift-version 5 -O -D DETECTION_SELF_TEST Sources/Detection/*.swift Sources/Detection/Tests/DetectionSelfTests.swift -o build/detection-self-tests
build/detection-self-tests --live-scan
```

纯测试覆盖时间关联误报、普通输入排除、修饰键区分、配置禁用与条件作用域、快捷键写法解析（含每个按键显示名可原样读回）与结论规则；收到组合后的自动停止由仅测试编译的 `selfTestDeliver` 送入合成快照，走真实的 `deliver`/`onComplete` 路径，覆盖只停一次、后续证据重新计时、回报最新结果、`stop()` 取消待停，不建监听器。`--live-scan` 使用实际扫描入口，仅输出级别计数和耗时；不启动监听器。实按接收者与安装版验收由产品验收记录维护，不能由这些单元测试替代。

## 接口与机制来源

- Apple SDK `CarbonEvents.h` 中的 `CopySymbolicHotKeys` 声明说明其只覆盖系统键盘偏好，且非线程安全。
- [Apple：CGGetEventTapList](https://developer.apple.com/documentation/coregraphics/cggeteventtaplist(_:_:_:))
- [Apple：eventTargetUnixProcessID](https://developer.apple.com/documentation/coregraphics/cgeventfield/eventtargetunixprocessid)
- [ShortcutDetective 作者说明](https://www.irradiatedsoftware.com/labs/)。双监听器机制来自对原产品的独立静态分析，没有复制原应用代码或资源。
- [NUIKit 的私有 CGS 头文件](https://github.com/NUIKit/CGSInternal/blob/master/CGSHotKeys.h) 中虽有按连接及 UID 查询的 `CGSGetHotKey`，但不是全量注册者枚举，未使用于产品。当前系统 SDK 导出的 SkyLight 符号也不提供已知的任意组合全量枚举接口。不能由此推导未来版本永远无法提供该能力。
