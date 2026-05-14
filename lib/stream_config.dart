import 'package:flutter/foundation.dart';

@immutable
class StreamProfile {
  const StreamProfile({
    required this.name,
    required this.description,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrate,
    required this.audioBitrate,
    required this.recommendedLatencyMs,
  });

  final String name;
  final String description;
  final int width;
  final int height;
  final int fps;
  final int bitrate;
  final int audioBitrate;
  final int recommendedLatencyMs;

  Map<String, Object> toJson() => {
        'name': name,
        'description': description,
        'width': width,
        'height': height,
        'fps': fps,
        'bitrate': bitrate,
        'audioBitrate': audioBitrate,
        'recommendedLatencyMs': recommendedLatencyMs,
      };
}

const battery720p30 = StreamProfile(
  name: '720p30',
  description: 'Battery-safe preview and setup mode',
  width: 720,
  height: 1280,
  fps: 30,
  bitrate: 6 * 1000 * 1000,
  audioBitrate: 96 * 1000,
  recommendedLatencyMs: 120,
);

const stable1080p30 = StreamProfile(
  name: '1080p30',
  description: 'Stable default for Wi-Fi and long sessions',
  width: 1080,
  height: 1920,
  fps: 30,
  bitrate: 12 * 1000 * 1000,
  audioBitrate: 128 * 1000,
  recommendedLatencyMs: 100,
);

const balanced1440p30 = StreamProfile(
  name: '1440p30',
  description: 'Sharper stream without 4K bandwidth pressure',
  width: 1440,
  height: 2560,
  fps: 30,
  bitrate: 24 * 1000 * 1000,
  audioBitrate: 128 * 1000,
  recommendedLatencyMs: 90,
);

const quality4k30 = StreamProfile(
  name: '4K30',
  description: 'High-detail default for strong Wi-Fi',
  width: 2160,
  height: 3840,
  fps: 30,
  bitrate: 50 * 1000 * 1000,
  audioBitrate: 128 * 1000,
  recommendedLatencyMs: 80,
);

const experimental4k60 = StreamProfile(
  name: '4K60',
  description: 'Maximum motion quality, requires excellent network',
  width: 2160,
  height: 3840,
  fps: 60,
  bitrate: 90 * 1000 * 1000,
  audioBitrate: 128 * 1000,
  recommendedLatencyMs: 120,
);

const profiles = [
  battery720p30,
  stable1080p30,
  balanced1440p30,
  quality4k30,
  experimental4k60
];

@immutable
class SenderConfig {
  const SenderConfig({
    required this.host,
    required this.port,
    required this.profile,
    required this.useHevc,
    required this.microphone,
    required this.lens,
    required this.latencyMs,
    required this.autoReconnect,
    required this.keepScreenOn,
  });

  final String host;
  final int port;
  final StreamProfile profile;
  final bool useHevc;
  final bool microphone;
  final String lens;
  final int latencyMs;
  final bool autoReconnect;
  final bool keepScreenOn;

  String get srtUrl => 'srt://$host:$port';

  SenderConfig copyWith({
    String? host,
    int? port,
    StreamProfile? profile,
    bool? useHevc,
    bool? microphone,
    String? lens,
    int? latencyMs,
    bool? autoReconnect,
    bool? keepScreenOn,
  }) {
    return SenderConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      profile: profile ?? this.profile,
      useHevc: useHevc ?? this.useHevc,
      microphone: microphone ?? this.microphone,
      lens: lens ?? this.lens,
      latencyMs: latencyMs ?? this.latencyMs,
      autoReconnect: autoReconnect ?? this.autoReconnect,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    );
  }

  Map<String, Object> toJson() => {
        'host': host,
        'port': port,
        'profile': profile.toJson(),
        'useHevc': useHevc,
        'microphone': microphone,
        'lens': lens,
        'latencyMs': latencyMs,
        'autoReconnect': autoReconnect,
        'keepScreenOn': keepScreenOn,
      };
}
