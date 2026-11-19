# WQ Tones — 在 iOS 27.3 Beta 1 上静音通话录音提示音

用 `worse_query` 沙盒逃逸直接读写 `/var/mobile/Library/CallServices/Greetings/default`，
不依赖 airlift（那条路 27.2 b3 就被 Apple 修了），也不需要配对文件 / LocalDevVPN。

> **只在 iOS 26.0–26.7.2 与 iOS 27.0–27.3 Beta 1 有效。27.3 Beta 2 起 Apple 已修补 worse_query。**
> 只在你自己持有的设备上使用；部分地区对「通话录音需双方知情」有法律要求，自担。

---

## 为什么需要自己编一个 App

WQ Files 的「前往路径」只能打开**容器**，而提示音目录在 mobile 用户共享库里，所以它拒绝。
但 worse_query 本身对 symlink 的目标路径没有任何限制（见 [PoC 源码](https://github.com/forcequitOS/worse_query)），
这个 App 就是把 PoC 接上一个最小界面，让目标指向提示音目录。

## 一、编译（不需要 Mac）

1. 在 GitHub 新建一个**公开**仓库（Actions 对公开仓库免费）。
2. 把本目录所有文件推上去（保持 `Sources/`、`Resources/`、`project.yml`、`.github/workflows/build.yml` 的结构）。
3. 打开仓库 **Actions** → **Build unsigned IPA** → **Run workflow**。
4. 等 3–5 分钟，进这次运行 → 底部 **Artifacts** → 下载 `WQTones-unsigned-ipa`，解压得到 `WQTones-unsigned.ipa`。

需要本地 Mac 也可以：`brew install xcodegen && xcodegen generate`，然后 Xcode 打开直接 Archive（记得关签名）。

## 二、签名安装（必须带 App Group）

- ✅ **AltStore / SideStore / Impactor**（Apple ID 登录）：会自动补 App Group，**推荐**
- ❌ Sideloadly、以及通配符证书（App ID 为 `*`）的 ESign/Feather：拿不到 App Group，App 顶部会显示「App Group: (缺失)」

装好后打开，顶部应显示 `App Group: group.xxxx`。没有就换签名工具。

## 三、使用

| 按钮 | 作用 |
|---|---|
| 检测访问 | 申请沙盒令牌并列出目标目录，验证这条路是否通 |
| 备份原件 | 把三个原始提示音读到 App 的 `Documents/WQTonesBackups` |
| 写入静音 | 用包内静音文件覆盖系统提示音（等长、静音） |
| 还原原件 | 从备份写回 |

**顺序：检测访问 → 备份原件 → 写入静音。** 然后拨一通真电话点录音验证，再重启复测一次。

备份也能在「文件」App 里看到：`我的 iPhone → WQ Tones → WQTonesBackups`。

## 四、结果怎么看

| 日志 | 含义 |
|---|---|
| `✓ 令牌成功，目录内容: (...)` | 通了，可以备份/写入 |
| `内核拒绝签发 sandbox extension (-6)` | 该目标路径被内核拒绝，这条路也不通 |
| `containermanagerd 拒绝了查询 (-5)` | 容器管理器不接受这个组/目标 |
| `没有拿到 App Group (-1)` | 签名丢了授权，换 AltStore/SideStore 重签 |
| `目标路径不存在 (-255)` | 27.3 中文版可能改了路径，需要先找出来 |

## 五、还原

- App 内「还原原件」；
- 或在「文件」App 把 `WQTonesBackups` 里的文件手动放回（需要 WQ Files 之类的工具）；
- 极端情况：设置 → 通用 → 语言与地区，换一次系统语言，iOS 会重新生成原始提示音。

## 许可

本工程包含的 `worse_query` 实现改编自
[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)（Copyright (C) 2026 Taj C，GPL-3.0-or-later）。
据此本工程整体按 **GPL-3.0-or-later** 发布，`Sources/main.m` 头部保留了原始版权与许可声明。
