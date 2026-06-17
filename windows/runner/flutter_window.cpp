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

  // Initialize Synthetic Pointer Device for Pen
  pointer_device_ = CreateSyntheticPointerDevice(PT_PEN, 1, POINTER_FEEDBACK_DEFAULT);

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
              inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = vkCode; numInputs++;
              // Key Up for Main Key
              inputs[numInputs].type = INPUT_KEYBOARD; inputs[numInputs].ki.wVk = vkCode; inputs[numInputs].ki.dwFlags = KEYEVENTF_KEYUP; numInputs++;
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

          if (this->pointer_device_ == nullptr) {
            result->Error("NO_DEVICE", "Synthetic pointer device not created");
            return;
          }

          int screenWidth = GetSystemMetrics(SM_CXSCREEN);
          int screenHeight = GetSystemMetrics(SM_CYSCREEN);

          POINTER_TYPE_INFO pointerInfo = {};
          pointerInfo.type = PT_PEN;
          pointerInfo.penInfo.pointerInfo.pointerType = PT_PEN;
          pointerInfo.penInfo.pointerInfo.pointerId = 1;

          // Action mapping
          // 0: Down, 1: Move, 2: Up, 3: Cancel, 4: Hover
          if (action == 0) {
            pointerInfo.penInfo.pointerInfo.pointerFlags = POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_DOWN;
          } else if (action == 1) {
            pointerInfo.penInfo.pointerInfo.pointerFlags = POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE;
          } else if (action == 2) {
            pointerInfo.penInfo.pointerInfo.pointerFlags = POINTER_FLAG_UP;
          } else if (action == 4) { // hover
            pointerInfo.penInfo.pointerInfo.pointerFlags = POINTER_FLAG_INRANGE | POINTER_FLAG_UPDATE;
          } else { // cancel
            pointerInfo.penInfo.pointerInfo.pointerFlags = POINTER_FLAG_UPDATE;
          }

          pointerInfo.penInfo.pointerInfo.ptPixelLocation.x = static_cast<LONG>(x * screenWidth);
          pointerInfo.penInfo.pointerInfo.ptPixelLocation.y = static_cast<LONG>(y * screenHeight);
          pointerInfo.penInfo.pressure = static_cast<UINT32>(pressure * 1024);
          pointerInfo.penInfo.penFlags = PEN_FLAG_NONE;
          pointerInfo.penInfo.penMask = PEN_MASK_PRESSURE;

          BOOL success = InjectSyntheticPointerInput(this->pointer_device_, &pointerInfo, 1);
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
