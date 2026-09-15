import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/network/udp_server.dart';
import '../core/network/stylus_event.dart';
import '../core/network/webrtc_signaler.dart';

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
  String? _connectedIp;
  WebRtcSignaler? _signaler;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  @override
  void initState() {
    super.initState();
    _initServer();
    _startSignalingServer();
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
      });
    } catch (e) {
      debugPrint("Failed to inject event: $e");
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
        setState(() {
          _connectedIp = ip;
        });
        _server.lockedIp = ip;
        _setupWebRtcAndSendOffer();
      },
      onDisconnect: () {
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
        final mediaConstraints = <String, dynamic>{
          'audio': false,
          'video': {
            'mandatory': {
              'chromeMediaSource': 'desktop',
              'chromeMediaSourceId': source.id,
            }
          }
        };
        _localStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
        
        _localStream!.getTracks().forEach((track) {
          _peerConnection!.addTrack(track, _localStream!);
        });

        RTCSessionDescription offer = await _peerConnection!.createOffer();
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
    if (_peerConnection == null) return;

    final type = message['type'];
    if (type == 'answer') {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(message['sdp'], type),
      );
      _isRemoteSet = true;
      for (var cand in _remoteCandidates) {
        await _peerConnection!.addCandidate(cand);
      }
      _remoteCandidates.clear();
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
