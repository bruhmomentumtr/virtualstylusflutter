#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <cstdint>
#include <map>
#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  struct TouchContact {
    LONG x = 0;
    LONG y = 0;
    uint16_t last_seq = 0;
    bool has_seq = false;
  };

  static constexpr int kMaxTouchContacts = 16;

  static POINTER_TYPE_INFO MakeTouchPointerInfo(int slot,
                                                LONG x,
                                                LONG y,
                                                DWORD flags,
                                                LONG screen_width,
                                                LONG screen_height);

  bool HandleTouchEvent(int action,
                        int slot,
                        LONG x,
                        LONG y,
                        int active_touch_mask,
                        int sequence,
                        LONG screen_width,
                        LONG screen_height);

  void ClearAllTouches();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Handles for the synthetic pointer devices we inject into (pen + touch).
  HSYNTHETICPOINTERDEVICE pointer_device_ = nullptr;
  HSYNTHETICPOINTERDEVICE touch_device_ = nullptr;

  // Currently active touch contacts keyed by wire slot (1..kMaxTouchContacts).
  // Windows requires ALL active contacts to be passed together in every
  // InjectSyntheticPointerInput(PT_TOUCH, ...) call.
  std::map<int, TouchContact> active_touches_;
  bool has_touch_seq_ = false;
  uint16_t last_touch_seq_ = 0;
  ULONGLONG last_touch_tick_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
