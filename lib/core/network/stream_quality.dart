import 'package:flutter_webrtc/flutter_webrtc.dart';

enum StreamQualityMode { performance, balanced, quality, manual }

enum VideoCodecPreference { auto, vp8, h264, vp9, h265, av1 }

class CodecCapability {
  final bool supported;
  final bool hardware;

  const CodecCapability({
    required this.supported,
    required this.hardware,
  });

  String get badge => !supported ? 'N/A' : (hardware ? 'HW' : 'SW');

  Map<String, dynamic> toMap() => {
        'supported': supported,
        'hardware': hardware,
      };

  factory CodecCapability.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return const CodecCapability(supported: false, hardware: false);
    }
    return CodecCapability(
      supported: map['supported'] == true,
      hardware: map['hardware'] == true,
    );
  }
}

extension VideoCodecPreferenceExt on VideoCodecPreference {
  String get label {
    switch (this) {
      case VideoCodecPreference.auto:
        return 'Auto';
      case VideoCodecPreference.vp8:
        return 'VP8';
      case VideoCodecPreference.h264:
        return 'H264';
      case VideoCodecPreference.vp9:
        return 'VP9';
      case VideoCodecPreference.h265:
        return 'H265';
      case VideoCodecPreference.av1:
        return 'AV1';
    }
  }

  /// SDP rtpmap codec names that match this preference.
  List<String> get sdpNames {
    switch (this) {
      case VideoCodecPreference.auto:
      case VideoCodecPreference.vp8:
        return const ['VP8'];
      case VideoCodecPreference.h264:
        return const ['H264'];
      case VideoCodecPreference.vp9:
        return const ['VP9'];
      case VideoCodecPreference.h265:
        return const ['H265', 'HEVC'];
      case VideoCodecPreference.av1:
        return const ['AV1', 'AV1X'];
    }
  }
}

VideoCodecPreference videoCodecPreferenceFromName(String? name) {
  switch (name) {
    case 'vp8':
      return VideoCodecPreference.vp8;
    case 'h264':
      return VideoCodecPreference.h264;
    case 'vp9':
      return VideoCodecPreference.vp9;
    case 'h265':
      return VideoCodecPreference.h265;
    case 'av1':
      return VideoCodecPreference.av1;
    case 'auto':
    default:
      return VideoCodecPreference.auto;
  }
}

/// Parses the video codecs advertised in a WebRTC SDP offer/answer.
Set<VideoCodecPreference> parseSupportedVideoCodecsFromSdp(String sdp) {
  final supported = <VideoCodecPreference>{};
  final lines = sdp.split(RegExp(r'\r?\n'));
  final videoStart = lines.indexWhere((l) => l.startsWith('m=video '));
  if (videoStart == -1) return supported;

  final rtpmapRegex = RegExp(
    r'^a=rtpmap:\d+\s+([A-Za-z0-9\-_]+)/',
    caseSensitive: false,
  );
  for (int i = videoStart + 1; i < lines.length; i++) {
    if (lines[i].startsWith('m=')) break;
    final m = rtpmapRegex.firstMatch(lines[i]);
    if (m == null) continue;
    final codec = m.group(1)!.toUpperCase();
    if (codec == 'VP8') supported.add(VideoCodecPreference.vp8);
    if (codec == 'H264') supported.add(VideoCodecPreference.h264);
    if (codec == 'VP9') supported.add(VideoCodecPreference.vp9);
    if (codec == 'H265' || codec == 'HEVC') {
      supported.add(VideoCodecPreference.h265);
    }
    if (codec == 'AV1' || codec == 'AV1X') {
      supported.add(VideoCodecPreference.av1);
    }
  }
  return supported;
}

/// Probes the local libwebrtc build for supported video codecs by creating a
/// short-lived offer with a send-only video transceiver.
Future<Set<VideoCodecPreference>> probeWebRtcVideoCodecs() async {
  RTCPeerConnection? pc;
  try {
    pc = await createPeerConnection({'iceServers': []});
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly),
    );
    final offer = await pc.createOffer();
    return parseSupportedVideoCodecsFromSdp(offer.sdp ?? '');
  } catch (_) {
    return const {
      VideoCodecPreference.vp8,
      VideoCodecPreference.h264,
      VideoCodecPreference.vp9,
      VideoCodecPreference.av1,
    };
  } finally {
    await pc?.close();
  }
}

