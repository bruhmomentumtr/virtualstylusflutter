import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/network/udp_client.dart';
import '../core/network/stylus_event.dart';

class ShortcutItem {
  final String label;
  final IconData icon;
  final int vkCode;
  final int modifiers;

  ShortcutItem({
    required this.label,
    required this.icon,
    required this.vkCode,
    required this.modifiers,
  });

  Map<String, dynamic> toMap() => {
        'label': label,
        'icon': icon.codePoint,
        'vkCode': vkCode,
        'modifiers': modifiers,
      };

  factory ShortcutItem.fromMap(Map<String, dynamic> map) => ShortcutItem(
        label: map['label'],
        icon: IconData(map['icon'], fontFamily: 'MaterialIcons'),
        vkCode: map['vkCode'],
        modifiers: map['modifiers'],
      );
}

class AndroidTransmitterScreen extends StatefulWidget {
  const AndroidTransmitterScreen({super.key});

  @override
  State<AndroidTransmitterScreen> createState() => _AndroidTransmitterScreenState();
}

class _AndroidTransmitterScreenState extends State<AndroidTransmitterScreen> {
  final TextEditingController _ipController = TextEditingController();
  UdpClient? _client;
  bool _isConnected = false;
  bool _isScanning = false;

  bool _shortcutsOnLeft = true;
  List<ShortcutItem> _shortcuts = [
    ShortcutItem(label: 'Undo', icon: Icons.undo, vkCode: 90, modifiers: 1), // Z + Ctrl
    ShortcutItem(label: 'Redo', icon: Icons.redo, vkCode: 89, modifiers: 1), // Y + Ctrl
  ];

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _shortcutsOnLeft = prefs.getBool('shortcutsOnLeft') ?? true;
      final savedShortcuts = prefs.getString('shortcuts');
      if (savedShortcuts != null) {
        final List decoded = jsonDecode(savedShortcuts);
        _shortcuts = decoded.map((e) => ShortcutItem.fromMap(e)).toList();
      }
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('shortcutsOnLeft', _shortcutsOnLeft);
    final encoded = jsonEncode(_shortcuts.map((e) => e.toMap()).toList());
    await prefs.setString('shortcuts', encoded);
  }

  void _connect([String? ipAddr]) async {
    final ip = ipAddr ?? _ipController.text.trim();
    if (ip.isEmpty) return;

    _client?.dispose();
    _client = UdpClient(targetIp: ip);
    await _client?.connect();

    setState(() {
      _isConnected = true;
      _isScanning = false;
    });

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _disconnect() {
    _client?.dispose();
    setState(() {
      _isConnected = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _handlePointerEvent(PointerEvent event, BoxConstraints constraints) {
    if (_client == null) return;

    final x = (event.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final y = (event.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    EventAction action = EventAction.move;
    if (event is PointerDownEvent) {
      action = EventAction.down;
    } else if (event is PointerUpEvent) {
      action = EventAction.up;
    } else if (event is PointerCancelEvent) {
      action = EventAction.cancel;
    } else if (event is PointerHoverEvent) {
      action = EventAction.hover;
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

  void _sendShortcut(ShortcutItem item) {
    if (_client == null) return;

    final shortcutEvent = StylusEvent(
      action: EventAction.shortcut,
      kind: PointerKind.touch,
      x: item.vkCode.toDouble(),
      y: item.modifiers.toDouble(),
      pressure: 0.0,
    );
    _client!.sendEvent(shortcutEvent);
  }

  void _addNewShortcut() {
    String label = "";
    int vkCode = 65; // Default 'A'
    bool ctrl = false;
    bool shift = false;
    bool alt = false;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Add Custom Shortcut', style: TextStyle(color: Colors.white)),
          content: StatefulBuilder(
            builder: (context, setDialogState) {
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(labelText: 'Label (e.g. Save)', labelStyle: TextStyle(color: Colors.white54)),
                      onChanged: (val) => label = val,
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      value: vkCode,
                      dropdownColor: Colors.grey[800],
                      style: const TextStyle(color: Colors.white),
                      items: List.generate(26, (index) => DropdownMenuItem(value: 65 + index, child: Text(String.fromCharCode(65 + index))))..add(const DropdownMenuItem(value: 32, child: Text("SPACE"))),
                      onChanged: (val) {
                        if (val != null) setDialogState(() => vkCode = val);
                      },
                      decoration: const InputDecoration(labelText: 'Key', labelStyle: TextStyle(color: Colors.white54)),
                    ),
                    CheckboxListTile(
                      title: const Text('Ctrl', style: TextStyle(color: Colors.white)),
                      value: ctrl,
                      onChanged: (val) => setDialogState(() => ctrl = val!),
                    ),
                    CheckboxListTile(
                      title: const Text('Shift', style: TextStyle(color: Colors.white)),
                      value: shift,
                      onChanged: (val) => setDialogState(() => shift = val!),
                    ),
                    CheckboxListTile(
                      title: const Text('Alt', style: TextStyle(color: Colors.white)),
                      value: alt,
                      onChanged: (val) => setDialogState(() => alt = val!),
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (label.isEmpty) label = String.fromCharCode(vkCode);
                int mods = (ctrl ? 1 : 0) | (shift ? 2 : 0) | (alt ? 4 : 0);
                setState(() {
                  _shortcuts.add(ShortcutItem(label: label, icon: Icons.keyboard, vkCode: vkCode, modifiers: mods));
                  _savePrefs();
                });
                Navigator.pop(context);
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCanvas() {
    return Expanded(
      flex: 92,
      child: Container(
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Listener(
              onPointerDown: (e) => _handlePointerEvent(e, constraints),
              onPointerMove: (e) => _handlePointerEvent(e, constraints),
              onPointerUp: (e) => _handlePointerEvent(e, constraints),
              onPointerCancel: (e) => _handlePointerEvent(e, constraints),
              onPointerHover: (e) => _handlePointerEvent(e, constraints),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSidebar() {
    return Expanded(
      flex: 8,
      child: Container(
        color: Colors.grey[900],
        child: Column(
          children: [
            const SizedBox(height: 10),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.redAccent),
              onPressed: _disconnect,
            ),
            const Divider(color: Colors.white24),
            Expanded(
              child: ListView.builder(
                itemCount: _shortcuts.length,
                itemBuilder: (context, index) {
                  final s = _shortcuts[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
                    child: InkWell(
                      onLongPress: () {
                        setState(() {
                          _shortcuts.removeAt(index);
                          _savePrefs();
                        });
                      },
                      child: Tooltip(
                        message: "Hold to delete",
                        child: FloatingActionButton(
                          heroTag: 'shortcut_$index',
                          mini: true,
                          backgroundColor: Colors.white24,
                          elevation: 0,
                          onPressed: () => _sendShortcut(s),
                          child: Text(s.label.substring(0, 1).toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(color: Colors.white24),
            IconButton(
              icon: const Icon(Icons.add, color: Colors.blueAccent),
              onPressed: _addNewShortcut,
            ),
            IconButton(
              icon: const Icon(Icons.swap_horiz, color: Colors.white54),
              onPressed: () {
                setState(() {
                  _shortcutsOnLeft = !_shortcutsOnLeft;
                  _savePrefs();
                });
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
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
        body: SafeArea(
          child: Row(
            children: _shortcutsOnLeft
                ? [_buildSidebar(), _buildCanvas()]
                : [_buildCanvas(), _buildSidebar()],
          ),
        ),
      );
    }

    if (_isScanning) {
      return Scaffold(
        body: Stack(
          children: [
            MobileScanner(
              onDetect: (capture) {
                final List<Barcode> barcodes = capture.barcodes;
                if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                  final ip = barcodes.first.rawValue!;
                  _ipController.text = ip;
                  _connect(ip);
                }
              },
            ),
            Positioned(
              top: 40,
              right: 20,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 32),
                onPressed: () => setState(() => _isScanning = false),
              ),
            ),
            const Center(
              child: Text(
                'Scan QR Code on PC Screen',
                style: TextStyle(color: Colors.white, fontSize: 24, backgroundColor: Colors.black54),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.wifi, color: Colors.white),
                    label: const Text('Connect', style: TextStyle(fontSize: 18, color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: () => setState(() => _isScanning = true),
                    icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
                    label: const Text('Scan QR', style: TextStyle(fontSize: 18, color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
