# 传输协议

Mac 与 iPad 之间是一条**裸 TCP 流**（USB 走 usbmux 隧道，Wi‑Fi 直接连 iPad 的局域网地址），双方都在上面跑同一套自定义分帧协议。
协议刻意做得很小：一个 8 字节头 + 定长负载，没有握手、没有重传，靠 TCP 自己保证顺序。

## 分帧格式

所有数据包（两个方向）都是：

```
0        4        8
+--------+--------+-------------------+
| length | type   | reserved (4B = 0) |  payload (length bytes)
+--------+--------+-------------------+
```

| 字段 | 长度 | 说明 |
| --- | --- | --- |
| `length` | 4 | 负载长度，**大端** uint32，不含 8 字节头 |
| `type` | 1 | 消息类型，见下表 |
| `reserved` | 3 | 补齐，恒为 0 |

### 消息类型

| 值 | 名称 | 方向 | 说明 |
| --- | --- | --- | --- |
| `1` | `config` | Mac → iPad | H.264 参数集（SPS/PPS）与画面尺寸 |
| `2` | `videoFrame` | Mac → iPad | 一个 AVCC 格式的访问单元（4 字节长度前缀的 NAL） |
| `3` | `touch` | iPad → Mac | 触控事件 |
| `4` | `audioConfig` | Mac → iPad | 音频格式协商（采样率 / 声道 / 位深） |
| `5` | `audioFrame` | Mac → iPad | 一帧裸 PCM 数据 |
| `6` | `keyboard` | Mac → iPad | 通知 iPad 唤起 / 收起软键盘 |
| `7` | `textInput` | iPad → Mac | 文字输入、退格、回车 |
| `8` | `scroll` | iPad → Mac | 滑动模式的滚动增量 |

## config（type = 1）

每次编码器重建（启动、切分辨率、切刷新率）后先发一包，iPad 收到后重建 `CMVideoFormatDescription`。

```
uint16 width      画面宽度，大端
uint16 height     画面高度，大端
uint32 spsLength  SPS 长度，大端
byte[] sps
uint32 ppsLength  PPS 长度，大端
byte[] pps
```

## videoFrame（type = 2）

负载是 `VTCompressionSession` 输出的 CMSampleBuffer 数据块，即 **AVCC / length-prefixed** 格式：
`[4 字节大端 NAL 长度][NAL][4 字节长度][NAL]…`。

iPad 侧把它塞进 `CMBlockBuffer`，配上 `nalUnitHeaderLength = 4` 的 format description，直接喂给 `AVSampleBufferDisplayLayer`。

编码参数：H.264、无 B 帧、`RealTime = true`、关键帧间隔 = 3 秒、码率可配。

## touch（type = 3）

```
uint8  phase      0 = began（含左键按下），1 = moved（拖动），2 = ended（含左键抬起），
                  3 = 只移动光标不点击，4 = 在坐标处右键单击
float32 x         归一化 0…1，大端
float32 y         归一化 0…1，大端
```

负载固定 9 字节。Mac 端收到后按虚拟屏的 `CGDisplayBounds` 换算成全局坐标：

```
point = (bounds.origin.x + x * bounds.width,
         bounds.origin.y + y * bounds.height)
```

然后投递 `mouseMoved` + `leftMouseDown/Dragged/Up` 三种 `CGEvent`（`.cghidEventTap`）。

**注意**：坐标是相对 iPad 整个屏幕归一化的，不是相对视频画面内容。如果虚拟屏比例和 iPad 屏幕比例不一致导致画面出现黑边，边缘区域的点击会有偏移。默认的 4:3 预设不存在这个问题。

`phase = 3`（滑动模式的首次落指）只投递 `mouseMoved`；`phase = 4`（双指轻点）先移动光标再投递 `rightMouseDown/rightMouseUp`。

## keyboard（type = 6）

```
uint8 visible     1 = 唤起 iPad 软键盘，0 = 收起
```

负载固定 1 字节。Mac 用辅助功能 API 每 0.5 秒检查一次焦点元素：落在 `AXTextField` / `AXTextArea` / `AXComboBox` / 搜索框上就发 `1`，离开就发 `0`。

## textInput（type = 7）

