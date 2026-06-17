import 'dart:io';
import 'stylus_event.dart';

class UdpClient {
  final String targetIp;
  final int port;
  RawDatagramSocket? _socket;

  UdpClient({required this.targetIp, this.port = 4000});

  Future<void> connect() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    print('UDP Client ready on port ${_socket?.port}, targeting $targetIp:$port');
  }

  void sendEvent(StylusEvent event) {
    if (_socket == null) return;
    try {
      final address = InternetAddress(targetIp);
      _socket?.send(event.toBytes(), address, port);
    } catch (e) {
      print('Error sending event: $e');
    }
  }

  void dispose() {
    _socket?.close();
    _socket = null;
  }
}
