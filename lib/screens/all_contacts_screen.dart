import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';

enum _EntryType { lead, businessContact, employee }

class _Entry {
  final int id;
  final _EntryType type;
  final String name;
  final String? email;
  final String? phone;
  final String status;
  final DateTime? createdAt;

  _Entry({
    required this.id,
    required this.type,
    required this.name,
    this.email,
    this.phone,
    required this.status,
    this.createdAt,
  });

  String get typeLabel {
    switch (type) {
      case _EntryType.lead: return 'Lead';
      case _EntryType.businessContact: return 'Business Contact';
      case _EntryType.employee: return 'Employee';
    }
  }

  Color get typeColor {
    switch (type) {
      case _EntryType.lead: return const Color(0xFF3B82F6);
      case _EntryType.businessContact: return const Color(0xFF8B5CF6);
      case _EntryType.employee: return const Color(0xFF10B981);
    }
  }

  String get route {
    switch (type) {
      case _EntryType.lead: return '/contacts/$id';
      case _EntryType.businessContact: return '/contacts/business/$id';
      case _EntryType.employee: return '/contacts/employees/$id';
    }
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
}

class AllContactsScreen extends StatefulWidget {
  const AllContactsScreen({super.key});
  @override
  State<AllContactsScreen> createState() => _AllContactsScreenState();
}

class _AllContactsScreenState extends State<AllContactsScreen> {
  final _db = Supabase.instance.client;
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  String? _error;

  List<_Entry> _all = [];
  List<_Entry> _filtered = [];

  _EntryType? _typeFilter; // null = all types

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_applyFilter);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final businessId = await getActiveBusinessId();
      if (businessId == null) return;

      final results = await Future.wait([
        _db.from('leads')
            .select('id, lead_name, lead_email, lead_phone, lead_status, date_added')
            .eq('business_id', businessId),
        _db.from('contacts')
            .select('id, full_name, email, phone, status, created_at')
            .eq('business_id', businessId)
            .filter('deleted_at', 'is', null),
        _db.from('profiles')
            .select('id, full_name, email, phone, status, created_at')
            .eq('business_id', businessId),
      ]);

      final leads = (results[0] as List).map((j) => _Entry(
        id: (j['id'] as num).toInt(),
        type: _EntryType.lead,
        name: j['lead_name'] as String? ?? 'Unknown',
        email: j['lead_email'] as String?,
        phone: j['lead_phone'] as String?,
        status: j['lead_status'] as String? ?? 'New',
        createdAt: j['date_added'] != null ? DateTime.tryParse(j['date_added'] as String) : null,
      ));

      final contacts = (results[1] as List).map((j) => _Entry(
        id: (j['id'] as num).toInt(),
        type: _EntryType.businessContact,
        name: j['full_name'] as String? ?? 'Unknown',
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        status: j['status'] as String? ?? 'Active',
        createdAt: j['created_at'] != null ? DateTime.tryParse(j['created_at'] as String) : null,
      ));

      final employees = (results[2] as List).map((j) => _Entry(
        id: (j['id'] as num).toInt(),
        type: _EntryType.employee,
        name: (j['full_name'] as String? ?? '').trim().isEmpty
            ? (j['email'] as String? ?? 'Unknown') : j['full_name'] as String,
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        status: j['status'] as String? ?? 'active',
        createdAt: j['created_at'] != null ? DateTime.tryParse(j['created_at'] as String) : null,
      ));

