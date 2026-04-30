import 'package:flutter/foundation.dart';

@immutable
class StreamProfile {
  const StreamProfile({
    required this.name,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrate,
    required this.audioBitrate,
  });

  final String name;
  final int width;
  final int height;
  final int fps;
  final int bitrate;
  final int audioBitrate;

  Map<String, Object> toJson() => {
        'name': name,
        'width': width,
        'height': height,
        'fps': fps,
        'bitrate': bitrate,
        'audioBitrate': audioBitrate,
      };
}

const stable1080p30 = StreamProfile(
  name: '1080p30',
  width: 1080,
  height: 1920,
  fps: 30,
  bitrate: 12 * 1000 * 1000,
  audioBitrate: 128 * 1000,
);

const quality4k30 = StreamProfile(
  name: '4K30',
  width: 2160,
  height: 3840,
  fps: 30,
  bitrate: 50 * 1000 * 1000,
  audioBitrate: 128 * 1000,
);

const experimental4k60 = StreamProfile(
  name: '4K60',
  width: 2160,
  height: 3840,
  fps: 60,
  bitrate: 90 * 1000 * 1000,
  audioBitrate: 128 * 1000,
);

const profiles = [stable1080p30, quality4k30, experimental4k60];

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
  });

  final String host;
  final int port;
  final StreamProfile profile;
  final bool useHevc;
  final bool microphone;
  final String lens;
  final int latencyMs;

  String get srtUrl => 'srt://$host:$port';

  SenderConfig copyWith({
    String? host,
    int? port,
    StreamProfile? profile,
    bool? useHevc,
    bool? microphone,
    String? lens,
    int? latencyMs,
  }) {
    return SenderConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      profile: profile ?? this.profile,
      useHevc: useHevc ?? this.useHevc,
      microphone: microphone ?? this.microphone,
      lens: lens ?? this.lens,
      latencyMs: latencyMs ?? this.latencyMs,
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
      };
}
