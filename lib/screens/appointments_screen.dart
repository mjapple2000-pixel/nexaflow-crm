import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

class AppointmentsScreen extends StatefulWidget {
  const AppointmentsScreen({super.key});

  @override
  State<AppointmentsScreen> createState() => _AppointmentsScreenState();
}

class _AppointmentsScreenState extends State<AppointmentsScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  List<Map<String, dynamic>> _allAppointments = [];
  List<Map<String, dynamic>> _filtered = [];
  String _statusFilter = 'All';
  String _viewMode = 'list'; // 'list' or 'calendar'
  DateTime _calendarMonth = DateTime.now();

  final _statuses = ['All', 'Scheduled', 'Completed', 'Cancelled', 'No Show'];

  @override
  void initState() {
    super.initState();
    _loadAppointments();
  }

  Future<void> _loadAppointments() async {
    setState(() => _loading = true);
    try {
      final userId = _db.auth.currentUser?.id;
      final profileRes = await _db
          .from('profiles')
          .select('business_id')
          .eq('user_id', userId!)
          .maybeSingle();
      final businessId = profileRes?['business_id'] as int?;
      if (businessId == null) return;

      final data = await _db
          .from('appointments')
          .select(
              'id, appointment_name, start_date_time, end_date_time, status, appointment_type, location, lead_name, lead_phone, lead_email, notes, confirmation_sent')
          .eq('business_id', businessId)
          .order('start_date_time', ascending: true);

      _allAppointments = List<Map<String, dynamic>>.from(data);
      _applyFilter();
    } catch (e) {
      debugPrint('Appointments error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyFilter() {
    setState(() {
      _filtered = _allAppointments.where((a) {
        final status = a['status'] ?? '';
        return _statusFilter == 'All' || status == _statusFilter;
      }).toList();
    });
  }

  void _showAddAppointment() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AppointmentFormSheet(
        onSaved: () {
          Navigator.pop(context);
          _loadAppointments();
        },
      ),
    );
  }

  void _showAppointmentDetail(Map<String, dynamic> appt) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AppointmentDetailSheet(
        appointment: appt,
        onUpdated: () {
          Navigator.pop(context);
          _loadAppointments();
        },
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
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  _buildFiltersRow(),
                  const SizedBox(height: 16),
                  _buildStatsRow(),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _viewMode == 'list'
                        ? _buildListView()
                        : _buildCalendarView(),
                  ),
                ],
              ),
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
          const Text('Appointments',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const Spacer(),
          // View toggle
          Container(
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(
              children: [
                _ViewToggleBtn(
                  icon: Icons.list,
                  label: 'List',
                  selected: _viewMode == 'list',
                  onTap: () => setState(() => _viewMode = 'list'),
                ),
                _ViewToggleBtn(
                  icon: Icons.calendar_month,
                  label: 'Calendar',
                  selected: _viewMode == 'calendar',
                  onTap: () => setState(() => _viewMode = 'calendar'),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton.icon(
              onPressed: _showAddAppointment,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Appointment'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFiltersRow() {
    return Row(
      children: [
        ...(_statuses.map((s) {
          final selected = _statusFilter == s;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Clickable(
              onTap: () {
                setState(() => _statusFilter = s);
                _applyFilter();
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? AppTheme.brand : AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color:
                        selected ? AppTheme.brand : AppTheme.borderColor,
                  ),
                ),
                child: Text(s,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: selected
                            ? Colors.white
                            : AppTheme.textSecondary)),
              ),
            ),
          );
        })),
        const Spacer(),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: IconButton(
            onPressed: _loadAppointments,
            icon: const Icon(Icons.refresh,
                size: 18, color: AppTheme.textSecondary),
            tooltip: 'Refresh',
          ),
        ),
      ],
    );
  }

  Widget _buildStatsRow() {
    final total = _allAppointments.length;
    final scheduled =
        _allAppointments.where((a) => a['status'] == 'Scheduled').length;
    final completed =
        _allAppointments.where((a) => a['status'] == 'Completed').length;
    final cancelled =
        _allAppointments.where((a) => a['status'] == 'Cancelled').length;

    return Row(
      children: [
        _MiniStat(label: 'Total', value: '$total', color: AppTheme.brand),
        const SizedBox(width: 8),
        _MiniStat(
            label: 'Scheduled',
            value: '$scheduled',
            color: const Color(0xFF6366f1)),
        const SizedBox(width: 8),
        _MiniStat(
            label: 'Completed',
            value: '$completed',
            color: AppTheme.success),
        const SizedBox(width: 8),
        _MiniStat(
            label: 'Cancelled',
            value: '$cancelled',
            color: AppTheme.error),
      ],
    );
  }

  // ── LIST VIEW ────────────────────────────────────────────────────────────────

  Widget _buildListView() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.calendar_today_outlined,
                size: 48, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            const Text('No appointments found',
                style:
                    TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: TextButton(
                onPressed: _showAddAppointment,
                child: const Text('Schedule your first appointment'),
              ),
            ),
          ],
        ),
      );
    }

    // Group by date
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final appt in _filtered) {
      final dt = DateTime.tryParse(appt['start_date_time'] ?? '') ??
          DateTime.now();
      final key = _formatDateKey(dt);
      grouped.putIfAbsent(key, () => []).add(appt);
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: [
          _buildListHeader(),
          Expanded(
            child: ListView.builder(
              itemCount: grouped.length,
              itemBuilder: (context, groupIndex) {
                final dateKey = grouped.keys.elementAt(groupIndex);
                final appts = grouped[dateKey]!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      color: AppTheme.pageBg,
                      child: Text(dateKey,
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary,
                              letterSpacing: 0.5)),
                    ),
                    ...appts.map((a) => Column(
                          children: [
                            _buildAppointmentRow(a),
                            const Divider(
                                height: 1, color: AppTheme.borderColor),
                          ],
                        )),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: const Row(
        children: [
          Expanded(
              flex: 3,
              child: Text('APPOINTMENT',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          Expanded(
              flex: 2,
              child: Text('CONTACT',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          Expanded(
              flex: 2,
              child: Text('TIME',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          Expanded(
              flex: 2,
              child: Text('TYPE',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          Expanded(
              flex: 2,
              child: Text('STATUS',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1))),
          SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _buildAppointmentRow(Map<String, dynamic> appt) {
    final name = appt['appointment_name'] ?? 'Untitled';
    final leadName = appt['lead_name'] ?? '—';
    final type = appt['appointment_type'] ?? '—';
    final status = appt['status'] ?? 'Scheduled';
    final startDt =
        DateTime.tryParse(appt['start_date_time'] ?? '') ?? DateTime.now();
    final endDt =
        DateTime.tryParse(appt['end_date_time'] ?? '') ?? DateTime.now();
    final timeStr =
        '${_formatTime(startDt)} – ${_formatTime(endDt)}';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: () => _showAppointmentDetail(appt),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: AppTheme.brand.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.calendar_today,
                          size: 14, color: AppTheme.brand),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(name,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.textPrimary)),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(leadName,
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textPrimary)),
                    if (appt['lead_phone'] != null &&
                        appt['lead_phone'].toString().isNotEmpty)
                      Text(appt['lead_phone'],
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(timeStr,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ),
              Expanded(
                flex: 2,
                child: Text(type,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textSecondary)),
              ),
              Expanded(
                flex: 2,
                child: _StatusBadge(status: status),
              ),
              SizedBox(
                width: 40,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: IconButton(
                    icon: const Icon(Icons.more_vert,
                        size: 16, color: AppTheme.textMuted),
                    onPressed: () => _showAppointmentDetail(appt),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── CALENDAR VIEW ────────────────────────────────────────────────────────────

  Widget _buildCalendarView() {
    final daysInMonth =
        DateUtils.getDaysInMonth(_calendarMonth.year, _calendarMonth.month);
    final firstDay =
        DateTime(_calendarMonth.year, _calendarMonth.month, 1);
    final startWeekday = firstDay.weekday % 7; // 0=Sun

    return Column(
      children: [
        // Month navigation
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(12)),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: IconButton(
                  onPressed: () => setState(() => _calendarMonth =
                      DateTime(_calendarMonth.year,
                          _calendarMonth.month - 1)),
                  icon: const Icon(Icons.chevron_left,
                      color: AppTheme.textSecondary),
                ),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    _formatMonthYear(_calendarMonth),
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary),
                  ),
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: IconButton(
                  onPressed: () => setState(() => _calendarMonth =
                      DateTime(_calendarMonth.year,
                          _calendarMonth.month + 1)),
                  icon: const Icon(Icons.chevron_right,
                      color: AppTheme.textSecondary),
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: TextButton(
                  onPressed: () =>
                      setState(() => _calendarMonth = DateTime.now()),
                  child: const Text('Today'),
                ),
              ),
            ],
          ),
        ),
        // Day headers
        Container(
          color: AppTheme.cardBg,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
                .map((d) => Expanded(
                      child: Center(
                        child: Text(d,
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textSecondary)),
                      ),
                    ))
                .toList(),
          ),
        ),
        // Grid
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(12)),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: GridView.builder(
              physics: const ClampingScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 1.8,
              ),
              itemCount: startWeekday + daysInMonth,
              itemBuilder: (context, index) {
                if (index < startWeekday) {
                  return const SizedBox();
                }
                final day = index - startWeekday + 1;
                final date = DateTime(
                    _calendarMonth.year, _calendarMonth.month, day);
                final dayAppts = _filtered.where((a) {
                  final dt =
                      DateTime.tryParse(a['start_date_time'] ?? '');
                  return dt != null &&
                      dt.year == date.year &&
                      dt.month == date.month &&
                      dt.day == date.day;
                }).toList();
                final isToday = DateUtils.isSameDay(date, DateTime.now());

                return Clickable(
                  onTap: dayAppts.isNotEmpty
                      ? () => _showDayAppointments(date, dayAppts)
                      : null,
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: isToday
                          ? AppTheme.brand.withValues(alpha: 0.05)
                          : null,
                      borderRadius: BorderRadius.circular(6),
                      border: isToday
                          ? Border.all(
                              color:
                                  AppTheme.brand.withValues(alpha: 0.3))
                          : null,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$day',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: isToday
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: isToday
                                    ? AppTheme.brand
                                    : AppTheme.textPrimary)),
                        ...dayAppts.take(2).map((a) => Container(
                              margin: const EdgeInsets.only(top: 2),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color:
                                    _statusColor(a['status'] ?? '')
                                        .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                a['appointment_name'] ?? '',
                                style: TextStyle(
                                    fontSize: 9,
                                    color: _statusColor(
                                        a['status'] ?? ''),
                                    fontWeight: FontWeight.w500),
                                overflow: TextOverflow.ellipsis,
                              ),
                            )),
                        if (dayAppts.length > 2)
                          Text('+${dayAppts.length - 2} more',
                              style: const TextStyle(
                                  fontSize: 9,
                                  color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _showDayAppointments(
      DateTime date, List<Map<String, dynamic>> appts) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(_formatDateKey(date),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 12),
            ...appts.map((a) => Clickable(
                  onTap: () {
                    Navigator.pop(context);
                    _showAppointmentDetail(a);
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Row(
                      children: [
                        _StatusBadge(status: a['status'] ?? ''),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a['appointment_name'] ?? '',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.textPrimary)),
                              Text(
                                  '${_formatTime(DateTime.tryParse(a['start_date_time'] ?? '') ?? DateTime.now())} · ${a['lead_name'] ?? ''}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.textSecondary)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 16, color: AppTheme.textMuted),
                      ],
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  // ── HELPERS ──────────────────────────────────────────────────────────────────

  String _formatDateKey(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday'
    ];
    return '${days[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _formatMonthYear(DateTime dt) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${months[dt.month - 1]} ${dt.year}';
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour == 0
        ? 12
        : dt.hour > 12
            ? dt.hour - 12
            : dt.hour;
    final min = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour < 12 ? 'AM' : 'PM';
    return '$hour:$min $period';
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'scheduled':
        return const Color(0xFF6366f1);
      case 'completed':
        return AppTheme.success;
      case 'cancelled':
        return AppTheme.error;
      case 'no show':
        return const Color(0xFFf59e0b);
      default:
        return AppTheme.textSecondary;
    }
  }
}

// ── VIEW TOGGLE BUTTON ────────────────────────────────────────────────────────

class _ViewToggleBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ViewToggleBtn({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppTheme.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 14,
                color: selected ? Colors.white : AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: selected ? Colors.white : AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}

// ── MINI STAT ─────────────────────────────────────────────────────────────────

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniStat(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: color)),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}

// ── STATUS BADGE ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status.toLowerCase()) {
      case 'scheduled':
        color = const Color(0xFF6366f1);
        break;
      case 'completed':
        color = AppTheme.success;
        break;
      case 'cancelled':
        color = AppTheme.error;
        break;
      case 'no show':
        color = const Color(0xFFf59e0b);
        break;
      default:
        color = AppTheme.textSecondary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(status,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w500, color: color)),
    );
  }
}

// ── APPOINTMENT FORM SHEET ────────────────────────────────────────────────────

class _AppointmentFormSheet extends StatefulWidget {
  final VoidCallback onSaved;
  final Map<String, dynamic>? existing;
  const _AppointmentFormSheet({required this.onSaved, this.existing});

  @override
  State<_AppointmentFormSheet> createState() =>
      _AppointmentFormSheetState();
}

class _AppointmentFormSheetState extends State<_AppointmentFormSheet> {
  final _db = Supabase.instance.client;
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();
  final _leadNameController = TextEditingController();
  final _leadPhoneController = TextEditingController();
  final _leadEmailController = TextEditingController();
  final _notesController = TextEditingController();

  String _type = 'Consultation';
  String _status = 'Scheduled';
  DateTime _startDt = DateTime.now().add(const Duration(hours: 1));
  DateTime _endDt = DateTime.now().add(const Duration(hours: 2));
  bool _saving = false;
  String? _error;

  final _types = [
    'Consultation', 'Follow-up', 'Demo', 'Check-in', 'Service', 'Other'
  ];
  final _statuses = [
    'Scheduled', 'Completed', 'Cancelled', 'No Show'
  ];

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _nameController.text = e['appointment_name'] ?? '';
      _locationController.text = e['location'] ?? '';
      _leadNameController.text = e['lead_name'] ?? '';
      _leadPhoneController.text = e['lead_phone'] ?? '';
      _leadEmailController.text = e['lead_email'] ?? '';
      _notesController.text = e['notes'] ?? '';
      _type = e['appointment_type'] ?? 'Consultation';
      _status = e['status'] ?? 'Scheduled';
      _startDt =
          DateTime.tryParse(e['start_date_time'] ?? '') ?? _startDt;
      _endDt = DateTime.tryParse(e['end_date_time'] ?? '') ?? _endDt;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _leadNameController.dispose();
    _leadPhoneController.dispose();
    _leadEmailController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime(bool isStart) async {
    final date = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDt : _endDt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay.fromDateTime(isStart ? _startDt : _endDt),
    );
    if (time == null || !mounted) return;
    final result =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _startDt = result;
        if (_endDt.isBefore(_startDt)) {
          _endDt = _startDt.add(const Duration(hours: 1));
        }
      } else {
        _endDt = result;
      }
    });
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _error = 'Appointment name is required');
      return;
    }
    if (_endDt.isBefore(_startDt)) {
      setState(() => _error = 'End time must be after start time');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final userId = _db.auth.currentUser?.id;
      final profileRes = await _db
          .from('profiles')
          .select('business_id')
          .eq('user_id', userId!)
          .maybeSingle();
      final businessId = profileRes?['business_id'] as int?;

      final payload = {
        'appointment_name': _nameController.text.trim(),
        'appointment_type': _type,
        'status': _status,
        'start_date_time': _startDt.toIso8601String(),
        'end_date_time': _endDt.toIso8601String(),
        'location': _locationController.text.trim(),
        'lead_name': _leadNameController.text.trim(),
        'lead_phone': _leadPhoneController.text.trim(),
        'lead_email': _leadEmailController.text.trim(),
        'notes': _notesController.text.trim(),
        'business_id': businessId,
        'user_id': userId,
        'confirmation_sent': false,
      };

      if (widget.existing != null) {
        await _db
            .from('appointments')
            .update(payload)
            .eq('id', widget.existing!['id']);
      } else {
        await _db.from('appointments').insert(payload);
      }
      widget.onSaved();
    } catch (e) {
      setState(() => _error = 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.borderColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                  widget.existing != null
                      ? 'Edit Appointment'
                      : 'New Appointment',
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 20),
              _field('Appointment Name', _nameController,
                  hint: 'e.g. Initial Consultation'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                      child: _dropdown('Type', _types, _type,
                          (v) => setState(() => _type = v!))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _dropdown('Status', _statuses, _status,
                          (v) => setState(() => _status = v!))),
                ],
              ),
              const SizedBox(height: 12),
              // Date/time pickers
              Row(
                children: [
                  Expanded(
                    child: _DateTimePickerField(
                      label: 'Start',
                      value: _startDt,
                      onTap: () => _pickDateTime(true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DateTimePickerField(
                      label: 'End',
                      value: _endDt,
                      onTap: () => _pickDateTime(false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _field('Location', _locationController,
                  hint: 'Office, Zoom, Phone...'),
              const SizedBox(height: 16),
              const Text('Contact Info',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              _field('Contact Name', _leadNameController,
                  hint: 'Jane Smith'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                      child: _field('Phone', _leadPhoneController,
                          hint: '555-0100',
                          keyboard: TextInputType.phone)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _field('Email', _leadEmailController,
                          hint: 'jane@example.com',
                          keyboard: TextInputType.emailAddress)),
                ],
              ),
              const SizedBox(height: 8),
              _field('Notes', _notesController,
                  hint: 'Any notes...', maxLines: 3),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.error)),
              ],
              const SizedBox(height: 20),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(
                            widget.existing != null
                                ? 'Save Changes'
                                : 'Save Appointment',
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller,
      {String? hint, TextInputType? keyboard, int maxLines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: keyboard,
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: hint,
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
              borderSide: const BorderSide(color: AppTheme.brand, width: 2),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
      ],
    );
  }

  Widget _dropdown(String label, List<String> items, String value,
      ValueChanged<String?> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 4),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                dropdownColor: AppTheme.cardBg,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textPrimary),
                items: items
                    .map((s) =>
                        DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── DATE TIME PICKER FIELD ────────────────────────────────────────────────────

class _DateTimePickerField extends StatelessWidget {
  final String label;
  final DateTime value;
  final VoidCallback onTap;

  const _DateTimePickerField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  String _format(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final hour = dt.hour == 0
        ? 12
        : dt.hour > 12
            ? dt.hour - 12
            : dt.hour;
    final min = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day} · $hour:$min $period';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 4),
        Clickable(
          onTap: onTap,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(
              children: [
                const Icon(Icons.access_time,
                    size: 14, color: AppTheme.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_format(value),
                      style: const TextStyle(
                          fontSize: 13, color: AppTheme.textPrimary)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── APPOINTMENT DETAIL SHEET ──────────────────────────────────────────────────

class _AppointmentDetailSheet extends StatefulWidget {
  final Map<String, dynamic> appointment;
  final VoidCallback onUpdated;
  const _AppointmentDetailSheet(
      {required this.appointment, required this.onUpdated});

  @override
  State<_AppointmentDetailSheet> createState() =>
      _AppointmentDetailSheetState();
}

class _AppointmentDetailSheetState
    extends State<_AppointmentDetailSheet> {
  final _db = Supabase.instance.client;
  late String _status;
  bool _saving = false;

  final _statuses = ['Scheduled', 'Completed', 'Cancelled', 'No Show'];

  @override
  void initState() {
    super.initState();
    _status = widget.appointment['status'] ?? 'Scheduled';
  }

  Future<void> _updateStatus(String newStatus) async {
    setState(() {
      _saving = true;
      _status = newStatus;
    });
    try {
      await _db
          .from('appointments')
          .update({'status': newStatus}).eq('id', widget.appointment['id']);
    } catch (e) {
      debugPrint('Update error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Appointment'),
        content: const Text(
            'Are you sure you want to delete this appointment?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete',
                  style: TextStyle(color: AppTheme.error))),
        ],
      ),
    );
    if (confirm != true) return;
    await _db
        .from('appointments')
        .delete()
        .eq('id', widget.appointment['id']);
    widget.onUpdated();
  }

  void _showEdit() {
    Navigator.pop(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AppointmentFormSheet(
        existing: widget.appointment,
        onSaved: widget.onUpdated,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appt = widget.appointment;
    final name = appt['appointment_name'] ?? 'Untitled';
    final type = appt['appointment_type'] ?? '—';
    final location = appt['location'] ?? '';
    final leadName = appt['lead_name'] ?? '—';
    final leadPhone = appt['lead_phone'] ?? '';
    final leadEmail = appt['lead_email'] ?? '';
    final notes = appt['notes'] ?? '';
    final startDt =
        DateTime.tryParse(appt['start_date_time'] ?? '') ?? DateTime.now();
    final endDt =
        DateTime.tryParse(appt['end_date_time'] ?? '') ?? DateTime.now();

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.calendar_today,
                      color: AppTheme.brand, size: 22),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textPrimary)),
                      Text(type,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: IconButton(
                    onPressed: _showEdit,
                    icon: const Icon(Icons.edit_outlined,
                        size: 18, color: AppTheme.textSecondary),
                    tooltip: 'Edit',
                  ),
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: IconButton(
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: AppTheme.error),
                    tooltip: 'Delete',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Time block
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppTheme.brand.withValues(alpha: 0.15)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.access_time,
                      size: 16, color: AppTheme.brand),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_formatFullDate(startDt),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary)),
                      Text(
                          '${_formatTime(startDt)} – ${_formatTime(endDt)}',
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (location.isNotEmpty)
              _detailRow(Icons.location_on_outlined, location),
            if (location.isNotEmpty) const SizedBox(height: 8),
            _detailRow(Icons.person_outline, leadName),
            if (leadPhone.isNotEmpty) ...[
              const SizedBox(height: 8),
              _detailRow(Icons.phone_outlined, leadPhone),
            ],
            if (leadEmail.isNotEmpty) ...[
              const SizedBox(height: 8),
              _detailRow(Icons.email_outlined, leadEmail),
            ],
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              _detailRow(Icons.notes_outlined, notes),
            ],
            const SizedBox(height: 20),
            const Text('Update Status',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _statuses.map((s) {
                final isSelected = s == _status;
                return Clickable(
                  onTap: () => _updateStatus(s),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppTheme.brand
                          : AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                        color: isSelected
                            ? AppTheme.brand
                            : AppTheme.borderColor,
                      ),
                    ),
                    child: Text(s,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: isSelected
                                ? Colors.white
                                : AppTheme.textSecondary)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  onPressed: widget.onUpdated,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Done',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textPrimary)),
        ),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour == 0
        ? 12
        : dt.hour > 12
            ? dt.hour - 12
            : dt.hour;
    final min = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour < 12 ? 'AM' : 'PM';
    return '$hour:$min $period';
  }

  String _formatFullDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = [
      'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
    ];
    return '${days[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}