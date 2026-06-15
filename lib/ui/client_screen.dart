import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:convert';

/// Client Setup: Get Host IP
class ClientSetupScreen extends StatefulWidget {
  const ClientSetupScreen({super.key});

  @override
  State<ClientSetupScreen> createState() => _ClientSetupScreenState();
}

class _ClientSetupScreenState extends State<ClientSetupScreen> {
  final TextEditingController _ipController = TextEditingController();

  void _connect() {
    final ip = _ipController.text.trim();
    if (ip.isNotEmpty) {
      final hostAddress = InternetAddress.tryParse(ip);
      if (hostAddress != null) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => ClientCanvasScreen(hostIp: hostAddress)),
        );
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Geçerli bir IP adresi giriniz.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bilgisayara Bağlan (Wi-Fi)')),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi, size: 64, color: Colors.blueAccent),
            const SizedBox(height: 20),
            const Text(
              'Windows/Linux PC Ekranında Yazan IP Adresini Girin:',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Örn: 192.168.1.100',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _connect,
              child: const Padding(
                padding: EdgeInsets.all(12.0),
                child: Text('Bağlan ve Çizime Başla', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Client Screen: Send UDP Events
class ClientCanvasScreen extends StatefulWidget {
  final InternetAddress hostIp;
  const ClientCanvasScreen({super.key, required this.hostIp});

  @override
  State<ClientCanvasScreen> createState() => _ClientCanvasScreenState();
}

class _ClientCanvasScreenState extends State<ClientCanvasScreen> {
  RawDatagramSocket? _socket;

  @override
  void initState() {
    super.initState();
    _initSocket();
    // Tam ekran modu
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _initSocket() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _socket?.close();
    super.dispose();
  }

  void _sendData(String data) {
    if (_socket != null) {
      List<int> bytes = utf8.encode(data);
      _socket!.send(bytes, widget.hostIp, 4999);
    }
  }

  void _handlePointerEvent(PointerEvent event, BuildContext context, String type) {
    // Mobil/Windows tablet üzerindeki cihaz koordinatlarını Host cihazın çözünürlüğüne uydurmak üzere 0.0 - 1.0 arasına oranlarız (Normalize)
    final size = MediaQuery.of(context).size;
    final normalizedX = event.position.dx / size.width;
    final normalizedY = event.position.dy / size.height;

    if (event.kind == PointerDeviceKind.stylus || event.kind == PointerDeviceKind.invertedStylus || event.kind == PointerDeviceKind.touch) {
      String payload = 'STYLUS|$type|$normalizedX|$normalizedY|${event.pressure}';
      _sendData(payload);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Bağlı: ${widget.hostIp.address}'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Listener(
        onPointerDown: (event) => _handlePointerEvent(event, context, 'DOWN'),
        onPointerMove: (event) => _handlePointerEvent(event, context, 'MOVE'),
        onPointerUp:   (event) => _handlePointerEvent(event, context, 'UP'),
        child: Container(
          color: Colors.grey[900],
          width: double.infinity,
          height: double.infinity,
          child: const Center(
            child: Text(
              'ÇİZİM ALANI AKTİF\n\nTablet ekranı kapalı, hareketler direkt hedef bilgisayara iletiliyor.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.white54),
            ),
          ),
        ),
      ),
    );
  }
}
