# CLAUDE.md

本文件给在此仓库工作的 Claude Code 提供指引。

## 项目概览

NotifSound 是一个 macOS 菜单栏工具：监听通知中心横幅，按应用播放用户指定的声音。
用来替代 Chirpy。核心约束是**不常驻音频引擎**——Chirpy 的 AVAudioEngine 会让
`coreaudiod` 一直持有 `PreventUserIdleSystemSleep`，挡住系统空闲睡眠；本工具只在播放时
调用 `afplay`，不产生长期防睡断言。

- 语言/框架：Swift 5.8 + Cocoa + ApplicationServices（Accessibility）+ UniformTypeIdentifiers
- 构建：Command Line Tools 的 `swiftc`（不需要 Xcode）
- 产物：`build/NotifSound.app` → 安装到 `~/Applications/NotifSound.app`
- 常驻：LaunchAgent `com.nexus.notifsound`
- 配置：`~/.config/notif-sound/rules.json`
- 音频：`~/data/notif-sound/sounds/`
- 日志：`~/data/notif-sound/logs/notif.log`
- 单实例锁：`~/data/notif-sound/notifsound.lock`

## 构建与安装

```bash
./build.sh    # 编译到 build/NotifSound.app
./install.sh  # 编译 + 复制到 ~/Applications + 写 LaunchAgent + 启动
```

安装后首次运行需要「系统设置 → 隐私与安全性 → 辅助功能」勾选 NotifSound。
程序每 5 秒检查一次权限，授权后自动连上通知中心，不需要重启。

## 测试

```bash
NotifSound --test-sound   # 播放当前第一条规则的音色
osascript -e 'display notification "test body" with title "Test" subtitle "hello"'
tail -5 ~/data/notif-sound/logs/notif.log
```

菜单「测试声音」播放的是配置里第一条规则的音色（最近在设置窗口选过/试听过的优先），
不是写死的 Glass；命令行 `--test-sound` 走同一套逻辑。

日志里应出现 `play app=脚本编辑器 rule=... sound=... text=...`（osascript 的横幅应用名是「脚本编辑器」）。
用 `pmset -g assertions | grep -i coreaudio` 确认空闲时没有音频/防睡断言。

## 架构

`Sources/main.swift` 单文件：

- `Watcher`：`NSApplicationDelegate`，负责状态栏菜单、配置加载、AX 观察和通知处理。
- `collectBanners`：遍历 AX 树，找 `AXGroup/AXNotificationCenterBanner`；
  `AXDescription` 是应用名，子节点 `AXStaticText` 的 value 是标题/副标题/正文。
- `scan`：窗口刚创建时子节点可能还没填好，0.4 秒重试最多 4 次。
- `process`：2 秒去重 → 匹配规则 → `afplay` 播放 → 写日志。
- `showSettingsWindow`：程序化 AppKit 设置窗口，每个规则一个 `NSPopUpButton`（已导入音频 +
  系统声音），`▶` 试听，底部「全部设为」一次改所有规则。
- `copyIntoLibrary`：SHA-256 内容去重；同路径直接复用；重名不同内容用 `-2` 后缀。
- `resolveSound`：绝对路径 → 导入目录 → 系统声音。
- `notificationCenterCallback`：全局 C 回调，通过 `refcon` 找回 `Watcher`。

## 规则语义

```json
{
  "fallback": "",
  "rules": [
    { "app": "微信", "sound": "pi-chime.mp3", "volume": 0.5 },
    { "app": "邮件", "text": "发票", "sound": "/path/to/sound.aiff" }
  ]
}
```

- 规则从上到下，第一条 `app` 和 `text` 都满足的生效。
- `app` / `text` 都是不区分大小写的包含匹配。
- 没有 `app` 和 `text` 的规则匹配所有通知，可放在末尾当兜底（支持 `volume`）。
- `fallback` 是无规则匹配时的声音，不支持单独设音量。
- `volume` 为 0–1，透传给 `afplay -v`。
- 配置在每条通知处理前按 mtime 自动重载，改完即生效。

## 音频解析顺序

1. `sound` 是绝对路径 → 直接使用。
2. `~/data/notif-sound/sounds/` 下的精确文件名；没有扩展名时依次尝试
   `.aiff` / `.wav` / `.mp3` / `.m4a` / `.caf`。
3. `/System/Library/Sounds/<sound>.aiff`。

菜单「导入音频…」按内容哈希去重复制；「设置提示音…」打开设置窗口：每个规则一行，
下拉选已导入音频 / 系统声音，`▶` 试听，底部「全部设为」可一键应用到全部规则；
「打开声音目录」在 Finder 中打开。
命令行：`NotifSound --set-sound <音频文件> <应用名>`；`NotifSound --settings` 直接打开设置窗口。

## 通知侧要求

- 系统设置 → 通知：保留「允许通知」，样式选「横幅」或「提醒」。
- 关闭「播放通知声音」，否则原生声音 + NotifSound 会双响。
- 样式为「无」的通知、以及专注模式下的通知不会产生横幅，watcher 抓不到。

## 已知坑

- **重建覆盖 App 后辅助功能可能失效**：ad-hoc 签名会变，TCC 授权可能不再匹配。
  重新在系统设置里勾选 NotifSound 即可；调试时可以先用 `build/` 里的 App 直接跑
  （从终端启动会继承终端的辅助功能权限）。
- 通知中心的 AX 结构未公开，macOS 大版本升级后可能变化。先写个探针 dump AX 树再改
  `collectBanners`，不要盲改。
- 横幅窗口的 `AXWindowCreated` 有时先于子节点填充触发，`collectBanners` 会扫到空树；
  `scan` 用 0.4 秒 ×4 次重试兜底，别去掉。
- 菜单「测试声音」曾经写死 Glass，用户改完提示音后试听仍是旧声音。现在播放第一条规则的
  音色（最近在设置窗口选过/试听过的优先），命令行 `--test-sound` 走同一逻辑。
- 这是 `LSUIElement` 状态栏应用，没有窗口，agent-desktop 的 `list-surfaces` 为空、
  `snapshot` 报 `WINDOW_NOT_FOUND`。调 UI 时用 `NotifSound --settings` 启动，窗口直接出现。
- 导入音频时不要直接 `removeItem` 再 `copyItem`：如果用户选中的文件本来就在
  `~/data/notif-sound/sounds/` 里，源和目标是同一路径，会先删掉源文件，表现为「导入后文件不见了」。
  `copyIntoLibrary` 已做同路径判断。
- 导入按 SHA-256 内容去重，改名后的同一音频不会重复占空间；重名不同内容会生成 `-2` 后缀文件。
- 设置窗口的「应用到全部」会改掉所有规则（包括 WeChat/Mail 这类别名行），测试或演示后记得恢复。
- 调试时先 `launchctl bootout gui/$(id -u)/com.nexus.notifsound`，否则单实例锁会让新实例直接退出。
- NotificationCenter 重启后靠 5 秒定时器重连；菜单里也有「重新连接通知中心」。
- 日志里的 `ax window created` 是调试输出，保留用于排查。

## 卸载

```bash
launchctl bootout gui/$(id -u)/com.nexus.notifsound
mv ~/Applications/NotifSound.app ~/.Trash/
mv ~/Library/LaunchAgents/com.nexus.notifsound.plist ~/.Trash/
```

## 代码约定

- 单文件、无第三方依赖、注释用中文。
- 保持 macOS 13 + Intel 兼容；不要引入需要 Xcode 工程的构建步骤。
- 新增功能优先走菜单项，不要把行为藏在配置里。
