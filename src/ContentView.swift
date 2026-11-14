import AppKit
import SwiftUI

private let accent = Color(red: 0.42, green: 0.83, blue: 0.98)
private let accentDeep = Color(red: 0.55, green: 0.45, blue: 0.98)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var now = Date()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.11),
                                    Color(red: 0.10, green: 0.09, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        deviceCard
                        screenCard
                        permissionCard
                        statsCard
                        logCard
                    }
                    .padding(20)
                }
                .defaultScrollAnchor(.top)
                Divider()
                    .overlay(.white.opacity(0.07))
                actionBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .padding(.top, 4)
            }
        }
        .frame(minWidth: 560, idealWidth: 560, minHeight: 760)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshDevices() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: accentDeep.opacity(0.45), radius: 12, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text("iPad 扩展屏")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("USB 有线 · 4:3 原生比例 · 触控回传")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.8), radius: 4)
            Text(model.phase.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.08)))
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var statusColor: Color {
        switch model.phase {
        case .streaming: return Color(red: 0.35, green: 0.92, blue: 0.6)
        case .preparing: return Color(red: 0.98, green: 0.78, blue: 0.35)
        case .failed: return Color(red: 0.98, green: 0.42, blue: 0.42)
        case .idle: return .white.opacity(0.35)
        }
    }

    private var deviceCard: some View {
        Card(title: "连接设备", subtitle: "USB 直连，无需 Wi-Fi") {
            VStack(spacing: 10) {
                if model.devices.isEmpty {
                    HStack {
                        Text("没有检测到设备，请用数据线连接 iPad 并点按「信任」")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                } else {
                    ForEach(model.devices) { device in
                        deviceRow(device)
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        model.refreshDevices()
                    } label: {
                        Label("刷新设备", systemImage: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(SoftButtonStyle())
                    Spacer()
                    Text(verbatim: model.selectedDevice == nil ? "等待设备" : "端口 12346")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }

    private func deviceRow(_ device: MuxDevice) -> some View {
        let selected = model.selectedDeviceUDID == device.udid
        return Button {
            model.selectedDeviceUDID = device.udid
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.isUSB ? "ipad.landscape" : "wifi")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? accent : .white.opacity(0.5))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceTitle(device))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(verbatim: device.shortUDID)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .help(device.udid)
                }
                Spacer()
                Text(device.isUSB ? "USB" : "网络")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(device.isUSB ? accent : .white.opacity(0.45))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((device.isUSB ? accent : .white).opacity(0.12)))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? accent.opacity(0.10) : .white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? accent.opacity(0.55) : .white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func deviceTitle(_ device: MuxDevice) -> String {
        if let name = device.name, !name.isEmpty { return name }
        return device.model ?? "iPad"
    }

    private var screenCard: some View {
        Card(title: "虚拟屏幕", subtitle: "iPad Air 原生 2048×1536 · 4:3") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                          spacing: 8) {
                    ForEach(DisplayPreset.all) { preset in
                        presetTile(preset)
                    }
                }
                HStack(spacing: 10) {
                    Text("刷新率")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                    Picker("", selection: Binding(
                        get: { model.refreshRate },
                        set: { model.applyRefreshRate($0) }
                    )) {
                        Text("30 Hz").tag(30.0)
                        Text("60 Hz").tag(60.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    Text("码率")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                    Picker("", selection: $model.bitrateMbps) {
                        Text("8M").tag(8)
                        Text("12M").tag(12)
                        Text("20M").tag(20)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    Spacer()
                }
            }
        }
    }

    private func presetTile(_ preset: DisplayPreset) -> some View {
        let selected = model.preset == preset
        return Button {
            model.applyPreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.8))
                Text(preset.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(selected ? 0.6 : 0.35))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? accent.opacity(0.14) : .white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? accent.opacity(0.6) : .white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var permissionCard: some View {
        Card(title: "系统权限", subtitle: "首次使用需要各授权一次") {
            VStack(spacing: 8) {
                permissionRow(title: "屏幕录制",
                              detail: "采集虚拟屏幕画面",
                              state: model.screenPermission,
                              action: model.requestScreenPermission)
                permissionRow(title: "辅助功能",
                              detail: "把 iPad 触控变成鼠标点击",
                              state: model.accessibilityPermission,
                              action: model.requestAccessibilityPermission)
            }
        }
    }

    private func permissionRow(title: String, detail: String,
                               state: PermissionState, action: @escaping () -> Void) -> some View {
        let ok = state == .granted
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(ok ? Color(red: 0.35, green: 0.9, blue: 0.6) : Color(red: 0.98, green: 0.76, blue: 0.35))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            if !ok {
                Button("去授权", action: action)
                    .buttonStyle(SoftButtonStyle())
            } else {
                Text("已授权")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.03)))
    }

    private var statsCard: some View {
        Card(title: "运行状态", subtitle: model.stats.encodedWidth > 0
             ? "编码 \(model.stats.encodedWidth)×\(model.stats.encodedHeight)"
             : "等待开始") {
            HStack(spacing: 8) {
                statTile(value: String(format: "%.0f", model.stats.fps), unit: "fps", label: "帧率")
                statTile(value: String(format: "%.1f", model.stats.megabytesPerSecond), unit: "MB/s", label: "流量")
                statTile(value: "\(model.stats.frames)", unit: "帧", label: "累计")
                statTile(value: "\(model.stats.touches)", unit: "次", label: "触控")
            }
        }
    }

    private func statTile(value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(unit)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.04)))
    }

    private var logCard: some View {
        Card(title: "日志", subtitle: "\(model.logs.count) 条") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(model.logs.suffix(6).enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 96, alignment: .top)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.35)))
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                if model.phase.isBusy {
                    model.stop()
                } else {
                    model.start()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.phase.isBusy ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(model.phase.isBusy ? "断开连接" : "开始扩展")
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(model.phase.isBusy
                          ? LinearGradient(colors: [Color(red: 0.85, green: 0.32, blue: 0.38),
                                                    Color(red: 0.62, green: 0.24, blue: 0.42)],
                                           startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [accent, accentDeep],
                                           startPoint: .leading, endPoint: .trailing)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!model.phase.isBusy && !model.canStart)
            .opacity(!model.phase.isBusy && !model.canStart ? 0.45 : 1)
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.32))
            }
            content
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(0.07), lineWidth: 1))
    }
}

private struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }
}
