import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:convert';
import '../theme/app_theme.dart';

class EmployeeHubScreen extends StatefulWidget {
  final String token;
  const EmployeeHubScreen({super.key, required this.token});

  @override
  State<EmployeeHubScreen> createState() => _EmployeeHubScreenState();
}

class _EmployeeHubScreenState extends State<EmployeeHubScreen> {
  static const _fnBase =
      'https://rllriopqojaraceytdno.supabase.co/functions/v1';
  static const _pendingActionKey = 'nexaflow_pending_clock_action';

  bool _loading = true;
  String? _error;
  bool _needsSetup = false;

  String _fullName = '';
  String _businessName = '';
  bool _requireLocation = false;
  Map<String, dynamic>? _activeEntry;
  List<Map<String, dynamic>> _appointments = [];
  List<Map<String, dynamic>> _routeStops = [];
  List<Map<String, dynamic>> _pastJobForms = [];

  int? _selectedAppointmentId;
  bool _submitting = false;
  Timer? _tickTimer;
  Duration _elapsed = Duration.zero;

  bool _gpsTrackingEnabled = false;
  bool _locationSharingEnabled = false;
  bool _savingLocationPref = false;
  Timer? _locationLoopTimer;

  bool _hasPendingSync = false;
  Timer? _pendingSyncRetryTimer;

  bool _jobCostingEnabled = false;
  List<Map<String, dynamic>> _expenseCategories = [];

  final _jobSearchCtrl = TextEditingController();
  bool _showJobResults = false;
  final _pastFormsSearchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _checkPendingSync();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _locationLoopTimer?.cancel();
    _pendingSyncRetryTimer?.cancel();
    _jobSearchCtrl.dispose();
    _pastFormsSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await http.get(
        Uri.parse('$_fnBase/get-employee-hub-data?token=${widget.token}'),
      );
      if (!mounted) return;

