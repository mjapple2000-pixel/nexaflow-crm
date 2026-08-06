import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/business_utils.dart';

// ─────────────────────────────────────────────
//  MODEL
// ─────────────────────────────────────────────

class _Employee {
  final int id;
  final String? userId;
  String name;
  String? email;
  String? phone;
  String role;
  String status;
  String? jobTitle;
  DateTime? createdAt;
  DateTime? invitedAt;
  Map<String, dynamic> permissions;

  _Employee({
    required this.id,
    this.userId,
    required this.name,
    this.email,
    this.phone,
    required this.role,
    required this.status,
    this.jobTitle,
    this.createdAt,
    this.invitedAt,
    required this.permissions,
  });

  factory _Employee.fromJson(Map<String, dynamic> j) {
    return _Employee(
      id: (j['id'] as num).toInt(),
      userId: j['user_id'] as String?,
      name: (j['full_name'] as String? ?? '').trim().isEmpty
          ? (j['email'] as String? ?? 'Unknown')
          : j['full_name'] as String,
      email: j['email'] as String?,
      phone: j['phone'] as String?,
      role: j['role'] as String? ?? 'member',
      status: j['status'] as String? ?? 'active',
      jobTitle: j['job_title'] as String?,
      createdAt: j['created_at'] != null ? DateTime.tryParse(j['created_at'] as String) : null,
      invitedAt: j['invited_at'] != null ? DateTime.tryParse(j['invited_at'] as String) : null,
      permissions: Map<String, dynamic>.from((j['permissions'] as Map?) ?? {}),
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

  bool get isOwner => role == 'owner';
  bool get isInactive => status == 'inactive';
  bool get isPending => status == 'pending';
}

// ─────────────────────────────────────────────
//  EMPLOYEES SCREEN
// ─────────────────────────────────────────────

class EmployeesScreen extends StatefulWidget {
  const EmployeesScreen({super.key});
  @override
  State<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends State<EmployeesScreen> {
  final _db = Supabase.instance.client;
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  String? _error;
  int? _businessId;
  String? _currentUserId;

  List<_Employee> _all = [];
  List<_Employee> _filtered = [];

  Set<int> _selected = {};
  bool get _hasSelection => _selected.isNotEmpty;

  // 0 = Active, 1 = Inactive, 2 = All
  int _activeTab = 0;

  bool _colEmail    = true;
  bool _colPhone    = true;
  bool _colRole     = true;
  bool _colJobTitle = true;
  bool _colCreated  = false;

  @override
  void initState() {
    super.initState();
    _currentUserId = _db.auth.currentUser?.id;
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
      _businessId = await getActiveBusinessId();
      if (_businessId == null) return;

      final data = await _db.from('profiles')
          .select('id, user_id, full_name, email, phone, role, status, job_title, '
              'created_at, invited_at, permissions')
          .eq('business_id', _businessId!)
          .order('full_name');

      _all = (data as List).map((j) => _Employee.fromJson(j)).toList();
      _applyFilter();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyFilter() {
    var result = List<_Employee>.from(_all);
    if (_activeTab == 0) result = result.where((e) => !e.isInactive).toList();
    else if (_activeTab == 1) result = result.where((e) => e.isInactive).toList();

    final q = _searchCtrl.text.toLowerCase();
    if (q.isNotEmpty) {
      result = result.where((e) =>
        e.name.toLowerCase().contains(q) ||
        (e.email ?? '').toLowerCase().contains(q) ||
        (e.phone ?? '').toLowerCase().contains(q) ||
        (e.jobTitle ?? '').toLowerCase().contains(q)
      ).toList();
    }
    setState(() => _filtered = result);
  }

  void _toggleSelect(int id) => setState(() {
    _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
  });

  void _toggleAll() => setState(() {
    final selectable = _filtered.where((e) => !e.isOwner).map((e) => e.id).toSet();
    _selected.length == selectable.length ? _selected.clear() : _selected = selectable;
  });

  void _clearSelection() => setState(() => _selected.clear());

  // ── STATUS ACTIONS — same profiles.status field Settings > My Staff uses ──

  Future<void> _setStatus(List<int> ids, String status) async {
    await _db.from('profiles').update({'status': status}).inFilter('id', ids);
    _clearSelection();
    _load();
  }

  Future<void> _confirmDeactivate(_Employee e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Deactivate Team Member', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
        content: Text(
          'Deactivate ${e.name}? They will lose all access immediately. Their record and work history stay saved, and they can be reactivated later.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5)),
        actions: [
          TextButton(onPressed: () => ctx.pop(false), child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            onPressed: () => ctx.pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Deactivate')),
        ],
      ),
    );
    if (confirmed == true) _setStatus([e.id], 'inactive');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppTheme.brand, duration: const Duration(seconds: 3)));
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
          if (_hasSelection) _buildBulkBar(),
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
        const Text('Employees', style: TextStyle(
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
        MouseRegion(cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => context.go('/settings?section=team'),
            child: Container(
              height: 36, padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: AppTheme.brand, borderRadius: BorderRadius.circular(8)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.person_add_outlined, size: 15, color: Colors.white),
                SizedBox(width: 6),
                Text('Invite Employee', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white)),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _iconBtn(Icons.view_column_outlined, 'Columns', onTap: _showColumnPicker),
        const SizedBox(width: 6),
        _iconBtn(Icons.refresh_rounded, 'Refresh', onTap: _load),
      ]),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, {required VoidCallback onTap}) {
    return Tooltip(message: tooltip,
      child: MouseRegion(cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap,
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
            child: const Icon(Icons.refresh_rounded, size: 16, color: AppTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _buildTabs() {
    final labels = ['Active', 'Inactive', 'All'];
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(children: List.generate(labels.length, (i) {
        final active = _activeTab == i;
        return GestureDetector(
          onTap: () { setState(() => _activeTab = i); _applyFilter(); },
          child: MouseRegion(cursor: SystemMouseCursors.click,
            child: Container(
              height: 44, margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(
                  color: active ? AppTheme.brand : Colors.transparent, width: 2))),
              child: Center(child: Text(labels[i], style: TextStyle(
                color: active ? AppTheme.brand : AppTheme.textSecondary,
                fontSize: 13, fontWeight: active ? FontWeight.w600 : FontWeight.w400))),
            ),
          ),
        );
      })),
    );
  }

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
        if (_activeTab != 1)
          _bulkBtn(Icons.person_off_outlined, 'Deactivate', () => _setStatus(_selected.toList(), 'inactive'), color: AppTheme.error),
        if (_activeTab == 1) ...[
          const SizedBox(width: 8),
          _bulkBtn(Icons.refresh_rounded, 'Reactivate', () => _setStatus(_selected.toList(), 'active')),
        ],
        const Spacer(),
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
          decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.borderColor)),
          child: Row(children: [
            Icon(icon, size: 14, color: color ?? AppTheme.textSecondary),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, color: color ?? AppTheme.textSecondary)),
          ]),
        ),
      ),
    );
  }

  Widget _buildTable() {
    return Container(
      margin: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
      child: Column(children: [
        _buildTableHeader(),
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

  Widget _buildTableHeader() {
    final selectableCount = _filtered.where((e) => !e.isOwner).length;
    return Container(
      height: 40, color: AppTheme.pageBg,
      child: Row(children: [
        _checkboxCell(_selected.length == selectableCount && selectableCount > 0, _toggleAll),
        _hCell('Name', flex: 3),
        if (_colEmail)    _hCell('Email', flex: 3),
        if (_colPhone)    _hCell('Phone', flex: 2),
        if (_colRole)     _hCell('Role', flex: 1),
        if (_colJobTitle) _hCell('Job Title', flex: 2),
        if (_colCreated)  _hCell('Created', flex: 2),
        _hCell('Status', flex: 1),
        const SizedBox(width: 48),
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

  Widget _checkboxCell(bool checked, VoidCallback onTap) {
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

  Widget _buildRow(_Employee e) {
    final selected = _selected.contains(e.id);
    return GestureDetector(
      onTap: () => context.push('/contacts/employees/${e.id}'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 56,
          color: selected ? AppTheme.brand.withValues(alpha: 0.04) : (e.isInactive ? AppTheme.pageBg.withValues(alpha: 0.5) : AppTheme.cardBg),
          child: Row(children: [
            e.isOwner
                ? const SizedBox(width: 48)
                : GestureDetector(
                    onTap: () => _toggleSelect(e.id),
                    behavior: HitTestBehavior.opaque,
                    child: _checkboxCell(selected, () => _toggleSelect(e.id)),
                  ),
            Expanded(flex: 3, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Container(
                  width: 34, height: 34,
                  decoration: BoxDecoration(color: e.avatarColor, shape: BoxShape.circle),
                  child: Center(child: Text(e.initials, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))),
                ),
                const SizedBox(width: 10),
                Expanded(child: Row(children: [
                  Flexible(child: Text(e.name, style: TextStyle(
                    color: e.isInactive ? AppTheme.textSecondary : AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis)),
                  if (e.userId == _currentUserId) ...[
                    const SizedBox(width: 6),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                      child: const Text('You', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppTheme.brand))),
                  ],
                ])),
              ]),
            )),
            if (_colEmail) Expanded(flex: 3, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(e.email ?? '—', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12), overflow: TextOverflow.ellipsis),
            )),
            if (_colPhone) Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(e.phone?.isNotEmpty == true ? e.phone! : '—', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12), overflow: TextOverflow.ellipsis),
            )),
            if (_colRole) Expanded(flex: 1, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _roleBadge(e.role),
            )),
            if (_colJobTitle) Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(e.jobTitle?.isNotEmpty == true ? e.jobTitle! : '—', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12), overflow: TextOverflow.ellipsis),
            )),
            if (_colCreated) Expanded(flex: 2, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(e.createdAt != null ? _fmtDate(e.createdAt!) : '—', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            )),
            Expanded(flex: 1, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _statusBadge(e),
            )),
            SizedBox(width: 48, child: PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, color: AppTheme.textSecondary, size: 18),
              color: AppTheme.cardBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              onSelected: (a) {
                if (a == 'view') context.push('/contacts/employees/${e.id}');
                else if (a == 'deactivate') _confirmDeactivate(e);
                else if (a == 'reactivate') _setStatus([e.id], 'active');
                else if (a == 'permissions') context.go('/settings?section=team');
              },
              itemBuilder: (_) => [
                _menuItem('view', Icons.open_in_new, 'View Details'),
                if (!e.isOwner) _menuItem('permissions', Icons.tune_rounded, 'Manage Permissions'),
                if (!e.isOwner) const PopupMenuDivider(),
                if (!e.isOwner && !e.isInactive) _menuItem('deactivate', Icons.person_off_outlined, 'Deactivate', color: AppTheme.error),
                if (!e.isOwner && e.isInactive) _menuItem('reactivate', Icons.refresh_rounded, 'Reactivate'),
              ],
            )),
          ]),
        ),
      ),
    );
  }

  Widget _roleBadge(String role) {
    final isOwner = role == 'owner';
    final color = isOwner ? AppTheme.brand : const Color(0xFF6366F1);
    final label = role.isEmpty ? 'member' : '${role[0].toUpperCase()}${role.substring(1)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }

  Widget _statusBadge(_Employee e) {
    if (e.isInactive) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: AppTheme.textMuted.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
        child: const Text('Inactive', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)));
    }
    if (e.isPending) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
        child: const Text('Pending', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.orange)));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: const Color(0xFF10B981).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: const Text('Active', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF10B981))));
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {Color? color}) =>
    PopupMenuItem(value: value, child: Row(children: [
      Icon(icon, size: 14, color: color ?? AppTheme.textSecondary),
      const SizedBox(width: 8),
      Text(label, style: TextStyle(color: color ?? AppTheme.textPrimary, fontSize: 13)),
    ]));

  Widget _buildEmpty() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.people_outline, size: 56, color: AppTheme.borderColor),
      const SizedBox(height: 16),
      Text(
        _searchCtrl.text.isNotEmpty ? 'No employees match your search'
          : _activeTab == 1 ? 'No inactive employees' : 'No employees yet',
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
      const SizedBox(height: 12),
      if (_activeTab != 1)
        MouseRegion(cursor: SystemMouseCursors.click,
          child: GestureDetector(onTap: () => context.go('/settings?section=team'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(color: AppTheme.brand, borderRadius: BorderRadius.circular(8)),
              child: const Text('Invite Your First Employee', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          )),
    ]));
  }

  Widget _buildError() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.error_outline, color: AppTheme.error, size: 40),
    const SizedBox(height: 12),
    Text(_error ?? 'Unknown error', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13), textAlign: TextAlign.center),
    const SizedBox(height: 12),
    TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, color: AppTheme.brand), label: const Text('Retry', style: TextStyle(color: AppTheme.brand))),
  ]));

  void _showColumnPicker() {
    var email = _colEmail, phone = _colPhone, role = _colRole, jobTitle = _colJobTitle, created = _colCreated;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Customize Columns', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 16)),
        content: StatefulBuilder(builder: (ctx, setS) => Column(mainAxisSize: MainAxisSize.min, children: [
          _colTgl('Email', email, setS, (v) { email = v; }),
          _colTgl('Phone', phone, setS, (v) { phone = v; }),
          _colTgl('Role', role, setS, (v) { role = v; }),
          _colTgl('Job Title', jobTitle, setS, (v) { jobTitle = v; }),
          _colTgl('Created Date', created, setS, (v) { created = v; }),
        ])),
        actions: [TextButton(onPressed: () => context.pop(), child: const Text('Done', style: TextStyle(color: AppTheme.brand)))],
      ),
    ).then((_) {
      if (mounted) setState(() {
        _colEmail = email; _colPhone = phone; _colRole = role; _colJobTitle = jobTitle; _colCreated = created;
      });
    });
  }

  Widget _colTgl(String label, bool value, StateSetter setS, Function(bool) onChanged) =>
    SwitchListTile(
      title: Text(label, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
      value: value, activeColor: AppTheme.brand, dense: true,
      onChanged: (v) => setS(() => onChanged(v)),
    );

  String _fmtDate(DateTime dt) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }
}