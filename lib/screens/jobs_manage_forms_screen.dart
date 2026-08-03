import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

// Standalone "Manage Job Forms" screen, living under the Jobs area rather
// than Settings — every job form in one place, usage stats (completed vs.
// pending submissions), archive without deleting, and (once wired
// elsewhere) control whether a form auto-attaches to new appointments.
// Distinct from the Job Forms tab under Jobs (build/edit/attach one at a
// time) and Forms Library (cross-tenant sharing) — this is the
// governance layer neither of those covers. Matches Jobber's own
// Settings → Checklists page in spirit, just placed where Mike wants
// every Jobber-parity thing grouped: alongside Jobs/Timesheets/Routes.
class JobsManageFormsScreen extends StatefulWidget {
  const JobsManageFormsScreen({super.key});

  @override
  State<JobsManageFormsScreen> createState() => _JobsManageFormsScreenState();
}

class _JobsManageFormsScreenState extends State<JobsManageFormsScreen> {
  final _supabase = Supabase.instance.client;
  int? _businessId;
  List<Map<String, dynamic>> _forms = [];
  Map<int, int> _completedCounts = {};
  Map<int, int> _pendingCounts = {};
  bool _loading = true;
  String? _error;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');

      final forms = await _supabase
          .from('job_forms')
          .select()
          .eq('business_id', _businessId!)
          .filter('deleted_at', 'is', null)
          .order('name');
      final formsList = List<Map<String, dynamic>>.from(forms);

