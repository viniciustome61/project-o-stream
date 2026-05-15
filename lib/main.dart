import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_metadata.dart';
import 'camera_state.dart';
import 'discovery.dart';
import 'native_streamer.dart';
import 'stream_config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const StreamApp());
}

class StreamApp extends StatelessWidget {
  const StreamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => CameraState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: Colors.black,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xffe5383b),
            brightness: Brightness.dark,
          ),
        ),
        home: const SenderScreen(),
      ),
    );
  }
}

class SenderScreen extends StatefulWidget {
  const SenderScreen({super.key});

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> {
  SenderConfig _config = const SenderConfig(
    host: '',
    port: 7070,
    profile: quality4k30,
    useHevc: false,
    microphone: true,
    lens: 'wide',
    latencyMs: 80,
    autoReconnect: true,
    keepScreenOn: true,
  );

  StreamSubscription<Map<String, Object?>>? _events;
  bool _live = false;
  bool _busy = true;
  bool _torch = false;
  double _zoom = 1;
  String _status = 'Starting camera';
  String _stats = '';
  Map<String, Object?> _capabilities = const {};
  DiscoveredReceiver? _receiver;
  Timer? _autoConnectTimer;
  bool _previewStarted = false;
  bool _useNativePreview = true;
  final Completer<void> _firstFrameReady = Completer<void>();
  static const _minAutoReconnectDelay = Duration(seconds: 2);
  static const _maxAutoReconnectDelay = Duration(seconds: 15);
  Duration _autoReconnectDelay = _minAutoReconnectDelay;

  // ── debug overlay ──────────────────────────────────────────────
  final List<String> _log = [];
  bool _showDebug = false;
  bool _settingsExpanded = true;
  int _versionTaps = 0;

  void _dbg(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    // ignore: avoid_print
    debugPrint('[PO-dart $ts] $msg');
    if (mounted) setState(() => _log.add('$ts $msg'));
  }
  // ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_firstFrameReady.isCompleted) {
        _firstFrameReady.complete();
      }
      unawaited(NativeStreamer.markFlutterRendered().catchError((error) {
        _dbg('flutterRendered signal failed: $error');
      }));
    });
    _events = NativeStreamer.events.listen(_handleNativeEvent);
    _boot();
  }

  @override
  void dispose() {
    _autoConnectTimer?.cancel();
    _events?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final saved = await NativeStreamer.loadSavedEndpoint();
    final host = saved['host'] as String?;
    final port = saved['port'] as int?;
    if (!ReceiverDiscovery.isUsableEndpointHost(host)) {
      return;
    }
    setState(() {
      _config = _config.copyWith(host: host, port: port ?? _config.port);
    });
  }

  Future<void> _saveHost(String value, int port) async {
    final host = value.trim();
    if (!ReceiverDiscovery.isUsableEndpointHost(host)) {
      _dbg('Ignoring invalid receiver host: $host');
      return;
    }
    await NativeStreamer.saveEndpoint(host: host, port: port);
    setState(() => _config = _config.copyWith(host: host, port: port));
  }

  Future<void> _boot() async {
    _dbg('_boot() start');
    try {
      await _load();
      _capabilities = await NativeStreamer.getCapabilities();
      _dbg('capabilities: $_capabilities');
      await NativeStreamer.setKeepScreenOn(_config.keepScreenOn);
      await _startPreviewWhenReady();
      await _discover();
      setState(() {
        _busy = false;
        _status = _receiver == null ? 'Searching receiver' : 'Receiver ready';
      });
      if (_config.autoReconnect) {
        _scheduleAutoConnect(const Duration(seconds: 2));
      }
      _dbg('boot complete. status=$_status');
    } catch (error) {
      _dbg('boot ERROR: $error');
      setState(() {
        _busy = false;
        _status = 'Camera unavailable: $error';
      });
    }
  }

  Future<void> _startPreviewWhenReady() async {
    if (_previewStarted) return;
    setState(() => _status = 'Starting preview');

    if (_capabilities['preview'] == true) {
      try {
        await _waitForFirstFrame();
        await NativeStreamer.startPreview();
        _previewStarted = true;
        return;
      } catch (error) {
        _dbg('native preview ERROR: $error');
        if (mounted) {
          setState(() => _useNativePreview = false);
        }
      }
    } else {
      if (mounted) {
        setState(() => _useNativePreview = false);
      } else {
        _useNativePreview = false;
      }
    }

    if (!mounted) return;
    final camera = context.read<CameraState>();
    await camera.initialize();
    _previewStarted = camera.isReady;
    if (!_previewStarted && camera.error != null) {
      setState(() => _status = 'Preview unavailable: ${camera.error}');
    }
  }

  Future<void> _discover() async {
    _dbg('Searching receiver...');
    setState(() => _status = 'Searching receiver');
    final DiscoveredReceiver? receiver;
    try {
      receiver = await ReceiverDiscovery.find(cachedHost: _config.host);
    } catch (error) {
      _dbg('Discovery error: $error');
      if (mounted) {
        setState(() => _status = 'Receiver discovery failed');
      }
      return;
    }
    final found = receiver;
    if (found == null) {
      _dbg('No receiver found.');
      return;
    }
    _receiver = found;
    _dbg('Receiver found: ${found.label}');
    await _saveHost(found.host, found.srtPort);
    if (!mounted) return;
    setState(() => _status = 'Receiver ${found.label}');
  }

  void _handleNativeEvent(Map<String, Object?> event) {
    _dbg('native event: $event');
    final nextLive = event['live'] == true;
    final status = event['status']?.toString();
    if (status != null) {
      _dbg('Status change: $status');
    }
    setState(() {
      _status = status ?? _status;
      _stats = event['stats']?.toString() ?? _stats;
      _live = nextLive;
    });
    if (nextLive) {
      _resetAutoReconnectDelay();
    }
    if (!nextLive && _config.autoReconnect && status != 'Connecting') {
      _scheduleAutoConnect();
    }
  }

  void _scheduleAutoConnect([Duration? delay]) {
    final retryDelay = delay ?? _autoReconnectDelay;
    _autoConnectTimer?.cancel();
    _dbg('Auto reconnect in ${retryDelay.inSeconds}s');
    _autoConnectTimer = Timer(retryDelay, () {
      if (!mounted || _live || _busy) return;
      unawaited(_ensureLive());
    });
  }

  void _resetAutoReconnectDelay() {
    _autoReconnectDelay = _minAutoReconnectDelay;
  }

  void _increaseAutoReconnectDelay() {
    final nextSeconds = (_autoReconnectDelay.inSeconds * 2)
        .clamp(
          _minAutoReconnectDelay.inSeconds,
          _maxAutoReconnectDelay.inSeconds,
        )
        .toInt();
    _autoReconnectDelay = Duration(seconds: nextSeconds);
  }

  List<String> get _availableLensIds {
    final raw = _capabilities['lenses'];
    final ids = <String>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map && item['id'] is String) {
          ids.add(item['id'] as String);
        } else if (item is String) {
          ids.add(item);
        }
      }
    }
    if (ids.isEmpty) {
      ids.addAll(const ['ultraWide', 'wide', 'telephoto', 'front']);
    }
    if (!ids.contains(_config.lens)) {
      ids.insert(0, _config.lens);
    }
    return ids.toSet().toList(growable: false);
  }

  String _lensLabel(String lens) {
    return switch (lens) {
      'ultraWide' => '0.5x Ultra',
      'telephoto' => 'Tele',
      'front' => 'Front',
      _ => '1x Wide',
    };
  }

  void _setAutoReconnect(bool value) {
    setState(() {
      _config = _config.copyWith(autoReconnect: value);
      _status = value ? 'Auto reconnect on' : 'Auto reconnect off';
    });
    if (!value) {
      _autoConnectTimer?.cancel();
      return;
    }
    _resetAutoReconnectDelay();
    if (!_live && !_busy) {
      _scheduleAutoConnect();
    }
  }

  Future<void> _waitForFirstFrame() async {
    if (_firstFrameReady.isCompleted) return;
    try {
      await _firstFrameReady.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _dbg('first Flutter frame wait timed out; continuing auto-connect');
    }
  }

  Future<void> _ensureLive() async {
    if (_busy || _live) return;
    final camera = context.read<CameraState>();
    setState(() => _busy = true);
    try {
      await _waitForFirstFrame();
      if (_receiver == null) {
        await _discover();
      }
      if (_receiver == null) {
        setState(() => _status = 'No receiver found');
        if (_config.autoReconnect) {
          _increaseAutoReconnectDelay();
          _scheduleAutoConnect();
        }
        return;
      }
      await camera.release();
      await NativeStreamer.initialize();
      await NativeStreamer.startStream(_config);
      setState(() {
        _live = true;
        _status = 'Live';
      });
      _resetAutoReconnectDelay();
    } catch (error) {
      String msg = error.toString();
      if (error is PlatformException) {
        msg = error.message ?? error.code;
      }
      _dbg('Stream error: $msg');
      setState(() => _status = 'Stream error: $msg');
      if (_config.autoReconnect) {
        _increaseAutoReconnectDelay();
        _scheduleAutoConnect();
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _switchCamera() async {
    if (_busy) return;
    final lenses = _availableLensIds;
    final current = lenses.indexOf(_config.lens);
    final next = lenses[(current + 1) % lenses.length];
    await _setLens(next);
  }

  Future<void> _setLens(String lens) async {
    if (_busy) return;
    final previousLens = _config.lens;
    try {
      if (_useNativePreview || _live) {
        await NativeStreamer.setLens(lens);
      } else {
        await context.read<CameraState>().setLens(lens);
      }
      setState(() {
        _config = _config.copyWith(lens: lens);
        _torch = false;
        _zoom = 1;
        _status = 'Lens ${_lensLabel(lens)}';
      });
    } catch (error) {
      setState(() {
        _config = _config.copyWith(lens: previousLens);
        _status = 'Lens switch failed: $error';
      });
    }
  }

  Future<void> _toggleTorch() async {
    if (_busy) return;
    final next = !_torch;
    try {
      if (_live) {
        await NativeStreamer.setTorch(next);
      } else {
        await context.read<CameraState>().setTorch(next);
      }
      setState(() {
        _torch = next;
        _status = next ? 'Torch on' : 'Torch off';
      });
    } catch (error) {
      setState(() {
        _torch = false;
        _status = 'Torch failed: $error';
      });
    }
  }

  Future<void> _setZoom(double value) async {
    setState(() => _zoom = value);
    try {
      if (_live) {
        await NativeStreamer.setZoom(value);
      } else {
        await context.read<CameraState>().setZoom(value);
      }
    } catch (error) {
      setState(() => _status = 'Zoom failed: $error');
    }
  }

  Future<void> _capturePhoto() async {
    if (_busy || _live) return;
    await context.read<CameraState>().captureAndSave();
    if (!mounted) return;
    final error = context.read<CameraState>().error;
    setState(
      () => _status = error == null ? 'Photo saved' : 'Photo failed: $error',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff101820),
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(color: Color(0xff101820)),
            ),
          ),
          Positioned.fill(
            child: NativeCameraPreview(enabled: _useNativePreview),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: .55),
                    Colors.transparent,
                    Colors.black.withValues(alpha: .75),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  status: _status,
                  live: _live,
                  stats: _stats,
                  version: AppMetadata.version,
                  onLogTap: () => setState(() => _showDebug = !_showDebug),
                  onVersionTap: () {
                    _versionTaps++;
                    if (_versionTaps >= 5) {
                      _versionTaps = 0;
                      setState(() => _showDebug = !_showDebug);
                    }
                  },
                ),
                const Spacer(),
                _SettingsPanel(
                  config: _config,
                  receiver: _receiver,
                  capabilities: _capabilities,
                  availableLensIds: _availableLensIds,
                  expanded: _settingsExpanded,
                  onToggleExpanded: () {
                    setState(() => _settingsExpanded = !_settingsExpanded);
                  },
                  onDiscover: () async {
                    await _discover();
                    await _ensureLive();
                  },
                  onProfileChanged: (profile) => setState(() {
                    _config = _config.copyWith(
                        profile: profile,
                        latencyMs: profile.recommendedLatencyMs);
                  }),
                  onCodecChanged: (value) => setState(() {
                    _config = _config.copyWith(useHevc: value);
                  }),
                  onMicrophoneChanged: (value) => setState(() {
                    _config = _config.copyWith(microphone: value);
                  }),
                  onLensChanged: (lens) => unawaited(_setLens(lens)),
                  onLatencyChanged: (value) => setState(() {
                    _config = _config.copyWith(latencyMs: value.round());
                  }),
                  onAutoReconnectChanged: _setAutoReconnect,
                  onKeepScreenOnChanged: (value) async {
                    await NativeStreamer.setKeepScreenOn(value);
                    setState(
                        () => _config = _config.copyWith(keepScreenOn: value));
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton.filledTonal(
                        onPressed:
                            _busy ? null : () => unawaited(_switchCamera()),
                        icon: const Icon(Icons.cameraswitch),
                      ),
                      _AutoConnectStatus(
                        busy: _busy,
                        live: _live,
                        receiver: _receiver,
                      ),
                      IconButton.filledTonal(
                        onPressed:
                            _busy ? null : () => unawaited(_toggleTorch()),
                        icon: Icon(_torch ? Icons.flash_on : Icons.flash_off),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  onPressed:
                      _busy || _live ? null : () => unawaited(_capturePhoto()),
                  icon: const Icon(Icons.photo_camera),
                  tooltip: 'Capture photo',
                ),
                Slider(
                  value: _zoom,
                  min: 1,
                  max: 8,
                  divisions: 28,
                  label: '${_zoom.toStringAsFixed(1)}x',
                  onChanged: (value) => unawaited(_setZoom(value)),
                ),
              ],
            ),
          ),
          // ── debug overlay ─────────────────────────────────────
          if (_showDebug)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _showDebug = false),
                child: Container(
                  color: Colors.black.withValues(alpha: .88),
                  padding: const EdgeInsets.all(12),
                  child: SafeArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('DEBUG LOG  (tap anywhere to close)',
                            style: TextStyle(
                                color: Colors.yellow,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                        const SizedBox(height: 6),
                        Expanded(
                          child: ListView.builder(
                            reverse: true,
                            itemCount: _log.length,
                            itemBuilder: (_, i) => Text(
                              _log[_log.length - 1 - i],
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                  fontFamily: 'monospace'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // ──────────────────────────────────────────────────────
        ],
      ),
    );
  }
}

class _AutoConnectStatus extends StatelessWidget {
  const _AutoConnectStatus({
    required this.busy,
    required this.live,
    required this.receiver,
  });

  final bool busy;
  final bool live;
  final DiscoveredReceiver? receiver;

  @override
  Widget build(BuildContext context) {
    final color = live
        ? Colors.greenAccent
        : receiver == null
            ? Colors.orangeAccent
            : Colors.lightBlueAccent;
    final icon = live
        ? Icons.sensors
        : receiver == null
            ? Icons.radar
            : Icons.sync;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: .48),
        border: Border.all(color: color, width: 3),
      ),
      child: busy
          ? Padding(
              padding: const EdgeInsets.all(20),
              child: CircularProgressIndicator(strokeWidth: 3, color: color),
            )
          : Icon(icon, color: color, size: 30),
    );
  }
}

