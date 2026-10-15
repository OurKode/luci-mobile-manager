import 'package:flutter/foundation.dart';

/// One device's real-time and cumulative traffic measured by Bandix.
@immutable
class BandixDevice {
  const BandixDevice({
    required this.mac,
    required this.ip,
    this.hostname,
    this.uploadRate = 0,
    this.downloadRate = 0,
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.connections = 0,
  });

  final String mac;
  final String ip;
  final String? hostname;

  /// Current upload speed in bytes per second.
  final int uploadRate;

  /// Current download speed in bytes per second.
  final int downloadRate;

  /// Total cumulative uploaded bytes.
  final int uploadTotal;

  /// Total cumulative downloaded bytes.
  final int downloadTotal;

  /// Active connection count.
  final int connections;

  int get totalRate => uploadRate + downloadRate;
  int get totalBytes => uploadTotal + downloadTotal;

  String get displayName {
    if (hostname != null && hostname!.isNotEmpty && hostname != 'Unknown') {
      return hostname!;
    }
    if (ip.isNotEmpty && ip != 'N/A') return ip;
    return mac;
  }

  factory BandixDevice.fromJson(Map<String, dynamic> json, {String? defaultKey}) {
    final mac = json['mac']?.toString() ??
        json['mac_address']?.toString() ??
        (defaultKey != null && defaultKey.contains(':') ? defaultKey : '');
    final ip = json['ip']?.toString() ??
        json['ip_address']?.toString() ??
        (defaultKey != null && !defaultKey.contains(':') ? defaultKey : '');
    final name = json['name']?.toString() ??
        json['hostname']?.toString() ??
        json['host']?.toString();

    int parseNum(dynamic value) {
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    final upRate = parseNum(
      json['total_tx_rate'] ??
          json['wide_tx_rate'] ??
          json['upload_speed'] ??
          json['upload_rate'] ??
          json['tx_speed'] ??
          json['tx_rate'] ??
          json['tx_bytes_per_sec'],
    );
    final downRate = parseNum(
      json['total_rx_rate'] ??
          json['wide_rx_rate'] ??
          json['download_speed'] ??
          json['download_rate'] ??
          json['rx_speed'] ??
          json['rx_rate'] ??
          json['rx_bytes_per_sec'],
    );

    final upTotal = parseNum(
      json['total_tx_bytes'] ??
          json['wide_tx_bytes'] ??
          json['upload_total'] ??
          json['total_upload'] ??
          json['tx_bytes'] ??
          json['total_tx'],
    );
    final downTotal = parseNum(
      json['total_rx_bytes'] ??
          json['wide_rx_bytes'] ??
          json['download_total'] ??
          json['total_download'] ??
          json['rx_bytes'] ??
          json['total_rx'],
    );

    final conns = parseNum(
      json['connections'] ??
          json['active_connections'] ??
          json['conns'] ??
          json['tcp_connections'],
    );

    return BandixDevice(
      mac: mac,
      ip: ip,
      hostname: name,
      uploadRate: upRate,
      downloadRate: downRate,
      uploadTotal: upTotal,
      downloadTotal: downTotal,
      connections: conns,
    );
  }
}

/// Aggregated WAN metrics reported by Bandix.
@immutable
class BandixMetrics {
  const BandixMetrics({
    this.uploadRate = 0,
    this.downloadRate = 0,
    this.uploadTotal = 0,
    this.downloadTotal = 0,
  });

  final int uploadRate;
  final int downloadRate;
  final int uploadTotal;
  final int downloadTotal;

  int get totalRate => uploadRate + downloadRate;
  int get totalBytes => uploadTotal + downloadTotal;

  factory BandixMetrics.fromJson(Map<String, dynamic> json) {
    int parseNum(dynamic value) {
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    Map<String, dynamic> source = json;
    if (json['metrics'] is List && (json['metrics'] as List).isNotEmpty) {
      final last = (json['metrics'] as List).last;
      if (last is Map<String, dynamic>) {
        source = last;
      } else if (last is Map) {
        source = Map<String, dynamic>.from(last);
      }
    } else if (json['data'] is Map) {
      final data = json['data'] as Map;
      if (data['metrics'] is List && (data['metrics'] as List).isNotEmpty) {
        final last = (data['metrics'] as List).last;
        if (last is Map) source = Map<String, dynamic>.from(last);
      }
    }

    return BandixMetrics(
      uploadRate: parseNum(
        source['total_tx_rate'] ??
            source['wide_tx_rate'] ??
            source['upload_speed'] ??
            source['total_upload_speed'] ??
            source['upload_rate'] ??
            source['tx_rate'],
      ),
      downloadRate: parseNum(
        source['total_rx_rate'] ??
            source['wide_rx_rate'] ??
            source['download_speed'] ??
            source['total_download_speed'] ??
            source['download_rate'] ??
            source['rx_rate'],
      ),
      uploadTotal: parseNum(
        source['total_tx_bytes'] ??
            source['wide_tx_bytes'] ??
            source['upload_total'] ??
            source['total_upload_bytes'] ??
            source['tx_bytes'] ??
            source['total_tx'],
      ),
      downloadTotal: parseNum(
        source['total_rx_bytes'] ??
            source['wide_rx_bytes'] ??
            source['download_total'] ??
            source['total_download_bytes'] ??
            source['rx_bytes'] ??
            source['total_rx'],
      ),
    );
  }

  /// Calculates aggregate metrics from a device list when /api/traffic/metrics is absent.
  factory BandixMetrics.fromDevices(List<BandixDevice> devices) {
    var upRate = 0;
    var downRate = 0;
    var upTotal = 0;
    var downTotal = 0;

    for (final d in devices) {
      upRate += d.uploadRate;
      downRate += d.downloadRate;
      upTotal += d.uploadTotal;
      downTotal += d.downloadTotal;
    }

    return BandixMetrics(
      uploadRate: upRate,
      downloadRate: downRate,
      uploadTotal: upTotal,
      downloadTotal: downTotal,
    );
  }
}

/// Composite snapshot containing both metrics and device list.
@immutable
class BandixSnapshot {
  const BandixSnapshot({
    required this.metrics,
    required this.devices,
    required this.timestamp,
  });

  final BandixMetrics metrics;
  final List<BandixDevice> devices;
  final DateTime timestamp;
}
