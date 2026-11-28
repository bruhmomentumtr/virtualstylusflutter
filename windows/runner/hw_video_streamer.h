#ifndef RUNNER_HW_VIDEO_STREAMER_H_
#define RUNNER_HW_VIDEO_STREAMER_H_

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

// Ultra-low-latency Windows hardware screen streamer:
//   DXGI Desktop Duplication (GPU VRAM)
//   -> D3D11 VideoProcessor (GPU BGRA -> NV12 + scaling)
//   -> Media Foundation Hardware Encoder MFT (NVENC / QSV / AMF H.264 or HEVC)
//   -> TCP port 4002 (TCP_NODELAY) Annex-B stream
class HwVideoStreamer {
 public:
  struct Config {
    bool use_hevc = false;  // false = H.264, true = H.265 (HEVC)
    int target_height = 0;  // 0 = Native screen height
    int fps = 60;
    int max_mbps = 12;
  };

  struct Stats {
    bool running = false;
    bool client_connected = false;
    bool hevc = false;
    int width = 0;
    int height = 0;
    double fps = 0.0;
    double encode_ms = 0.0;
    double mbps = 0.0;
    std::string encoder_name;
  };

  HwVideoStreamer();
  ~HwVideoStreamer();

  bool Start(const Config& config, uint16_t port = 4002);
  void Stop();
  void UpdateConfig(const Config& config);
  Stats GetStats() const;

 private:
  void WorkerLoop(uint16_t port);

  std::thread worker_;
  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> reconfig_requested_{false};

  mutable std::mutex config_mutex_;
  Config config_;

  mutable std::mutex stats_mutex_;
  Stats stats_;
};

#endif  // RUNNER_HW_VIDEO_STREAMER_H_
