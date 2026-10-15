import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/l10n/failure_text.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/models/bandix_device.dart';
import 'package:luci_mobile/models/router_capabilities.dart';
import 'package:luci_mobile/services/bandix_service.dart';
import 'package:luci_mobile/state/app_state_provider.dart';
import 'package:luci_mobile/state/feature_providers.dart';
import 'package:luci_mobile/utils/format_bytes.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/widgets/luci_feature_gate.dart';
import 'package:luci_mobile/widgets/luci_loading_states.dart';

final bandixServiceProvider = Provider<BandixService>((ref) {
  return BandixService();
});

final bandixSnapshotProvider = FutureProvider<BandixSnapshot>((ref) async {
  final session = ref.watch(sessionProvider);
  final service = ref.watch(bandixServiceProvider);
  final api = ref.watch(apiServiceProvider);
  if (session == null) {
    return BandixSnapshot(
      metrics: const BandixMetrics(),
      devices: const [],
      timestamp: DateTime.now(),
    );
  }
  return service.fetchSnapshot(session, api: api);
}, retry: (_, _) => null);

enum BandixSortMode { liveSpeed, totalTraffic }

/// Real-time bandwidth monitoring screen powered by Bandix on port 8686.
class TrafficScreen extends ConsumerStatefulWidget {
  const TrafficScreen({super.key});

  @override
  ConsumerState<TrafficScreen> createState() => _TrafficScreenState();
}

