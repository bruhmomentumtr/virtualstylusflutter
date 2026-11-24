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
  int _captureSourceHeight = 1080;
  String? _connectedIp;
  WebRtcSignaler? _signaler;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  StreamQualityConfig get _activeQualityConfig => _qualityMode.resolveConfig(
        manual: _manualSettings,
        sourceHeight: _captureSourceHeight,
      );

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _initServer();
    _startSignalingServer();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getString('streamQualityMode');
    final savedHeight = prefs.getInt('manualTargetHeight') ?? 1080;
    final savedFps = prefs.getInt('manualFps') ?? 60;
    final savedMbps = prefs.getInt('manualMaxMbps') ?? 15;
    if (mounted) {
      setState(() {
        _qualityMode = streamQualityModeFromName(savedMode);
        _manualSettings = ManualStreamSettings(
          targetHeight: savedHeight < 0 ? 0 : savedHeight,
          fps: savedFps.clamp(15, 120),
          maxMbps: savedMbps.clamp(2, 40),
        );
      });
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
      await applyVideoSenderParameters(_peerConnection!, _activeQualityConfig);
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
        _setupWebRtcAndSendOffer();
      },
      onDisconnect: () {
        _clearTouches();
        setState(() {
          _connectedIp = null;
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
      "iceServers": [] // P2P local network, no stun needed
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
      final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
      if (sources.isNotEmpty) {
        final source = sources.first; // primary monitor
        final cfg = _activeQualityConfig;
        final mediaConstraints = <String, dynamic>{
          'audio': false,
          'video': {
            'mandatory': {
              'chromeMediaSource': 'desktop',
              'chromeMediaSourceId': source.id,
              'maxFrameRate': cfg.maxFramerate,
            },
            'frameRate': {
              'ideal': cfg.maxFramerate,
              'max': cfg.maxFramerate,
            },
          }
        };
        _localStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);

        final videoTracks = _localStream!.getVideoTracks();
        if (videoTracks.isNotEmpty) {
          final settings = videoTracks.first.getSettings();
          final h = (settings['height'] as num?)?.toInt();
          if (h != null && h > 0) {
            _captureSourceHeight = h;
          }
        }

        for (final track in _localStream!.getTracks()) {
          await _peerConnection!.addTrack(track, _localStream!);
        }

        final resolvedCfg = _activeQualityConfig;
        await applyVideoSenderParameters(_peerConnection!, resolvedCfg);

        final RTCSessionDescription rawOffer = await _peerConnection!.createOffer();
        final optimizedSdp = optimizeVideoSdp(rawOffer.sdp ?? '', resolvedCfg);
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

    if (_peerConnection == null) return;

    if (type == 'answer') {
      final resolvedCfg = _activeQualityConfig;
      final optimizedAnswerSdp = optimizeVideoSdp(
        (message['sdp'] as String?) ?? '',
        resolvedCfg,
      );
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(optimizedAnswerSdp, type),
      );
      _isRemoteSet = true;
      for (var cand in _remoteCandidates) {
        await _peerConnection!.addCandidate(cand);
      }
      _remoteCandidates.clear();
      await applyVideoSenderParameters(_peerConnection!, resolvedCfg);
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
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;
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
