import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import '../native/windows_input.dart';

class HostScreen extends StatefulWidget {
  const HostScreen({super.key});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  RawDatagramSocket? _socket;
  List<String> _localIps = [];
  String _lastEvent = 'Bekleniyor...';

  int _hostScreenWidth = 1920;
  int _hostScreenHeight = 1080;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _hostScreenWidth = WindowsInput.getScreenWidth();
      _hostScreenHeight = WindowsInput.getScreenHeight();
    }
    _startServer();
  }

  Future<void> _startServer() async {
    List<String> ips = [];
    try {
      var interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            ips.add(addr.address);
          }
        }
      }
    } catch (e) {
      ips.add('Ağ Hatası - IP Alınamadı');
    }

    if (mounted) setState(() => _localIps = ips);

    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 4999);
    _socket?.listen((RawSocketEvent e) {
      if (e == RawSocketEvent.read) {
        Datagram? dg = _socket?.receive();
        if (dg != null) {
          String message = utf8.decode(dg.data);
          _processNetworkEvent(message);
        }
      }
    });
  }

  void _processNetworkEvent(String message) {
    if (mounted) setState(() => _lastEvent = message);

    List<String> parts = message.split('|');
    if (parts.length >= 5 && parts[0] == 'STYLUS') {
      String type = parts[1]; // UP, DOWN, MOVE
      
      // Gelen normalize (0.0-1.0) koordinatları asıl ekran çözünürlüğüne çevirme
      double nx = double.tryParse(parts[2]) ?? 0;
      double ny = double.tryParse(parts[3]) ?? 0;
      
      int targetX = (nx * _hostScreenWidth).toInt();
      int targetY = (ny * _hostScreenHeight).toInt();

      // Yerleşik kütüphaneye veri yolluyoruz (Windows Fare/Kalem Simülasyonu)
      if (Platform.isWindows) {
        WindowsInput.moveCursor(targetX, targetY);
        if (type == 'DOWN') {
          WindowsInput.leftDown();
        } else if (type == 'UP') {
          WindowsInput.leftUp();
        }
      }
    }
  }

  @override
  void dispose() {
    _socket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alıcı (Host) Modu')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.satellite_alt, size: 60, color: Colors.green),
              const SizedBox(height: 20),
              Text(
                'Alıcı Başlatıldı (Ekran: ${_hostScreenWidth}x$_hostScreenHeight)',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              const Text('Stylus (Android/Tablet) cihazında şu IP adresini girin:'),
              const SizedBox(height: 10),
              if (_localIps.isNotEmpty)
                Column(
                  children: _localIps.map((ip) => Text(
                        ip,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                      )).toList(),
                )
              else
                const CircularProgressIndicator(),
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(8)),
                child: Text('Gelen Paketler:\n$_lastEvent', style: const TextStyle(fontFamily: 'monospace')),
              )
            ],
          ),
        ),
      ),
    );
  }
}
