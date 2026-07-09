import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:universal_html/html.dart' as html;
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';

// ─────────────────────────────────────────────
//  MODEL
// ─────────────────────────────────────────────

class _Lead {
  final int id;
  String name;
  String? email;
  String? phone;
  String status;
  String? source;
  String? notes;
  double? estimatedValue;
  List<String> tags;
  DateTime? createdAt;
  DateTime? lastActivity;
  String? businessName;
  String? address;

  _Lead({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    required this.status,
    this.source,
    this.notes,
    this.estimatedValue,
    required this.tags,
    this.createdAt,
    this.lastActivity,
    this.businessName,
    this.address,
  });

  factory _Lead.fromJson(Map<String, dynamic> j) {
    List<String> parsedTags = [];
    final rawTags = j['tags'];
    if (rawTags is List) {
      parsedTags = rawTags.map((t) => t.toString()).toList();
    } else if (rawTags is String && rawTags.isNotEmpty) {
      parsedTags = rawTags
          .replaceAll('[', '').replaceAll(']', '')
          .split(',')
          .map((t) => t.trim().replaceAll('"', ''))
          .where((t) => t.isNotEmpty)
          .toList();
    }
    return _Lead(
      id: (j['id'] as num).toInt(),
      name: j['lead_name'] as String? ?? 'Unknown',
      email: j['lead_email'] as String?,
      phone: j['lead_phone'] as String?,
      status: j['lead_status'] as String? ?? 'New',
      source: j['source'] as String?,
      notes: j['notes'] as String?,
      estimatedValue: (j['estimated_value'] as num?)?.toDouble(),
      tags: parsedTags,
      createdAt: j['date_added'] != null
          ? DateTime.tryParse(j['date_added'] as String)
          : null,
      lastActivity: j['last_message_at'] != null
          ? DateTime.tryParse(j['last_message_at'] as String)
          : null,
      businessName: j['business_name'] as String?,
      address: j['lead_address'] as String?,
    );
  }

  String get initials {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  Color get avatarColor {
    const colors = [
      Color(0xFF6C63FF), Color(0xFF3B82F6), Color(0xFF10B981),
      Color(0xFFF59E0B), Color(0xFFEF4444), Color(0xFF8B5CF6),
      Color(0xFF06B6D4), Color(0xFFEC4899),
    ];
    return colors[name.hashCode.abs() % colors.length];
  }

  Color get statusColor {
    switch (status.toLowerCase()) {
      case 'new':            return const Color(0xFF3B82F6);
      case 'in conversation': return const Color(0xFF8B5CF6);
      case 'qualified':      return const Color(0xFF10B981);
      case 'won':            return const Color(0xFF059669);
      case 'lost':           return const Color(0xFFEF4444);
      case 'unqualified':    return const Color(0xFF6B7280);
      default:               return AppTheme.brand;
    }
  }
}

// ─────────────────────────────────────────────
//  CONTACTS SCREEN
// ─────────────────────────────────────────────

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _db = Supabase.instance.client;
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  bool _loading = true;
  String? _error;
  int? _businessId;

  List<_Lead> _all = [];
  List<_Lead> _filtered = [];
  List<_Lead> _page = [];

  // Pagination
  int _currentPage = 1;
  int _pageSize = 20;
  int get _totalPages => (_filtered.isEmpty ? 1 : (_filtered.length / _pageSize).ceil());

  // Selection
  Set<int> _selected = {};
  bool get _hasSelection => _selected.isNotEmpty;

  // Filters
  String _statusFilter = 'All';
  String _sourceFilter = 'All';
  String _tagFilter    = 'All';
  bool _showFilters    = false;

  // Columns
  bool _colPhone    = true;
  bool _colEmail    = true;
  bool _colCreated  = true;
  bool _colActivity = true;
  bool _colTags     = true;
  bool _colSource   = false;
  bool _colValue    = false;

  // Smart lists
  int _activeList = 0;
  List<String> _listNames = ['All', 'New Leads', 'Won', 'Lost'];
  List<Map<String, dynamic>> _smartLists = [];

  final _statuses = ['All','New','In Conversation','Qualified','Won','Lost','Unqualified'];
  final _sources  = ['All','SMS','Email','Web Form','Manual','Import'];

