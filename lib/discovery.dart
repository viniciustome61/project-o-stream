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
      for (final address in _candidateAddresses(cachedHost)) {
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

    final lanCandidates = <String>[];
    final tailscaleCandidates = <String>[];

    void addLan(String? value) {
      final host = value?.trim();
      if (_isLanEndpointHost(host) && !lanCandidates.contains(host)) {
        lanCandidates.add(host!);
      }
    }

    void addTailscale(String? value) {
      final host = value?.trim();
      if (_isTailscaleEndpointHost(host) &&
          !tailscaleCandidates.contains(host)) {
        tailscaleCandidates.add(host!);
      }
    }

    addLan(datagramHost);
    addLan(lanIp);
    if (lanIps is List) {
      for (final candidate in lanIps) {
        addLan(candidate?.toString());
      }
    }
    addLan(payloadHost);

    addTailscale(tailscaleIp);
    addTailscale(payloadHost);
    addTailscale(datagramHost);

    for (final candidate in lanCandidates) {
      final reachedOverLan = candidate == datagramHost ||
          await _probeLan(candidate, timeout: const Duration(milliseconds: 450));
      if (reachedOverLan) {
        final fallback = _firstCandidate(tailscaleCandidates);
        return _EndpointSelection(
          host: candidate,
          transport: 'lan',
          fallbackHost: fallback,
          fallbackTransport: fallback == null ? null : 'tailscale',
        );
      }
    }

    final tailscaleHost = _firstCandidate(tailscaleCandidates);
    if (tailscaleHost != null) {
      return _EndpointSelection(
        host: tailscaleHost,
        transport: 'tailscale',
      );
    }

    final directHost = _firstUsableHost([payloadHost, datagramHost]);
    if (directHost == null) return null;
    return _EndpointSelection(
      host: directHost,
      transport: _transportForHost(directHost),
    );
  }

  static String? _firstCandidate(List<String> values) {
    return values.isEmpty ? null : values.first;
  }

  static String? _firstUsableHost(Iterable<String?> values) {
    for (final value in values) {
      final host = value?.trim();
      if (_isUsableEndpointHost(host)) return host;
    }
    return null;
  }

  static String _transportForHost(String host) {
    if (_isTailscaleEndpointHost(host)) return 'tailscale';
    if (_isLanEndpointHost(host)) return 'lan';
    return 'srt';
  }

  // Sends PROJECTO_STREAM_LAN_PROBE to the server's LAN IP and waits for ACK.
  // Used to decide whether to route SRT over LAN instead of Tailscale.
  static Future<bool> _probeLan(
    String ip, {
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    try {
      final socket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final lanCompleter = Completer<bool>();
      final timer = Timer(timeout, () {
        if (!lanCompleter.isCompleted) lanCompleter.complete(false);
      });
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        if (dg.address.address == ip && !lanCompleter.isCompleted) {
          final msg = utf8.decode(dg.data, allowMalformed: true);
          if (msg == _lanAck) lanCompleter.complete(true);
        }
      });
      socket.send(
        utf8.encode(_lanProbe),
        InternetAddress(ip),
        discoveryPort,
      );
      final result = await lanCompleter.future;
      timer.cancel();
      socket.close();
      return result;
    } catch (_) {
      return false;
    }
  }

  static Iterable<InternetAddress> _candidateAddresses(
    String? cachedHost,
  ) sync* {
    final cached = cachedHost?.trim();
    if (cached != null && cached.isNotEmpty) {
      final cachedAddress = _parseProbeAddress(cached);
      if (cachedAddress == null) return;

      yield cachedAddress;
      // Scan the same /24 subnet as the cached host.
      final parts = cachedAddress.address.split('.');
      if (_shouldScanSubnet(cachedAddress.address) && parts.length == 4) {
        final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
        for (var last = 1; last <= 254; last++) {
          final candidate = '$prefix.$last';
          if (candidate == cachedAddress.address) continue;
          final address = _parseProbeAddress(candidate);
          if (address != null) yield address;
        }
      }
    }
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
