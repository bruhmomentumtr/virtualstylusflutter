import 'dart:io';
import 'dart:async';
import 'stylus_event.dart';

class UdpServer {
  final int port;
  RawDatagramSocket? _socket;
  final _eventStreamController = StreamController<StylusEvent>.broadcast();

  UdpServer({this.port = 4000});

  Stream<StylusEvent> get events => _eventStreamController.stream;

  String? lockedIp;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    print('UDP Server listening on port $port');

    _socket?.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        Datagram? datagram = _socket?.receive();
        if (datagram != null) {
          // IP Filtering for Security (Anti-Multi-Device)
          if (lockedIp != null && datagram.address.address != lockedIp) {
            return; // Ignore packets from unauthorized devices
          }
          
          try {
            final stylusEvent = StylusEvent.fromBytes(datagram.data);
            _eventStreamController.add(stylusEvent);
          } catch (e) {
            print('Error parsing StylusEvent: $e');
          }
        }
      }
    });
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}