  static const _supabaseUrl = 'https://rllriopqojaraceytdno.supabase.co';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_applyFilter);
    _loadLeads();
    _loadSmartLists();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── DATA ──────────────────────────────────

  Future<void> _loadLeads() async {
    setState(() { _loading = true; _error = null; });
    try {
      _businessId = await getActiveBusinessId();
      debugPrint('Contacts using business ID: $_businessId');
      if (_businessId == null) return;

      final data = await _db.from('leads').select(
        'id, lead_name, lead_email, lead_phone, lead_status, source, '
        'notes, estimated_value, tags, date_added, last_message_at, '
        'business_name, lead_address'
      ).eq('business_id', _businessId!).order('date_added', ascending: false);

      _all = (data as List).map((j) => _Lead.fromJson(j)).toList();
      _applyFilter();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadSmartLists() async {
    if (_businessId == null) return;
    try {
      final data = await _db
          .from('smart_lists')
          .select('id, name, filters')
          .eq('business_id', _businessId!)
          .order('created_at');
      setState(() {
        _smartLists = List<Map<String, dynamic>>.from(data);
        _listNames = ['All', 'New Leads', 'Won', 'Lost',
          ..._smartLists.map((s) => s['name'] as String)];
      });
    } catch (e) {
      debugPrint('Smart lists error: $e');
    }
  }

  void _applyFilter() {
    var result = List<_Lead>.from(_all);
    if (_activeList == 1) result = result.where((l) => l.status == 'New').toList();
    else if (_activeList == 2) result = result.where((l) => l.status == 'Won').toList();
    else if (_activeList == 3) result = result.where((l) => l.status == 'Lost').toList();
    else if (_activeList >= 4 && _activeList - 4 < _smartLists.length) {
      final saved = _smartLists[_activeList - 4]['filters'] as Map<String, dynamic>;
      final savedStatus = saved['status'] as String? ?? 'All';
      final savedSource = saved['source'] as String? ?? 'All';
      final savedTag    = saved['tag'] as String? ?? 'All';
      if (savedStatus != 'All') result = result.where((l) => l.status == savedStatus).toList();
      if (savedSource != 'All') result = result.where((l) => (l.source ?? '').toLowerCase() == savedSource.toLowerCase()).toList();
      if (savedTag != 'All') result = result.where((l) => l.tags.contains(savedTag)).toList();
    }
    if (_statusFilter != 'All') result = result.where((l) => l.status == _statusFilter).toList();
    if (_sourceFilter != 'All') result = result.where((l) => (l.source ?? '').toLowerCase() == _sourceFilter.toLowerCase()).toList();
    if (_tagFilter != 'All') result = result.where((l) => l.tags.contains(_tagFilter)).toList();
    final q = _searchCtrl.text.toLowerCase();
    if (q.isNotEmpty) {
      result = result.where((l) =>
        l.name.toLowerCase().contains(q) ||
        (l.email ?? '').toLowerCase().contains(q) ||
        (l.phone ?? '').toLowerCase().contains(q) ||
        (l.businessName ?? '').toLowerCase().contains(q)
      ).toList();
    }
    setState(() { _filtered = result; _currentPage = 1; _rebuildPage(); });
  }

  void _rebuildPage() {
    final start = (_currentPage - 1) * _pageSize;
    final end = (start + _pageSize).clamp(0, _filtered.length);
    _page = _filtered.sublist(start, end);
  }

  void _goPage(int p) {
    if (p < 1 || p > _totalPages) return;
    setState(() { _currentPage = p; _rebuildPage(); });
    _scrollCtrl.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  // ── SELECTION ──────────────────────────────

  void _toggleSelect(int id) => setState(() {
    _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
  });

  void _toggleAll() => setState(() {
    _selected.length == _page.length ? _selected.clear() : _selected = _page.map((l) => l.id).toSet();
  });

  void _clearSelection() => setState(() => _selected.clear());

  // ── TAGS list ─────────────────────────────

  List<String> get _allTags {
    final t = <String>{};
    for (final l in _all) t.addAll(l.tags);
    return ['All', ...t.toList()..sort()];
  }

  List<String> get _allTagsNoAll {
    final t = <String>{};
    for (final l in _all) t.addAll(l.tags);
    return t.toList()..sort();
  }

  // ── ADD CONTACT ──────────────────────────

  void _showAdd() => showModalBottomSheet(
    context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
    builder: (_) => _AddSheet(businessId: _businessId ?? 0, onSaved: () { context.pop(); _loadLeads(); }),
  );

  // ── BULK STATUS / DELETE ──────────────────

  Future<void> _bulkStatus(String s) async {
    if (_selected.isEmpty) return;
    await _db.from('leads').update({'lead_status': s}).inFilter('id', _selected.toList());
    _clearSelection(); _loadLeads();
  }

  Future<void> _bulkDelete() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final step1 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 22),
          const SizedBox(width: 8),
          Text('Delete $count contacts?',
            style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
        ]),
        content: const Text(
          'This will permanently remove all their data including messages, appointments, and history.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
        actions: [
          TextButton(onPressed: () => ctx.pop(false),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => ctx.pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B), foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Continue')),
        ],
      ),
    );
    if (step1 != true) return;

    final step2 = await showDialog<bool>(
      context: context,
      builder: (ctx2) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(children: [
          Icon(Icons.delete_forever, color: AppTheme.error, size: 22),
          SizedBox(width: 8),
          Text('Are you absolutely sure?',
            style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w700)),
        ]),
        content: const Text(
          'This action CANNOT be undone. The contacts will be permanently deleted.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
        actions: [
          TextButton(onPressed: () => ctx2.pop(false),
            child: const Text('No, Keep Contacts', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => ctx2.pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Permanently Delete')),
        ],
      ),
    );
    if (step2 != true) return;

    try {
      await _db.from('leads').delete().inFilter('id', _selected.toList());
      _clearSelection(); _loadLeads();
      if (mounted) _snack('$count contacts permanently deleted.');
    } catch (e) {
      if (mounted) _snack('Error: $e');
    }
  }

  // ── BULK TAG ─────────────────────────────

  void _showBulkTag() {
    showDialog(
      context: context,
      builder: (ctx) => _BulkTagDialog(
        existingTags: _allTagsNoAll,
        selectedLeads: _selected.toList(),
        db: _db,
        onDone: (msg) {
          _clearSelection();
          _loadLeads();
          _snack(msg);
        },
      ),
    );
  }

  // ── BULK SMS ─────────────────────────────

  void _showBulkSms() {
    final selectedLeads = _all.where((l) => _selected.contains(l.id)).toList();
    final withPhone = selectedLeads.where((l) => l.phone != null && l.phone!.isNotEmpty).length;
    final noPhone   = selectedLeads.length - withPhone;

    showDialog(
      context: context,
      builder: (ctx) => _BulkSmsDialog(
        selectedCount: selectedLeads.length,
        withPhone: withPhone,
        noPhone: noPhone,
        onSend: (message) async {
        ctx.pop();
          _snack('Sending SMS to $withPhone contacts…');
          try {
            const anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJsbHJpb3Bxb2phcmFjZXl0ZG5vIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzczOTQzMzgsImV4cCI6MjA5Mjk3MDMzOH0.BxTbaRRD_xc88gyWBm5k7ZVVGP8c3CqW5U8aXBmXPMw';
            final res = await http.post(
              Uri.parse('$_supabaseUrl/functions/v1/bulk-sms'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $anonKey',
              },
              body: jsonEncode({
                'lead_ids': _selected.toList(),
                'message': message,
                'business_id': _businessId,
              }),
            );
            if (!mounted) return;
            final data = jsonDecode(res.body);
            final sent    = data['sent'] ?? 0;
            final skipped = data['skipped'] ?? 0;
            _clearSelection();
            _loadLeads();
            _snack('SMS sent to $sent contacts${skipped > 0 ? ', $skipped skipped (no phone)' : ''}.');
          } catch (e) {
            if (mounted) _snack('Error: $e');
          }
        },
      ),
    );
  }

  // ── BULK EMAIL ───────────────────────────

  void _showBulkEmail() {
    final selectedLeads = _all.where((l) => _selected.contains(l.id)).toList();
    final withEmail = selectedLeads.where((l) => l.email != null && l.email!.isNotEmpty).length;
    final noEmail   = selectedLeads.length - withEmail;

    showDialog(
      context: context,
      builder: (ctx) => _BulkEmailDialog(
        selectedCount: selectedLeads.length,
        withEmail: withEmail,
        noEmail: noEmail,
        onSend: (subject, body) async {
        ctx.pop();
          _snack('Sending email to $withEmail contacts…');
          try {
            const anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJsbHJpb3Bxb2phcmFjZXl0ZG5vIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzczOTQzMzgsImV4cCI6MjA5Mjk3MDMzOH0.BxTbaRRD_xc88gyWBm5k7ZVVGP8c3CqW5U8aXBmXPMw';
            final res = await http.post(
              Uri.parse('$_supabaseUrl/functions/v1/bulk-email'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $anonKey',
              },
              body: jsonEncode({
                'lead_ids': _selected.toList(),
                'subject': subject,
                'body': body,
                'business_id': _businessId,
              }),
            );
            if (!mounted) return;
            final data = jsonDecode(res.body);
            final sent    = data['sent'] ?? 0;
            final skipped = data['skipped'] ?? 0;
            _clearSelection();
            _loadLeads();
            _snack('Email sent to $sent contacts${skipped > 0 ? ', $skipped skipped (no email)' : ''}.');
          } catch (e) {
            if (mounted) _snack('Error: $e');
          }
        },
      ),
    );
  }

  // ── EXPORT CSV ────────────────────────────

  void _exportCsv() {
    if (_filtered.isEmpty) { _snack('No contacts to export.'); return; }
    try {
      final rows = <List<dynamic>>[
        ['Name', 'Email', 'Phone', 'Status', 'Source', 'Business', 'Address', 'Created', 'Tags'],
      ];
      for (final l in _filtered) {
        rows.add([l.name, l.email ?? '', l.phone ?? '', l.status,
          l.source ?? '', l.businessName ?? '', l.address ?? '',
          l.createdAt?.toIso8601String() ?? '', l.tags.join('; ')]);
      }
      final csv   = const ListToCsvConverter().convert(rows);
      final bytes = utf8.encode(csv);
      final blob  = html.Blob([bytes], 'text/csv');
      final url   = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', 'contacts_${DateTime.now().millisecondsSinceEpoch}.csv')
        ..click();
      html.Url.revokeObjectUrl(url);
      _snack('Exported ${_filtered.length} contacts.');
    } catch (e) { _snack('Export failed: $e'); }
  }

  // ── IMPORT CSV ───────────────────────────

  Future<void> _importCsv() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['csv'], withData: true);
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null) return;
    final csvString = utf8.decode(bytes);
    showDialog(
      context: context, barrierDismissible: false,
      builder: (_) => _ImportCsvDialog(
        csvString: csvString, businessId: _businessId ?? 0,
        onImported: (count) { context.pop(); _loadLeads(); _snack('Imported $count contacts successfully!'); },
      ),
    );
  }

  // ── MANAGE SMART LISTS ───────────────────

  void _showManageSmartLists() {
    showDialog(
      context: context,
      builder: (_) => _SmartListsDialog(
        businessId: _businessId ?? 0,
        currentFilters: { 'status': _statusFilter, 'source': _sourceFilter, 'tag': _tagFilter },
        onChanged: () => _loadSmartLists(),
      ),
    ).then((_) { if (mounted) _loadSmartLists(); });
  }

  void _snack(String msg) {
  if (!mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), backgroundColor: AppTheme.brand,
      duration: const Duration(seconds: 3)));
}

  // ─────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTopBar(),
          _buildTabs(),
          if (_showFilters) _buildFilterBar(),
          if (_hasSelection) _buildBulkBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppTheme.brand))
                : _error != null ? _buildError()
                : _filtered.isEmpty ? _buildEmpty()
                : _buildTable(),
          ),
          _buildPagination(),
        ],
      ),
    );
  }

  // ── TOP BAR ──────────────────────────────

  Widget _buildTopBar() {
    return Container(
      color: AppTheme.cardBg,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Row(children: [
        Text('Contacts', style: const TextStyle(
          fontSize: 20, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
          child: Text('${_filtered.length}', style: const TextStyle(color: AppTheme.brand, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        const Spacer(),
        SizedBox(width: 220, height: 36,
          child: TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Quick search...',
              hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              prefixIcon: const Icon(Icons.search, color: AppTheme.textSecondary, size: 16),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? GestureDetector(onTap: () { _searchCtrl.clear(); _applyFilter(); },
                      child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 14))
                  : null,
              filled: true, fillColor: AppTheme.pageBg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _btn(Icons.add, 'Add Contact', primary: true, onTap: _showAdd),
        const SizedBox(width: 8),
        _iconBtn(Icons.filter_list_rounded, 'Filters',
          active: _showFilters || _statusFilter != 'All' || _sourceFilter != 'All' || _tagFilter != 'All',
          onTap: () => setState(() => _showFilters = !_showFilters)),
        const SizedBox(width: 6),
        _iconBtn(Icons.view_column_outlined, 'Columns', onTap: _showColumnPicker),
        const SizedBox(width: 6),
        _iconBtn(Icons.refresh_rounded, 'Refresh', onTap: _loadLeads),
        const SizedBox(width: 6),
        _iconBtn(Icons.upload_file_outlined, 'Import CSV', onTap: _importCsv),
        const SizedBox(width: 6),
        _iconBtn(Icons.download_outlined, 'Export CSV', onTap: _exportCsv),
      ]),
    );
  }

  Widget _btn(IconData icon, String label, {bool primary = false, required VoidCallback onTap}) {
    return MouseRegion(cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap,
        child: Container(
          height: 36, padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: primary ? AppTheme.brand : AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: primary ? AppTheme.brand : AppTheme.borderColor),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: primary ? Colors.white : AppTheme.textPrimary),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                color: primary ? Colors.white : AppTheme.textPrimary)),
          ]),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, {bool active = false, required VoidCallback onTap}) {
    return Tooltip(message: tooltip,
      child: MouseRegion(cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap,
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: active ? AppTheme.brand.withValues(alpha: 0.1) : AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: active ? AppTheme.brand.withValues(alpha: 0.4) : AppTheme.borderColor),
            ),
            child: Icon(icon, size: 16, color: active ? AppTheme.brand : AppTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  // ── TABS ─────────────────────────────────

  Widget _buildTabs() {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(children: [
          ...List.generate(_listNames.length, (i) {
            final active = _activeList == i;
            return GestureDetector(
              onTap: () { setState(() => _activeList = i); _applyFilter(); },
              child: MouseRegion(cursor: SystemMouseCursors.click,
                child: Container(
                  height: 44, margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(
                      color: active ? AppTheme.brand : Colors.transparent, width: 2))),
                  child: Center(child: Text(_listNames[i], style: TextStyle(
                    color: active ? AppTheme.brand : AppTheme.textSecondary,
                    fontSize: 13, fontWeight: active ? FontWeight.w600 : FontWeight.w400))),
                ),
              ),
            );
          }),
          Container(height: 20, width: 1, color: AppTheme.borderColor, margin: const EdgeInsets.symmetric(horizontal: 8)),
          GestureDetector(
            onTap: _showManageSmartLists,
            child: MouseRegion(cursor: SystemMouseCursors.click,
              child: Container(height: 44, alignment: Alignment.center,
                child: Row(mainAxisSize: MainAxisSize.min, children: const [
                  Icon(Icons.settings_outlined, size: 14, color: Color(0xFF9B9B9B)),
                  SizedBox(width: 5),
                  Text('Manage Smart Lists', style: TextStyle(color: Color(0xFF9B9B9B), fontSize: 12)),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // ── FILTER BAR ───────────────────────────

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      color: AppTheme.cardBg,
      child: Row(children: [
        const Text('Filters:', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        _filterDrop('Status', _statusFilter, _statuses, (v) => setState(() { _statusFilter = v!; _applyFilter(); })),
        const SizedBox(width: 8),
        _filterDrop('Source', _sourceFilter, _sources, (v) => setState(() { _sourceFilter = v!; _applyFilter(); })),
        const SizedBox(width: 8),
        _filterDrop('Tag', _tagFilter, _allTags, (v) => setState(() { _tagFilter = v!; _applyFilter(); })),
        const SizedBox(width: 12),
        if (_statusFilter != 'All' || _sourceFilter != 'All' || _tagFilter != 'All')
          GestureDetector(
            onTap: () => setState(() { _statusFilter = 'All'; _sourceFilter = 'All'; _tagFilter = 'All'; _applyFilter(); }),
            child: MouseRegion(cursor: SystemMouseCursors.click,
              child: Row(children: const [
                Icon(Icons.close, size: 13, color: AppTheme.textSecondary),
                SizedBox(width: 3),
                Text('Clear', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _filterDrop(String label, String value, List<String> items, ValueChanged<String?> onChange) {
    return Container(
      height: 32, padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: value != 'All' ? AppTheme.brand.withValues(alpha: 0.08) : AppTheme.pageBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: value != 'All' ? AppTheme.brand.withValues(alpha: 0.4) : AppTheme.borderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value, onChanged: onChange,
          dropdownColor: AppTheme.cardBg, isDense: true,
          style: TextStyle(color: value != 'All' ? AppTheme.brand : AppTheme.textSecondary, fontSize: 12),
          items: items.map((s) => DropdownMenuItem(value: s,
            child: Text(s == 'All' ? '$label: All' : s))).toList(),
        ),
      ),
    );
  }

  // ── BULK BAR ─────────────────────────────

  Widget _buildBulkBar() {
    return Container(
      height: 46,
      color: AppTheme.brand.withValues(alpha: 0.06),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(children: [
        Container(width: 20, height: 20,
          decoration: BoxDecoration(color: AppTheme.brand, borderRadius: BorderRadius.circular(4)),
          child: const Icon(Icons.check, color: Colors.white, size: 14)),
        const SizedBox(width: 10),
        Text('${_selected.length} selected',
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(width: 20),
        _bulkBtn(Icons.local_offer_outlined, 'Tag', _showBulkTag),
        const SizedBox(width: 8),
        _bulkBtn(Icons.email_outlined, 'Email', _showBulkEmail),
        const SizedBox(width: 8),
        _bulkBtn(Icons.sms_outlined, 'SMS', _showBulkSms),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          color: AppTheme.cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          tooltip: 'Change status', onSelected: _bulkStatus,
          itemBuilder: (_) => ['New','Qualified','Won','Lost','Unqualified']
              .map((s) => PopupMenuItem(value: s,
                child: Text(s, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)))).toList(),
          child: _bulkBtn(Icons.swap_horiz, 'Change Status', () {}),
        ),
        const Spacer(),
        _bulkBtn(Icons.delete_outline, 'Delete', _bulkDelete, color: AppTheme.error),
        const SizedBox(width: 12),
        GestureDetector(onTap: _clearSelection,
          child: MouseRegion(cursor: SystemMouseCursors.click,
            child: Row(children: const [
              Icon(Icons.close, size: 14, color: AppTheme.textSecondary),
              SizedBox(width: 4),
              Text('Clear', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bulkBtn(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    return MouseRegion(cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap,
        child: Container(
          height: 30, padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(children: [
            Icon(icon, size: 14, color: color ?? AppTheme.textSecondary),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, color: color ?? AppTheme.textSecondary)),
          ]),
        ),
      ),
    );
  }

  // ── TABLE ────────────────────────────────

  Widget _buildTable() {
    return Container(
      margin: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(children: [
        _buildTableHeader(),
        const Divider(height: 1, color: AppTheme.borderColor),
        Expanded(
          child: ListView.separated(
            controller: _scrollCtrl,
            itemCount: _page.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
            itemBuilder: (_, i) => _buildRow(_page[i]),
          ),
        ),
      ]),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      height: 40, color: AppTheme.pageBg,
      child: Row(children: [
        _checkboxCell(_selected.length == _page.length && _page.isNotEmpty, _toggleAll, header: true),
        _hCell('Name', flex: 3),
        if (_colPhone)    _hCell('Phone', flex: 2),
        if (_colEmail)    _hCell('Email', flex: 3),
        if (_colCreated)  _hCell('Created', flex: 2),
        if (_colActivity) _hCell('Last Activity', flex: 2),
        if (_colTags)     _hCell('Tags', flex: 2),
        if (_colSource)   _hCell('Source', flex: 1),
        if (_colValue)    _hCell('Value', flex: 1),
        const SizedBox(width: 48),
      ]),
    );
  }

  Widget _hCell(String label, {int flex = 1}) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(label, style: const TextStyle(
        color: AppTheme.textSecondary, fontSize: 11,
        fontWeight: FontWeight.w600, letterSpacing: 0.4)),
    ),
  );

  Widget _checkboxCell(bool checked, VoidCallback onTap, {bool header = false}) {
    return SizedBox(width: 48, child: Center(
      child: GestureDetector(onTap: onTap,
        child: MouseRegion(cursor: SystemMouseCursors.click,
          child: Container(
            width: 16, height: 16,
            decoration: BoxDecoration(
              color: checked ? AppTheme.brand : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: checked ? AppTheme.brand : AppTheme.borderColor, width: 1.5),
            ),
            child: checked ? const Icon(Icons.check, size: 11, color: Colors.white) : null,
          ),
        ),
      ),
    ));
  }

  Widget _buildRow(_Lead lead) {
    final selected = _selected.contains(lead.id);
    return GestureDetector(
      onTap: () => context.push('/contacts/${lead.id}'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 56,
          color: selected ? AppTheme.brand.withValues(alpha: 0.04) : AppTheme.cardBg,
          child: Row(children: [
            GestureDetector(
              onTap: () => _toggleSelect(lead.id),
              behavior: HitTestBehavior.opaque,
              child: _checkboxCell(selected, () => _toggleSelect(lead.id)),
            ),
            Expanded(flex: 3, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Container(
                  width: 34, height: 34,
                  decoration: BoxDecoration(color: lead.avatarColor, shape: BoxShape.circle),
                  child: Center(child: Text(lead.initials,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lead.name, style: const TextStyle(
                      color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Row(children: [
                      _statusBadge(lead.status, lead.statusColor),
                      if (lead.businessName != null && lead.businessName!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(child: Text(lead.businessName!,
                          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                          overflow: TextOverflow.ellipsis)),
                      ],
                    ]),
                  ],
                )),
              ]),
            )),
            if (_colPhone) Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: lead.phone != null && lead.phone!.isNotEmpty
                  ? Row(children: [
                      const Icon(Icons.phone_outlined, size: 12, color: AppTheme.textSecondary),
                      const SizedBox(width: 5),
                      Expanded(child: Text(lead.phone!,
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                        overflow: TextOverflow.ellipsis)),
                    ])
                  : const Text('—', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            )),
            if (_colEmail) Expanded(flex: 3, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: lead.email != null && lead.email!.isNotEmpty
                  ? Row(children: [
                      const Icon(Icons.email_outlined, size: 12, color: AppTheme.textSecondary),
                      const SizedBox(width: 5),
                      Expanded(child: Text(lead.email!,
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                        overflow: TextOverflow.ellipsis)),
                    ])
                  : const Text('—', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            )),
            if (_colCreated) Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: lead.createdAt != null
                  ? Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_fmtDate(lead.createdAt!), style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
                      Text(_fmtTime(lead.createdAt!), style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10)),
                    ])
                  : const Text('—', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            )),
            if (_colActivity) Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: lead.lastActivity != null
                  ? Row(children: [
                      const Icon(Icons.chat_bubble_outline, size: 11, color: AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text(_timeAgo(lead.lastActivity!),
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                    ])
                  : const Text('—', style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
            )),
            if (_colTags) Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: lead.tags.isEmpty
                  ? const Text('—', style: TextStyle(color: AppTheme.textSecondary, fontSize: 11))
                  : SingleChildScrollView(scrollDirection: Axis.horizontal,
                      child: Row(children: lead.tags.take(3).map(_tagChip).toList())),
            )),
            if (_colSource) Expanded(flex: 1, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(lead.source ?? '—',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                overflow: TextOverflow.ellipsis),
            )),
            if (_colValue) Expanded(flex: 1, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                lead.estimatedValue != null && lead.estimatedValue! > 0
                    ? '\$${lead.estimatedValue!.toStringAsFixed(0)}' : '—',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            )),
            SizedBox(width: 48, child: PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, color: AppTheme.textSecondary, size: 18),
              color: AppTheme.cardBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              onSelected: (a) async {
                if (a == 'view') context.push('/contacts/${lead.id}');
                else if (a == 'delete') _deleteLead(lead);
              },
              itemBuilder: (_) => [
                _menuItem('view', Icons.open_in_new, 'View Details'),
                const PopupMenuDivider(),
                _menuItem('delete', Icons.delete_outline, 'Delete', color: AppTheme.error),
              ],
            )),
          ]),
        ),
      ),
    );
  }

  Widget _statusBadge(String status, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4)),
    child: Text(status, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
  );

  Widget _tagChip(String tag) => Container(
    margin: const EdgeInsets.only(right: 4),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.borderColor)),
    child: Text(tag, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 10)),
  );

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {Color? color}) =>
    PopupMenuItem(value: value, child: Row(children: [
      Icon(icon, size: 14, color: color ?? AppTheme.textSecondary),
      const SizedBox(width: 8),
      Text(label, style: TextStyle(color: color ?? AppTheme.textPrimary, fontSize: 13)),
    ]));

  // ── PAGINATION ───────────────────────────

  Widget _buildPagination() {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(children: [
        Text('Total ${_filtered.length} records  |  Page $_currentPage of $_totalPages',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        const Spacer(),
        _pgBtn(Icons.chevron_left, () => _goPage(_currentPage - 1), _currentPage > 1),
        const SizedBox(width: 4),
        Container(
          width: 30, height: 28,
          decoration: BoxDecoration(color: AppTheme.brand, borderRadius: BorderRadius.circular(6)),
          child: Center(child: Text('$_currentPage',
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
        ),
        const SizedBox(width: 4),
        _pgBtn(Icons.chevron_right, () => _goPage(_currentPage + 1), _currentPage < _totalPages),
        const SizedBox(width: 16),
        const Text('Page Size:', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        const SizedBox(width: 8),
        DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: _pageSize, dropdownColor: AppTheme.cardBg,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
            items: [20, 50, 100].map((n) => DropdownMenuItem(value: n, child: Text('$n'))).toList(),
            onChanged: (v) => setState(() { _pageSize = v!; _currentPage = 1; _rebuildPage(); }),
          ),
        ),
      ]),
    );
  }

  Widget _pgBtn(IconData icon, VoidCallback onTap, bool enabled) =>
    MouseRegion(cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(onTap: enabled ? onTap : null,
        child: Container(
          width: 28, height: 28,
          decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.borderColor)),
          child: Icon(icon, size: 16, color: enabled ? AppTheme.textSecondary : AppTheme.textMuted),
        ),
      ),
    );

  // ── EMPTY / ERROR ────────────────────────

  Widget _buildEmpty() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.people_outline, size: 56, color: AppTheme.borderColor),
      const SizedBox(height: 16),
      Text(_searchCtrl.text.isNotEmpty ? 'No contacts match your search' : 'No contacts yet',
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
      const SizedBox(height: 12),
      MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: _showAdd,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(color: AppTheme.brand, borderRadius: BorderRadius.circular(8)),
          child: const Text('Add First Contact', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      )),
    ]));
  }

  Widget _buildError() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.error_outline, color: AppTheme.error, size: 40),
    const SizedBox(height: 12),
    Text(_error ?? 'Unknown error', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13), textAlign: TextAlign.center),
    const SizedBox(height: 12),
    TextButton.icon(onPressed: _loadLeads,
      icon: const Icon(Icons.refresh, color: AppTheme.brand),
      label: const Text('Retry', style: TextStyle(color: AppTheme.brand))),
  ]));

  // ── COLUMN PICKER ────────────────────────

  void _showColumnPicker() {
  // Capture current values
  var phone    = _colPhone;
  var email    = _colEmail;
  var created  = _colCreated;
  var activity = _colActivity;
  var tags     = _colTags;
  var source   = _colSource;
  var value    = _colValue;

  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('Customize Columns',
        style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 16)),
      content: StatefulBuilder(builder: (ctx, setS) => Column(mainAxisSize: MainAxisSize.min, children: [
        _colTgl('Phone',         phone,    setS, (v) { phone    = v; }),
        _colTgl('Email',         email,    setS, (v) { email    = v; }),
        _colTgl('Created Date',  created,  setS, (v) { created  = v; }),
        _colTgl('Last Activity', activity, setS, (v) { activity = v; }),
        _colTgl('Tags',          tags,     setS, (v) { tags     = v; }),
        _colTgl('Source',        source,   setS, (v) { source   = v; }),
        _colTgl('Est. Value',    value,    setS, (v) { value    = v; }),
      ])),
      actions: [TextButton(
        onPressed: () => context.pop(),
        child: const Text('Done', style: TextStyle(color: AppTheme.brand)))],
    ),
  ).then((_) {
    // Apply all changes AFTER dialog is fully closed
    if (mounted) setState(() {
      _colPhone    = phone;
      _colEmail    = email;
      _colCreated  = created;
      _colActivity = activity;
      _colTags     = tags;
      _colSource   = source;
      _colValue    = value;
    });
  });
}

  Widget _colTgl(String label, bool value, StateSetter setS, Function(bool) onChanged) =>
  SwitchListTile(
    title: Text(label, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
    value: value, activeColor: AppTheme.brand, dense: true,
    onChanged: (v) => setS(() => onChanged(v)),
  );

  // ── DELETE ───────────────────────────────

  Future<void> _deleteLead(_Lead lead) async {
    final step1 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 22),
          const SizedBox(width: 8),
          Text('Delete ${lead.name}?',
            style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
        ]),
        content: const Text(
          'This will permanently remove all their data including messages, appointments, and history.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
        actions: [
          TextButton(onPressed: () => ctx.pop(false),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => ctx.pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B), foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Continue')),
        ],
      ),
    );
    if (step1 != true) return;

    final step2 = await showDialog<bool>(
      context: context,
      builder: (ctx2) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(children: [
          Icon(Icons.delete_forever, color: AppTheme.error, size: 22),
          SizedBox(width: 8),
          Text('Are you absolutely sure?',
            style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w700)),
        ]),
        content: const Text(
          'This action CANNOT be undone. The contact will be permanently deleted.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
        actions: [
          TextButton(onPressed: () => ctx2.pop(false),
            child: const Text('No, Keep Contact', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => ctx2.pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Permanently Delete')),
        ],
      ),
    );
    if (step2 != true) return;

    try {
      await _db.from('leads').delete().eq('id', lead.id);
      _loadLeads();
      if (mounted) _snack('${lead.name} permanently deleted.');
    } catch (e) {
      if (mounted) _snack('Error: $e');
    }
  }

  // ── HELPERS ──────────────────────────────

  String _fmtDate(DateTime dt) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }

  String _fmtTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$min $ampm';
  }

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    if (d.inDays < 30) return '${(d.inDays / 7).floor()}w ago';
    return _fmtDate(dt);
  }
}

