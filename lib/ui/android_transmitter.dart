import 'dart:async';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/network/udp_client.dart';
import '../core/network/stylus_event.dart';
import '../core/network/webrtc_signaler.dart';
import '../core/network/stream_quality.dart';

class ShortcutItem {
  final String label;
  final IconData icon;
  final int vkCode;
  final int modifiers;

  ShortcutItem({
    required this.label,
    required this.icon,
    required this.vkCode,
    required this.modifiers,
  });

  Map<String, dynamic> toMap() => {
        'label': label,
        'icon': icon.codePoint,
        'vkCode': vkCode,
        'modifiers': modifiers,
      };

  factory ShortcutItem.fromMap(Map<String, dynamic> map) {
    int code = map['icon'];
    IconData iconData = Icons.keyboard;
    if (code == Icons.undo.codePoint) iconData = Icons.undo;
    if (code == Icons.redo.codePoint) iconData = Icons.redo;

    return ShortcutItem(
      label: map['label'],
      icon: iconData,
      vkCode: map['vkCode'],
      modifiers: map['modifiers'],
    );
  }
}

class AndroidTransmitterScreen extends StatefulWidget {
  const AndroidTransmitterScreen({super.key});

  @override
  State<AndroidTransmitterScreen> createState() => _AndroidTransmitterScreenState();
}

class _AndroidTransmitterScreenState extends State<AndroidTransmitterScreen> {
  final TextEditingController _ipController = TextEditingController();
  UdpClient? _client;
  bool _isConnected = false;
  bool _isScanning = false;

  bool _shortcutsOnLeft = true;
  List<ShortcutItem> _shortcuts = [
    ShortcutItem(label: 'Undo', icon: Icons.undo, vkCode: 90, modifiers: 1), // Z + Ctrl
    ShortcutItem(label: 'Redo', icon: Icons.redo, vkCode: 89, modifiers: 1), // Y + Ctrl
  ];

  // Multi-touch slot management (1..16) to prevent modulo collisions and
  // synchronize active finger bitmask across UDP packets.
  static const int _maxTouchContacts = 16;
  final Map<int, int> _activeTouchSlots = <int, int>{};
  int _touchSequence = 0;

  // Video Streaming (Native MediaCodec HW primary, WebRTC fallback)
  static const MethodChannel _deviceChannel = MethodChannel('com.virtualstylus/device');
  bool _mirrorScreen = true;
  bool _usingNativeHwStream = false;
  int? _nativeTextureId;
  int _nativeVideoWidth = 0;
  int _nativeVideoHeight = 0;
  String? _connectedHostIp;
  StreamQualityMode _qualityMode = StreamQualityMode.balanced;
  ManualStreamSettings _manualSettings = const ManualStreamSettings();
  VideoCodecPreference _videoCodec = VideoCodecPreference.auto;
  Map<VideoCodecPreference, CodecCapability> _pcCodecCapabilities = {};
  Map<VideoCodecPreference, CodecCapability> _tabletCodecCapabilities = {};
  WebRtcSignaler? _signaler;
  RTCPeerConnection? _peerConnection;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  StreamQualityConfig get _activeQualityConfig =>
      _qualityMode.resolveConfig(manual: _manualSettings);

  VideoCodecPreference get _effectiveCodec =>
      _videoCodec == VideoCodecPreference.auto
          ? resolveAutoCodec(_pcCodecCapabilities, _tabletCodecCapabilities)
          : _videoCodec;

  int? _allocateTouchSlot(int flutterPointer) {
    final existing = _activeTouchSlots[flutterPointer];
    if (existing != null) return existing;
    final usedSlots = _activeTouchSlots.values.toSet();
    for (int slot = 1; slot <= _maxTouchContacts; slot++) {
      if (!usedSlots.contains(slot)) {
        _activeTouchSlots[flutterPointer] = slot;
        return slot;
      }
    }
    return null;
  }

  int _computeActiveTouchMask() {
    int mask = 0;
    for (final slot in _activeTouchSlots.values) {
      if (slot >= 1 && slot <= _maxTouchContacts) {
        mask |= 1 << (slot - 1);
      }
    }
    return mask;
  }

  int _nextTouchSequence() {
    _touchSequence = (_touchSequence + 1) & 0xFFFF;
    return _touchSequence;
  }

