import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/network/udp_server.dart';
import '../core/network/stylus_event.dart';
import '../core/network/webrtc_signaler.dart';
import '../core/network/stream_quality.dart';

class WindowsReceiverScreen extends StatefulWidget {
  const WindowsReceiverScreen({super.key});

  @override
  State<WindowsReceiverScreen> createState() => _WindowsReceiverScreenState();
}

class _WindowsReceiverScreenState extends State<WindowsReceiverScreen> {
  final UdpServer _server = UdpServer();
  static const MethodChannel _channel = MethodChannel('com.virtualstylus/pen');
  String _localIp = 'Loading...';

  // WebRTC
  bool _enableScreenMirroring = true;
  StreamQualityMode _qualityMode = StreamQualityMode.balanced;
  ManualStreamSettings _manualSettings = const ManualStreamSettings();
  VideoCodecPreference _videoCodec = VideoCodecPreference.auto;
  Map<VideoCodecPreference, CodecCapability> _codecCapabilities = {};
  Map<VideoCodecPreference, CodecCapability> _tabletCodecCapabilities = {};
  int _captureSourceHeight = 1080;
  String? _captureSourceId;
  int _currentCaptureFps = 0;
  String? _connectedIp;
  String? _liveStatsSummary;
  Timer? _statsTimer;
  WebRtcSignaler? _signaler;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  VideoCodecPreference get _effectiveCodec =>
      _videoCodec == VideoCodecPreference.auto
          ? resolveAutoCodec(_codecCapabilities, _tabletCodecCapabilities)
          : _videoCodec;

  StreamQualityConfig get _activeQualityConfig => _qualityMode.resolveConfig(
        manual: _manualSettings,
        sourceHeight: _captureSourceHeight,
      );

  int _detectScreenHeight() {
    try {
      final views = PlatformDispatcher.instance.views;
      if (views.isNotEmpty) {
        final h = views.first.display.size.height.round();
        if (h > 0) return h;
      }
    } catch (_) {}
    return _captureSourceHeight;
  }

  Future<MediaStream> _openDesktopStream(String sourceId, int fps) async {
    // flutter_webrtc's Windows FlutterScreenCapture::GetDisplayMedia reads:
    //   video.deviceId.exact      -> desktop source ID
    //   video.mandatory.frameRate -> capture FPS as a double (defaults to 30.0!)
    final mediaConstraints = <String, dynamic>{
      'audio': false,
      'video': {
        'deviceId': {'exact': sourceId},
        'mandatory': {
          'frameRate': fps.toDouble(),
        },
      },
    };
    return navigator.mediaDevices.getDisplayMedia(mediaConstraints);
  }

