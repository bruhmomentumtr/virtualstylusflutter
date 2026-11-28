#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <timeapi.h>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <initguid.h>
#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <strmif.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <vector>

#include "hw_video_streamer.h"

using Microsoft::WRL::ComPtr;

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

bool SendAll(SOCKET sock, const uint8_t* data, size_t len) {
  size_t sent = 0;
  while (sent < len) {
    int n = send(sock,
                 reinterpret_cast<const char*>(data + sent),
                 static_cast<int>(len - sent),
                 0);
    if (n <= 0) return false;
    sent += static_cast<size_t>(n);
  }
  return true;
}

bool SendConfigPacket(SOCKET sock,
                      bool hevc,
                      uint16_t width,
                      uint16_t height,
                      uint16_t fps) {
  uint8_t pkt[8];
  pkt[0] = 0x01;
  pkt[1] = hevc ? 1 : 0;
  pkt[2] = static_cast<uint8_t>(width & 0xFF);
  pkt[3] = static_cast<uint8_t>((width >> 8) & 0xFF);
  pkt[4] = static_cast<uint8_t>(height & 0xFF);
  pkt[5] = static_cast<uint8_t>((height >> 8) & 0xFF);
  pkt[6] = static_cast<uint8_t>(fps & 0xFF);
  pkt[7] = static_cast<uint8_t>((fps >> 8) & 0xFF);
  return SendAll(sock, pkt, sizeof(pkt));
}

bool SendFramePacket(SOCKET sock,
                     bool is_keyframe,
                     const uint8_t* payload,
                     uint32_t size) {
  uint8_t hdr[6];
  hdr[0] = 0x02;
  hdr[1] = is_keyframe ? 1 : 0;
  hdr[2] = static_cast<uint8_t>(size & 0xFF);
  hdr[3] = static_cast<uint8_t>((size >> 8) & 0xFF);
  hdr[4] = static_cast<uint8_t>((size >> 16) & 0xFF);
  hdr[5] = static_cast<uint8_t>((size >> 24) & 0xFF);
  if (!SendAll(sock, hdr, sizeof(hdr))) return false;
  return SendAll(sock, payload, size);
}

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return {};
  int needed = WideCharToMultiByte(
      CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr,
      nullptr);
  if (needed <= 0) return {};
  std::string out(static_cast<size_t>(needed), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                      out.data(), needed, nullptr, nullptr);
  return out;
}

// Holds all D3D11 + DXGI + Media Foundation HW encoder resources for one
// active encoding configuration.
struct HwPipeline {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<IDXGIOutput1> output1;
  ComPtr<IDXGIOutputDuplication> duplication;

  ComPtr<ID3D11VideoDevice> video_device;
  ComPtr<ID3D11VideoContext> video_context;
  ComPtr<ID3D11VideoProcessorEnumerator> vp_enum;
  ComPtr<ID3D11VideoProcessor> video_processor;

  ComPtr<ID3D11Texture2D> nv12_tex;
  ComPtr<ID3D11VideoProcessorOutputView> nv12_out_view;
  ComPtr<ID3D11Texture2D> nv12_staging;

  ComPtr<IMFDXGIDeviceManager> dxgi_manager;
  ComPtr<IMFActivate> encoder_activate;
  ComPtr<IMFTransform> encoder;
  ComPtr<IMFMediaEventGenerator> event_gen;
  ComPtr<ICodecAPI> codec_api;

  bool is_async = false;
  bool use_d3d_input = false;
  bool hevc = false;
  int src_w = 0;
  int src_h = 0;
  int enc_w = 0;
  int enc_h = 0;
  int fps = 60;
  int bitrate_bps = 12000000;
  std::string encoder_name;
  int64_t frame_index = 0;

