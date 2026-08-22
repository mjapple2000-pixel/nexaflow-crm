import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';
import '../widgets/office_job_form_viewer_sheet.dart';

// ─────────────────────────────────────────────
//  REPORTING SCREEN
// ─────────────────────────────────────────────

class ReportingScreen extends StatefulWidget {
  final int initialTabIndex;
  const ReportingScreen({super.key, this.initialTabIndex = 0});

  @override
  State<ReportingScreen> createState() => _ReportingScreenState();
}

class _ReportingScreenState extends State<ReportingScreen> with SingleTickerProviderStateMixin {
  final _supabase = Supabase.instance.client;
  late TabController _reportTabController;

  // Checklists report state
  List<Map<String, dynamic>> _checklistSubmissions = [];
  bool _loadingChecklists = false;
  String? _checklistsError;
  String _checklistStatusFilter = 'all'; // all | not_started | started
  final _checklistSearchCtrl = TextEditingController();
  // Independent of the 7d/30d/90d chips above — when both are set, they
  // override the day-bucket for the Forms tab's load and its CSV export.
  DateTime? _checklistStartDate;
  DateTime? _checklistEndDate;
  final Set<int> _selectedSubmissionIds = {};
  bool _sendingBulkEmail = false;
  bool _resolvingRecipients = false;

  bool _loading = true;
  String? _error;
  int? _businessId;
  List<Map<String, dynamic>> _teamMembers = [];

  // Stat card data
  int _totalContacts = 0;
  int _totalLeads = 0;
  int _openConversations = 0;
  double _pipelineValue = 0;
  int _totalDeals = 0;
  int _campaignsSent = 0;
  int _totalMessages = 0;
  int _unreadMessages = 0;

  // Chart data
  List<Map<String, dynamic>> _messagesByDay = [];
  List<Map<String, dynamic>> _dealsByStage = [];
  List<Map<String, dynamic>> _campaignStats = [];
  Map<String, int> _convosByChannel = {};
  Map<String, int> _leadsByStatus = {};

  // Date range filter
  String _range = '30'; // 7 | 30 | 90

  // Job Costing report data
  bool _loadingJobCosting = false;
  bool _jobCostingUpgradeRequired = false;
  List<Map<String, dynamic>> _profitByJobType = [];
  List<Map<String, dynamic>> _profitByCalendar = [];
  List<Map<String, dynamic>> _topJobs = [];
  List<Map<String, dynamic>> _bottomJobs = [];

  // Expense report data
  bool _loadingExpenseReport = false;
  bool _expenseReportUpgradeRequired = false;
  int _expenseTotalCents = 0;
  int _expenseBillableCents = 0;
  List<Map<String, dynamic>> _expensesByJob = [];
  List<Map<String, dynamic>> _expensesByMember = [];
  List<Map<String, dynamic>> _expensesByCategory = [];

  // Tax summary report data
  bool _loadingTaxSummary = false;
  String? _taxSummaryError;
  String? _taxJurisdictionName;
  int _taxInvoiceCount = 0;
  double _taxStateAmount = 0;
  double _taxCountyAmount = 0;
  double _taxCityAmount = 0;
  double _taxSpecialAmount = 0;
  double _taxTotalAmount = 0;

  @override
  void initState() {
    super.initState();
    _reportTabController = TabController(length: 5, vsync: this, initialIndex: widget.initialTabIndex);
    _loadData().then((_) => _loadChecklistsReport());
    _loadTaxSummary();
  }

