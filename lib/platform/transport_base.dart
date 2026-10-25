import 'dart:typed_data';

class TransportEvent {
  final Uint8List bytes;
  final String endpoint, message;
  final bool closed;
  final SerialStatus? serialStatus;
  TransportEvent({
    List<int> bytes = const [],
    this.endpoint = '',
    this.message = '',
    this.closed = false,
    this.serialStatus,
  }) : bytes = Uint8List.fromList(bytes);
}

class Peer {
  final String id, endpoint;
  Peer(this.id, this.endpoint);
}

abstract class Transport {
  Stream<TransportEvent> get events;
  List<Peer> get peers;
  String get localEndpoint;
  Future<void> send(Uint8List bytes, {String? target});
  Future<void> disconnectPeer(String id);
  Future<void> close();
}

/// Optional capability: freeze one numeric UDP destination for a complete task.
/// It must select an address compatible with the bound socket's address family.
abstract interface class DatagramTargetResolver {
  Future<String> resolveDatagramTarget(String target);
}

class PortInfo {
  final String path, description, identity;
  PortInfo(this.path, this.description, {this.identity = ''});
}

class SerialStatus {
  final bool? dtr, rts, cts, dsr;
  final String error;
  const SerialStatus({this.dtr, this.rts, this.cts, this.dsr, this.error = ''});
}

abstract interface class SerialControl {
  SerialStatus get serialStatus;
  Future<void> setControlLines({bool? dtr, bool? rts});
}

/// Optional cancellation of writes that have not yet been submitted to the OS.
/// Already submitted bytes are never replayed or reported as retracted.
abstract interface class PendingWriteCancellation {
  void cancelPendingWrites();
}