      if (res.statusCode != 200) {
        setState(() {
          _error = 'This link is no longer valid.';
          _loading = false;
        });
        return;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;

      if (data['needs_setup'] == true) {
        setState(() {
          _needsSetup = true;
          _fullName = data['full_name'] as String? ?? '';
          _loading = false;
        });
        return;
      }

      setState(() {
        _fullName = data['full_name'] as String? ?? '';
        _businessName = data['business_name'] as String? ?? '';
        _requireLocation = data['require_location_on_clock'] as bool? ?? false;
        _gpsTrackingEnabled = data['gps_tracking_enabled'] as bool? ?? false;
        _locationSharingEnabled = data['location_sharing_enabled'] as bool? ?? false;
        _activeEntry = data['active_entry'] as Map<String, dynamic>?;
        _appointments =
            List<Map<String, dynamic>>.from(data['appointments'] ?? []);
        _routeStops =
            List<Map<String, dynamic>>.from(data['route_stops'] ?? []);
        _pastJobForms =
            List<Map<String, dynamic>>.from(data['past_job_forms'] ?? []);
        _jobCostingEnabled = data['job_costing_enabled'] as bool? ?? false;
        _expenseCategories =
            List<Map<String, dynamic>>.from(data['expense_categories'] ?? []);
        _loading = false;
      });

      _startTickerIfNeeded();
      _updateLocationLoop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Unable to load your hub. Please try again.';
        _loading = false;
      });
    }
  }

  void _startTickerIfNeeded() {
    _tickTimer?.cancel();
    if (_activeEntry == null) return;

    final clockedInAt =
        DateTime.tryParse(_activeEntry!['clocked_in_at'] as String? ?? '');
    if (clockedInAt == null) return;

    void tick() {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().toUtc().difference(clockedInAt.toUtc()));
    }

    tick();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void _updateLocationLoop() {
    _locationLoopTimer?.cancel();
    final isClockedIn = _activeEntry != null;
    if (!isClockedIn || !_gpsTrackingEnabled || !_locationSharingEnabled) return;
    _sendLocationUpdate();
    _locationLoopTimer = Timer.periodic(const Duration(seconds: 60), (_) => _sendLocationUpdate());
  }

  Future<bool> _checkInAtStop(int appointmentId) async {
    final pos = await _getLocation();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not get your location. Please allow location access and try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
      return false;
    }
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/employee-hub-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'action': 'check_in_at_stop',
          'appointment_id': appointmentId,
          'lat': pos.latitude,
          'lng': pos.longitude,
          'accuracy': pos.accuracy,
        }),
      );
      if (res.statusCode == 200) {
        await _load();
        return true;
      }
      if (mounted) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(body['message'] as String? ?? body['error'] as String? ?? 'Could not check in.'),
          backgroundColor: AppTheme.error,
        ));
      }
      return false;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: AppTheme.error,
        ));
      }
      return false;
    }
  }

  Future<void> _sendLocationUpdate() async {
    final pos = await _getLocation();
    if (pos == null) return;
    try {
      await http.post(
        Uri.parse('$_fnBase/employee-hub-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'action': 'update_location',
          'lat': pos.latitude,
          'lng': pos.longitude,
          'accuracy': pos.accuracy,
        }),
      );
    } catch (e) {
      debugPrint('Location update error: $e');
    }
  }

  Future<void> _toggleLocationSharing(bool value) async {
    setState(() => _savingLocationPref = true);
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/employee-hub-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'action': 'toggle_location_sharing',
          'enabled': value,
        }),
      );
      if (res.statusCode == 200) {
        setState(() => _locationSharingEnabled = value);
        _updateLocationLoop();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not update location sharing. Please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Network error — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _savingLocationPref = false);
    }
  }

  Future<Position?> _getLocation() async {
    void debugMsg(String msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 8),
        ));
      }
    }

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      debugMsg('checkPermission: $permission');
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        debugMsg('requestPermission: $permission');
        if (permission == LocationPermission.denied) return null;
      }
      if (permission == LocationPermission.deniedForever) {
        debugMsg('deniedForever — blocked at browser/OS level');
        return null;
      }

      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException('Location request timed out'),
      );
    } catch (e) {
      debugMsg('Location exception: $e');
      return null;
    }
  }

  Future<void> _clockAction(String action) async {
    setState(() => _submitting = true);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('DEBUG: clockAction started, requesting location...'),
        backgroundColor: Colors.blue,
        duration: Duration(seconds: 6),
      ));
    }

    Position? pos;
    if (_requireLocation || action == 'clock_in' || action == 'clock_out') {
      pos = await _getLocation();
    }

    if (_requireLocation && pos == null) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'This business requires location access. Please allow location and try again.'),
        backgroundColor: AppTheme.error,
        duration: Duration(seconds: 6),
      ));
      return;
    }

    // Captured the moment the tech actually pressed the button — sent to
    // the server as client_timestamp so that if this request has to be
    // queued and retried later (no connectivity right now), the recorded
    // clock time reflects this exact moment, not whenever the retry
    // eventually succeeds.
    final pressedAt = DateTime.now().toUtc().toIso8601String();
    final actionBody = <String, dynamic>{
      'token': widget.token,
      'action': action,
      if (action == 'clock_in') 'appointment_id': _selectedAppointmentId,
      'lat': pos?.latitude,
      'lng': pos?.longitude,
      'client_timestamp': pressedAt,
    };

    try {
      final res = await http
          .post(
            Uri.parse('$_fnBase/employee-hub-action'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(actionBody),
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;

      final body = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode == 200) {
        await _clearPendingSync();
        await _load();
      } else {
        final msg = body['message'] as String? ??
            body['error'] as String? ??
            'Something went wrong.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: AppTheme.error,
          duration: const Duration(seconds: 6),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      // No connectivity (or the request otherwise couldn't complete) —
      // save this exact action + timestamp on-device so it isn't lost,
      // and keep retrying automatically until it goes through. The tech
      // sees a clear "saved on this device" message instead of a plain
      // error implying nothing happened.
      await _savePendingSync(actionBody);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'No signal right now — your clock time is saved on this device and will sync automatically once you\'re back in range.'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 8),
      ));
      _startPendingSyncRetry();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _savePendingSync(Map<String, dynamic> actionBody) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingActionKey, jsonEncode(actionBody));
    if (mounted) setState(() => _hasPendingSync = true);
  }

  Future<void> _clearPendingSync() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingActionKey);
    _pendingSyncRetryTimer?.cancel();
    if (mounted) setState(() => _hasPendingSync = false);
  }

  Future<void> _checkPendingSync() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_pendingActionKey);
    if (saved == null) return;
    if (mounted) setState(() => _hasPendingSync = true);
    _attemptPendingSync();
    _startPendingSyncRetry();
  }

  void _startPendingSyncRetry() {
    _pendingSyncRetryTimer?.cancel();
    _pendingSyncRetryTimer = Timer.periodic(
        const Duration(seconds: 20), (_) => _attemptPendingSync());
  }

  Future<void> _attemptPendingSync() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_pendingActionKey);
    if (saved == null) {
      _pendingSyncRetryTimer?.cancel();
      return;
    }
    try {
      final res = await http
          .post(
            Uri.parse('$_fnBase/employee-hub-action'),
            headers: {'Content-Type': 'application/json'},
            body: saved,
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        await _clearPendingSync();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Synced! Your saved clock time has been recorded.'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 5),
          ));
          await _load();
        }
      }
      // Non-200 response: leave it queued, the periodic timer retries.
    } catch (_) {
      // Still no connectivity — leave it queued, timer will retry.
    }
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  List<Map<String, dynamic>> get _filteredAppointments {
    final q = _jobSearchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _appointments;
    return _appointments.where((a) {
      final type = (a['appointment_type'] as String? ?? '').toLowerCase();
      final lead = (a['lead_name'] as String? ?? '').toLowerCase();
      final addr = (a['lead_address'] as String? ?? '').toLowerCase();
      return type.contains(q) || lead.contains(q) || addr.contains(q);
    }).toList();
  }

  List<Map<String, dynamic>> get _filteredPastJobForms {
    final q = _pastFormsSearchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _pastJobForms;
    return _pastJobForms.where((f) {
      final formName = (f['form_name'] as String? ?? '').toLowerCase();
      final apptType = (f['appointment_type'] as String? ?? '').toLowerCase();
      final lead = (f['lead_name'] as String? ?? '').toLowerCase();
      return formName.contains(q) || apptType.contains(q) || lead.contains(q);
    }).toList();
  }

  // Splits the merged appointments list from get-employee-hub-data into
  // today's jobs vs. outstanding ones from a prior date whose job form
  // still needs attention — the backend returns them as one list, so
  // this is purely a display-layer split for the two headings below.
  List<Map<String, dynamic>> get _todaysAppointments {
    final now = DateTime.now();
    return _appointments.where((a) {
      final dt = a['scheduled_at'] != null
          ? DateTime.tryParse(a['scheduled_at'] as String)?.toLocal()
          : null;
      return dt != null && dt.year == now.year && dt.month == now.month && dt.day == now.day;
    }).toList();
  }

  List<Map<String, dynamic>> get _outstandingAppointments {
    final now = DateTime.now();
    return _appointments.where((a) {
      final dt = a['scheduled_at'] != null
          ? DateTime.tryParse(a['scheduled_at'] as String)?.toLocal()
          : null;
      return dt == null || dt.year != now.year || dt.month != now.month || dt.day != now.day;
    }).toList();
  }

  void _selectJob(Map<String, dynamic>? appt) {
    setState(() {
      _selectedAppointmentId = appt?['id'] as int?;
      _jobSearchCtrl.text = appt == null
          ? ''
          : '${appt['appointment_type'] ?? 'Appointment'} — ${appt['lead_name'] ?? ''}';
      _showJobResults = false;
    });
  }

  void _showAppointmentDetail(Map<String, dynamic> appt) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EmployeeAppointmentDetailSheet(
        token: widget.token,
        appt: appt,
        fnBase: _fnBase,
        onNoteSaved: _load,
        jobCostingEnabled: _jobCostingEnabled,
        expenseCategories: _expenseCategories,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppTheme.pageBg,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return _HubMessageScreen(
        icon: Icons.link_off_rounded,
        title: 'Link Not Found',
        message: _error!,
      );
    }

    if (_needsSetup) {
      return _HubMessageScreen(
        icon: Icons.mark_email_unread_outlined,
        title: 'Finish Setting Up',
        message: _fullName.isNotEmpty
            ? 'Hi $_fullName — check your email for a link to finish setting up your account. Once that\'s done, this link will work for clocking in and out.'
            : 'Check your email for a link to finish setting up your account. Once that\'s done, this link will work for clocking in and out.',
      );
    }

    final isClockedIn = _activeEntry != null;

    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_businessName,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 4),
                  Text('Hi $_fullName',
                      style: const TextStyle(
                          fontSize: 14, color: AppTheme.textSecondary)),
                  const SizedBox(height: 24),

                  // ── Status card ─────────────────────────────────────
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppTheme.cardBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isClockedIn
                            ? AppTheme.success.withValues(alpha: 0.4)
                            : AppTheme.borderColor,
                        width: isClockedIn ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isClockedIn
                                ? AppTheme.success.withValues(alpha: 0.1)
                                : AppTheme.borderColor.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            isClockedIn ? 'Clocked In' : 'Clocked Out',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isClockedIn
                                    ? AppTheme.success
                                    : AppTheme.textSecondary),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (isClockedIn) ...[
                          Text(
                            _formatElapsed(_elapsed),
                            style: const TextStyle(
                                fontSize: 40,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                                fontFeatures: [FontFeature.tabularFigures()]),
                          ),
                          const SizedBox(height: 20),
                        ] else if (_appointments.isNotEmpty) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Job (optional)',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary)),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _jobSearchCtrl,
                            onTap: () => setState(() => _showJobResults = true),
                            onChanged: (_) => setState(() => _showJobResults = true),
                            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                            decoration: InputDecoration(
                              hintText: 'Search jobs by name or address...',
                              hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                              prefixIcon: const Icon(Icons.search, size: 18, color: AppTheme.textSecondary),
                              suffixIcon: _selectedAppointmentId != null
                                  ? IconButton(
                                      icon: const Icon(Icons.close, size: 16, color: AppTheme.textSecondary),
                                      onPressed: () => _selectJob(null),
                                    )
                                  : null,
                              filled: true,
                              fillColor: AppTheme.pageBg,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(color: AppTheme.borderColor)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(color: AppTheme.borderColor)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                            ),
                          ),
                          if (_showJobResults) ...[
                            const SizedBox(height: 6),
                            Container(
                              constraints: const BoxConstraints(maxHeight: 220),
                              decoration: BoxDecoration(
                                color: AppTheme.cardBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppTheme.borderColor),
                              ),
                              child: _filteredAppointments.isEmpty
                                  ? const Padding(
                                      padding: EdgeInsets.all(14),
                                      child: Text('No matching jobs',
                                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                    )
                                  : ListView(
                                      shrinkWrap: true,
                                      padding: EdgeInsets.zero,
                                      children: _filteredAppointments.map((a) {
                                        final label = '${a['appointment_type'] ?? 'Appointment'} — ${a['lead_name'] ?? ''}';
                                        final addr = a['lead_address'] as String? ?? '';
                                        return InkWell(
                                          onTap: () => _selectJob(a),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(label,
                                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                                                if (addr.isNotEmpty)
                                                  Text(addr,
                                                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                              ],
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                            ),
                          ],
                          const SizedBox(height: 20),
                        ] else
                          const SizedBox(height: 4),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _submitting
                                ? null
                                : () => _clockAction(
                                    isClockedIn ? 'clock_out' : 'clock_in'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isClockedIn
                                  ? AppTheme.error
                                  : AppTheme.brand,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              textStyle: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700),
                            ),
                            child: _submitting
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : Text(
                                    isClockedIn ? 'Clock Out' : 'Clock In'),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (_gpsTrackingEnabled) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: AppTheme.cardBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.location_on_outlined,
                              size: 20,
                              color: _locationSharingEnabled
                                  ? AppTheme.brand
                                  : AppTheme.textSecondary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Share My Location',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.textPrimary)),
                                const SizedBox(height: 2),
                                const Text(
                                    'Lets your dispatcher see where you are and build your route.',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textSecondary)),
                              ],
                            ),
                          ),
                          _savingLocationPref
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : Switch(
                                  value: _locationSharingEnabled,
                                  onChanged: _toggleLocationSharing,
                                  activeColor: AppTheme.brand,
                                ),
                        ],
                      ),
                    ),
                  ],

                  if (_routeStops.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text('Your Route Today',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 10),
                    ..._routeStops.map((s) => _RouteStopCard(
                          stop: s,
                          showCheckIn: _gpsTrackingEnabled && _locationSharingEnabled,
                          onArrived: () => _checkInAtStop(s['appointment_id'] as int),
                        )),
                  ],

                  if (_todaysAppointments.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text("Today's Jobs",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 10),
                    ..._todaysAppointments.map((a) => _AppointmentCard(
                          appt: a,
                          token: widget.token,
                          onTap: () => _showAppointmentDetail(a),
                          showCheckIn: _gpsTrackingEnabled && _locationSharingEnabled,
                          onArrived: _checkInAtStop,
                        )),
                  ],
                  if (_outstandingAppointments.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text("Outstanding",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 2),
                    const Text('Jobs from a previous date with a form that still needs attention.',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary)),
                    const SizedBox(height: 10),
                    ..._outstandingAppointments.map((a) => _AppointmentCard(
                          appt: a,
                          token: widget.token,
                          onTap: () => _showAppointmentDetail(a),
                          showCheckIn: _gpsTrackingEnabled && _locationSharingEnabled,
                          onArrived: _checkInAtStop,
                        )),
                  ],
                  if (_pastJobForms.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text("Past Job Forms",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _pastFormsSearchCtrl,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Search past forms by name, job, or customer...',
                        hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                        prefixIcon: const Icon(Icons.search, size: 18, color: AppTheme.textSecondary),
                        suffixIcon: _pastFormsSearchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close, size: 16, color: AppTheme.textSecondary),
                                onPressed: () => setState(() => _pastFormsSearchCtrl.clear()),
                              )
                            : null,
                        filled: true,
                        fillColor: AppTheme.pageBg,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: AppTheme.borderColor)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: AppTheme.borderColor)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_filteredPastJobForms.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('No matching past forms',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      )
                    else
                      ..._filteredPastJobForms.map((f) => _PastJobFormCard(token: widget.token, form: f)),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Today's job card ──────────────────────────────────────────────────────────

