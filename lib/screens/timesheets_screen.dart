import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

class TimesheetsScreen extends StatefulWidget {
  const TimesheetsScreen({super.key});

  @override
  State<TimesheetsScreen> createState() => _TimesheetsScreenState();
}

class _TimesheetsScreenState extends State<TimesheetsScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  bool _isOwner = false;
  Map<String, dynamic>? _myActiveEntry;
  List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> _totals = [];
  List<Map<String, dynamic>> _teamProfiles = [];
  String? _error;

  // Clock timer
  Timer? _clockTimer;
  Duration _elapsed = Duration.zero;

  // Clock action
  bool _clockActionInProgress = false;

  // Filters (owner only)
  String? _filterUserId;
  DateTime? _filterStart;
  DateTime? _filterEnd;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final body = <String, dynamic>{};
      if (_filterStart != null) body['start_date'] = _filterStart!.toIso8601String().substring(0, 10);
      if (_filterEnd != null)   body['end_date']   = _filterEnd!.toIso8601String().substring(0, 10);
      if (_filterUserId != null) body['user_id_filter'] = _filterUserId;

      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-timesheets'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return;

      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to load timesheets');
      }

      setState(() {
        _isOwner       = data['is_owner'] as bool? ?? false;
        _myActiveEntry = data['my_active_entry'] as Map<String, dynamic>?;
        _entries       = List<Map<String, dynamic>>.from(data['entries'] as List? ?? []);
        _totals        = List<Map<String, dynamic>>.from(data['totals'] as List? ?? []);
        _teamProfiles  = List<Map<String, dynamic>>.from(data['team_profiles'] as List? ?? []);
      });
      _startOrStopTicker();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startOrStopTicker() {
    _clockTimer?.cancel();
    if (_myActiveEntry == null) {
      setState(() => _elapsed = Duration.zero);
      return;
    }
    final clockedInAt = DateTime.tryParse(_myActiveEntry!['clocked_in_at'] ?? '');
    if (clockedInAt == null) return;
    void tick() {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().toUtc().difference(clockedInAt.toUtc()));
    }
    tick();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<Position?> _getLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }
      if (permission == LocationPermission.deniedForever) return null;
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      debugPrint('Location error: $e');
      return null;
    }
  }

  Future<void> _toggleClock() async {
    setState(() => _clockActionInProgress = true);
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final action = _myActiveEntry == null ? 'clock_in' : 'clock_out';
      final position = await _getLocation();
      final body = <String, dynamic>{'action': action};
      if (position != null) {
        body['lat'] = position.latitude;
        body['lng'] = position.longitude;
      }

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/clock-in-out'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        final errCode = data['error'] as String?;
        if (errCode == 'location_required') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Location is required by your business. Please allow location access and try again.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 4),
              ),
            );
          }
          return;
        }
        throw Exception(data['error'] ?? 'Clock action failed');
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _clockActionInProgress = false);
    }
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatDuration(int? minutes) {
    if (minutes == null || minutes == 0) return '—';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  String _formatDateTime(String? raw) {
    if (raw == null) return '—';
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return '—';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day} · $h:$m $ampm';
  }

  Future<void> _pickDateFilter(bool isStart) async {
    final initial = isStart ? (_filterStart ?? DateTime.now()) : (_filterEnd ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (!mounted || picked == null) return;
    setState(() {
      if (isStart) _filterStart = picked;
      else         _filterEnd   = picked;
    });
    _load();
  }

  void _showEntryDetail(Map<String, dynamic> entry) {
    showDialog(
      context: context,
      builder: (_) => _TimeEntryDetailDialog(
        entry: entry,
        isOwner: _isOwner,
        onForceClockOut: () => _forceClockOut(entry['id'] as int),
      ),
    );
  }

  Future<void> _forceClockOut(int entryId) async {
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/force-clock-out'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'entry_id': entryId}),
      );
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to force clock out');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Team member clocked out.')),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        _buildTopBar(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.error)))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _buildClockCard(),
                        const SizedBox(height: 24),
                        if (_isOwner && _totals.isNotEmpty) ...[
                          _buildTotalsSection(),
                          const SizedBox(height: 24),
                        ],
                        if (_isOwner) _buildOwnerFilters(),
                        if (_isOwner) const SizedBox(height: 16),
                        _buildEntriesTable(),
                      ]),
                    ),
        ),
      ]),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(children: [
        const Text('Timesheets',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const Spacer(),
        IconButton(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 18, color: AppTheme.textSecondary),
          tooltip: 'Refresh',
        ),
      ]),
    );
  }

  Widget _buildClockCard() {
    final isClockedIn = _myActiveEntry != null;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isClockedIn ? AppTheme.success.withValues(alpha: 0.08) : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isClockedIn ? AppTheme.success.withValues(alpha: 0.4) : AppTheme.borderColor,
          width: isClockedIn ? 1.5 : 1,
        ),
      ),
      child: Row(children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            color: isClockedIn
                ? AppTheme.success.withValues(alpha: 0.15)
                : AppTheme.brand.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            isClockedIn ? Icons.timer : Icons.timer_outlined,
            size: 24,
            color: isClockedIn ? AppTheme.success : AppTheme.brand,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            isClockedIn ? 'Currently Clocked In' : 'Not Clocked In',
            style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700,
              color: isClockedIn ? AppTheme.success : AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          if (isClockedIn) ...[
            Text(
              _formatElapsed(_elapsed),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
            ),
            if ((_myActiveEntry!['appointment_id']) != null)
              const Text('On a scheduled job', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ] else
            const Text('Tap Clock In to start tracking your time',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ])),
        const SizedBox(width: 16),
        SizedBox(
          height: 44, width: 120,
          child: ElevatedButton.icon(
            onPressed: _clockActionInProgress ? null : _toggleClock,
            icon: _clockActionInProgress
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(isClockedIn ? Icons.stop_circle_outlined : Icons.play_circle_outline, size: 18),
            label: Text(isClockedIn ? 'Clock Out' : 'Clock In',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: isClockedIn ? AppTheme.error : AppTheme.brand,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildTotalsSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('TEAM SUMMARY',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary, letterSpacing: 1)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 12, runSpacing: 12,
        children: _totals.map((t) {
          final name    = t['full_name'] as String? ?? 'Unknown';
          final minutes = (t['total_minutes'] as num?)?.toInt() ?? 0;
          final count   = (t['entry_count'] as num?)?.toInt() ?? 0;
          final initials = name.trim().split(' ')
              .map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
          return Container(
            width: 180,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(children: [
              Container(
                width: 34, height: 34,
                decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(initials,
                    style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary), overflow: TextOverflow.ellipsis),
                Text(_formatDuration(minutes),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.brand)),
                Text('$count ${count == 1 ? 'entry' : 'entries'}',
                    style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
              ])),
            ]),
          );
        }).toList(),
      ),
    ]);
  }

  Widget _buildOwnerFilters() {
    final memberItems = [
      {'user_id': null, 'full_name': 'All Team Members'},
      ..._teamProfiles.where((p) => p['user_id'] != null).toList(),
    ];
    final selectedName = _filterUserId == null
        ? 'All Team Members'
        : (_teamProfiles.firstWhere(
            (p) => p['user_id'] == _filterUserId,
            orElse: () => {'full_name': 'All Team Members'},
          )['full_name'] as String? ?? 'All Team Members');

    return Row(children: [
      // Team member filter
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: DropdownButtonHideUnderline(child: DropdownButton<String?>(
          value: _filterUserId,
          dropdownColor: AppTheme.cardBg,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          hint: const Text('All Team Members', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
          items: memberItems.map((m) => DropdownMenuItem<String?>(
            value: m['user_id'] as String?,
            child: Text(m['full_name'] as String? ?? 'Unknown'),
          )).toList(),
          onChanged: (v) { setState(() => _filterUserId = v); _load(); },
        )),
      ),
      const SizedBox(width: 10),

      // Start date
      Clickable(
        onTap: () => _pickDateFilter(true),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _filterStart != null ? AppTheme.brand.withValues(alpha: 0.08) : AppTheme.cardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _filterStart != null ? AppTheme.brand.withValues(alpha: 0.4) : AppTheme.borderColor,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.calendar_today_outlined, size: 13, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(
              _filterStart == null ? 'Start Date' : _formatDate(_filterStart!),
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            ),
          ]),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Text('—', style: TextStyle(color: AppTheme.textSecondary)),
      ),

      // End date
      Clickable(
        onTap: () => _pickDateFilter(false),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _filterEnd != null ? AppTheme.brand.withValues(alpha: 0.08) : AppTheme.cardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _filterEnd != null ? AppTheme.brand.withValues(alpha: 0.4) : AppTheme.borderColor,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.calendar_today_outlined, size: 13, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(
              _filterEnd == null ? 'End Date' : _formatDate(_filterEnd!),
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            ),
          ]),
        ),
      ),

      // Clear filters
      if (_filterStart != null || _filterEnd != null || _filterUserId != null) ...[
        const SizedBox(width: 10),
        Clickable(
          onTap: () {
            setState(() { _filterStart = null; _filterEnd = null; _filterUserId = null; });
            _load();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.close, size: 13, color: AppTheme.textSecondary),
              SizedBox(width: 4),
              Text('Clear', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          ),
        ),
      ],
    ]);
  }

  String _formatDate(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  Widget _buildEntriesTable() {
    if (_entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.access_time_outlined, size: 48, color: AppTheme.textMuted),
          SizedBox(height: 12),
          Text('No time entries found', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
          SizedBox(height: 6),
          Text('Use the Clock In button to start tracking time.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        ])),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: Row(children: [
            if (_isOwner)
              const Expanded(flex: 3, child: Text('TEAM MEMBER',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 3, child: Text('CLOCKED IN',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 3, child: Text('CLOCKED OUT',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 2, child: Text('DURATION',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 2, child: Text('STATUS',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            if (_isOwner)
              const SizedBox(width: 24),
          ]),
        ),
        // Rows
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _entries.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
          itemBuilder: (_, i) {
            final e       = _entries[i];
            final status  = e['status'] as String? ?? 'completed';
            final isActive = status == 'active';
            final isStale  = e['is_stale_display'] as bool? ?? false;
            final name     = e['full_name'] as String? ?? 'Unknown';
            final initials = name.trim().split(' ')
                .map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();

            Color statusColor;
            String statusLabel;
            if (isStale) {
              statusColor = AppTheme.error;
              statusLabel = 'Forgot to clock out';
            } else if (isActive) {
              statusColor = AppTheme.success;
              statusLabel = 'Clocked In';
            } else {
              statusColor = AppTheme.textSecondary;
              statusLabel = 'Completed';
            }

            return Clickable(
              onTap: () => _showEntryDetail(e),
              child: Container(
              color: isStale ? AppTheme.error.withValues(alpha: 0.04) : null,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                if (_isOwner)
                  Expanded(flex: 3, child: Row(children: [
                    Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: Text(initials,
                          style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(name,
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                        overflow: TextOverflow.ellipsis)),
                  ])),
                Expanded(flex: 3, child: Text(_formatDateTime(e['clocked_in_at'] as String?),
                    style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
                Expanded(flex: 3, child: Text(
                  isActive ? '—' : _formatDateTime(e['clocked_out_at'] as String?),
                  style: TextStyle(fontSize: 12,
                      color: isActive ? AppTheme.textMuted : AppTheme.textPrimary),
                )),
                Expanded(flex: 2, child: isActive
                    ? _LiveDuration(
                        clockedInAt: e['clocked_in_at'] as String?,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: AppTheme.success),
                      )
                    : Text(
                        _formatDuration(e['duration_minutes'] as int?),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary),
                      )),
                Expanded(flex: 2, child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(statusLabel,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: statusColor)),
                )),
                if (_isOwner)
                  isStale
                      ? Tooltip(
                          message: 'This entry has been open for 14+ hours',
                          child: Icon(Icons.warning_amber_rounded, size: 16, color: AppTheme.error),
                        )
                      : const SizedBox(width: 24),
              ]),
              ),
            );
          },
        ),
      ]),
    );
  }
}

