import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'business_contacts_screen.dart' show AddEditBusinessContactSheet;

class BusinessContactDetailScreen extends StatefulWidget {
  final String contactId;
  const BusinessContactDetailScreen({super.key, required this.contactId});
  @override
  State<BusinessContactDetailScreen> createState() => _BusinessContactDetailScreenState();
}

class _BusinessContactDetailScreenState extends State<BusinessContactDetailScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _contact;
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _referrals = [];

  int get _id => int.parse(widget.contactId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final contact = await _db.from('contacts')
          .select('id, business_id, full_name, email, phone, address, city, state, zip, '
              'source, status, tags, notes, assigned_to, last_contacted, do_not_contact, created_at, '
              'referral_code')
          .eq('id', _id)
          .filter('deleted_at', 'is', null)
          .maybeSingle();

      if (contact == null) {
        setState(() { _error = 'Contact not found.'; _loading = false; });
        return;
      }

      final convos = await _db.from('conversations')
          .select('id, channel, last_message, last_message_at')
          .eq('contact_id', _id)
          .order('last_message_at', ascending: false)
          .limit(5);

      List<Map<String, dynamic>> referrals = [];
      try {
        final referralData = await _db.from('referrals')
            .select('id, status, created_at, leads(lead_name, lead_phone)')
            .eq('referrer_contact_id', _id)
            .filter('deleted_at', 'is', null)
            .order('created_at', ascending: false);
        referrals = List<Map<String, dynamic>>.from(referralData);
      } catch (e) {
        debugPrint('Referrals load: $e');
      }

      if (!mounted) return;
      setState(() {
        _contact = contact;
        _conversations = List<Map<String, dynamic>>.from(convos);
        _referrals = referrals;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _edit() {
    if (_contact == null) return;
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => AddEditBusinessContactSheet(
        businessId: (_contact!['business_id'] as num).toInt(),
        existing: _contact,
        onSaved: () { context.pop(); _load(); },
      ),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete this contact?', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
        content: const Text('This will remove them from your active list. This can be restored by support if needed.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
        actions: [
          TextButton(onPressed: () => ctx.pop(false), child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => ctx.pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _db.from('contacts')
          .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', _id);
      if (mounted) context.go('/contacts');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.brand))
          : _error != null
              ? _buildError()
              : _buildContent(),
    );
  }

  Widget _buildError() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.error_outline, color: AppTheme.error, size: 40),
    const SizedBox(height: 12),
    Text(_error ?? 'Unknown error', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
    const SizedBox(height: 12),
    TextButton.icon(onPressed: () => context.go('/contacts'),
      icon: const Icon(Icons.arrow_back, color: AppTheme.brand),
      label: const Text('Back to Contacts', style: TextStyle(color: AppTheme.brand))),
  ]));

  Widget _buildContent() {
    final c = _contact!;
    final name = c['full_name'] as String? ?? 'Unknown';
    final status = c['status'] as String? ?? 'Active';
    final tags = (c['tags'] as List?)?.map((t) => t.toString()).toList() ?? [];
    final initials = name.trim().split(' ').length >= 2
        ? '${name.trim().split(' ')[0][0]}${name.trim().split(' ')[1][0]}'.toUpperCase()
        : (name.isNotEmpty ? name[0].toUpperCase() : '?');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top bar
          Container(
            color: AppTheme.cardBg,
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Row(children: [
              GestureDetector(
                onTap: () => context.go('/contacts'),
                child: Container(width: 36, height: 36,
                  decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                  child: const Icon(Icons.arrow_back, size: 18, color: AppTheme.textSecondary)),
              ),
              const SizedBox(width: 16),
              Container(width: 44, height: 44,
                decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                child: Center(child: Text(initials, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                _statusBadge(status),
              ])),
              OutlinedButton.icon(
                onPressed: _edit,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit'),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.textPrimary, side: const BorderSide(color: AppTheme.borderColor)),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.error),
                label: const Text('Delete', style: TextStyle(color: AppTheme.error)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: AppTheme.error)),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: Column(children: [
                  _card('Contact Info', [
                    _infoRow(Icons.phone_outlined, 'Phone', c['phone'] as String?),
                    _infoRow(Icons.email_outlined, 'Email', c['email'] as String?),
                    _infoRow(Icons.location_on_outlined, 'Address', _fmtAddress(c)),
                    _infoRow(Icons.source_outlined, 'Source', c['source'] as String?),
                    _infoRow(Icons.person_outline, 'Assigned To', c['assigned_to'] as String? ?? 'Unassigned'),
                    _infoRow(Icons.block_outlined, 'Do Not Contact', (c['do_not_contact'] as bool? ?? false) ? 'Yes' : 'No'),
                  ]),
                  const SizedBox(height: 16),
                  if (tags.isNotEmpty)
                    _card('Tags', [
                      Wrap(spacing: 6, runSpacing: 6, children: tags.map((t) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppTheme.borderColor)),
                        child: Text(t, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                      )).toList()),
                    ]),
                  if (tags.isNotEmpty) const SizedBox(height: 16),
                  if ((c['notes'] as String?)?.isNotEmpty == true)
                    _card('Notes', [
                      Text(c['notes'] as String, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.6)),
                    ]),
                  if ((c['notes'] as String?)?.isNotEmpty == true) const SizedBox(height: 16),
                  _buildReferralCard(c),
                ])),
                const SizedBox(width: 20),
                Expanded(flex: 1, child: Column(children: [
                  _card('Details', [
                    _infoRow(Icons.calendar_today_outlined, 'Created', _fmtDate(c['created_at'] as String?)),
                    _infoRow(Icons.chat_bubble_outline, 'Last Contacted', _fmtDate(c['last_contacted'] as String?)),
                  ]),
                  const SizedBox(height: 16),
                  _card('Recent Conversations', _conversations.isEmpty
                      ? [const Text('No conversations yet.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))]
                      : [
                          ..._conversations.map((conv) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Icon(conv['channel'] == 'email' ? Icons.email_outlined : Icons.sms_outlined, size: 14, color: AppTheme.textSecondary),
                              const SizedBox(width: 8),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text((conv['last_message'] as String?) ?? '(no message)',
                                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                                Text(_fmtDate(conv['last_message_at'] as String?), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10)),
                              ])),
                            ]),
                          )),
                          TextButton(onPressed: () => context.go('/conversations'),
                            child: const Text('View all in Conversations', style: TextStyle(color: AppTheme.brand, fontSize: 12))),
                        ]),
                ])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReferralCard(Map<String, dynamic> c) {
    final code = c['referral_code'] as String?;
    final link = code != null ? 'https://nexaflow-crm.web.app/refer/$code' : null;

    return _card('Referral Link', [
      if (link == null)
        const Text('No referral code on file.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))
      else ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor)),
          child: Row(children: [
            Expanded(child: Text(link,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: link));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Referral link copied!'), backgroundColor: AppTheme.brand,
                      duration: Duration(seconds: 2)));
              },
              child: const Icon(Icons.copy_outlined, size: 15, color: AppTheme.brand),
            ),
          ]),
        ),
        const SizedBox(height: 14),
      ],
      const Text('Referred', style: TextStyle(color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
      const SizedBox(height: 8),
      if (_referrals.isEmpty)
        const Text('No referrals yet.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))
      else
        ..._referrals.map((r) {
          final lead = r['leads'] as Map<String, dynamic>?;
          final leadName = lead?['lead_name'] as String? ?? 'Unknown';
          final status = r['status'] as String? ?? 'lead_created';
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(leadName, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
                Text(_fmtDate(r['created_at'] as String?), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10)),
              ])),
              _referralStatusBadge(status),
            ]),
          );
        }),
    ]);
  }

  Widget _referralStatusBadge(String status) {
    late String label;
    late Color color;
    switch (status) {
      case 'lead_created':
        label = 'Lead Created'; color = const Color(0xFF3B82F6); break;
      case 'contacted':
        label = 'Contacted'; color = const Color(0xFF8B5CF6); break;
      case 'became_customer':
        label = 'Became Customer'; color = const Color(0xFF10B981); break;
      case 'thanked':
        label = 'Thanked'; color = const Color(0xFF059669); break;
      default:
        label = status; color = AppTheme.brand;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }

  Widget _card(String title, List<Widget> children) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
      const SizedBox(height: 12),
      ...children,
    ]),
  );

  Widget _infoRow(IconData icon, String label, String? value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 15, color: AppTheme.textSecondary),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10)),
        Text(value?.isNotEmpty == true ? value! : '—', style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
      ])),
    ]),
  );

  Widget _statusBadge(String status) {
    Color color;
    switch (status.toLowerCase()) {
      case 'active':   color = const Color(0xFF10B981); break;
      case 'inactive': color = const Color(0xFF6B7280); break;
      case 'archived': color = const Color(0xFFEF4444); break;
      default:         color = AppTheme.brand;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(status, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }

  String? _fmtAddress(Map<String, dynamic> c) {
    final parts = [c['address'], c['city'], c['state'], c['zip']]
        .where((p) => p != null && (p as String).isNotEmpty).cast<String>();
    return parts.isEmpty ? null : parts.join(', ');
  }

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '—';
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }
}
