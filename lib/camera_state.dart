import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraState extends ChangeNotifier with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  CameraLensDirection _lensDirection = CameraLensDirection.back;
  bool _initializing = false;
  bool _capturing = false;
  String? _error;
  double _zoom = 1;
  double _minZoom = 1;
  double _maxZoom = 1;
  FlashMode _flashMode = FlashMode.off;
  bool _observingLifecycle = false;

  CameraController? get controller => _controller;
  bool get isReady => _controller?.value.isInitialized == true;
  bool get isInitializing => _initializing;
  bool get isCapturing => _capturing;
  String? get error => _error;
  double get zoom => _zoom;
  double get maxZoom => _maxZoom;
  bool get torchEnabled => _flashMode == FlashMode.torch;

  Future<void> initialize() async {
    if (_initializing || isReady) return;
    _initializing = true;
    _error = null;
    notifyListeners();

    try {
      final cameraStatus = await Permission.camera.request();
      if (!cameraStatus.isGranted) {
        throw CameraException('permission_denied', 'Camera permission denied');
      }

      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        throw CameraException('no_camera', 'No camera found on this device');
      }

      await _openCamera(_selectCamera(_lensDirection));
      _startObservingLifecycle();
    } catch (error) {
      _error = error.toString();
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> release() async {
    _stopObservingLifecycle();
    await _disposeController();
  }

  Future<void> switchCamera() async {
    if (_cameras.length < 2) return;
    _lensDirection = _lensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    await _openCamera(_selectCamera(_lensDirection));
  }

  Future<void> setTorch(bool enabled) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _flashMode = enabled ? FlashMode.torch : FlashMode.off;
    await controller.setFlashMode(_flashMode);
    notifyListeners();
  }

  Future<void> setZoom(double value) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _zoom = value.clamp(_minZoom, _maxZoom).toDouble();
    await controller.setZoomLevel(_zoom);
    notifyListeners();
  }

  Future<void> captureAndSave() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }

    _capturing = true;
    notifyListeners();
    try {
      final image = await controller.takePicture();
      final directory = await getApplicationDocumentsDirectory();
      final captures = Directory('${directory.path}/captures');
      await captures.create(recursive: true);
      final fileName = 'project_o_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final saved = await File(image.path).copy('${captures.path}/$fileName');
      await Gal.putImage(saved.path, album: 'Project O Stream');
    } catch (error) {
      _error = error.toString();
    } finally {
      _capturing = false;
      notifyListeners();
    }
  }

  Future<void> _openCamera(CameraDescription camera) async {
    final previous = _controller;
    _controller = null;
    notifyListeners();
    await previous?.dispose();

    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await controller.initialize();
    _controller = controller;
    _minZoom = await controller.getMinZoomLevel();
    _maxZoom = await controller.getMaxZoomLevel();
    _zoom = _minZoom;
    _flashMode = FlashMode.off;
    await controller.setFlashMode(_flashMode);
    await controller.setZoomLevel(_zoom);
  }

  CameraDescription _selectCamera(CameraLensDirection direction) {
    return _cameras.firstWhere(
      (camera) => camera.lensDirection == direction,
      orElse: () => _cameras.first,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_disposeController());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(initialize());
    }
  }

  @override
  void dispose() {
    _stopObservingLifecycle();
    _controller?.dispose();
    super.dispose();
  }

  void _startObservingLifecycle() {
    if (_observingLifecycle) return;
    WidgetsBinding.instance.addObserver(this);
    _observingLifecycle = true;
  }

  void _stopObservingLifecycle() {
    if (!_observingLifecycle) return;
    WidgetsBinding.instance.removeObserver(this);
    _observingLifecycle = false;
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    notifyListeners();
    await controller?.dispose();
  }
}
