import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../theme/app_theme.dart';

class ClientHubScreen extends StatefulWidget {
  final String token;
  const ClientHubScreen({super.key, required this.token});

  @override
  State<ClientHubScreen> createState() => _ClientHubScreenState();
}

class _ClientHubScreenState extends State<ClientHubScreen> {
  static const _fnBase =
      'https://rllriopqojaraceytdno.supabase.co/functions/v1';

  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _data;

  // Service request form
  final _descCtrl = TextEditingController();
  DateTime? _preferredDate;
  bool _submitting = false;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await http.get(
        Uri.parse('$_fnBase/get-client-portal-data?token=${widget.token}'),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          _data = jsonDecode(res.body) as Map<String, dynamic>;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'This link is no longer valid.';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Unable to load your portal. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _quoteAction(int quoteId, String actionType) async {
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/client-portal-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'action_type': actionType,
          'target_id': quoteId,
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        // Refresh data so status updates inline
        await _load();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(actionType == 'approve_quote'
              ? 'Quote approved — we\'ll be in touch soon!'
              : 'Quote declined.'),
          backgroundColor:
              actionType == 'approve_quote' ? Colors.green[700] : AppTheme.error,
        ));
      } else {
        final body = jsonDecode(res.body);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(body['error'] ?? 'Something went wrong.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error — please try again.'),
        backgroundColor: AppTheme.error,
      ));
    }
  }

  Future<void> _submitServiceRequest() async {
    final desc = _descCtrl.text.trim();
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please describe what you need.'),
        backgroundColor: AppTheme.error,
      ));
      return;
    }
    setState(() => _submitting = true);
    try {
      final res = await http.post(
        Uri.parse('$_fnBase/client-portal-action'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': widget.token,
          'action_type': 'submit_service_request',
          'payload': {
            'description': desc,
            'preferred_date': _preferredDate?.toUtc().toIso8601String(),
          },
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          _submitted = true;
          _submitting = false;
        });
      } else {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed to submit — please try again.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error — please try again.'),
        backgroundColor: AppTheme.error,
      ));
    }
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
      return _ErrorScreen(message: _error!);
    }

    final business = _data!['business'] as Map<String, dynamic>;
    final lead = _data!['lead'] as Map<String, dynamic>;
    final appointments = List<Map<String, dynamic>>.from(_data!['appointments'] ?? []);
    final quotes = List<Map<String, dynamic>>.from(_data!['quotes'] ?? []);
    final invoices = List<Map<String, dynamic>>.from(_data!['invoices'] ?? []);

    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                _PortalHeader(
                  businessName: business['name'] as String? ?? '',
                  logoUrl: business['logo_url'] as String?,
                  firstName: lead['first_name'] as String? ?? 'there',
                ),
                const SizedBox(height: 24),

                // Upcoming Appointments
                _SectionCard(
                  title: 'Upcoming Appointments',
                  icon: Icons.calendar_today_rounded,
                  child: appointments.isEmpty
                      ? _emptyState('No upcoming appointments.')
                      : Column(
                          children: appointments
                              .map((a) => _AppointmentRow(appt: a))
                              .toList(),
                        ),
                ),
                const SizedBox(height: 16),

                // Quotes
                _SectionCard(
                  title: 'Quotes',
                  icon: Icons.description_rounded,
                  child: quotes.isEmpty
                      ? _emptyState('No quotes on file.')
                      : Column(
                          children: quotes
                              .map((q) => _QuoteRow(
                                    quote: q,
                                    onApprove: () => _quoteAction(
                                        (q['id'] as num).toInt(), 'approve_quote'),
                                    onDecline: () => _quoteAction(
                                        (q['id'] as num).toInt(), 'decline_quote'),
                                  ))
                              .toList(),
                        ),
                ),
                const SizedBox(height: 16),

                // Invoices
                _SectionCard(
                  title: 'Invoices',
                  icon: Icons.receipt_long_rounded,
                  child: invoices.isEmpty
                      ? _emptyState('No invoices on file.')
                      : Column(
                          children: invoices
                              .map((i) => _InvoiceRow(invoice: i))
                              .toList(),
                        ),
                ),
                const SizedBox(height: 16),

                // Request New Work
                _SectionCard(
                  title: 'Request New Work',
                  icon: Icons.build_rounded,
                  child: _submitted
                      ? _RequestSuccess(businessName: business['name'] as String? ?? '')
                      : _RequestForm(
                          descCtrl: _descCtrl,
                          preferredDate: _preferredDate,
                          submitting: _submitting,
                          onDatePick: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: DateTime.now().add(const Duration(days: 1)),
                              firstDate: DateTime.now(),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null && mounted) {
                              setState(() => _preferredDate = picked);
                            }
                          },
                          onSubmit: _submitServiceRequest,
                        ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState(String msg) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(msg,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      );
}

