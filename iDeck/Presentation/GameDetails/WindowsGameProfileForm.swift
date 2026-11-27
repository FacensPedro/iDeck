// WindowsGameProfileForm.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

struct WindowsGameProfileForm: View {
    @Binding var profile: WindowsGameProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailCard(title: tr("Display")) {
                DetailPickerRow(title: tr("Resolution"), selection: $profile.resolution,
                                choices: ["Device native", "960x540", "1280x720", "1600x900", "1920x1080"],
                                icon: "rectangle.on.rectangle", iconColor: .blue)
                DetailPickerRow(title: tr("Surface scaling"), selection: $profile.surfaceScaling,
                                choices: ["fit", "fill", "stretch", "aspect"],
                                icon: "arrow.up.left.and.arrow.down.right", iconColor: .blue)
                DetailPickerRow(title: tr("Frame rate limit"), selection: $profile.fpsLimit,
                                choices: WindowsGameProfile.fpsLimits,
                                icon: "speedometer", iconColor: .orange)
                DetailPickerRow(title: "MetalFX", selection: WindowsGameProfile.metalFXAllowed
                                    ? $profile.metalFXMode : .constant("Off"),
                                choices: WindowsGameProfile.metalFXModes, showsDivider: false,
                                icon: "sparkles", iconColor: .purple)
                    .disabled(!WindowsGameProfile.metalFXAllowed)
                if !WindowsGameProfile.metalFXAllowed {
                    Text(tr("Device not compatible with MetalFX"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
            DetailCard(title: tr("Graphics")) {
                DetailPickerRow(title: tr("Direct3D 12"), selection: $profile.d3d12Renderer,
                                choices: WindowsGameProfile.d3d12Renderers,
                                icon: "cube.transparent.fill", iconColor: .indigo)
                DetailPickerRow(title: tr("Vulkan"), selection: $profile.vulkanMode, choices: WindowsGameProfile.vulkanModes,
                                icon: "flame.fill", iconColor: .red)
                DetailPickerRow(title: tr("OpenGL"), selection: $profile.openGLBackend,
                                choices: WindowsGameProfile.openGLBackends, showsDivider: false,
                                icon: "circle.hexagongrid.fill", iconColor: .teal)
            }
            DetailCard(title: tr("Controls")) {
                DetailPickerRow(title: tr("Controller API"), selection: $profile.controllerAPI,
                                choices: ["Automatic"] + ControllerAPI.choices,
                                showsDivider: false, icon: "gamecontroller.fill", iconColor: .green,
                                label: ControllerAPI.label)
            }
            DetailCard(title: tr("Performance")) {
                // 0: iDeck decides (every core the device gives the game), shown as Automatic.
                DetailPickerRow(title: tr("CPU cores"), selection: Binding(
                                    get: { profile.cpuCount == 0 ? tr("Automatic") : String(profile.cpuCount) },
                                    set: { profile.cpuCount = Int($0) ?? 0 }),
                                choices: WindowsGameProfile.cpuCounts.map { $0 == 0 ? tr("Automatic") : String($0) },
                                icon: "cpu", iconColor: .blue)
                DetailPickerRow(title: tr("JIT pool"), selection: Binding(
                                    get: { profile.jitPoolMiB == 0 ? tr("Automatic") : "\(profile.jitPoolMiB) MB" },
                                    set: { value in profile.jitPoolMiB = Int(value.split(separator: " ").first ?? "") ?? 0 }),
                                choices: WindowsGameProfile.jitPoolChoices.map { $0 == 0 ? tr("Automatic") : "\($0) MB" },
                                icon: "memorychip", iconColor: .orange)
                DetailToggleRow(title: tr("Fast synchronization"), isOn: $profile.fastSync, showsDivider: false,
                                icon: "bolt.fill", iconColor: .yellow)
            }
            DetailCard(title: tr("Compatibility")) {
                DetailToggleRow(title: tr("Use recommended settings"), isOn: $profile.useRecommended,
                                icon: "checkmark.seal.fill", iconColor: .green)
                DetailPickerRow(title: tr("Code checks"), selection: $profile.codeChecks,
                                choices: WindowsGameProfile.codeCheckModes,
                                icon: "checkmark.shield.fill", iconColor: .orange)
                DetailToggleRow(title: tr("Keep helper processes running"),
                                isOn: $profile.keepChildProcessesRunning,
                                icon: "square.stack.3d.up.fill", iconColor: .gray)
                DetailButtonRow(title: tr("Reset to Recommended"), systemImage: "arrow.counterclockwise",
                                showsDivider: false) {
                    GameRecommendations.applySwitches(for: profile.id, to: &profile)
                }
            }
            DetailCard(title: tr("Launch arguments")) {
                TextField(tr("Example: -windowed"), text: $profile.arguments)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
            }
        }
    }
}
