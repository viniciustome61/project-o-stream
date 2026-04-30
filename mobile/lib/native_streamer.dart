import 'dart:async';

import 'package:flutter/services.dart';

import 'stream_config.dart';

class NativeStreamer {
  NativeStreamer._();

  static const MethodChannel _methods = MethodChannel('project_o_stream/native');
  static const EventChannel _events = EventChannel('project_o_stream/events');

  static Stream<Map<String, Object?>> get events {
    return _events.receiveBroadcastStream().map((event) {
      return Map<String, Object?>.from(event as Map);
    });
  }

  static Future<void> initialize() async {
    await _methods.invokeMethod<void>('initialize');
  }

  static Future<void> startPreview() async {
    await _methods.invokeMethod<void>('startPreview');
  }

  static Future<void> stopPreview() async {
    await _methods.invokeMethod<void>('stopPreview');
  }

  static Future<void> startStream(SenderConfig config) async {
    await _methods.invokeMethod<void>('startStream', config.toJson());
  }

  static Future<void> stopStream() async {
    await _methods.invokeMethod<void>('stopStream');
  }

  static Future<void> switchCamera() async {
    await _methods.invokeMethod<void>('switchCamera');
  }

  static Future<void> setTorch(bool enabled) async {
    await _methods.invokeMethod<void>('setTorch', {'enabled': enabled});
  }

  static Future<void> setZoom(double value) async {
    await _methods.invokeMethod<void>('setZoom', {'value': value});
  }
}