  Future<void> _restartCaptureForFps(int targetFps) async {
    if (_peerConnection == null || _captureSourceId == null) return;
    if (_currentCaptureFps == targetFps) return;
    try {
      final newStream = await _openDesktopStream(_captureSourceId!, targetFps);
      final newTracks = newStream.getVideoTracks();
      if (newTracks.isEmpty) {
        await newStream.dispose();
        return;
      }
      final newTrack = newTracks.first;
      final senders = await _peerConnection!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await sender.replaceTrack(newTrack);
        }
      }
      final oldStream = _localStream;
      _localStream = newStream;
      _currentCaptureFps = targetFps;
      oldStream?.getTracks().forEach((track) => track.stop());
      await oldStream?.dispose();
    } catch (e) {
      debugPrint('Failed to restart capture at $targetFps FPS: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _detectCodecCapabilities();
    _initServer();
    _startSignalingServer();
  }

  Future<void> _detectCodecCapabilities() async {
    Map<String, bool> hwMap = {};
    try {
      final raw = await _channel.invokeMethod('getHardwareEncoders');
      if (raw is Map) {
        for (final entry in raw.entries) {
          hwMap[entry.key.toString()] = entry.value == true;
        }
      }
    } catch (e) {
      debugPrint('Failed to query hardware encoders: $e');
    }

    final webrtcSupported = await probeWebRtcVideoCodecs();
    final caps = <VideoCodecPreference, CodecCapability>{};
    for (final codec in VideoCodecPreference.values) {
      if (codec == VideoCodecPreference.auto) continue;
      caps[codec] = CodecCapability(
        supported: webrtcSupported.contains(codec),
        hardware: hwMap[codec.name] == true,
      );
    }

    if (mounted) {
      setState(() {
        _codecCapabilities = caps;
      });
    } else {
      _codecCapabilities = caps;
    }

    if (_connectedIp != null) {
      _sendCodecCapabilitiesToPeer();
    }
  }

  void _sendCodecCapabilitiesToPeer() {
    if (_signaler == null || _codecCapabilities.isEmpty) return;
    final serialized = <String, dynamic>{};
    for (final entry in _codecCapabilities.entries) {
      serialized[entry.key.name] = entry.value.toMap();
    }
    _signaler?.sendMessage({
      'type': 'codec_capabilities',
      'codec': _videoCodec.name,
      'capabilities': serialized,
    });
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getString('streamQualityMode');
    final savedCodec = prefs.getString('videoCodecPreference');
    final savedHeight = prefs.getInt('manualTargetHeight') ?? 1080;
    final savedFps = prefs.getInt('manualFps') ?? 60;
    final savedMbps = prefs.getInt('manualMaxMbps') ?? 15;
    if (mounted) {
      setState(() {
        _qualityMode = streamQualityModeFromName(savedMode);
        _videoCodec = videoCodecPreferenceFromName(savedCodec);
        _manualSettings = ManualStreamSettings(
          targetHeight: savedHeight < 0 ? 0 : savedHeight,
          fps: savedFps.clamp(15, 120),
          maxMbps: savedMbps.clamp(2, 40),
        );
      });
    }
  }

  Future<void> _setVideoCodec(
    VideoCodecPreference codec, {
    bool notifyPeer = true,
  }) async {
    final changed = _videoCodec != codec;
    if (mounted) {
      setState(() {
        _videoCodec = codec;
      });
    } else {
      _videoCodec = codec;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('videoCodecPreference', codec.name);

    if (notifyPeer && _connectedIp != null) {
      _signaler?.sendMessage({
        'type': 'codec_mode',
        'codec': codec.name,
      });
    }

    // Codec changes require fresh SDP negotiation; cleanly restart WebRTC
    // when connected so the newly selected codec takes effect immediately.
    if (changed && _connectedIp != null && _enableScreenMirroring) {
      _closeWebRtc();
      await _setupWebRtcAndSendOffer();
    }
  }

  Future<void> _setQualityMode(
    StreamQualityMode mode, {
    ManualStreamSettings? manual,
    bool notifyPeer = true,
  }) async {
    final nextManual = manual ?? _manualSettings;
    if (mounted) {
      setState(() {
        _qualityMode = mode;
        _manualSettings = nextManual;
      });
    } else {
      _qualityMode = mode;
      _manualSettings = nextManual;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('streamQualityMode', mode.name);
    await prefs.setInt('manualTargetHeight', nextManual.targetHeight);
    await prefs.setInt('manualFps', nextManual.fps);
    await prefs.setInt('manualMaxMbps', nextManual.maxMbps);

    if (_peerConnection != null) {
      final cfg = _activeQualityConfig;
      if (cfg.maxFramerate != _currentCaptureFps) {
        await _restartCaptureForFps(cfg.maxFramerate);
      }
      await applyVideoSenderParameters(_peerConnection!, cfg);
    }

    if (notifyPeer && _connectedIp != null) {
      _signaler?.sendMessage({
        'type': 'quality_mode',
        'mode': mode.name,
        'manual': nextManual.toMap(),
      });
    }
  }

  Future<void> _initServer() async {
    try {
      final interfaces = await NetworkInterface.list();
      String? ip;
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            ip = addr.address;
            break;
          }
        }
        if (ip != null) break;
      }
      setState(() {
        _localIp = ip ?? 'Could not determine IP';
      });

      await _server.start();
      _server.events.listen((event) {
        _injectEvent(event);
      });
    } catch (e) {
      setState(() {
        _localIp = 'Error: $e';
      });
    }
  }

  Future<void> _injectEvent(StylusEvent event) async {
    try {
      await _channel.invokeMethod('injectPenEvent', {
        'action': event.action.index,
        'kind': event.kind.index,
        'x': event.x,
        'y': event.y,
        'pressure': event.pressure,
        'pointerId': event.pointerId,
        'activeTouchMask': event.activeTouchMask,
        'sequence': event.sequence,
      });
    } catch (e) {
      debugPrint("Failed to inject event: $e");
    }
  }

  Future<void> _clearTouches() async {
    try {
      await _channel.invokeMethod('clearTouches');
    } catch (e) {
      debugPrint("Failed to clear touches: $e");
    }
  }

  void _toggleScreenMirroring(bool value) {
    setState(() {
      _enableScreenMirroring = value;
    });

    if (value) {
      _startSignalingServer();
    } else {
      _stopSignalingServer();
    }
  }

  Future<void> _startSignalingServer() async {
    _signaler = WebRtcSignaler(
      port: 4001,
      onConnect: (ip) {
        _clearTouches();
        setState(() {
          _connectedIp = ip;
        });
        _server.lockedIp = ip;
        _sendCodecCapabilitiesToPeer();
        _setupWebRtcAndSendOffer();
      },
      onDisconnect: () {
        _clearTouches();
        setState(() {
          _connectedIp = null;
          _tabletCodecCapabilities = {};
          _liveStatsSummary = null;
        });
        _server.lockedIp = null;
        _closeWebRtc();
      },
      onMessage: _handleSignalingMessage,
    );
    await _signaler!.startServer();
  }

  void _stopSignalingServer() {
    _signaler?.stop();
    _signaler = null;
    _closeWebRtc();
  }

  Future<void> _setupWebRtcAndSendOffer() async {
    _isRemoteSet = false;
    _remoteCandidates.clear();
    
    final configuration = {
      "iceServers": [], // P2P local network, no stun needed
      "sdpSemantics": "unified-plan",
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection!.onIceCandidate = (candidate) {
      _signaler?.sendMessage({
        'type': 'candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    // Get screen stream
    try {
      _captureSourceHeight = _detectScreenHeight();
      final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
      if (sources.isNotEmpty) {
        final source = sources.first; // primary monitor
        _captureSourceId = source.id;
        final cfg = _activeQualityConfig;
        _localStream = await _openDesktopStream(source.id, cfg.maxFramerate);
        _currentCaptureFps = cfg.maxFramerate;

        for (final track in _localStream!.getTracks()) {
          await _peerConnection!.addTrack(track, _localStream!);
        }

        final resolvedCfg = _activeQualityConfig;
        await applyVideoSenderParameters(_peerConnection!, resolvedCfg);

        final RTCSessionDescription rawOffer = await _peerConnection!.createOffer();
        final optimizedSdp = optimizeVideoSdp(
          rawOffer.sdp ?? '',
          resolvedCfg,
          codecPreference: _effectiveCodec,
        );
        final offer = RTCSessionDescription(optimizedSdp, rawOffer.type);
        await _peerConnection!.setLocalDescription(offer);

        _signaler?.sendMessage({
          'type': 'offer',
          'sdp': offer.sdp,
        });
      }
    } catch (e) {
      debugPrint("Error capturing screen: $e");
    }
  }

  List<RTCIceCandidate> _remoteCandidates = [];
  bool _isRemoteSet = false;

  void _startStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final pc = _peerConnection;
      if (pc == null) return;
      final summary = await readVideoStatsSummary(pc, inbound: false);
      if (mounted && summary != null) {
        setState(() => _liveStatsSummary = summary);
      }
    });
  }

  void _handleSignalingMessage(Map<String, dynamic> message) async {
    final type = message['type'];
    if (type == 'quality_mode') {
      final mode = streamQualityModeFromName(message['mode'] as String?);
      final manualMap = message['manual'] is Map
          ? Map<String, dynamic>.from(message['manual'] as Map)
          : null;
      await _setQualityMode(
        mode,
        manual: manualMap != null ? ManualStreamSettings.fromMap(manualMap) : null,
        notifyPeer: false,
      );
      return;
    }
    if (type == 'codec_mode') {
      final codec = videoCodecPreferenceFromName(message['codec'] as String?);
      await _setVideoCodec(codec, notifyPeer: false);
      return;
    }
    if (type == 'tablet_codec_capabilities') {
      final rawCaps = message['capabilities'];
      final parsed = <VideoCodecPreference, CodecCapability>{};
      if (rawCaps is Map) {
        for (final entry in rawCaps.entries) {
          final pref = videoCodecPreferenceFromName(entry.key.toString());
          if (pref == VideoCodecPreference.auto) continue;
          if (entry.value is Map) {
            parsed[pref] = CodecCapability.fromMap(entry.value as Map);
          }
        }
      }
      if (mounted) {
        setState(() {
          _tabletCodecCapabilities = parsed;
        });
      } else {
        _tabletCodecCapabilities = parsed;
      }
      return;
    }

    if (_peerConnection == null) return;

    if (type == 'answer') {
      final resolvedCfg = _activeQualityConfig;
      final optimizedAnswerSdp = optimizeVideoSdp(
        (message['sdp'] as String?) ?? '',
        resolvedCfg,
        codecPreference: _effectiveCodec,
      );
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(optimizedAnswerSdp, type),
      );
      _isRemoteSet = true;
      for (var cand in _remoteCandidates) {
        await _peerConnection!.addCandidate(cand);
      }
      _remoteCandidates.clear();
      // Ensure capture FPS matches the latest synced mode (handles race when
      // Android sends quality_mode while initial offer is still being created).
      if (_activeQualityConfig.maxFramerate != _currentCaptureFps) {
        await _restartCaptureForFps(_activeQualityConfig.maxFramerate);
      }
      await applyVideoSenderParameters(_peerConnection!, _activeQualityConfig);
      _startStatsPolling();
    } else if (type == 'candidate') {
      final cand = RTCIceCandidate(message['candidate'], message['sdpMid'], message['sdpMLineIndex']);
      if (_isRemoteSet) {
        await _peerConnection!.addCandidate(cand);
      } else {
        _remoteCandidates.add(cand);
      }
    }
  }

  void _closeWebRtc() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;
    _currentCaptureFps = 0;
    _peerConnection?.close();
    _peerConnection = null;
  }

  @override
  void dispose() {
    _clearTouches();
    _stopSignalingServer();
    _server.stop();
    super.dispose();
  }

  Widget _buildGlassCard({required Widget child, EdgeInsetsGeometry? padding}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: padding ?? const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 30, offset: const Offset(0, 10))
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F172A), Color(0xFF1E1B4B), Color(0xFF000000)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildGlassCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.blueAccent.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.wifi_tethering, size: 64, color: Colors.blueAccent),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'VirtualStylus',
                        style: TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800, letterSpacing: 1.2),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _connectedIp != null ? 'Client is connected securely.' : 'Server is running and ready to connect',
                        style: TextStyle(color: _connectedIp != null ? Colors.greenAccent : Colors.white60, fontSize: 16),
                      ),
                      const SizedBox(height: 32),
                      
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        decoration: BoxDecoration(
                          color: _connectedIp != null ? Colors.green.withOpacity(0.2) : Colors.black.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: _connectedIp != null ? Colors.green.withOpacity(0.5) : Colors.blueAccent.withOpacity(0.3), width: 1),
                        ),
                        child: Column(
                          children: [
                            Text(
                              _connectedIp != null ? 'CONNECTED DEVICE IP' : 'LOCAL IP ADDRESS', 
                              style: TextStyle(
                                color: _connectedIp != null ? Colors.greenAccent : Colors.blueAccent, 
                                fontSize: 12, 
                                fontWeight: FontWeight.bold, 
                                letterSpacing: 2
                              )
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _connectedIp ?? _localIp,
                              style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w300, letterSpacing: 3),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),

                      if (_connectedIp == null && _localIp.contains('.'))
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(color: Colors.blueAccent.withOpacity(0.2), blurRadius: 20, spreadRadius: 5)
                            ],
                          ),
                          child: QrImageView(
                            data: _localIp,
                            version: QrVersions.auto,
                            size: 180.0,
                            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black87),
                            dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Colors.black87),
                          ),
                        ),
                      
                      if (_connectedIp != null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40.0),
                          child: Icon(Icons.check_circle_outline, size: 100, color: Colors.greenAccent),
                        ),

                      const SizedBox(height: 32),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: _enableScreenMirroring,
                            onChanged: _toggleScreenMirroring,
                            activeColor: Colors.blueAccent,
                            activeTrackColor: Colors.blueAccent.withOpacity(0.3),
                            inactiveThumbColor: Colors.white54,
                            inactiveTrackColor: Colors.black45,
                          ),
                          const SizedBox(width: 12),
                          const Text(
                            'Screen Mirroring (WebRTC)',
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                      if (_enableScreenMirroring) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.35),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white.withOpacity(0.08)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: StreamQualityMode.values.map((mode) {
                              final selected = _qualityMode == mode;
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 2),
                                child: InkWell(
                                  onTap: () => _setQualityMode(mode),
                                  borderRadius: BorderRadius.circular(10),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 160),
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: selected ? Colors.blueAccent : Colors.transparent,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      mode.config.label,
                                      style: TextStyle(
                                        color: selected ? Colors.white : Colors.white60,
                                        fontSize: 13,
                                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _activeQualityConfig.description,
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        if (_qualityMode == StreamQualityMode.manual) ...[
                          const SizedBox(height: 14),
                          Container(
                            width: 360,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.white.withOpacity(0.08)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Resolution',
                                  style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: kManualResolutionHeights.map((h) {
                                    final selected = _manualSettings.targetHeight == h;
                                    final label = h == 0 ? 'Native' : '${h}p';
                                    return ChoiceChip(
                                      label: Text(label, style: const TextStyle(fontSize: 12)),
                                      selected: selected,
                                      selectedColor: Colors.blueAccent,
                                      backgroundColor: Colors.white.withOpacity(0.08),
                                      labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
                                      side: BorderSide.none,
                                      visualDensity: VisualDensity.compact,
                                      onSelected: (_) => _setQualityMode(
                                        StreamQualityMode.manual,
                                        manual: _manualSettings.copyWith(targetHeight: h),
                                      ),
                                    );
                                  }).toList(),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'FPS',
                                  style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: kManualFpsOptions.map((fps) {
                                    final selected = _manualSettings.fps == fps;
                                    return ChoiceChip(
                                      label: Text('$fps', style: const TextStyle(fontSize: 12)),
                                      selected: selected,
                                      selectedColor: Colors.blueAccent,
                                      backgroundColor: Colors.white.withOpacity(0.08),
                                      labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
                                      side: BorderSide.none,
                                      visualDensity: VisualDensity.compact,
                                      onSelected: (_) => _setQualityMode(
                                        StreamQualityMode.manual,
                                        manual: _manualSettings.copyWith(fps: fps),
                                      ),
                                    );
                                  }).toList(),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Bitrate',
                                      style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                                    ),
                                    Text(
                                      '${_manualSettings.maxMbps} Mbps',
                                      style: const TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                Slider(
                                  value: _manualSettings.maxMbps.toDouble().clamp(2.0, 40.0),
                                  min: 2,
                                  max: 40,
                                  divisions: 38,
                                  activeColor: Colors.blueAccent,
                                  inactiveColor: Colors.white24,
                                  onChanged: (val) => _setQualityMode(
                                    StreamQualityMode.manual,
                                    manual: _manualSettings.copyWith(maxMbps: val.round()),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        const Text(
                          'Video Codec (PC Enc • Tablet Dec)',
                          style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          alignment: WrapAlignment.center,
                          children: VideoCodecPreference.values.map((codec) {
                            final selected = _videoCodec == codec;
                            final pcCap = _codecCapabilities[codec];
                            final tabCap = _tabletCodecCapabilities[codec];
                            final isAuto = codec == VideoCodecPreference.auto;
                            final pcSupported = isAuto || (pcCap?.supported ?? true);
                            final tabSupported = isAuto || (tabCap?.supported ?? true);
                            final supported = pcSupported && tabSupported;
                            final bothHw = !isAuto &&
                                (pcCap?.supported == true && pcCap?.hardware == true) &&
                                (tabCap?.supported == true && tabCap?.hardware == true);

                            Widget buildSideBadge(String prefix, CodecCapability? cap) {
                              final text = cap == null ? '$prefix:...' : '$prefix:${cap.badge}';
                              final color = cap == null
                                  ? Colors.white38
                                  : (!cap.supported
                                      ? Colors.white24
                                      : (cap.hardware ? Colors.greenAccent : Colors.amberAccent));
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? Colors.black.withOpacity(0.25)
                                      : color.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  text,
                                  style: TextStyle(
                                    color: selected ? Colors.white : color,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                            }

                            return InkWell(
                              onTap: supported ? () => _setVideoCodec(codec) : null,
                              borderRadius: BorderRadius.circular(10),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? Colors.blueAccent
                                      : Colors.black.withOpacity(supported ? 0.35 : 0.18),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: selected
                                        ? Colors.blueAccent
                                        : (bothHw
                                            ? Colors.greenAccent.withOpacity(0.55)
                                            : Colors.white.withOpacity(supported ? 0.1 : 0.04)),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      codec.label,
                                      style: TextStyle(
                                        color: !supported
                                            ? Colors.white30
                                            : (selected ? Colors.white : Colors.white70),
                                        fontSize: 12,
                                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                      ),
                                    ),
                                    if (!isAuto) ...[
                                      const SizedBox(width: 5),
                                      buildSideBadge('PC', pcCap),
                                      if (_tabletCodecCapabilities.isNotEmpty) ...[
                                        const SizedBox(width: 3),
                                        buildSideBadge('Tab', tabCap),
                                      ],
                                    ],
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        if (_liveStatsSummary != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            _liveStatsSummary!,
                            style: const TextStyle(color: Colors.greenAccent, fontSize: 11),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                const Text(
                  'Listening on UDP 4000 • TCP 4001',
                  style: TextStyle(color: Colors.white30, fontSize: 12, letterSpacing: 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
