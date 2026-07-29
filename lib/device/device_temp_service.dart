import 'package:flutter/services.dart';

/// Thin wrapper around [DeviceTempBridge] (native, MainActivity.kt): the
/// battery's reported temperature, a permission-free proxy for device
/// thermal load. Feeds the top-left corner readout.
class DeviceTempService {
  DeviceTempService._();
  static final DeviceTempService instance = DeviceTempService._();

  static const _channel = MethodChannel('voidduck/device_temp');

  Future<double?> getBatteryTemperatureC() async {
    final result = await _channel.invokeMethod<double>('getBatteryTemperatureC');
    return result;
  }
}
