import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

class FullscreenSession extends ChangeNotifier {
  bool active = false;
  bool _closed = false;
  Future<void>? _pending;
  Future<void>? _closing;
  Future<void> toggle() {
    if (_closed || _pending != null) return _pending ?? Future.value();
    _pending = _toggle().whenComplete(() => _pending = null);
    return _pending!;
  }

  Future<void> _toggle() async {
    if (active) {
      await defaultExitNativeFullscreen();
      active = false;
    } else {
      await defaultEnterNativeFullscreen();
      active = true;
    }
    if (!_closed) notifyListeners();
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    return _closing = _restore();
  }

  Future<void> _restore() async {
    await _pending;
    if (active) {
      await defaultExitNativeFullscreen();
      active = false;
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