const List<int> kManualResolutionHeights = <int>[0, 1440, 1080, 900, 720, 540];
const List<int> kManualFpsOptions = <int>[30, 60, 90, 120];

class ManualStreamSettings {
  /// Target video height in pixels. `0` means Native (no downscaling).
  final int targetHeight;
  final int fps;
  final int maxMbps;

  const ManualStreamSettings({
    this.targetHeight = 1080,
    this.fps = 60,
    this.maxMbps = 15,
  });

  ManualStreamSettings copyWith({
    int? targetHeight,
    int? fps,
    int? maxMbps,
  }) {
    return ManualStreamSettings(
      targetHeight: targetHeight ?? this.targetHeight,
      fps: fps ?? this.fps,
      maxMbps: maxMbps ?? this.maxMbps,
    );
  }

  String get resolutionLabel =>
      targetHeight <= 0 ? 'Native' : '${targetHeight}p';

  Map<String, dynamic> toMap() => {
        'targetHeight': targetHeight,
        'fps': fps,
        'maxMbps': maxMbps,
      };

  factory ManualStreamSettings.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const ManualStreamSettings();
    final rawHeight = (map['targetHeight'] as num?)?.toInt() ?? 1080;
    final rawFps = (map['fps'] as num?)?.toInt() ?? 60;
    final rawMbps = (map['maxMbps'] as num?)?.toInt() ?? 15;
    return ManualStreamSettings(
      targetHeight: rawHeight < 0 ? 0 : rawHeight,
      fps: rawFps.clamp(15, 120),
      maxMbps: rawMbps.clamp(2, 40),
    );
  }
}

class StreamQualityConfig {
  final String label;
  final String shortLabel;
  final String description;
  final int startBitrateKbps;
  final int minBitrateKbps;
  final int maxBitrateKbps;
  final int maxFramerate;
  final double scaleResolutionDownBy;
  final RTCDegradationPreference degradationPreference;

  const StreamQualityConfig({
    required this.label,
    required this.shortLabel,
    required this.description,
    required this.startBitrateKbps,
    required this.minBitrateKbps,
    required this.maxBitrateKbps,
    required this.maxFramerate,
    required this.scaleResolutionDownBy,
    required this.degradationPreference,
  });
}

extension StreamQualityModeExt on StreamQualityMode {
  StreamQualityConfig resolveConfig({
    ManualStreamSettings manual = const ManualStreamSettings(),
    int sourceHeight = 1080,
  }) {
    switch (this) {
      case StreamQualityMode.performance:
        return const StreamQualityConfig(
          label: 'Performance',
          shortLabel: 'Perf',
          description: 'Lowest latency • 60 FPS • 6 Mbps',
          startBitrateKbps: 3000,
          minBitrateKbps: 1000,
          maxBitrateKbps: 6000,
          maxFramerate: 60,
          scaleResolutionDownBy: 1.5,
          degradationPreference: RTCDegradationPreference.MAINTAIN_FRAMERATE,
        );
      case StreamQualityMode.balanced:
        return const StreamQualityConfig(
          label: 'Balanced',
          shortLabel: 'Bal',
          description: 'Native res • 60 FPS • 12 Mbps',
          startBitrateKbps: 6000,
          minBitrateKbps: 1500,
          maxBitrateKbps: 12000,
          maxFramerate: 60,
          scaleResolutionDownBy: 1.0,
          degradationPreference: RTCDegradationPreference.MAINTAIN_FRAMERATE,
        );
      case StreamQualityMode.quality:
        return const StreamQualityConfig(
          label: 'Quality',
          shortLabel: 'HQ',
          description: 'Native res • 60 FPS • 25 Mbps',
          startBitrateKbps: 10000,
          minBitrateKbps: 2500,
          maxBitrateKbps: 25000,
          maxFramerate: 60,
          scaleResolutionDownBy: 1.0,
          degradationPreference: RTCDegradationPreference.MAINTAIN_RESOLUTION,
        );
      case StreamQualityMode.manual:
        double scale = 1.0;
        if (manual.targetHeight > 0 && sourceHeight > manual.targetHeight) {
          scale = (sourceHeight / manual.targetHeight).clamp(1.0, 4.0);
        }
        final int maxKbps = manual.maxMbps.clamp(2, 40) * 1000;
        final int startKbps = (maxKbps * 0.6).round().clamp(1000, maxKbps);
        final int minKbps = (maxKbps * 0.2).round().clamp(500, startKbps);
        return StreamQualityConfig(
          label: 'Manual',
          shortLabel: 'Man',
          description:
              '${manual.resolutionLabel} • ${manual.fps} FPS • ${manual.maxMbps} Mbps',
          startBitrateKbps: startKbps,
          minBitrateKbps: minKbps,
          maxBitrateKbps: maxKbps,
          maxFramerate: manual.fps.clamp(15, 120),
          scaleResolutionDownBy: scale,
          degradationPreference: RTCDegradationPreference.MAINTAIN_FRAMERATE,
        );
    }
  }

