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

  // WebRTC
  bool _mirrorScreen = true;
  WebRtcSignaler? _signaler;
  RTCPeerConnection? _peerConnection;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _remoteRenderer.initialize();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _shortcutsOnLeft = prefs.getBool('shortcutsOnLeft') ?? true;
      _mirrorScreen = prefs.getBool('mirrorScreen') ?? true;
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
    final encoded = jsonEncode(_shortcuts.map((e) => e.toMap()).toList());
    await prefs.setString('shortcuts', encoded);
  }

  void _connect([String? ipAddr]) async {
    final ip = ipAddr ?? _ipController.text.trim();
    if (ip.isEmpty) return;

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
      onMessage: _handleSignalingMessage,
      onDisconnect: _closeWebRtc,
    );
    await _signaler!.connect(targetIp);
  }

  List<RTCIceCandidate> _remoteCandidates = [];
  bool _isRemoteSet = false;

  void _handleSignalingMessage(Map<String, dynamic> message) async {
    final type = message['type'];
    
    if (type == 'offer') {
      _isRemoteSet = false;
      _remoteCandidates.clear();

      final configuration = {
        "iceServers": []
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

      final answer = await _peerConnection!.createAnswer();
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
    _peerConnection?.close();
    _peerConnection = null;
    _signaler?.stop();
    _signaler = null;
    _remoteRenderer.srcObject = null;
  }

  void _disconnect() {
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
    if (_remoteRenderer.value.width > 0 && _remoteRenderer.value.height > 0) {
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

    final stylusEvent = StylusEvent(
      action: action,
      kind: kind,
      x: x,
      y: y,
      pressure: event.pressure,
    );

    _client!.sendEvent(stylusEvent);
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
                if (_mirrorScreen && _remoteRenderer.srcObject != null)
                  Positioned.fill(
                    child: RTCVideoView(
                      _remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
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
                        child: InkWell(
                          onLongPress: () {
                            setState(() {
                              _shortcuts.removeAt(index);
                              _savePrefs();
                            });
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Tooltip(
                            message: "Hold to delete",
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
                      );
                    },
                  ),
                ),
                Divider(color: Colors.white.withOpacity(0.1), height: 20),
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