class _AppointmentCard extends StatefulWidget {
  final Map<String, dynamic> appt;
  final String token;
  final VoidCallback? onTap;
  final bool showCheckIn;
  final Future<bool> Function(int appointmentId)? onArrived;
  const _AppointmentCard({
    required this.appt,
    required this.token,
    this.onTap,
    this.showCheckIn = false,
    this.onArrived,
  });

  @override
  State<_AppointmentCard> createState() => _AppointmentCardState();
}

class _AppointmentCardState extends State<_AppointmentCard> {
  bool _checkingIn = false;

  Future<void> _handleArrived() async {
    if (widget.onArrived == null) return;
    setState(() => _checkingIn = true);
    await widget.onArrived!(widget.appt['id'] as int);
    if (mounted) setState(() => _checkingIn = false);
  }

  @override
  Widget build(BuildContext context) {
    final appt = widget.appt;
    final dt = appt['scheduled_at'] != null
        ? DateTime.tryParse(appt['scheduled_at'] as String)?.toLocal()
        : null;
    // A form reopened for correction (or simply never finished) can now
    // surface here from a past date, not just today — show the date
    // alongside the time in that case so it's not mistaken for one of
    // today's jobs. Today's own appointments keep the plain time-only
    // display they've always had.
    final now = DateTime.now();
    final isToday = dt != null && dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final timeStr = dt == null ? '' : (isToday ? _time(dt) : '${_shortDate(dt)} · ${_time(dt)}');
    final type = appt['appointment_type'] as String? ?? 'Appointment';
    final leadName = appt['lead_name'] as String? ?? '';
    final address = appt['lead_address'] as String? ?? '';
    final jobForms = List<Map<String, dynamic>>.from(appt['job_forms'] ?? []);
    final checkedInAt = appt['checked_in_at'] != null
        ? DateTime.tryParse(appt['checked_in_at'] as String)?.toLocal()
        : null;

    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: checkedInAt != null
              ? AppTheme.success.withValues(alpha: 0.4)
              : AppTheme.borderColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(type,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                    if (leadName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(leadName,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary)),
                    ],
                    if (address.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(address,
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary)),
                    ],
                  ],
                ),
              ),
              if (timeStr.isNotEmpty)
                Text(timeStr,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textSecondary)),
            ],
          ),
          if (jobForms.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: jobForms
                  .map((f) => _JobFormChip(token: widget.token, form: f))
                  .toList(),
            ),
          ],
          if (widget.showCheckIn) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: checkedInAt != null
                  ? OutlinedButton.icon(
                      onPressed: _checkingIn ? null : _handleArrived,
                      icon: const Icon(Icons.check_circle_outline, size: 15, color: AppTheme.success),
                      label: Text('Arrived at ${_time(checkedInAt)} — Update',
                          style: const TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.success,
                        side: const BorderSide(color: AppTheme.success),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    )
                  : ElevatedButton.icon(
                      onPressed: _checkingIn ? null : _handleArrived,
                      icon: _checkingIn
                          ? const SizedBox(width: 13, height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.location_on_outlined, size: 15),
                      label: const Text('Arrived', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
            ),
          ],
        ],
      ),
      ),
    );
  }

  String _time(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$min $ampm';
  }

  String _shortDate(DateTime dt) => '${dt.month}/${dt.day}';
}