  StreamQualityConfig get config => resolveConfig();
}

StreamQualityMode streamQualityModeFromName(String? name) {
  switch (name) {
    case 'performance':
      return StreamQualityMode.performance;
    case 'quality':
      return StreamQualityMode.quality;
    case 'manual':
      return StreamQualityMode.manual;
    case 'balanced':
    default:
      return StreamQualityMode.balanced;
  }
}

/// Optimizes a WebRTC SDP string so local-network screen mirroring starts at
/// high bitrate immediately instead of ramping up slowly from ~300 kbps,
/// and prioritizes the selected video codec.
String optimizeVideoSdp(
  String sdp,
  StreamQualityConfig cfg, {
  VideoCodecPreference codecPreference = VideoCodecPreference.auto,
}) {
  try {
    final hasCrLf = sdp.contains('\r\n');
    final lineSep = hasCrLf ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));

    final videoStart = lines.indexWhere((l) => l.startsWith('m=video '));
    if (videoStart == -1) return sdp;

    int videoEnd = lines.length;
    for (int i = videoStart + 1; i < lines.length; i++) {
      if (lines[i].startsWith('m=')) {
        videoEnd = i;
        break;
      }
    }

    // Collect payload types for video codecs and identify preferred codec PTs.
    final preferredCodecNames = codecPreference.sdpNames;
    final videoCodecPts = <String>{};
    final preferredPts = <String>[];
    final rtpmapRegex = RegExp(
      r'^a=rtpmap:(\d+)\s+([A-Za-z0-9\-_]+)/',
      caseSensitive: false,
    );
    for (int i = videoStart + 1; i < videoEnd; i++) {
      final m = rtpmapRegex.firstMatch(lines[i]);
      if (m != null) {
        final pt = m.group(1)!;
        final codec = m.group(2)!.toUpperCase();
        if (codec == 'H264' ||
            codec == 'H265' ||
            codec == 'HEVC' ||
            codec == 'VP8' ||
            codec == 'VP9' ||
            codec == 'AV1' ||
            codec == 'AV1X') {
          videoCodecPts.add(pt);
          if (preferredCodecNames.contains(codec)) {
            preferredPts.add(pt);
          }
        }
      }
    }

    // Move the preferred codec payload types to the front of m=video.
    if (preferredPts.isNotEmpty) {
      final parts = lines[videoStart].split(' ');
      if (parts.length > 3) {
        final header = parts.sublist(0, 3);
        final payloadTypes = parts.sublist(3);
        final preferred = <String>[];
        final others = <String>[];
        for (final pt in payloadTypes) {
          if (preferredPts.contains(pt)) {
            preferred.add(pt);
          } else {
            others.add(pt);
          }
        }
        lines[videoStart] = [...header, ...preferred, ...others].join(' ');
      }
    }

    final bitrateParams =
        'x-google-start-bitrate=${cfg.startBitrateKbps};'
        'x-google-min-bitrate=${cfg.minBitrateKbps};'
        'x-google-max-bitrate=${cfg.maxBitrateKbps}';

    final fmtpRegex = RegExp(r'^a=fmtp:(\d+)\s+(.*)$');
    final stripGoogleBitrate = RegExp(
      r'(?:^|;)\s*x-google-(?:start|min|max)-bitrate=\d+',
      caseSensitive: false,
    );

    final fmtpUpdated = <String>{};
    final rebuiltVideoSection = <String>[];
    bool bandwidthInserted = false;

    for (int i = videoStart; i < videoEnd; i++) {
      final line = lines[i];

      // Strip old bandwidth lines so we can insert fresh ones cleanly.
      if (line.startsWith('b=AS:') || line.startsWith('b=TIAS:')) {
        continue;
      }

      if (i == videoStart) {
        rebuiltVideoSection.add(line);
        continue;
      }

      final fmtpMatch = fmtpRegex.firstMatch(line);
      if (fmtpMatch != null && videoCodecPts.contains(fmtpMatch.group(1))) {
        final pt = fmtpMatch.group(1)!;
        var params = fmtpMatch.group(2)!.replaceAll(stripGoogleBitrate, '');
        params = params.replaceAll(RegExp(r'^;+|;+$'), '');
        final combined =
            params.isEmpty ? bitrateParams : '$params;$bitrateParams';
        rebuiltVideoSection.add('a=fmtp:$pt $combined');
        fmtpUpdated.add(pt);
        continue;
      }

      rebuiltVideoSection.add(line);

      // Insert b=AS and b=TIAS right after the c= line in the video section.
      if (!bandwidthInserted && line.startsWith('c=')) {
        rebuiltVideoSection.add('b=AS:${cfg.maxBitrateKbps}');
        rebuiltVideoSection.add('b=TIAS:${cfg.maxBitrateKbps * 1000}');
        bandwidthInserted = true;
      }
    }

    if (!bandwidthInserted && rebuiltVideoSection.isNotEmpty) {
      rebuiltVideoSection.insert(1, 'b=AS:${cfg.maxBitrateKbps}');
      rebuiltVideoSection.insert(2, 'b=TIAS:${cfg.maxBitrateKbps * 1000}');
    }

    // For video codecs without an existing a=fmtp line (common for VP8),
    // add one right after their a=rtpmap line so start/min/max bitrate apply.
    final withMissingFmtp = <String>[];
    for (final line in rebuiltVideoSection) {
      withMissingFmtp.add(line);
      final m = rtpmapRegex.firstMatch(line);
      if (m != null) {
        final pt = m.group(1)!;
        if (videoCodecPts.contains(pt) && !fmtpUpdated.contains(pt)) {
          withMissingFmtp.add('a=fmtp:$pt $bitrateParams');
          fmtpUpdated.add(pt);
        }
      }
    }

    final resultLines = <String>[
      ...lines.sublist(0, videoStart),
      ...withMissingFmtp,
      ...lines.sublist(videoEnd),
    ];

    return resultLines.join(lineSep);
  } catch (_) {
    return sdp;
  }
}

