# Frame

Captura, edição e gravação de tela para macOS, num app só.

Reúne o que normalmente exige dois apps: o fluxo de screenshot (capturar,
anotar, embelezar, OCR) e o de screencast (gravar, zoom automático, cursor
suavizado, editar, exportar). Os dois lados compartilham o mesmo motor de
embelezamento, então um preset criado num screenshot vale para uma gravação.

## Requisitos

- macOS 26 ou superior
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`), opcional

## Rodar

```sh
xcodegen generate
xcodebuild -project Frame.xcodeproj -scheme Frame -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Frame-*/Build/Products/Debug/Frame.app
```

Ou abra `Frame.xcodeproj` no Xcode e dê ⌘R.

O `Frame.xcodeproj` é **gerado** a partir de `project.yml` e não é versionado.
Ao acrescentar um arquivo em `Sources/`, rode `xcodegen generate` de novo.

## Testes

```sh
xcodebuild -project Frame.xcodeproj -scheme Frame test
```

Os testes de render visual gravam amostras em
`$TMPDIR/frame-visual-smoke/` — úteis para conferir o resultado a olho.

## Permissões

Na primeira execução o app abre a tela de permissões. **Gravação de Tela** é
obrigatória; microfone, câmera e acessibilidade são opcionais e destravam,
respectivamente, narração, câmera sobreposta e zoom automático nos cliques.

O app roda **fora do sandbox** porque o zoom automático depende de observar a
posição do cursor pelo sistema. Publicar na App Store exigiria trocar essa
detecção por análise de quadro.

## Estrutura

```
Sources/
├── FrameCore/      modelos, .frameproj, preferências, atalhos globais
├── FrameCapture/   ScreenCaptureKit: estático, scroll, vídeo, trilha de eventos
├── FrameVision/    OCR (Vision) + IA no dispositivo (FoundationModels)
├── FrameStudio/    editor de imagem: anotação e embelezamento
├── FrameMotion/    editor de vídeo: linha do tempo, zoom, cursor, export
├── FrameUI/        design system: tokens, componentes, animações
└── FrameApp/       menu bar, janelas, onboarding, preferências
```

### Decisão central: gravação não-destrutiva

O vídeo é gravado **cru** — sem cursor, sem zoom, sem fundo. Em paralelo, uma
trilha de eventos registra onde o cursor esteve e onde houve cliques. O editor
recompõe tudo a partir dessas duas fontes, e o export usa exatamente o mesmo
compositor do preview.

Isso é o que permite mexer no zoom, no cursor e no fundo indefinidamente sem
nunca degradar a gravação original.

### Captura com scroll

Frames da mesma área são alinhados por correlação de assinaturas de linha
(vImage) e a parte inédita de cada um é acrescentada à imagem longa. Regiões
fixas — cabeçalhos e rodapés que não rolam — são detectadas e não duplicadas.

Costurar pixels funciona em qualquer app, inclusive nos que desenham o próprio
scroll e não expõem uma hierarquia de acessibilidade utilizável.
