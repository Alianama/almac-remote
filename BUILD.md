# Build AlmacRemote from source

> Romanian: see [BUILD.ro.md](BUILD.ro.md)

## 1. System dependencies

### Xcode + Metal Toolchain

```bash
xcode-select --install   # if not already installed
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# On macOS 26+ / Xcode 26+, the Metal Toolchain is a separate component:
xcodebuild -downloadComponent MetalToolchain
```

### Homebrew + libraries

```bash
brew install freerdp xcodegen
```

`freerdp` provides `libfreerdp-client3`, `libfreerdp3`, `libwinpr3` at
`/opt/homebrew/opt/freerdp/`. The paths are wired into `project.yml`
(`HEADER_SEARCH_PATHS`, `LIBRARY_SEARCH_PATHS`).

## 2. Generate the Xcode project

```bash
cd AlmacRemote
xcodegen generate
```

This produces `AlmacRemote.xcodeproj` from `project.yml` + `Package.swift`.
Re-run it whenever you add or remove files in `App/`.

## 3. Build

### Command line

```bash
xcodebuild \
  -project AlmacRemote.xcodeproj \
  -scheme AlmacRemote \
  -configuration Debug \
  -derivedDataPath .build-xcode \
  build
```

Resulting binary: `.build-xcode/Build/Products/Debug/AlmacRemote.app`.

### From Xcode

```bash
open AlmacRemote.xcodeproj
```

Then Cmd+R.

## 4. Local install

```bash
cp -R .build-xcode/Build/Products/Debug/AlmacRemote.app /Applications/
open /Applications/AlmacRemote.app
```

## 5. Known build issues

- **`Metal Toolchain not found`** — run `xcodebuild -downloadComponent MetalToolchain`.
- **`'freerdp/freerdp.h' not found`** — `brew install freerdp`. Verify with
  `ls /opt/homebrew/opt/freerdp/include/freerdp3/freerdp/freerdp.h`.
- **`Cannot find type 'MRNGCore' in scope`** — run `xcodegen generate` after
  you add new files into `App/`.
- **Deployment-target warning** (e.g. `dylib built for macOS 26`) — benign;
  the brew dylibs are built for macOS 26 but the app runs fine.

## 6. Crypto validation (optional, CLI)

```bash
swift run mrngprobe /path/to/confCons.xml
```

Prints statistics (node count, connection types) and validates that
decryption succeeds for all passwords.