// ── Job form chip (tappable, links to the field fill-out screen) ──────────────

class _PastJobFormCard extends StatelessWidget {
  final String token;
  final Map<String, dynamic> form;
  const _PastJobFormCard({required this.token, required this.form});

  String _formatDate(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${dt.month}/${dt.day}/${dt.year} · $h:$min $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final submissionId = form['submission_id'];
    final formName = form['form_name'] as String? ?? 'Job Form';
    final apptType = form['appointment_type'] as String? ?? '';
    final leadName = form['lead_name'] as String? ?? '';
    final completedAt = _formatDate(form['completed_at'] as String?);

    return InkWell(
      onTap: () => context.go('/hub/$token/job-form/$submissionId'),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline_rounded,
                size: 18, color: AppTheme.success),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(formName,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary)),
                  if (apptType.isNotEmpty || leadName.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      [apptType, leadName].where((s) => s.isNotEmpty).join(' — '),
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                    ),
                  ],
                  if (completedAt.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(completedAt,
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 16, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _JobFormChip extends StatelessWidget {
  final String token;
  final Map<String, dynamic> form;
  const _JobFormChip({required this.token, required this.form});

  @override
  Widget build(BuildContext context) {
    final status = form['status'] as String? ?? 'not_started';
    final formName = form['form_name'] as String? ?? 'Job Form';
    final submissionId = form['submission_id'];
    final totalRequired = form['total_required'] as int? ?? 0;
    final missingRequired = form['missing_required'] as int? ?? 0;
    final completedRequired = totalRequired - missingRequired;
    // Matches Jobber's own model: any non-completed form shows "X of Y
    // required" (including 0 of Y for a form that's never been opened),
    // a completed form shows the plain status label instead — no count
    // needed once everything's done.
    final statusText = status == 'completed' || totalRequired == 0
        ? _formStatusLabel(status)
        : '$completedRequired of $totalRequired required';

    return InkWell(
      onTap: () => context.go('/hub/$token/job-form/$submissionId'),
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _formStatusColor(status).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: _formStatusColor(status).withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_formStatusIcon(status), size: 13, color: _formStatusColor(status)),
            const SizedBox(width: 5),
            Text(formName,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _formStatusColor(status))),
            const SizedBox(width: 5),
            Text('· $statusText',
                style: TextStyle(fontSize: 11, color: _formStatusColor(status))),
          ],
        ),
      ),
    );
  }
}

