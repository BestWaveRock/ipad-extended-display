# iPad 扩展屏 · iPad Extended Display

把一台跑不动 Sidecar 的老 iPad（甚至 iOS 12）变成 Mac 的第二块屏幕：**纯 USB 有线传输、4:3 原生比例、H.264 硬解上屏、触控反向回传**。

![应用截图](docs/screenshot.png)

这个项目一开始只是想验证一件事：一台 iOS 12.5.8 的 iPad Air 1，官方 Sidecar 不支持、Duet 新版要 iOS 13、Splashtop XDisplay 又依赖已废弃的内核扩展，那它到底还能不能当副屏？

结论是能，而且不需要装任何驱动或内核扩展：自签名 App 在 iPad 上监听一个端口，Mac 通过 usbmux（就是 iTunes / Xcode 用来跟设备通信的那条 USB 通道）打洞进去，把屏幕画面用 H.264 推过去，iPad 用 `AVSampleBufferDisplayLayer` 硬解显示。

> 想看这条路是怎么试出来的（Sidecar / Duet / kext 各自为什么走不通、两个真坑长什么样）：[docs/story.md](docs/story.md)

## 特性

- **纯 USB**：走 usbmux 通道，不依赖 Wi-Fi，不受路由器、5GHz、隔墙影响，延迟稳定在个位数毫秒级。
- **原样 4:3**：iPad Air 原生 2048×1536，虚拟屏按 4:3 建，画面点对点没有黑边、没有拉伸。
- **不装驱动**：不需要内核扩展（kext），不需要关闭 SIP，不需要改系统文件。
- **自带虚拟屏**：应用内直接创建虚拟显示器（`CGVirtualDisplay`），不再需要 BetterDisplay 之类的第三方工具。
- **零依赖**：自己实现了 usbmux 协议客户端，不需要 `iproxy`、不需要 `libimobiledevice`、不需要 Homebrew。
- **触控回传**：在 iPad 上点、拖、滑，Mac 上就是对应的鼠标事件，可以直接操作副屏窗口。
- **可调参数**：4 档分辨率、30/60Hz 刷新率、8/12/20 Mbps 码率，运行中可实时切换。
- **命令行版本**：附带同引擎的 CLI，方便脚本化或排障。

## 实测性能

测试机：iPad Air 1（iPad4,1，iOS 12.5.8） + Apple Silicon Mac，USB 2.0（480 Mbps）。

| 场景 | 帧率 | 码率 |
| --- | --- | --- |
| 静态桌面 | 5–15 fps（内容不变时编码器自动降帧） | 150–250 KB/s |
| 滚动网页 / 拖窗口 | 30–60 fps | 1.5–2 MB/s |
| 播放视频 | 30–60 fps | 3–6 MB/s |

USB 2.0 的带宽（理论 60 MB/s）远超 H.264 的需求，所以画面质量主要取决于 iPad 的硬解能力和码率设置，而不是链路。

## 工作原理

```
┌──────────────────────── Mac ────────────────────────┐       ┌────── iPad ──────┐
│                                                     │       │                  │
│  CGVirtualDisplay ──► ScreenCaptureKit ──► VideoToolbox │       │                  │
│  （创建 2048×1536      （采集像素缓冲）      （H.264 硬编）│       │                  │
│    虚拟显示器）                                      │       │                  │
│         ▲                                  │        │       │                  │
│         │ 鼠标事件                          ▼        │       │                  │
│  CGEvent.post ◄──── 触控包 ◄──── usbmuxd 隧道 ◄──────┼──USB──┼─► NWListener     │
│                                                     │       │    :12346        │
│                                                     │       │       │          │
│                                                     │       │       ▼          │
│                                                     │       │  AVSampleBuffer  │
│                                                     │       │  DisplayLayer    │
└─────────────────────────────────────────────────────┘       └──────────────────┘
```

三段链路：

1. **虚拟显示器**：Mac 端用私有类 `CGVirtualDisplay` 在系统里注册一块 2048×1536 的虚拟屏，系统把它当成真的外接显示器，窗口可以拖过去。
2. **采集与编码**：`ScreenCaptureKit` 按虚拟屏 ID 采集像素，`VideoToolbox` 实时编成 H.264（Baseline/Main，无 B 帧，低延迟）。
3. **USB 传输**：Mac 直接连 `usbmuxd` 的 Unix socket，用 plist 协议请求「连接到设备 12346 端口」，之后这条 socket 就是一条裸 TCP 隧道；iPad 端用 `NWListener` 监听同一端口，收到包后用 `AVSampleBufferDisplayLayer` 硬解显示。

触控走反方向：`UIGestureRecognizer` 级别的 `touchesBegan/Moved/Ended` → 归一化坐标 → 同一个隧道回传 → Mac 用 `CGEvent` 投递鼠标事件到虚拟屏坐标。