// ── Header ────────────────────────────────────────────────────────────────────

class _PortalHeader extends StatelessWidget {
  final String businessName;
  final String? logoUrl;
  final String firstName;
  const _PortalHeader(
      {required this.businessName,
      required this.logoUrl,
      required this.firstName});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          if (logoUrl != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(logoUrl!,
                  height: 40, width: 40, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox()),
            ),
            const SizedBox(width: 12),
          ],
          Text(businessName,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary)),
        ]),
        const SizedBox(height: 12),
        Text('Hi $firstName — here\'s your account with $businessName.',
            style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary)),
      ],
    );
  }
}

// ── Section card wrapper ───────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const _SectionCard(
      {required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 16, color: AppTheme.brand),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
          ]),
          const SizedBox(height: 14),
          const Divider(color: AppTheme.borderColor, height: 1),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

// ── Appointment row ───────────────────────────────────────────────────────────

class _AppointmentRow extends StatelessWidget {
  final Map<String, dynamic> appt;
  const _AppointmentRow({required this.appt});

  @override
  Widget build(BuildContext context) {
    final dt = appt['scheduled_at'] != null
        ? DateTime.parse(appt['scheduled_at'] as String).toLocal()
        : null;
    final dateStr = dt != null
        ? '${_weekday(dt.weekday)}, ${_month(dt.month)} ${dt.day} · ${_time(dt)}'
        : 'TBD';
    final type = appt['appointment_type'] as String? ?? 'Appointment';
    final status = appt['status'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(type,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 2),
              Text(dateStr,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          ),
          _StatusBadge(status: status),
        ],
      ),
    );
  }

  String _weekday(int d) =>
      ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d - 1];
  String _month(int m) => [
        'Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'
      ][m - 1];
  String _time(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$min $ampm';
  }
}

// ── Quote row ─────────────────────────────────────────────────────────────────

class _QuoteRow extends StatelessWidget {
  final Map<String, dynamic> quote;
  final VoidCallback onApprove;
  final VoidCallback onDecline;
  const _QuoteRow(
      {required this.quote,
      required this.onApprove,
      required this.onDecline});

  @override
  Widget build(BuildContext context) {
    final status = quote['status'] as String? ?? '';
    final number = quote['quote_number'] as String? ?? '';
    final jobTitle = quote['job_title'] as String?;
    final total = (quote['total'] as num?)?.toDouble() ?? 0.0;
    final canAct = status == 'sent';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      jobTitle != null ? '$jobTitle · $number' : number,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text('\$${total.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textSecondary)),
                  ]),
            ),
            _StatusBadge(status: status),
          ]),
          if (canAct) ...[
            const SizedBox(height: 10),
            Row(children: [
              ElevatedButton(
                onPressed: onApprove,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                  textStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
                child: const Text('Approve'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: onDecline,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.error,
                  side: const BorderSide(color: AppTheme.error),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                  textStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
                child: const Text('Decline'),
              ),
            ]),
          ],
          const SizedBox(height: 8),
          const Divider(color: AppTheme.borderColor, height: 1),
        ],
      ),
    );
  }
}

// ── Invoice row ───────────────────────────────────────────────────────────────

class _InvoiceRow extends StatelessWidget {
  final Map<String, dynamic> invoice;
  const _InvoiceRow({required this.invoice});

