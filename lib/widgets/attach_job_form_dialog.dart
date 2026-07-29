import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';

// ─────────────────────────────────────────────
//  ATTACH JOB FORM TO LEAD
//  Opened from a Job Forms row. Lets office staff search an existing Lead
//  or create a new one, then creates a real appointment (with a real
//  start/end time — appointments always require one) and links a
//  job_form_submissions row to it. job_form_submissions has no lead_id of
//  its own; appointment_id is its only path to a customer, so this dialog
//  always creates an appointment, never a bare submission.
// ─────────────────────────────────────────────
class AttachJobFormDialog extends StatefulWidget {
  final int jobFormId;
  final String jobFormName;
  final VoidCallback onSaved;

  const AttachJobFormDialog({
    super.key,
    required this.jobFormId,
    required this.jobFormName,
    required this.onSaved,
  });

  @override
  State<AttachJobFormDialog> createState() => _AttachJobFormDialogState();
}

class _AttachJobFormDialogState extends State<AttachJobFormDialog> {
  final _db = Supabase.instance.client;

  final _contactCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();

  int? _businessId;
  List<Map<String, dynamic>> _leads = [];
  List<Map<String, dynamic>> _filteredLeads = [];
  List<Map<String, dynamic>> _teamMembers = [];
  bool _showDropdown = false;
  String? _selectedLeadId;
  String? _assignedTo;