class _LiveDuration extends StatefulWidget {
  final String? clockedInAt;
  final TextStyle style;
  const _LiveDuration({required this.clockedInAt, required this.style});

  @override
  State<_LiveDuration> createState() => _LiveDurationState();
}

class _LiveDurationState extends State<_LiveDuration> {
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    final clockedInAt = DateTime.tryParse(widget.clockedInAt ?? '');
    if (clockedInAt != null) {
      void tick() {
        if (!mounted) return;
        setState(() => _elapsed = DateTime.now().toUtc().difference(clockedInAt.toUtc()));
      }
      tick();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) => Text(_format(_elapsed), style: widget.style);
}

class _TimeEntryDetailDialog extends StatelessWidget {
  final Map<String, dynamic> entry;
  final bool isOwner;
  final VoidCallback onForceClockOut;

  const _TimeEntryDetailDialog({
    required this.entry,
    required this.isOwner,
    required this.onForceClockOut,
  });

  String _formatDateTime(String? raw) {
    if (raw == null) return '—';
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return '—';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day} · $h:$m $ampm';
  }

  String _formatDuration(int? minutes) {
    if (minutes == null || minutes == 0) return '—';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  Widget _mapOrPlaceholder(double? lat, double? lng) {
    if (lat == null || lng == null) {
      return Container(
        height: 100,
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        alignment: Alignment.center,
        child: const Text('No location recorded',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      );
    }
    final mapsUrl = 'https://www.google.com/maps?q=$lat,$lng';
    return InkWell(
      onTap: () async {
        final uri = Uri.parse(mapsUrl);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          color: AppTheme.brand.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_on_outlined, size: 24, color: AppTheme.brand),
            const SizedBox(height: 6),
            Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            const SizedBox(height: 4),
            const Text('Tap to view on map',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.brand)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = entry['status'] as String? ?? 'completed';
    final isActive = status == 'active';
    final name = entry['full_name'] as String? ?? 'Unknown';
    final notes = entry['notes'] as String?;

    final clockInLat = (entry['clock_in_lat'] as num?)?.toDouble();
    final clockInLng = (entry['clock_in_lng'] as num?)?.toDouble();
    final clockOutLat = (entry['clock_out_lat'] as num?)?.toDouble();
    final clockOutLng = (entry['clock_out_lng'] as num?)?.toDouble();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(name,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppTheme.success.withValues(alpha: 0.1)
                          : AppTheme.borderColor.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(isActive ? 'Clocked In' : 'Completed',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                            color: isActive ? AppTheme.success : AppTheme.textSecondary)),
                  ),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Clocked In', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    const SizedBox(height: 2),
                    Text(_formatDateTime(entry['clocked_in_at'] as String?),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  ])),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Clocked Out', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    const SizedBox(height: 2),
                    Text(isActive ? '—' : _formatDateTime(entry['clocked_out_at'] as String?),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  ])),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Duration', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    const SizedBox(height: 2),
                    Text(isActive ? 'In progress' : _formatDuration(entry['duration_minutes'] as int?),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  ])),
                ]),
                const SizedBox(height: 20),
                const Text('Clock-In Location',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                _mapOrPlaceholder(clockInLat, clockInLng),
                const SizedBox(height: 16),
                const Text('Clock-Out Location',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                _mapOrPlaceholder(clockOutLat, clockOutLng),
                if (notes != null && notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Notes',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Text(notes,
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
                  ),
                ],
                const SizedBox(height: 24),
                Row(children: [
                  if (isOwner && isActive) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(context, rootNavigator: true).pop();
                          onForceClockOut();
                        },
                        icon: const Icon(Icons.stop_circle_outlined, size: 16, color: AppTheme.error),
                        label: const Text('Force Clock Out'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.error,
                          side: const BorderSide(color: AppTheme.error),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Close'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}