// ─────────────────────────────────────────────
//  BULK TAG DIALOG
// ─────────────────────────────────────────────

class _BulkTagDialog extends StatefulWidget {
  final List<String> existingTags;
  final List<int> selectedLeads;
  final SupabaseClient db;
  final void Function(String msg) onDone;

  const _BulkTagDialog({
    required this.existingTags,
    required this.selectedLeads,
    required this.db,
    required this.onDone,
  });

  @override
  State<_BulkTagDialog> createState() => _BulkTagDialogState();
}

class _BulkTagDialogState extends State<_BulkTagDialog> {
  final _newTagCtrl = TextEditingController();
  Set<String> _selectedTags = {};
  String _mode = 'add'; // 'add' or 'remove'
  bool _saving = false;

  static const _suggestedTags = [
    'Hot Lead', 'Follow Up', 'VIP', 'Cold', 'Booked',
    'No Answer', 'Left Voicemail', 'Interested', 'Not Interested',
  ];

  @override
  void dispose() { _newTagCtrl.dispose(); super.dispose(); }

  List<String> get _allTags {
    final t = <String>{...widget.existingTags, ..._suggestedTags};
    return t.toList()..sort();
  }

  Future<void> _apply() async {
    if (_selectedTags.isEmpty) return;
    setState(() => _saving = true);
    try {
      // Fetch current tags for each lead
      final data = await widget.db
          .from('leads')
          .select('id, tags')
          .inFilter('id', widget.selectedLeads);

      for (final lead in data as List) {
        final id = (lead['id'] as num).toInt();
        List<String> current = [];
        final raw = lead['tags'];
        if (raw is List) current = raw.map((t) => t.toString()).toList();

        List<String> updated;
        if (_mode == 'add') {
          updated = {...current, ..._selectedTags}.toList();
        } else {
          updated = current.where((t) => !_selectedTags.contains(t)).toList();
        }

        await widget.db.from('leads').update({'tags': updated}).eq('id', id);
      }

      final verb = _mode == 'add' ? 'added to' : 'removed from';
      final msg = 'Tags $verb ${widget.selectedLeads.length} contacts.';
        if (mounted) {
   context.pop();
    widget.onDone(msg);
}
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.local_offer_outlined, color: AppTheme.brand, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('Tag ${widget.selectedLeads.length} contacts',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
              GestureDetector(onTap: () => context.pop(),
                child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 20)),
            ]),
          ),

          Padding(padding: const EdgeInsets.all(20), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [

            // Mode toggle
            Container(
              decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
              child: Row(children: [
                Expanded(child: GestureDetector(
                  onTap: () => setState(() => _mode = 'add'),
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: _mode == 'add' ? AppTheme.brand : Colors.transparent,
                      borderRadius: BorderRadius.circular(7)),
                    child: Center(child: Text('Add Tags',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: _mode == 'add' ? Colors.white : AppTheme.textSecondary))),
                  ),
                )),
                Expanded(child: GestureDetector(
                  onTap: () => setState(() => _mode = 'remove'),
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: _mode == 'remove' ? AppTheme.error : Colors.transparent,
                      borderRadius: BorderRadius.circular(7)),
                    child: Center(child: Text('Remove Tags',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: _mode == 'remove' ? Colors.white : AppTheme.textSecondary))),
                  ),
                )),
              ]),
            ),

            const SizedBox(height: 16),
            const Text('SELECT TAGS', style: TextStyle(
              color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
            const SizedBox(height: 10),

            // Tag grid
            Wrap(spacing: 6, runSpacing: 6,
              children: _allTags.map((tag) {
                final selected = _selectedTags.contains(tag);
                return GestureDetector(
                  onTap: () => setState(() => selected ? _selectedTags.remove(tag) : _selectedTags.add(tag)),
                  child: MouseRegion(cursor: SystemMouseCursors.click,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected
                          ? (_mode == 'add' ? AppTheme.brand : AppTheme.error).withValues(alpha: 0.12)
                          : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected
                            ? (_mode == 'add' ? AppTheme.brand : AppTheme.error).withValues(alpha: 0.5)
                            : AppTheme.borderColor,
                          width: selected ? 1.5 : 1),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (selected) ...[
                          Icon(
                            _mode == 'add' ? Icons.add : Icons.remove,
                            size: 12,
                            color: _mode == 'add' ? AppTheme.brand : AppTheme.error),
                          const SizedBox(width: 4),
                        ],
                        Text(tag, style: TextStyle(
                          fontSize: 12, fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          color: selected
                            ? (_mode == 'add' ? AppTheme.brand : AppTheme.error)
                            : AppTheme.textSecondary)),
                      ]),
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 14),

            // Custom tag input
            Row(children: [
              Expanded(child: SizedBox(height: 36,
                child: TextField(
                  controller: _newTagCtrl,
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Type a custom tag...',
                    hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    filled: true, fillColor: AppTheme.pageBg,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
                  ),
                  onSubmitted: (v) {
                    final t = v.trim();
                    if (t.isNotEmpty) setState(() { _selectedTags.add(t); _newTagCtrl.clear(); });
                  },
                ),
              )),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  final t = _newTagCtrl.text.trim();
                  if (t.isNotEmpty) setState(() { _selectedTags.add(t); _newTagCtrl.clear(); });
                },
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3))),
                  child: const Icon(Icons.add, color: AppTheme.brand, size: 18),
                ),
              ),
            ]),

            if (_selectedTags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '${_selectedTags.length} tag${_selectedTags.length == 1 ? '' : 's'} selected — will be ${_mode == 'add' ? 'added to' : 'removed from'} ${widget.selectedLeads.length} contacts',
                style: TextStyle(
                  color: _mode == 'add' ? AppTheme.brand : AppTheme.error,
                  fontSize: 12, fontWeight: FontWeight.w500)),
            ],
          ])),

          // Footer
          Container(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => context.pop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: const Text('Cancel'),
              )),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: ElevatedButton(
                onPressed: (_saving || _selectedTags.isEmpty) ? null : _apply,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _mode == 'add' ? AppTheme.brand : AppTheme.error,
                  disabledBackgroundColor: AppTheme.borderColor,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text(
                        _selectedTags.isEmpty
                          ? 'Select tags first'
                          : '${_mode == 'add' ? 'Add' : 'Remove'} ${_selectedTags.length} tag${_selectedTags.length == 1 ? '' : 's'}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              )),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  BULK SMS DIALOG
// ─────────────────────────────────────────────

class _BulkSmsDialog extends StatefulWidget {
  final int selectedCount;
  final int withPhone;
  final int noPhone;
  final void Function(String message) onSend;

  const _BulkSmsDialog({
    required this.selectedCount,
    required this.withPhone,
    required this.noPhone,
    required this.onSend,
  });

  @override
  State<_BulkSmsDialog> createState() => _BulkSmsDialogState();
}

class _BulkSmsDialogState extends State<_BulkSmsDialog> {
  final _msgCtrl = TextEditingController();
  static const _maxChars = 160;

  @override
  void dispose() { _msgCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.sms_outlined, color: AppTheme.brand, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('Send SMS to ${widget.selectedCount} contacts',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
              GestureDetector(onTap: () => context.pop(),
                child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 20)),
            ]),
          ),

          Padding(padding: const EdgeInsets.all(20), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [

            // Reach summary
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor)),
              child: Row(children: [
                Icon(Icons.info_outline, size: 16,
                  color: widget.withPhone > 0 ? AppTheme.brand : AppTheme.error),
                const SizedBox(width: 8),
                Expanded(child: RichText(text: TextSpan(
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  children: [
                    TextSpan(text: '${widget.withPhone} contacts',
                      style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.brand)),
                    const TextSpan(text: ' will receive this SMS'),
                    if (widget.noPhone > 0) ...[
                      TextSpan(text: '  ·  ${widget.noPhone} skipped',
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                      const TextSpan(text: ' (no phone)',
                        style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                    ],
                  ],
                ))),
              ]),
            ),

            const SizedBox(height: 16),

            // Tip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6)),
              child: Row(children: const [
                Icon(Icons.lightbulb_outline, size: 13, color: AppTheme.brand),
                SizedBox(width: 6),
                Expanded(child: Text('Use {{name}} to personalize — e.g. "Hi {{name}}, just checking in!"',
                  style: TextStyle(color: AppTheme.brand, fontSize: 11))),
              ]),
            ),

            const SizedBox(height: 14),

            // Message box
            StatefulBuilder(builder: (ctx, setS) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(
                  controller: _msgCtrl,
                  maxLines: 5,
                  maxLength: _maxChars,
                  onChanged: (_) => setS(() {}),
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14, height: 1.5),
                  decoration: InputDecoration(
                    hintText: 'Type your message here...',
                    hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                    filled: true, fillColor: AppTheme.pageBg,
                    counterText: '',
                    contentPadding: const EdgeInsets.all(14),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
                  ),
                ),
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerRight,
                  child: Text('${_msgCtrl.text.length}/$_maxChars',
                    style: TextStyle(
                      fontSize: 11,
                      color: _msgCtrl.text.length > _maxChars * 0.9
                        ? AppTheme.error : AppTheme.textSecondary))),
              ]);
            }),
          ])),

          // Footer
          Container(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => context.pop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: const Text('Cancel'),
              )),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: ValueListenableBuilder(
                valueListenable: _msgCtrl,
                builder: (_, val, __) => ElevatedButton.icon(
                  onPressed: val.text.trim().isEmpty || widget.withPhone == 0
                      ? null
                      : () => widget.onSend(_msgCtrl.text.trim()),
                  icon: const Icon(Icons.send_rounded, size: 16, color: Colors.white),
                  label: Text('Send to ${widget.withPhone} contacts',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    disabledBackgroundColor: AppTheme.borderColor,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                ),
              )),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  BULK EMAIL DIALOG
