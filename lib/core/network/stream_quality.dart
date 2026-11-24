import 'package:flutter_webrtc/flutter_webrtc.dart';

enum StreamQualityMode { performance, balanced, quality }

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
  StreamQualityConfig get config {
    switch (this) {
      case StreamQualityMode.performance:
        return const StreamQualityConfig(
          label: 'Performance',
          shortLabel: 'Perf',
          description: 'Lowest latency • 60 FPS',
          startBitrateKbps: 3000,
          minBitrateKbps: 1500,
          maxBitrateKbps: 6000,
          maxFramerate: 60,
          scaleResolutionDownBy: 1.5,
          degradationPreference: RTCDegradationPreference.MAINTAIN_FRAMERATE,
        );
      case StreamQualityMode.balanced:
        return const StreamQualityConfig(
          label: 'Balanced',
          shortLabel: 'Bal',
          description: 'Native res • 60 FPS',
          startBitrateKbps: 6000,
          minBitrateKbps: 3000,
          maxBitrateKbps: 12000,
          maxFramerate: 60,
          scaleResolutionDownBy: 1.0,
          degradationPreference: RTCDegradationPreference.MAINTAIN_RESOLUTION,
        );
      case StreamQualityMode.quality:
        return const StreamQualityConfig(
          label: 'Quality',
          shortLabel: 'HQ',
          description: 'Max sharpness • 25 Mbps',
          startBitrateKbps: 12000,
          minBitrateKbps: 6000,
          maxBitrateKbps: 25000,
          maxFramerate: 60,
          scaleResolutionDownBy: 1.0,
          degradationPreference: RTCDegradationPreference.MAINTAIN_RESOLUTION,
        );
    }
  }

  StreamQualityMode get next {
    switch (this) {
      case StreamQualityMode.performance:
        return StreamQualityMode.balanced;
      case StreamQualityMode.balanced:
        return StreamQualityMode.quality;
      case StreamQualityMode.quality:
        return StreamQualityMode.performance;
    }
  }
}

StreamQualityMode streamQualityModeFromName(String? name) {
  switch (name) {
    case 'performance':
      return StreamQualityMode.performance;
    case 'quality':
      return StreamQualityMode.quality;
    case 'balanced':
    default:
      return StreamQualityMode.balanced;
  }
}

/// Optimizes a WebRTC SDP string so local-network screen mirroring starts at
/// high bitrate immediately instead of ramping up slowly from ~300 kbps.
String optimizeVideoSdp(String sdp, StreamQualityMode mode) {
  try {
    final cfg = mode.config;
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

    // Collect payload types for video codecs (and identify H264 for HW accel).
    final videoCodecPts = <String>{};
    final h264Pts = <String>[];
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
            codec == 'VP8' ||
            codec == 'VP9' ||
            codec == 'AV1') {
          videoCodecPts.add(pt);
          if (codec == 'H264') {
            h264Pts.add(pt);
          }
        }
      }
    }

    // Prefer H264 first on the m=video line for hardware encode/decode.
    if (h264Pts.isNotEmpty) {
      final parts = lines[videoStart].split(' ');
      if (parts.length > 3) {
        final header = parts.sublist(0, 3);
        final payloadTypes = parts.sublist(3);
        final preferred = <String>[];
        final others = <String>[];
        for (final pt in payloadTypes) {
          if (h264Pts.contains(pt)) {
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

/// Applies bitrate, framerate, resolution scaling, and degradation preference
/// directly on active video RTCRtpSenders (works live without reconnecting).
Future<void> applyVideoSenderParameters(
  RTCPeerConnection pc,
  StreamQualityMode mode,
) async {
  try {
    final cfg = mode.config;
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