  @override
  void dispose() {
    _reportTabController.dispose();
    _checklistSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final userId = _supabase.auth.currentUser?.id;
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');

      final teamMembersData = await _supabase
          .from('profiles')
          .select('id, full_name')
          .eq('business_id', _businessId!);
      _teamMembers = List<Map<String, dynamic>>.from(teamMembersData as List);

      final since = DateTime.now()
          .subtract(Duration(days: int.parse(_range)))
          .toUtc()
          .toIso8601String();

      // ── Stat cards ──────────────────────────
      final contacts = await _supabase
          .from('contacts')
          .select('id')
          .eq('business_id', _businessId!);
      _totalContacts = (contacts as List).length;

      final leads = await _supabase
          .from('leads')
          .select('id')
          .eq('business_id', _businessId!);
      _totalLeads = (leads as List).length;

      final openConvos = await _supabase
          .from('conversations')
          .select('id')
          .eq('business_id', _businessId!)
          .eq('status', 'open');
      _openConversations = (openConvos as List).length;

      final unread = await _supabase
          .from('conversations')
          .select('unread_count')
          .eq('business_id', _businessId!);
      _unreadMessages = (unread as List)
          .fold(0, (s, c) => s + ((c['unread_count'] as int?) ?? 0));

      final deals = await _supabase
          .from('deals')
          .select('id, value, status')
          .eq('business_id', _businessId!);
      _totalDeals = (deals as List).length;
      _pipelineValue = (deals as List).fold(
          0.0,
          (s, d) =>
              s +
              (d['status'] != 'lost'
                  ? (double.tryParse(d['value']?.toString() ?? '0') ?? 0)
                  : 0));

      final campaigns = await _supabase
          .from('campaigns')
          .select('id, status')
          .eq('business_id', _businessId!);
      _campaignsSent = (campaigns as List)
          .where((c) => c['status'] == 'sent' || c['status'] == 'active')
          .length;

      final messages = await _supabase
          .from('messages')
          .select('id')
          .eq('business_id', _businessId!)
          .gte('created_at', since);
      _totalMessages = (messages as List).length;

      // ── Messages by day ─────────────────────
      final msgByDay = await _supabase
          .from('messages')
          .select('direction, created_at')
          .eq('business_id', _businessId!)
          .gte('created_at', since)
          .order('created_at', ascending: true);

      final dayMap = <String, Map<String, int>>{};
      for (final m in (msgByDay as List)) {
        final dt = DateTime.tryParse(m['created_at'] ?? '')?.toLocal();
        if (dt == null) continue;
        final key = '${dt.month}/${dt.day}';
        dayMap[key] ??= {'inbound': 0, 'outbound': 0};
        final dir = m['direction'] as String? ?? 'inbound';
        dayMap[key]![dir] = (dayMap[key]![dir] ?? 0) + 1;
      }
      _messagesByDay = dayMap.entries
          .map((e) => {
                'day': e.key,
                'inbound': e.value['inbound'] ?? 0,
                'outbound': e.value['outbound'] ?? 0,
              })
          .toList();

      // ── Deals by stage ───────────────────────
      final stageDeals = await _supabase
          .from('deals')
          .select('stage_id, value, pipeline_stages(stage_name)')
          .eq('business_id', _businessId!);

      final stageMap = <String, double>{};
      for (final d in (stageDeals as List)) {
        final stageName =
            d['pipeline_stages']?['stage_name'] as String? ?? 'Unknown';
        final val =
            double.tryParse(d['value']?.toString() ?? '0') ?? 0;
        stageMap[stageName] = (stageMap[stageName] ?? 0) + val;
      }
      _dealsByStage = stageMap.entries
          .map((e) => {'stage': e.key, 'value': e.value})
          .toList();

      // ── Campaign stats ───────────────────────
      final campStats = await _supabase
          .from('campaigns')
          .select(
              'name, sent_count, delivered_count, reply_count, failed_count')
          .eq('business_id', _businessId!)
          .order('created_at', ascending: false)
          .limit(5);
      _campaignStats =
          List<Map<String, dynamic>>.from(campStats as List);

      // ── Conversations by channel ─────────────
      final convos = await _supabase
          .from('conversations')
          .select('channel')
          .eq('business_id', _businessId!);
      final channelMap = <String, int>{};
      for (final c in (convos as List)) {
        final ch = c['channel'] as String? ?? 'sms';
        channelMap[ch] = (channelMap[ch] ?? 0) + 1;
      }
      _convosByChannel = channelMap;

      // ── Leads by status ──────────────────────
      final leadStatus = await _supabase
          .from('leads')
          .select('lead_status')
          .eq('business_id', _businessId!);
      final statusMap = <String, int>{};
      for (final l in (leadStatus as List)) {
        final s = l['lead_status'] as String? ?? 'unknown';
        statusMap[s] = (statusMap[s] ?? 0) + 1;
      }
      _leadsByStatus = statusMap;

      setState(() => _loading = false);
      _loadJobCostingData();
      _loadExpenseReport();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadJobCostingData() async {
    if (_businessId == null) return;
    setState(() { _loadingJobCosting = true; _jobCostingUpgradeRequired = false; });
    try {
      final token = _supabase.auth.currentSession?.accessToken;
      if (token == null) return;
      final resp = await http.get(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-job-costing-report?date_range_days=$_range&business_id=$_businessId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode == 403 && data['error'] == 'upgrade_required') {
        setState(() => _jobCostingUpgradeRequired = true);
        return;
      }
      if (resp.statusCode == 200 && data['success'] == true) {
        setState(() {
          _profitByJobType  = List<Map<String, dynamic>>.from(data['profit_by_job_type']  ?? []);
          _profitByCalendar = List<Map<String, dynamic>>.from(data['profit_by_calendar']  ?? []);
          _topJobs          = List<Map<String, dynamic>>.from(data['top_jobs']             ?? []);
          _bottomJobs       = List<Map<String, dynamic>>.from(data['bottom_jobs']          ?? []);
        });
      }
    } catch (e) {
      debugPrint('Job costing report error: $e');
    } finally {
      if (mounted) setState(() => _loadingJobCosting = false);
    }
  }

  Future<void> _loadExpenseReport() async {
    if (_businessId == null) return;
    setState(() { _loadingExpenseReport = true; _expenseReportUpgradeRequired = false; });
    try {
      final token = _supabase.auth.currentSession?.accessToken;
      if (token == null) return;
      final resp = await http.get(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-expense-report?date_range_days=$_range&business_id=$_businessId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode == 403 && data['error'] == 'upgrade_required') {
        setState(() => _expenseReportUpgradeRequired = true);
        return;
      }
      if (resp.statusCode == 200 && data['success'] == true) {
        setState(() {
          _expenseTotalCents    = data['total_cents'] as int? ?? 0;
          _expenseBillableCents = data['billable_cents'] as int? ?? 0;
          _expensesByJob        = List<Map<String, dynamic>>.from(data['expenses_by_job'] ?? []);
          _expensesByMember     = List<Map<String, dynamic>>.from(data['expenses_by_member'] ?? []);
          _expensesByCategory   = List<Map<String, dynamic>>.from(data['expenses_by_category'] ?? []);
        });
      }
    } catch (e) {
      debugPrint('Expense report error: $e');
    } finally {
      if (mounted) setState(() => _loadingExpenseReport = false);
    }
  }

  Future<void> _loadTaxSummary() async {
    if (_businessId == null) return;
    setState(() { _loadingTaxSummary = true; _taxSummaryError = null; });
    try {
      final token = _supabase.auth.currentSession?.accessToken;
      if (token == null) return;
      final resp = await http.get(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-tax-summary-report?date_range_days=$_range&business_id=$_businessId'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode == 200 && data['success'] == true) {
        final totals = data['totals'] as Map<String, dynamic>? ?? {};
        setState(() {
          _taxJurisdictionName = data['jurisdiction_name'] as String?;
          _taxInvoiceCount = totals['invoice_count'] as int? ?? 0;
          _taxStateAmount = (totals['state_amount'] as num?)?.toDouble() ?? 0;
          _taxCountyAmount = (totals['county_amount'] as num?)?.toDouble() ?? 0;
          _taxCityAmount = (totals['city_amount'] as num?)?.toDouble() ?? 0;
          _taxSpecialAmount = (totals['special_district_amount'] as num?)?.toDouble() ?? 0;
          _taxTotalAmount = (totals['total_tax_amount'] as num?)?.toDouble() ?? 0;
        });
      } else {
        setState(() => _taxSummaryError = data['error'] as String? ?? 'Could not load tax summary.');
      }
    } catch (e) {
      debugPrint('Tax summary report error: $e');
      if (mounted) setState(() => _taxSummaryError = 'Network error — please try again.');
    } finally {
      if (mounted) setState(() => _loadingTaxSummary = false);
    }
  }

  Future<void> _loadChecklistsReport() async {
    if (_businessId == null) return;
    setState(() { _loadingChecklists = true; _checklistsError = null; });
    try {
      final token = _supabase.auth.currentSession?.accessToken;
      if (token == null) return;
      final hasCustomRange = _checklistStartDate != null && _checklistEndDate != null;
      final uri = Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-checklists-report')
          .replace(queryParameters: {
        if (hasCustomRange) 'start_date': _checklistStartDate!.toUtc().toIso8601String(),
        if (hasCustomRange) 'end_date': _checklistEndDate!.toUtc().toIso8601String(),
        if (!hasCustomRange) 'date_range_days': _range,
        'status_filter': _checklistStatusFilter,
        if (_businessId != null) 'business_id': '$_businessId',
      });
      final resp = await http.get(uri, headers: {'Authorization': 'Bearer $token'});
      if (!mounted) return;
      if (resp.statusCode != 200) {
        setState(() { _checklistsError = 'Could not load checklists report.'; _loadingChecklists = false; });
        return;
      }
      final data = jsonDecode(resp.body);
      setState(() {
        _checklistSubmissions = List<Map<String, dynamic>>.from(data['submissions'] ?? []);
        _loadingChecklists = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _checklistsError = 'Network error — please try again.'; _loadingChecklists = false; });
    }
  }

  List<Map<String, dynamic>> get _filteredChecklistSubmissions {
    final q = _checklistSearchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _checklistSubmissions;
    return _checklistSubmissions.where((s) {
      final form = (s['form_name'] ?? '').toString().toLowerCase();
      final label = (s['submission_label'] ?? '').toString().toLowerCase();
      final by = (s['completed_by_name'] ?? '').toString().toLowerCase();
      final lead = (s['lead_name'] ?? '').toString().toLowerCase();
      return form.contains(q) || label.contains(q) || by.contains(q) || lead.contains(q);
    }).toList();
  }

  void _openChecklistViewer(int submissionId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OfficeJobFormViewerSheet(
        submissionId: submissionId,
        businessId: _businessId,
        onSent: _loadChecklistsReport,
      ),
    );
  }

