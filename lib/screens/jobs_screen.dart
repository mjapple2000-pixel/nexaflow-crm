import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../screens/quotes_screen.dart';
import '../screens/invoices_screen.dart';
import '../screens/job_forms_screen.dart';

class JobsScreen extends StatefulWidget {
  final int initialTab;
  const JobsScreen({super.key, this.initialTab = 0});

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this, initialIndex: widget.initialTab);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(tabController: _tabController),
          _TabBar(controller: _tabController),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                _QuotesTab(),
                _InvoicesTab(),
                _ServiceRequestsTab(),
                _JobFormsTab(),
                _ComingSoonTab(
                  icon: Icons.timer_outlined,
                  title: 'Time & expenses',
                  description:
                      'Log crew hours and job expenses, then attach them directly to a quote or invoice.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  TOP BAR
// ─────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final TabController tabController;
  const _TopBar({required this.tabController});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: tabController,
      builder: (context, _) {
        final isQuotesTab = tabController.index == 0;
        return Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: Row(
            children: [
              const Text(
                'Jobs',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              if (isQuotesTab)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton.icon(
                      onPressed: () => context.go('/jobs/quotes/new'),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('New Quote'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                ),
              if (tabController.index == 1)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: ElevatedButton.icon(
                      onPressed: () => context.go('/jobs/invoices/new'),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('New Invoice'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Tooltip(
                  message: 'Service Library',
                  child: IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 18, color: AppTheme.textSecondary),
                    onPressed: () => context.go('/settings?section=service_library'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
//  TAB BAR
// ─────────────────────────────────────────────
class _TabBar extends StatelessWidget {
  final TabController controller;
  const _TabBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        border: const Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        labelColor: AppTheme.brand,
        unselectedLabelColor: AppTheme.textSecondary,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
        indicatorColor: AppTheme.brand,
        indicatorWeight: 2,
        dividerColor: Colors.transparent,
        tabs: [
          const Tab(
            child: Row(
              children: [
                Icon(Icons.request_quote_outlined, size: 16),
                SizedBox(width: 7),
                Text('Quotes'),
              ],
            ),
          ),
          const Tab(
            child: Row(
              children: [
                Icon(Icons.receipt_long_outlined, size: 16),
                SizedBox(width: 7),
                Text('Invoices'),
              ],
            ),
          ),
          const Tab(
            child: Row(
              children: [
                Icon(Icons.inbox_outlined, size: 16),
                SizedBox(width: 7),
                Text('Requests'),
              ],
            ),
          ),
          const Tab(
            child: Row(
              children: [
                Icon(Icons.assignment_outlined, size: 16),
                SizedBox(width: 7),
                Text('Job forms'),
              ],
            ),
          ),
          Tab(
            child: Row(
              children: const [
                Icon(Icons.timer_outlined, size: 16),
                SizedBox(width: 7),
                Text('Time & expenses'),
                SizedBox(width: 7),
                _SoonBadge(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SoonBadge extends StatelessWidget {
  const _SoonBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: const Text(
        'Soon',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}
class _QuotesTab extends StatelessWidget {
  const _QuotesTab();

  @override
  Widget build(BuildContext context) {
    return const QuotesScreen();
  }
}

// ─────────────────────────────────────────────
//  INVOICES TAB
// ─────────────────────────────────────────────
class _InvoicesTab extends StatelessWidget {
  const _InvoicesTab();

  @override
  Widget build(BuildContext context) {
    return const InvoicesScreen();
  }
}

// ─────────────────────────────────────────────
//  JOB FORMS TAB
// ─────────────────────────────────────────────
class _JobFormsTab extends StatelessWidget {
  const _JobFormsTab();

  @override
  Widget build(BuildContext context) {
    return const JobFormsScreen();
  }
}

// ─────────────────────────────────────────────
//  SERVICE REQUESTS TAB
// ─────────────────────────────────────────────
class _ServiceRequestsTab extends StatefulWidget {
  const _ServiceRequestsTab();

  @override
  State<_ServiceRequestsTab> createState() => _ServiceRequestsTabState();
}

class _ServiceRequestsTabState extends State<_ServiceRequestsTab> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _requests = [];

  static const _statuses = ['new', 'reviewed', 'scheduled', 'declined'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final userId = _db.auth.currentUser?.id;
      if (userId == null) return;
      final profile = await _db
          .from('profiles')
          .select('business_id')
          .eq('user_id', userId)
          .single();
      final businessId = (profile['business_id'] as num).toInt();

      final data = await _db
          .from('client_service_requests')
          .select('id, description, preferred_date, status, internal_notes, created_at, lead_id, leads(lead_name, lead_phone)')
          .eq('business_id', businessId)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false);

      if (!mounted) return;
      setState(() => _requests = List<Map<String, dynamic>>.from(data));
    } catch (e) {
      debugPrint('Service requests load: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updateStatus(int id, String status) async {
    try {
      await _db
          .from('client_service_requests')
          .update({'status': status})
          .eq('id', id);
      await _load();
    } catch (e) {
      debugPrint('Status update: $e');
    }
  }

  Future<void> _saveNotes(int id, String notes) async {
    try {
      await _db
          .from('client_service_requests')
          .update({'internal_notes': notes})
          .eq('id', id);
    } catch (e) {
      debugPrint('Notes save: $e');
    }
  }

  void _openDetail(Map<String, dynamic> req) {
    final notesCtrl = TextEditingController(
        text: req['internal_notes'] as String? ?? '');
    String currentStatus = req['status'] as String? ?? 'new';
    final leadName = (req['leads'] as Map<String, dynamic>?)?['lead_name'] as String? ?? 'Unknown';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: Row(children: [
            const Icon(Icons.inbox_outlined, size: 18, color: AppTheme.brand),
            const SizedBox(width: 8),
            Expanded(
              child: Text(leadName,
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Description
                const Text('Request',
                    style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Text(req['description'] as String? ?? '',
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontSize: 13, height: 1.5)),
                ),
                if (req['preferred_date'] != null) ...[
                  const SizedBox(height: 12),
                  Row(children: [
                    const Icon(Icons.calendar_today_rounded,
                        size: 13, color: AppTheme.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      'Preferred: ${_formatDate(req['preferred_date'] as String)}',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12),
                    ),
                  ]),
                ],
                const SizedBox(height: 16),
                // Status
                const Text('Status',
                    style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
                const SizedBox(height: 6),
                Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: currentStatus,
                      isExpanded: true,
                      dropdownColor: AppTheme.cardBg,
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontSize: 13),
                      items: _statuses
                          .map((s) => DropdownMenuItem(
                              value: s,
                              child: Text(_capitalize(s))))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setS(() => currentStatus = v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Internal notes
                const Text('Internal Notes (staff only)',
                    style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
                const SizedBox(height: 6),
                TextField(
                  controller: notesCtrl,
                  maxLines: 3,
                  style: const TextStyle(
                      color: AppTheme.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Add notes visible only to your team...',
                    hintStyle: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 13),
                    filled: true,
                    fillColor: AppTheme.pageBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: AppTheme.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: AppTheme.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppTheme.brand),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Cancel',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () async {
                final id = (req['id'] as num).toInt();
                await _updateStatus(id, currentStatus);
                await _saveNotes(id, notesCtrl.text.trim());
                if (ctx.mounted) {
                  Navigator.of(ctx, rootNavigator: true).pop();
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    const months = ['Jan','Feb','Mar','Apr','May','Jun',
                    'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Color _statusColor(String status) => switch (status) {
        'new'       => const Color(0xFF1D4ED8),
        'reviewed'  => const Color(0xFFF59E0B),
        'scheduled' => const Color(0xFF059669),
        'declined'  => AppTheme.error,
        _           => AppTheme.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppTheme.brand));
    }

    if (_requests.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.borderColor),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.inbox_outlined, size: 26, color: AppTheme.brand),
          ),
          const SizedBox(height: 14),
          const Text('No service requests yet',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          const SizedBox(
            width: 320,
            child: Text(
              'When customers submit requests through their client portal, they\'ll appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary, height: 1.6),
            ),
          ),
        ]),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _requests.length,
      itemBuilder: (_, i) {
        final req = _requests[i];
        final leadName =
            (req['leads'] as Map<String, dynamic>?)?['lead_name'] as String? ??
                'Unknown';
        final status = req['status'] as String? ?? 'new';
        final description = req['description'] as String? ?? '';
        final preferredDate = req['preferred_date'] as String?;
        final createdAt = req['created_at'] as String?;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _openDetail(req),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(children: [
                // Status dot
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: _statusColor(status),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(leadName,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: _statusColor(status).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(_capitalize(status),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: _statusColor(status))),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                        description.length > 100
                            ? '${description.substring(0, 100)}...'
                            : description,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Right meta
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (preferredDate != null)
                      Text(_formatDate(preferredDate),
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary)),
                    if (createdAt != null)
                      Text(_timeAgo(createdAt),
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textMuted)),
                  ],
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right,
                    size: 16, color: AppTheme.textSecondary),
              ]),
            ),
          ),
        );
      },
    );
  }

  String _timeAgo(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${(d.inDays / 7).floor()}w ago';
  }
}

// ─────────────────────────────────────────────
//  COMING SOON TAB
// ─────────────────────────────────────────────
class _ComingSoonTab extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _ComingSoonTab({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.borderColor),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 26, color: AppTheme.brand),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 320,
            child: Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: AppTheme.brandActive,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              'Coming soon',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.brand,
              ),
            ),
          ),
        ],
      ),
    );
  }
}