      final formIds = formsList.map((f) => f['id']).toList();
      Map<int, int> completed = {};
      Map<int, int> pending = {};
      if (formIds.isNotEmpty) {
        final subs = await _supabase
            .from('job_form_submissions')
            .select('job_form_id, status')
            .inFilter('job_form_id', formIds)
            .eq('business_id', _businessId!)
            .filter('deleted_at', 'is', null);
        for (final s in List<Map<String, dynamic>>.from(subs)) {
          final id = s['job_form_id'] as int;
          if (s['status'] == 'completed') {
            completed[id] = (completed[id] ?? 0) + 1;
          } else {
            pending[id] = (pending[id] ?? 0) + 1;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _forms = formsList;
        _completedCounts = completed;
        _pendingCounts = pending;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchQuery.isEmpty) return _forms;
    final q = _searchQuery.toLowerCase();
    return _forms.where((f) => (f['name'] as String? ?? '').toLowerCase().contains(q)).toList();
  }

  Future<void> _toggleActive(Map<String, dynamic> form) async {
    final newVal = !(form['is_active'] as bool? ?? true);
    await _supabase.from('job_forms').update({'is_active': newVal}).eq('id', form['id']);
    await _load();
  }

  Future<void> _toggleAutoAttach(Map<String, dynamic> form) async {
    final newVal = !(form['auto_attach_to_new_appointments'] as bool? ?? false);
    await _supabase.from('job_forms').update({'auto_attach_to_new_appointments': newVal}).eq('id', form['id']);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(
              color: AppTheme.cardBg,
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Row(children: [
              const Text('Manage Job Forms',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: IconButton(
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded, size: 18, color: AppTheme.textSecondary),
                  tooltip: 'Refresh',
                ),
              ),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.error_outline, color: Colors.red, size: 40),
                          const SizedBox(height: 12),
                          Text(_error!, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                          const SizedBox(height: 12),
                          ElevatedButton(onPressed: _load, child: const Text('Retry')),
                        ]),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Every job form in one place — see how much each one is being used, archive ones you no longer need, and control auto-attach.',
                              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: AppTheme.brand.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
                              ),
                              child: const Row(children: [
                                Icon(Icons.info_outline, size: 16, color: AppTheme.brand),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'To build or attach a new job form, use the Job Forms tab under Jobs. This screen is for managing job forms you\'ve already created.',
                                    style: TextStyle(fontSize: 12, color: AppTheme.brand, height: 1.5),
                                  ),
                                ),
                              ]),
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              width: 340,
                              height: 38,
                              child: TextField(
                                onChanged: (v) => setState(() => _searchQuery = v),
                                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                                decoration: InputDecoration(
                                  hintText: 'Search job forms...',
                                  hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                                  prefixIcon: const Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
                                  filled: true,
                                  fillColor: AppTheme.cardBg,
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: _filtered.isEmpty
                                  ? Center(
                                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                                        const Icon(Icons.checklist_rtl_rounded, size: 48, color: AppTheme.textMuted),
                                        const SizedBox(height: 12),
                                        Text(
                                          _searchQuery.isNotEmpty ? 'No job forms match your search.' : 'No job forms yet.',
                                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                                        ),
                                        const SizedBox(height: 8),
                                        const Text(
                                          'Build your first job form from the Job Forms tab under Jobs — it\'ll show up here once created.',
                                          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                                          textAlign: TextAlign.center,
                                        ),
                                      ]),
                                    )
                                  : Container(
                                      decoration: BoxDecoration(
                                        color: AppTheme.cardBg,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: AppTheme.borderColor),
                                      ),
                                      child: Column(children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                                          child: const Row(children: [
                                            Expanded(flex: 3, child: Text('NAME', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.8))),
                                            Expanded(flex: 2, child: Text('COMPLETED', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.8))),
                                            Expanded(flex: 2, child: Text('PENDING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.8))),
                                            Expanded(flex: 2, child: Text('AUTO-ATTACH', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.8))),
                                            Expanded(flex: 2, child: Text('STATUS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.8))),
                                          ]),
                                        ),
                                        Expanded(
                                          child: ListView.separated(
                                            itemCount: _filtered.length,
                                            separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                                            itemBuilder: (_, i) {
                                              final form = _filtered[i];
                                              final id = form['id'] as int;
                                              final isActive = form['is_active'] as bool? ?? true;
                                              final autoAttach = form['auto_attach_to_new_appointments'] as bool? ?? false;
                                              final completed = _completedCounts[id] ?? 0;
                                              final pending = _pendingCounts[id] ?? 0;
                                              return Container(
                                                color: isActive ? null : AppTheme.pageBg.withValues(alpha: 0.5),
                                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                                child: Row(children: [
                                                  Expanded(flex: 3, child: Text(
                                                    form['name'] as String? ?? '',
                                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isActive ? AppTheme.textPrimary : AppTheme.textSecondary),
                                                    overflow: TextOverflow.ellipsis,
                                                  )),
                                                  Expanded(flex: 2, child: Text('$completed', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                                  Expanded(flex: 2, child: Text('$pending', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                                  Expanded(flex: 2, child: Align(
                                                    alignment: Alignment.centerLeft,
                                                    child: Switch(
                                                      value: autoAttach,
                                                      onChanged: isActive ? (_) => _toggleAutoAttach(form) : null,
                                                      activeColor: AppTheme.brand,
                                                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                    ),
                                                  )),
                                                  Expanded(flex: 2, child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      // Plain status indicator — not tappable, so it never has to
                                                      // double as an unlabeled button.
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                        decoration: BoxDecoration(
                                                          color: isActive ? AppTheme.success.withValues(alpha: 0.1) : AppTheme.textMuted.withValues(alpha: 0.1),
                                                          borderRadius: BorderRadius.circular(99),
                                                        ),
                                                        child: Text(
                                                          isActive ? 'Active' : 'Archived',
                                                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: isActive ? AppTheme.success : AppTheme.textSecondary),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      // The actual action — states exactly what tapping it does,
                                                      // instead of relying on the badge itself looking clickable.
                                                      Clickable(
                                                        onTap: () => _toggleActive(form),
                                                        child: Text(
                                                          isActive ? 'Archive' : 'Restore',
                                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.brand, decoration: TextDecoration.underline),
                                                        ),
                                                      ),
                                                    ],
                                                  )),
                                                ]),
                                              );
                                            },
                                          ),
                                        ),
                                      ]),
                                    ),
                            ),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}