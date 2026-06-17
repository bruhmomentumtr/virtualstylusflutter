import 'package:flutter/material.dart';
import 'dart:io';
import 'ui/android_transmitter.dart';
import 'ui/windows_receiver.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VirtualStylusApp());
}

class VirtualStylusApp extends StatelessWidget {
  const VirtualStylusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VirtualStylus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: _getHomeScreen(),
    );
  }

  Widget _getHomeScreen() {
    if (Platform.isWindows) {
      return const WindowsReceiverScreen();
    } else if (Platform.isAndroid) {
      return const AndroidTransmitterScreen();
    } else {
      return const Scaffold(
        body: Center(
          child: Text('Unsupported Platform. Please run on Windows or Android.'),
        ),
      );
    }
  }
}