Color _formStatusColor(String status) {
  switch (status) {
    case 'completed':
      return AppTheme.success;
    case 'in_progress':
      return Colors.orange;
    default:
      return AppTheme.textSecondary;
  }
}

String _formStatusLabel(String status) {
  switch (status) {
    case 'completed':
      return 'Completed';
    case 'in_progress':
      return 'In Progress';
    default:
      return 'Not Started';
  }
}

IconData _formStatusIcon(String status) {
  switch (status) {
    case 'completed':
      return Icons.check_circle_outline;
    case 'in_progress':
      return Icons.edit_note_rounded;
    default:
      return Icons.assignment_outlined;
  }
}

// ── Route stop card (employee's ordered route for today) ───────────────────────

class _RouteStopCard extends StatefulWidget {
  final Map<String, dynamic> stop;
  final bool showCheckIn;
  final Future<bool> Function()? onArrived;
  const _RouteStopCard({required this.stop, this.showCheckIn = false, this.onArrived});

  @override
  State<_RouteStopCard> createState() => _RouteStopCardState();
}

class _RouteStopCardState extends State<_RouteStopCard> {
  bool _checkingIn = false;

  Future<void> _handleArrived() async {
    if (widget.onArrived == null) return;
    setState(() => _checkingIn = true);
    await widget.onArrived!();
    if (mounted) setState(() => _checkingIn = false);
  }

