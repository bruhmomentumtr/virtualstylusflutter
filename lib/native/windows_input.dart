import 'dart:ffi';
import 'dart:io';

typedef SetCursorPosC = Int32 Function(Int32 x, Int32 y);
typedef SetCursorPosDart = int Function(int x, int y);

typedef MouseEventC = Void Function(Uint32 dwFlags, Int32 dx, Int32 dy, Uint32 dwData, IntPtr dwExtraInfo);
typedef MouseEventDart = void Function(int dwFlags, int dx, int dy, int dwData, int dwExtraInfo);

typedef GetSystemMetricsC = Int32 Function(Int32 nIndex);
typedef GetSystemMetricsDart = int Function(int nIndex);

const int MOUSEEVENTF_LEFTDOWN = 0x0002;
const int MOUSEEVENTF_LEFTUP = 0x0004;

class WindowsInput {
  static late final DynamicLibrary user32;
  static late final SetCursorPosDart setCursorPos;
  static late final MouseEventDart mouseEvent;
  static late final GetSystemMetricsDart getSystemMetrics;
  
  static bool _initialized = false;

  /// user32.dll üzerinden native metodları yakalar
  static void init() {
    if (Platform.isWindows) {
      try {
        user32 = DynamicLibrary.open('user32.dll');
        setCursorPos = user32.lookupFunction<SetCursorPosC, SetCursorPosDart>('SetCursorPos');
        mouseEvent = user32.lookupFunction<MouseEventC, MouseEventDart>('mouse_event');
        getSystemMetrics = user32.lookupFunction<GetSystemMetricsC, GetSystemMetricsDart>('GetSystemMetrics');
        _initialized = true;
      } catch (e) {
        print('WindowsInput İlk Değerlendirme Hatası: $e');
      }
    }
  }

  /// Ekran genişliğini döndürür (SM_CXSCREEN = 0)
  static int getScreenWidth() => _initialized ? getSystemMetrics(0) : 1920;

  /// Ekran yüksekliğini döndürür (SM_CYSCREEN = 1)
  static int getScreenHeight() => _initialized ? getSystemMetrics(1) : 1080;

  /// Windows imlecini ekrandaki belirli (x, y) pikseline atar
  static void moveCursor(int x, int y) {
    if (_initialized) setCursorPos(x, y);
  }

  /// Sol tık (Kalemi ekrana bastırma)
  static void leftDown() {
    if (_initialized) mouseEvent(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
  }

  /// Sol tık bırakma (Kalemi ekrandan çekme)
  static void leftUp() {
    if (_initialized) mouseEvent(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
  }
}