// ─────────────────────────────────────────────

class _BulkEmailDialog extends StatefulWidget {
  final int selectedCount;
  final int withEmail;
  final int noEmail;
  final void Function(String subject, String body) onSend;

  const _BulkEmailDialog({
    required this.selectedCount,
    required this.withEmail,
    required this.noEmail,
    required this.onSend,
  });

  @override
  State<_BulkEmailDialog> createState() => _BulkEmailDialogState();
}

class _BulkEmailDialogState extends State<_BulkEmailDialog> {
  final _subjectCtrl = TextEditingController();
  final _bodyCtrl    = TextEditingController();

  @override
  void dispose() { _subjectCtrl.dispose(); _bodyCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 540,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.email_outlined, color: AppTheme.brand, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('Send Email to ${widget.selectedCount} contacts',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
              GestureDetector(onTap: () => context.pop(),
                child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 20)),
            ]),
          ),

          Padding(padding: const EdgeInsets.all(20), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [

            // From + reach summary
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Text('From:', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  const Text('Vantagecaretech <vantagecaretech@gmail.com>',
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Icon(Icons.info_outline, size: 14,
                    color: widget.withEmail > 0 ? AppTheme.brand : AppTheme.error),
                  const SizedBox(width: 6),
                  RichText(text: TextSpan(
                    style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                    children: [
                      TextSpan(text: '${widget.withEmail} contacts',
                        style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.brand)),
                      const TextSpan(text: ' will receive this email'),
                      if (widget.noEmail > 0)
                        TextSpan(text: '  ·  ${widget.noEmail} skipped (no email)',
                          style: const TextStyle(color: AppTheme.textSecondary)),
                    ],
                  )),
                ]),
              ]),
            ),

            const SizedBox(height: 12),

            // Personalization tip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6)),
              child: Row(children: const [
                Icon(Icons.lightbulb_outline, size: 13, color: AppTheme.brand),
                SizedBox(width: 6),
                Expanded(child: Text('Use {{name}} anywhere to personalize — replaced with each contact\'s first name',
                  style: TextStyle(color: AppTheme.brand, fontSize: 11))),
              ]),
            ),

            const SizedBox(height: 14),

            // Subject
            const Text('SUBJECT', style: TextStyle(
              color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
            const SizedBox(height: 6),
            TextField(
              controller: _subjectCtrl,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'e.g. Quick update from Vantagecaretech',
                hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                filled: true, fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
              ),
            ),

            const SizedBox(height: 14),

            // Body
            const Text('MESSAGE', style: TextStyle(
              color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
            const SizedBox(height: 6),
            TextField(
              controller: _bodyCtrl,
              maxLines: 8,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, height: 1.6),
              decoration: InputDecoration(
                hintText: 'Hi {{name}},\n\nJust wanted to reach out...',
                hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                filled: true, fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
              ),
            ),
          ])),

          // Footer
          Container(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () => context.pop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: const Text('Cancel'),
              )),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: ValueListenableBuilder(
                valueListenable: _subjectCtrl,
                builder: (_, __, ___) => ValueListenableBuilder(
                  valueListenable: _bodyCtrl,
                  builder: (_, __, ___) {
                    final canSend = _subjectCtrl.text.trim().isNotEmpty &&
                        _bodyCtrl.text.trim().isNotEmpty &&
                        widget.withEmail > 0;
                    return ElevatedButton.icon(
                      onPressed: canSend
                          ? () => widget.onSend(_subjectCtrl.text.trim(), _bodyCtrl.text.trim())
                          : null,
                      icon: const Icon(Icons.send_rounded, size: 16, color: Colors.white),
                      label: Text('Send to ${widget.withEmail} contacts',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        disabledBackgroundColor: AppTheme.borderColor,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                    );
                  },
                ),
              )),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  CONFIRM DIALOG
