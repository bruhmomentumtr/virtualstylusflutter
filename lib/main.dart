import 'package:flutter/material.dart';
import 'dart:io';
import 'ui/mode_selection.dart';
import 'native/windows_input.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Yerleşik Kütüphane Yüklemeleri (Windows Cihazlar için)
  if (Platform.isWindows) {
    WindowsInput.init();
  }

  runApp(const VirtualStylusApp());
}

class VirtualStylusApp extends StatelessWidget {
  const VirtualStylusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Virtual Stylus',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      home: const ModeSelectionScreen(),
    );
  }
}