  String _time(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$min $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final stop = widget.stop;
    final dt = stop['scheduled_at'] != null
        ? DateTime.tryParse(stop['scheduled_at'] as String)?.toLocal()
        : null;
    final timeStr = dt != null ? _time(dt) : '';
    final type = stop['appointment_type'] as String? ?? 'Appointment';
    final leadName = stop['lead_name'] as String? ?? '';
    final address = stop['location'] as String? ?? '';
    final sequence = stop['sequence'] as int? ?? 0;
    final checkedInAt = stop['checked_in_at'] != null
        ? DateTime.tryParse(stop['checked_in_at'] as String)?.toLocal()
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: checkedInAt != null
              ? AppTheme.success.withValues(alpha: 0.4)
              : AppTheme.borderColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                    color: checkedInAt != null ? AppTheme.success : AppTheme.brand,
                    shape: BoxShape.circle),
                alignment: Alignment.center,
                child: checkedInAt != null
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : Text('$sequence',
                        style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(type,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                    if (leadName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(leadName,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary)),
                    ],
                    if (address.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(address,
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary)),
                    ],
                  ],
                ),
              ),
              if (timeStr.isNotEmpty)
                Text(timeStr,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textSecondary)),
            ],
          ),
          if (widget.showCheckIn) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: checkedInAt != null
                  ? OutlinedButton.icon(
                      onPressed: _checkingIn ? null : _handleArrived,
                      icon: const Icon(Icons.check_circle_outline, size: 15, color: AppTheme.success),
                      label: Text('Arrived at ${_time(checkedInAt)} — Update',
                          style: const TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.success,
                        side: const BorderSide(color: AppTheme.success),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    )
                  : ElevatedButton.icon(
                      onPressed: _checkingIn ? null : _handleArrived,
                      icon: _checkingIn
                          ? const SizedBox(width: 13, height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.location_on_outlined, size: 15),
                      label: const Text('Arrived', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Shared message screen (setup needed / error) ───────────────────────────────

class _HubMessageScreen extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const _HubMessageScreen(
      {required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Center(
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: AppTheme.brand),
            const SizedBox(height: 16),
            Text(title,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    height: 1.5)),
          ]),
        ),
      ),
    );
  }
}
class _EmployeeAppointmentDetailSheet extends StatefulWidget {
  final String token;
  final Map<String, dynamic> appt;
  final String fnBase;
  final VoidCallback onNoteSaved;
  final bool jobCostingEnabled;
  final List<Map<String, dynamic>> expenseCategories;

  const _EmployeeAppointmentDetailSheet({
    required this.token,
    required this.appt,
    required this.fnBase,
    required this.onNoteSaved,
    this.jobCostingEnabled = false,
    this.expenseCategories = const [],
  });

