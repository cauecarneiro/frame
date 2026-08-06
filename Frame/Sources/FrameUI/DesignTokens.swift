import SwiftUI

/// Design tokens do Frame.
///
/// Uma escala única de espaçamento, raio, tipografia e movimento. Tudo na UI
/// puxa daqui — nenhum valor mágico solto nas views.
enum FR {

    // MARK: - Espaçamento (escala base 4pt)

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // MARK: - Raio de canto

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let pill: CGFloat = 999
    }

    // MARK: - Cor

    enum Color {
        /// Único acento do app: o azul do sistema, o mesmo que a Apple usa em
        /// botões padrão. Nada de cor de marca própria — a interface é neutra e
        /// a cor só aparece onde indica ação ou seleção.
        static let accent = SwiftUI.Color(nsColor: .systemBlue)
        static let accentSoft = SwiftUI.Color(nsColor: .systemBlue).opacity(0.12)

        static let surface = SwiftUI.Color(nsColor: .controlBackgroundColor)
        static let surfaceRaised = SwiftUI.Color(nsColor: .windowBackgroundColor)

        static let label = SwiftUI.Color(nsColor: .labelColor)
        static let labelSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        static let labelTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)

        static let separator = SwiftUI.Color(nsColor: .separatorColor)

        static let danger = SwiftUI.Color(nsColor: .systemRed)
        static let success = SwiftUI.Color(nsColor: .systemGreen)
        static let recording = SwiftUI.Color(nsColor: .systemRed)

        /// Paleta oferecida nas ferramentas de anotação. Vermelho primeiro —
        /// é o padrão de quem marca um print.
        static let annotationSwatches: [SwiftUI.Color] = [
            SwiftUI.Color(nsColor: .systemRed),
            SwiftUI.Color(nsColor: .systemOrange),
            SwiftUI.Color(nsColor: .systemYellow),
            SwiftUI.Color(nsColor: .systemGreen),
            SwiftUI.Color(nsColor: .systemBlue),
            .white,
            .black,
        ]
    }

    // MARK: - Tipografia

    enum Font {
        // SF Pro puro, sem `design: .rounded` — é a tipografia que a HIG
        // define para macOS e a que o resto do sistema usa.
        static let display = SwiftUI.Font.system(size: 26, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 19, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let callout = SwiftUI.Font.system(size: 12, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        static let mono = SwiftUI.Font.system(size: 12, weight: .regular, design: .monospaced)
        /// Numerais de largura fixa — timecodes, dimensões, contadores.
        static let numeric = SwiftUI.Font.system(size: 12, weight: .medium).monospacedDigit()
    }

    // MARK: - Movimento

    /// Curvas de animação. Todo movimento do app sai de uma destas — é o que
    /// mantém a sensação coesa entre captura, editor e timeline.
    enum Motion {
        /// Transições de estado corriqueiras: hover, seleção, toggle.
        static let quick = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.86)
        /// Padrão para aparecimento e movimento de painéis.
        static let standard = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.82)
        /// Transições grandes: captura → editor, abrir projeto.
        static let expressive = SwiftUI.Animation.spring(response: 0.58, dampingFraction: 0.78)
        /// Com um leve overshoot, para confirmações e entradas de conteúdo.
        static let bouncy = SwiftUI.Animation.spring(response: 0.46, dampingFraction: 0.66)
        /// Movimento contínuo sem inércia — scrubbing da timeline.
        static let linearFast = SwiftUI.Animation.easeOut(duration: 0.12)
    }

    // MARK: - Sombra

    struct Shadow {
        let color: SwiftUI.Color
        let radius: CGFloat
        let y: CGFloat

        static let sm = Shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        static let md = Shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        static let lg = Shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        static let xl = Shadow(color: .black.opacity(0.30), radius: 56, y: 22)
    }
}

extension View {
    func frShadow(_ shadow: FR.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }

    /// Aplica uma animação respeitando a preferência de movimento reduzido.
    ///
    /// Usar isto em vez de `.animation` direto garante que a passada de
    /// acessibilidade valha para o app inteiro, não view a view.
    func frAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReducedMotionAnimation(animation: animation, value: value))
    }
}

private struct ReducedMotionAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeInOut(duration: 0.12) : animation, value: value)
    }
}