  @override
  Widget build(BuildContext context) {
    final status = invoice['status'] as String? ?? '';
    final number = invoice['invoice_number'] as String? ?? '';
    final jobTitle = invoice['job_title'] as String?;
    final total = (invoice['total'] as num?)?.toDouble() ?? 0.0;
    final dueDate = invoice['due_date'] != null
        ? DateTime.parse(invoice['due_date'] as String).toLocal()
        : null;

    // Client-side overdue detection — mirrors JG-01 logic
    final isOverdue = (status == 'approved' || status == 'sent') &&
        dueDate != null &&
        dueDate.isBefore(DateTime.now());
    final displayStatus = isOverdue ? 'overdue' : status;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  jobTitle != null ? '$jobTitle · $number' : number,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  dueDate != null
                      ? '\$${total.toStringAsFixed(2)} · Due ${_formatDate(dueDate)}'
                      : '\$${total.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary),
                ),
              ]),
        ),
        _StatusBadge(status: displayStatus),
      ]),
    );
  }

  String _formatDate(DateTime dt) =>
      '${_month(dt.month)} ${dt.day}, ${dt.year}';
  String _month(int m) => [
        'Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'
      ][m - 1];
}

// ── Request form ──────────────────────────────────────────────────────────────

class _RequestForm extends StatelessWidget {
  final TextEditingController descCtrl;
  final DateTime? preferredDate;
  final bool submitting;
  final VoidCallback onDatePick;
  final VoidCallback onSubmit;

  const _RequestForm({
    required this.descCtrl,
    required this.preferredDate,
    required this.submitting,
    required this.onDatePick,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('What do you need done?',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        TextField(
          controller: descCtrl,
          maxLines: 4,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'Describe the work you\'d like us to do...',
            hintStyle:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            filled: true,
            fillColor: AppTheme.pageBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppTheme.brand),
            ),
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: onDatePick,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(children: [
              const Icon(Icons.calendar_today_rounded,
                  size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Text(
                preferredDate != null
                    ? 'Preferred date: ${preferredDate!.month}/${preferredDate!.day}/${preferredDate!.year}'
                    : 'Preferred date (optional)',
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: submitting ? null : onSubmit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              textStyle: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600),
            ),
            child: submitting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Submit Request'),
          ),
        ),
      ],
    );
  }
}

// ── Request success state ─────────────────────────────────────────────────────

class _RequestSuccess extends StatelessWidget {
  final String businessName;
  const _RequestSuccess({required this.businessName});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Icon(Icons.check_circle_rounded,
            size: 40, color: Colors.green),
        const SizedBox(height: 12),
        Text(
          'We received your request and will be in touch soon!',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary),
        ),
        const SizedBox(height: 6),
        Text(
          businessName,
          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
      ],
    );
  }
}

// ── Error screen ──────────────────────────────────────────────────────────────

class _ErrorScreen extends StatelessWidget {
  final String message;
  const _ErrorScreen({required this.message});

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
            const Icon(Icons.link_off_rounded,
                size: 48, color: AppTheme.error),
            const SizedBox(height: 16),
            const Text('Link Not Found',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            const Text('Contact us to receive a new link.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary)),
          ]),
        ),
      ),
    );
  }
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch (status) {
      'draft' => ('Draft', const Color(0xFF374151), Colors.white),
      'sent' => ('Pending Approval', const Color(0xFF1D4ED8), Colors.white),
      'approved' => ('Approved', Colors.green[700]!, Colors.white),
      'declined' => ('Declined', AppTheme.error, Colors.white),
      'expired' => ('Expired', const Color(0xFF6B7280), Colors.white),
      'paid' => ('Paid', Colors.green[700]!, Colors.white),
      'overdue' => ('Overdue', const Color(0xFFDC2626), Colors.white),
      'void' => ('Void', const Color(0xFF6B7280), Colors.white),
      'confirmed' => ('Confirmed', Colors.green[700]!, Colors.white),
      'cancelled' => ('Cancelled', AppTheme.error, Colors.white),
      'new' => ('New', const Color(0xFF1D4ED8), Colors.white),
      _ => (status, const Color(0xFF374151), Colors.white),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}