// ─────────────────────────────────────────────

AlertDialog _confirmDialog(BuildContext ctx, String title, String body) => AlertDialog(
  backgroundColor: AppTheme.cardBg,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  title: Text(title, style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
  content: Text(body, style: const TextStyle(color: AppTheme.textSecondary)),
  actions: [
    TextButton(onPressed: () => ctx.pop(false),
      child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
    ElevatedButton(onPressed: () => ctx.pop(true),
      style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
      child: const Text('Delete')),
  ],
);

// ─────────────────────────────────────────────
//  ADD CONTACT SHEET
// ─────────────────────────────────────────────

class _AddSheet extends StatefulWidget {
  final int businessId;
  final VoidCallback onSaved;
  const _AddSheet({required this.businessId, required this.onSaved});
  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final _db = Supabase.instance.client;
  final _fk = GlobalKey<FormState>();
  final _nameCtrl   = TextEditingController();
  final _emailCtrl  = TextEditingController();
  final _phoneCtrl  = TextEditingController();
  final _bizCtrl    = TextEditingController();
  final _addrCtrl   = TextEditingController();
  final _cityCtrl   = TextEditingController();
  final _stateCtrl  = TextEditingController();
  final _postalCtrl = TextEditingController();
  final _notesCtrl  = TextEditingController();
  final _tagCtrl    = TextEditingController();
  final _valueCtrl  = TextEditingController();
  String _status = 'New';
  String _source = 'Manual';
  List<String> _tags = [];
  bool _saving = false;
  List<Map<String, dynamic>> _teamMembers = [];
  String? _assignedToName;

  static const _suggestedTags = [
    'Hot Lead', 'Follow Up', 'VIP', 'Cold', 'Booked',
    'No Answer', 'Left Voicemail', 'Interested', 'Not Interested',
  ];

  @override
  void initState() {
    super.initState();
    _loadBusinessName();
    _loadTeamMembers();
  }

  Future<void> _loadBusinessName() async {
    try {
      final biz = await _db.from('businesses').select('business_name')
          .eq('id', widget.businessId).maybeSingle();
      if (biz != null && mounted) {
        final name = biz['business_name'] as String?;
        if (_bizCtrl.text.isEmpty && name != null) setState(() => _bizCtrl.text = name);
      }
    } catch (e) { debugPrint('Load biz name: $e'); }
  }

  Future<void> _loadTeamMembers() async {
    try {
      final data = await _db.from('profiles')
          .select('id, full_name')
          .eq('business_id', widget.businessId)
          .order('full_name');
      if (!mounted) return;
      setState(() => _teamMembers = List<Map<String, dynamic>>.from(data));
    } catch (e) { debugPrint('Load team members: $e'); }
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl,_emailCtrl,_phoneCtrl,_bizCtrl,_addrCtrl,
        _cityCtrl,_stateCtrl,_postalCtrl,_notesCtrl,_tagCtrl,_valueCtrl]) c.dispose();
    super.dispose();
  }

  void _addTag() {
    final t = _tagCtrl.text.trim();
    if (t.isNotEmpty && !_tags.contains(t)) setState(() { _tags.add(t); _tagCtrl.clear(); });
  }

  Future<void> _save() async {
    if (!_fk.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final addrParts = [_addrCtrl.text.trim(), _cityCtrl.text.trim(),
          _stateCtrl.text.trim(), _postalCtrl.text.trim()].where((s) => s.isNotEmpty);
      await _db.from('leads').insert({
        'lead_name': _nameCtrl.text.trim(),
        'lead_email': _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
        'lead_phone': _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
        'lead_status': _status,
        'source': _source,
        'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        'tags': _tags,
        'business_id': widget.businessId,
        'business_name': _bizCtrl.text.trim().isEmpty ? null : _bizCtrl.text.trim(),
        'lead_address': addrParts.isEmpty ? null : addrParts.join(', '),
        'estimated_value': _valueCtrl.text.trim().isEmpty ? null
            : double.tryParse(_valueCtrl.text.trim().replaceAll(r'$', '').replaceAll(',', '')),
        'assigned_to': _assignedToName,
        'assigned_to_profile_id': _assignedToName != null
            ? _teamMembers.firstWhere((m) => m['full_name'] == _assignedToName,
                orElse: () => {})['id'] as int?
            : null,
        'date_added': DateTime.now().toIso8601String(),
      });
      widget.onSaved();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error));
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9, maxChildSize: 0.95, minChildSize: 0.5,
      builder: (_, sc) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        child: Column(children: [
          Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4,
            decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2))),
          Padding(padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Row(children: [
              const Text('Add Contact',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              GestureDetector(onTap: () => context.pop(),
                child: Container(width: 32, height: 32,
                  decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 16))),
            ])),
          const Divider(height: 1, color: AppTheme.borderColor),
          Expanded(child: Form(key: _fk, child: ListView(controller: sc, padding: const EdgeInsets.all(24), children: [
            _secLabel('Basic Info'),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _field(_nameCtrl, 'Full Name *',
                validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null)),
              const SizedBox(width: 12),
              Expanded(child: _field(_bizCtrl, 'Business Name')),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _field(_emailCtrl, 'Email', type: TextInputType.emailAddress)),
              const SizedBox(width: 12),
              Expanded(child: _field(_phoneCtrl, 'Phone', type: TextInputType.phone)),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _drop('Status', _status,
                ['New','In Conversation','Qualified','Won','Lost','Unqualified'],
                (v) => setState(() => _status = v!))),
              const SizedBox(width: 12),
              Expanded(child: _drop('Source', _source,
                ['Manual','SMS','Email','Web Form','Import','Other'],
                (v) => setState(() => _source = v!))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _field(_valueCtrl, 'Estimated Value (\$)', type: TextInputType.number)),
              const SizedBox(width: 12),
              Expanded(child: _assignDropdown()),
            ]),
            const SizedBox(height: 20),
            _secLabel('Address'),
            const SizedBox(height: 12),
            _field(_addrCtrl, 'Street Address'),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(flex: 2, child: _field(_cityCtrl, 'City')),
              const SizedBox(width: 12),
              Expanded(child: _field(_stateCtrl, 'State')),
              const SizedBox(width: 12),
              Expanded(child: _field(_postalCtrl, 'Postal Code')),
            ]),
            const SizedBox(height: 20),
            _secLabel('Notes'),
            const SizedBox(height: 12),
            _field(_notesCtrl, 'Notes', maxLines: 3),
            const SizedBox(height: 20),
            _secLabel('Tags'),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6,
              children: _suggestedTags.map((t) {
                final selected = _tags.contains(t);
                return GestureDetector(
                  onTap: () => setState(() => selected ? _tags.remove(t) : _tags.add(t)),
                  child: MouseRegion(cursor: SystemMouseCursors.click,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: selected ? AppTheme.brand.withValues(alpha: 0.12) : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: selected ? AppTheme.brand.withValues(alpha: 0.4) : AppTheme.borderColor)),
                      child: Text(t, style: TextStyle(
                        color: selected ? AppTheme.brand : AppTheme.textSecondary,
                        fontSize: 12, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                    ),
                  ),
                );
              }).toList()),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _field(_tagCtrl, 'Add custom tag...', onSubmit: (_) => _addTag())),
              const SizedBox(width: 8),
              GestureDetector(onTap: _addTag, child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3))),
                child: const Icon(Icons.add, color: AppTheme.brand, size: 20))),
            ]),
            if (_tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: _tags.map((t) =>
                GestureDetector(onTap: () => setState(() => _tags.remove(t)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.brand.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3))),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(t, style: const TextStyle(color: AppTheme.brand, fontSize: 12)),
                      const SizedBox(width: 4),
                      const Icon(Icons.close, size: 12, color: AppTheme.brand),
                    ]),
                  ),
                )
              ).toList()),
            ],
            const SizedBox(height: 32),
          ]))),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              Expanded(child: GestureDetector(onTap: () => context.pop(),
                child: Container(height: 44,
                  decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                  child: const Center(child: Text('Cancel', style: TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w500)))))),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: GestureDetector(onTap: _saving ? null : _save,
                child: Container(height: 44,
                  decoration: BoxDecoration(color: AppTheme.brand, borderRadius: BorderRadius.circular(8)),
                  child: Center(child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Save Contact', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)))))),
            ])),
        ]),
      ),
    );
  }

  Widget _secLabel(String s) => Text(s, style: const TextStyle(
    color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8));

  Widget _field(TextEditingController ctrl, String label, {
    TextInputType? type, int maxLines = 1,
    String? Function(String?)? validator, ValueChanged<String>? onSubmit,
  }) => TextFormField(
    controller: ctrl, keyboardType: type, maxLines: maxLines,
    onFieldSubmitted: onSubmit, validator: validator,
    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
    decoration: InputDecoration(labelText: label,
      labelStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
  );

  Widget _assignDropdown() =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Assigned To', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      const SizedBox(height: 6),
      Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
        child: DropdownButtonHideUnderline(child: DropdownButton<String?>(
          value: _assignedToName, isExpanded: true, dropdownColor: AppTheme.cardBg,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          hint: const Text('Unassigned', style: TextStyle(color: AppTheme.textSecondary)),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Unassigned')),
            ..._teamMembers.map((m) => DropdownMenuItem<String?>(
                value: m['full_name'] as String?,
                child: Text(m['full_name'] as String? ?? 'Unknown'))),
          ],
          onChanged: (v) => setState(() => _assignedToName = v),
        ))),
    ]);

  Widget _drop(String label, String value, List<String> items, ValueChanged<String?> onChange) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      const SizedBox(height: 6),
      Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
        child: DropdownButtonHideUnderline(child: DropdownButton<String>(
          value: value, isExpanded: true, dropdownColor: AppTheme.cardBg,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          items: items.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
          onChanged: onChange,
        ))),
    ]);
}