  DateTime _startDt = DateTime.now().add(const Duration(hours: 1));
  DateTime _endDt = DateTime.now().add(const Duration(hours: 2));

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _contactCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final businessId = await getActiveBusinessId();
      if (businessId == null) {
        setState(() {
          _error = 'Could not resolve business';
          _loading = false;
        });
        return;
      }
      final results = await Future.wait([
        _db
            .from('leads')
            .select('id, lead_name, lead_email, lead_phone, lead_address')
            .eq('business_id', businessId)
            .order('lead_name', ascending: true),
        _db.from('profiles').select('id, full_name').eq('business_id', businessId),
      ]);
      if (!mounted) return;
      setState(() {
        _businessId = businessId;
        _leads = List<Map<String, dynamic>>.from(results[0] as List);
        _filteredLeads = _leads;
        _teamMembers = List<Map<String, dynamic>>.from(results[1] as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error loading: $e';
        _loading = false;
      });
    }
  }

  void _filterLeads(String q) {
    setState(() {
      _showDropdown = true;
      _selectedLeadId = null;
      _filteredLeads = q.isEmpty
          ? _leads
          : _leads.where((l) {
              final n = (l['lead_name'] ?? '').toString().toLowerCase();
              final e = (l['lead_email'] ?? '').toString().toLowerCase();
              final p = (l['lead_phone'] ?? '').toString().toLowerCase();
              final query = q.toLowerCase();
              return n.contains(query) || e.contains(query) || p.contains(query);
            }).toList();
    });
  }

  void _selectLead(Map<String, dynamic> lead) {
    setState(() {
      _selectedLeadId = lead['id']?.toString();
      _contactCtrl.text = lead['lead_name'] ?? '';
      _phoneCtrl.text = lead['lead_phone'] ?? '';
      _emailCtrl.text = lead['lead_email'] ?? '';
      _locationCtrl.text = lead['lead_address'] ?? '';
      _showDropdown = false;
    });
  }

  Future<void> _pickDateTime(bool isStart) async {
    final date = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDt : _endDt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(isStart ? _startDt : _endDt),
    );
    if (time == null || !mounted) return;
    final result = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _startDt = result;
        if (_endDt.isBefore(_startDt)) _endDt = _startDt.add(const Duration(hours: 1));
      } else {
        _endDt = result;
      }
    });
  }

  int? _assignedToProfileId() {
    if (_assignedTo == null) return null;
    final match = _teamMembers.firstWhere(
      (m) => m['full_name'] == _assignedTo,
      orElse: () => {},
    );
    return match['id'] as int?;
  }

  Future<void> _save() async {
    if (_contactCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Contact name is required');
      return;
    }
    if (_endDt.isBefore(_startDt)) {
      setState(() => _error = 'End time must be after start time');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final businessId = _businessId;
      if (businessId == null) {
        setState(() {
          _error = 'Could not resolve business';
          _saving = false;
        });
        return;
      }

      // Resolve the lead — use the one picked from the dropdown, or
      // dedupe by phone/email (same pattern as forms_screen.dart's
      // create_lead_on_submit flow), or create a fresh one.
      String? leadId = _selectedLeadId;
      if (leadId == null) {
        final phone = _phoneCtrl.text.trim();
        final email = _emailCtrl.text.trim();
        List existing = [];
        if (email.isNotEmpty) {
          existing = await _db
              .from('leads')
              .select('id')
              .eq('business_id', businessId)
              .eq('lead_email', email)
              .limit(1);
        }
        if (existing.isEmpty && phone.isNotEmpty) {
          existing = await _db
              .from('leads')
              .select('id')
              .eq('business_id', businessId)
              .eq('lead_phone', phone)
              .limit(1);
        }
        if (existing.isNotEmpty) {
          leadId = existing.first['id'].toString();
        } else {
          final newLead = await _db
              .from('leads')
              .insert({
                'business_id': businessId,
                'lead_name': _contactCtrl.text.trim(),
                'lead_phone': phone.isEmpty ? null : phone,
                'lead_email': email.isEmpty ? null : email,
                'lead_status': 'new',
                'source': 'job_form_attach',
              })
              .select()
              .maybeSingle();
          leadId = newLead?['id']?.toString();
        }
      }

      final userId = _db.auth.currentUser?.id;
      final apptName = '${widget.jobFormName} — ${_contactCtrl.text.trim()}';
      final newAppt = await _db
          .from('appointments')
          .insert({
            'business_id': businessId,
            'appointment_name': apptName,
            'appointment_type': 'Service Appointment',
            'status': 'New',
            'start_date_time': _startDt.toUtc().toIso8601String(),
            'end_date_time': _endDt.toUtc().toIso8601String(),
            'location': _locationCtrl.text.trim(),
            'lead_id': leadId != null ? int.tryParse(leadId) : null,
            'lead_name': _contactCtrl.text.trim(),
            'lead_phone': _phoneCtrl.text.trim(),
            'lead_email': _emailCtrl.text.trim(),
            'user_id': userId,
            'confirmation_sent': false,
            'is_recurring': false,
            if (_assignedTo != null) 'assigned_to': _assignedTo,
            if (_assignedTo != null) 'assigned_to_profile_id': _assignedToProfileId(),
          })
          .select()
          .maybeSingle();

      final apptId = newAppt?['id'];

      await _db.from('job_form_submissions').insert({
        'business_id': businessId,
        'job_form_id': widget.jobFormId,
        'appointment_id': apptId,
        'status': 'not_started',
      });

      // Same appointment_booked automation trigger every other
      // appointment-creation path fires, and the same location geocode —
      // both non-blocking, matching appointments_screen.dart exactly, so
      // this appointment behaves identically to one booked normally.
      try {
        await http.post(
          Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/run-automation'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'trigger_type': 'appointment_booked',
            'business_id': businessId,
            'payload': {
              'appointment_id': apptId,
              'appointment_name': apptName,
              'lead_name': _contactCtrl.text.trim(),
              'lead_id': leadId,
              'phone': _phoneCtrl.text.trim(),
              'email': _emailCtrl.text.trim(),
            },
          }),
        );
      } catch (e) {
        debugPrint('Automation error: $e');
      }

      final locationText = _locationCtrl.text.trim();
      if (locationText.isNotEmpty && apptId != null) {
        try {
          final token = _db.auth.currentSession?.accessToken;
          if (token != null) {
            await http.post(
              Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/geocode-location'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'appointment_id': apptId, 'address': locationText}),
            );
          }
        } catch (e) {
          debugPrint('Geocode error: $e');
        }
      }

      widget.onSaved();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (e) {
      setState(() => _error = 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fmtDt(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day} · $h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
        child: _loading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(color: AppTheme.brand),
                ),
              )
            : Column(children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
                  decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                  child: Row(children: [
                    const Icon(Icons.person_add_alt_outlined, size: 20, color: AppTheme.brand),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Attach "${widget.jobFormName}" to a Lead',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                          overflow: TextOverflow.ellipsis),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                      icon: const Icon(Icons.close, size: 20, color: AppTheme.textSecondary),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  ]),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (_error != null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: AppTheme.error.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
                          ),
                          child: Text(_error!, style: const TextStyle(color: AppTheme.error, fontSize: 12)),
                        ),
                      ],
                      _label('Contact Name *'),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _contactCtrl,
                        onChanged: _filterLeads,
                        onTap: () => setState(() {
                          _showDropdown = true;
                          _filteredLeads = _leads;
                        }),
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          hintText: 'Search or type a name',
                          hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          filled: true,
                          fillColor: AppTheme.pageBg,
                          suffixIcon: const Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: AppTheme.borderColor)),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: AppTheme.borderColor)),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                        ),
                      ),
                      if (_showDropdown) ...[
                        const SizedBox(height: 4),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 180),
                          decoration: BoxDecoration(
                            color: AppTheme.cardBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.borderColor),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2))
                            ],
                          ),
                          child: SingleChildScrollView(
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              InkWell(
                                onTap: () => setState(() {
                                  _showDropdown = false;
                                  _selectedLeadId = null;
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  decoration: BoxDecoration(
                                      border: Border(
                                          bottom: BorderSide(
                                              color: AppTheme.borderColor.withValues(alpha: 0.5)))),
                                  child: const Row(children: [
                                    Icon(Icons.edit_outlined, size: 14, color: AppTheme.textSecondary),
                                    SizedBox(width: 8),
                                    Text('Enter manually — creates a new Lead',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: AppTheme.textSecondary,
                                            fontStyle: FontStyle.italic)),
                                  ]),
                                ),
                              ),
                              if (_filteredLeads.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text('No contacts found',
                                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                )
                              else
                                ..._filteredLeads.map((lead) {
                                  final name = lead['lead_name']?.toString() ?? '';
                                  final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
                                  final subtitle = [lead['lead_email'], lead['lead_phone']]
                                      .where((v) => (v ?? '').toString().isNotEmpty)
                                      .join(' · ');
                                  return InkWell(
                                    onTap: () => _selectLead(lead),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                      decoration: BoxDecoration(
                                          border: Border(
                                              bottom: BorderSide(
                                                  color: AppTheme.borderColor.withValues(alpha: 0.4)))),
                                      child: Row(children: [
                                        Container(
                                          width: 28,
                                          height: 28,
                                          decoration: BoxDecoration(
                                              color: AppTheme.brand.withValues(alpha: 0.1),
                                              shape: BoxShape.circle),
                                          alignment: Alignment.center,
                                          child: Text(initial,
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                  color: AppTheme.brand)),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(name.isNotEmpty ? name : 'Unknown',
                                                    style: const TextStyle(
                                                        fontSize: 13,
                                                        fontWeight: FontWeight.w500,
                                                        color: AppTheme.textPrimary)),
                                                if (subtitle.isNotEmpty)
                                                  Text(subtitle,
                                                      style: const TextStyle(
                                                          fontSize: 11, color: AppTheme.textSecondary)),
                                              ]),
                                        ),
                                      ]),
                                    ),
                                  );
                                }),
                            ]),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(children: [
                        Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _label('Phone'),
                          const SizedBox(height: 4),
                          _textField(_phoneCtrl, hint: '555-0100', keyboard: TextInputType.phone),
                        ])),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _label('Email'),
                          const SizedBox(height: 4),
                          _textField(_emailCtrl,
                              hint: 'jane@example.com', keyboard: TextInputType.emailAddress),
                        ])),
                      ]),
                      const SizedBox(height: 14),
                      _label('Location'),
                      const SizedBox(height: 4),
                      const Text(
                          'Where the tech needs to go to fill this out. Defaults to the Lead\'s address if on file.',
                          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const SizedBox(height: 6),
                      _textField(_locationCtrl, hint: 'Job site address'),
                      const SizedBox(height: 14),
                      Row(children: [
                        Expanded(child: _dateTimeField('Start', _startDt, () => _pickDateTime(true))),
                        const SizedBox(width: 12),
                        Expanded(child: _dateTimeField('End', _endDt, () => _pickDateTime(false))),
                      ]),
                      const SizedBox(height: 14),
                      if (_teamMembers.isNotEmpty) ...[
                        _label('Assigned To'),
                        const SizedBox(height: 4),
                        _dropdownField(
                          value: _assignedTo ?? 'Unassigned',
                          items: [
                            'Unassigned',
                            ..._teamMembers.map((m) => m['full_name']?.toString() ?? 'Unknown')
                          ],
                          onChanged: (v) => setState(() => _assignedTo = v == 'Unassigned' ? null : v),
                        ),
                      ],
                    ]),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: AppTheme.borderColor))),
                  child: Row(children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                      child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Create & Attach'),
                    ),
                  ]),
                ),
              ]),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary));

  Widget _textField(TextEditingController ctrl, {String? hint, TextInputType? keyboard}) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboard,
      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        filled: true,
        fillColor: AppTheme.pageBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
      ),
    );
  }

  Widget _dateTimeField(String label, DateTime value, VoidCallback onTap) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label(label),
      const SizedBox(height: 4),
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor)),
            child: Row(children: [
              const Icon(Icons.access_time, size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(child: Text(_fmtDt(value), style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _dropdownField(
      {required String value, required List<String> items, required ValueChanged<String?> onChanged}) {
    final safe = items.contains(value) ? value : items.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: safe,
          isExpanded: true,
          dropdownColor: AppTheme.cardBg,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          items: items.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}