#include "flutter_window.h"

#include <mfapi.h>
#include <mferror.h>
#include <mftransform.h>

#include <algorithm>
#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <iostream>

namespace {

constexpr DWORD MakeFourCC(char a, char b, char c, char d) {
  return static_cast<DWORD>(static_cast<uint8_t>(a)) |
         (static_cast<DWORD>(static_cast<uint8_t>(b)) << 8) |
         (static_cast<DWORD>(static_cast<uint8_t>(c)) << 16) |
         (static_cast<DWORD>(static_cast<uint8_t>(d)) << 24);
}

constexpr GUID MakeVideoSubtype(DWORD fourcc) {
  return GUID{fourcc,
              0x0000,
              0x0010,
              {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
}

bool HasHardwareVideoEncoder(const GUID& subtype) {
  MFT_REGISTER_TYPE_INFO output_type = {};
  output_type.guidMajorType = MFMediaType_Video;
  output_type.guidSubtype = subtype;

  IMFActivate** activates = nullptr;
  UINT32 count = 0;
  HRESULT hr = MFTEnumEx(
      MFT_CATEGORY_VIDEO_ENCODER,
      MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
      nullptr,
      &output_type,
      &activates,
      &count);
  if (FAILED(hr) || activates == nullptr) {
    return false;
  }

  // Verify at least one enumerated MFT actually activates on this GPU.
  // Drivers often register stub MFTs for newer codecs (e.g., AV1/VP9) that
  // return E_FAIL from ActivateObject when the silicon lacks that encoder.
  bool found_working_hw = false;
  for (UINT32 i = 0; i < count; ++i) {
    if (activates[i] == nullptr) continue;
    if (!found_working_hw) {
      IMFTransform* transform = nullptr;
      HRESULT act_hr = activates[i]->ActivateObject(IID_PPV_ARGS(&transform));
      if (SUCCEEDED(act_hr) && transform != nullptr) {
        found_working_hw = true;
        transform->Release();
        activates[i]->ShutdownObject();
      }
    }
    activates[i]->Release();
  }
  CoTaskMemFree(activates);
  return found_working_hw;
}

constexpr DWORD kTouchDownFlags =
    POINTER_FLAG_NEW | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT |
    POINTER_FLAG_DOWN;
constexpr DWORD kTouchUpdateFlags =
    POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE;
constexpr DWORD kTouchUpFlags = POINTER_FLAG_UP;
constexpr DWORD kTouchCancelFlags = POINTER_FLAG_UP | POINTER_FLAG_CANCELED;

bool IsSeqNewer(uint16_t candidate, uint16_t baseline) {
  return static_cast<int16_t>(static_cast<uint16_t>(candidate - baseline)) > 0;
}

bool ContainsSlot(const std::vector<int>& slots, int target) {
  return std::find(slots.begin(), slots.end(), target) != slots.end();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

POINTER_TYPE_INFO FlutterWindow::MakeTouchPointerInfo(int slot,
                                                      LONG x,
                                                      LONG y,
                                                      DWORD flags,
                                                      LONG screen_width,
                                                      LONG screen_height) {
  POINTER_TYPE_INFO info = {};
  info.type = PT_TOUCH;
  info.touchInfo.pointerInfo.pointerType = PT_TOUCH;
  // CreateSyntheticPointerDevice(PT_TOUCH, kMaxTouchContacts, ...) uses
  // zero-based contact IDs in [0, kMaxTouchContacts - 1].
  info.touchInfo.pointerInfo.pointerId = static_cast<UINT32>(slot - 1);
  info.touchInfo.pointerInfo.pointerFlags = flags;
  info.touchInfo.pointerInfo.ptPixelLocation.x = x;
  info.touchInfo.pointerInfo.ptPixelLocation.y = y;

  info.touchInfo.touchFlags = TOUCH_FLAG_NONE;
  info.touchInfo.touchMask = TOUCH_MASK_CONTACTAREA;
  constexpr LONG kContactRadius = 2;
  LONG left = (std::max)(LONG{0}, x - kContactRadius);
  LONG top = (std::max)(LONG{0}, y - kContactRadius);
  LONG right = (std::min)(screen_width, x + kContactRadius);
  LONG bottom = (std::min)(screen_height, y + kContactRadius);
  if (right <= left) right = left + 1;
  if (bottom <= top) bottom = top + 1;
  info.touchInfo.rcContact.left = left;
  info.touchInfo.rcContact.top = top;
  info.touchInfo.rcContact.right = right;
  info.touchInfo.rcContact.bottom = bottom;
  return info;
}

bool FlutterWindow::HandleTouchEvent(int action,
                                     int slot,
                                     LONG x,
                                     LONG y,
                                     int active_touch_mask,
                                     int sequence,
                                     LONG screen_width,
                                     LONG screen_height) {
  if (touch_device_ == nullptr) {
    return false;
  }
  if (slot < 1 || slot > kMaxTouchContacts) {
    return false;
  }
  if (action == 4) {
    // Finger touch does not hover; ignore safely.
    return true;
  }

  const ULONGLONG now_tick = GetTickCount64();
  if (active_touches_.empty() && has_touch_seq_ &&
      (now_tick - last_touch_tick_) > 2000) {
    // Reset sequence baseline after idle gap so client reconnects (even with
    // WebRTC signaling disabled) immediately synchronize.
    has_touch_seq_ = false;
  }
  last_touch_tick_ = now_tick;

  const bool has_seq = (sequence >= 0 && sequence <= 0xFFFF);
  const uint16_t seq16 = has_seq ? static_cast<uint16_t>(sequence) : uint16_t{0};
  const bool seq_is_newer =
      !has_seq || !has_touch_seq_ || IsSeqNewer(seq16, last_touch_seq_);
  if (has_seq && seq_is_newer) {
    last_touch_seq_ = seq16;
    has_touch_seq_ = true;
  }

  // Reconcile any contacts whose UP packet was dropped over UDP using the
  // sender's activeTouchMask (only when this packet is not older than the
  // latest sequence we already processed).
  std::vector<int> stale_slots;
  if (active_touch_mask >= 0 && seq_is_newer) {
    for (const auto& entry : active_touches_) {
      const int existing_slot = entry.first;
      if (existing_slot == slot) continue;
      if (((active_touch_mask >> (existing_slot - 1)) & 1) == 0) {
        stale_slots.push_back(existing_slot);
      }
    }
  }

  auto erase_stale = [&]() {
    for (int stale : stale_slots) {
      active_touches_.erase(stale);
    }
  };

  // Action 2 = Up, Action 3 = Cancel
  if (action == 2 || action == 3) {
    auto it = active_touches_.find(slot);
    bool release_slot = (it != active_touches_.end());
    if (release_slot && has_seq && it->second.has_seq &&
        !IsSeqNewer(seq16, it->second.last_seq)) {
      // Delayed duplicate UP/CANCEL from an older tap after this slot was
      // already reused by a newer DOWN. Do not lift the new contact.
      release_slot = false;
    }

    if (!release_slot && stale_slots.empty()) {
      return true;
    }

    const DWORD release_flags =
        (action == 3) ? kTouchCancelFlags : kTouchUpFlags;
    std::vector<POINTER_TYPE_INFO> frame;
    frame.reserve(active_touches_.size());
    for (const auto& entry : active_touches_) {
      const int id = entry.first;
      const TouchContact& contact = entry.second;
      DWORD flags = kTouchUpdateFlags;
      if (release_slot && id == slot) {
        flags = release_flags;
      } else if (ContainsSlot(stale_slots, id)) {
        flags = kTouchUpFlags;
      }
      // On UP/CANCEL Windows requires ptPixelLocation to match the last
      // reported contact position.
      frame.push_back(MakeTouchPointerInfo(
          id, contact.x, contact.y, flags, screen_width, screen_height));
    }

    BOOL ok = InjectSyntheticPointerInput(
        touch_device_, frame.data(), static_cast<UINT32>(frame.size()));
    if (!ok && action == 3 && release_slot) {
      // Fallback to plain POINTER_FLAG_UP if CANCELED is rejected.
      for (auto& pti : frame) {
        if (pti.touchInfo.pointerInfo.pointerId ==
            static_cast<UINT32>(slot - 1)) {
          pti.touchInfo.pointerInfo.pointerFlags = kTouchUpFlags;
        }
      }
      ok = InjectSyntheticPointerInput(
          touch_device_, frame.data(), static_cast<UINT32>(frame.size()));
    }

    if (release_slot) {
      active_touches_.erase(slot);
    }
    erase_stale();
    return ok != FALSE;
  }

  // Action 0 = Down, Action 1 = Move
  auto existing_it = active_touches_.find(slot);
  const bool already_active = (existing_it != active_touches_.end());

  if (action == 1 && !already_active) {
    if (has_seq && !seq_is_newer) {
      // Out-of-order MOVE arrived after this finger was already lifted.
      return true;
    }
    // Missed DOWN packet over UDP; promote this MOVE to DOWN so the finger
    // starts cleanly.
    action = 0;
  }

  if (action == 1 && already_active) {
    if (has_seq && existing_it->second.has_seq &&
        !IsSeqNewer(seq16, existing_it->second.last_seq)) {
      // Out-of-order older MOVE for this same finger; drop to prevent jitter.
      return true;
    }
    existing_it->second.x = x;
    existing_it->second.y = y;
    if (has_seq) {
      existing_it->second.last_seq = seq16;
      existing_it->second.has_seq = true;
    }

    std::vector<POINTER_TYPE_INFO> frame;
    frame.reserve(active_touches_.size());
    for (const auto& entry : active_touches_) {
      const int id = entry.first;
      const TouchContact& contact = entry.second;
      const DWORD flags = ContainsSlot(stale_slots, id)
                              ? kTouchUpFlags
                              : kTouchUpdateFlags;
      frame.push_back(MakeTouchPointerInfo(
          id, contact.x, contact.y, flags, screen_width, screen_height));
    }

    BOOL ok = InjectSyntheticPointerInput(
        touch_device_, frame.data(), static_cast<UINT32>(frame.size()));
    erase_stale();
    return ok != FALSE;
  }

  // Action 0 = Down
  if (already_active) {
    if (has_seq && existing_it->second.has_seq &&
        !IsSeqNewer(seq16, existing_it->second.last_seq)) {
      // Duplicate/reordered older DOWN; ignore.
      return true;
    }
    // Previous UP for this slot was lost; release the stale contact first
    // while keeping all other active fingers down.
    std::vector<POINTER_TYPE_INFO> release_frame;
    release_frame.reserve(active_touches_.size());
    for (const auto& entry : active_touches_) {
      const int id = entry.first;
      const TouchContact& contact = entry.second;
      const DWORD flags = (id == slot || ContainsSlot(stale_slots, id))
                              ? kTouchUpFlags
                              : kTouchUpdateFlags;
      release_frame.push_back(MakeTouchPointerInfo(
          id, contact.x, contact.y, flags, screen_width, screen_height));
    }
    InjectSyntheticPointerInput(
        touch_device_, release_frame.data(),
        static_cast<UINT32>(release_frame.size()));
    active_touches_.erase(slot);
    erase_stale();
    stale_slots.clear();
  }

  TouchContact new_contact;
  new_contact.x = x;
  new_contact.y = y;
  new_contact.last_seq = seq16;
  new_contact.has_seq = has_seq;
  active_touches_[slot] = new_contact;

  std::vector<POINTER_TYPE_INFO> frame;
  frame.reserve(active_touches_.size());
  for (const auto& entry : active_touches_) {
    const int id = entry.first;
    const TouchContact& contact = entry.second;
    DWORD flags = kTouchUpdateFlags;
    if (id == slot) {
      flags = kTouchDownFlags;
    } else if (ContainsSlot(stale_slots, id)) {
      flags = kTouchUpFlags;
    }
    frame.push_back(MakeTouchPointerInfo(
        id, contact.x, contact.y, flags, screen_width, screen_height));
  }

  BOOL ok = InjectSyntheticPointerInput(
      touch_device_, frame.data(), static_cast<UINT32>(frame.size()));
  erase_stale();
  if (!ok) {
    active_touches_.erase(slot);
  }
  return ok != FALSE;
}

void FlutterWindow::ClearAllTouches() {
  if (touch_device_ != nullptr && !active_touches_.empty()) {
    LONG screen_width = static_cast<LONG>(GetSystemMetrics(SM_CXSCREEN));
    LONG screen_height = static_cast<LONG>(GetSystemMetrics(SM_CYSCREEN));
    if (screen_width <= 0) screen_width = 1920;
    if (screen_height <= 0) screen_height = 1080;

    std::vector<POINTER_TYPE_INFO> frame;
    frame.reserve(active_touches_.size());
    for (const auto& entry : active_touches_) {
      frame.push_back(MakeTouchPointerInfo(
          entry.first, entry.second.x, entry.second.y, kTouchUpFlags,
          screen_width, screen_height));
    }
    InjectSyntheticPointerInput(
        touch_device_, frame.data(), static_cast<UINT32>(frame.size()));
  }
  active_touches_.clear();
  has_touch_seq_ = false;
  last_touch_seq_ = 0;
  last_touch_tick_ = 0;
}

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
  // The touch device supports up to 16 simultaneous contacts so the receiver
  // can forward multi-touch from the tablet to Windows.
  pointer_device_ = CreateSyntheticPointerDevice(PT_PEN, 1, POINTER_FEEDBACK_DEFAULT);
  touch_device_  = CreateSyntheticPointerDevice(PT_TOUCH, 16, POINTER_FEEDBACK_DEFAULT);

  // Setup Method Channel for Pen Injection
  flutter::MethodChannel<> channel(
      flutter_controller_->engine()->messenger(), "com.virtualstylus/pen",
      &flutter::StandardMethodCodec::GetInstance());

  channel.SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "clearTouches") {
          ClearAllTouches();
          result->Success();
          return;
        }
        if (call.method_name() == "getHardwareEncoders") {
          HRESULT mf_hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
          flutter::EncodableMap encoders;
          if (SUCCEEDED(mf_hr)) {
            encoders[flutter::EncodableValue("h264")] = flutter::EncodableValue(
                HasHardwareVideoEncoder(
                    MakeVideoSubtype(MakeFourCC('H', '2', '6', '4'))));
            encoders[flutter::EncodableValue("h265")] = flutter::EncodableValue(
                HasHardwareVideoEncoder(
                    MakeVideoSubtype(MakeFourCC('H', 'E', 'V', 'C'))));
            encoders[flutter::EncodableValue("vp8")] = flutter::EncodableValue(
                HasHardwareVideoEncoder(
                    MakeVideoSubtype(MakeFourCC('V', 'P', '8', '0'))));
            encoders[flutter::EncodableValue("vp9")] = flutter::EncodableValue(
                HasHardwareVideoEncoder(
                    MakeVideoSubtype(MakeFourCC('V', 'P', '9', '0'))));
            encoders[flutter::EncodableValue("av1")] = flutter::EncodableValue(
                HasHardwareVideoEncoder(
                    MakeVideoSubtype(MakeFourCC('A', 'V', '0', '1'))));
            MFShutdown();
          } else {
            encoders[flutter::EncodableValue("h264")] = flutter::EncodableValue(false);
            encoders[flutter::EncodableValue("h265")] = flutter::EncodableValue(false);
            encoders[flutter::EncodableValue("vp8")] = flutter::EncodableValue(false);
            encoders[flutter::EncodableValue("vp9")] = flutter::EncodableValue(false);
            encoders[flutter::EncodableValue("av1")] = flutter::EncodableValue(false);
          }
          result->Success(flutter::EncodableValue(encoders));
          return;
        }
        if (call.method_name() == "startHwStream" ||
            call.method_name() == "updateHwStream") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          HwVideoStreamer::Config cfg;
          int port = 4002;
          if (args) {
            auto readInt = [&](const char* key, int def) -> int {
              auto it = args->find(flutter::EncodableValue(key));
              if (it != args->end()) {
                if (const auto* v = std::get_if<int>(&it->second)) return *v;
              }
              return def;
            };
            auto readBool = [&](const char* key, bool def) -> bool {
              auto it = args->find(flutter::EncodableValue(key));
              if (it != args->end()) {
                if (const auto* v = std::get_if<bool>(&it->second)) return *v;
              }
              return def;
            };
            cfg.use_hevc = readBool("useHevc", false);
            cfg.target_height = readInt("targetHeight", 0);
            cfg.fps = readInt("fps", 60);
            cfg.max_mbps = readInt("maxMbps", 12);
            port = readInt("port", 4002);
          }
          if (call.method_name() == "startHwStream") {
            hw_video_streamer_.Start(cfg, static_cast<uint16_t>(port));
          } else {
            hw_video_streamer_.UpdateConfig(cfg);
          }
          result->Success();
          return;
        }
        if (call.method_name() == "stopHwStream") {
          hw_video_streamer_.Stop();
          result->Success();
          return;
        }
        if (call.method_name() == "getHwStreamStats") {
          const auto st = hw_video_streamer_.GetStats();
          flutter::EncodableMap map;
          map[flutter::EncodableValue("running")] = flutter::EncodableValue(st.running);
          map[flutter::EncodableValue("clientConnected")] = flutter::EncodableValue(st.client_connected);
          map[flutter::EncodableValue("hevc")] = flutter::EncodableValue(st.hevc);
          map[flutter::EncodableValue("width")] = flutter::EncodableValue(st.width);
          map[flutter::EncodableValue("height")] = flutter::EncodableValue(st.height);
          map[flutter::EncodableValue("fps")] = flutter::EncodableValue(st.fps);
          map[flutter::EncodableValue("encodeMs")] = flutter::EncodableValue(st.encode_ms);
          map[flutter::EncodableValue("mbps")] = flutter::EncodableValue(st.mbps);
          map[flutter::EncodableValue("encoderName")] = flutter::EncodableValue(st.encoder_name);
          result->Success(flutter::EncodableValue(map));
          return;
        }
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

          auto getOptionalInt = [&](const char* key, int default_val) -> int {
            auto it = args->find(flutter::EncodableValue(key));
            if (it != args->end()) {
              const auto* val = std::get_if<int>(&it->second);
              if (val) return *val;
            }
            return default_val;
          };

          int action = getOptionalInt("action", 1);
          double x = getDouble(args->at(flutter::EncodableValue("x")));
          double y = getDouble(args->at(flutter::EncodableValue("y")));
          double pressure = getDouble(args->at(flutter::EncodableValue("pressure")));

          // Pointer ID from the wire (1..16). Defaults to 1 so older clients
          // (that don't send "pointerId") still work and the pen keeps using
          // id 1.
          int pointerId = getOptionalInt("pointerId", 1);
          if (pointerId < 1 || pointerId > kMaxTouchContacts) {
            pointerId = 1;
          }

          int activeTouchMask = getOptionalInt("activeTouchMask", -1);
          int sequence = getOptionalInt("sequence", -1);

          // Handle Shortcuts (action == 5)
          if (action == 5) {
            int vkCode = static_cast<int>(x + 0.5);
            int modifiers = static_cast<int>(y + 0.5);

            bool ctrl = (modifiers & 1) != 0;
            bool shift = (modifiers & 2) != 0;
            bool alt = (modifiers & 4) != 0;
            bool win = (modifiers & 8) != 0;

            int numInputs = 0;
            INPUT inputs[10] = {};

            auto addKey = [&](WORD vk, bool keyUp) {
              inputs[numInputs].type = INPUT_KEYBOARD;
              inputs[numInputs].ki.wVk = vk;
              inputs[numInputs].ki.wScan =
                  static_cast<WORD>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
              inputs[numInputs].ki.dwFlags = keyUp ? KEYEVENTF_KEYUP : 0;
              numInputs++;
            };

            // Key Down for Modifiers
            if (ctrl) addKey(VK_CONTROL, false);
            if (shift) addKey(VK_SHIFT, false);
            if (alt) addKey(VK_MENU, false);
            if (win) addKey(VK_LWIN, false);

            // Key Down & Up for Main Key
            if (vkCode > 0 && vkCode <= 0xFFFF) {
              WORD mainVk = static_cast<WORD>(vkCode);
              addKey(mainVk, false);
              addKey(mainVk, true);
            }

            // Key Up for Modifiers (reverse order)
            if (win) addKey(VK_LWIN, true);
            if (alt) addKey(VK_MENU, true);
            if (shift) addKey(VK_SHIFT, true);
            if (ctrl) addKey(VK_CONTROL, true);

            if (numInputs > 0) {
              SendInput(numInputs, inputs, sizeof(INPUT));
            }
            result->Success();
            return;
          }

          // Pointer kind from the wire: 0=touch, 1=stylus, 2=invertedStylus, 3=mouse.
          // Defaults to stylus so older clients (that don't send "kind") still work.
          int kind = getOptionalInt("kind", 1);

          LONG screenWidth = static_cast<LONG>(GetSystemMetrics(SM_CXSCREEN));
          LONG screenHeight = static_cast<LONG>(GetSystemMetrics(SM_CYSCREEN));
          if (screenWidth <= 0) screenWidth = 1920;
          if (screenHeight <= 0) screenHeight = 1080;

          LONG px = std::clamp(
              static_cast<LONG>(x * static_cast<double>(screenWidth)),
              LONG{0},
              (std::max)(LONG{0}, screenWidth - 1));
          LONG py = std::clamp(
              static_cast<LONG>(y * static_cast<double>(screenHeight)),
              LONG{0},
              (std::max)(LONG{0}, screenHeight - 1));

          // Multi-touch path: inject all active contacts together in one frame.
          if (kind == 0) {
            if (touch_device_ == nullptr) {
              result->Error("NO_DEVICE", "Synthetic touch device not created");
              return;
            }
            bool ok = HandleTouchEvent(
                action, pointerId, px, py, activeTouchMask, sequence,
                screenWidth, screenHeight);
            if (ok) {
              result->Success();
            } else {
              result->Error("INJECT_FAILED", "Failed to inject touch input");
            }
            return;
          }

          // If switching to pen/stylus and Android reports no active fingers,
          // release any lingering touch contacts cleanly.
          if (activeTouchMask == 0 && !active_touches_.empty()) {
            ClearAllTouches();
          }

          // Pen / stylus / mouse path (single contact via PT_PEN).
          if (pointer_device_ == nullptr) {
            result->Error("NO_DEVICE", "Synthetic pen device not created");
            return;
          }

          POINTER_TYPE_INFO pointerInfo = {};
          pointerInfo.type = PT_PEN;
          pointerInfo.penInfo.pointerInfo.pointerType = PT_PEN;
          pointerInfo.penInfo.pointerInfo.pointerId = 1;
          pointerInfo.penInfo.pointerInfo.ptPixelLocation.x = px;
          pointerInfo.penInfo.pointerInfo.ptPixelLocation.y = py;
          pointerInfo.penInfo.penFlags = PEN_FLAG_NONE;
          pointerInfo.penInfo.penMask = PEN_MASK_PRESSURE;
          pointerInfo.penInfo.pressure = static_cast<UINT32>(
              std::clamp(pressure, 0.0, 1.0) * 1024.0);

          // Action mapping: 0=Down, 1=Move, 2=Up, 3=Cancel, 4=Hover
          if (action == 0) {
            pointerInfo.penInfo.pointerInfo.pointerFlags =
                POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_DOWN;
          } else if (action == 1) {
            pointerInfo.penInfo.pointerInfo.pointerFlags =
                POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE;
          } else if (action == 2) {
            pointerInfo.penInfo.pointerInfo.pointerFlags = POINTER_FLAG_UP;
          } else if (action == 4) {
            pointerInfo.penInfo.pointerInfo.pointerFlags =
                POINTER_FLAG_INRANGE | POINTER_FLAG_UPDATE;
          } else {
            pointerInfo.penInfo.pointerInfo.pointerFlags =
                POINTER_FLAG_UP | POINTER_FLAG_CANCELED;
          }

          BOOL success = InjectSyntheticPointerInput(pointer_device_, &pointerInfo, 1);
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
  hw_video_streamer_.Stop();
  ClearAllTouches();
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
