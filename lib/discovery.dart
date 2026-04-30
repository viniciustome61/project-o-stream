import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DiscoveredReceiver {
  const DiscoveredReceiver({
    required this.host,
    required this.hostname,
    required this.srtPort,
    required this.roundTripMs,
  });

  final String host;
  final String hostname;
  final int srtPort;
  final int roundTripMs;

  String get label => '$hostname  $host:$srtPort  ${roundTripMs}ms';
}

class ReceiverDiscovery {
  static const int discoveryPort = 7071;
  static const int offerPort = 7072;
  static const String probe = 'PROJECTO_STREAM_DISCOVER';

  static Future<DiscoveredReceiver?> find({
    Duration timeout = const Duration(seconds: 4),
    String? cachedHost,
  }) async {
    final started = DateTime.now();
    final completer = Completer<DiscoveredReceiver?>();
    final seen = <String>{};
    final sockets = <RawDatagramSocket>[];
    final subscriptions = <StreamSubscription<RawSocketEvent>>[];
    Timer? pulseTimer;

    Future<void> finishFrom(Datagram datagram) async {
      try {
        final payload = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
        if (payload['service'] != 'project-o-stream') return;
        final host = (payload['host'] as String?) ?? datagram.address.address;
        if (!seen.add(host) || completer.isCompleted) return;
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        completer.complete(
          DiscoveredReceiver(
            host: host,
            hostname: (payload['hostname'] as String?) ?? host,
            srtPort: (payload['srtPort'] as num?)?.toInt() ?? 7070,
            roundTripMs: elapsed,
          ),
        );
      } catch (_) {
        return;
      }
    }

    void attachReader(RawDatagramSocket socket) {
      subscriptions.add(
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          unawaited(finishFrom(datagram));
        }),
      );
    }

    final probeSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    probeSocket.broadcastEnabled = true;
    sockets.add(probeSocket);
    attachReader(probeSocket);

    try {
      final offerSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        offerPort,
        reuseAddress: true,
      );
      sockets.add(offerSocket);
      attachReader(offerSocket);
    } catch (_) {
      // Another app instance may own the offer port. Active probes still work.
    }

    void sendPulse() {
      final payload = utf8.encode(probe);
      for (final host in _candidateHosts(cachedHost)) {
        try {
          probeSocket.send(payload, InternetAddress(host), discoveryPort);
        } catch (_) {
          continue;
        }
      }
    }

    pulseTimer = Timer.periodic(const Duration(milliseconds: 350), (_) => sendPulse());
    sendPulse();

    final result = await completer.future.timeout(timeout, onTimeout: () => null);
    pulseTimer.cancel();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    for (final socket in sockets) {
      socket.close();
    }
    return result;
  }

  static Iterable<String> _candidateHosts(String? cachedHost) sync* {
    yield '255.255.255.255';
    final cached = cachedHost?.trim();
    if (cached != null && cached.isNotEmpty) {
      yield cached;
      // Scan the same /24 subnet as the cached host — faster than guessing a hardcoded range.
      final parts = cached.split('.');
      if (parts.length == 4) {
        final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
        for (var last = 1; last <= 254; last++) {
          final candidate = '$prefix.$last';
          if (candidate != cached) yield candidate;
        }
      }
    }
  }
}