  // Two taps of the same showDatePicker widget already used everywhere
  // else in the app (appointment start/end times, booking dialogs) —
  // deliberately not Flutter's showDateRangePicker, which renders as a
  // completely different, much clunkier full-screen widget.
  Future<void> _pickChecklistDateRange() async {
    final start = await showDatePicker(
      context: context,
      initialDate: _checklistStartDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'Start Date',
    );
    if (start == null || !mounted) return;
    final end = await showDatePicker(
      context: context,
      initialDate: _checklistEndDate != null && _checklistEndDate!.isAfter(start) ? _checklistEndDate! : start,
      firstDate: start,
      lastDate: DateTime.now(),
      helpText: 'End Date',
    );
    if (end == null) return;
    setState(() {
      _checklistStartDate = start;
      // End of the selected day, not midnight, so the last day of the
      // range is fully included rather than excluded.
      _checklistEndDate = DateTime(end.year, end.month, end.day, 23, 59, 59);
    });
    _loadChecklistsReport();
  }

  void _clearChecklistDateRange() {
    setState(() {
      _checklistStartDate = null;
      _checklistEndDate = null;
    });
    _loadChecklistsReport();
  }

  String _fmtChecklistRangeLabel() {
    if (_checklistStartDate == null || _checklistEndDate == null) return 'Date Range';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    String fmt(DateTime d) => '${months[d.month-1]} ${d.day}';
    return '${fmt(_checklistStartDate!)} – ${fmt(_checklistEndDate!)}';
  }

