import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

class EmployeePtoScreen extends StatefulWidget {
  const EmployeePtoScreen({super.key});

  @override
  State<EmployeePtoScreen> createState() => _EmployeePtoScreenState();
}

class _EmployeePtoScreenState extends State<EmployeePtoScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  int? _businessId;
  int? _myProfileId;
  bool _ptoAvailable = false; // pto_enabled AND plan allows
  double _balanceHours = 0;
  List<Map<String, dynamic>> _requests = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');

      final userId = _db.auth.currentUser?.id;
      if (userId == null) throw Exception('Not signed in.');
      final me = await _db
          .from('profiles')
          .select('id')
          .eq('user_id', userId)
          .eq('business_id', _businessId!)
          .maybeSingle();
      _myProfileId = me != null ? (me['id'] as num).toInt() : null;
      if (_myProfileId == null) throw Exception('Profile not found.');

      final biz = await _db
          .from('businesses')
          .select('pto_enabled, plan, is_beta')
          .eq('id', _businessId!)
          .maybeSingle();
      final ptoEnabled = biz?['pto_enabled'] as bool? ?? false;
      final isBeta = biz?['is_beta'] as bool? ?? false;
      bool planAllows = isBeta;
      if (!planAllows) {
        final allowed = await _db.rpc('check_plan_feature', params: {
          'p_business_id': _businessId,
          'p_feature': 'pto_tracking',
        });
        planAllows = allowed == true;
      }
      _ptoAvailable = ptoEnabled && planAllows;

      if (_ptoAvailable) {
        final balance = await _db
            .from('pto_balances')
            .select('balance_hours')
            .eq('business_id', _businessId!)
            .eq('profile_id', _myProfileId!)
            .filter('deleted_at', 'is', null)
            .maybeSingle();
        _balanceHours = balance != null ? (balance['balance_hours'] as num).toDouble() : 0;

        final requests = await _db
            .from('pto_requests')
            .select('id, start_date, end_date, hours_requested, status, note, requested_at')
            .eq('business_id', _businessId!)
            .eq('profile_id', _myProfileId!)
            .filter('deleted_at', 'is', null)
            .order('requested_at', ascending: false);
        _requests = List<Map<String, dynamic>>.from(requests as List);
      }

      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _showRequestDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RequestTimeOffDialog(
        businessId: _businessId!,
        profileId: _myProfileId!,
        onSaved: () {
          Navigator.of(context, rootNavigator: true).pop();
          _load();
        },
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return const Color(0xFF10B981);
      case 'denied':
        return Colors.red;
      default:
        return Colors.orange;
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
                      padding: const EdgeInsets.all(32),
                      child: _ptoAvailable ? _buildContent() : _buildUnavailable(),
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
        Clickable(
          onTap: () => context.go('/settings?section=profile'),
          child: const Icon(Icons.arrow_back, size: 18, color: AppTheme.textSecondary),
        ),
        const SizedBox(width: 14),
        const Text('My PTO',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const Spacer(),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 18, color: AppTheme.textSecondary),
            tooltip: 'Refresh',
          ),
        ),
      ]),
    );
  }

  Widget _buildUnavailable() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(48),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.beach_access_outlined, size: 48, color: AppTheme.textMuted),
        const SizedBox(height: 16),
        const Text('PTO tracking is not turned on',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        const SizedBox(height: 8),
        const Text('Ask your manager or business owner to enable PTO tracking to start earning and requesting time off.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary), textAlign: TextAlign.center),
      ]),
    );
  }

  Widget _buildContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppTheme.brand.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Available Balance',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
            const SizedBox(height: 4),
            Text('${_balanceHours.toStringAsFixed(1)} hours',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
            const SizedBox(height: 16),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ElevatedButton.icon(
                onPressed: _showRequestDialog,
                icon: const Icon(Icons.event_available_outlined, size: 16),
                label: const Text('Request Time Off'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 24),
        const Text('My Requests',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        if (_requests.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: const Center(
              child: Text('No time off requests yet.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Column(
              children: _requests.asMap().entries.map((entry) {
                final i = entry.key;
                final r = entry.value;
                final isLast = i == _requests.length - 1;
                final status = r['status'] as String? ?? 'pending';
                return Container(
                  decoration: BoxDecoration(
                    border: isLast ? null : const Border(bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${r['start_date']} → ${r['end_date']}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                        const SizedBox(height: 2),
                        Text('${(r['hours_requested'] as num).toStringAsFixed(1)} hours'
                            '${(r['note'] as String?)?.isNotEmpty == true ? '  ·  ${r['note']}' : ''}',
                            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      ]),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _statusColor(status).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(status[0].toUpperCase() + status.substring(1),
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600, color: _statusColor(status))),
                    ),
                  ]),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

class _RequestTimeOffDialog extends StatefulWidget {
  final int businessId;
  final int profileId;
  final VoidCallback onSaved;
  const _RequestTimeOffDialog(
      {required this.businessId, required this.profileId, required this.onSaved});

  @override
  State<_RequestTimeOffDialog> createState() => _RequestTimeOffDialogState();
}

class _RequestTimeOffDialogState extends State<_RequestTimeOffDialog> {
  final _db = Supabase.instance.client;
  DateTime? _startDate;
  DateTime? _endDate;
  final _hoursCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _hoursCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _startDate : _endDate) ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (!mounted || picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
        if (_endDate != null && _endDate!.isBefore(picked)) _endDate = picked;
      } else {
        _endDate = picked;
      }
    });
  }

  String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (_startDate == null || _endDate == null) {
      setState(() => _error = 'Pick a start and end date.');
      return;
    }
    final hours = double.tryParse(_hoursCtrl.text.trim());
    if (hours == null || hours <= 0) {
      setState(() => _error = 'Enter a valid number of hours.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final rows = await _db.from('pto_requests').insert({
        'business_id': widget.businessId,
        'profile_id': widget.profileId,
        'start_date': _fmt(_startDate!),
        'end_date': _fmt(_endDate!),
        'hours_requested': hours,
        'status': 'pending',
        'note': _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      }).select('id');
      final requestId = (rows as List).isNotEmpty ? (rows.first['id'] as num).toInt() : null;
      if (requestId != null) {
        // Best-effort — the request itself is already saved regardless of
        // whether the owner's email notification succeeds, so this never
        // blocks or fails the submission the employee is waiting on.
        unawaited(_notifyOwner(requestId));
      }
      widget.onSaved();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _saving = false;
        });
      }
    }
  }

  Future<void> _notifyOwner(int requestId) async {
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) return;
      await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/notify-pto-request'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'pto_request_id': requestId}),
      );
    } catch (e) {
      debugPrint('PTO owner notification failed (non-blocking): $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 460,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Request Time Off',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: Clickable(
                  onTap: () => _pickDate(isStart: true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Text(_startDate == null ? 'Start date' : _fmt(_startDate!),
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Clickable(
                  onTap: () => _pickDate(isStart: false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Text(_endDate == null ? 'End date' : _fmt(_endDate!),
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: _hoursCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                labelText: 'Hours Requested',
                hintText: 'e.g. 16',
                filled: true,
                fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _noteCtrl,
              maxLines: 2,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                labelText: 'Note (optional)',
                filled: true,
                fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textSecondary,
                      side: const BorderSide(color: AppTheme.borderColor),
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _saving ? null : _submit,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Submit Request'),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}