      _all = [...leads, ...contacts, ...employees]
        ..sort((a, b) => (b.createdAt ?? DateTime(2000)).compareTo(a.createdAt ?? DateTime(2000)));
      _applyFilter();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyFilter() {
    var result = List<_Entry>.from(_all);
    if (_typeFilter != null) result = result.where((e) => e.type == _typeFilter).toList();
    final q = _searchCtrl.text.toLowerCase();
    if (q.isNotEmpty) {
      result = result.where((e) =>
        e.name.toLowerCase().contains(q) ||
        (e.email ?? '').toLowerCase().contains(q) ||
        (e.phone ?? '').toLowerCase().contains(q)
      ).toList();
    }
    setState(() => _filtered = result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTopBar(),
          _buildTypeFilterBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppTheme.brand))
                : _error != null ? _buildError()
                : _filtered.isEmpty ? _buildEmpty()
                : _buildTable(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      color: AppTheme.cardBg,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Row(children: [
        const Text('All', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
          child: Text('${_filtered.length}', style: const TextStyle(color: AppTheme.brand, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        const Spacer(),
        SizedBox(width: 260, height: 36,
          child: TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search across all contacts...',
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
        const SizedBox(width: 8),
        Tooltip(message: 'Refresh',
          child: MouseRegion(cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: _load,
              child: Container(width: 36, height: 36,
                decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                child: const Icon(Icons.refresh_rounded, size: 16, color: AppTheme.textSecondary)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildTypeFilterBar() {
    final chips = <(_EntryType?, String)>[
      (null, 'All Types'),
      (_EntryType.lead, 'Leads'),
      (_EntryType.businessContact, 'Business Contacts'),
      (_EntryType.employee, 'Employees'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      color: AppTheme.cardBg,
      child: Row(children: chips.map((c) {
        final selected = _typeFilter == c.$1;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () { setState(() => _typeFilter = c.$1); _applyFilter(); },
            child: MouseRegion(cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: selected ? AppTheme.brand : AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: selected ? AppTheme.brand : AppTheme.borderColor),
                ),
                child: Text(c.$2, style: TextStyle(
                  fontSize: 12, fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? Colors.white : AppTheme.textSecondary)),
              ),
            ),
          ),
        );
      }).toList()),
    );
  }

  Widget _buildTable() {
    return Container(
      margin: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
      child: Column(children: [
        Container(
          height: 40, color: AppTheme.pageBg,
          child: Row(children: [
            _hCell('Name', flex: 3),
            _hCell('Type', flex: 2),
            _hCell('Email', flex: 3),
            _hCell('Phone', flex: 2),
            _hCell('Status', flex: 1),
            _hCell('Created', flex: 2),
          ]),
        ),
        const Divider(height: 1, color: AppTheme.borderColor),
        Expanded(
          child: ListView.separated(
            itemCount: _filtered.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
            itemBuilder: (_, i) => _buildRow(_filtered[i]),
          ),
        ),
      ]),
    );
  }

  Widget _hCell(String label, {int flex = 1}) => Expanded(
    flex: flex,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(label, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.4)),
    ),
  );

  Widget _buildRow(_Entry e) {
    return GestureDetector(
      onTap: () => context.push(e.route),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 56,
          color: AppTheme.cardBg,
          child: Row(children: [
            Expanded(flex: 3, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Container(width: 34, height: 34,
                  decoration: BoxDecoration(color: e.avatarColor, shape: BoxShape.circle),
                  child: Center(child: Text(e.initials, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)))),
                const SizedBox(width: 10),
                Expanded(child: Text(e.name, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
              ]),
            )),
            Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: e.typeColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                child: Text(e.typeLabel, style: TextStyle(color: e.typeColor, fontSize: 10, fontWeight: FontWeight.w600)),
              ),
            )),
            Expanded(flex: 3, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(e.email?.isNotEmpty == true ? e.email! : '—', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12), overflow: TextOverflow.ellipsis),
            )),
            Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(e.phone?.isNotEmpty == true ? e.phone! : '—', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12), overflow: TextOverflow.ellipsis),
            )),
            Expanded(flex: 1, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(e.status, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11), overflow: TextOverflow.ellipsis),
            )),
            Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(e.createdAt != null ? _fmtDate(e.createdAt!) : '—', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            )),
          ]),
        ),
      ),
    );
  }

  Widget _buildEmpty() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.groups_outlined, size: 56, color: AppTheme.borderColor),
    const SizedBox(height: 16),
    Text(_searchCtrl.text.isNotEmpty ? 'No results match your search' : 'Nothing here yet',
      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
  ]));

  Widget _buildError() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.error_outline, color: AppTheme.error, size: 40),
    const SizedBox(height: 12),
    Text(_error ?? 'Unknown error', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13), textAlign: TextAlign.center),
    const SizedBox(height: 12),
    TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, color: AppTheme.brand), label: const Text('Retry', style: TextStyle(color: AppTheme.brand))),
  ]));

  String _fmtDate(DateTime dt) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }
}