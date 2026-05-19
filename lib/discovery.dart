import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DiscoveredReceiver {
  const DiscoveredReceiver({
    required this.host,
    required this.hostname,
    required this.srtPort,
    required this.obsUdpPort,
    required this.transport,
    required this.roundTripMs,
    String? preferredHost,
    String? preferredTransport,
    this.fallbackHost,
    this.fallbackTransport,
    this.slotIndex = 0,
    this.totalSlots = 1,
  })  : preferredHost = preferredHost ?? host,
        preferredTransport = preferredTransport ?? transport;

  final String host;
  final String preferredHost;
  final String hostname;
  final int srtPort;
  final int obsUdpPort;
  final String transport;
  final String preferredTransport;
  final String? fallbackHost;
  final String? fallbackTransport;
  final int roundTripMs;
  final int slotIndex;
  final int totalSlots;

  String get label => '$hostname  $host:$srtPort  ${roundTripMs}ms';
  String get details => transport.toUpperCase();
  bool get hasFallback =>
      fallbackHost != null && fallbackHost!.trim() != preferredHost.trim();

  String transportForHost(String endpoint) {
    final host = endpoint.trim();
    if (host == preferredHost) return preferredTransport;
    if (host == fallbackHost) return fallbackTransport ?? transport;
    if (host == this.host) return transport;
    return transport;
  }

  DiscoveredReceiver withActiveHost(String activeHost) {
    return DiscoveredReceiver(
      host: activeHost,
      preferredHost: preferredHost,
      hostname: hostname,
      srtPort: srtPort,
      obsUdpPort: obsUdpPort,
      transport: transportForHost(activeHost),
      preferredTransport: preferredTransport,
      fallbackHost: fallbackHost,
      fallbackTransport: fallbackTransport,
      roundTripMs: roundTripMs,
      slotIndex: slotIndex,
      totalSlots: totalSlots,
    );
  }
}

class ReceiverDiscovery {
  static const int discoveryPort = 7071;
  static const int offerPort = 7072;
  static const String probe = 'PROJECTO_STREAM_DISCOVER';
  static const String _lanProbe = 'PROJECTO_STREAM_LAN_PROBE';
  static const String _lanAck = 'PROJECTO_STREAM_LAN_ACK';

  static bool isUsableEndpointHost(String? value) {
    return _isUsableEndpointHost(value);
  }