/// Picks the best mutually-supported codec when Auto is selected:
/// prefers codecs where both PC and Tablet have HW support, otherwise falls
/// back to VP8 (lowest software latency in libwebrtc).
VideoCodecPreference resolveAutoCodec(
  Map<VideoCodecPreference, CodecCapability> pcCaps,
  Map<VideoCodecPreference, CodecCapability> tabletCaps,
) {
  const priority = [
    VideoCodecPreference.h264,
    VideoCodecPreference.vp8,
    VideoCodecPreference.vp9,
    VideoCodecPreference.h265,
    VideoCodecPreference.av1,
  ];
  // 1) Both PC and Tablet support WebRTC + HW acceleration.
  for (final codec in priority) {
    final pc = pcCaps[codec];
    final tab = tabletCaps[codec];
    if (pc != null &&
        pc.supported &&
        pc.hardware &&
        tab != null &&
        tab.supported &&
        tab.hardware) {
      return codec;
    }
  }
  // 2) Fallback to VP8 (zero-lookahead, lowest latency software encode).
  return VideoCodecPreference.vp8;
}

/// Applies bitrate, framerate, resolution scaling, and degradation preference
/// directly on active video RTCRtpSenders (works live without reconnecting).
Future<void> applyVideoSenderParameters(
  RTCPeerConnection pc,
  StreamQualityConfig cfg,
) async {
  try {
    final senders = await pc.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind != 'video') continue;
      final params = sender.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) {
        params.encodings = [
          RTCRtpEncoding(
            active: true,
            maxBitrate: cfg.maxBitrateKbps * 1000,
            minBitrate: cfg.minBitrateKbps * 1000,
            maxFramerate: cfg.maxFramerate,
            numTemporalLayers: 1,
            scaleResolutionDownBy: cfg.scaleResolutionDownBy,
            priority: RTCPriorityType.high,
            networkPriority: RTCPriorityType.high,
          ),
        ];
      } else {
        for (final enc in encodings) {
          enc.active = true;
          enc.maxBitrate = cfg.maxBitrateKbps * 1000;
          enc.minBitrate = cfg.minBitrateKbps * 1000;
          enc.maxFramerate = cfg.maxFramerate;
          enc.numTemporalLayers = 1;
          enc.scaleResolutionDownBy = cfg.scaleResolutionDownBy;
          enc.priority = RTCPriorityType.high;
          enc.networkPriority = RTCPriorityType.high;
        }
      }
      params.degradationPreference = cfg.degradationPreference;
      await sender.setParameters(params);
    }
  } catch (_) {
    // Some platform builds may ignore individual RTP parameters; SDP hints
    // still ensure fast ramp-up and high bitrate.
  }
}