class FlutterCameraPreview extends StatelessWidget {
  const FlutterCameraPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<CameraState>(
      builder: (context, camera, _) {
        final controller = camera.controller;
        if (controller != null && controller.value.isInitialized) {
          return CameraPreview(controller);
        }

        final message = camera.error ??
            (camera.isInitializing ? 'Starting camera' : 'Camera preview');
        return ColoredBox(
          color: const Color(0xff101820),
          child: Center(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        );
      },
    );
  }
}

class NativeCameraPreview extends StatelessWidget {
  const NativeCameraPreview({required this.enabled, super.key});

  static const _viewType = 'project_o_stream/preview';
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (enabled && defaultTargetPlatform == TargetPlatform.iOS) {
      return const UiKitView(viewType: _viewType);
    }
    if (enabled && defaultTargetPlatform == TargetPlatform.android) {
      return const AndroidView(viewType: _viewType);
    }
    return const FlutterCameraPreview();
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.status,
    required this.live,
    required this.stats,
    required this.version,
    required this.onVersionTap,
    required this.onLogTap,
  });

  final String status;
  final bool live;
  final String stats;
  final String version;
  final VoidCallback onVersionTap;
  final VoidCallback onLogTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: live ? Colors.greenAccent : Colors.orangeAccent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  stats.isEmpty ? status : '$status  $stats',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onLogTap,
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  backgroundColor: Colors.white10,
                ),
                child: const Text('LOG',
                    style: TextStyle(fontSize: 10, color: Colors.white70)),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: onVersionTap,
                child: Text(version,
                    style: Theme.of(context).textTheme.labelMedium),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.config,
    required this.receiver,
    required this.capabilities,
    required this.availableLensIds,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onDiscover,
    required this.onProfileChanged,
    required this.onCodecChanged,
    required this.onMicrophoneChanged,
    required this.onLensChanged,
    required this.onLatencyChanged,
    required this.onAutoReconnectChanged,
    required this.onKeepScreenOnChanged,
  });

  final SenderConfig config;
  final DiscoveredReceiver? receiver;
  final Map<String, Object?> capabilities;
  final List<String> availableLensIds;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final Future<void> Function() onDiscover;
  final ValueChanged<StreamProfile> onProfileChanged;
  final ValueChanged<bool> onCodecChanged;
  final ValueChanged<bool> onMicrophoneChanged;
  final ValueChanged<String> onLensChanged;
  final ValueChanged<double> onLatencyChanged;
  final ValueChanged<bool> onAutoReconnectChanged;
  final ValueChanged<bool> onKeepScreenOnChanged;

  @override
  Widget build(BuildContext context) {
    final maxPanelHeight = MediaQuery.sizeOf(context).height * .46;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .65),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .4),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.fastOutSlowIn,
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: expanded ? maxPanelHeight : 140,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              physics: expanded
                  ? const BouncingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(context),
                  if (!expanded) _buildMiniStatus(context),
                  if (expanded) ...[
                    const Divider(height: 22, color: Colors.white10),
                    _buildSectionTitle('QUALITY'),
                    _buildProfileSelector(),
                    const SizedBox(height: 12),
                    _buildSectionTitle('LENS'),
                    _buildLensSelector(),
                    const SizedBox(height: 12),
                    _buildSectionTitle('TRANSPORT'),
                    _buildLatencySlider(),
                    const SizedBox(height: 12),
                    _buildSectionTitle('HARDWARE'),
                    _buildHardwareToggles(),
                    const SizedBox(height: 12),
                    _buildSectionTitle('SYSTEM'),
                    _buildSystemToggles(),
                    const SizedBox(height: 12),
                    _buildCapabilitiesFooter(context),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (receiver != null ? Colors.greenAccent : Colors.white10)
                .withValues(alpha: .1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            receiver != null ? Icons.lan : Icons.lan_outlined,
            size: 18,
            color: receiver != null ? Colors.greenAccent : Colors.white38,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                receiver == null
                    ? 'Searching for receiver'
                    : receiver!.hostname,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  letterSpacing: 0.2,
                ),
              ),
              Text(
                receiver == null ? 'UDP 7071/7072' : receiver!.host,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => unawaited(onDiscover()),
          icon: const Icon(Icons.refresh, size: 20),
          visualDensity: VisualDensity.compact,
          color: Colors.white54,
          tooltip: 'Discover',
        ),
        const SizedBox(width: 4),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onToggleExpanded,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                expanded ? Icons.expand_less : Icons.tune,
                size: 20,
                color: Colors.white70,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMiniStatus(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          _StatusChip(
              label: config.profile.name,
              icon: Icons.video_camera_back_outlined),
          const SizedBox(width: 8),
          _StatusChip(label: _lensLabel(config.lens), icon: Icons.camera),
          const SizedBox(width: 8),
          _StatusChip(
              label: '${config.latencyMs}ms', icon: Icons.timer_outlined),
        ],
      ),
    );
  }

  String _lensLabel(String lens) {
    return switch (lens) {
      'ultraWide' => '0.5x',
      'telephoto' => 'Tele',
      'front' => 'Front',
      _ => '1x',
    };
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: const TextStyle(
            color: Colors.white24,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildProfileSelector() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .03),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: profiles.map((p) {
            final selected = config.profile.name == p.name;
            return Padding(
              padding: EdgeInsets.only(right: p == profiles.last ? 0 : 8),
              child: ChoiceChip(
                selected: selected,
                showCheckmark: false,
                label: Text('${p.name}  ${p.bitrate ~/ 1000000}M'),
                labelStyle: TextStyle(
                  color: selected ? Colors.white : Colors.white60,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                ),
                selectedColor: Colors.redAccent.withValues(alpha: .28),
                backgroundColor: Colors.white.withValues(alpha: .04),
                side: BorderSide(
                  color: selected
                      ? Colors.redAccent.withValues(alpha: .5)
                      : Colors.white10,
                ),
                onSelected: (_) => onProfileChanged(p),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildLensSelector() {
    final lenses = availableLensIds.contains(config.lens)
        ? availableLensIds
        : [config.lens, ...availableLensIds];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .03),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: lenses.map((lens) {
            final selected = config.lens == lens;
            return Padding(
              padding: EdgeInsets.only(right: lens == lenses.last ? 0 : 8),
              child: ChoiceChip(
                selected: selected,
                showCheckmark: false,
                avatar: Icon(
                  _lensIcon(lens),
                  size: 15,
                  color: selected ? Colors.white : Colors.white38,
                ),
                label: Text(_lensName(lens)),
                labelStyle: TextStyle(
                  color: selected ? Colors.white : Colors.white60,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                ),
                selectedColor: Colors.redAccent.withValues(alpha: .28),
                backgroundColor: Colors.white.withValues(alpha: .04),
                side: BorderSide(
                  color: selected
                      ? Colors.redAccent.withValues(alpha: .5)
                      : Colors.white10,
                ),
                onSelected: (_) => onLensChanged(lens),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  String _lensName(String lens) {
    return switch (lens) {
      'ultraWide' => '0.5x Ultra',
      'telephoto' => 'Telephoto',
      'front' => 'Front',
      _ => '1x Wide',
    };
  }

  IconData _lensIcon(String lens) {
    return switch (lens) {
      'ultraWide' => Icons.panorama_wide_angle,
      'telephoto' => Icons.center_focus_strong,
      'front' => Icons.face,
      _ => Icons.camera,
    };
  }

  Widget _buildLatencySlider() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .03),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('SRT Buffer Latency', style: TextStyle(fontSize: 12)),
              Text(
                '${config.latencyMs} ms',
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Colors.redAccent,
              inactiveTrackColor: Colors.white10,
              thumbColor: Colors.redAccent,
            ),
            child: Slider(
              value: config.latencyMs.toDouble(),
              min: 40,
              max: 240,
              divisions: 20,
              onChanged: onLatencyChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHardwareToggles() {
    return Row(
      children: [
        Expanded(
          child: _ToggleTile(
            label: 'HEVC / H.265',
            value: config.useHevc,
            onChanged: onCodecChanged,
            icon: Icons.high_quality,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ToggleTile(
            label: 'Audio Input',
            value: config.microphone,
            onChanged: onMicrophoneChanged,
            icon: Icons.mic,
          ),
        ),
      ],
    );
  }

  Widget _buildSystemToggles() {
    return Row(
      children: [
        Expanded(
          child: _ToggleTile(
            label: 'Auto Reconnect',
            value: config.autoReconnect,
            onChanged: onAutoReconnectChanged,
            icon: Icons.sync,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ToggleTile(
            label: 'Keep Awake',
            value: config.keepScreenOn,
            onChanged: onKeepScreenOnChanged,
            icon: Icons.brightness_6_outlined,
          ),
        ),
      ],
    );
  }

  Widget _buildCapabilitiesFooter(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .02),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '${capabilities['device'] ?? 'Device'} • ${capabilities['os'] ?? 'OS'} • SRT/HEVC Ready',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white24,
          fontSize: 10,
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white38),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.icon,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: value
                  ? Colors.redAccent.withValues(alpha: .3)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: value ? Colors.redAccent : Colors.white24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: value ? Colors.white : Colors.white60,
                  ),
                ),
              ),
              Transform.scale(
                scale: .72,
                alignment: Alignment.centerRight,
                child: Switch.adaptive(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: Colors.redAccent,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