  void Shutdown() {
    if (encoder) {
      encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
      encoder->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
      encoder.Reset();
    }
    codec_api.Reset();
    event_gen.Reset();
    if (encoder_activate) {
      encoder_activate->ShutdownObject();
      encoder_activate.Reset();
    }
    dxgi_manager.Reset();
    nv12_staging.Reset();
    nv12_out_view.Reset();
    nv12_tex.Reset();
    video_processor.Reset();
    vp_enum.Reset();
    video_context.Reset();
    video_device.Reset();
    duplication.Reset();
    output1.Reset();
    context.Reset();
    device.Reset();
  }

  bool RecreateDuplication() {
    duplication.Reset();
    if (!output1 || !device) return false;
    HRESULT hr = output1->DuplicateOutput(device.Get(), &duplication);
    return SUCCEEDED(hr) && duplication != nullptr;
  }

  bool Init(const HwVideoStreamer::Config& cfg) {
    Shutdown();
    hevc = cfg.use_hevc;
    fps = std::clamp(cfg.fps, 15, 120);
    bitrate_bps = std::clamp(cfg.max_mbps, 2, 40) * 1000000;

    // 1. Create D3D11 device on primary adapter.
    D3D_FEATURE_LEVEL feature_levels[] = {D3D_FEATURE_LEVEL_11_1,
                                          D3D_FEATURE_LEVEL_11_0};
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT |
                 D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    HRESULT hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, feature_levels,
        ARRAYSIZE(feature_levels), D3D11_SDK_VERSION, &device, nullptr,
        &context);
    if (FAILED(hr)) return false;

    ComPtr<ID3D10Multithread> mt;
    if (SUCCEEDED(device.As(&mt)) && mt) {
      mt->SetMultithreadProtected(TRUE);
    }

    // 2. Get primary monitor IDXGIOutput1 & Desktop Duplication.
    ComPtr<IDXGIDevice> dxgi_device;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIOutput> output;
    if (FAILED(device.As(&dxgi_device)) ||
        FAILED(dxgi_device->GetAdapter(&adapter)) ||
        FAILED(adapter->EnumOutputs(0, &output)) ||
        FAILED(output.As(&output1))) {
      return false;
    }

    DXGI_OUTPUT_DESC out_desc = {};
    output1->GetDesc(&out_desc);
    src_w = static_cast<int>(out_desc.DesktopCoordinates.right -
                             out_desc.DesktopCoordinates.left);
    src_h = static_cast<int>(out_desc.DesktopCoordinates.bottom -
                             out_desc.DesktopCoordinates.top);
    if (src_w <= 0 || src_h <= 0) return false;

    if (!RecreateDuplication()) return false;

    // Compute even-aligned output dimensions.
    if (cfg.target_height > 0 && cfg.target_height < src_h) {
      enc_h = cfg.target_height & ~1;
      enc_w = static_cast<int>(
                  (static_cast<double>(src_w) * enc_h) / src_h) &
              ~1;
    } else {
      enc_w = src_w & ~1;
      enc_h = src_h & ~1;
    }
    if (enc_w < 64) enc_w = 64;
    if (enc_h < 64) enc_h = 64;

    // 3. Create D3D11 VideoProcessor for GPU BGRA -> NV12 conversion & scale.
    if (FAILED(device.As(&video_device)) ||
        FAILED(context.As(&video_context))) {
      return false;
    }

    D3D11_VIDEO_PROCESSOR_CONTENT_DESC vp_desc = {};
    vp_desc.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    vp_desc.InputWidth = static_cast<UINT>(src_w);
    vp_desc.InputHeight = static_cast<UINT>(src_h);
    vp_desc.OutputWidth = static_cast<UINT>(enc_w);
    vp_desc.OutputHeight = static_cast<UINT>(enc_h);
    vp_desc.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;

    if (FAILED(video_device->CreateVideoProcessorEnumerator(&vp_desc, &vp_enum)) ||
        FAILED(video_device->CreateVideoProcessor(vp_enum.Get(), 0,
                                                  &video_processor))) {
      return false;
    }

