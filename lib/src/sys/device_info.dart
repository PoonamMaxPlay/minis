import 'package:flutter/services.dart';

class DeviceInfoData {
  final String model;
  final String os;
  final String osVersion;
  final int ramMb;
  final String gpu;
  final List<String> codecs;
  final Map<String, Object?> hdrCapabilities;
  final int sdkInt;
  final String machine;
  final bool isPhysicalDevice;
  const DeviceInfoData({
    required this.model,
    required this.os,
    required this.osVersion,
    required this.ramMb,
    required this.gpu,
    required this.codecs,
    required this.hdrCapabilities,
    this.sdkInt = 0,
    this.machine = '',
    this.isPhysicalDevice = true,
  });

  factory DeviceInfoData.fromMap(Map<String, Object?> m) => DeviceInfoData(
    model: (m['model'] as String?) ?? '',
    os: (m['os'] as String?) ?? '',
    osVersion: (m['osVersion'] as String?) ?? '',
    ramMb: (m['ramMb'] as num?)?.toInt() ?? 0,
    gpu: (m['gpu'] as String?) ?? '',
    codecs: ((m['codecs'] as List?) ?? const []).map((e) => e.toString()).toList(),
    hdrCapabilities: (m['hdrCapabilities'] as Map?)?.cast<String, Object?>() ?? const {},
    sdkInt: (m['sdkInt'] as num?)?.toInt() ?? 0,
    machine: (m['machine'] as String?) ?? '',
    isPhysicalDevice: (m['isPhysicalDevice'] as bool?) ?? true,
  );
}

class NativeDeviceInfo {
  NativeDeviceInfo._();
  static const _ch = MethodChannel('loopit/minis/device');
  static const _thermal = EventChannel('loopit/minis/device/thermal');

  static Future<DeviceInfoData> info() async {
    final r = await _ch.invokeMapMethod<String, Object?>('info');
    return DeviceInfoData.fromMap(r ?? const {});
  }

  static Future<String> thermal() async {
    final r = await _ch.invokeMapMethod<String, Object?>('thermal');
    return (r?['state'] as String?) ?? 'nominal';
  }

  static Future<Map<String, Object?>> battery() async {
    final r = await _ch.invokeMapMethod<String, Object?>('battery');
    return r ?? const {};
  }

  static Stream<String> thermalStream() =>
      _thermal.receiveBroadcastStream().map((e) => ((e as Map)['state'] as String?) ?? 'nominal');
}
