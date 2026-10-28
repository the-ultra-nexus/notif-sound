# NotifSound

轻量版「按应用播放自定义通知声音」的 macOS 菜单栏工具，用来替代 Chirpy。
不常驻音频引擎，不会像 Chirpy 那样一直持有 `PreventUserIdleSystemSleep`。

## 原理

- 用 Accessibility API 监听 `com.apple.notificationcenterui` 的 `AXWindowCreated` 事件。
- 横幅结构：`AXGroup/AXNotificationCenterBanner`，`AXDescription` 是应用名，
  子节点 `AXStaticText` 是标题/副标题/正文。
- 按规则匹配后，用 `/usr/bin/afplay` 播放声音——只在播放的那一两秒产生音频活动，不挡空闲睡眠。

## 配置

`~/.config/notif-sound/rules.json`：

```json
{
  "fallback": "",
  "rules": [
    { "app": "微信", "sound": "Glass" },
    { "app": "邮件", "sound": "Hero" },
    { "app": "滴答清单", "sound": "Ping" },
    { "app": "kitty", "sound": "Pop" },
    { "app": "Claude", "sound": "Submarine" }
  ]
}
```

- `sound` 先在 `~/data/notif-sound/sounds/` 里找（可写 `my-chime.mp3`，也可只写 `my-chime`），
  找不到再退回 `/System/Library/Sounds/` 的系统声音（`Glass`、`Hero`、`Ping`…），也支持绝对路径。
- 菜单栏 🔔 →「导入音频…」：按内容哈希去重，同一文件只存一份；重名但内容不同会自动加 `-2` 后缀。
- 菜单栏 🔔 →「设置提示音…」：每个应用一行，从已导入音频 / 系统声音里选，`▶` 试听；
  底部「全部设为」+「应用到全部」可以一键把所有规则改成同一个声音。
- 也可以命令行设置：`NotifSound --set-sound <音频文件> <应用名>`；
- 命令行 `NotifSound --play <应用名>` 直接按应用名取规则播放，不用等横幅——终端里跑的
  Codex、Claude 这类 agent，横幅应用名永远是终端，只能由 agent 自己调用它。
  `~/.codex/config.toml` 里 `notify = ["~/scripts/agent-notify.sh", "Codex"]` 就是这么接的。
  `NotifSound --settings` 直接打开设置窗口。
- 菜单「测试声音」播放当前配置里第一条规则的音色（最近在设置窗口选过/试听过的优先）；
  命令行 `NotifSound --test-sound` 等价。
- `app` 匹配横幅里的应用名（不区分大小写、包含即可）；`text` 可再按标题/正文关键词收窄。
- 规则从上到下，第一条匹配的生效；都不匹配时用 `fallback`（留空 = 不响）。
- 修改配置后无需重启，下一条通知会重新读取。

## 通知设置（避免双声）

系统设置 → 通知 → 每个要用的 App：

- 保留「允许通知」，样式选「横幅」或「提醒」（「无」不会产生横幅，也就不会被捕获）
- **关闭「播放通知声音」**——否则你会同时听到 App 原生声音 + NotifSound 的声音

NotifSound 不需要通知权限，只需要辅助功能权限；原生声音关掉后横幅照常出现。

## 示例规则

| App | 横幅里的应用名 | 声音 |
|---|---|---|
| 微信 | 微信 / WeChat | Glass |
| 邮件 | 邮件 / Mail | Hero |
| 滴答清单 | 滴答清单 / TickTick | Ping |
| kitty | kitty | Pop |
| Claude | Claude | Submarine |

自定义音频放在 `~/data/notif-sound/sounds/`，`sound` 写文件名即可（如 `my-chime.mp3`）。
作者本地使用从旧 Chirpy 迁移的 `pi-chime.mp3`、`hello.mp3`、`discord-notification.mp3`，
这些文件不随仓库分发。

如果想让所有通知都用同一个声音，在 rules 末尾加一条不带 `app`/`text` 的规则：

```json
{ "sound": "Glass", "volume": 0.5 }
```

## 构建 / 安装

```bash
cd ~/projects/opensource/notif-sound
./build.sh        # 只编译到 build/NotifSound.app
./install.sh      # 编译 + 安装到 ~/Applications + LaunchAgent
```

首次运行需要在 **系统设置 → 隐私与安全性 → 辅助功能** 勾选 `NotifSound`。
授权后程序会在 5 秒内自动连上通知中心，不需要重启。

## 卸载

```bash
launchctl bootout gui/$(id -u)/com.nexus.notifsound
mv ~/Applications/NotifSound.app ~/.Trash/
mv ~/Library/LaunchAgents/com.nexus.notifsound.plist ~/.Trash/
```

## 日志

`~/data/notif-sound/logs/notif.log`，每条形如：

```
2026-10-28 23:02:14 attached to NotificationCenter pid 423
2026-10-28 23:02:14 play app=脚本编辑器 rule=脚本编辑器 sound=Glass text=NotifTest hello body
```

## 已知边界

- 只对「横幅 / 提醒」样式的通知有效；设为「无」的通知不会出现在 AX 树里。
- 专注模式（勿扰）下横幅不出现，自然也不会响——和系统行为一致。
- 通知中心的 AX 结构是未公开接口，macOS 大版本升级后可能需要调整 `collectBanners` 的匹配条件；
  菜单里的「重新连接通知中心」和日志可用于排查。
- 同一应用的同一条通知在 2 秒内重复出现会被去重。
- 需要辅助功能权限；没有该权限时程序会打开系统设置页面并每 5 秒重试。