    D3D11_TEXTURE2D_DESC nv12_desc = {};
    nv12_desc.Width = static_cast<UINT>(enc_w);
    nv12_desc.Height = static_cast<UINT>(enc_h);
    nv12_desc.MipLevels = 1;
    nv12_desc.ArraySize = 1;
    nv12_desc.Format = DXGI_FORMAT_NV12;
    nv12_desc.SampleDesc.Count = 1;
    nv12_desc.Usage = D3D11_USAGE_DEFAULT;
    nv12_desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    if (FAILED(device->CreateTexture2D(&nv12_desc, nullptr, &nv12_tex))) {
      return false;
    }

    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC out_view_desc = {};
    out_view_desc.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
    out_view_desc.Texture2D.MipSlice = 0;
    if (FAILED(video_device->CreateVideoProcessorOutputView(
            nv12_tex.Get(), vp_enum.Get(), &out_view_desc, &nv12_out_view))) {
      return false;
    }

    D3D11_TEXTURE2D_DESC staging_desc = nv12_desc;
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.BindFlags = 0;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(device->CreateTexture2D(&staging_desc, nullptr, &nv12_staging))) {
      return false;
    }

    // 4. Create DXGI Device Manager for zero-copy MFT encoding.
    UINT reset_token = 0;
    if (SUCCEEDED(MFCreateDXGIDeviceManager(&reset_token, &dxgi_manager))) {
      dxgi_manager->ResetDevice(device.Get(), reset_token);
    }

    // 5. Enumerate and activate hardware video encoder MFT (H.264 or HEVC).
    const GUID out_subtype = hevc
                                 ? MakeVideoSubtype(MakeFourCC('H', 'E', 'V', 'C'))
                                 : MakeVideoSubtype(MakeFourCC('H', '2', '6', '4'));
    MFT_REGISTER_TYPE_INFO out_info = {};
    out_info.guidMajorType = MFMediaType_Video;
    out_info.guidSubtype = out_subtype;

    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                   MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                   nullptr, &out_info, &activates, &count);
    if (FAILED(hr) || activates == nullptr || count == 0) {
      if (activates) CoTaskMemFree(activates);
      return false;
    }

    for (UINT32 i = 0; i < count; ++i) {
      if (!activates[i]) continue;
      if (!encoder) {
        ComPtr<IMFTransform> candidate;
        if (SUCCEEDED(activates[i]->ActivateObject(IID_PPV_ARGS(&candidate))) &&
            candidate) {
          encoder = candidate;
          encoder_activate = activates[i];
          UINT32 name_len = 0;
          if (SUCCEEDED(activates[i]->GetStringLength(
                  MFT_FRIENDLY_NAME_Attribute, &name_len)) &&
              name_len > 0) {
            std::wstring wname(name_len + 1, L'\0');
            if (SUCCEEDED(activates[i]->GetString(
                    MFT_FRIENDLY_NAME_Attribute, wname.data(),
                    name_len + 1, &name_len))) {
              wname.resize(name_len);
              encoder_name = WideToUtf8(wname);
            }
          }
        }
      }
      activates[i]->Release();
    }
    CoTaskMemFree(activates);
    if (!encoder) return false;

    // Unlock async MFT if required.
    ComPtr<IMFAttributes> mft_attrs;
    if (SUCCEEDED(encoder->GetAttributes(&mft_attrs)) && mft_attrs) {
      UINT32 async_flag = 0;
      if (SUCCEEDED(mft_attrs->GetUINT32(MF_TRANSFORM_ASYNC, &async_flag)) &&
          async_flag != 0) {
        is_async = true;
        mft_attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
        encoder.As(&event_gen);
      }
    }

    if (dxgi_manager) {
      HRESULT d3d_hr = encoder->ProcessMessage(
          MFT_MESSAGE_SET_D3D_MANAGER,
          reinterpret_cast<ULONG_PTR>(dxgi_manager.Get()));
      use_d3d_input = SUCCEEDED(d3d_hr);
    }

    // Configure low-latency encoding via ICodecAPI before media types.
    if (SUCCEEDED(encoder.As(&codec_api)) && codec_api) {
      VARIANT v = {};
      v.vt = VT_BOOL;
      v.boolVal = VARIANT_TRUE;
      codec_api->SetValue(&CODECAPI_AVLowLatencyMode, &v);

      v.vt = VT_UI4;
      v.ulVal = eAVEncCommonRateControlMode_CBR;
      codec_api->SetValue(&CODECAPI_AVEncCommonRateControlMode, &v);

      v.vt = VT_UI4;
      v.ulVal = static_cast<ULONG>(bitrate_bps);
      codec_api->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &v);

      // Zero B-frames for minimum latency.
      v.vt = VT_UI4;
      v.ulVal = 0;
      codec_api->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &v);

      v.vt = VT_UI4;
      v.ulVal = static_cast<ULONG>(fps * 2);
      codec_api->SetValue(&CODECAPI_AVEncMPVGOPSize, &v);
    }

    // 6. Set Output Media Type (H.264 or HEVC).
    ComPtr<IMFMediaType> out_type;
    if (FAILED(MFCreateMediaType(&out_type))) return false;
    out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out_type->SetGUID(MF_MT_SUBTYPE, out_subtype);
    out_type->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(bitrate_bps));
    out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(out_type.Get(), MF_MT_FRAME_SIZE,
                       static_cast<UINT32>(enc_w), static_cast<UINT32>(enc_h));
    MFSetAttributeRatio(out_type.Get(), MF_MT_FRAME_RATE,
                        static_cast<UINT32>(fps), 1);
    MFSetAttributeRatio(out_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (FAILED(encoder->SetOutputType(0, out_type.Get(), 0))) return false;

    // 7. Set Input Media Type (NV12).
    ComPtr<IMFMediaType> in_type;
    if (FAILED(MFCreateMediaType(&in_type))) return false;
    in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE,
                       static_cast<UINT32>(enc_w), static_cast<UINT32>(enc_h));
    MFSetAttributeRatio(in_type.Get(), MF_MT_FRAME_RATE,
                        static_cast<UINT32>(fps), 1);
    MFSetAttributeRatio(in_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (FAILED(encoder->SetInputType(0, in_type.Get(), 0))) return false;

    encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    encoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    frame_index = 0;
    return true;
  }

  void ForceKeyFrame() {
    if (!codec_api) return;
    VARIANT v = {};
    v.vt = VT_UI4;
    v.ulVal = 1;
    codec_api->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &v);
  }

  bool ConvertBgraToNv12(ID3D11Texture2D* bgra_tex) {
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC in_view_desc = {};
    in_view_desc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    in_view_desc.Texture2D.MipSlice = 0;
    ComPtr<ID3D11VideoProcessorInputView> in_view;
    if (FAILED(video_device->CreateVideoProcessorInputView(
            bgra_tex, vp_enum.Get(), &in_view_desc, &in_view))) {
      return false;
    }

    D3D11_VIDEO_PROCESSOR_STREAM stream = {};
    stream.Enable = TRUE;
    stream.pInputSurface = in_view.Get();
    HRESULT hr = video_context->VideoProcessorBlt(
        video_processor.Get(), nv12_out_view.Get(), 0, 1, &stream);
    return SUCCEEDED(hr);
  }

  bool BuildNv12Sample(ComPtr<IMFSample>* out_sample) {
    ComPtr<IMFSample> sample;
    if (FAILED(MFCreateSample(&sample))) return false;

    ComPtr<IMFMediaBuffer> buffer;
    if (use_d3d_input) {
      if (FAILED(MFCreateDXGISurfaceBuffer(
              __uuidof(ID3D11Texture2D), nv12_tex.Get(), 0, FALSE, &buffer))) {
        return false;
      }
      ComPtr<IMF2DBuffer> buf2d;
      if (SUCCEEDED(buffer.As(&buf2d)) && buf2d) {
        DWORD len = 0;
        if (SUCCEEDED(buf2d->GetContiguousLength(&len))) {
          buffer->SetCurrentLength(len);
        }
      }
    } else {
      context->CopyResource(nv12_staging.Get(), nv12_tex.Get());
      D3D11_MAPPED_SUBRESOURCE mapped = {};
      if (FAILED(context->Map(nv12_staging.Get(), 0, D3D11_MAP_READ, 0,
                              &mapped))) {
        return false;
      }
      const DWORD nv12_size = static_cast<DWORD>(enc_w * enc_h * 3 / 2);
      if (FAILED(MFCreateMemoryBuffer(nv12_size, &buffer))) {
        context->Unmap(nv12_staging.Get(), 0);
        return false;
      }
      BYTE* dst = nullptr;
      if (SUCCEEDED(buffer->Lock(&dst, nullptr, nullptr)) && dst) {
        const BYTE* src = static_cast<const BYTE*>(mapped.pData);
        for (int y = 0; y < enc_h; ++y) {
          std::memcpy(dst + y * enc_w, src + y * mapped.RowPitch,
                      static_cast<size_t>(enc_w));
        }
        BYTE* dst_uv = dst + enc_w * enc_h;
        const BYTE* src_uv = src + mapped.RowPitch * enc_h;
        for (int y = 0; y < enc_h / 2; ++y) {
          std::memcpy(dst_uv + y * enc_w, src_uv + y * mapped.RowPitch,
                      static_cast<size_t>(enc_w));
        }
        buffer->Unlock();
        buffer->SetCurrentLength(nv12_size);
      }
      context->Unmap(nv12_staging.Get(), 0);
    }

    sample->AddBuffer(buffer.Get());
    const LONGLONG dur = 10000000LL / fps;
    sample->SetSampleTime(frame_index * dur);
    sample->SetSampleDuration(dur);
    ++frame_index;
    *out_sample = sample;
    return true;
  }

  bool PullEncodedOutput(std::vector<uint8_t>* out_bytes, bool* is_keyframe) {
    MFT_OUTPUT_STREAM_INFO stream_info = {};
    encoder->GetOutputStreamInfo(0, &stream_info);

    MFT_OUTPUT_DATA_BUFFER out_data = {};
    out_data.dwStreamID = 0;

    ComPtr<IMFSample> alloc_sample;
    const bool mft_provides =
        (stream_info.dwFlags &
         (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
          MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
    if (!mft_provides) {
      if (FAILED(MFCreateSample(&alloc_sample))) return false;
      ComPtr<IMFMediaBuffer> buf;
      DWORD cb = stream_info.cbSize > 0 ? stream_info.cbSize
                                        : static_cast<DWORD>(enc_w * enc_h);
      if (FAILED(MFCreateMemoryBuffer(cb, &buf))) return false;
      alloc_sample->AddBuffer(buf.Get());
      out_data.pSample = alloc_sample.Get();
    }

    DWORD status = 0;
    HRESULT hr = encoder->ProcessOutput(0, 1, &out_data, &status);
    if (out_data.pEvents) {
      out_data.pEvents->Release();
      out_data.pEvents = nullptr;
    }
    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
      ComPtr<IMFMediaType> avail;
      if (SUCCEEDED(encoder->GetOutputAvailableType(0, 0, &avail))) {
        encoder->SetOutputType(0, avail.Get(), 0);
      }
      if (mft_provides && out_data.pSample) out_data.pSample->Release();
      return false;
    }
    if (FAILED(hr) || out_data.pSample == nullptr) {
      if (mft_provides && out_data.pSample) out_data.pSample->Release();
      return false;
    }

    UINT32 clean_point = 0;
    *is_keyframe =
        SUCCEEDED(out_data.pSample->GetUINT32(MFSampleExtension_CleanPoint,
                                              &clean_point)) &&
        clean_point != 0;

    ComPtr<IMFMediaBuffer> contiguous;
    if (SUCCEEDED(out_data.pSample->ConvertToContiguousBuffer(&contiguous)) &&
        contiguous) {
      BYTE* ptr = nullptr;
      DWORD len = 0;
      if (SUCCEEDED(contiguous->Lock(&ptr, nullptr, &len)) && ptr && len > 0) {
        out_bytes->assign(ptr, ptr + len);
        contiguous->Unlock();
      }
    }

    if (mft_provides) {
      out_data.pSample->Release();
    }
    return !out_bytes->empty();
  }

  bool EncodeCurrentNv12(std::vector<uint8_t>* out_bytes, bool* is_keyframe) {
    ComPtr<IMFSample> sample;
    if (!BuildNv12Sample(&sample)) return false;

    if (is_async && event_gen) {
      bool input_fed = false;
      for (int iter = 0; iter < 16; ++iter) {
        ComPtr<IMFMediaEvent> ev;
        if (FAILED(event_gen->GetEvent(0, &ev)) || !ev) break;
        MediaEventType met = MEUnknown;
        ev->GetType(&met);
        if (met == METransformNeedInput && !input_fed) {
          if (FAILED(encoder->ProcessInput(0, sample.Get(), 0))) return false;
          input_fed = true;
        } else if (met == METransformHaveOutput) {
          if (PullEncodedOutput(out_bytes, is_keyframe)) {
            return true;
          }
        }
      }
      return false;
    }

    if (FAILED(encoder->ProcessInput(0, sample.Get(), 0))) return false;
    return PullEncodedOutput(out_bytes, is_keyframe);
  }
};

}  // namespace

