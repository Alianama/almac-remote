# Build AlmacRemote din sursa

> English: see [BUILD.md](BUILD.md)

## 1. Dependinte de sistem

### Xcode + Metal Toolchain

```bash
xcode-select --install   # daca n-ai deja
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# Pe macOS 26+ / Xcode 26+, Metal Toolchain e o componenta separata:
xcodebuild -downloadComponent MetalToolchain
```

### Homebrew + librarii

```bash
brew install freerdp xcodegen
```

`freerdp` ofera `libfreerdp-client3`, `libfreerdp3`, `libwinpr3` la
`/opt/homebrew/opt/freerdp/`. Path-urile sunt cablate in `project.yml`
(`HEADER_SEARCH_PATHS`, `LIBRARY_SEARCH_PATHS`).

## 2. Generare proiect Xcode

```bash
cd AlmacRemote
xcodegen generate
```

Asta produce `AlmacRemote.xcodeproj` din `project.yml` + `Package.swift`.
Re-ruleaza ori de cate ori adaugi/sterge fisiere in `App/`.

## 3. Build

### Din linia de comanda

```bash
xcodebuild \
  -project AlmacRemote.xcodeproj \
  -scheme AlmacRemote \
  -configuration Debug \
  -derivedDataPath .build-xcode \
  build
```

Binarul rezultat: `.build-xcode/Build/Products/Debug/AlmacRemote.app`.

### Din Xcode

```bash
open AlmacRemote.xcodeproj
```

Apoi Cmd+R.

## 4. Instalare locala

```bash
cp -R .build-xcode/Build/Products/Debug/AlmacRemote.app /Applications/
open /Applications/AlmacRemote.app
```

## 5. Probleme cunoscute la build

- **`Metal Toolchain not found`** — ruleaza `xcodebuild -downloadComponent MetalToolchain`.
- **`'freerdp/freerdp.h' not found`** — `brew install freerdp`. Verifica `ls /opt/homebrew/opt/freerdp/include/freerdp3/freerdp/freerdp.h`.
- **`Cannot find type 'MRNGCore' in scope`** — ruleaza `xcodegen generate` dupa
  ce ai adaugat fisiere noi in `App/`.
- **Warning despre deployment target** (e.g. `dylib built for macOS 26`) — benign,
  dylib-urile brew sunt construite pentru macOS 26 dar app-ul ruleaza fara probleme.

## 6. Validare crypto (optional, CLI)

```bash
swift run mrngprobe /cale/catre/confCons.xml
```

Printeaza statistici (numar noduri, tipuri de conexiuni) si valideaza ca
decriptarea reuseste pe toate parolele.
