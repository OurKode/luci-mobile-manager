import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:luci_mobile/models/bandix_device.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/state/router_session.dart';

/// Client for Bandix bandwidth monitoring via LuCI ubus RPC and fallback REST port 8686.
class BandixService {
  BandixService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 4),
                sendTimeout: const Duration(seconds: 4),
                headers: {'Connection': 'close'},
                validateStatus: (status) =>
                    status != null && status >= 200 && status < 300,
              ),
            );

  final Dio _dio;

  static const int port = 8686;

  /// Builds a URL for Bandix REST API on port 8686.
  static String _url(String ipAddress, String path) {
    var cleanHost = ipAddress.trim();
    if (cleanHost.startsWith('http://')) {
      cleanHost = cleanHost.substring(7);
    } else if (cleanHost.startsWith('https://')) {
      cleanHost = cleanHost.substring(8);
    }
    if (cleanHost.contains(':')) {
      cleanHost = cleanHost.split(':').first;
    }
    return 'http://$cleanHost:$port$path';
  }

  /// Checks whether Bandix is responsive either via ubus or REST on port 8686.
  Future<bool> isAvailable(
    String ipAddress, {
    IApiService? api,
    RouterSession? session,
  }) async {
    if (session != null && api != null && !session.reviewerMode) {
      try {
        final res = await api.call(
          session.ipAddress,
          session.sysauth,
          session.useHttps,
          object: 'luci.bandix',
          method: 'getStatus',
          params: {},
        );
        if (res != null) return true;
      } catch (_) {}
    }

    try {
      final res = await _dio.get<dynamic>(
        _url(ipAddress, '/api/traffic/devices'),
        options: Options(
          headers: {'Connection': 'close'},
          receiveTimeout: const Duration(seconds: 2),
          sendTimeout: const Duration(seconds: 2),
        ),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Fetches real-time devices and aggregated WAN metrics from Bandix.
  Future<BandixSnapshot> fetchSnapshot(
    RouterSession session, {
    IApiService? api,
  }) async {
    if (session.reviewerMode) {
      return _mockSnapshot();
    }

    // 1. Try ubus RPC luci.bandix (standard LuCI session path)
    if (api != null) {
      try {
        final results = await Future.wait([
          api.call(
            session.ipAddress,
            session.sysauth,
            session.useHttps,
            object: 'luci.bandix',
            method: 'getStatus',
            params: {},
          ),
          api.call(
            session.ipAddress,
            session.sysauth,
            session.useHttps,
            object: 'luci.bandix',
            method: 'getMetrics',
            params: {},
          ),
        ]);

        final statusRes = results[0];
        final metricsRes = results[1];
        final devices = _parseDevices(statusRes);
        final metrics = _parseMetrics(metricsRes, devices);

        if (devices.isNotEmpty || metrics.totalRate > 0 || metrics.totalBytes > 0) {
          return BandixSnapshot(
            metrics: metrics,
            devices: devices,
            timestamp: DateTime.now(),
          );
        }
      } catch (e) {
        debugPrint('BandixService: ubus luci.bandix failed: $e, falling back to HTTP:8686');
      }
    }

    // 2. Fallback to direct HTTP on port 8686
    final ip = session.ipAddress;
    final (devicesRaw, metricsRaw) = await (
      _fetchDevicesRaw(ip),
      _fetchMetricsRaw(ip),
    ).wait;

    final devices = _parseDevices(devicesRaw);
    final metrics = _parseMetrics(metricsRaw, devices);

    return BandixSnapshot(
      metrics: metrics,
      devices: devices,
      timestamp: DateTime.now(),
    );
  }

  Future<dynamic> _fetchDevicesRaw(String ip) async {
    try {
      final res = await _dio.get<dynamic>(
        _url(ip, '/api/traffic/devices'),
        options: Options(headers: {'Connection': 'close'}),
      );
      return res.data;
    } catch (e) {
      debugPrint('BandixService: Failed to fetch devices via HTTP: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchMetricsRaw(String ip) async {
    try {
      final res = await _dio.get<dynamic>(
        _url(ip, '/api/traffic/metrics'),
        options: Options(headers: {'Connection': 'close'}),
      );
      final data = res.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return null;
    } catch (_) {
      return null;
    }
  }

  List<BandixDevice> _parseDevices(dynamic raw) {
    if (raw == null) return const [];
    final list = <BandixDevice>[];

    dynamic data;
    if (raw is List) {
      if (raw.length > 1 && raw[0] == 0) {
        // [status, data] ubus envelope
        return _parseDevices(raw[1]);
      }
      data = raw;
    } else if (raw is Map) {
      data = raw['devices'] ?? raw['items'];
      if (data == null && raw['data'] != null) {
        if (raw['data'] is Map) {
          data = raw['data']['devices'] ?? raw['data']['items'];
        } else if (raw['data'] is List) {
          data = raw['data'];
        }
      }
    }

    if (data is List) {
      for (final item in data) {
        if (item is Map) {
          list.add(BandixDevice.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    } else if (raw is Map) {
      // Map keyed by MAC or IP
      for (final entry in raw.entries) {
        if (entry.key == 'status' || entry.key == 'message' || entry.key == 'data') {
          continue;
        }
        if (entry.value is Map) {
          list.add(
            BandixDevice.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
              defaultKey: entry.key.toString(),
            ),
          );
        }
      }
    }

    return list;
  }

  BandixMetrics _parseMetrics(dynamic raw, List<BandixDevice> devices) {
    if (raw == null) return BandixMetrics.fromDevices(devices);
    if (raw is List && raw.length > 1 && raw[0] == 0) {
      return _parseMetrics(raw[1], devices);
    }
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      return BandixMetrics.fromJson(map);
    }
    return BandixMetrics.fromDevices(devices);
  }

  static BandixSnapshot _mockSnapshot() {
    final devices = [
      const BandixDevice(
        mac: 'AA:BB:CC:11:22:33',
        ip: '192.168.1.101',
        hostname: 'MacBook-Pro',
        uploadRate: 154000,
        downloadRate: 3420000,
        uploadTotal: 840000000,
        downloadTotal: 4890000000,
        connections: 42,
      ),
      const BandixDevice(
        mac: 'AA:BB:CC:22:33:44',
        ip: '192.168.1.102',
        hostname: 'iPhone-15',
        uploadRate: 48000,
        downloadRate: 1120000,
        uploadTotal: 210000000,
        downloadTotal: 1450000000,
        connections: 18,
      ),
      const BandixDevice(
        mac: 'AA:BB:CC:33:44:55',
        ip: '192.168.1.105',
        hostname: 'Smart-TV',
        uploadRate: 12000,
        downloadRate: 6800000,
        uploadTotal: 95000000,
        downloadTotal: 12400000000,
        connections: 8,
      ),
      const BandixDevice(
        mac: 'AA:BB:CC:44:55:66',
        ip: '192.168.1.108',
        hostname: 'HomePod-Mini',
        uploadRate: 3500,
        downloadRate: 18000,
        uploadTotal: 34000000,
        downloadTotal: 189000000,
        connections: 4,
      ),
    ];

    return BandixSnapshot(
      metrics: BandixMetrics.fromDevices(devices),
      devices: devices,
      timestamp: DateTime.now(),
    );
  }
}