```
uint8 kind        0 = 插入文字，1 = 退格，2 = 回车
byte[] utf8       kind = 0 时的 UTF-8 文本，其它 kind 为空
```

Mac 收到后用 `CGEvent.keyboardSetUnicodeString` 投递按键，所以中文、emoji 都能直接落到当前输入框；退格与回车分别用虚拟键码 51 / 36。

iPad 端用一个 1×1 的 `UIKeyInput` 视图接收系统键盘输入：输入法组词由系统处理，最终 `insertText` 拿到的就是成品文字。

## scroll（type = 8）

```
float32 dx       手指横向位移，大端（正 = 向右）
float32 dy       手指纵向位移，大端（正 = 向下）
```

只在「滑动模式」下发送。iPad 每次 `touchesMoved` 把位移方向归一化成固定 12 像素的增量，所以滚动速度恒定、只跟方向有关，跟手指快慢无关。Mac 侧换算成 `CGEvent` 的双轴滚动：

```
wheel1 = -dy   （自然滚动：手指向下 → 内容向下）
wheel2 = dx
```

## audioConfig（type = 4）

开启"音频透传"后，Mac 在建立隧道时先发一包，iPad 收到后建 `AVAudioEngine` 播放链路。

```
uint32 sampleRate  采样率，大端（当前固定 48000）
uint16 channels    声道数，大端（当前固定 2）
uint16 bits        位深，大端（当前固定 16）
```

负载固定 8 字节。Mac 端在每次推流开始（包括切分辨率、切刷新率导致的重连）都会重发一次。

## audioFrame（type = 5）

负载是**裸 PCM**：交错立体声、16 bit 有符号、小端、48 kHz，没有包头也没有时间戳。

```
int16 left, int16 right, int16 left, int16 right, …
```

iPad 侧按 `audioConfig` 声明的格式建 `AVAudioPCMBuffer` 直接 `scheduleBuffer` 播放；采样率固定，所以不需要重采样。

数据源是 `ScreenCaptureKit` 的 `.audio` 输出（`capturesAudio = true`、`sampleRate = 48000`、`channelCount = 2`）。Mac 端把 `Float32`（planar 或 interleaved 都支持）削顶到 ±1 后线性映射成 `Int16`，因此链路里没有任何压缩，音质等于系统音源。

Mac 端默认 `excludesCurrentProcessAudio = true`，只排掉本应用自己的声音，其它 App 的声音都会被采集。

带宽开销约 192 KB/s（48000 × 2 声道 × 2 字节），相对于 H.264 视频流很小；USB 2.0 和普通 5 GHz Wi‑Fi 都无压力。

## 连接建立

Mac 侧不监听端口，它主动"打洞"：

1. 连接 `/var/run/usbmuxd`（Unix domain socket）。
2. 发送 plist 请求 `MessageType = ListDevices`，拿到设备的 `DeviceID`。
   帧头同样是 16 字节，但这里的 `length` **包含 16 字节头**（usbmux 与上层协议在这一点上不同）。
3. 发送 `MessageType = Connect`，带 `DeviceID` 与 `PortNumber`（**网络字节序**）。
4. `usbmuxd` 返回 `Number = 0` 后，这条 socket 变成直通设备端口的裸 TCP 隧道。
5. iPad 端 `NWListener` 监听 `12346`，接受连接后开始等 `config` 包。

iPad 每次重连会 `cancel()` 掉旧连接、清空解码器，所以 Mac 侧断开重连是安全的。

Wi‑Fi 走的是完全相同的分帧协议，只是第一条隧道换成普通 TCP：

1. iPad 端 `NWListener` 启动时把自己注册成 Bonjour 服务 `_ipaddisplay._tcp`（名字就是设备名）。
2. Mac 端用 `NetServiceBrowser` 搜 `_ipaddisplay._tcp.`，解析出 `hostName` + `port`。
3. Mac 直接 `connect()` 到该地址，之后就是同一条裸 TCP 流，包格式一字不差。

所以 Wi‑Fi 模式不需要额外的中继或转发进程，`usbmuxd` 也完全不参与。

## 端口

默认 `12346`。选这个端口是因为 `12345` 常年被各种调试工具占用（原型阶段就被一个探测 App 抢占过，导致连上了却是别人的监听）。
