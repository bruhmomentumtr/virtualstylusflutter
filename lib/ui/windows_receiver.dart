import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/network/udp_server.dart';
import '../core/network/stylus_event.dart';

class WindowsReceiverScreen extends StatefulWidget {
  const WindowsReceiverScreen({super.key});

  @override
  State<WindowsReceiverScreen> createState() => _WindowsReceiverScreenState();
}

class _WindowsReceiverScreenState extends State<WindowsReceiverScreen> {
  final UdpServer _server = UdpServer();
  static const MethodChannel _channel = MethodChannel('com.virtualstylus/pen');
  String _localIp = 'Loading...';

  @override
  void initState() {
    super.initState();
    _initServer();
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
        'x': event.x,
        'y': event.y,
        'pressure': event.pressure,
      });
    } catch (e) {
      debugPrint("Failed to inject event: $e");
    }
  }

  @override
  void dispose() {
    _server.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_tethering, size: 80, color: Colors.blueAccent),
            const SizedBox(height: 20),
            const Text(
              'VirtualStylus Receiver',
              style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            const Text(
              'Scan QR or Enter IP in Android App:',
              style: TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blueAccent, width: 2),
              ),
              child: Text(
                _localIp,
                style: const TextStyle(color: Colors.greenAccent, fontSize: 36, fontWeight: FontWeight.bold, letterSpacing: 2),
              ),
            ),
            const SizedBox(height: 30),
            if (_localIp.contains('.'))
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: _localIp,
                  version: QrVersions.auto,
                  size: 200.0,
                ),
              ),
            const SizedBox(height: 30),
            const Text(
              'Listening on Port: 4000',
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
