import AppKit
import AVFoundation
import SwiftUI

/// Uma permissão que o app precisa, com o estado atual e como resolvê-la.
struct PermissionItem: Identifiable {
    enum Kind: String, CaseIterable {
        case screenRecording
        case microphone
        case camera
        case accessibility

        var title: LocalizedStringKey {
            switch self {
            case .screenRecording: "Gravação de tela"
            case .microphone: "Microfone"
            case .camera: "Câmera"
            case .accessibility: "Acessibilidade"
            }
        }

        var explanation: LocalizedStringKey {
            switch self {
            case .screenRecording: "Necessária para capturar e gravar a tela. Sem ela, nada funciona."
            case .microphone: "Opcional. Só para narrar suas gravações."
            case .camera: "Opcional. Só para o vídeo sobreposto da câmera."
            case .accessibility: "Opcional. Habilita o zoom automático nos cliques durante a gravação."
            }
        }

        var symbol: String {
            switch self {
            case .screenRecording: "rectangle.inset.filled.badge.record"
            case .microphone: "mic"
            case .camera: "camera"
            case .accessibility: "accessibility"
            }
        }

        var isRequired: Bool { self == .screenRecording }

        /// Painel dos Ajustes correspondente.
        var settingsURL: URL? {
            let anchor = switch self {
            case .screenRecording: "Privacy_ScreenCapture"
            case .microphone: "Privacy_Microphone"
            case .camera: "Privacy_Camera"
            case .accessibility: "Privacy_Accessibility"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }
    }

    let kind: Kind
    var isGranted: Bool

    var id: String { kind.rawValue }
}

/// Tela de boas-vindas e central de permissões.
struct OnboardingView: View {
    @State private var permissions: [PermissionItem] = []
    @State private var appeared = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: FR.Space.sm) {
                    ForEach(permissions) { item in
                        PermissionRow(item: item) { refresh() }
                    }
                }
                .padding(FR.Space.lg)
            }

            Divider()

            HStack {
                Button("Verificar de novo") { refresh() }
                    .buttonStyle(.plain)
                    .font(FR.Font.callout)
                    .foregroundStyle(FR.Color.accent)
                Spacer()
                PrimaryButton(title: "Começar", symbol: "arrow.right") {
                    NSApp.keyWindow?.close()
                }
            }
            .padding(FR.Space.lg)
        }
        .frame(width: 560, height: 540)
        .background(FR.Color.surfaceRaised)
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // Ao voltar dos Ajustes, reavalia sem o usuário precisar pedir.
            refresh()
        }
    }

    private var header: some View {
        VStack(spacing: FR.Space.md) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(FR.Color.label)
                .frame(width: 72, height: 72)
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)

            Text("Frame")
                .font(FR.Font.display)
            Text("Capture, embeleze e grave a sua tela — tudo num app só.")
                .font(FR.Font.body)
                .foregroundStyle(FR.Color.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FR.Space.xxl)
        .padding(.bottom, FR.Space.lg)
        .onAppear { withAnimation(FR.Motion.expressive) { appeared = true } }
    }

    private func refresh() {
        permissions = PermissionItem.Kind.allCases.map { kind in
            PermissionItem(kind: kind, isGranted: isGranted(kind))
        }
    }

    private func isGranted(_ kind: PermissionItem.Kind) -> Bool {
        switch kind {
        case .screenRecording:
            CGPreflightScreenCaptureAccess()
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera:
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .accessibility:
            AXIsProcessTrusted()
        }
    }
}

private struct PermissionRow: View {
    let item: PermissionItem
    let onChange: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: FR.Space.md) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(item.isGranted ? FR.Color.success : FR.Color.labelSecondary)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: FR.Space.xs) {
                    Text(item.kind.title).font(FR.Font.headline)
                    if item.kind.isRequired {
                        Text("obrigatória")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(FR.Color.danger)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(FR.Color.danger.opacity(0.14)))
                    }
                }
                Text(item.kind.explanation)
                    .font(FR.Font.caption)
                    .foregroundStyle(FR.Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: FR.Space.sm)

            if item.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(FR.Color.success)
                    .symbolEffect(.bounce, value: item.isGranted)
            } else {
                SecondaryButton(title: "Permitir", symbol: "arrow.up.forward.app") {
                    request()
                }
            }
        }
        .padding(FR.Space.md)
        .background {
            RoundedRectangle(cornerRadius: FR.Radius.md, style: .continuous)
                .fill(FR.Color.label.opacity(isHovering ? 0.07 : 0.04))
        }
        .onHover { isHovering = $0 }
        .frAnimation(FR.Motion.quick, value: isHovering)
        .frAnimation(FR.Motion.bouncy, value: item.isGranted)
    }

    private func request() {
        switch item.kind {
        case .screenRecording:
            // O prompt do sistema só aparece uma vez; depois, só pelos Ajustes.
            if !CGRequestScreenCaptureAccess() { openSettings() }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in onChange() }
            }
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                Task { @MainActor in onChange() }
            }
        case .accessibility:
            // A constante do AX é `var` global e não é `Sendable`; o valor
            // literal é estável e evita o acesso concorrente.
            let options = ["AXTrustedCheckOptionPrompt": true]
            if !AXIsProcessTrustedWithOptions(options as CFDictionary) { openSettings() }
        }
        onChange()
    }

    private func openSettings() {
        guard let url = item.kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