/// Reads a concise human-readable live video stats summary from WebRTC
/// (e.g. "59 fps • 1920x1080 • VP8 (libvpx) • 12ms").
Future<String?> readVideoStatsSummary(
  RTCPeerConnection pc, {
  required bool inbound,
}) async {
  try {
    final reports = await pc.getStats();
    Map<dynamic, dynamic>? rtpValues;
    final codecsById = <String, String>{};

    for (final report in reports) {
      final type = report.type;
      final values = report.values;
      if (type == 'codec') {
        final mime = values['mimeType']?.toString() ?? '';
        if (mime.toLowerCase().startsWith('video/')) {
          codecsById[report.id] = mime.substring(6).toUpperCase();
        }
      } else if ((inbound && type == 'inbound-rtp') ||
          (!inbound && type == 'outbound-rtp')) {
        final kind = (values['kind'] ?? values['mediaType'])?.toString();
        if (kind == 'video') {
          rtpValues = values;
        }
      }
    }

    if (rtpValues == null) return null;

    final fpsNum = rtpValues['framesPerSecond'] as num?;
    final wNum = rtpValues['frameWidth'] as num?;
    final hNum = rtpValues['frameHeight'] as num?;
    final codecId = rtpValues['codecId']?.toString();
    final codecName = codecId != null ? codecsById[codecId] : null;
    final impl = (inbound
            ? rtpValues['decoderImplementation']
            : rtpValues['encoderImplementation'])
        ?.toString();
    final jitterSec = rtpValues['jitter'] as num?;

    final parts = <String>[];
    if (fpsNum != null) parts.add('${fpsNum.round()} fps');
    if (wNum != null && hNum != null && wNum > 0 && hNum > 0) {
      parts.add('${wNum.round()}x${hNum.round()}');
    }
    if (codecName != null && codecName.isNotEmpty) {
      parts.add(impl != null && impl.isNotEmpty ? '$codecName ($impl)' : codecName);
    }
    if (jitterSec != null) {
      parts.add('jitter ${(jitterSec * 1000).round()}ms');
    }
    return parts.isEmpty ? null : parts.join(' • ');
  } catch (_) {
    return null;
  }
}
