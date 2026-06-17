# VirtualStylus 🎨

Transform your Android tablet into a professional, ultra-low latency wireless drawing tablet for your Windows PC. 

VirtualStylus utilizes high-speed UDP for sub-millisecond drawing transmission, WebRTC for real-time screen mirroring, and native Windows Win32 API injection to provide a seamless, pressure-sensitive drawing experience similar to a Wacom or Apple Pencil.

## ✨ Features

- **Ultra-Low Latency UDP Protocol**: Sends raw stylus events (X/Y coordinates, pressure, and state) over UDP (Port 4000) for zero-lag drawing.
- **WebRTC Screen Mirroring**: View your Windows desktop directly on your tablet canvas in real-time.
- **1:1 Canvas Mapping**: Intelligent mathematical aspect-ratio mapping ensures your pen strokes are 100% accurate, completely neutralizing letterboxing or resolution differences.
- **Dynamic Virtual Keyboard Sidebar**: A customizable, frosted-glass sidebar lets you create and save specific keyboard shortcuts (like `Ctrl + Z`, `Shift + B`) right next to your canvas.
- **Premium Glassmorphism UI & Material You Icons**: Beautiful, modern dark-mode aesthetics with blurred backdrops, neon gradients, and micro-animations. Includes full support for Android 13+ Monochrome Themed Icons (Material You).
- **Robust Connection Security**: Features a persistent TCP handshake and an aggressive **IP-Locking Firewall**. Once connected, it blocks all other devices on the network to prevent cursor interference.
- **Pressure Sensitivity**: Fully supports stylus pressure data for professional digital art software (Photoshop, Illustrator, Krita, etc.).

## 🏗️ Architecture

VirtualStylus consists of two unified roles built within a single Flutter codebase:

1. **Windows Receiver (Server)**
   - Listens on `TCP 4001` for handshakes and WebRTC signaling.
   - Listens on `UDP 4000` for stylus coordinate packets.
   - Captures the Windows display via `desktop_capturer` and streams it to the tablet.
   - Injects stylus inputs directly into the Windows OS using native C++ `SendInput` (via MethodChannel).

2. **Android Transmitter (Client)**
   - Connects to the PC via QR Code scanning or manual IP entry.
   - Renders the WebRTC video stream.
   - Captures raw `PointerEvent` data (specifically stylus and touch) and transmits it via optimized 14-byte UDP datagrams.

## 🚀 Getting Started

### Prerequisites
- **Windows PC**: Windows 10 or 11.
- **Android Tablet/Phone**: Android 8.0+ (Stylus supported devices like Galaxy Tab series recommended for pressure sensitivity).
- Both devices must be on the **same local Wi-Fi network**.

### Installation

1. Go to the [Releases](../../releases) page and download the latest `.apk` for your Android device and `.exe` / Windows Build for your PC.
2. Allow VirtualStylus through your Windows Firewall (Ports 4000 UDP and 4001 TCP).

### How to Use

1. **Launch on Windows**: Open VirtualStylus on your PC. It will display a QR code and your local IP address.
2. **Launch on Android**: Open VirtualStylus on your tablet.
3. **Connect**: Tap "Scan QR" to scan your PC's screen, or manually type the IP address. You can toggle "Mirror PC Screen" before connecting.
4. **Draw**: Once the screen shows the green "Connected" indicator, your tablet is locked in. Start drawing on your tablet—your cursor will instantly move on your PC!

## ⌨️ Customizing Shortcuts

While drawing, you can use the sidebar to trigger PC keyboard commands:
1. Tap the **+** (Plus) icon in the sidebar.
2. Type a label (e.g., `Undo`).
3. Select an Icon.
4. Choose the base key (e.g., `Z`) and toggle any modifiers (e.g., `Ctrl`).
5. Tap **Add Shortcut**. 
*(Long-press any shortcut to delete it).*

## 🛠️ Building from Source

To build the project yourself, ensure you have Flutter installed with Windows and Android support enabled.

```bash
# Clone the repository
git clone https://github.com/bruhmomentumtr/virtualstylusflutter.git
cd virtualstylusflutter

# Get dependencies
flutter pub get

# Build for Windows
flutter build windows

# Build for Android (ARM64 recommended for smaller APK size)
flutter build apk --target-platform android-arm64 --obfuscate --split-debug-info=./debug-info
```

## 🤝 Contributing

Pull requests are welcome! If you find a bug or want to suggest a new feature (like multi-monitor support or custom pressure curves), please open an issue first to discuss what you would like to change.

## 📄 License

This project is open-source and available under the MIT License.
