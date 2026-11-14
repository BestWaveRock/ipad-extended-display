# 传输协议

Mac 与 iPad 之间是一条**裸 TCP 流**（经 usbmux 隧道），双方都在上面跑同一套自定义分帧协议。
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
uint8  phase      0 = began，1 = moved，2 = ended/cancelled
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

## 连接建立

Mac 侧不监听端口，它主动"打洞"：

1. 连接 `/var/run/usbmuxd`（Unix domain socket）。
2. 发送 plist 请求 `MessageType = ListDevices`，拿到设备的 `DeviceID`。
   帧头同样是 16 字节，但这里的 `length` **包含 16 字节头**（usbmux 与上层协议在这一点上不同）。
3. 发送 `MessageType = Connect`，带 `DeviceID` 与 `PortNumber`（**网络字节序**）。
4. `usbmuxd` 返回 `Number = 0` 后，这条 socket 变成直通设备端口的裸 TCP 隧道。
5. iPad 端 `NWListener` 监听 `12346`，接受连接后开始等 `config` 包。

iPad 每次重连会 `cancel()` 掉旧连接、清空解码器，所以 Mac 侧断开重连是安全的。

## 端口

默认 `12346`。选这个端口是因为 `12345` 常年被各种调试工具占用（原型阶段就被一个探测 App 抢占过，导致连上了却是别人的监听）。
