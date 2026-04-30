import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffe5383b),
          brightness: Brightness.dark,
        ),
      ),
      home: const SenderScreen(),
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
  );

  StreamSubscription<Map<String, Object?>>? _events;
  bool _live = false;
  bool _busy = true;
  bool _torch = false;
  double _zoom = 1;
  String _status = 'Starting camera';
  String _stats = '';
  DiscoveredReceiver? _receiver;

  @override
  void initState() {
    super.initState();
    _events = NativeStreamer.events.listen(_handleNativeEvent);
    _boot();
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('host');
    final port = prefs.getInt('port');
    if (host == null || host.isEmpty) {
      return;
    }
    setState(() {
      _config = _config.copyWith(host: host, port: port ?? _config.port);
    });
  }

  Future<void> _saveHost(String value, int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('host', value.trim());
    await prefs.setInt('port', port);
    setState(() => _config = _config.copyWith(host: value.trim(), port: port));
  }

  Future<void> _boot() async {
    try {
      await _load();
      await NativeStreamer.initialize();
      await NativeStreamer.startPreview();
      await _discover();
      setState(() {
        _busy = false;
        _status = _receiver == null ? 'Searching receiver' : 'Ready';
      });
    } catch (error) {
      setState(() {
        _busy = false;
        _status = 'Camera unavailable: $error';
      });
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
    setState(() {
      _status = event['status']?.toString() ?? _status;
      _stats = event['stats']?.toString() ?? _stats;
      _live = event['live'] == true;
    });
  }

  Future<void> _toggleLive() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_live) {
        await NativeStreamer.stopStream();
        setState(() {
          _live = false;
          _status = 'Ready';
        });
      } else {
        if (_receiver == null) {
          await _discover();
        }
        if (_receiver == null) {
          setState(() => _status = 'No receiver found');
          return;
        }
        await NativeStreamer.startStream(_config);
        setState(() {
          _live = true;
          _status = 'Live';
        });
      }
    } catch (error) {
      setState(() => _status = 'Stream error: $error');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: NativePreview()),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(.55),
                    Colors.transparent,
                    Colors.black.withOpacity(.75),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _TopBar(status: _status, live: _live, stats: _stats),
                const Spacer(),
                _SettingsPanel(
                  config: _config,
                  receiver: _receiver,
                  onDiscover: _discover,
                  onProfileChanged: (profile) => setState(() {
                    _config = _config.copyWith(profile: profile);
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
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton.filledTonal(
                        onPressed: _busy ? null : NativeStreamer.switchCamera,
                        icon: const Icon(Icons.cameraswitch),
                      ),
                      GestureDetector(
                        onTap: _toggleLive,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          width: 86,
                          height: 86,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _live ? Colors.black : Colors.red,
                            border: Border.all(
                              color: _live ? Colors.red : Colors.white,
                              width: 5,
                            ),
                          ),
                          child: _busy
                              ? const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: CircularProgressIndicator(strokeWidth: 3),
                                )
                              : null,
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: _busy
                            ? null
                            : () async {
                                final next = !_torch;
                                await NativeStreamer.setTorch(next);
                                setState(() => _torch = next);
                              },
                        icon: Icon(_torch ? Icons.flash_on : Icons.flash_off),
                      ),
                    ],
                  ),
                ),
                Slider(
                  value: _zoom,
                  min: 1,
                  max: 8,
                  divisions: 28,
                  label: '${_zoom.toStringAsFixed(1)}x',
                  onChanged: (value) async {
                    setState(() => _zoom = value);
                    await NativeStreamer.setZoom(value);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class NativePreview extends StatelessWidget {
  const NativePreview({super.key});

  @override
  Widget build(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.android:
        return const AndroidView(viewType: 'project_o_stream/preview');
      case TargetPlatform.iOS:
        return const UiKitView(viewType: 'project_o_stream/preview');
      default:
        return const ColoredBox(color: Colors.black);
    }
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.status, required this.live, required this.stats});

  final String status;
  final bool live;
  final String stats;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: live ? Colors.red : Colors.green,
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
        ],
      ),
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.config,
    required this.receiver,
    required this.onDiscover,
    required this.onProfileChanged,
    required this.onCodecChanged,
    required this.onMicrophoneChanged,
    required this.onLatencyChanged,
  });

  final SenderConfig config;
  final DiscoveredReceiver? receiver;
  final Future<void> Function() onDiscover;
  final ValueChanged<StreamProfile> onProfileChanged;
  final ValueChanged<bool> onCodecChanged;
  final ValueChanged<bool> onMicrophoneChanged;
  final ValueChanged<double> onLatencyChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.58),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  receiver == null ? 'Receiver: searching' : 'Receiver: ${receiver!.label}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: () => unawaited(onDiscover()),
                icon: const Icon(Icons.radar),
                tooltip: 'Discover receiver',
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<StreamProfile>(
            segments: [
              for (final profile in profiles)
                ButtonSegment(value: profile, label: Text(profile.name)),
            ],
            selected: {config.profile},
            onSelectionChanged: (selection) => onProfileChanged(selection.first),
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
        ],
      ),
    );
  }
}
