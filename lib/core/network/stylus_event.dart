import 'dart:typed_data';

enum EventAction { down, move, up, cancel }
enum PointerKind { touch, stylus, invertedStylus, mouse }

class StylusEvent {
  final EventAction action;
  final PointerKind kind;
  final double x;
  final double y;
  final double pressure;

  StylusEvent({
    required this.action,
    required this.kind,
    required this.x,
    required this.y,
    required this.pressure,
  });

  Uint8List toBytes() {
    final data = ByteData(14);
    data.setUint8(0, action.index);
    data.setUint8(1, kind.index);
    data.setFloat32(2, x, Endian.little);
    data.setFloat32(6, y, Endian.little);
    data.setFloat32(10, pressure, Endian.little);
    return data.buffer.asUint8List();
  }

  factory StylusEvent.fromBytes(Uint8List bytes) {
    if (bytes.length < 14) {
      throw const FormatException("Invalid byte length for StylusEvent");
    }
    final data = ByteData.sublistView(bytes);
    return StylusEvent(
      action: EventAction.values[data.getUint8(0)],
      kind: PointerKind.values[data.getUint8(1)],
      x: data.getFloat32(2, Endian.little),
      y: data.getFloat32(6, Endian.little),
      pressure: data.getFloat32(10, Endian.little),
    );
  }
}
