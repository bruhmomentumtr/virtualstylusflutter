#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <iostream>
FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Initialize Synthetic Pointer Devices (pen + touch).
  // Each synthetic device has its own pointer type, which lets the Windows
  // input stack deliver distinct WM_POINTERUPDATE messages for finger vs pen.
  pointer_device_ = CreateSyntheticPointerDevice(PT_PEN, 1, POINTER_FEEDBACK_DEFAULT);
  touch_device_  = CreateSyntheticPointerDevice(PT_TOUCH, 1, POINTER_FEEDBACK_DEFAULT);

  // Setup Method Channel for Pen Injection
  flutter::MethodChannel<> channel(
      flutter_controller_->engine()->messenger(), "com.virtualstylus/pen",
      &flutter::StandardMethodCodec::GetInstance());

  channel.SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "injectPenEvent") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("INVALID_ARGUMENTS", "Expected map arguments");
            return;
          }

          auto getDouble = [](const flutter::EncodableValue& val) -> double {
            if (std::holds_alternative<double>(val)) return std::get<double>(val);
            if (std::holds_alternative<int>(val)) return static_cast<double>(std::get<int>(val));
            return 0.0;
          };

          int action = std::get<int>(args->at(flutter::EncodableValue("action")));
          double x = getDouble(args->at(flutter::EncodableValue("x")));
          double y = getDouble(args->at(flutter::EncodableValue("y")));
          double pressure = getDouble(args->at(flutter::EncodableValue("pressure")));

          // Handle Shortcuts (action == 5)
          if (action == 5) {
            int vkCode = static_cast<int>(x);
            int modifiers = static_cast<int>(y);
            
            bool ctrl = (modifiers & 1) != 0;
            bool shift = (modifiers & 2) != 0;
            bool alt = (modifiers & 4) != 0;
            bool win = (modifiers & 8) != 0;

            int numInputs = 0;
            INPUT inputs[10] = {};

            // Key Down for Modifiers
            if (ctrl) { inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = VK_CONTROL; numInputs++; }
            if (shift) { inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = VK_SHIFT; numInputs++; }
            if (alt) { inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = VK_MENU; numInputs++; }
            if (win) { inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = VK_LWIN; numInputs++; }

            // Key Down for Main Key
            if (vkCode != 0) {
              inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = static_cast<WORD>(vkCode); numInputs++;
              // Key Up for Main Key
              inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = static_cast<WORD>(vkCode); inputs[numInputs].ki.dwFlags = KEYEVENTF_KEYUP; numInputs++;
            }

            // Key Up for Modifiers (reverse order)
            if (win) { inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = VK_LWIN; inputs[numInputs].ki.dwFlags = KEYEVENTF_KEYUP; numInputs++; }
            if (alt) { inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = VK_MENU; inputs[numInputs].ki.dwFlags = KEYEVENTF_KEYUP; numInputs++; }
            if (shift) { inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = VK_SHIFT; inputs[numInputs].ki.dwFlags = KEYEVENTF_KEYUP; numInputs++; }
            if (ctrl) { inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = VK_CONTROL; inputs[numInputs].ki.dwFlags = KEYEVENTF_KEYUP; numInputs++; }

            if (numInputs > 0) {
              SendInput(numInputs, inputs, sizeof(INPUT));
            }
            result->Success();
            return;
          }

          // Pointer kind from the wire: 0=touch, 1=stylus, 2=invertedStylus, 3=mouse.
          // Defaults to stylus so older clients (that don't send "kind") still work.
          int kind = 1;
          auto kindIt = args->find(flutter::EncodableValue("kind"));
          if (kindIt != args->end()) {
            const auto* kindVal = std::get_if<int>(&kindIt->second);
            if (kindVal) kind = *kindVal;
          }

          int screenWidth = GetSystemMetrics(SM_CXSCREEN);
          int screenHeight = GetSystemMetrics(SM_CYSCREEN);

          POINTER_TYPE_INFO pointerInfo = {};
          HSYNTHETICPOINTERDEVICE target_device = nullptr;

          // Pick the matching synthetic device and pre-fill its sub-struct.
          // The struct is a union (touchInfo | penInfo | mouseInfo), so the
          // "common" pointerInfo fields must be written through the active
          // member — the helpers below do that routing.
          if (kind == 0) { // touch
            if (touch_device_ == nullptr) {
              result->Error("NO_DEVICE", "Synthetic touch device not created");
              return;
            }
            target_device = touch_device_;
            pointerInfo.type = PT_TOUCH;
            pointerInfo.touchInfo.pointerInfo.pointerType = PT_TOUCH;
            pointerInfo.touchInfo.pointerInfo.pointerId = 1;
            pointerInfo.touchInfo.touchFlags = TOUCH_FLAG_NONE;
            pointerInfo.touchInfo.touchMask = TOUCH_MASK_CONTACTAREA;
            pointerInfo.touchInfo.pointerInfo.ptPixelLocation.x = 0;
            pointerInfo.touchInfo.pointerInfo.ptPixelLocation.y = 0;
            pointerInfo.touchInfo.rcContactArea.left = 0;
            pointerInfo.touchInfo.rcContactArea.top = 0;
            pointerInfo.touchInfo.rcContactArea.right = 4;
            pointerInfo.touchInfo.rcContactArea.bottom = 4;
          } else { // stylus, invertedStylus, or mouse all go through pen
            if (pointer_device_ == nullptr) {
              result->Error("NO_DEVICE", "Synthetic pen device not created");
              return;
            }
            target_device = pointer_device_;
            pointerInfo.type = PT_PEN;
            pointerInfo.penInfo.pointerInfo.pointerType = PT_PEN;
            pointerInfo.penInfo.pointerInfo.pointerId = 1;
            pointerInfo.penInfo.penFlags = PEN_FLAG_NONE;
            pointerInfo.penInfo.penMask = PEN_MASK_PRESSURE;
          }

          auto applyFlags = [&](DWORD flags) {
            if (kind == 0) {
              pointerInfo.touchInfo.pointerInfo.pointerFlags = flags;
            } else {
              pointerInfo.penInfo.pointerInfo.pointerFlags = flags;
            }
          };
          auto applyLocation = [&](double lx, double ly) {
            LONG px = static_cast<LONG>(lx * screenWidth);
            LONG py = static_cast<LONG>(ly * screenHeight);
            if (kind == 0) {
              pointerInfo.touchInfo.pointerInfo.ptPixelLocation.x = px;
              pointerInfo.touchInfo.pointerInfo.ptPixelLocation.y = py;
            } else {
              pointerInfo.penInfo.pointerInfo.ptPixelLocation.x = px;
              pointerInfo.penInfo.pointerInfo.ptPixelLocation.y = py;
            }
          };

          // Action mapping
          // 0: Down, 1: Move, 2: Up, 3: Cancel, 4: Hover
          if (action == 0) {
            if (kind == 0) { // touch down needs POINTER_FLAG_NEW
              applyFlags(POINTER_FLAG_NEW | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_DOWN);
            } else {
              applyFlags(POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_DOWN);
            }
          } else if (action == 1) {
            applyFlags(POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE);
          } else if (action == 2) {
            applyFlags(POINTER_FLAG_UP);
          } else if (action == 4) { // hover
            applyFlags(POINTER_FLAG_INRANGE | POINTER_FLAG_UPDATE);
          } else { // cancel
            applyFlags(POINTER_FLAG_UPDATE);
          }

          applyLocation(x, y);

          // Pressure is pen-only; touch input never reports pressure.
          if (kind != 0) {
            pointerInfo.penInfo.pressure = static_cast<UINT32>(pressure * 1024);
          }

          BOOL success = InjectSyntheticPointerInput(target_device, &pointerInfo, 1);
          if (success) {
            result->Success();
          } else {
            result->Error("INJECT_FAILED", "Failed to inject pointer input");
          }
        } else {
          result->NotImplemented();
        }
      });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (pointer_device_ != nullptr) {
    DestroySyntheticPointerDevice(pointer_device_);
    pointer_device_ = nullptr;
  }
  if (touch_device_ != nullptr) {
    DestroySyntheticPointerDevice(touch_device_);
    touch_device_ = nullptr;
  }

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
