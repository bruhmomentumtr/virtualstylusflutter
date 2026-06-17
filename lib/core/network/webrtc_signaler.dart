import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class WebRtcSignaler {
  ServerSocket? _server;
  Socket? _socket;
  final int port;
  final Function(Map<String, dynamic> data)? onMessage;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  WebRtcSignaler({
    this.port = 4001,
    this.onMessage,
    this.onConnect,
    this.onDisconnect,
  });

  // Windows side starts server
  Future<void> startServer() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      debugPrint("Signaler listening on port $port");
      _server!.listen((Socket socket) {
        if (_socket != null) {
          // Reject multiple connections for now
          socket.close();
          return;
        }
        _socket = socket;
        if (onConnect != null) onConnect!();
        _listenToSocket();
      });
    } catch (e) {
      debugPrint("Failed to start signaler server: $e");
    }
  }

  // Android side connects to server
  Future<void> connect(String targetIp) async {
    try {
      _socket = await Socket.connect(targetIp, port);
      debugPrint("Signaler connected to $targetIp:$port");
      if (onConnect != null) onConnect!();
      _listenToSocket();
    } catch (e) {
      debugPrint("Failed to connect signaler to $targetIp: $e");
    }
  }

  void _listenToSocket() {
    _socket!.listen(
      (data) {
        try {
          final str = utf8.decode(data);
          // Handle potential concatenated messages (JSON streams)
          final messages = str.split('\n').where((s) => s.trim().isNotEmpty);
          for (var msgStr in messages) {
            final msg = jsonDecode(msgStr);
            if (onMessage != null) {
              onMessage!(msg);
            }
          }
        } catch (e) {
          debugPrint("Failed to parse message: $e");
        }
      },
      onDone: () {
        _socket = null;
        if (onDisconnect != null) onDisconnect!();
      },
      onError: (e) {
        _socket = null;
        if (onDisconnect != null) onDisconnect!();
      },
    );
  }

  void sendMessage(Map<String, dynamic> message) {
    if (_socket != null) {
      final str = jsonEncode(message) + '\n';
      _socket!.write(str);
    }
  }

  void stop() {
    _socket?.close();
    _socket = null;
    _server?.close();
    _server = null;
  }
}
