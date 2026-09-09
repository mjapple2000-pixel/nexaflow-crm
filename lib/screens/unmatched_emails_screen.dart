import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

// Read-only superuser tool — lists inbound emails that couldn't be matched
// to a business's dedicated_email (see EM-01). No editing, no workflow,
// just visibility so a misconfigured Mailgun domain doesn't go unnoticed.
class UnmatchedEmailsScreen extends StatefulWidget {
  const UnmatchedEmailsScreen({super.key});

  @override
  State<UnmatchedEmailsScreen> createState() => _UnmatchedEmailsScreenState();
}

class _UnmatchedEmailsScreenState extends State<UnmatchedEmailsScreen> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await _db
          .from('unmatched_inbound_emails')
          .select('id, raw_to_address, raw_from_address, subject, received_at')
          .filter('deleted_at', 'is', null)
          .order('received_at', ascending: false)
          .limit(200);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      debugPrint('Unmatched emails load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatDate(String? iso) {
    final dt = DateTime.tryParse(iso ?? '')?.toLocal();
    if (dt == null) return '';
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    final m = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month]} ${dt.day}, ${dt.year} · $h:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.pageBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Unmatched Emails',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 4),
          const Text(
            'Inbound emails that could not be matched to a business by dedicated_email — dropped, not answered.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppTheme.brand))
                : _rows.isEmpty
                    ? const Center(
                        child: Text('No unmatched inbound emails.',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                      )
                    : Container(
                        decoration: BoxDecoration(
                          color: AppTheme.cardBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.borderColor),
                        ),
                        child: ListView.separated(
                          padding: const EdgeInsets.all(4),
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.divider),
                          itemBuilder: (context, i) {
                            final r = _rows[i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  const Icon(Icons.mail_outline_rounded, size: 16, color: AppTheme.textMuted),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 3,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(r['subject'] as String? ?? '(no subject)',
                                            style: const TextStyle(
                                                fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                                            overflow: TextOverflow.ellipsis),
                                        const SizedBox(height: 3),
                                        Text('From: ${r['raw_from_address'] ?? ''}',
                                            style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
                                            overflow: TextOverflow.ellipsis),
                                        Text('To: ${r['raw_to_address'] ?? ''}',
                                            style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
                                            overflow: TextOverflow.ellipsis),
                                      ],
                                    ),
                                  ),
                                  Text(_formatDate(r['received_at'] as String?),
                                      style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}