  @override
  void initState() {
    super.initState();
    _deviceChannel.setMethodCallHandler((call) async {
      if (call.method == 'onNativeVideoDimensions') {
        final args = call.arguments;
        if (args is Map && mounted) {
          final w = (args['width'] as num?)?.toInt() ?? 0;
          final h = (args['height'] as num?)?.toInt() ?? 0;
          if (w > 0 && h > 0) {
            setState(() {
              _nativeVideoWidth = w;
              _nativeVideoHeight = h;
            });
          }
        }
      }
    });
    _loadPrefs();
    _detectTabletCodecCapabilities();
    _remoteRenderer.initialize();
  }

  Future<void> _startNativeVideo(int port) async {
    final hostIp = _connectedHostIp;
    if (!_mirrorScreen || hostIp == null || hostIp.isEmpty) return;
    try {
      final texId = await _deviceChannel.invokeMethod<int>('startNativeVideo', {
        'hostIp': hostIp,
        'port': port,
      });
      if (mounted && texId != null && texId >= 0) {
        setState(() {
          _nativeTextureId = texId;
          _usingNativeHwStream = true;
        });
      }
    } catch (e) {
      debugPrint('Failed to start native HW video: $e');
    }
  }

  Future<void> _stopNativeVideo() async {
    try {
      await _deviceChannel.invokeMethod('stopNativeVideo');
    } catch (_) {}
    if (mounted) {
      setState(() {
        _usingNativeHwStream = false;
        _nativeTextureId = null;
        _nativeVideoWidth = 0;
        _nativeVideoHeight = 0;
      });
    } else {
      _usingNativeHwStream = false;
      _nativeTextureId = null;
      _nativeVideoWidth = 0;
      _nativeVideoHeight = 0;
    }
  }

  Future<void> _detectTabletCodecCapabilities() async {
    Map<String, bool> hwMap = {};
    try {
      final raw = await _deviceChannel.invokeMethod('getHardwareDecoders');
      if (raw is Map) {
        for (final entry in raw.entries) {
          hwMap[entry.key.toString()] = entry.value == true;
        }
      }
    } catch (e) {
      debugPrint('Failed to query tablet hardware decoders: $e');
    }

    final webrtcSupported = await probeWebRtcVideoCodecs();
    final caps = <VideoCodecPreference, CodecCapability>{};
    for (final codec in VideoCodecPreference.values) {
      if (codec == VideoCodecPreference.auto) continue;
      final isHw = hwMap[codec.name] == true;
      // Native MediaCodec player supports H264 and H265 (HEVC) directly in HW.
      final nativeHwSupported = isHw &&
          (codec == VideoCodecPreference.h264 ||
              codec == VideoCodecPreference.h265);
      caps[codec] = CodecCapability(
        supported: webrtcSupported.contains(codec) || nativeHwSupported,
        hardware: isHw,
      );
    }

    if (mounted) {
      setState(() {
        _tabletCodecCapabilities = caps;
      });
    } else {
      _tabletCodecCapabilities = caps;
    }

    _sendTabletCodecCapabilitiesToPeer();
  }