  Future<void> _reassignForm(int? appointmentId, Map<String, dynamic> member) async {
    if (appointmentId == null) return;
    try {
      await _supabase.from('appointments').update({
        'assigned_to': member['full_name'],
        'assigned_to_profile_id': member['id'],
      }).eq('id', appointmentId);
      await _loadChecklistsReport();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to reassign: $e'),
        backgroundColor: AppTheme.error,
      ));
    }
  }

  void _confirmDeleteSubmission(Map<String, dynamic> row) {
    final submissionId = row['submission_id'] as int?;
    if (submissionId == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete Job Form Submission?',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
        content: Text(
          'This removes "${row['form_name'] ?? 'this form'}" for ${row['lead_name'] ?? 'this customer'} from Job Forms. '
          'This cannot be undone.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx, rootNavigator: true).pop();
              _deleteSubmission(submissionId);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // Soft delete, matching the pattern already established in
  // job_forms_screen.dart's _detachForm — nulls appointment_id (not just
  // deleted_at) so the appointment's own Job Forms section correctly
  // stops showing it too, rather than leaving a dangling reference.
  Future<void> _deleteSubmission(int submissionId) async {
    try {
      await _supabase.from('job_form_submissions').update({
        'deleted_at': DateTime.now().toUtc().toIso8601String(),
        'appointment_id': null,
      }).eq('id', submissionId);
      _selectedSubmissionIds.remove(submissionId);
      await _loadChecklistsReport();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to delete: $e'),
        backgroundColor: AppTheme.error,
      ));
    }
  }

  // Sends every selected submission's forms to their respective leads —
  // email-job-forms auto-groups by lead server-side, so a selection
  // spanning multiple customers correctly becomes one email per customer,
  // not one email listing everyone's forms together. No override_email
  // here (unlike the single-form send) since a manually-typed address
  // would incorrectly apply to every recipient in a mixed-lead batch.
  // Resolves which lead(s) the current selection will actually email, so
  // the dialog can show the real address(es) instead of sending blind.
  // Goes submission -> appointment -> appointments.lead_id -> leads.lead_email,
  // the same chain email-job-forms uses server-side, kept in sync with it.
  Future<Map<String, dynamic>> _resolveSelectedRecipients() async {
    final selectedRows = _checklistSubmissions
        .where((r) => _selectedSubmissionIds.contains(r['submission_id'] as int?))
        .toList();
    final unlinkedCount = selectedRows.where((r) => r['appointment_id'] == null).length;
    final appointmentIds = selectedRows
        .map((r) => r['appointment_id'] as int?)
        .whereType<int>()
        .toSet()
        .toList();

    if (appointmentIds.isEmpty) {
      return {'groups': <Map<String, dynamic>>[], 'unlinked': selectedRows.length};
    }

    final appts = await _supabase
        .from('appointments')
        .select('id, lead_id')
        .inFilter('id', appointmentIds);
    final leadIds = List<Map<String, dynamic>>.from(appts)
        .map((a) => a['lead_id'] as int?)
        .whereType<int>()
        .toSet()
        .toList();

    final apptsWithoutLead = List<Map<String, dynamic>>.from(appts).where((a) => a['lead_id'] == null).length;

    if (leadIds.isEmpty) {
      return {'groups': <Map<String, dynamic>>[], 'unlinked': unlinkedCount + apptsWithoutLead};
    }

    final leads = await _supabase
        .from('leads')
        .select('id, lead_name, lead_email')
        .inFilter('id', leadIds);

    return {
      'groups': List<Map<String, dynamic>>.from(leads),
      'unlinked': unlinkedCount + apptsWithoutLead,
    };
  }

  Future<void> _sendBulkEmail({required bool includePdf, required bool includeViewLink, String? overrideEmail}) async {
    if (_selectedSubmissionIds.isEmpty || _businessId == null) return;
    setState(() => _sendingBulkEmail = true);
    try {
      final token = _supabase.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');
      final res = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/email-job-forms'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'business_id': _businessId,
          'submission_ids': _selectedSubmissionIds.toList(),
          'include_pdf': includePdf,
          'include_view_link': includeViewLink,
          if (overrideEmail != null && overrideEmail.trim().isNotEmpty) 'override_email': overrideEmail.trim(),
        }),
      );
      if (!mounted) return;
      final data = res.statusCode == 200 ? jsonDecode(res.body) as Map<String, dynamic> : null;
      final results = data != null ? List<dynamic>.from(data['results'] ?? []) : [];
      final sentCount = results.where((r) => r['sent'] == true).length;
      final failedCount = results.length - sentCount;
      final skippedCount = data != null ? List<dynamic>.from(data['skipped'] ?? []).length : 0;

      if (res.statusCode == 200 && results.isNotEmpty) {
        setState(() => _selectedSubmissionIds.clear());
        final parts = <String>['$sentCount email${sentCount == 1 ? '' : 's'} sent'];
        if (failedCount > 0) parts.add('$failedCount failed');
        if (skippedCount > 0) parts.add('$skippedCount form${skippedCount == 1 ? '' : 's'} skipped (no linked lead)');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(parts.join(' · ')),
          backgroundColor: failedCount > 0 ? AppTheme.error : AppTheme.success,
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(data?['error'] as String? ?? 'Send failed.'),
          backgroundColor: AppTheme.error,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Network error — please try again.'),
        backgroundColor: AppTheme.error,
      ));
    } finally {
      if (mounted) setState(() => _sendingBulkEmail = false);
    }
  }

  Future<void> _showBulkEmailDialog() async {
    setState(() => _resolvingRecipients = true);
    Map<String, dynamic> resolved;
    try {
      resolved = await _resolveSelectedRecipients();
    } catch (e) {
      if (!mounted) return;
      setState(() => _resolvingRecipients = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not look up recipients: $e'),
        backgroundColor: AppTheme.error,
      ));
      return;
    }
    if (!mounted) return;
    setState(() => _resolvingRecipients = false);

    final groups = List<Map<String, dynamic>>.from(resolved['groups'] as List);
    final unlinked = resolved['unlinked'] as int;
    // Editing only makes sense when the whole selection resolves to
    // exactly one recipient — a typed override can't be applied per-lead
    // across a mixed batch, and email-job-forms only accepts one.
    final singleGroup = groups.length == 1 ? groups.first : null;
    final emailCtrl = TextEditingController(text: singleGroup?['lead_email'] as String? ?? '');

    bool includePdf = true;
    bool includeViewLink = true;
    showDialog(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDlgState) => AlertDialog(
          backgroundColor: AppTheme.cardBg,
          title: Text('Email ${_selectedSubmissionIds.length} Selected Form${_selectedSubmissionIds.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary)),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (groups.isEmpty)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'None of the selected forms are linked to a lead with an email on file — nothing will send.',
                    style: TextStyle(fontSize: 12, color: AppTheme.error),
                  ),
                )
              else if (singleGroup != null) ...[
                const Text('Recipient', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                const SizedBox(height: 6),
                Text(singleGroup['lead_name'] as String? ?? '', style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                const SizedBox(height: 6),
                TextField(
                  controller: emailCtrl,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Recipient email',
                    isDense: true,
                    filled: true,
                    fillColor: AppTheme.pageBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ] else ...[
                const Text('Recipients', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                const SizedBox(height: 6),
                ...groups.map((g) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${g['lead_name'] ?? 'Unknown'} — ${g['lead_email'] ?? 'no email on file'}',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                      ),
                    )),
                const SizedBox(height: 4),
                const Text('Multiple recipients — email addresses can\'t be edited for a mixed batch.',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
              ],
              if (unlinked > 0) ...[
                const SizedBox(height: 8),
                Text('$unlinked selected form${unlinked == 1 ? '' : 's'} will be skipped (no linked lead).',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ],
              const SizedBox(height: 14),
              CheckboxListTile(
                value: includePdf,
                onChanged: (v) => setDlgState(() => includePdf = v ?? false),
                title: const Text('Include PDF link', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              CheckboxListTile(
                value: includeViewLink,
                onChanged: (v) => setDlgState(() => includeViewLink = v ?? false),
                title: const Text('Include read-only "View Online" link',
                    style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: (groups.isEmpty || (!includePdf && !includeViewLink))
                  ? null
                  : () {
                      Navigator.of(dctx, rootNavigator: true).pop();
                      _sendBulkEmail(
                        includePdf: includePdf,
                        includeViewLink: includeViewLink,
                        overrideEmail: singleGroup != null ? emailCtrl.text : null,
                      );
                    },
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
          _buildTopBar(),
          Container(
            color: AppTheme.cardBg,
            child: TabBar(
              controller: _reportTabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: AppTheme.brand,
              unselectedLabelColor: AppTheme.textSecondary,
              labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              unselectedLabelStyle: const TextStyle(fontSize: 13),
              indicatorColor: AppTheme.brand,
              indicatorWeight: 2,
              dividerColor: AppTheme.borderColor,
              tabs: const [
                Tab(text: 'Overview'),
                Tab(text: 'Job Costing'),
                Tab(text: 'Expenses'),
                Tab(text: 'Forms'),
                Tab(text: 'Tax'),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _errorView()
                    : TabBarView(
                        controller: _reportTabController,
                        children: [
                          _buildOverviewTab(),
                          _buildJobCostingTab(),
                          _buildExpensesTab(),
                          _buildChecklistsTab(),
                          _buildTaxTab(),
                        ],
                      ),
          ),
        ],
      ),
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
      child: Row(
        children: [
          const Text('Reporting',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const Spacer(),
          // ── Date range filter chips ──
          _rangeChip('7d', '7'),
          const SizedBox(width: 6),
          _rangeChip('30d', '30'),
          const SizedBox(width: 6),
          _rangeChip('90d', '90'),
          const SizedBox(width: 12),
          // ── Refresh button with pointer cursor ──
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh_rounded,
                  size: 18, color: AppTheme.textSecondary),
              tooltip: 'Refresh',
            ),
          ),
        ],
      ),
    );
  }

  Widget _rangeChip(String label, String value) {
    final active = _range == value;
    return Clickable(
      onTap: () {
        setState(() {
          _range = value;
          _checklistStartDate = null;
          _checklistEndDate = null;
        });
        _loadData();
        _loadChecklistsReport();
        _loadTaxSummary();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppTheme.brand : AppTheme.pageBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: active ? AppTheme.brand : AppTheme.borderColor),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  Widget _buildOverviewTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _sectionTitle('Overview'),
        const SizedBox(height: 12),
        _buildStatCards(),
        const SizedBox(height: 28),

        _sectionTitle('Messages (Last $_range days)'),
        const SizedBox(height: 12),
        _buildMessagesChart(),
        const SizedBox(height: 28),

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('Conversations by Channel'),
                  const SizedBox(height: 12),
                  _buildChannelChart(),
                ],
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('Leads by Status'),
                  const SizedBox(height: 12),
                  _buildLeadsChart(),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),

        _sectionTitle('Pipeline Value by Stage'),
        const SizedBox(height: 12),
        _buildPipelineChart(),
        const SizedBox(height: 28),

        _sectionTitle('Recent Campaign Performance'),
        const SizedBox(height: 12),
        _buildCampaignTable(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildJobCostingTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _sectionTitle('Job Costing'),
        const SizedBox(height: 4),
        const Text('Profitability tracking across jobs and calendars.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        _buildJobCostingSection(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildExpensesTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _sectionTitle('Expenses'),
        const SizedBox(height: 4),
        const Text('What\'s being spent, broken down by job, team member, and category.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        _buildExpenseReportSection(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildTaxTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _sectionTitle('Tax Collected'),
        const SizedBox(height: 4),
        const Text('Sales tax actually collected on paid invoices, broken down by taxing entity — use this to know how much to remit and to whom.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        _buildTaxSummarySection(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildTaxSummarySection() {
    if (_loadingTaxSummary) {
      return Container(
        height: 120,
        decoration: _cardDecoration(),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_taxSummaryError != null) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: _cardDecoration(),
        child: Column(children: [
          const Icon(Icons.error_outline, size: 32, color: AppTheme.error),
          const SizedBox(height: 10),
          Text(_taxSummaryError!, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ]),
      );
    }

    if (_taxInvoiceCount == 0) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: _cardDecoration(),
        child: Column(children: [
          const Icon(Icons.receipt_long_outlined, size: 40, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          const Text('No tax collected on paid invoices in this period',
              style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
        ]),
      );
    }

    String fmtMoney(double v) => '\$${v.toStringAsFixed(2)}';

    Widget jurisdictionCard(String label, double amount, Color color) {
      return Expanded(child: Container(
        padding: const EdgeInsets.all(16),
        decoration: _cardDecoration(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          Text(fmtMoney(amount),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
        ]),
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_taxJurisdictionName != null) ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.brand.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.location_on_outlined, size: 15, color: AppTheme.brand),
            const SizedBox(width: 8),
            Text('Jurisdiction: $_taxJurisdictionName',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            const Spacer(),
            Text('$_taxInvoiceCount paid invoice${_taxInvoiceCount == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        ),
        const SizedBox(height: 16),
      ],
      Container(
        padding: const EdgeInsets.all(16),
        decoration: _cardDecoration(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Total Tax Collected', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          Text(fmtMoney(_taxTotalAmount),
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
        ]),
      ),
      const SizedBox(height: 16),
      Row(children: [
        jurisdictionCard('State', _taxStateAmount, const Color(0xFF3B82F6)),
        const SizedBox(width: 12),
        jurisdictionCard('County', _taxCountyAmount, const Color(0xFF8B5CF6)),
        const SizedBox(width: 12),
        jurisdictionCard('City', _taxCityAmount, const Color(0xFF10B981)),
        const SizedBox(width: 12),
        jurisdictionCard('Special District', _taxSpecialAmount, const Color(0xFFF59E0B)),
      ]),
    ]);
  }

  Widget _buildChecklistsTab() {
    final rows = _filteredChecklistSubmissions;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Job Forms'),
          const SizedBox(height: 4),
          const Text('Job form submissions across your team — completed, in progress, and not yet started.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          Row(children: [
            _checklistFilterChip('All', 'all'),
            const SizedBox(width: 8),
            _checklistFilterChip('Completed', 'completed'),
            const SizedBox(width: 8),
            _checklistFilterChip('Started', 'started'),
            const SizedBox(width: 8),
            _checklistFilterChip('Not Started', 'not_started'),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _pickChecklistDateRange,
              icon: const Icon(Icons.date_range_rounded, size: 15),
              label: Text(_fmtChecklistRangeLabel()),
              style: OutlinedButton.styleFrom(
                foregroundColor: _checklistStartDate != null ? AppTheme.brand : AppTheme.textSecondary,
                side: BorderSide(color: _checklistStartDate != null ? AppTheme.brand : AppTheme.borderColor),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            if (_checklistStartDate != null)
              IconButton(
                tooltip: 'Clear custom date range',
                onPressed: _clearChecklistDateRange,
                icon: const Icon(Icons.close, size: 16, color: AppTheme.textSecondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _filteredChecklistSubmissions.isEmpty ? null : _downloadChecklistsCsv,
              icon: const Icon(Icons.download_rounded, size: 15),
              label: const Text('Download CSV'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textSecondary,
                side: const BorderSide(color: AppTheme.borderColor),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(onPressed: _loadChecklistsReport, icon: const Icon(Icons.refresh, size: 18, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            width: 360,
            child: TextField(
              controller: _checklistSearchCtrl,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search forms, techs, customers',
                hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                prefixIcon: const Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
                filled: true, fillColor: AppTheme.cardBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            TextButton.icon(
              onPressed: rows.where((r) => (r['status'] as String? ?? '') == 'completed').isEmpty
                  ? null
                  : () => setState(() {
                        _selectedSubmissionIds.addAll(rows
                            .where((r) => (r['status'] as String? ?? '') == 'completed')
                            .map((r) => r['submission_id'] as int));
                      }),
              icon: const Icon(Icons.checklist_rounded, size: 15),
              label: Text('Select All${_checklistSearchCtrl.text.trim().isNotEmpty ? ' Matching' : ''} Completed'),
              style: TextButton.styleFrom(foregroundColor: AppTheme.textSecondary),
            ),
            if (_selectedSubmissionIds.isNotEmpty) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _selectedSubmissionIds.clear()),
                child: const Text('Clear Selection'),
              ),
              const Spacer(),
              Text('${_selectedSubmissionIds.length} selected',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: (_sendingBulkEmail || _resolvingRecipients) ? null : _showBulkEmailDialog,
                icon: (_sendingBulkEmail || _resolvingRecipients)
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.email_outlined, size: 15, color: Colors.white),
                label: Text(_sendingBulkEmail ? 'Sending...' : (_resolvingRecipients ? 'Looking up...' : 'Email Selected to Lead')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: _loadingChecklists
                ? const Center(child: CircularProgressIndicator())
                : _checklistsError != null
                    ? Center(child: Text(_checklistsError!, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)))
                    : rows.isEmpty
                        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.assignment_outlined, size: 40, color: AppTheme.textMuted),
                            const SizedBox(height: 12),
                            const Text('No checklists found for this range', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          ]))
                        : Container(
                            decoration: _cardDecoration(),
                            child: Column(children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                                child: Row(children: [
                                  const SizedBox(width: 32),
                                  const Expanded(flex: 3, child: Text('FORM', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                                  const Expanded(flex: 2, child: Text('STATUS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                                  const Expanded(flex: 2, child: Text('TECHNICIAN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                                  const Expanded(flex: 3, child: Text('CUSTOMER / LOCATION', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                                  const Expanded(flex: 2, child: Text('UPDATED', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                                  const SizedBox(width: 36),
                                ]),
                              ),
                              Expanded(child: ListView.separated(
                                itemCount: rows.length,
                                separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                                itemBuilder: (_, i) {
                                  final row = rows[i];
                                  final status = row['status'] as String? ?? 'not_started';
                                  final isCompleted = status == 'completed';
                                  final submissionId = row['submission_id'] as int?;
                                  final isSelected = submissionId != null && _selectedSubmissionIds.contains(submissionId);
                                  final content = Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    child: Row(children: [
                                      SizedBox(
                                        width: 32,
                                        child: isCompleted && submissionId != null
                                            ? Checkbox(
                                                value: isSelected,
                                                onChanged: (v) => setState(() {
                                                  if (v == true) {
                                                    _selectedSubmissionIds.add(submissionId);
                                                  } else {
                                                    _selectedSubmissionIds.remove(submissionId);
                                                  }
                                                }),
                                              )
                                            : null,
                                      ),
                                      Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(row['form_name'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
                                        if ((row['submission_label'] as String?)?.isNotEmpty == true)
                                          Text(row['submission_label'], style: const TextStyle(fontSize: 11, color: AppTheme.brand, fontStyle: FontStyle.italic), overflow: TextOverflow.ellipsis),
                                      ])),
                                      Expanded(flex: 2, child: _checklistStatusBadge(
                                        status,
                                        totalRequired: row['total_required'] as int? ?? 0,
                                        missingRequired: row['missing_required'] as int? ?? 0,
                                      )),
                                      Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(row['completed_by_name'] ?? '—', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                                        const SizedBox(height: 4),
                                        PopupMenuButton<Map<String, dynamic>>(
                                          tooltip: 'Reassign this form',
                                          padding: EdgeInsets.zero,
                                          itemBuilder: (_) => _teamMembers.map((m) => PopupMenuItem(
                                            value: m,
                                            child: Text(m['full_name'] ?? 'Unknown', style: const TextStyle(fontSize: 13)),
                                          )).toList(),
                                          onSelected: (member) => _reassignForm(row['appointment_id'] as int?, member),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: AppTheme.brand.withValues(alpha: 0.08),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
                                            ),
                                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                                              Icon(Icons.person_outline, size: 12, color: AppTheme.brand),
                                              SizedBox(width: 4),
                                              Text('Reassign', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.brand)),
                                            ]),
                                          ),
                                        ),
                                      ])),
                                      Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(row['lead_name'] ?? '—', style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                                        if ((row['location'] ?? '').toString().isNotEmpty)
                                          Text(row['location'], style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                                      ])),
                                      Expanded(flex: 2, child: Text(_fmtChecklistDate(row['updated_at']), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                      SizedBox(
                                        width: 36,
                                        child: IconButton(
                                          tooltip: 'Delete Submission',
                                          icon: const Icon(Icons.delete_outline, size: 17, color: AppTheme.textSecondary),
                                          onPressed: () => _confirmDeleteSubmission(row),
                                        ),
                                      ),
                                    ]),
                                  );
                                  return isCompleted
                                      ? InkWell(onTap: () => _openChecklistViewer(row['submission_id'] as int), child: content)
                                      : content;
                                },
                              )),
                            ]),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _checklistFilterChip(String label, String value) {
    final selected = _checklistStatusFilter == value;
    return Clickable(
      onTap: () {
        setState(() => _checklistStatusFilter = value);
        _loadChecklistsReport();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppTheme.brand : AppTheme.cardBg,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: selected ? AppTheme.brand : AppTheme.borderColor),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: selected ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  Widget _checklistStatusBadge(String status, {int totalRequired = 0, int missingRequired = 0}) {
    // Matches Jobber's own model (and the Employee Hub chip's behavior):
    // any non-completed row shows "X of Y required" — including "0 of Y"
    // for a form that's never been opened — a completed row shows the
    // plain status label since there's nothing left to count.
    final completedRequired = totalRequired - missingRequired;
    final label = status == 'completed' || totalRequired == 0
        ? switch (status) {
            'not_started' => 'Not Started',
            'in_progress' => 'In Progress',
            'completed' => 'Completed',
            _ => status,
          }
        : '$completedRequired of $totalRequired required';
    final color = switch (status) {
      'not_started' => AppTheme.textSecondary,
      'in_progress' => const Color(0xFFF59E0B),
      'completed' => AppTheme.success,
      _ => AppTheme.textSecondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  String _fmtChecklistDate(dynamic iso) {
    final dt = DateTime.tryParse(iso?.toString() ?? '')?.toLocal();
    if (dt == null) return '—';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month-1]} ${dt.day}';
  }

  // Wraps a value in quotes and escapes any internal quotes only if the
  // value actually needs it (contains a comma, quote, or newline) — safe
  // for the common no-punctuation case, correct for the rare one.
  String _csvCell(dynamic value) {
    final text = (value ?? '').toString();
    if (text.contains(',') || text.contains('"') || text.contains('\n')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  // Exports exactly what's currently on screen — respects both the
  // status filter chips and the search box, same "download what I'm
  // looking at" principle as the existing bulk-email selection. This is
  // an internal office/owner export (never seen by a customer or field
  // tech), triggered client-side from data already loaded for the table,
  // so there's no server round-trip or email attachment involved.
  void _downloadChecklistsCsv() {
    final rows = _filteredChecklistSubmissions;
    final buffer = StringBuffer();
    buffer.writeln([
      'Form', 'Label', 'Status', 'Completed Required', 'Total Required',
      'Technician', 'Customer', 'Location', 'Updated',
    ].map(_csvCell).join(','));

    for (final row in rows) {
      final totalRequired = row['total_required'] as int? ?? 0;
      final missingRequired = row['missing_required'] as int? ?? 0;
      final completedRequired = totalRequired - missingRequired;
      final statusLabel = switch (row['status'] as String? ?? '') {
        'not_started' => 'Not Started',
        'in_progress' => 'In Progress',
        'completed' => 'Completed',
        final s => s,
      };
      buffer.writeln([
        row['form_name'],
        row['submission_label'],
        statusLabel,
        completedRequired,
        totalRequired,
        row['completed_by_name'],
        row['lead_name'],
        row['location'],
        _fmtChecklistDate(row['updated_at']),
      ].map(_csvCell).join(','));
    }

    final bytes = utf8.encode(buffer.toString());
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'text/csv'),
    );
    final url = web.URL.createObjectURL(blob);
    final dateStr = DateTime.now().toIso8601String().split('T').first;
    web.HTMLAnchorElement()
      ..href = url
      ..style.display = 'none'
      ..download = 'job-forms-report-$dateStr.csv'
      ..click();
    web.URL.revokeObjectURL(url);
  }

  // ── Stat Cards ────────────────────────────

  Widget _buildStatCards() {
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
      childAspectRatio: 1.8,
      children: [
        _StatCard(
          label: 'Total Contacts',
          value: _totalContacts.toString(),
          icon: Icons.people_outline,
          color: const Color(0xFF3B82F6),
        ),
        _StatCard(
          label: 'Total Leads',
          value: _totalLeads.toString(),
          icon: Icons.person_add_outlined,
          color: const Color(0xFF8B5CF6),
        ),
        _StatCard(
          label: 'Open Conversations',
          value: _openConversations.toString(),
          icon: Icons.chat_bubble_outline,
          color: const Color(0xFF10B981),
          subtitle: '$_unreadMessages unread',
        ),
        _StatCard(
          label: 'Pipeline Value',
          value:
              '\$${_pipelineValue >= 1000 ? '${(_pipelineValue / 1000).toStringAsFixed(1)}k' : _pipelineValue.toStringAsFixed(0)}',
          icon: Icons.attach_money_outlined,
          color: const Color(0xFFF59E0B),
          subtitle: '$_totalDeals deals',
        ),
        _StatCard(
          label: 'Messages Sent',
          value: _totalMessages.toString(),
          icon: Icons.send_outlined,
          color: const Color(0xFF06B6D4),
          subtitle: 'Last $_range days',
        ),
        _StatCard(
          label: 'Campaigns Sent',
          value: _campaignsSent.toString(),
          icon: Icons.campaign_outlined,
          color: const Color(0xFFEF4444),
        ),
        _StatCard(
          label: 'SMS Conversations',
          value: (_convosByChannel['sms'] ?? 0).toString(),
          icon: Icons.sms_outlined,
          color: const Color(0xFF3B82F6),
        ),
        _StatCard(
          label: 'Email Conversations',
          value: (_convosByChannel['email'] ?? 0).toString(),
          icon: Icons.email_outlined,
          color: const Color(0xFF10B981),
        ),
      ],
    );
  }

  // ── Messages Chart ────────────────────────

  Widget _buildMessagesChart() {
    if (_messagesByDay.isEmpty) {
      return _emptyChart('No messages in this period');
    }

    final maxVal = _messagesByDay.fold(
        0,
        (m, d) =>
            m > ((d['inbound'] as int) + (d['outbound'] as int))
                ? m
                : (d['inbound'] as int) + (d['outbound'] as int));

    return Container(
      height: 200,
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        children: [
          Row(
            children: [
              _legendDot(const Color(0xFF3B82F6), 'Inbound'),
              const SizedBox(width: 16),
              _legendDot(AppTheme.brand, 'Outbound'),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (_, constraints) {
                final barWidth =
                    (constraints.maxWidth / _messagesByDay.length) - 4;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: _messagesByDay.map((d) {
                    final inbound = d['inbound'] as int;
                    final outbound = d['outbound'] as int;
                    final total = inbound + outbound;
                    final heightFactor =
                        maxVal > 0 ? total / maxVal : 0.0;
                    return Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (total > 0)
                              Text('$total',
                                  style: const TextStyle(
                                      fontSize: 9,
                                      color: AppTheme.textSecondary)),
                            const SizedBox(height: 2),
                            Container(
                              width: barWidth.clamp(4.0, 40.0),
                              height: ((constraints.maxHeight - 40) *
                                      heightFactor)
                                  .clamp(2.0, double.infinity),
                              decoration: BoxDecoration(
                                color: AppTheme.brand,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(d['day'] as String,
                                style: const TextStyle(
                                    fontSize: 8,
                                    color: AppTheme.textSecondary)),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Channel Donut Chart ───────────────────

  Widget _buildChannelChart() {
    final sms = _convosByChannel['sms'] ?? 0;
    final email = _convosByChannel['email'] ?? 0;
    final total = sms + email;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: total == 0
          ? _emptyChart('No conversations yet')
          : Column(
              children: [
                _DonutChart(
                  segments: [
                    _DonutSegment(
                        label: 'SMS',
                        value: sms.toDouble(),
                        color: const Color(0xFF3B82F6)),
                    _DonutSegment(
                        label: 'Email',
                        value: email.toDouble(),
                        color: const Color(0xFF10B981)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _legendDot(
                        const Color(0xFF3B82F6), 'SMS ($sms)'),
                    const SizedBox(width: 16),
                    _legendDot(
                        const Color(0xFF10B981), 'Email ($email)'),
                  ],
                ),
              ],
            ),
    );
  }

  // ── Leads by Status ───────────────────────

  Widget _buildLeadsChart() {
    if (_leadsByStatus.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecoration(),
        child: _emptyChart('No leads yet'),
      );
    }

    final colors = [
      const Color(0xFF3B82F6),
      const Color(0xFF10B981),
      const Color(0xFF8B5CF6),
      const Color(0xFFF59E0B),
      const Color(0xFFEF4444),
      const Color(0xFF06B6D4),
    ];

    final entries = _leadsByStatus.entries.toList();
    final total = entries.fold(0, (s, e) => s + e.value);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        children: entries.asMap().entries.map((entry) {
          final i = entry.key;
          final e = entry.value;
          final pct = total > 0 ? e.value / total : 0.0;
          final color = colors[i % colors.length];
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      e.key[0].toUpperCase() + e.key.substring(1),
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary),
                    ),
                    const Spacer(),
                    Text('${e.value}',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: AppTheme.borderColor,
                    valueColor: AlwaysStoppedAnimation(color),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Pipeline by Stage ─────────────────────

  Widget _buildPipelineChart() {
    if (_dealsByStage.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecoration(),
        child: _emptyChart('No deals in pipeline'),
      );
    }

    final maxVal = _dealsByStage.fold(
        0.0,
        (m, d) =>
            m > (d['value'] as double) ? m : d['value'] as double);

    final colors = [
      AppTheme.brand,
      const Color(0xFF10B981),
      const Color(0xFF3B82F6),
      const Color(0xFF8B5CF6),
      const Color(0xFFF59E0B),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        children: _dealsByStage.asMap().entries.map((entry) {
          final i = entry.key;
          final d = entry.value;
          final val = d['value'] as double;
          final pct = maxVal > 0 ? val / maxVal : 0.0;
          final color = colors[i % colors.length];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(d['stage'] as String,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary)),
                    const Spacer(),
                    Text(
                      '\$${val >= 1000 ? '${(val / 1000).toStringAsFixed(1)}k' : val.toStringAsFixed(0)}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: color),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: AppTheme.borderColor,
                    valueColor: AlwaysStoppedAnimation(color),
                    minHeight: 8,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Campaign Table ────────────────────────

  Widget _buildCampaignTable() {
    if (_campaignStats.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: _cardDecoration(),
        child: _emptyChart('No campaigns yet'),
      );
    }

    return Container(
      decoration: _cardDecoration(),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: const Row(
              children: [
                Expanded(
                    flex: 3,
                    child: Text('Campaign',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                Expanded(
                    child: Text('Sent',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                Expanded(
                    child: Text('Delivered',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                Expanded(
                    child: Text('Replies',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                Expanded(
                    child: Text('Failed',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
              ],
            ),
          ),
          // Rows
          ..._campaignStats.map((c) {
            final sent = c['sent_count'] ?? 0;
            final delivered = c['delivered_count'] ?? 0;
            final replies = c['reply_count'] ?? 0;
            final failed = c['failed_count'] ?? 0;
            return Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 14),
              decoration: const BoxDecoration(
                border: Border(
                    bottom: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(c['name'] ?? 'Untitled',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  Expanded(
                    child: Text('$sent',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textPrimary)),
                  ),
                  Expanded(
                    child: Text('$delivered',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF10B981))),
                  ),
                  Expanded(
                    child: Text('$replies',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.brand)),
                  ),
                  Expanded(
                    child: Text('$failed',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13,
                            color: failed > 0
                                ? Colors.red
                                : AppTheme.textSecondary)),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── Job Costing Section ───────────────────

  Widget _buildJobCostingSection() {
    if (_jobCostingUpgradeRequired) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: _cardDecoration(),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.lock_outline, size: 20, color: AppTheme.brand),
          ),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Job Costing is a Growth Plan feature',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 4),
            const Text('Upgrade to Growth to see profitability by job type, calendar, and individual jobs.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ])),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () {},
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Upgrade'),
          ),
        ]),
      );
    }

    if (_loadingJobCosting) {
      return Container(
        height: 120,
        decoration: _cardDecoration(),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_profitByJobType.isEmpty && _profitByCalendar.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: _cardDecoration(),
        child: Column(children: [
          const Icon(Icons.receipt_long_outlined, size: 40, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          const Text('No job cost data yet',
              style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          const Text('Add expenses to appointments or deals to start tracking profitability.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              textAlign: TextAlign.center),
        ]),
      );
    }

    String _fmtCents(int? cents) {
      if (cents == null) return '—';
      final dollars = cents / 100.0;
      if (dollars >= 1000) return '\$${(dollars / 1000).toStringAsFixed(1)}k';
      return '\$${dollars.toStringAsFixed(0)}';
    }

    return Column(children: [
      // Card 1 — Profitability by Job Type
      if (_profitByJobType.isNotEmpty) ...[
        Container(
          decoration: _cardDecoration(),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
              child: const Row(children: [
                Expanded(flex: 3, child: Text('JOB TYPE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('JOBS', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('AVG REVENUE', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('AVG COST', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('AVG PROFIT', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('MARGIN', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
              ]),
            ),
            ..._profitByJobType.map((row) {
              final profit = row['avg_profit_cents'] as int? ?? 0;
              final margin = row['avg_margin_pct'];
              final profitColor = profit >= 0 ? const Color(0xFF10B981) : AppTheme.error;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(row['job_type'] as String? ?? 'Uncategorized',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
                  Expanded(child: Text('${row['jobs_count'] ?? 0}', textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['avg_revenue_cents'] as int?), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['avg_expenses_cents'] as int?), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['avg_profit_cents'] as int?), textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: profitColor))),
                  Expanded(child: Text(
                    margin != null ? '${(margin as num).toStringAsFixed(1)}%' : '—',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: profitColor),
                  )),
                ]),
              );
            }),
          ]),
        ),
        const SizedBox(height: 16),
      ],

      // Card 2 — Profitability by Calendar
      if (_profitByCalendar.isNotEmpty) ...[
        Container(
          decoration: _cardDecoration(),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
              child: const Row(children: [
                Expanded(flex: 3, child: Text('CALENDAR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('JOBS', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('REVENUE', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('COSTS', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
                Expanded(child: Text('PROFIT', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5))),
              ]),
            ),
            ..._profitByCalendar.map((row) {
              final profit = row['total_profit_cents'] as int? ?? 0;
              final profitColor = profit >= 0 ? const Color(0xFF10B981) : AppTheme.error;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(row['calendar_name'] as String? ?? '—',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
                  Expanded(child: Text('${row['jobs_count'] ?? 0}', textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['total_revenue_cents'] as int?), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['total_expenses_cents'] as int?), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(child: Text(_fmtCents(row['total_profit_cents'] as int?), textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: profitColor))),
                ]),
              );
            }),
          ]),
        ),
        const SizedBox(height: 16),
      ],

      // Card 3 — Top & Bottom Jobs
      if (_topJobs.isNotEmpty || _bottomJobs.isNotEmpty)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Top 5
          Expanded(child: Container(
            decoration: _cardDecoration(),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                child: const Row(children: [
                  Icon(Icons.trending_up_rounded, size: 14, color: Color(0xFF10B981)),
                  SizedBox(width: 6),
                  Text('Most Profitable Jobs', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                ]),
              ),
              ..._topJobs.map((job) => _jobProfitRow(job, positive: true)),
            ]),
          )),
          const SizedBox(width: 16),
          // Bottom 5
          Expanded(child: Container(
            decoration: _cardDecoration(),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                child: const Row(children: [
                  Icon(Icons.trending_down_rounded, size: 14, color: AppTheme.error),
                  SizedBox(width: 6),
                  Text('Least Profitable Jobs', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                ]),
              ),
              ..._bottomJobs.map((job) => _jobProfitRow(job, positive: false)),
            ]),
          )),
        ]),
    ]);
  }

  Widget _buildExpenseReportSection() {
    if (_expenseReportUpgradeRequired) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: _cardDecoration(),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.lock_outline, size: 20, color: AppTheme.brand),
          ),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Expense Reporting is a Growth Plan feature',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 4),
            const Text('Upgrade to Growth to see spend broken down by job, team member, and category.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ])),
          const SizedBox(width: 16),
          ElevatedButton(
            onPressed: () {},
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Upgrade'),
          ),
        ]),
      );
    }

    if (_loadingExpenseReport) {
      return Container(
        height: 120,
        decoration: _cardDecoration(),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_expensesByCategory.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: _cardDecoration(),
        child: Column(children: [
          const Icon(Icons.receipt_long_outlined, size: 40, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          const Text('No expenses logged yet',
              style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          const Text('Add expenses to appointments or deals to see them broken down here.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              textAlign: TextAlign.center),
        ]),
      );
    }

    String fmtCents(int? cents) {
      if (cents == null) return '—';
      final dollars = cents / 100.0;
      if (dollars >= 1000) return '\$${(dollars / 1000).toStringAsFixed(1)}k';
      return '\$${dollars.toStringAsFixed(0)}';
    }

    Widget breakdownCard({
      required String title,
      required IconData icon,
      required List<Map<String, dynamic>> rows,
      required String labelKey,
    }) {
      return Expanded(child: Container(
        decoration: _cardDecoration(),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              Icon(icon, size: 14, color: AppTheme.brand),
              const SizedBox(width: 6),
              Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            ]),
          ),
          ...rows.map((row) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              Expanded(child: Text(
                row[labelKey] as String? ?? 'Unknown',
                style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                overflow: TextOverflow.ellipsis,
              )),
              const SizedBox(width: 8),
              Text('${row['count'] ?? 0}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              const SizedBox(width: 10),
              Text(fmtCents(row['total_cents'] as int?),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            ]),
          )),
        ]),
      ));
    }

    return Column(children: [
      Row(children: [
        Expanded(child: Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Total Expenses', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            const SizedBox(height: 4),
            Text(fmtCents(_expenseTotalCents),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
          ]),
        )),
        const SizedBox(width: 16),
        Expanded(child: Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Billable to Customer', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            const SizedBox(height: 4),
            Text(fmtCents(_expenseBillableCents),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF10B981))),
          ]),
        )),
      ]),
      const SizedBox(height: 16),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        breakdownCard(title: 'BY JOB', icon: Icons.work_outline_rounded, rows: _expensesByJob, labelKey: 'job_name'),
        const SizedBox(width: 16),
        breakdownCard(title: 'BY TEAM MEMBER', icon: Icons.person_outline_rounded, rows: _expensesByMember, labelKey: 'member'),
        const SizedBox(width: 16),
        breakdownCard(title: 'BY CATEGORY', icon: Icons.category_outlined, rows: _expensesByCategory, labelKey: 'category'),
      ]),
    ]);
  }

  Widget _jobProfitRow(Map<String, dynamic> job, {required bool positive}) {
    final cents = job['gross_profit_cents'] as int? ?? 0;
    final dollars = cents / 100.0;
    final color = positive ? const Color(0xFF10B981) : AppTheme.error;
    final name = job['job_name'] as String? ?? 'Untitled';
    final jobType = job['job_type'] as String? ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary),
              overflow: TextOverflow.ellipsis),
          if (jobType.isNotEmpty)
            Text(jobType, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        ])),
        Text(
          dollars >= 0 ? '\$${dollars.toStringAsFixed(0)}' : '-\$${dollars.abs().toStringAsFixed(0)}',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color),
        ),
      ]),
    );
  }

  // ── Helpers ───────────────────────────────

  Widget _sectionTitle(String title) {
    return Text(title,
        style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary));
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(
                fontSize: 11, color: AppTheme.textSecondary)),
      ],
    );
  }

  Widget _emptyChart(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(msg,
            style: const TextStyle(
                fontSize: 13, color: AppTheme.textSecondary)),
      ),
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: AppTheme.cardBg,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppTheme.borderColor),
    );
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 40),
          const SizedBox(height: 12),
          Text(_error!,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 12),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
                onPressed: _loadData, child: const Text('Retry')),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  STAT CARD
// ─────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? subtitle;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
              const Spacer(),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary)),
              Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
              if (subtitle != null)
                Text(subtitle!,
                    style: TextStyle(fontSize: 11, color: color)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  DONUT CHART
// ─────────────────────────────────────────────

class _DonutSegment {
  final String label;
  final double value;
  final Color color;
  const _DonutSegment(
      {required this.label, required this.value, required this.color});
}

class _DonutChart extends StatelessWidget {
  final List<_DonutSegment> segments;
  const _DonutChart({required this.segments});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: CustomPaint(
        painter: _DonutPainter(segments),
        child: Center(
          child: Text(
            segments
                .fold(0.0, (s, e) => s + e.value)
                .toInt()
                .toString(),
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<_DonutSegment> segments;
  _DonutPainter(this.segments);

  @override
  void paint(Canvas canvas, Size size) {
    final total = segments.fold(0.0, (s, e) => s + e.value);
    if (total == 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    double startAngle = -3.14159 / 2;
    for (final seg in segments) {
      final sweepAngle = 2 * 3.14159 * (seg.value / total);
      final paint = Paint()
        ..color = seg.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 20;
      canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}