协议细节见 [docs/protocol.md](docs/protocol.md)。

## 系统要求

| 端 | 要求 |
| --- | --- |
| Mac | macOS 14 或更新（`CGVirtualDisplay` / ScreenCaptureKit 需要），Apple Silicon 或 Intel |
| iPad | iOS 12 或更新（iPad Air 1 / iPad 5 / 6 代等 4:3 机型效果最好） |
| 连接 | Lightning 或 USB-C 数据线（能传数据的线，不是纯充电线） |

## 快速开始

### 第一步：iPad 端安装 App

项目提供已打包好的 `iPadDisplay.ipa`（`ios/iPadDisplay.ipa`，也可从 Releases 下载）。

因为这是自签名应用，需要用 **iLoader**（或 SideStore / AltStore 这类工具）装进 iPad：

1. 在 Mac 上打开 iLoader，用 Apple ID 登录（免费账号即可）。
2. 设备列表里选中你的 iPad，点「导入 IPA」，选择 `iPadDisplay.ipa`。
3. 点安装，等待进度完成。
4. iPad 桌面上会出现 **iPad 扩展屏** 图标，点开它。
5. 如果提示「不受信任的开发者」，去 iPad 的 `设置 → 通用 → VPN 与设备管理` 里信任你的 Apple ID 证书。

> **关于 iLoader**：它是一个 iOS 侧载（sideload）工具，作用是拿你的 Apple ID 给 IPA 重新签名，让系统允许安装非 App Store 应用。免费 Apple ID 签出来的证书 **7 天过期**，过期后 App 打不开，回到 iLoader 重新签一次即可（数据不会丢）。这也是为什么本项目必须开源：你随时可以自己重新打包、重新签名。

打开 App 后它会长这样：黑屏 + 一行 `等待 Mac 连接…(listening :12346)`。**请保持 App 在前台、不要锁屏**（iOS 12 会在切后台时挂起进程，画面会中断，回到前台会自动恢复）。

### 第二步：Mac 端安装

1. 打开 `iPad-Extended-Display-1.0.0.dmg`，把 **iPad 扩展屏** 拖进「应用程序」。
2. 首次打开会被 Gatekeeper 拦一下（应用是 ad-hoc 签名，没有 Apple 公证）：右键点图标 →「打开」，或到 `系统设置 → 隐私与安全性` 里点「仍要打开」。
3. 按提示授权两项权限：
   - **屏幕录制**：采集虚拟屏画面必需。授权后需要**退出并重新打开应用**才生效。
   - **辅助功能**：把 iPad 上的触控变成 Mac 上的鼠标点击。不授权也能看画面，但点不动。
4. 用数据线连接 iPad，iPad 上点「信任」。
5. 应用里点「刷新设备」，选中你的 iPad，点「开始扩展」。

成功后系统会多出一块显示器，把窗口往那个方向拖就行。iPad 上会立刻出现画面。

### 第三步：调整

- **分辨率**：`1024×768` 是推荐值——虚拟屏以 2 倍渲染，实际像素 2048×1536，正好是 iPad Air 的原生分辨率，字大且清晰。想要更大桌面就选 `2048×1536`（1:1 像素，但字会很小）。
- **刷新率**：30Hz 更省电、更省带宽；60Hz 更跟手。运行中切换会自动重连。
- **码率**：8 Mbps 适合看文档，20 Mbps 适合看视频/图片。

## 命令行版本

`mac/ipad-usb-display` 是同一套引擎的 CLI，方便排障：

```bash
cd mac
./build.sh
./ipad-usb-display --preset 1024 --refresh 60 --bitrate 12
```

参数：

| 参数 | 说明 |
| --- | --- |
| `--preset` | `1024` / `1280` / `1600` / `2048` |
| `--refresh` | `30` 或 `60` |
| `--bitrate` | 码率，单位 Mbps |
| `--port` | iPad 端监听端口，默认 `12346` |
| `--host` | 不连 iPad，改连指定地址（排障用：`--host 127.0.0.1 --port 23457` 可以只验证采集与编码） |

接上设备后正常输出：

```
[22:44:23] 设备 0f3c9a51…7d2b8e
[22:44:25] 虚拟屏 1024 × 768 · 像素 2048×1536
[22:44:26] 隧道已建立 (fd 3)
[22:44:26] 开始采集 2048×1536 @60fps
[22:44:27] 20.7 fps · 0.7 MB/s · 触控 0 · 丢帧 0
[22:45:32] 30.9 fps · 0.2 MB/s · 触控 2 · 丢帧 0
```

桌面静止时帧率会掉到 0（ScreenCaptureKit 只在画面变化时出帧），这是正常的省带宽行为，iPad 上会一直显示最后一帧。

## 从源码构建