  void _sendTabletCodecCapabilitiesToPeer() {
    if (_signaler == null || _tabletCodecCapabilities.isEmpty) return;
    final serialized = <String, dynamic>{};
    for (final entry in _tabletCodecCapabilities.entries) {
      serialized[entry.key.name] = entry.value.toMap();
    }
    _signaler?.sendMessage({
      'type': 'tablet_codec_capabilities',
      'capabilities': serialized,
    });
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedHeight = prefs.getInt('manualTargetHeight') ?? 1080;
    final savedFps = prefs.getInt('manualFps') ?? 60;
    final savedMbps = prefs.getInt('manualMaxMbps') ?? 15;
    setState(() {
      _shortcutsOnLeft = prefs.getBool('shortcutsOnLeft') ?? true;
      _mirrorScreen = prefs.getBool('mirrorScreen') ?? true;
      _qualityMode = streamQualityModeFromName(prefs.getString('streamQualityMode'));
      _videoCodec = videoCodecPreferenceFromName(prefs.getString('videoCodecPreference'));
      _manualSettings = ManualStreamSettings(
        targetHeight: savedHeight < 0 ? 0 : savedHeight,
        fps: savedFps.clamp(15, 120),
        maxMbps: savedMbps.clamp(2, 40),
      );
      final savedShortcuts = prefs.getString('shortcuts');
      if (savedShortcuts != null) {
        final List decoded = jsonDecode(savedShortcuts);
        _shortcuts = decoded.map((e) => ShortcutItem.fromMap(e)).toList();
      }
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('shortcutsOnLeft', _shortcutsOnLeft);
    await prefs.setBool('mirrorScreen', _mirrorScreen);
    await prefs.setString('streamQualityMode', _qualityMode.name);
    await prefs.setString('videoCodecPreference', _videoCodec.name);
    await prefs.setInt('manualTargetHeight', _manualSettings.targetHeight);
    await prefs.setInt('manualFps', _manualSettings.fps);
    await prefs.setInt('manualMaxMbps', _manualSettings.maxMbps);
    final encoded = jsonEncode(_shortcuts.map((e) => e.toMap()).toList());
    await prefs.setString('shortcuts', encoded);
  }

  void _setVideoCodec(VideoCodecPreference codec, {bool notifyPeer = true}) {
    setState(() {
      _videoCodec = codec;
    });
    _savePrefs();
    if (notifyPeer) {
      _signaler?.sendMessage({
        'type': 'codec_mode',
        'codec': codec.name,
      });
    }
  }

  void _setQualityMode(
    StreamQualityMode mode, {
    ManualStreamSettings? manual,
    bool notifyPeer = true,
  }) {
    final nextManual = manual ?? _manualSettings;
    setState(() {
      _qualityMode = mode;
      _manualSettings = nextManual;
    });
    _savePrefs();
    if (notifyPeer) {
      _signaler?.sendMessage({
        'type': 'quality_mode',
        'mode': mode.name,
        'manual': nextManual.toMap(),
      });
    }
  }

  void _connect([String? ipAddr]) async {
    final ip = ipAddr ?? _ipController.text.trim();
    if (ip.isEmpty) return;

    _activeTouchSlots.clear();
    _touchSequence = 0;
    _connectedHostIp = ip;

    // Connect UDP for Stylus Data
    _client?.dispose();
    _client = UdpClient(targetIp: ip);
    await _client?.connect();

    setState(() {
      _isConnected = true;
      _isScanning = false;
    });

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Connect TCP for Handshake and WebRTC
    _startWebRtcSignaling(ip);
  }

  Future<void> _startWebRtcSignaling(String targetIp) async {
    _signaler = WebRtcSignaler(
      port: 4001,
      onConnect: (_) {
        _signaler?.sendMessage({
          'type': 'quality_mode',
          'mode': _qualityMode.name,
          'manual': _manualSettings.toMap(),
        });
        _sendTabletCodecCapabilitiesToPeer();
      },
      onMessage: _handleSignalingMessage,
      onDisconnect: _closeWebRtc,
    );
    await _signaler!.connect(targetIp);
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
      _setQualityMode(
        mode,
        manual: manualMap != null ? ManualStreamSettings.fromMap(manualMap) : null,
        notifyPeer: false,
      );
      return;
    }

    if (type == 'codec_mode') {
      final codec = videoCodecPreferenceFromName(message['codec'] as String?);
      _setVideoCodec(codec, notifyPeer: false);
      return;
    }

    if (type == 'stream_mode') {
      final mode = message['mode'] as String?;
      if (mode == 'native_hw') {
        final port = (message['port'] as num?)?.toInt() ?? 4002;
        await _peerConnection?.close();
        _peerConnection = null;
        _remoteRenderer.srcObject = null;
        await _startNativeVideo(port);
      } else {
        await _stopNativeVideo();
      }
      return;
    }

    if (type == 'codec_capabilities') {
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
      final pcCodec = message['codec'] as String?;
      setState(() {
        _pcCodecCapabilities = parsed;
        if (pcCodec != null) {
          _videoCodec = videoCodecPreferenceFromName(pcCodec);
        }
      });
      return;
    }

    if (type == 'offer') {
      if (_peerConnection != null) {
        await _peerConnection!.close();
        _peerConnection = null;
      }
      _isRemoteSet = false;
      _remoteCandidates.clear();

      final configuration = {
        "iceServers": [],
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

      _peerConnection!.onAddStream = (stream) {
        if (_mirrorScreen) {
          _remoteRenderer.srcObject = stream;
          setState(() {}); // trigger rebuild to show video
        }
      };

      _peerConnection!.onTrack = (event) {
        if (_mirrorScreen && event.track.kind == 'video') {
          _remoteRenderer.srcObject = event.streams[0];
          setState(() {});
        }
      };

      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(message['sdp'], type),
      );

      _isRemoteSet = true;
      for (var cand in _remoteCandidates) {
        await _peerConnection!.addCandidate(cand);
      }
      _remoteCandidates.clear();

      final rawAnswer = await _peerConnection!.createAnswer();
      final optimizedSdp = optimizeVideoSdp(
        rawAnswer.sdp ?? '',
        _activeQualityConfig,
        codecPreference: _effectiveCodec,
      );
      final answer = RTCSessionDescription(optimizedSdp, rawAnswer.type);
      await _peerConnection!.setLocalDescription(answer);

      _signaler?.sendMessage({
        'type': 'answer',
        'sdp': answer.sdp,
      });

    } else if (type == 'candidate') {
      final cand = RTCIceCandidate(message['candidate'], message['sdpMid'], message['sdpMLineIndex']);
      if (_isRemoteSet && _peerConnection != null) {
        await _peerConnection!.addCandidate(cand);
      } else {
        _remoteCandidates.add(cand);
      }
    }
  }

  void _closeWebRtc() {
    _stopNativeVideo();
    _peerConnection?.close();
    _peerConnection = null;
    _signaler?.stop();
    _signaler = null;
    _remoteRenderer.srcObject = null;
  }

  void _disconnect() {
    if (_client != null && _activeTouchSlots.isNotEmpty) {
      final activeSlots = _activeTouchSlots.values.toList();
      _activeTouchSlots.clear();
      for (final slot in activeSlots) {
        final cancelEvent = StylusEvent(
          action: EventAction.cancel,
          kind: PointerKind.touch,
          x: 0.0,
          y: 0.0,
          pressure: 0.0,
          pointerId: slot,
          activeTouchMask: 0,
          sequence: _nextTouchSequence(),
        );
        _client!.sendEvent(cancelEvent);
      }
    }
    _activeTouchSlots.clear();
    _touchSequence = 0;
    _client?.dispose();
    _closeWebRtc();
    setState(() {
      _isConnected = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _handlePointerEvent(PointerEvent event, BoxConstraints constraints) {
    if (_client == null) return;

    double videoWidth = 16.0;
    double videoHeight = 9.0;
    if (_usingNativeHwStream &&
        _nativeVideoWidth > 0 &&
        _nativeVideoHeight > 0) {
      videoWidth = _nativeVideoWidth.toDouble();
      videoHeight = _nativeVideoHeight.toDouble();
    } else if (_remoteRenderer.value.width > 0 &&
        _remoteRenderer.value.height > 0) {
      videoWidth = _remoteRenderer.value.width.toDouble();
      videoHeight = _remoteRenderer.value.height.toDouble();
    }

    final screenWidth = constraints.maxWidth;
    final screenHeight = constraints.maxHeight;

    final videoRatio = videoWidth / videoHeight;
    final screenRatio = screenWidth / screenHeight;

    double drawnWidth;
    double drawnHeight;

    if (videoRatio > screenRatio) {
      drawnWidth = screenWidth;
      drawnHeight = screenWidth / videoRatio;
    } else {
      drawnHeight = screenHeight;
      drawnWidth = screenHeight * videoRatio;
    }

    final xOffset = (screenWidth - drawnWidth) / 2.0;
    final yOffset = (screenHeight - drawnHeight) / 2.0;

    final x = ((event.localPosition.dx - xOffset) / drawnWidth).clamp(0.0, 1.0);
    final y = ((event.localPosition.dy - yOffset) / drawnHeight).clamp(0.0, 1.0);

    EventAction action = EventAction.move;
    if (event is PointerDownEvent) {
      action = EventAction.down;
    } else if (event is PointerUpEvent) {
      action = EventAction.up;
    } else if (event is PointerCancelEvent) {
      action = EventAction.cancel;
    } else if (event is PointerHoverEvent) {
      action = EventAction.hover;
    }

    PointerKind kind = PointerKind.touch;
    if (event.kind == PointerDeviceKind.stylus) kind = PointerKind.stylus;
    if (event.kind == PointerDeviceKind.invertedStylus) kind = PointerKind.invertedStylus;
    if (event.kind == PointerDeviceKind.mouse) kind = PointerKind.mouse;

    int pointerId = 1;
    int activeMask = _computeActiveTouchMask();
    int sequence = -1;

    if (kind == PointerKind.touch) {
      if (action == EventAction.hover) return;

      int? slot;
      if (action == EventAction.down) {
        slot = _allocateTouchSlot(event.pointer);
      } else if (action == EventAction.move) {
        slot = _activeTouchSlots[event.pointer] ?? _allocateTouchSlot(event.pointer);
      } else if (action == EventAction.up || action == EventAction.cancel) {
        slot = _activeTouchSlots.remove(event.pointer);
      }

      if (slot == null) return;
      pointerId = slot;
      activeMask = _computeActiveTouchMask();
      sequence = _nextTouchSequence();
    }

    final stylusEvent = StylusEvent(
      action: action,
      kind: kind,
      x: x,
      y: y,
      pressure: event.pressure,
      pointerId: pointerId,
      activeTouchMask: activeMask,
      sequence: sequence,
    );

    _client!.sendEvent(stylusEvent);

    // When lifting the last active finger, send one redundant copy so a single
    // dropped UDP packet cannot leave a stuck touch contact on Windows.
    if (kind == PointerKind.touch &&
        (action == EventAction.up || action == EventAction.cancel) &&
        activeMask == 0) {
      _client!.sendEvent(stylusEvent);
    }
  }

  void _sendShortcut(ShortcutItem item) {
    if (_client == null) return;

    final shortcutEvent = StylusEvent(
      action: EventAction.shortcut,
      kind: PointerKind.touch,
      x: item.vkCode.toDouble(),
      y: item.modifiers.toDouble(),
      pressure: 0.0,
    );
    _client!.sendEvent(shortcutEvent);
  }

  Widget _buildManualControls({
    required ManualStreamSettings current,
    required ValueChanged<ManualStreamSettings> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
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
            final selected = current.targetHeight == h;
            final label = h == 0 ? 'Native' : '${h}p';
            return ChoiceChip(
              label: Text(label, style: const TextStyle(fontSize: 12)),
              selected: selected,
              selectedColor: Colors.blueAccent,
              backgroundColor: Colors.white.withOpacity(0.08),
              labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => onChanged(current.copyWith(targetHeight: h)),
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
            final selected = current.fps == fps;
            return ChoiceChip(
              label: Text('$fps', style: const TextStyle(fontSize: 12)),
              selected: selected,
              selectedColor: Colors.blueAccent,
              backgroundColor: Colors.white.withOpacity(0.08),
              labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => onChanged(current.copyWith(fps: fps)),
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
              '${current.maxMbps} Mbps',
              style: const TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        Slider(
          value: current.maxMbps.toDouble().clamp(2.0, 40.0),
          min: 2,
          max: 40,
          divisions: 38,
          activeColor: Colors.blueAccent,
          inactiveColor: Colors.white24,
          onChanged: (val) => onChanged(current.copyWith(maxMbps: val.round())),
        ),
      ],
    );
  }

  Widget _buildCodecSelector({
    required VideoCodecPreference selectedCodec,
    required ValueChanged<VideoCodecPreference> onSelected,
  }) {
    Widget buildSideBadge(String prefix, CodecCapability? cap, bool selected) {
      final text = cap == null ? '$prefix:...' : '$prefix:${cap.badge}';
      final color = cap == null
          ? Colors.white38
          : (!cap.supported
              ? Colors.white24
              : (cap.hardware ? Colors.greenAccent : Colors.amberAccent));
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: selected ? Colors.black.withOpacity(0.25) : color.withOpacity(0.15),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _pcCodecCapabilities.isNotEmpty
              ? 'Video Codec (PC Enc • Tablet Dec)'
              : 'Video Codec (Tablet Dec)',
          style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: VideoCodecPreference.values.map((codec) {
            final selected = selectedCodec == codec;
            final pcCap = _pcCodecCapabilities[codec];
            final tabCap = _tabletCodecCapabilities[codec];
            final isAuto = codec == VideoCodecPreference.auto;
            final pcSupported = isAuto || (pcCap?.supported ?? true);
            final tabSupported = isAuto || (tabCap?.supported ?? true);
            final supported = pcSupported && tabSupported;
            final bothHw = !isAuto &&
                (pcCap?.supported == true && pcCap?.hardware == true) &&
                (tabCap?.supported == true && tabCap?.hardware == true);

            return InkWell(
              onTap: supported ? () => onSelected(codec) : null,
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: selected
                      ? Colors.blueAccent
                      : Colors.white.withOpacity(supported ? 0.08 : 0.03),
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
                      if (_pcCodecCapabilities.isNotEmpty) ...[
                        const SizedBox(width: 5),
                        buildSideBadge('PC', pcCap, selected),
                      ],
                      const SizedBox(width: 4),
                      buildSideBadge('Tab', tabCap, selected),
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  void _showQualityDialog() {
    StreamQualityMode dialogMode = _qualityMode;
    ManualStreamSettings dialogManual = _manualSettings;
    VideoCodecPreference dialogCodec = _videoCodec;
    String? liveStats;
    Timer? dialogStatsTimer;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Stream Quality & Codec', style: TextStyle(color: Colors.white)),
          content: StatefulBuilder(
            builder: (context, setDialogState) {
              dialogStatsTimer ??= Timer.periodic(const Duration(seconds: 1), (_) async {
                if (_usingNativeHwStream) {
                  try {
                    final raw = await _deviceChannel.invokeMethod('getNativeVideoStats');
                    if (raw is Map && context.mounted) {
                      final fps = (raw['fps'] as num?)?.toInt() ?? 0;
                      final w = (raw['width'] as num?)?.toInt() ?? 0;
                      final h = (raw['height'] as num?)?.toInt() ?? 0;
                      final codec = raw['codec']?.toString() ?? '';
                      final dec = raw['decoder']?.toString() ?? '';
                      final label = dec.isNotEmpty ? '$codec ($dec)' : codec;
                      setDialogState(() {
                        liveStats = '$fps fps • ${w}x$h • $label';
                      });
                    }
                  } catch (_) {}
                  return;
                }
                final pc = _peerConnection;
                if (pc == null) return;
                final s = await readVideoStatsSummary(pc, inbound: true);
                if (s != null && context.mounted) {
                  setDialogState(() => liveStats = s);
                }
              });
              final resolved = dialogMode.resolveConfig(manual: dialogManual);
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (liveStats != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.greenAccent.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
                        ),
                        child: Text(
                          liveStats!,
                          style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: StreamQualityMode.values.map((mode) {
                        final selected = dialogMode == mode;
                        return ChoiceChip(
                          label: Text(mode.config.label, style: const TextStyle(fontSize: 12)),
                          selected: selected,
                          selectedColor: Colors.blueAccent,
                          backgroundColor: Colors.white.withOpacity(0.08),
                          labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
                          side: BorderSide.none,
                          onSelected: (_) {
                            setDialogState(() => dialogMode = mode);
                            _setQualityMode(mode, manual: dialogManual);
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      resolved.description,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    if (dialogMode == StreamQualityMode.manual) ...[
                      const SizedBox(height: 14),
                      _buildManualControls(
                        current: dialogManual,
                        onChanged: (updated) {
                          setDialogState(() => dialogManual = updated);
                          _setQualityMode(StreamQualityMode.manual, manual: updated);
                        },
                      ),
                    ],
                    const SizedBox(height: 16),
                    _buildCodecSelector(
                      selectedCodec: dialogCodec,
                      onSelected: (codec) {
                        setDialogState(() => dialogCodec = codec);
                        _setVideoCodec(codec);
                      },
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ).whenComplete(() {
      dialogStatsTimer?.cancel();
    });
  }

  void _addNewShortcut() {
    String label = "";
    int vkCode = 65;
    bool ctrl = false;
    bool shift = false;
    bool alt = false;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Add Custom Shortcut', style: TextStyle(color: Colors.white)),
          content: StatefulBuilder(
            builder: (context, setDialogState) {
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Label (e.g. Save)', labelStyle: TextStyle(color: Colors.white54)),
                      onChanged: (val) => label = val,
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      value: vkCode,
                      dropdownColor: Colors.grey[800],
                      style: const TextStyle(color: Colors.white),
                      items: List.generate(26, (index) => DropdownMenuItem(value: 65 + index, child: Text(String.fromCharCode(65 + index))))..add(const DropdownMenuItem(value: 32, child: Text("SPACE"))),
                      onChanged: (val) {
                        if (val != null) setDialogState(() => vkCode = val);
                      },
                      decoration: const InputDecoration(labelText: 'Key', labelStyle: TextStyle(color: Colors.white54)),
                    ),
                    CheckboxListTile(
                      title: const Text('Ctrl', style: TextStyle(color: Colors.white)),
                      value: ctrl,
                      onChanged: (val) => setDialogState(() => ctrl = val!),
                    ),
                    CheckboxListTile(
                      title: const Text('Shift', style: TextStyle(color: Colors.white)),
                      value: shift,
                      onChanged: (val) => setDialogState(() => shift = val!),
                    ),
                    CheckboxListTile(
                      title: const Text('Alt', style: TextStyle(color: Colors.white)),
                      value: alt,
                      onChanged: (val) => setDialogState(() => alt = val!),
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (label.isEmpty) label = String.fromCharCode(vkCode);
                int mods = (ctrl ? 1 : 0) | (shift ? 2 : 0) | (alt ? 4 : 0);
                setState(() {
                  _shortcuts.add(ShortcutItem(label: label, icon: Icons.keyboard, vkCode: vkCode, modifiers: mods));
                  _savePrefs();
                });
                Navigator.pop(context);
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCanvas() {
    return Expanded(
      flex: 92,
      child: Container(
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                if (_mirrorScreen &&
                    _usingNativeHwStream &&
                    _nativeTextureId != null)
                  Positioned.fill(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: (_nativeVideoWidth > 0 &&
                                _nativeVideoHeight > 0)
                            ? _nativeVideoWidth / _nativeVideoHeight
                            : 16.0 / 9.0,
                        child: Texture(
                          textureId: _nativeTextureId!,
                          filterQuality: FilterQuality.low,
                        ),
                      ),
                    ),
                  )
                else if (_mirrorScreen && _remoteRenderer.srcObject != null)
                  Positioned.fill(
                    child: RTCVideoView(
                      _remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      filterQuality: FilterQuality.low,
                    ),
                  ),
                Positioned.fill(
                  child: Listener(
                    onPointerDown: (e) => _handlePointerEvent(e, constraints),
                    onPointerMove: (e) => _handlePointerEvent(e, constraints),
                    onPointerUp: (e) => _handlePointerEvent(e, constraints),
                    onPointerCancel: (e) => _handlePointerEvent(e, constraints),
                    onPointerHover: (e) => _handlePointerEvent(e, constraints),
                    behavior: HitTestBehavior.opaque,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
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

  Widget _buildSidebar() {
    return Expanded(
      flex: 8,
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              border: Border(
                right: _shortcutsOnLeft ? BorderSide(color: Colors.white.withOpacity(0.1)) : BorderSide.none,
                left: !_shortcutsOnLeft ? BorderSide(color: Colors.white.withOpacity(0.1)) : BorderSide.none,
              )
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.redAccent, size: 28),
                  onPressed: _disconnect,
                  tooltip: 'Disconnect',
                ),
                Divider(color: Colors.white.withOpacity(0.1), height: 30),
                Expanded(
                  child: ListView.builder(
                    itemCount: _shortcuts.length,
                    itemBuilder: (context, index) {
                      final s = _shortcuts[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            onTap: () => _sendShortcut(s),
                            onLongPress: () {
                              setState(() {
                                _shortcuts.removeAt(index);
                                _savePrefs();
                              });
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Tooltip(
                              message: "Tap to send • Hold to delete",
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                                ),
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(s.icon, color: Colors.white70, size: 24),
                                    const SizedBox(height: 4),
                                    Text(
                                      s.label,
                                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                      textAlign: TextAlign.center,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Divider(color: Colors.white.withOpacity(0.1), height: 20),
                if (_mirrorScreen) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        onTap: _showQualityDialog,
                        borderRadius: BorderRadius.circular(12),
                        child: Tooltip(
                          message:
                              'Stream: ${_activeQualityConfig.label} (${_activeQualityConfig.description})',
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                            decoration: BoxDecoration(
                              color: Colors.blueAccent.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.blueAccent.withOpacity(0.35)),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _qualityMode == StreamQualityMode.performance
                                      ? Icons.speed
                                      : (_qualityMode == StreamQualityMode.quality
                                          ? Icons.high_quality
                                          : (_qualityMode == StreamQualityMode.manual
                                              ? Icons.display_settings
                                              : Icons.tune)),
                                  color: Colors.blueAccent,
                                  size: 20,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _activeQualityConfig.shortLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                IconButton(
                  icon: const Icon(Icons.add_circle, color: Colors.blueAccent, size: 32),
                  onPressed: _addNewShortcut,
                  tooltip: 'Add Shortcut',
                ),
                const SizedBox(height: 10),
                IconButton(
                  icon: Icon(Icons.swap_horiz, color: Colors.white.withOpacity(0.5)),
                  onPressed: () {
                    setState(() {
                      _shortcutsOnLeft = !_shortcutsOnLeft;
                      _savePrefs();
                    });
                  },
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _client?.dispose();
    _ipController.dispose();
    _remoteRenderer.dispose();
    _closeWebRtc();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isConnected) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Row(
            children: _shortcutsOnLeft
                ? [_buildSidebar(), _buildCanvas()]
                : [_buildCanvas(), _buildSidebar()],
          ),
        ),
      );
    }

    if (_isScanning) {
      return Scaffold(
        body: Stack(
          children: [
            MobileScanner(
              onDetect: (capture) {
                final List<Barcode> barcodes = capture.barcodes;
                if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                  final ip = barcodes.first.rawValue!;
                  _ipController.text = ip;
                  _connect(ip);
                }
              },
            ),
            Positioned(
              top: 40,
              right: 20,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 32),
                onPressed: () => setState(() => _isScanning = false),
              ),
            ),
            const Center(
              child: Text(
                'Scan QR Code on PC Screen',
                style: TextStyle(color: Colors.white, fontSize: 24, backgroundColor: Colors.black54),
              ),
            ),
          ],
        ),
      );
    }

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
            padding: const EdgeInsets.all(32.0),
            child: _buildGlassCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.edit, size: 64, color: Colors.blueAccent),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'VirtualStylus',
                    style: TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800, letterSpacing: 1.2),
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: 350,
                    child: TextField(
                      controller: _ipController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 2),
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        hintText: 'Enter PC IP Address',
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3), letterSpacing: 0),
                        filled: true,
                        fillColor: Colors.black.withOpacity(0.4),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(color: Colors.blueAccent),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: 350,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.03),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.05)),
                      ),
                      child: SwitchListTile(
                        title: const Text('Mirror PC Screen', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                        subtitle: const Text('WebRTC Video Stream', style: TextStyle(color: Colors.white54, fontSize: 12)),
                        value: _mirrorScreen,
                        activeColor: Colors.blueAccent,
                        activeTrackColor: Colors.blueAccent.withOpacity(0.3),
                        inactiveThumbColor: Colors.white54,
                        inactiveTrackColor: Colors.black45,
                        onChanged: (val) {
                          setState(() => _mirrorScreen = val);
                          _savePrefs();
                        },
                      ),
                    ),
                  ),
                  if (_mirrorScreen) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: 350,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withOpacity(0.05)),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: StreamQualityMode.values.map((mode) {
                                final selected = _qualityMode == mode;
                                return Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 2),
                                    child: InkWell(
                                      onTap: () => _setQualityMode(mode, notifyPeer: false),
                                      borderRadius: BorderRadius.circular(12),
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 160),
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        decoration: BoxDecoration(
                                          color: selected ? Colors.blueAccent : Colors.transparent,
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          mode.config.label,
                                          textAlign: TextAlign.center,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: selected ? Colors.white : Colors.white60,
                                            fontSize: 12,
                                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _activeQualityConfig.description,
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                            if (_qualityMode == StreamQualityMode.manual) ...[
                              const SizedBox(height: 12),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                child: _buildManualControls(
                                  current: _manualSettings,
                                  onChanged: (updated) => _setQualityMode(
                                    StreamQualityMode.manual,
                                    manual: updated,
                                    notifyPeer: false,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: _buildCodecSelector(
                                selectedCodec: _videoCodec,
                                onSelected: (codec) => _setVideoCodec(codec, notifyPeer: false),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 40),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _connect,
                        icon: const Icon(Icons.wifi, color: Colors.white),
                        label: const Text('Connect', style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 10,
                          shadowColor: Colors.blueAccent.withOpacity(0.5),
                        ),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        onPressed: () => setState(() => _isScanning = true),
                        icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
                        label: const Text('Scan QR', style: TextStyle(fontSize: 18, color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white.withOpacity(0.1),
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
