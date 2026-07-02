import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
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

  bool _loading = true;
  String? _error;
  bool _needsSetup = false;

  String _fullName = '';
  String _businessName = '';
  bool _requireLocation = false;
  Map<String, dynamic>? _activeEntry;
  List<Map<String, dynamic>> _appointments = [];

  int? _selectedAppointmentId;
  bool _submitting = false;
  Timer? _tickTimer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
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
        _activeEntry = data['active_entry'] as Map<String, dynamic>?;
        _appointments =
            List<Map<String, dynamic>>.from(data['appointments'] ?? []);
        _loading = false;
      });

      _startTickerIfNeeded();
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

    try {
      final res = await http.post(
        Uri.parse('$_fnBase/employee-hub-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'action': action,
          if (action == 'clock_in') 'appointment_id': _selectedAppointmentId,
          'lat': pos?.latitude,
          'lng': pos?.longitude,
        }),
      );
      if (!mounted) return;

      final body = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode == 200) {
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error — please try again.'),
        backgroundColor: AppTheme.error,
      ));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
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
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12),
                            decoration: BoxDecoration(
                              color: AppTheme.pageBg,
                              borderRadius: BorderRadius.circular(8),
                              border:
                                  Border.all(color: AppTheme.borderColor),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int?>(
                                isExpanded: true,
                                value: _selectedAppointmentId,
                                hint: const Text('No specific job',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.textSecondary)),
                                items: [
                                  const DropdownMenuItem<int?>(
                                    value: null,
                                    child: Text('No specific job'),
                                  ),
                                  ..._appointments.map((a) {
                                    final id = a['id'] as int;
                                    final label =
                                        '${a['appointment_type'] ?? 'Appointment'} — ${a['lead_name'] ?? ''}';
                                    return DropdownMenuItem<int?>(
                                      value: id,
                                      child: Text(label,
                                          overflow: TextOverflow.ellipsis),
                                    );
                                  }),
                                ],
                                onChanged: (v) =>
                                    setState(() => _selectedAppointmentId = v),
                              ),
                            ),
                          ),
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

                  if (_appointments.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text("Today's Jobs",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 10),
                    ..._appointments.map((a) => _AppointmentCard(appt: a)),
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

class _AppointmentCard extends StatelessWidget {
  final Map<String, dynamic> appt;
  const _AppointmentCard({required this.appt});

  @override
  Widget build(BuildContext context) {
    final dt = appt['scheduled_at'] != null
        ? DateTime.tryParse(appt['scheduled_at'] as String)?.toLocal()
        : null;
    final timeStr = dt != null ? _time(dt) : '';
    final type = appt['appointment_type'] as String? ?? 'Appointment';
    final leadName = appt['lead_name'] as String? ?? '';
    final address = appt['lead_address'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(
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
    );
  }

  String _time(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$min $ampm';
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