```bash
# Mac 应用（生成 build/iPad 扩展屏.app）
./src/build-app.sh

# DMG 安装包（生成 dist/iPad-Extended-Display-1.0.0.dmg）
./package.sh

# iPad 端 IPA（生成 ios/iPadDisplay.ipa）
./ios/build.sh
```

构建 IPA 需要 Xcode 命令行工具（`xcode-select --install`），并会把产物复制到 `~/Downloads/iPadDisplay.ipa`。

## 分辨率与画面比例

iPad Air 1/2、iPad 5/6 代、iPad Pro 9.7 的屏幕都是 **2048×1536（4:3）**，逻辑分辨率 1024×768 @2x。本项目默认按这个尺寸建虚拟屏，所以画面是点对点的。

其他机型（iPad 10.2" 是 2160×1620，iPad Air 4/5 是 2360×1640，iPad Pro 12.9" 是 2732×2048）也能用，但需要调整 `src/VirtualDisplay.swift` 里的 `pixelWidth` / `pixelHeight` 与预设列表，否则画面会被 iPad 缩放，略微发虚。

## 第三方工具说明

为了避免误会，这里说清楚每个外部工具在整条链路中的角色：

| 工具 | 是否必需 | 作用 |
| --- | --- | --- |
| **iLoader** | 必需（iPad 端） | iOS 侧载工具，用你的 Apple ID 给 `iPadDisplay.ipa` 重新签名并安装。免费账号签名 7 天过期。同类替代品：SideStore、AltStore、Sideloadly。 |
| **BetterDisplay** | **不再需要** | 早期原型用它的虚拟屏功能做验证，现在 Mac 端用 `CGVirtualDisplay` 自己建虚拟屏，完全独立。若你已经在用 BetterDisplay 管理多显示器，二者不冲突。 |
| **libimobiledevice / iproxy** | **不再需要** | 早期原型靠 `iproxy` 转发端口。现在应用内置了 usbmux 客户端，直接和 `usbmuxd` 通信。 |
| **Xcode 命令行工具** | 仅构建时需要 | 编译 Swift 源码、打包 IPA。普通用户用现成的 DMG 即可。 |

## 常见问题

**iPad 上一直显示「等待 Mac 连接」**

先确认数据线能传数据（换一根线试试），iPad 上要点「信任此电脑」。然后在应用里点「刷新设备」，确认设备标签是 `USB` 而不是「网络」。如果 iPad App 被切到后台或锁屏，它会停止监听，重新打开即可。

**有画面但点不动**

辅助功能权限没给。去 `系统设置 → 隐私与安全性 → 辅助功能` 勾选「iPad 扩展屏」，然后重启应用。

**点「开始扩展」提示缺少屏幕录制权限**

去 `系统设置 → 隐私与安全性 → 屏幕录制` 勾选「iPad 扩展屏」，然后**完全退出应用再打开**。macOS 只在进程启动时检查这个权限。

**画面很卡 / 掉帧**

先把码率降到 8 Mbps、刷新率降到 30Hz。另外确认 iPad 没有处于低电量模式（会限制解码性能），并且 App 在前台。

**虚拟屏在「显示器」设置里删不掉**

虚拟屏的生命周期跟创建它的进程绑定，退出应用后它会自动消失。如果残留，注销一次或重启即可。

**7 天后 App 打不开**

免费 Apple ID 签名过期了。用 iLoader 重新签名安装一次，数据不会丢。

**装好后桌面图标是空白的**

早期版本在 `Info.plist` 里写了 `CFBundleIconName = AppIcon`，但没有对应的 `Assets.car` 资产目录，系统找不到图标就画成空白。现在已去掉这个键，改为完整的 `CFBundleIconFiles` 列表（含 iPad 需要的 76/83.5 尺寸，且全部去掉 alpha 通道）。

重装后如果还是空白，是 SpringBoard 的图标缓存没刷新：先删掉旧图标，重启一次 iPad 再装。

## 已知限制

- iPad 端 App 必须在前台，iOS 12 不支持后台保持网络监听。
- 只推画面和触控：键盘输入、剪贴板同步、Apple Pencil 压感、音频回传都还没做。
- 虚拟屏切换分辨率偶尔会被系统拒绝一次（`CGErrorFailure`），代码里做了重试，极少数情况下需要再点一次。
- 触控坐标按整屏归一化映射；当 iPad 上的画面有黑边（分辨率比例不是 4:3）时，边缘区域会有偏移。
- ad-hoc 签名 + 无公证：首次启动需要右键打开，且每次重新构建后 TCC 权限可能需要重新授权。
- 未在 Intel Mac 上实测。

## 许可

[MIT](LICENSE)。欢迎提 issue 和 PR，尤其是其他 iPad 型号的分辨率预设、Apple Pencil、键盘输入方向。
