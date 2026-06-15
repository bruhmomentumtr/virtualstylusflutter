import 'package:flutter/material.dart';
import 'dart:io';
import 'client_screen.dart';
import 'host_screen.dart';

class ModeSelectionScreen extends StatelessWidget {
  const ModeSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    bool isAndroid = Platform.isAndroid || Platform.isIOS;
    bool isWindows = Platform.isWindows;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Virtual Stylus'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Çalışma Modunu Seçin',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),

            // Sadece ANDROID ise:
            if (isAndroid) ...[
              const Icon(Icons.tablet_android, size: 64, color: Colors.blueAccent),
              const SizedBox(height: 20),
              const Text(
                'Mobil cihazlar (Tablet/Telefon) sadece kalem göndericisi (Stylus) olarak çalışır.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.edit, size: 40),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
                  child: Text('Stylus Modu ile Bağlan', style: TextStyle(fontSize: 18)),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ClientSetupScreen()),
                  );
                },
              ),
            ]
            // Sadece WINDOWS ise (Hem Host Hem Client):
            else if (isWindows) ...[
              ElevatedButton.icon(
                icon: const Icon(Icons.desktop_mac, size: 40),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
                  child: Text('Ana Ekran Modu (Alıcı)', style: TextStyle(fontSize: 18)),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const HostScreen()),
                  );
                },
              ),
              const SizedBox(height: 30),
              const Text('veya Windows Cihazını Tablet Olarak Kullan', style: TextStyle(color: Colors.grey, fontSize: 16)),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                icon: const Icon(Icons.edit, size: 40),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
                  child: Text('Stylus Modu (Gönderici)', style: TextStyle(fontSize: 18)),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ClientSetupScreen()),
                  );
                },
              ),
            ]
            // LİNUX veya Diğer Platformlar:
            else ...[
              ElevatedButton.icon(
                icon: const Icon(Icons.desktop_mac, size: 40),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20.0, horizontal: 16.0),
                  child: Text('Ana Ekran Modu (Linux vb.)', style: TextStyle(fontSize: 18)),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const HostScreen()),
                  );
                },
              ),
            ]
          ],
        ),
      ),
    );
  }
}
