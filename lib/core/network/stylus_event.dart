import 'dart:typed_data';

enum EventAction { down, move, up, cancel, hover, shortcut }
enum PointerKind { touch, stylus, invertedStylus, mouse }

class StylusEvent {
  final EventAction action;
  final PointerKind kind;
  final double x;
  final double y;
  final double pressure;
  final int pointerId;
  final int activeTouchMask;
  final int sequence;

  StylusEvent({
    required this.action,
    required this.kind,
    required this.x,
    required this.y,
    required this.pressure,
    this.pointerId = 1,
    this.activeTouchMask = -1,
    this.sequence = -1,
  });

  Uint8List toBytes() {
    final int byteLength = sequence >= 0
        ? 22
        : (activeTouchMask >= 0 ? 20 : 18);
    final data = ByteData(byteLength);
    data.setUint8(0, action.index);
    data.setUint8(1, kind.index);
    data.setFloat32(2, x, Endian.little);
    data.setFloat32(6, y, Endian.little);
    data.setFloat32(10, pressure, Endian.little);
    data.setUint32(14, pointerId, Endian.little);
    if (byteLength >= 20) {
      data.setUint16(
        18,
        activeTouchMask >= 0 ? (activeTouchMask & 0xFFFF) : 0,
        Endian.little,
      );
    }
    if (byteLength >= 22) {
      data.setUint16(20, sequence & 0xFFFF, Endian.little);
    }
    return data.buffer.asUint8List();
  }

  factory StylusEvent.fromBytes(Uint8List bytes) {
    if (bytes.length < 14) {
      throw const FormatException("Invalid byte length for StylusEvent");
    }
    final data = ByteData.sublistView(bytes);
    final actionIdx = data.getUint8(0);
    final kindIdx = data.getUint8(1);
    if (actionIdx >= EventAction.values.length ||
        kindIdx >= PointerKind.values.length) {
      throw const FormatException("Invalid enum index for StylusEvent");
    }
    int pointerId = 1;
    if (bytes.length >= 18) {
      pointerId = data.getUint32(14, Endian.little);
      if (pointerId <= 0 || pointerId > 16) pointerId = 1;
    }
    int activeTouchMask = -1;
    if (bytes.length >= 20) {
      activeTouchMask = data.getUint16(18, Endian.little);
    }
    int sequence = -1;
    if (bytes.length >= 22) {
      sequence = data.getUint16(20, Endian.little);
    }
    return StylusEvent(
      action: EventAction.values[actionIdx],
      kind: PointerKind.values[kindIdx],
      x: data.getFloat32(2, Endian.little),
      y: data.getFloat32(6, Endian.little),
      pressure: data.getFloat32(10, Endian.little),
      pointerId: pointerId,
      activeTouchMask: activeTouchMask,
      sequence: sequence,
    );
  }
}
