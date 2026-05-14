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
    lens: 'back',
    latencyMs: 80,
    autoReconnect: true,
    keepScreenOn: true,
    showSafeAreaGrid: false,
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
    if (host == null || host.isEmpty) {
      return;
    }
    setState(() {
      _config = _config.copyWith(host: host, port: port ?? _config.port);
    });
  }

  Future<void> _saveHost(String value, int port) async {
    final host = value.trim();
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
      _scheduleAutoConnect(const Duration(seconds: 2));
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
    setState(() => _status = 'Searching receiver');
    final receiver = await ReceiverDiscovery.find(cachedHost: _config.host);
    if (receiver == null) return;
    _receiver = receiver;
    await _saveHost(receiver.host, receiver.srtPort);
    setState(() => _status = 'Receiver ${receiver.label}');
  }

  void _handleNativeEvent(Map<String, Object?> event) {
    _dbg('native event: $event');
    final nextLive = event['live'] == true;
    setState(() {
      _status = event['status']?.toString() ?? _status;
      _stats = event['stats']?.toString() ?? _stats;
      _live = nextLive;
    });
    if (!nextLive && _config.autoReconnect) {
      _scheduleAutoConnect();
    }
  }

  void _scheduleAutoConnect([Duration delay = const Duration(seconds: 2)]) {
    _autoConnectTimer?.cancel();
    _autoConnectTimer = Timer(delay, () {
      if (!mounted || _live || _busy) return;
      unawaited(_ensureLive());
    });
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
        _scheduleAutoConnect();
        return;
      }
      await camera.release();
      await NativeStreamer.initialize();
      await NativeStreamer.startStream(_config);
      setState(() {
        _live = true;
        _status = 'Live';
      });
    } catch (error) {
      setState(() => _status = 'Stream error: $error');
      if (_config.autoReconnect) {
        _scheduleAutoConnect();
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _switchCamera() async {
    if (_busy) return;
    try {
      if (_live) {
        await NativeStreamer.switchCamera();
      } else {
        await context.read<CameraState>().switchCamera();
      }
      setState(() {
        _torch = false;
        _status = 'Camera switched';
      });
    } catch (error) {
      setState(() => _status = 'Camera switch failed: $error');
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
                  capabilities: _capabilities,
                  version: AppMetadata.version,
                  onVersionTap: () {
                    _versionTaps++;
                    if (_versionTaps >= 5) {
                      _versionTaps = 0;
                      setState(() => _showDebug = !_showDebug);
                    }
                  },
                ),
                const Spacer(),
                if (_config.showSafeAreaGrid)
                  const Expanded(child: _CompositionGrid()),
                _SettingsPanel(
                  config: _config,
                  receiver: _receiver,
                  capabilities: _capabilities,
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
                  onLatencyChanged: (value) => setState(() {
                    _config = _config.copyWith(latencyMs: value.round());
                  }),
                  onKeepScreenOnChanged: (value) async {
                    await NativeStreamer.setKeepScreenOn(value);
                    setState(
                        () => _config = _config.copyWith(keepScreenOn: value));
                  },
                  onGridChanged: (value) => setState(() {
                    _config = _config.copyWith(showSafeAreaGrid: value);
                  }),
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
    required this.capabilities,
    required this.version,
    required this.onVersionTap,
  });

  final String status;
  final bool live;
  final String stats;
  final Map<String, Object?> capabilities;
  final String version;
  final VoidCallback onVersionTap;

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
              GestureDetector(
                onTap: onVersionTap,
                child: Text(version,
                    style: Theme.of(context).textTheme.labelMedium),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _CapabilityChip(
                  label: 'SRT Transport', enabled: capabilities['srt'] == true),
              _CapabilityChip(
                  label: 'HEVC', enabled: capabilities['hevc'] == true),
              _CapabilityChip(
                  label: 'Torch', enabled: capabilities['torch'] == true),
              _CapabilityChip(
                  label: 'Native Preview',
                  enabled: capabilities['preview'] == true),
            ],
          ),
        ],
      ),
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label, required this.enabled});

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: (enabled ? Colors.green : Colors.white)
            .withValues(alpha: enabled ? .2 : .1),
        borderRadius: BorderRadius.circular(999),
        border:
            Border.all(color: enabled ? Colors.greenAccent : Colors.white24),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: enabled ? Colors.greenAccent : Colors.white54,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CompositionGrid extends StatelessWidget {
  const _CompositionGrid();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _GridPainter(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .22)
      ..strokeWidth = 1;
    for (final x in [size.width / 3, size.width * 2 / 3]) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (final y in [size.height / 3, size.height * 2 / 3]) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.config,
    required this.receiver,
    required this.capabilities,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onDiscover,
    required this.onProfileChanged,
    required this.onCodecChanged,
    required this.onMicrophoneChanged,
    required this.onLatencyChanged,
    required this.onKeepScreenOnChanged,
    required this.onGridChanged,
  });

  final SenderConfig config;
  final DiscoveredReceiver? receiver;
  final Map<String, Object?> capabilities;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final Future<void> Function() onDiscover;
  final ValueChanged<StreamProfile> onProfileChanged;
  final ValueChanged<bool> onCodecChanged;
  final ValueChanged<bool> onMicrophoneChanged;
  final ValueChanged<double> onLatencyChanged;
  final ValueChanged<bool> onKeepScreenOnChanged;
  final ValueChanged<bool> onGridChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: EdgeInsets.fromLTRB(14, 10, 10, expanded ? 14 : 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .58),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    receiver == null
                        ? 'Receiver: searching'
                        : 'Receiver: ${receiver!.label}',
                    maxLines: expanded ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: () => unawaited(onDiscover()),
                  icon: const Icon(Icons.radar),
                  tooltip: 'Discover receiver',
                ),
                IconButton.filledTonal(
                  onPressed: onToggleExpanded,
                  icon: Icon(
                    expanded ? Icons.keyboard_arrow_down : Icons.settings,
                  ),
                  tooltip: expanded ? 'Minimize settings' : 'Show settings',
                ),
              ],
            ),
            if (!expanded)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${config.profile.name} | ${config.latencyMs} ms | ${config.useHevc ? 'HEVC' : 'H.264'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Colors.white60),
                ),
              ),
            if (expanded) ...[
              if (receiver != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    receiver!.details,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.white70),
                  ),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<StreamProfile>(
                initialValue: config.profile,
                decoration: const InputDecoration(labelText: 'Stream profile'),
                items: [
                  for (final profile in profiles)
                    DropdownMenuItem(
                      value: profile,
                      child: Text('${profile.name} - ${profile.description}'),
                    ),
                ],
                onChanged: (profile) {
                  if (profile != null) onProfileChanged(profile);
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('HEVC'),
                      value: config.useHevc,
                      onChanged: onCodecChanged,
                    ),
                  ),
                  Expanded(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Mic'),
                      value: config.microphone,
                      onChanged: onMicrophoneChanged,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text('SRT latency'),
                  Expanded(
                    child: Slider(
                      value: config.latencyMs.toDouble(),
                      min: 40,
                      max: 240,
                      divisions: 10,
                      label: '${config.latencyMs} ms',
                      onChanged: onLatencyChanged,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('Keep screen awake'),
                    selected: config.keepScreenOn,
                    onSelected: onKeepScreenOnChanged,
                  ),
                  FilterChip(
                    label: const Text('Rule-of-thirds grid'),
                    selected: config.showSafeAreaGrid,
                    onSelected: onGridChanged,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Platform: ${capabilities['platform'] ?? 'unknown'} | Transport: ${capabilities['transportStatus'] ?? 'checking'}',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Colors.white60),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
