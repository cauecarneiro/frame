# Frame

App para Mac que junta captura de tela, edição e gravação de tela em um só: tira print, anota, grava a tela e edita o vídeo. Para quem hoje usa dois apps para isso.

Estudo e ferramenta pessoal · macOS 26+ · 2026

## O que faz

- **Screenshot:** captura de área, anotação, embelezamento (fundo, margens, cantos e sombra) e reconhecimento de texto (OCR) com a Vision.
- **Captura com rolagem:** costura vários frames de uma página longa em uma imagem só.
- **Gravação de tela:** grava o vídeo cru, com zoom automático nos cliques, cursor suavizado e narração por microfone opcional.
- **Editor de vídeo:** linha do tempo, zoom, cursor e fundo ajustáveis, com exportação pelo mesmo compositor do preview.
- **Ações de IA no texto reconhecido:** resumir, explicar, corrigir gramática, reescrever e responder, com o modelo do sistema (FoundationModels), sem serviço externo.
- Os dois lados (screenshot e gravação) compartilham o mesmo motor de embelezamento, então um preset criado num print vale para uma gravação.

## Meu papel

Projeto solo. O repositório tem dois commits, os dois de Cauê Carneiro, em 06/08/2026.

## Como foi feito

- **Módulos por pasta em `Frame/Sources/`:** `FrameCore` (modelos, projeto `.frameproj`, preferências, atalhos globais), `FrameCapture` (ScreenCaptureKit), `FrameVision` (OCR e IA no aparelho), `FrameStudio` (editor de imagem), `FrameMotion` (editor de vídeo), `FrameUI` (design system) e `FrameApp` (barra de menus, janelas, onboarding, preferências).
- **Gravação não destrutiva:** o vídeo é gravado cru, sem cursor, sem zoom e sem fundo. Uma trilha de eventos registra onde o cursor esteve e onde houve cliques, e o editor recompõe tudo a partir dessas duas fontes. Assim dá para mexer no zoom, no cursor e no fundo sem degradar a gravação original.
- **Captura com rolagem por pixels:** os frames são alinhados por correlação de assinaturas de linha (vImage) e só a parte inédita de cada um é acrescentada; cabeçalhos e rodapés fixos são detectados e não se repetem. Funciona em apps que desenham o próprio scroll.
- **Fora do sandbox:** o zoom automático depende de observar a posição do cursor pelo sistema. Publicar na App Store exigiria trocar essa detecção por análise de quadro.
- **Projeto gerado:** `Frame/project.yml` (XcodeGen) descreve o projeto.

## Tecnologias

Swift 6, SwiftUI, ScreenCaptureKit, Vision, FoundationModels, vImage, XcodeGen.

## Como rodar

Requisitos: macOS 26 ou superior, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) e, opcional, [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`).

```sh
cd Frame
xcodegen generate
xcodebuild -project Frame.xcodeproj -scheme Frame -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Frame-*/Build/Products/Debug/Frame.app
```

Ou abra `Frame/Frame.xcodeproj` no Xcode e dê ⌘R. Ao acrescentar um arquivo em `Sources/`, rode `xcodegen generate` de novo.

Testes:

```sh
cd Frame
xcodebuild -project Frame.xcodeproj -scheme Frame test
```

Os testes de render visual gravam amostras em `$TMPDIR/frame-visual-smoke/`, úteis para conferir o resultado a olho.

### Permissões

Na primeira execução o app abre a tela de permissões. **Gravação de Tela** é obrigatória; microfone, câmera e acessibilidade são opcionais e destravam, respectivamente, narração, câmera sobreposta e zoom automático nos cliques.

## Licença

[MIT](LICENSE).

---
Feito por Cauê Crillanovick · [portfólio](https://cauecarneiro.github.io/portfolio/) · [LinkedIn](https://www.linkedin.com/in/cau%C3%AA-carneiro)
