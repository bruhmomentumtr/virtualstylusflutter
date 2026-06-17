import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/network/udp_client.dart';
import '../core/network/stylus_event.dart';

class AndroidTransmitterScreen extends StatefulWidget {
  const AndroidTransmitterScreen({super.key});

  @override
  State<AndroidTransmitterScreen> createState() => _AndroidTransmitterScreenState();
}

class _AndroidTransmitterScreenState extends State<AndroidTransmitterScreen> {
  final TextEditingController _ipController = TextEditingController();
  UdpClient? _client;
  bool _isConnected = false;

  void _connect() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;

    _client?.dispose();
    _client = UdpClient(targetIp: ip);
    await _client?.connect();

    setState(() {
      _isConnected = true;
    });

    // Enter immersive mode for drawing
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _disconnect() {
    _client?.dispose();
    setState(() {
      _isConnected = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _handlePointerEvent(PointerEvent event) {
    if (_client == null) return;

    final RenderBox box = context.findRenderObject() as RenderBox;
    final size = box.size;

    // Normalize coordinates to 0.0 - 1.0
    final x = (event.localPosition.dx / size.width).clamp(0.0, 1.0);
    final y = (event.localPosition.dy / size.height).clamp(0.0, 1.0);

    EventAction action = EventAction.move;
    if (event is PointerDownEvent) {
      action = EventAction.down;
    } else if (event is PointerUpEvent) {
      action = EventAction.up;
    } else if (event is PointerCancelEvent) {
      action = EventAction.cancel;
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

  @override
  void dispose() {
    _client?.dispose();
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isConnected) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Listener(
              onPointerDown: _handlePointerEvent,
              onPointerMove: _handlePointerEvent,
              onPointerUp: _handlePointerEvent,
              onPointerCancel: _handlePointerEvent,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
            Positioned(
              top: 40,
              right: 20,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 32),
                onPressed: _disconnect,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.grey[900],
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.edit, size: 80, color: Colors.blueAccent),
              const SizedBox(height: 20),
              const Text(
                'VirtualStylus',
                style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _ipController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white, fontSize: 24),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  hintText: 'Enter PC IP Address',
                  hintStyle: const TextStyle(color: Colors.white30),
                  filled: true,
                  fillColor: Colors.black54,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _connect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Connect', style: TextStyle(fontSize: 20, color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