  static Future<DiscoveredReceiver?> find({
    Duration timeout = const Duration(seconds: 4),
    String? cachedHost,
  }) async {
    final started = DateTime.now();
    final completer = Completer<DiscoveredReceiver?>();
    final seen = <String>{};
    final sockets = <RawDatagramSocket>[];
    final subscriptions = <StreamSubscription<RawSocketEvent>>[];
    final probeAddresses = await _candidateAddresses(cachedHost);
    Timer? pulseTimer;

    Future<void> finishFrom(Datagram datagram) async {
      try {
        final payload =
            jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
        if (payload['service'] != 'project-o-stream') return;

        final endpoint = await _selectEndpoint(payload, datagram);
        if (endpoint == null) return;

        if (!seen.add(endpoint.host) || completer.isCompleted) return;
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        completer.complete(
          DiscoveredReceiver(
            host: endpoint.host,
            preferredHost: endpoint.host,
            hostname: (payload['hostname'] as String?) ?? endpoint.host,
            srtPort: (payload['srtPort'] as num?)?.toInt() ?? 7070,
            obsUdpPort: (payload['obsUdpPort'] as num?)?.toInt() ?? 15000,
            transport: endpoint.transport,
            preferredTransport: endpoint.transport,
            fallbackHost: endpoint.fallbackHost,
            fallbackTransport: endpoint.fallbackTransport,
            roundTripMs: elapsed,
            slotIndex: (payload['slotIndex'] as num?)?.toInt() ?? 0,
            totalSlots: (payload['totalSlots'] as num?)?.toInt() ?? 1,
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

    final probeSocket =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
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
      // LAN broadcast — finds the server when Tailscale is off or no cached host.
      try {
        probeSocket.send(
            payload, InternetAddress('255.255.255.255'), discoveryPort);
      } on Object {/* broadcast unsupported on this interface — ignore */}
      for (final address in probeAddresses) {
        try {
          probeSocket.send(payload, address, discoveryPort);
        } on Object {
          continue;
        }
      }
    }

    void sendPulseSafely() {
      try {
        sendPulse();
      } on Object {
        // Discovery is opportunistic; server offers on UDP 7072 are enough.
      }
    }

    pulseTimer = Timer.periodic(
      const Duration(milliseconds: 350),
      (_) => sendPulseSafely(),
    );
    sendPulseSafely();

    final result =
        await completer.future.timeout(timeout, onTimeout: () => null);
    pulseTimer.cancel();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    for (final socket in sockets) {
      socket.close();
    }
    return result;
  }

  static Future<_EndpointSelection?> _selectEndpoint(
    Map<String, dynamic> payload,
    Datagram datagram,
  ) async {
    final payloadHost = (payload['host'] as String?)?.trim();
    final datagramHost = datagram.address.address;
    final lanIp = (payload['lanIp'] as String?)?.trim();
    final lanIps = payload['lanIps'];
    final tailscaleIp = (payload['tailscaleIp'] as String?)?.trim();

    // Collect unique candidates preserving insertion order (highest priority first).
    final candidates = <_HostCandidate>[];
    final seen = <String>{};

    void add(String? value, String transport) {
      final host = value?.trim();
      if (!_isUsableEndpointHost(host) || !seen.add(host!)) return;
      candidates.add(_HostCandidate(host: host, transport: transport));
    }

    add(datagramHost, _transportForHost(datagramHost));
    add(lanIp, 'lan');
    if (lanIps is List) {
      for (final ip in lanIps) {
        add(ip?.toString(), 'lan');
      }
    }
    add(tailscaleIp, 'tailscale');
    add(payloadHost, _transportForHost(payloadHost ?? ''));

    if (candidates.isEmpty) return null;

    // Probe all candidates in parallel — pick by lowest stable RTT.
    final results = await Future.wait(
      candidates.map((c) async {
        final rtt = await _measureLatency(c.host);
        return _ProbeResult(candidate: c, rtt: rtt);
      }),
    );

    final reachable = results.where((r) => r.rtt != null).toList()
      ..sort((a, b) => a.rtt!.compareTo(b.rtt!));

    if (reachable.isEmpty) {
      // No path responded — use heuristic order (insertion priority).
      return _EndpointSelection(
        host: candidates.first.host,
        transport: candidates.first.transport,
        fallbackHost: candidates.length > 1 ? candidates[1].host : null,
        fallbackTransport: candidates.length > 1 ? candidates[1].transport : null,
      );
    }

    final best = reachable.first;
    final second = reachable.length > 1 ? reachable[1] : null;

    return _EndpointSelection(
      host: best.candidate.host,
      transport: best.candidate.transport,
      fallbackHost: second?.candidate.host,
      fallbackTransport: second?.candidate.transport,
    );
  }

  static String _transportForHost(String host) {
    if (_isTailscaleEndpointHost(host)) return 'tailscale';
    if (_isLanEndpointHost(host)) return 'lan';
    return 'srt';
  }

  /// Sends up to [probes] LAN probes to [host] with [intervalMs] between them
  /// and returns the minimum observed RTT in milliseconds, or null if no
  /// response arrived. All candidates are probed in parallel by the caller.
  static Future<int?> _measureLatency(
    String host, {
    int probes = 3,
    int intervalMs = 80,
    int perProbeTimeoutMs = 200,
  }) async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final address = InternetAddress(host);
      final bytes = utf8.encode(_lanProbe);
      int? minRtt;
      Completer<int?>? active;
      var t0 = 0;

      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null || dg.address.address != host) return;
        if (utf8.decode(dg.data, allowMalformed: true) != _lanAck) return;
        final rtt = DateTime.now().millisecondsSinceEpoch - t0;
        final pending = active;
        if (pending != null && !pending.isCompleted) pending.complete(rtt);
      });

      for (var i = 0; i < probes; i++) {
        final pending = Completer<int?>();
        active = pending;
        t0 = DateTime.now().millisecondsSinceEpoch;
        socket.send(bytes, address, discoveryPort);

        final rtt = await pending.future.timeout(
          Duration(milliseconds: perProbeTimeoutMs),
          onTimeout: () => null,
        );

        if (rtt != null && (minRtt == null || rtt < minRtt)) minRtt = rtt;
        // Early exit: LAN-like latency confirmed, no need for more probes.
        if (minRtt != null && minRtt < 5) break;
        if (i < probes - 1) {
          await Future.delayed(Duration(milliseconds: intervalMs));
        }
      }