  @override
  State<_EmployeeAppointmentDetailSheet> createState() => _EmployeeAppointmentDetailSheetState();
}

class _EmployeeAppointmentDetailSheetState extends State<_EmployeeAppointmentDetailSheet> {
  final _noteCtrl = TextEditingController();
  bool _savingNote = false;
  bool _sendingOnMyWay = false;
  String? _onMyWaySentAt;

  // Expense logging
  final _expenseAmountCtrl = TextEditingController();
  final _expenseDescCtrl = TextEditingController();
  int? _expenseCategoryId;
  bool _expenseBillable = true;
  bool _savingExpense = false;
  String? _expenseError;
  String? _expenseSuccess;
  Uint8List? _receiptBytes;
  String? _receiptName;
  bool _pickingPhoto = false;

  @override
  void initState() {
    super.initState();
    _onMyWaySentAt = widget.appt['on_my_way_sent_at'] as String?;
    if (widget.expenseCategories.isNotEmpty) {
      _expenseCategoryId = widget.expenseCategories.first['id'] as int?;
    }
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _expenseAmountCtrl.dispose();
    _expenseDescCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickReceiptPhoto(ImageSource source) async {
    setState(() => _pickingPhoto = true);
    try {
      final picked = await ImagePicker().pickImage(source: source, imageQuality: 80);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _receiptBytes = bytes;
        _receiptName = picked.name;
      });
    } catch (e) {
      debugPrint('Pick receipt photo error: $e');
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  Future<void> _logExpense() async {
    if (_expenseCategoryId == null) {
      setState(() => _expenseError = 'Select a category');
      return;
    }
    final dollars = double.tryParse(_expenseAmountCtrl.text.trim().replaceAll(',', ''));
    if (dollars == null || dollars <= 0) {
      setState(() => _expenseError = 'Enter a valid amount');
      return;
    }
    setState(() { _savingExpense = true; _expenseError = null; _expenseSuccess = null; });
    try {
      final res = await http.post(
        Uri.parse('${widget.fnBase}/employee-hub-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'action': 'log_expense',
          'appointment_id': widget.appt['id'],
          'category_id': _expenseCategoryId,
          'amount_cents': (dollars * 100).round(),
          'description': _expenseDescCtrl.text.trim().isEmpty ? null : _expenseDescCtrl.text.trim(),
          'billable': _expenseBillable,
          if (_receiptBytes != null) 'receipt_base64': base64Encode(_receiptBytes!),
          if (_receiptName != null) 'receipt_filename': _receiptName,
        }),
      );
      if (!mounted) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && data['success'] == true) {
        setState(() {
          _expenseSuccess = 'Expense logged.';
          _expenseAmountCtrl.clear();
          _expenseDescCtrl.clear();
          _receiptBytes = null;
          _receiptName = null;
          _expenseBillable = true;
        });
        return;
      }
      if (res.statusCode == 403 && data['error'] == 'upgrade_required') {
        setState(() => _expenseError = data['message'] as String? ?? 'Job Costing requires the Growth plan.');
        return;
      }
      setState(() => _expenseError = data['message'] as String? ?? data['error'] as String? ?? 'Failed to log expense.');
    } catch (e) {
      if (mounted) setState(() => _expenseError = 'Error: $e');
    } finally {
      if (mounted) setState(() => _savingExpense = false);
    }
  }

  String _formatDateTime(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${dt.month}/${dt.day}/${dt.year} · $h:$min $ampm';
  }

  Future<void> _saveNote() async {
    if (_noteCtrl.text.trim().isEmpty) return;
    setState(() => _savingNote = true);
    try {
      final res = await http.post(
        Uri.parse('${widget.fnBase}/employee-hub-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'action': 'add_note',
          'appointment_id': widget.appt['id'],
          'notes': _noteCtrl.text.trim(),
        }),
      );
      if (!mounted) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && data['success'] == true) {
        _noteCtrl.clear();
        widget.onNoteSaved();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Note saved.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['error'] as String? ?? 'Failed to save note.'), backgroundColor: AppTheme.error),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _savingNote = false);
    }
  }

  Future<void> _sendOnMyWay() async {
    setState(() => _sendingOnMyWay = true);
    try {
      final res = await http.post(
        Uri.parse('${widget.fnBase}/employee-hub-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'action': 'send_on_my_way',
          'appointment_id': widget.appt['id'],
        }),
      );
      if (!mounted) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && data['success'] == true) {
        setState(() => _onMyWaySentAt = data['sent_at'] as String?);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Text sent.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['message'] as String? ?? data['error'] as String? ?? 'Failed to send text.'), backgroundColor: AppTheme.error),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingOnMyWay = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.appt;
    final type = a['appointment_type'] as String? ?? 'Appointment';
    final leadName = a['lead_name'] as String? ?? '';
    final address = a['lead_address'] as String? ?? '';
    final scheduledAt = _formatDateTime(a['scheduled_at'] as String?);
    final notes = a['notes'] as String? ?? '';
    final alreadySent = _onMyWaySentAt != null;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Text(type, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            if (scheduledAt.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(scheduledAt, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ],
            const SizedBox(height: 16),
            if (leadName.isNotEmpty) ...[
              const Text('Customer', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
              const SizedBox(height: 2),
              Text(leadName, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
              const SizedBox(height: 12),
            ],
            if (address.isNotEmpty) ...[
              const Text('Address', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
              const SizedBox(height: 2),
              Text(address, style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
              const SizedBox(height: 16),
            ],

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: (_sendingOnMyWay) ? null : _sendOnMyWay,
                icon: _sendingOnMyWay
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.directions_car_filled_outlined, size: 16),
                label: Text(alreadySent ? 'On My Way Sent — Send Again' : 'On My Way'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: alreadySent ? AppTheme.borderColor : AppTheme.brand,
                  foregroundColor: alreadySent ? AppTheme.textSecondary : Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(height: 20),

            if (widget.jobCostingEnabled) ...[
              const Text('Log an Expense', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
              const SizedBox(height: 8),
              if (widget.expenseCategories.isEmpty)
                const Text('No expense categories set up for this business yet.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
              else ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                  child: DropdownButtonHideUnderline(child: DropdownButton<int>(
                    value: _expenseCategoryId,
                    isExpanded: true,
                    dropdownColor: AppTheme.cardBg,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                    items: widget.expenseCategories.map((c) => DropdownMenuItem<int>(
                      value: c['id'] as int,
                      child: Text(c['name'] as String? ?? 'Unnamed'),
                    )).toList(),
                    onChanged: (v) => setState(() => _expenseCategoryId = v),
                  )),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _expenseAmountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    prefixText: '\$ ',
                    prefixStyle: const TextStyle(fontSize: 15, color: AppTheme.textSecondary),
                    hintText: '0.00',
                    filled: true,
                    fillColor: AppTheme.pageBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _expenseDescCtrl,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'e.g. 2 bundles shingles, fuel for the day...',
                    hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    filled: true,
                    fillColor: AppTheme.pageBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                  ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Switch(value: _expenseBillable, onChanged: (v) => setState(() => _expenseBillable = v), activeColor: AppTheme.brand),
                  const SizedBox(width: 8),
                  const Text('Billable to customer', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                ]),
                const SizedBox(height: 10),
                if (_receiptBytes != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                    child: Row(children: [
                      const Icon(Icons.image_outlined, size: 16, color: AppTheme.brand),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_receiptName ?? 'Photo attached',
                          style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary), overflow: TextOverflow.ellipsis)),
                      GestureDetector(
                        onTap: () => setState(() { _receiptBytes = null; _receiptName = null; }),
                        child: const Icon(Icons.close, size: 14, color: AppTheme.error),
                      ),
                    ]),
                  )
                else
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(
                      onPressed: _pickingPhoto ? null : () => _pickReceiptPhoto(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined, size: 16),
                      label: const Text('Take Photo', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textPrimary,
                        side: const BorderSide(color: AppTheme.borderColor),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: OutlinedButton.icon(
                      onPressed: _pickingPhoto ? null : () => _pickReceiptPhoto(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined, size: 16),
                      label: const Text('Choose File', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textPrimary,
                        side: const BorderSide(color: AppTheme.borderColor),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    )),
                  ]),
                if (_expenseError != null) ...[
                  const SizedBox(height: 8),
                  Text(_expenseError!, style: const TextStyle(fontSize: 12, color: AppTheme.error)),
                ],
                if (_expenseSuccess != null) ...[
                  const SizedBox(height: 8),
                  Text(_expenseSuccess!, style: const TextStyle(fontSize: 12, color: AppTheme.success)),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _savingExpense ? null : _logExpense,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _savingExpense
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Log Expense'),
                  ),
                ),
              ],
              const SizedBox(height: 20),
            ],

            if (notes.isNotEmpty) ...[
              const Text('Notes', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Text(notes, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.4)),
              ),
              const SizedBox(height: 16),
            ],

            const Text('Add a Note', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
            const SizedBox(height: 6),
            TextField(
              controller: _noteCtrl,
              maxLines: 3,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: 'e.g. gate code, dog on site, customer not home...',
                hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                filled: true,
                fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _savingNote ? null : _saveNote,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.brand,
                  side: const BorderSide(color: AppTheme.brand),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: _savingNote
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.brand))
                    : const Text('Save Note'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}