class _TrafficScreenState extends ConsumerState<TrafficScreen> {
  Timer? _pollingTimer;
  BandixSortMode _sortMode = BandixSortMode.liveSpeed;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (_searchQuery != _searchController.text) {
        setState(() => _searchQuery = _searchController.text);
      }
    });

    // Auto-refresh bandwidth stats every 2 seconds while this screen is active
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      ref.invalidate(bandixSnapshotProvider);
    });
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final gate = ref.watch(featureProvider(RouterFeature.trafficAccounting));
    final snapshotAsync = ref.watch(bandixSnapshotProvider);

    return Scaffold(
      appBar: LuciAppBar(title: l10n.trafficHistory, showBack: true),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(bandixSnapshotProvider),
        child: snapshotAsync.when(
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          loading: () => const Padding(
            padding: EdgeInsets.all(LuciSpacing.md),
            child: Column(
              children: [
                LuciCardSkeleton(contentLines: 3),
                SizedBox(height: LuciSpacing.md),
                Expanded(child: LuciCardSkeleton(contentLines: 6)),
              ],
            ),
          ),
          error: (error, _) => LuciMessageState(
            message: gate.explain(context) ?? apiErrorText(context, error),
            action: l10n.retry,
            onAction: () => ref.invalidate(bandixSnapshotProvider),
          ),
          data: (snapshot) {
            final filteredDevices = snapshot.devices.where((d) {
              if (_searchQuery.isEmpty) return true;
              final q = _searchQuery.toLowerCase();
              return d.ip.toLowerCase().contains(q) ||
                  d.mac.toLowerCase().contains(q) ||
                  (d.hostname != null && d.hostname!.toLowerCase().contains(q));
            }).toList();

            filteredDevices.sort((a, b) {
              if (_sortMode == BandixSortMode.liveSpeed) {
                return b.totalRate.compareTo(a.totalRate);
              } else {
                return b.totalBytes.compareTo(a.totalBytes);
              }
            });

            return Column(
              children: [
                // Top WAN Bandwidth Summary Card
                _WanMetricsHeader(metrics: snapshot.metrics),
                // Search & Sort Bar
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LuciSpacing.md,
                    vertical: LuciSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: l10n.clientSearchHint,
                            prefixIcon: const Icon(Icons.search, size: 20),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 18),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _searchQuery = '');
                                    },
                                    tooltip: l10n.clearSearch,
                                  )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: LuciSpacing.sm),
                      SegmentedButton<BandixSortMode>(
                        segments: const [
                          ButtonSegment(
                            value: BandixSortMode.liveSpeed,
                            icon: Icon(Icons.speed, size: 16),
                            tooltip: 'Kecepatan Live',
                          ),
                          ButtonSegment(
                            value: BandixSortMode.totalTraffic,
                            icon: Icon(Icons.data_usage, size: 16),
                            tooltip: 'Total Kuota',
                          ),
                        ],
                        selected: {_sortMode},
                        onSelectionChanged: (selected) {
                          setState(() => _sortMode = selected.first);
                        },
                        showSelectedIcon: false,
                        style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // Device List
                Expanded(
                  child: filteredDevices.isEmpty
                      ? LuciMessageState(
                          message: _searchQuery.isEmpty
                              ? l10n.trafficNoRecords
                              : l10n.noMatchingClients,
                        )
                      : _DeviceList(
                          devices: filteredDevices,
                          sortMode: _sortMode,
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WanMetricsHeader extends StatelessWidget {
  const _WanMetricsHeader({required this.metrics});

  final BandixMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;

    return Padding(
      padding: const EdgeInsets.all(LuciSpacing.md),
      child: LuciCardStyles.standardCardWrapper(
        context: context,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.wifi_tethering, color: scheme.primary, size: 20),
                    const SizedBox(width: LuciSpacing.sm),
                    Text(
                      'Bandix Bandwidth Live',
                      style: LuciTextStyles.cardTitle(context),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Live (2s)',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: LuciSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _rateColumn(
                    context,
                    label: l10n.download,
                    rate: '${formatBytes(metrics.downloadRate)}/s',
                    total: formatBytes(metrics.downloadTotal),
                    color: Colors.teal,
                    icon: Icons.arrow_downward,
                  ),
                ),
                Container(
                  width: 1,
                  height: 48,
                  color: scheme.surfaceContainerHighest,
                ),
                Expanded(
                  child: _rateColumn(
                    context,
                    label: l10n.upload,
                    rate: '${formatBytes(metrics.uploadRate)}/s',
                    total: formatBytes(metrics.uploadTotal),
                    color: Colors.deepOrange,
                    icon: Icons.arrow_upward,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _rateColumn(
    BuildContext context, {
    required String label,
    required String rate,
    required String total,
    required Color color,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LuciSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            rate,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            'Total: $total',
            style: LuciTextStyles.cardSubtitle(context),
          ),
        ],
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.devices, required this.sortMode});

  final List<BandixDevice> devices;
  final BandixSortMode sortMode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final maxMetric = sortMode == BandixSortMode.liveSpeed
        ? (devices.isEmpty ? 1 : devices.first.totalRate)
        : (devices.isEmpty ? 1 : devices.first.totalBytes);

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: devices.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final device = devices[i];
        final ratio = maxMetric > 0
            ? (sortMode == BandixSortMode.liveSpeed
                    ? device.totalRate
                    : device.totalBytes) /
                maxMetric
            : 0.0;

        return ListTile(
          key: ValueKey(device.mac.isNotEmpty ? device.mac : device.ip),
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer.withValues(alpha: 0.3),
            child: Icon(
              Icons.devices,
              color: scheme.primary,
              size: 20,
            ),
          ),
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  device.displayName,
                  style: LuciTextStyles.cardTitle(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                sortMode == BandixSortMode.liveSpeed
                    ? '${formatBytes(device.totalRate)}/s'
                    : formatBytes(device.totalBytes),
                style: LuciTextStyles.cardTitle(context).copyWith(
                  color: sortMode == BandixSortMode.liveSpeed && device.totalRate > 0
                      ? Colors.teal
                      : null,
                ),
              ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${device.ip} · ${device.mac}',
                style: LuciTextStyles.cardSubtitle(context),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(
                    '↓ ${formatBytes(device.downloadRate)}/s',
                    style: TextStyle(
                      fontSize: 11,
                      color: device.downloadRate > 0 ? Colors.teal : Colors.grey,
                      fontWeight: device.downloadRate > 0 ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '↑ ${formatBytes(device.uploadRate)}/s',
                    style: TextStyle(
                      fontSize: 11,
                      color: device.uploadRate > 0 ? Colors.deepOrange : Colors.grey,
                      fontWeight: device.uploadRate > 0 ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${l10n.download}: ${formatBytes(device.downloadTotal)}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