// ─────────────────────────────────────────────────────────────────────────────
//  IMPORT CSV DIALOG  (unchanged from original)
// ─────────────────────────────────────────────────────────────────────────────

class _ImportCsvDialog extends StatefulWidget {
  final String csvString;
  final int businessId;
  final void Function(int count) onImported;
  const _ImportCsvDialog({required this.csvString, required this.businessId, required this.onImported});
  @override
  State<_ImportCsvDialog> createState() => _ImportCsvDialogState();
}

class _ImportCsvDialogState extends State<_ImportCsvDialog> {
  final _db = Supabase.instance.client;
  late List<List<dynamic>> _rows;
  late List<String> _headers;
  bool _hasHeader = true;
  bool _importing = false;
  String? _error;
  String? _mapName, _mapEmail, _mapPhone, _mapStatus, _mapSource,
          _mapBusiness, _mapAddress, _mapNotes, _mapValue, _mapTags;

  @override
  void initState() {
    super.initState();
    try {
      _rows = const CsvToListConverter(eol: '\n').convert(widget.csvString);
      if (_rows.isEmpty) { _error = 'CSV file is empty.'; _headers = []; return; }
      _headers = _rows.first.map((c) => c.toString()).toList();
      for (final h in _headers) {
        final lower = h.toLowerCase();
        if (lower.contains('name') && _mapName == null) _mapName = h;
        else if (lower.contains('email') && _mapEmail == null) _mapEmail = h;
        else if (lower.contains('phone') && _mapPhone == null) _mapPhone = h;
        else if (lower.contains('status') && _mapStatus == null) _mapStatus = h;
        else if (lower.contains('source') && _mapSource == null) _mapSource = h;
        else if (lower.contains('business') && _mapBusiness == null) _mapBusiness = h;
        else if (lower.contains('tag') && _mapTags == null) _mapTags = h;
        else if ((lower.contains('address') || lower.contains('street')) && _mapAddress == null) _mapAddress = h;
        else if (lower.contains('note') && _mapNotes == null) _mapNotes = h;
        else if ((lower.contains('value') || lower.contains('revenue') || lower.contains('amount')) && _mapValue == null) _mapValue = h;
      }
    } catch (e) { _error = 'Could not parse CSV: $e'; _headers = []; _rows = []; }
  }

