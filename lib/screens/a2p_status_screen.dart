import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

// Read-only superuser tool — lists every business's Twilio A2P brand and
// campaign registration status (see SMS-01). No editing, no workflow;
// just visibility so support can answer "why can't I send texts yet?"
// without querying the database directly.
class A2pStatusScreen extends StatefulWidget {
  const A2pStatusScreen({super.key});

  @override
  State<A2pStatusScreen> createState() => _A2pStatusScreenState();
}

class _A2pStatusScreenState extends State<A2pStatusScreen> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await _db
          .from('businesses')
          .select(
              'id, business_name, ai_phone_number, business_a2p_profiles(status, brand_type, twilio_brand_sid, twilio_customer_profile_sid), business_a2p_campaigns(status, use_case, twilio_campaign_sid)')
          .order('business_name', ascending: true);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
      // TEMP DEBUG — remove once the pill rendering is confirmed correct.
      if (_rows.isNotEmpty) {
        debugPrint('A2P DEBUG first row: ${_rows.first}');
      }
    } catch (e) {
      debugPrint('A2P status load error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _statusColor(String? status) {
    switch (status) {
      case 'approved':
        return const Color(0xFF10B981);
      case 'pending':
        return const Color(0xFFF59E0B);
      case 'rejected':
      case 'suspended':
        return const Color(0xFFEF4444);
      default:
        return AppTheme.textMuted;
    }
  }

  Widget _statusPill(String label, String? status) {
    final color = _statusColor(status);
    final text = status ?? 'not_started';
    final isNeutral = status == null || status == 'not_started';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: isNeutral ? const Color(0xFFE5E7EB) : color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isNeutral ? const Color(0xFF9CA3AF) : color),
      ),
      child: Text('$label: $text',
          style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: isNeutral ? const Color(0xFF374151) : color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredRows = _search.isEmpty
        ? _rows
        : _rows.where((r) {
            final name = (r['business_name'] as String? ?? '').toLowerCase();
            final phone =
                (r['ai_phone_number'] as String? ?? '').toLowerCase();
            return name.contains(_search) || phone.contains(_search);
          }).toList();

    return Container(
      color: AppTheme.pageBg,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('A2P Registration Status',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 4),
          const Text(
            'Twilio A2P brand + campaign compliance status per business. Number requests are disabled until a business\'s A2P brand shows Approved.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 320,
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _search = v.toLowerCase()),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search businesses...',
                prefixIcon:
                    const Icon(Icons.search_rounded, size: 18),
                isDense: true,
                filled: true,
                fillColor: AppTheme.cardBg,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppTheme.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppTheme.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppTheme.brand),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(
                    child:
                        CircularProgressIndicator(color: AppTheme.brand))
                : filteredRows.isEmpty
                    ? Center(
                        child: Text(
                            _search.isEmpty
                                ? 'No businesses found.'
                                : 'No businesses match "$_search".',
                            style: const TextStyle(
                                color: AppTheme.textSecondary)))
                    : Scrollbar(
                        thumbVisibility: true,
                        child: ListView.builder(
                          itemCount: filteredRows.length,
                          itemBuilder: (context, i) {
                            final row = filteredRows[i];
                            final profiles = List<Map<String, dynamic>>.from(
                                row['business_a2p_profiles'] as List? ?? []);
                            final campaigns = List<Map<String, dynamic>>.from(
                                row['business_a2p_campaigns'] as List? ?? []);
                            final profile =
                                profiles.isNotEmpty ? profiles.first : null;
                            final campaign =
                                campaigns.isNotEmpty ? campaigns.first : null;
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                color: AppTheme.cardBg,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppTheme.divider),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 1,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            row['business_name']
                                                    as String? ??
                                                'Unknown',
                                            style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: AppTheme.textPrimary)),
                                        const SizedBox(height: 2),
                                        Text(
                                            (row['ai_phone_number']
                                                    as String?) ??
                                                'No number provisioned',
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: AppTheme.textMuted)),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    flex: 1,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _statusPill('Brand',
                                              profile?['status'] as String?),
                                          const SizedBox(width: 8),
                                          _statusPill('Campaign',
                                              campaign?['status'] as String?),
                                        ],
                                      ),
                                    ),
                                  ),
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