HwVideoStreamer::HwVideoStreamer() = default;

HwVideoStreamer::~HwVideoStreamer() {
  Stop();
}

bool HwVideoStreamer::Start(const Config& config, uint16_t port) {
  Stop();
  {
    std::lock_guard<std::mutex> lock(config_mutex_);
    config_ = config;
  }
  stop_requested_.store(false);
  reconfig_requested_.store(false);
  worker_ = std::thread(&HwVideoStreamer::WorkerLoop, this, port);
  return true;
}

void HwVideoStreamer::Stop() {
  stop_requested_.store(true);
  if (worker_.joinable()) {
    worker_.join();
  }
  std::lock_guard<std::mutex> lock(stats_mutex_);
  stats_.running = false;
  stats_.client_connected = false;
  stats_.fps = 0.0;
}

void HwVideoStreamer::UpdateConfig(const Config& config) {
  {
    std::lock_guard<std::mutex> lock(config_mutex_);
    config_ = config;
  }
  reconfig_requested_.store(true);
}

HwVideoStreamer::Stats HwVideoStreamer::GetStats() const {
  std::lock_guard<std::mutex> lock(stats_mutex_);
  return stats_;
}

void HwVideoStreamer::WorkerLoop(uint16_t port) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  MFStartup(MF_VERSION, MFSTARTUP_LITE);
  timeBeginPeriod(1);

  WSADATA wsa = {};
  const bool wsa_ok = (WSAStartup(MAKEWORD(2, 2), &wsa) == 0);

  SOCKET listen_sock = INVALID_SOCKET;
  if (wsa_ok) {
    listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listen_sock != INVALID_SOCKET) {
      int reuse = 1;
      setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR,
                 reinterpret_cast<const char*>(&reuse), sizeof(reuse));
      u_long non_blocking = 1;
      ioctlsocket(listen_sock, FIONBIO, &non_blocking);

      sockaddr_in addr = {};
      addr.sin_family = AF_INET;
      addr.sin_addr.s_addr = INADDR_ANY;
      addr.sin_port = htons(port);
      if (bind(listen_sock, reinterpret_cast<sockaddr*>(&addr),
               sizeof(addr)) != 0 ||
          listen(listen_sock, 1) != 0) {
        closesocket(listen_sock);
        listen_sock = INVALID_SOCKET;
      }
    }
  }

  {
    std::lock_guard<std::mutex> lock(stats_mutex_);
    stats_.running = (listen_sock != INVALID_SOCKET);
  }

  HwPipeline pipeline;
  bool pipeline_ready = false;
  bool have_initial_frame = false;
  SOCKET client_sock = INVALID_SOCKET;

  auto last_stat_time = std::chrono::steady_clock::now();
  int frames_in_window = 0;
  uint64_t bytes_in_window = 0;
  double encode_ms_sum = 0.0;
  std::vector<uint8_t> encoded_buf;

  while (!stop_requested_.load() && listen_sock != INVALID_SOCKET) {
    // Wait for a client connection if none is connected.
    if (client_sock == INVALID_SOCKET) {
      SOCKET accepted = accept(listen_sock, nullptr, nullptr);
      if (accepted == INVALID_SOCKET) {
        Sleep(20);
        continue;
      }
      u_long blocking = 0;
      ioctlsocket(accepted, FIONBIO, &blocking);
      int nodelay = 1;
      setsockopt(accepted, IPPROTO_TCP, TCP_NODELAY,
                 reinterpret_cast<const char*>(&nodelay), sizeof(nodelay));
      int sndbuf = 256 * 1024;
      setsockopt(accepted, SOL_SOCKET, SO_SNDBUF,
                 reinterpret_cast<const char*>(&sndbuf), sizeof(sndbuf));
      DWORD send_timeout = 500;
      setsockopt(accepted, SOL_SOCKET, SO_SNDTIMEO,
                 reinterpret_cast<const char*>(&send_timeout),
                 sizeof(send_timeout));

      client_sock = accepted;
      reconfig_requested_.store(true);
      {
        std::lock_guard<std::mutex> lock(stats_mutex_);
        stats_.client_connected = true;
      }
    }

    // Initialize or reconfigure hardware pipeline when needed.
    if (!pipeline_ready || reconfig_requested_.exchange(false)) {
      Config cfg;
      {
        std::lock_guard<std::mutex> lock(config_mutex_);
        cfg = config_;
      }
      pipeline_ready = pipeline.Init(cfg);
      if (!pipeline_ready && cfg.use_hevc) {
        // Fallback to HW H.264 if HEVC encoder failed to initialize.
        cfg.use_hevc = false;
        pipeline_ready = pipeline.Init(cfg);
      }
      have_initial_frame = false;
      if (!pipeline_ready) {
        closesocket(client_sock);
        client_sock = INVALID_SOCKET;
        std::lock_guard<std::mutex> lock(stats_mutex_);
        stats_.client_connected = false;
        Sleep(100);
        continue;
      }

      if (!SendConfigPacket(client_sock, pipeline.hevc,
                            static_cast<uint16_t>(pipeline.enc_w),
                            static_cast<uint16_t>(pipeline.enc_h),
                            static_cast<uint16_t>(pipeline.fps))) {
        closesocket(client_sock);
        client_sock = INVALID_SOCKET;
        std::lock_guard<std::mutex> lock(stats_mutex_);
        stats_.client_connected = false;
        continue;
      }
      pipeline.ForceKeyFrame();

      {
        std::lock_guard<std::mutex> lock(stats_mutex_);
        stats_.hevc = pipeline.hevc;
        stats_.width = pipeline.enc_w;
        stats_.height = pipeline.enc_h;
        stats_.encoder_name = pipeline.encoder_name;
      }
    }

    const auto frame_start = std::chrono::steady_clock::now();
    const int target_frame_ms = (std::max)(1, 1000 / pipeline.fps);

    // Acquire next desktop frame from DXGI Desktop Duplication.
    DXGI_OUTDUPL_FRAME_INFO frame_info = {};
    ComPtr<IDXGIResource> desktop_res;
    HRESULT acq_hr = pipeline.duplication->AcquireNextFrame(
        static_cast<UINT>(target_frame_ms), &frame_info, &desktop_res);

    if (acq_hr == DXGI_ERROR_ACCESS_LOST) {
      pipeline.RecreateDuplication();
      Sleep(10);
      continue;
    }

    bool converted = false;
    if (SUCCEEDED(acq_hr) && desktop_res) {
      ComPtr<ID3D11Texture2D> bgra_tex;
      if (SUCCEEDED(desktop_res.As(&bgra_tex)) && bgra_tex) {
        converted = pipeline.ConvertBgraToNv12(bgra_tex.Get());
        if (converted) have_initial_frame = true;
      }
      pipeline.duplication->ReleaseFrame();
    } else if (acq_hr == DXGI_ERROR_WAIT_TIMEOUT) {
      // No screen update; re-send nothing unless we haven't sent any frame yet.
      if (!have_initial_frame) {
        continue;
      }
      // Check if client disconnected while idle.
      char peek_buf = 0;
      u_long nb = 1;
      ioctlsocket(client_sock, FIONBIO, &nb);
      int r = recv(client_sock, &peek_buf, 1, MSG_PEEK);
      u_long bl = 0;
      ioctlsocket(client_sock, FIONBIO, &bl);
      if (r == 0) {
        closesocket(client_sock);
        client_sock = INVALID_SOCKET;
        std::lock_guard<std::mutex> lock(stats_mutex_);
        stats_.client_connected = false;
      }
      continue;
    } else {
      Sleep(5);
      continue;
    }

    if (!converted) continue;

    encoded_buf.clear();
    bool is_keyframe = false;
    const auto enc_t0 = std::chrono::steady_clock::now();
    const bool enc_ok = pipeline.EncodeCurrentNv12(&encoded_buf, &is_keyframe);
    const auto enc_t1 = std::chrono::steady_clock::now();
    const double enc_ms =
        std::chrono::duration<double, std::milli>(enc_t1 - enc_t0).count();

    if (enc_ok && !encoded_buf.empty()) {
      if (!SendFramePacket(client_sock, is_keyframe, encoded_buf.data(),
                           static_cast<uint32_t>(encoded_buf.size()))) {
        closesocket(client_sock);
        client_sock = INVALID_SOCKET;
        std::lock_guard<std::mutex> lock(stats_mutex_);
        stats_.client_connected = false;
        continue;
      }
      ++frames_in_window;
      bytes_in_window += encoded_buf.size();
      encode_ms_sum += enc_ms;
    }

    const auto now = std::chrono::steady_clock::now();
    const double elapsed_sec =
        std::chrono::duration<double>(now - last_stat_time).count();
    if (elapsed_sec >= 1.0) {
      std::lock_guard<std::mutex> lock(stats_mutex_);
      stats_.fps = frames_in_window / elapsed_sec;
      stats_.mbps = (bytes_in_window * 8.0) / (elapsed_sec * 1000000.0);
      stats_.encode_ms =
          frames_in_window > 0 ? (encode_ms_sum / frames_in_window) : 0.0;
      frames_in_window = 0;
      bytes_in_window = 0;
      encode_ms_sum = 0.0;
      last_stat_time = now;
    }

    // Pace to target FPS without oversleeping.
    const double frame_elapsed_ms =
        std::chrono::duration<double, std::milli>(now - frame_start).count();
    const double target_ms = 1000.0 / static_cast<double>(pipeline.fps);
    if (frame_elapsed_ms + 1.0 < target_ms) {
      Sleep(static_cast<DWORD>(target_ms - frame_elapsed_ms));
    }
  }

  if (client_sock != INVALID_SOCKET) {
    closesocket(client_sock);
  }
  if (listen_sock != INVALID_SOCKET) {
    closesocket(listen_sock);
  }
  pipeline.Shutdown();
  if (wsa_ok) WSACleanup();
  timeEndPeriod(1);
  MFShutdown();
  CoUninitialize();
}