  List<List<dynamic>> get _dataRows => _hasHeader && _rows.length > 1 ? _rows.sublist(1) : _rows;

  String? _val(List<dynamic> row, String? header) {
    if (header == null) return null;
    final idx = _headers.indexOf(header);
    if (idx < 0 || idx >= row.length) return null;
    final v = row[idx].toString().trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _import() async {
    if (_mapName == null) { setState(() => _error = 'Please map the Name column.'); return; }
    setState(() { _importing = true; _error = null; });
    try {
      final batch = <Map<String, dynamic>>[];
      for (final row in _dataRows) {
        final name = _val(row, _mapName);
        if (name == null || name.isEmpty) continue;
        final tagsRaw = _val(row, _mapTags);
        final tags = tagsRaw != null
            ? tagsRaw.split(';').map((t) => t.trim()).where((t) => t.isNotEmpty).toList()
            : <String>[];
        double? estValue;
        final rawVal = _val(row, _mapValue);
        if (rawVal != null) {
          estValue = double.tryParse(rawVal.replaceAll(r'$', '').replaceAll(',', '').trim());
        }
        batch.add({
          'lead_name': name, 'lead_email': _val(row, _mapEmail),
          'lead_phone': _val(row, _mapPhone), 'lead_status': _val(row, _mapStatus) ?? 'New',
          'source': _val(row, _mapSource) ?? 'Import', 'business_name': _val(row, _mapBusiness),
          'lead_address': _val(row, _mapAddress), 'notes': _val(row, _mapNotes),
          'estimated_value': estValue, 'tags': tags,
          'business_id': widget.businessId, 'date_added': DateTime.now().toIso8601String(),
        });
      }
      if (batch.isEmpty) { setState(() { _error = 'No valid rows found.'; _importing = false; }); return; }
      var imported = 0;
      for (var i = 0; i < batch.length; i += 100) {
        final chunk = batch.sublist(i, (i + 100).clamp(0, batch.length));
        await _db.from('leads').insert(chunk);
        imported += chunk.length;
      }
      widget.onImported(imported);
    } catch (e) { setState(() { _error = e.toString(); _importing = false; }); }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(width: 560, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
          child: Row(children: [
            const Icon(Icons.upload_file_outlined, color: AppTheme.brand, size: 20),
            const SizedBox(width: 10),
            const Expanded(child: Text('Import CSV', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
            GestureDetector(onTap: () => context.pop(), child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 20)),
          ])),
        if (_error != null)
          Container(margin: const EdgeInsets.fromLTRB(20, 16, 20, 0), padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppTheme.error.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.error.withValues(alpha: 0.3))),
            child: Row(children: [
              Icon(Icons.error_outline, color: AppTheme.error, size: 16), const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: TextStyle(color: AppTheme.error, fontSize: 12))),
            ])),
        Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Checkbox(value: _hasHeader, activeColor: AppTheme.brand, onChanged: (v) => setState(() => _hasHeader = v!)),
            const Text('First row is a header', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
            const Spacer(),
            Text('${_dataRows.length} rows to import', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ]),
          const SizedBox(height: 16),
          const Text('Map columns', style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          const SizedBox(height: 12),
          ...[
            ('Name *', _mapName, (v) => setState(() => _mapName = v)),
            ('Email', _mapEmail, (v) => setState(() => _mapEmail = v)),
            ('Phone', _mapPhone, (v) => setState(() => _mapPhone = v)),
            ('Status', _mapStatus, (v) => setState(() => _mapStatus = v)),
            ('Source', _mapSource, (v) => setState(() => _mapSource = v)),
            ('Business Name', _mapBusiness, (v) => setState(() => _mapBusiness = v)),
            ('Tags (semicolon separated)', _mapTags, (v) => setState(() => _mapTags = v)),
            ('Address', _mapAddress, (v) => setState(() => _mapAddress = v)),
            ('Notes', _mapNotes, (v) => setState(() => _mapNotes = v)),
            ('Estimated Value', _mapValue, (v) => setState(() => _mapValue = v)),
          ].map((entry) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              SizedBox(width: 180, child: Text(entry.$1, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13))),
              Expanded(child: Container(
                height: 36, padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.borderColor)),
                child: DropdownButtonHideUnderline(child: DropdownButton<String>(
                  value: entry.$2, isExpanded: true, isDense: true, dropdownColor: AppTheme.cardBg,
                  style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                  hint: const Text('— skip —', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('— skip —', style: TextStyle(color: AppTheme.textSecondary))),
                    ..._headers.map((h) => DropdownMenuItem(value: h, child: Text(h))),
                  ],
                  onChanged: (v) => entry.$3(v),
                )),
              )),
            ]),
          )),
        ])),
        Container(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: () => context.pop(),
            style: OutlinedButton.styleFrom(foregroundColor: AppTheme.textSecondary, side: const BorderSide(color: AppTheme.borderColor), padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Cancel'))),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: ElevatedButton(
            onPressed: _importing ? null : _import,
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: _importing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Text('Import ${_dataRows.length} Contacts', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)))),
        ])),
      ])),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  MANAGE SMART LISTS DIALOG  (unchanged from original)
