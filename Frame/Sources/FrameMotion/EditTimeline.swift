import SwiftUI

/// Linha do tempo do editor de vídeo.
///
/// Mostra, em faixas empilhadas: os zooms, os cortes e os textos. Arrastar em
/// qualquer ponto move o cabeçote — a interação principal é o scrubbing.
struct EditTimeline: View {
    @Bindable var project: VideoProject
    @Bindable var preview: VideoPreviewController

    @State private var draggingKeyframe: ZoomKeyframe.ID?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(preview.duration, 0.001)

            VStack(spacing: FR.Space.xs) {
                ruler(width: width, duration: duration)
                    .frame(height: 16)

                track(label: "Zoom", symbol: "plus.magnifyingglass") {
                    ForEach(project.edit.zoomKeyframes) { keyframe in
                        segment(
                            start: keyframe.startTime,
                            end: keyframe.endTime,
                            duration: duration,
                            width: width,
                            color: FR.Color.accent
                        ) {
                            Text(String(format: "%.1f×", keyframe.scale))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }

                track(label: "Cortes", symbol: "scissors") {
                    ForEach(project.edit.cuts) { cut in
                        segment(
                            start: cut.startTime,
                            end: cut.endTime,
                            duration: duration,
                            width: width,
                            color: FR.Color.danger
                        ) { EmptyView() }
                        .contextMenu {
                            Button("Remover corte", role: .destructive) {
                                project.edit.cuts.removeAll { $0.id == cut.id }
                            }
                        }
                    }
                }

                track(label: "Texto", symbol: "textformat") {
                    ForEach(project.edit.textOverlays) { overlay in
                        segment(
                            start: overlay.startTime,
                            end: overlay.endTime,
                            duration: duration,
                            width: width,
                            color: FR.Color.success
                        ) {
                            Text(overlay.text)
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                        }
                        .contextMenu {
                            Button("Remover texto", role: .destructive) {
                                project.edit.textOverlays.removeAll { $0.id == overlay.id }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, FR.Space.md)
            .padding(.vertical, FR.Space.sm)
            .overlay(alignment: .topLeading) {
                playhead(width: width, duration: duration, height: geometry.size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = (value.location.x - FR.Space.md) / max(1, width - FR.Space.md * 2)
                        preview.seek(to: Double(min(max(0, ratio), 1)) * duration)
                    }
            )
        }
        .background(FR.Color.surface)
    }

    // MARK: - Componentes

    private func ruler(width: CGFloat, duration: Double) -> some View {
        // Marcas a cada 1, 5, 10 ou 30s, conforme a duração cabe na largura.
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60]
        let interval = candidates.first { duration / $0 <= 14 } ?? 60
        let count = Int(duration / interval)

        return ZStack(alignment: .topLeading) {
            ForEach(0...max(count, 0), id: \.self) { index in
                let time = Double(index) * interval
                let x = CGFloat(time / duration) * (width - FR.Space.md * 2)
                VStack(alignment: .leading, spacing: 1) {
                    Rectangle()
                        .fill(FR.Color.separator)
                        .frame(width: 1, height: 4)
                    Text(format(time))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(FR.Color.labelTertiary)
                }
                .offset(x: x)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func track<Content: View>(
        label: LocalizedStringKey,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: FR.Space.sm) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 8))
                Text(label).font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(FR.Color.labelTertiary)
            .frame(width: 52, alignment: .leading)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(FR.Color.label.opacity(0.05))
                content()
            }
            .frame(height: 22)
        }
    }

    private func segment<Content: View>(
        start: Double,
        end: Double,
        duration: Double,
        width: CGFloat,
        color: Color,
        @ViewBuilder label: () -> Content
    ) -> some View {
        // A faixa é deslocada pelos 52pt do rótulo e pelo espaçamento.
        let available = width - FR.Space.md * 2 - 52 - FR.Space.sm
        let x = CGFloat(start / duration) * available
        let segmentWidth = max(3, CGFloat((end - start) / duration) * available)

        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color.opacity(0.85))
            .frame(width: segmentWidth, height: 22)
            .overlay { label() }
            .offset(x: x)
    }

    private func playhead(width: CGFloat, duration: Double, height: CGFloat) -> some View {
        let available = width - FR.Space.md * 2
        let x = FR.Space.md + CGFloat(preview.currentTime / duration) * available

        return ZStack(alignment: .top) {
            Rectangle()
                .fill(FR.Color.label)
                .frame(width: 1.5, height: height)
            Circle()
                .fill(FR.Color.label)
                .frame(width: 7, height: 7)
                .offset(y: -2)
        }
        .offset(x: x)
        .allowsHitTesting(false)
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