      socket.close();
      return minRtt;
    } catch (_) {
      return null;
    }
  }

  static Future<List<InternetAddress>> _candidateAddresses(
    String? cachedHost,
  ) async {
    final addresses = <InternetAddress>[];
    final seen = <String>{};

    void add(String value) {
      final address = _parseProbeAddress(value);
      if (address != null && seen.add(address.address)) {
        addresses.add(address);
      }
    }

    void addSubnetCandidates(String value) {
      final address = InternetAddress.tryParse(value);
      if (address == null || address.type != InternetAddressType.IPv4) {
        return;
      }
      if (!_shouldScanSubnet(address.address)) return;

      final parts = address.address.split('.');
      if (parts.length != 4) return;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

      // Tethering and hotspot hosts are usually the subnet gateway. Probe the
      // likely gateway and directed broadcast before falling back to a /24 scan.
      add('$prefix.1');
      add('$prefix.254');
      add('$prefix.255');
      for (var last = 1; last <= 254; last++) {
        final candidate = '$prefix.$last';
        if (candidate == address.address) continue;
        add(candidate);
      }
    }

    final cached = cachedHost?.trim();
    if (cached != null && cached.isNotEmpty) {
      final cachedAddress = _parseProbeAddress(cached);
      if (cachedAddress != null) {
        add(cachedAddress.address);
        addSubnetCandidates(cachedAddress.address);
      }
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          addSubnetCandidates(address.address);
        }
      }
    } catch (_) {
      // Interface enumeration is best-effort; static tether gateways below still
      // cover common hotspot defaults.
    }

    for (final gateway in const [
      '192.168.137.1', // Windows Mobile Hotspot / ICS
      '192.168.43.1',  // common Android hotspot
      '192.168.42.129', // common Android USB tether gateway
      '172.20.10.1',   // common iPhone personal hotspot
    ]) {
      add(gateway);
    }

    return addresses;
  }

  static InternetAddress? _parseProbeAddress(String value) {
    final address = InternetAddress.tryParse(value.trim());
    if (address == null || address.type != InternetAddressType.IPv4) {
      return null;
    }
    if (!_isUsableEndpointHost(address.address)) return null;
    return address;
  }

  static bool _isUsableEndpointHost(String? value) {
    if (value == null) return false;
    final address = InternetAddress.tryParse(value.trim());
    if (address == null || address.type != InternetAddressType.IPv4) {
      return false;
    }

    final octets = address.address.split('.').map(int.parse).toList();
    if (octets.length != 4) return false;

    final first = octets[0];
    final second = octets[1];
    final allZero = octets.every((octet) => octet == 0);
    final allOnes = octets.every((octet) => octet == 255);
    final multicastOrReserved = first >= 224;
    final loopback = first == 127;
    final linkLocal = first == 169 && second == 254;

    return !allZero &&
        !allOnes &&
        !multicastOrReserved &&
        !loopback &&
        !linkLocal;
  }

  static bool _isLanEndpointHost(String? value) {
    if (!_isUsableEndpointHost(value)) return false;
    return _shouldScanSubnet(value!.trim());
  }

  static bool _isTailscaleEndpointHost(String? value) {
    if (!_isUsableEndpointHost(value)) return false;
    final address = InternetAddress.tryParse(value!.trim());
    if (address == null || address.type != InternetAddressType.IPv4) {
      return false;
    }
    final octets = address.address.split('.').map(int.parse).toList();
    return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
  }

  static bool _shouldScanSubnet(String value) {
    final address = InternetAddress.tryParse(value);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return false;
    }
    final octets = address.address.split('.').map(int.parse).toList();
    final first = octets[0];
    final second = octets[1];
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }
}

class _EndpointSelection {
  const _EndpointSelection({
    required this.host,
    required this.transport,
    this.fallbackHost,
    this.fallbackTransport,
  });

  final String host;
  final String transport;
  final String? fallbackHost;
  final String? fallbackTransport;
}

class _HostCandidate {
  const _HostCandidate({required this.host, required this.transport});
  final String host;
  final String transport;
}

class _ProbeResult {
  const _ProbeResult({required this.candidate, required this.rtt});
  final _HostCandidate candidate;
  final int? rtt;
}