// ─────────────────────────────────────────────────────────────────────────────

class _SmartListsDialog extends StatefulWidget {
  final int businessId;
  final Map<String, String> currentFilters;
  final VoidCallback onChanged;
  const _SmartListsDialog({required this.businessId, required this.currentFilters, required this.onChanged});
  @override
  State<_SmartListsDialog> createState() => _SmartListsDialogState();
}

class _SmartListsDialogState extends State<_SmartListsDialog> {
  final _db = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  List<Map<String, dynamic>> _lists = [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _nameCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await _db.from('smart_lists').select('id, name, filters, created_at')
          .eq('business_id', widget.businessId).order('created_at');
      setState(() => _lists = List<Map<String, dynamic>>.from(data));
    } catch (e) { debugPrint('Load smart lists: $e'); }
    finally { setState(() => _loading = false); }
  }

  Future<void> _saveCurrentAsList() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      await _db.from('smart_lists').insert({'business_id': widget.businessId, 'name': name, 'filters': widget.currentFilters});
      _nameCtrl.clear();
      await _load();
    } catch (e) { debugPrint('Save smart list: $e'); }
    finally { setState(() => _saving = false); }
  }

  Future<void> _delete(int id) async {
    await _db.from('smart_lists').delete().eq('id', id);
    await _load();
  }

  String _describeFilters(Map<String, dynamic> filters) {
    final parts = <String>[];
    final s = filters['status'] as String?;
    final src = filters['source'] as String?;
    final t = filters['tag'] as String?;
    if (s != null && s != 'All') parts.add('Status: $s');
    if (src != null && src != 'All') parts.add('Source: $src');
    if (t != null && t != 'All') parts.add('Tag: $t');
    return parts.isEmpty ? 'No filters (shows all)' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final hasActiveFilters = widget.currentFilters.values.any((v) => v != 'All');
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(width: 480, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
          child: Row(children: [
            const Icon(Icons.bookmarks_outlined, color: AppTheme.brand, size: 20),
            const SizedBox(width: 10),
            const Expanded(child: Text('Manage Smart Lists', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
      GestureDetector(onTap: () => context.pop(), child: const Icon(Icons.close, color: AppTheme.textSecondary, size: 20)),          ])),
        Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Save current filters as a Smart List', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(hasActiveFilters ? _describeFilters(widget.currentFilters) : 'Set filters on the Contacts page first, then save them here.',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              if (hasActiveFilters) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: SizedBox(height: 36, child: TextField(
                    controller: _nameCtrl,
                    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Smart list name...', hintStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                      filled: true, fillColor: AppTheme.cardBg,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
                    ),
                  ))),
                  const SizedBox(width: 8),
                  SizedBox(height: 36, child: ElevatedButton(
                    onPressed: _saving ? null : _saveCurrentAsList,
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
                    child: _saving
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)))),
                ]),
              ],
            ])),
          const SizedBox(height: 20),
          const Text('Your Smart Lists', style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          const SizedBox(height: 10),
          if (_loading)
            const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: AppTheme.brand)))
          else if (_lists.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
              child: const Center(child: Text('No smart lists yet. Set filters on the Contacts page and save them here.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13), textAlign: TextAlign.center)))
          else
            ...(_lists.map((list) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
              child: Row(children: [
                const Icon(Icons.list_alt_outlined, size: 16, color: AppTheme.brand),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(list['name'] as String, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                  Text(_describeFilters(Map<String, dynamic>.from(list['filters'] as Map)),
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
                ])),
                GestureDetector(
                  onTap: () => _delete((list['id'] as num).toInt()),
                  child: MouseRegion(cursor: SystemMouseCursors.click,
                    child: Padding(padding: const EdgeInsets.all(4),
                      child: Icon(Icons.delete_outline, size: 16, color: AppTheme.error)))),
              ]),
            ))),
        ])),
      ])),
    );
  }
}