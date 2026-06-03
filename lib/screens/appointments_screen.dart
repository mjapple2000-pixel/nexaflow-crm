import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../utils/business_utils.dart';

class AppointmentsScreen extends StatefulWidget {
  const AppointmentsScreen({super.key});
  @override
  State<AppointmentsScreen> createState() => _AppointmentsScreenState();
}

class _AppointmentsScreenState extends State<AppointmentsScreen>
    with SingleTickerProviderStateMixin {
  final _db = Supabase.instance.client;
  late TabController _tabController;

  bool _loading = true;
  List<Map<String, dynamic>> _appointments = [];
  List<Map<String, dynamic>> _calendars    = [];
  List<Map<String, dynamic>> _teamMembers  = [];
  List<Map<String, dynamic>> _leads        = [];
  int? _businessId;
  Map<String, dynamic>? _business;

  String   _calView   = 'week';
  DateTime _focusDate = DateTime.now();

  String _statusFilter = 'All';
  final _statuses = ['All','New','Confirmed','Showed','No-Show','Cancelled','Invalid','Rescheduled'];

  int _panelTab = 0;
  final _usersSearchCtrl     = TextEditingController();
  final _calendarsSearchCtrl = TextEditingController();
  final _groupsSearchCtrl    = TextEditingController();

  Map<String, Map<String, dynamic>> _availability = {
    'monday':    {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'tuesday':   {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'wednesday': {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'thursday':  {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'friday':    {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'saturday':  {'enabled': false, 'start': '09:00', 'end': '17:00', 'blocks': []},
    'sunday':    {'enabled': false, 'start': '09:00', 'end': '17:00', 'blocks': []},
  };

  static const _appointmentTypes = [
    'Consultation','Discovery Call','Demo','Strategy Session','Follow-Up',
    'Check-In','Onboarding','Renewal','Support Call','Sales Call',
    'Service Appointment','In-Person Meeting','Virtual Meeting','Round Robin',
    'Class / Event','Collective Meeting','Internal Meeting','Interview','Training','Other',
  ];

  static const _appointmentStatuses = [
    'New','Confirmed','Showed','No-Show','Cancelled','Invalid','Rescheduled',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _usersSearchCtrl.dispose();
    _calendarsSearchCtrl.dispose();
    _groupsSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) return;
      final results = await Future.wait([
        _db.from('appointments').select().eq('business_id', _businessId!).order('start_date_time', ascending: true),
        _db.from('businesses').select('availability_hours, slot_duration_minutes').eq('id', _businessId!).maybeSingle(),
        _db.from('profiles').select('id, full_name, role').eq('business_id', _businessId!),
        _db.from('leads').select('id, lead_name, lead_email, lead_phone').eq('business_id', _businessId!).order('lead_name', ascending: true),
        _db.from('calendars').select().eq('business_id', _businessId!).order('created_at', ascending: true),
      ]);
      _appointments = List<Map<String, dynamic>>.from(results[0] as List);
      _business     = results[1] as Map<String, dynamic>?;
      _teamMembers  = List<Map<String, dynamic>>.from(results[2] as List);
      _leads        = List<Map<String, dynamic>>.from(results[3] as List);
      _calendars    = List<Map<String, dynamic>>.from(results[4] as List);
      if (_business != null) {
        final ah = _business!['availability_hours'];
        if (ah != null) {
          final map = ah is String ? jsonDecode(ah) : ah;
          (map as Map).forEach((day, val) {
            if (_availability.containsKey(day)) {
              _availability[day] = {
                'enabled': val['enabled'] ?? false,
                'start':   val['start']   ?? '09:00',
                'end':     val['end']     ?? '17:00',
                'blocks':  (val['blocks'] as List?)?.cast<Map<String, dynamic>>() ?? [],
              };
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Load error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_statusFilter == 'All') return _appointments;
    return _appointments.where((a) => a['status'] == _statusFilter).toList();
  }

  ({int startHour, int endHour}) _visibleHourRange() {
    int? earliest; int? latest;
    _availability.forEach((_, v) {
      if (v['enabled'] == true) {
        final s = _parseHour(v['start'] as String);
        final e = _parseHour(v['end']   as String);
        if (earliest == null || s < earliest!) earliest = s;
        if (latest   == null || e > latest!)   latest   = e;
      }
    });
    final start = earliest ?? 8;
    final end   = latest   ?? 18;
    return (startHour: start.clamp(0, 23), endHour: (end + 1).clamp(1, 24));
  }

  int    _parseHour(String t)  => int.tryParse(t.split(':')[0]) ?? 9;
  String _formatHour(int hour) {
    if (hour == 0)  return '12AM';
    if (hour == 12) return '12PM';
    return hour < 12 ? '${hour}AM' : '${hour - 12}PM';
  }
  String _formatDateKey(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days   = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
    return '${days[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
  String _fmtTime(DateTime dt) {
    final local = dt.isUtc ? dt.toLocal() : dt;
    final h = local.hour == 0 ? 12 : local.hour > 12 ? local.hour - 12 : local.hour;
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m ${local.hour < 12 ? 'AM' : 'PM'}';
  }
  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'new':         return const Color(0xFF6366f1);
      case 'confirmed':   return const Color(0xFF0EA5E9);
      case 'showed':      return AppTheme.success;
      case 'no-show':     return const Color(0xFFf59e0b);
      case 'cancelled':   return AppTheme.error;
      case 'invalid':     return const Color(0xFF94a3b8);
      case 'rescheduled': return const Color(0xFFa855f7);
      case 'blocked':     return const Color(0xFF94a3b8);
      case 'scheduled':   return const Color(0xFF6366f1);
      case 'completed':   return AppTheme.success;
      case 'no show':     return const Color(0xFFf59e0b);
      default:            return AppTheme.textSecondary;
    }
  }
  bool _isBlocked(Map<String, dynamic> a) =>
      (a['appointment_type'] ?? '').toString().toLowerCase() == 'blocked' ||
      (a['status'] ?? '').toString().toLowerCase() == 'blocked';

  // ══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        _buildTopBar(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _buildCalendarsTab(),
                    _buildAppointmentsTab(),
                    _buildCalendarManagerTab(),
                  ],
                ),
        ),
      ]),
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(children: [
        const SizedBox(width: 24),
        const Text('Calendars', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const SizedBox(width: 32),
        Expanded(child: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: AppTheme.brand,
          unselectedLabelColor: AppTheme.textSecondary,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 13),
          indicatorColor: AppTheme.brand,
          indicatorWeight: 2,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(text: 'Calendars'),
            Tab(text: 'Appointments'),
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.settings_outlined, size: 14),
              SizedBox(width: 6),
              Text('Calendar Settings'),
            ])),
          ],
        )),
        AnimatedBuilder(
          animation: _tabController,
          builder: (_, __) {
            if (_tabController.index == 2) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 16),
              child: ElevatedButton.icon(
                onPressed: _showNewAppointmentDialog,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            );
          },
        ),
      ]),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 1 — CALENDARS GRID VIEW
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildCalendarsTab() {
    return Column(children: [
      _buildCalendarToolbar(),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: LayoutBuilder(builder: (context, constraints) {
          if (_calView == 'day')  return _buildDayView(constraints);
          if (_calView == 'week') return _buildWeekView(constraints);
          return _buildMonthView(constraints);
        })),
        _buildRightPanel(),
      ])),
    ]);
  }

  Widget _buildCalendarToolbar() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(color: AppTheme.cardBg, border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
      child: Row(children: [
        Text(_dateRangeLabel(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const SizedBox(width: 8),
        IconButton(onPressed: _prevPeriod, icon: const Icon(Icons.chevron_left,  size: 18, color: AppTheme.textSecondary), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
        IconButton(onPressed: _nextPeriod, icon: const Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
        Clickable(
          onTap: () => setState(() => _focusDate = DateTime.now()),
          child: Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(border: Border.all(color: AppTheme.borderColor), borderRadius: BorderRadius.circular(6)),
            child: const Text('Today', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
        ),
        const Spacer(),
        Container(
          decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.borderColor)),
          child: Row(children: [_calViewBtn('Day','day'), _calViewBtn('Week','week'), _calViewBtn('Month','month')]),
        ),
      ]),
    );
  }

  Widget _calViewBtn(String label, String val) {
    final sel = _calView == val;
    return Clickable(
      onTap: () => setState(() => _calView = val),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(color: sel ? AppTheme.brand : Colors.transparent, borderRadius: BorderRadius.circular(5)),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: sel ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  String _dateRangeLabel() {
    const months     = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const fullMonths = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    if (_calView == 'day') return '${months[_focusDate.month-1]} ${_focusDate.day}, ${_focusDate.year}';
    if (_calView == 'week') {
      final monday = _focusDate.subtract(Duration(days: _focusDate.weekday - 1));
      final sunday = monday.add(const Duration(days: 6));
      if (monday.month == sunday.month) return '${months[monday.month-1]} ${monday.day} - ${sunday.day}, ${monday.year}';
      return '${months[monday.month-1]} ${monday.day} - ${months[sunday.month-1]} ${sunday.day}';
    }
    return '${fullMonths[_focusDate.month-1]} ${_focusDate.year}';
  }

  void _prevPeriod() => setState(() {
    if (_calView == 'day')       _focusDate = _focusDate.subtract(const Duration(days: 1));
    else if (_calView == 'week') _focusDate = _focusDate.subtract(const Duration(days: 7));
    else _focusDate = DateTime(_focusDate.year, _focusDate.month - 1);
  });

  void _nextPeriod() => setState(() {
    if (_calView == 'day')       _focusDate = _focusDate.add(const Duration(days: 1));
    else if (_calView == 'week') _focusDate = _focusDate.add(const Duration(days: 7));
    else _focusDate = DateTime(_focusDate.year, _focusDate.month + 1);
  });

  Widget _buildApptBlock(Map<String, dynamic> a, ({int startHour, int endHour}) range,
      double gutterWidth, double? colWidth, {int dayIndex = 0}) {
    const double hourHeight = 60.0;
    final start = DateTime.tryParse(a['start_date_time'] as String) ?? DateTime.now();
    final end   = DateTime.tryParse(a['end_date_time']   as String) ?? DateTime.now();
    final offsetHours = start.hour + start.minute / 60.0 - range.startHour;
    if (offsetHours < 0) return const SizedBox.shrink();
    final top     = offsetHours * hourHeight;
    final height  = ((end.difference(start).inMinutes) / 60.0) * hourHeight;
    final blocked = _isBlocked(a);
    final color   = blocked ? const Color(0xFF94a3b8) : _statusColor(a['status'] ?? '');
    final left    = colWidth != null ? gutterWidth + dayIndex * colWidth + 2 : gutterWidth + 4;
    final width   = colWidth != null ? colWidth - 4 : null;

    return Positioned(
      top: top, left: left, width: width, right: colWidth != null ? null : 4,
      height: height.clamp(20.0, double.infinity),
      child: Clickable(
        onTap: () => _showAppointmentDetail(a),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: colWidth != null ? 4 : 8, vertical: 2),
          decoration: BoxDecoration(
            color: blocked ? color.withValues(alpha: 0.20) : color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(colWidth != null ? 4 : 6),
            border: blocked ? Border.all(color: color.withValues(alpha: 0.4)) : null,
          ),
          child: colWidth != null
              ? Text(a['appointment_name'] ?? '',
                  style: TextStyle(fontSize: 10, color: blocked ? AppTheme.textSecondary : Colors.white, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis)
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a['appointment_name'] ?? '',
                      style: TextStyle(fontSize: 12, color: blocked ? AppTheme.textSecondary : Colors.white, fontWeight: FontWeight.w600)),
                  if (!blocked && (a['lead_name'] ?? '').isNotEmpty)
                    Text(a['lead_name'], style: const TextStyle(fontSize: 10, color: Colors.white70)),
                ]),
        ),
      ),
    );
  }

  Widget _buildDayView(BoxConstraints constraints) {
    const double hourHeight  = 60.0;
    const double gutterWidth = 56.0;
    final now     = DateTime.now();
    final isToday = DateUtils.isSameDay(_focusDate, now);
    final range   = _visibleHourRange();
    final hours   = List.generate(range.endHour - range.startHour, (i) => range.startHour + i);
    final dayAppts = _appointments.where((a) {
      final dt = DateTime.tryParse(a['start_date_time'] ?? '');
      return dt != null && DateUtils.isSameDay(dt, _focusDate);
    }).toList();

    return SingleChildScrollView(child: Column(children: [
      Container(
        height: 48,
        decoration: const BoxDecoration(color: AppTheme.cardBg, border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
        child: Row(children: [
          const SizedBox(width: gutterWidth),
          Expanded(child: Container(
            decoration: BoxDecoration(color: isToday ? AppTheme.brand.withValues(alpha: 0.04) : null, border: const Border(left: BorderSide(color: AppTheme.borderColor))),
            alignment: Alignment.center,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][_focusDate.weekday - 1],
                  style: TextStyle(fontSize: 11, color: isToday ? AppTheme.brand : AppTheme.textSecondary)),
              Container(width: 28, height: 28,
                decoration: BoxDecoration(color: isToday ? AppTheme.brand : null, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text('${_focusDate.day}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isToday ? Colors.white : AppTheme.textPrimary)),
              ),
            ]),
          )),
        ]),
      ),
      SizedBox(
        height: hourHeight * hours.length,
        child: Stack(children: [
          Column(children: hours.map((hour) => SizedBox(height: hourHeight, child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            SizedBox(width: gutterWidth, child: Text(_formatHour(hour), textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary))),
            Expanded(child: Container(decoration: BoxDecoration(
              border: Border(left: const BorderSide(color: AppTheme.borderColor), top: BorderSide(color: hour == hours.first ? Colors.transparent : AppTheme.borderColor)),
              color: isToday ? AppTheme.brand.withValues(alpha: 0.01) : null,
            ))),
          ]))).toList()),
          ...dayAppts.map((a) => _buildApptBlock(a, range, gutterWidth, null)),
          if (isToday && now.hour >= range.startHour && now.hour < range.endHour)
            Positioned(
              top: (now.hour + now.minute / 60.0 - range.startHour) * hourHeight - 1,
              left: gutterWidth, right: 0,
              child: Row(children: [
                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                Expanded(child: Container(height: 1.5, color: Colors.red)),
              ]),
            ),
        ]),
      ),
    ]));
  }

  Widget _buildWeekView(BoxConstraints constraints) {
    const double hourHeight  = 60.0;
    const double gutterWidth = 48.0;
    final monday   = _focusDate.subtract(Duration(days: _focusDate.weekday - 1));
    final days     = List.generate(7, (i) => monday.add(Duration(days: i)));
    final now      = DateTime.now();
    final colWidth = (constraints.maxWidth - gutterWidth) / 7;
    final range    = _visibleHourRange();
    final hours    = List.generate(range.endHour - range.startHour, (i) => range.startHour + i);

    return SingleChildScrollView(child: Column(children: [
      SizedBox(height: 52, child: Row(children: [
        const SizedBox(width: gutterWidth),
        ...days.map((d) {
          final isToday = DateUtils.isSameDay(d, now);
          return SizedBox(width: colWidth, child: Container(
            decoration: BoxDecoration(color: isToday ? AppTheme.brand.withValues(alpha: 0.04) : AppTheme.cardBg,
              border: const Border(left: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor))),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][d.weekday - 1],
                  style: TextStyle(fontSize: 11, color: isToday ? AppTheme.brand : AppTheme.textSecondary)),
              const SizedBox(height: 2),
              Container(width: 28, height: 28,
                decoration: BoxDecoration(color: isToday ? AppTheme.brand : null, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text('${d.day}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isToday ? Colors.white : AppTheme.textPrimary)),
              ),
            ]),
          ));
        }),
      ])),
      SizedBox(
        height: hourHeight * hours.length,
        child: Stack(children: [
          Column(children: hours.map((hour) => SizedBox(height: hourHeight, child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            SizedBox(width: gutterWidth, child: Text(_formatHour(hour), textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary))),
            ...days.map((d) => SizedBox(width: colWidth, child: Container(decoration: BoxDecoration(
              border: Border(left: const BorderSide(color: AppTheme.borderColor), top: BorderSide(color: hour == hours.first ? Colors.transparent : AppTheme.borderColor)),
              color: DateUtils.isSameDay(d, now) ? AppTheme.brand.withValues(alpha: 0.02) : null,
            )))),
          ]))).toList()),
          ..._appointments.where((a) {
            final dt = DateTime.tryParse(a['start_date_time'] ?? '');
            return dt != null && days.any((d) => DateUtils.isSameDay(d, dt));
          }).map((a) {
            final start    = DateTime.tryParse(a['start_date_time'] as String) ?? DateTime.now();
            final dayIndex = days.indexWhere((d) => DateUtils.isSameDay(d, start));
            if (dayIndex < 0) return const SizedBox.shrink();
            return _buildApptBlock(a, range, gutterWidth, colWidth, dayIndex: dayIndex);
          }),
          if (days.any((d) => DateUtils.isSameDay(d, now)) && now.hour >= range.startHour && now.hour < range.endHour)
            Positioned(
              top: (now.hour + now.minute / 60.0 - range.startHour) * hourHeight - 1,
              left: gutterWidth, right: 0,
              child: Row(children: [
                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                Expanded(child: Container(height: 1.5, color: Colors.red)),
              ]),
            ),
        ]),
      ),
    ]));
  }

  Widget _buildMonthView(BoxConstraints constraints) {
    final firstDay    = DateTime(_focusDate.year, _focusDate.month, 1);
    final daysInMonth = DateUtils.getDaysInMonth(_focusDate.year, _focusDate.month);
    final startOffset = firstDay.weekday % 7;
    final rowCount    = ((startOffset + daysInMonth) / 7).ceil();
    final now         = DateTime.now();
    final cellHeight  = (constraints.maxHeight - 36.0 - 8.0) / rowCount;

    return Column(children: [
      SizedBox(height: 36, child: Row(children: ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'].map((d) => Expanded(child: Container(
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: AppTheme.cardBg, border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
        child: Text(d, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
      ))).toList())),
      ...List.generate(rowCount, (row) => SizedBox(
        height: cellHeight,
        child: Row(children: List.generate(7, (col) {
          final dayNum = row * 7 + col - startOffset + 1;
          if (dayNum < 1 || dayNum > daysInMonth) {
            return Expanded(child: Container(decoration: BoxDecoration(
              border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.3)),
              color: AppTheme.pageBg.withValues(alpha: 0.3),
            )));
          }
          final date     = DateTime(_focusDate.year, _focusDate.month, dayNum);
          final isToday  = DateUtils.isSameDay(date, now);
          final dayAppts = _appointments.where((a) {
            final dt = DateTime.tryParse(a['start_date_time'] ?? '')?.toLocal();
            return dt != null && DateUtils.isSameDay(dt, date);
          }).toList();

          return Expanded(child: Clickable(
            onTap: () => dayAppts.isNotEmpty ? _showDaySheet(date, dayAppts) : setState(() { _focusDate = date; _calView = 'day'; }),
            child: Container(
              decoration: BoxDecoration(
                color: isToday ? AppTheme.brand.withValues(alpha: 0.04) : AppTheme.cardBg,
                border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.5)),
              ),
              padding: const EdgeInsets.all(4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: 24, height: 24,
                  decoration: BoxDecoration(color: isToday ? AppTheme.brand : null, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: Text('$dayNum', style: TextStyle(fontSize: 12, fontWeight: isToday ? FontWeight.w700 : FontWeight.w400, color: isToday ? Colors.white : AppTheme.textPrimary)),
                ),
                ...dayAppts.take(2).map((a) {
                  final blocked = _isBlocked(a);
                  final color   = blocked ? const Color(0xFF94a3b8) : _statusColor(a['status'] ?? '');
                  return Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                    decoration: BoxDecoration(color: color.withValues(alpha: blocked ? 0.12 : 0.15), borderRadius: BorderRadius.circular(3)),
                    child: Text(a['appointment_name'] ?? '',
                        style: TextStyle(fontSize: 9, color: blocked ? AppTheme.textSecondary : color, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis),
                  );
                }),
                if (dayAppts.length > 2) Text('+${dayAppts.length - 2} more', style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary)),
              ]),
            ),
          ));
        })),
      )),
    ]);
  }

  // ── RIGHT PANEL ───────────────────────────────────────────────────────────

  Widget _buildRightPanel() {
    final now         = DateTime.now();
    final firstDay    = DateTime(_focusDate.year, _focusDate.month, 1);
    final daysInMonth = DateUtils.getDaysInMonth(_focusDate.year, _focusDate.month);
    final startOffset = firstDay.weekday % 7;
    const fullMonths  = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    final activeCtrl  = _panelTab == 0 ? _usersSearchCtrl : _panelTab == 1 ? _calendarsSearchCtrl : _groupsSearchCtrl;
    final activeHint  = _panelTab == 0 ? 'Search for User' : _panelTab == 1 ? 'Search Calendars' : 'Search Groups';
    final filteredUsers     = <String>['Owner'].where((u) => u.toLowerCase().contains(_usersSearchCtrl.text.toLowerCase())).toList();
    final filteredCalendars = _calendars.where((c) => (c['name'] ?? '').toString().toLowerCase().contains(_calendarsSearchCtrl.text.toLowerCase())).toList();

    return Container(
      width: 240,
      decoration: const BoxDecoration(color: AppTheme.cardBg, border: Border(left: BorderSide(color: AppTheme.borderColor))),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${fullMonths[_focusDate.month-1]} ${_focusDate.year}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary))),
              Clickable(onTap: () => setState(() => _focusDate = DateTime(_focusDate.year, _focusDate.month - 1)), child: const Icon(Icons.chevron_left,  size: 16, color: AppTheme.textSecondary)),
              Clickable(onTap: () => setState(() => _focusDate = DateTime(_focusDate.year, _focusDate.month + 1)), child: const Icon(Icons.chevron_right, size: 16, color: AppTheme.textSecondary)),
            ]),
            const SizedBox(height: 6),
            Row(children: ['S','M','T','W','T','F','S'].map((d) => Expanded(child: Center(child: Text(d, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.textSecondary))))).toList()),
            const SizedBox(height: 2),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, childAspectRatio: 1),
              itemCount: startOffset + daysInMonth,
              itemBuilder: (context, index) {
                if (index < startOffset) return const SizedBox();
                final day  = index - startOffset + 1;
                final date = DateTime(_focusDate.year, _focusDate.month, day);
                final isToday    = DateUtils.isSameDay(date, now);
                final isSelected = DateUtils.isSameDay(date, _focusDate);
                final hasAppt    = _appointments.any((a) {
                  final dt = DateTime.tryParse(a['start_date_time'] ?? '')?.toLocal();
                  return dt != null && DateUtils.isSameDay(dt, date);
                });
                return Clickable(
                  onTap: () => setState(() { _focusDate = date; _calView = 'day'; }),
                  child: Container(
                    margin: const EdgeInsets.all(1),
                    decoration: BoxDecoration(color: isSelected ? AppTheme.brand : isToday ? AppTheme.brand.withValues(alpha: 0.1) : null, shape: BoxShape.circle),
                    child: Stack(alignment: Alignment.center, children: [
                      Text('$day', style: TextStyle(fontSize: 10, color: isSelected ? Colors.white : isToday ? AppTheme.brand : AppTheme.textPrimary)),
                      if (hasAppt && !isSelected) Positioned(bottom: 1, child: Container(width: 3, height: 3, decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle))),
                    ]),
                  ),
                );
              },
            ),
          ]),
        ),
        const Divider(height: 1, color: AppTheme.borderColor),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Upcoming', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            ..._appointments.where((a) {
              final dt = DateTime.tryParse(a['start_date_time'] ?? '');
              return dt != null && dt.isAfter(DateTime.now().subtract(const Duration(hours: 1))) && !_isBlocked(a);
            }).take(3).map((a) {
              final dt = DateTime.parse(a['start_date_time'] as String);
              return Clickable(
                onTap: () => _showAppointmentDetail(a),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(color: _statusColor(a['status'] ?? '').withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6), border: Border.all(color: _statusColor(a['status'] ?? '').withValues(alpha: 0.2))),
                  child: Row(children: [
                    Container(width: 3, height: 28, decoration: BoxDecoration(color: _statusColor(a['status'] ?? ''), borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 7),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(a['appointment_name'] ?? '', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textPrimary), overflow: TextOverflow.ellipsis),
                      Text('${_fmtTime(dt)} · ${a['lead_name'] ?? ''}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    ])),
                  ]),
                ),
              );
            }),
          ]),
        ),
        const Divider(height: 1, color: AppTheme.borderColor),
        Row(children: [_panelTabBtn('Users',0), _panelTabBtn('Calendars',1), _panelTabBtn('Groups',2)]),
        const Divider(height: 1, color: AppTheme.borderColor),
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: activeCtrl, onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: activeHint, hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              prefixIcon: const Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
              filled: true, fillColor: AppTheme.pageBg, contentPadding: const EdgeInsets.symmetric(vertical: 6),
              border:        OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: AppTheme.brand)),
            ),
          ),
        ),
        Expanded(child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: _panelTab == 0
              ? filteredUsers.map((u) => _panelUserRow(u, AppTheme.brand)).toList()
              : _panelTab == 1
                  ? filteredCalendars.map((c) => _panelCheckRow(c['name'] ?? 'Unnamed', const Color(0xFF6366F1))).toList()
                  : [],
        )),
      ]),
    );
  }

  Widget _panelTabBtn(String label, int idx) {
    final sel = _panelTab == idx;
    return Expanded(child: Clickable(
      onTap: () => setState(() => _panelTab = idx),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: sel ? AppTheme.brand : Colors.transparent, width: 2))),
        alignment: Alignment.center,
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: sel ? FontWeight.w600 : FontWeight.w400, color: sel ? AppTheme.brand : AppTheme.textSecondary)),
      ),
    ));
  }

  Widget _panelUserRow(String name, Color color) {
    final initials = name.trim().split(' ').map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
      Container(width: 28, height: 28, decoration: BoxDecoration(color: color, shape: BoxShape.circle), alignment: Alignment.center,
          child: Text(initials, style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600))),
      const SizedBox(width: 8),
      Expanded(child: Text(name, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
      Checkbox(value: true, onChanged: (_) {}, activeColor: AppTheme.brand, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
    ]));
  }

  Widget _panelCheckRow(String label, Color color) {
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
      Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 8),
      Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
      Checkbox(value: true, onChanged: (_) {}, activeColor: color, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
    ]));
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 2 — APPOINTMENTS LIST
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildAppointmentsTab() {
    final filtered = _filtered;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Row(children: [
          _MiniStat(label: 'Total',     value: '${_appointments.length}', color: AppTheme.brand),
          const SizedBox(width: 8),
          _MiniStat(label: 'New',       value: '${_appointments.where((a) => a['status'] == 'New').length}',       color: const Color(0xFF6366f1)),
          const SizedBox(width: 8),
          _MiniStat(label: 'Confirmed', value: '${_appointments.where((a) => a['status'] == 'Confirmed').length}', color: const Color(0xFF0EA5E9)),
          const SizedBox(width: 8),
          _MiniStat(label: 'Showed',    value: '${_appointments.where((a) => a['status'] == 'Showed').length}',    color: AppTheme.success),
          const SizedBox(width: 8),
          _MiniStat(label: 'No-Show',   value: '${_appointments.where((a) => a['status'] == 'No-Show' || a['status'] == 'No Show').length}', color: const Color(0xFFf59e0b)),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          ..._statuses.map((s) {
            final selected = _statusFilter == s;
            return Padding(padding: const EdgeInsets.only(right: 8), child: Clickable(
              onTap: () => setState(() => _statusFilter = s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(color: selected ? AppTheme.brand : AppTheme.cardBg, borderRadius: BorderRadius.circular(99), border: Border.all(color: selected ? AppTheme.brand : AppTheme.borderColor)),
                child: Text(s, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: selected ? Colors.white : AppTheme.textSecondary)),
              ),
            ));
          }),
          const Spacer(),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 18, color: AppTheme.textSecondary)),
        ]),
        const SizedBox(height: 16),
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.calendar_today_outlined, size: 48, color: AppTheme.textMuted),
                  const SizedBox(height: 12),
                  const Text('No appointments found', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _showNewAppointmentDialog, child: const Text('Schedule your first appointment')),
                ]))
              : Container(
                  decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
                  child: Column(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
                      child: const Row(children: [
                        Expanded(flex: 3, child: Text('APPOINTMENT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                        Expanded(flex: 2, child: Text('CONTACT',     style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                        Expanded(flex: 2, child: Text('TIME',        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                        Expanded(flex: 2, child: Text('TYPE',        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                        Expanded(flex: 2, child: Text('STATUS',      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
                        SizedBox(width: 40),
                      ]),
                    ),
                    Expanded(child: ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                      itemBuilder: (_, i) {
                        final appt    = filtered[i];
                        final startDt = DateTime.tryParse(appt['start_date_time'] ?? '') ?? DateTime.now();
                        final endDt   = DateTime.tryParse(appt['end_date_time']   ?? '') ?? DateTime.now();
                        final status  = appt['status'] ?? 'New';
                        return MouseRegion(cursor: SystemMouseCursors.click, child: InkWell(
                          onTap: () => _showAppointmentDetail(appt),
                          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(children: [
                            Expanded(flex: 3, child: Row(children: [
                              Container(width: 30, height: 30, decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)), alignment: Alignment.center, child: const Icon(Icons.calendar_today, size: 14, color: AppTheme.brand)),
                              const SizedBox(width: 10),
                              Expanded(child: Text(appt['appointment_name'] ?? 'Untitled', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
                            ])),
                            Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(appt['lead_name'] ?? '—', style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                              if ((appt['lead_phone'] ?? '').isNotEmpty) Text(appt['lead_phone'], style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                            ])),
                            Expanded(flex: 2, child: Text('${_fmtTime(startDt)} - ${_fmtTime(endDt)}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                            Expanded(flex: 2, child: Text(appt['appointment_type'] ?? '—', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                            Expanded(flex: 2, child: _StatusBadge(status: status, colorFn: _statusColor)),
                            SizedBox(width: 40, child: IconButton(icon: const Icon(Icons.more_vert, size: 16, color: AppTheme.textMuted), onPressed: () => _showAppointmentDetail(appt))),
                          ])),
                        ));
                      },
                    )),
                  ]),
                ),
        ),
      ]),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 3 — CALENDAR MANAGER
  // ══════════════════════════════════════════════════════════════════════════

  // Sub-tab index for Calendar Settings
  int _calSettingsTab = 0;

  Widget _buildCalendarManagerTab() {
    return DefaultTabController(
      length: 5,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Top bar: title + buttons
        Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Calendar Settings',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
              const SizedBox(height: 4),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.group_add_outlined, size: 16),
                label: const Text('Create Group'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: _showSchedulingTypePicker,
                icon: const Icon(Icons.calendar_month, size: 16),
                label: const Text('Create Calendar'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            const Text('Manage your calendars and groups.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            TabBar(
              onTap: (i) => setState(() => _calSettingsTab = i),
              labelColor: AppTheme.brand,
              unselectedLabelColor: AppTheme.textSecondary,
              labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              unselectedLabelStyle: const TextStyle(fontSize: 13),
              indicatorColor: AppTheme.brand,
              indicatorWeight: 2,
              dividerColor: Colors.transparent,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: const [
                Tab(text: 'Calendars'),
                Tab(text: 'Groups'),
                Tab(text: 'Service Menu'),
                Tab(text: 'Rooms'),
                Tab(text: 'Equipment'),
              ],
            ),
          ]),
        ),
        // Tab content
        Expanded(child: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _buildCalendarsListTab(),
            _buildComingSoonTab('Groups'),
            _buildComingSoonTab('Service Menu'),
            _buildComingSoonTab('Rooms'),
            _buildComingSoonTab('Equipment'),
          ],
        )),
      ]),
    );
  }

  Widget _buildComingSoonTab(String name) {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.construction_outlined, size: 48, color: AppTheme.textMuted),
      const SizedBox(height: 12),
      Text('$name coming soon', style: const TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
    ]));
  }

  Widget _buildCalendarsListTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        // Table header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: const Row(children: [
            Expanded(flex: 4, child: Text('CALENDAR NAME', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('TYPE',     style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('DURATION', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('STATUS',   style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            SizedBox(width: 80),
          ]),
        ),
        Expanded(
          child: _calendars.isEmpty
              ? Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.calendar_month_outlined, size: 48, color: AppTheme.textMuted),
                    const SizedBox(height: 12),
                    const Text('No calendars yet', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _showSchedulingTypePicker, child: const Text('Create your first calendar')),
                  ])),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: ListView.separated(
                    itemCount: _calendars.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                    itemBuilder: (_, i) {
                      final cal      = _calendars[i];
                      final type     = cal['calendar_type'] ?? 'personal';
                      final duration = cal['duration_minutes'] as int? ?? 60;
                      final isActive = cal['is_active'] as bool? ?? true;
                      final typeLabel = {'personal': 'Personal Booking', 'round_robin': 'Round Robin', 'class': 'Class Booking', 'collective': 'Collective Booking'}[type] ?? type;
                      final durationLabel = duration < 60 ? '${duration}m' : duration % 60 == 0 ? '${duration ~/ 60}h' : '${duration ~/ 60}h ${duration % 60}m';
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Row(children: [
                          Expanded(flex: 4, child: Row(children: [
                            Container(width: 36, height: 36,
                                decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                                alignment: Alignment.center,
                                child: const Icon(Icons.calendar_month, size: 18, color: AppTheme.brand)),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(cal['name'] ?? 'Unnamed', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                              if ((cal['description'] ?? '').isNotEmpty)
                                Text(cal['description'], style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                            ])),
                          ])),
                          Expanded(flex: 2, child: Text(typeLabel,     style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                          Expanded(flex: 2, child: Text(durationLabel, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                          Expanded(flex: 2, child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: isActive ? AppTheme.success.withValues(alpha: 0.1) : AppTheme.borderColor.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(isActive ? 'Active' : 'Inactive',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
                                    color: isActive ? AppTheme.success : AppTheme.textSecondary)),
                          )),
                          SizedBox(width: 80, child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            IconButton(icon: const Icon(Icons.edit_outlined,  size: 16, color: AppTheme.textSecondary), onPressed: () => _showCreateCalendarDialog(existing: cal)),
                            IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.error),         onPressed: () => _deleteCalendar(cal)),
                          ])),
                        ]),
                      );
                    },
                  ),
                ),
        ),
      ]),
    );
  }

  void _showSchedulingTypePicker() {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 60, vertical: 80),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Scheduling type', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                  SizedBox(height: 4),
                  Text('Choose a scheduling type for your new calendar', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                ])),
                IconButton(
                  onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                  icon: const Icon(Icons.close, size: 20, color: AppTheme.textSecondary),
                ),
              ]),
              const SizedBox(height: 20),
              Row(children: [
                _schedTypeCard(ctx, 'personal',    'Personal Booking',   'Schedules one-on-one meetings with a specific team member.\nE.g.: Client meetings, private consultations.', Icons.person_outline),
                const SizedBox(width: 12),
                _schedTypeCard(ctx, 'round_robin', 'Round Robin',        'Distributes appointments among team members in a rotating order.\nE.g.: Sales calls, onboarding sessions.', Icons.rotate_right_outlined),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _schedTypeCard(ctx, 'class',       'Class Booking',      'One host meets with multiple participants.\nE.g.: Webinars, group training, online classes.', Icons.groups_outlined),
                const SizedBox(width: 12),
                _schedTypeCard(ctx, 'collective',  'Collective Booking', 'Multiple hosts meet with one participant.\nE.g.: Panel interviews, committee reviews.', Icons.people_outline),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _schedTypeCard(BuildContext ctx, String type, String title, String desc, IconData icon) {
    return Expanded(child: Clickable(
      onTap: () {
        Navigator.of(ctx, rootNavigator: true).pop();
        _showCreateCalendarDialog(preselectedType: type);
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: AppTheme.brand),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            const SizedBox(height: 4),
            Text(desc, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ])),
        ]),
      ),
    ));
  }

  Future<void> _deleteCalendar(Map<String, dynamic> cal) async {
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete Calendar'),
      content: Text('Delete "${cal['name']}"? Appointments on this calendar will remain but lose their calendar assignment.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),  child: const Text('Delete', style: TextStyle(color: AppTheme.error))),
      ],
    ));
    if (confirmed != true) return;
    await _db.from('calendars').delete().eq('id', cal['id']);
    _load();
  }

  void _showCreateCalendarDialog({Map<String, dynamic>? existing, String? preselectedType}) {
    showDialog(context: context, barrierColor: Colors.black54, builder: (ctx) => _CalendarFormDialog(
      businessId: _businessId, teamMembers: _teamMembers, existing: existing,
      preselectedType: preselectedType,
      onSaved: (String calendarName) {
        Navigator.of(ctx, rootNavigator: true).pop();
        _load();
        if (existing == null) {
          _showCalendarSuccessDialog(calendarName);
        }
      },
    ));
  }

  void _showCalendarSuccessDialog(String calendarName) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 100),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(color: AppTheme.success.withValues(alpha: 0.1), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: const Icon(Icons.calendar_month, size: 28, color: AppTheme.success),
              ),
              const SizedBox(height: 16),
              const Text('Success', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
              const SizedBox(height: 6),
              Text('You have successfully configured the "$calendarName" calendar',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const SizedBox(height: 28),
              Row(children: [
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.borderColor),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Close', style: TextStyle(color: AppTheme.textPrimary)),
                )),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  void _showNewAppointmentDialog() {
    showDialog(context: context, barrierColor: Colors.black54, builder: (ctx) => _NewAppointmentDialog(
      appointmentTypes: _appointmentTypes, appointmentStatuses: _appointmentStatuses,
      teamMembers: _teamMembers, leads: _leads, calendars: _calendars, businessId: _businessId,
      onSaved: () { Navigator.of(ctx, rootNavigator: true).pop(); _load(); },
    ));
  }

  void _showAppointmentDetail(Map<String, dynamic> appt) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _AppointmentDetailSheet(appointment: appt, appointmentStatuses: _appointmentStatuses, colorFn: _statusColor, onUpdated: () { Navigator.pop(context); _load(); }));
  }

  void _showDaySheet(DateTime date, List<Map<String, dynamic>> appts) {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent, builder: (_) => Container(
      decoration: const BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        Text(_formatDateKey(date), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
        const SizedBox(height: 12),
        ...appts.map((a) => Clickable(
          onTap: () { Navigator.pop(context); _showAppointmentDetail(a); },
          child: Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
            child: Row(children: [
              _StatusBadge(status: a['status'] ?? '', colorFn: _statusColor),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a['appointment_name'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                Text('${_fmtTime(DateTime.tryParse(a['start_date_time'] ?? '') ?? DateTime.now())} · ${a['lead_name'] ?? ''}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ])),
              const Icon(Icons.chevron_right, size: 16, color: AppTheme.textMuted),
            ]),
          ),
        )),
      ]),
    ));
  }
}
// ═══════════════ END OF PART 1 — continue with appt_part2.dart ═══════════════
// ═══════════════ PART 2 OF 4 — paste directly after Part 1 ═══════════════

// ══════════════════════════════════════════════════════════════════════════════
//  CALENDAR FORM DIALOG (Create / Edit)
// ══════════════════════════════════════════════════════════════════════════════

class _CalendarFormDialog extends StatefulWidget {
  final int? businessId;
  final List<Map<String, dynamic>> teamMembers;
  final Map<String, dynamic>? existing;
 final void Function(String calendarName) onSaved;

  final String? preselectedType;

  const _CalendarFormDialog({
    required this.businessId,
    required this.teamMembers,
    required this.onSaved,
    this.existing,
    this.preselectedType,
  });

  @override
  State<_CalendarFormDialog> createState() => _CalendarFormDialogState();
}

class _CalendarFormDialogState extends State<_CalendarFormDialog> {
  final _db       = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  String  _calType       = 'personal';
  int     _duration      = 60;
  int     _customDuration = 45;
  bool    _isActive      = true;
  bool    _saving        = false;
  String? _error;
  Set<String> _selectedMemberIds = {};

  Map<String, Map<String, dynamic>> _availability = {
    'monday':    {'enabled': true,  'start': '09:00', 'end': '17:00'},
    'tuesday':   {'enabled': true,  'start': '09:00', 'end': '17:00'},
    'wednesday': {'enabled': true,  'start': '09:00', 'end': '17:00'},
    'thursday':  {'enabled': true,  'start': '09:00', 'end': '17:00'},
    'friday':    {'enabled': true,  'start': '09:00', 'end': '17:00'},
    'saturday':  {'enabled': false, 'start': '09:00', 'end': '17:00'},
    'sunday':    {'enabled': false, 'start': '09:00', 'end': '17:00'},
  };

  static const _calTypes = [
    ('personal',    'Personal Booking',   'One-on-one meetings with a specific team member.'),
    ('round_robin', 'Round Robin',        'Distributes appointments among team members.'),
    ('class',       'Class Booking',      'One host meets with multiple participants.'),
    ('collective',  'Collective Booking', 'Multiple hosts meet with one participant.'),
  ];

  List<String> get _timeValues => List.generate(48, (i) {
    final h = i ~/ 2;
    final m = i % 2 == 0 ? '00' : '30';
    return '${h.toString().padLeft(2, '0')}:$m';
  });

  List<String> get _timeLabels => List.generate(48, (i) {
    final h    = i ~/ 2;
    final m    = i % 2 == 0 ? '00' : '30';
    final hour = h == 0 ? 12 : h > 12 ? h - 12 : h;
    return '${hour.toString().padLeft(2, '0')}:$m ${h < 12 ? 'AM' : 'PM'}';
  });

  @override
  void initState() {
    super.initState();
    if (widget.preselectedType != null && widget.existing == null) {
      _calType = widget.preselectedType!;
    }
    if (widget.existing != null) {
      final e = widget.existing!;
      _nameCtrl.text = e['name']        ?? '';
      _descCtrl.text = e['description'] ?? '';
      _calType       = e['calendar_type']    ?? 'personal';
      _duration      = e['duration_minutes'] as int? ?? 60;
      _isActive      = e['is_active']        as bool? ?? true;
      _selectedMemberIds = (e['team_member_ids'] as List?)
          ?.map((v) => v.toString()).toSet() ?? {};
      final ah = e['availability_hours'];
      if (ah != null) {
        final map = ah is String ? jsonDecode(ah) : ah;
        (map as Map).forEach((day, val) {
          if (_availability.containsKey(day)) {
            _availability[day] = {
              'enabled': val['enabled'] ?? false,
              'start':   val['start']   ?? '09:00',
              'end':     val['end']     ?? '17:00',
            };
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Calendar name is required');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final effectiveDuration = _duration == -1 ? _customDuration : _duration;
      final payload = {
        'business_id':       widget.businessId,
        'name':              _nameCtrl.text.trim(),
        'description':       _descCtrl.text.trim(),
        'calendar_type':     _calType,
        'duration_minutes':  effectiveDuration,
        'availability_hours': _availability,
        'team_member_ids':   _selectedMemberIds.toList(),
        'is_active':         _isActive,
        'updated_at':        DateTime.now().toIso8601String(),
      };
      if (widget.existing != null) {
        await _db.from('calendars').update(payload).eq('id', widget.existing!['id']);
      } else {
        await _db.from('calendars').insert(payload);
      }
      widget.onSaved(_nameCtrl.text.trim());
    } catch (e) {
      setState(() => _error = 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const days      = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
    const dayLabels = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];

    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 800),
        child: Column(children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              Expanded(child: Text(
                widget.existing != null ? 'Edit Calendar' : 'New Calendar',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
              )),
              IconButton(
                onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                icon: const Icon(Icons.close, size: 20, color: AppTheme.textSecondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ]),
          ),
          // Body
          Flexible(child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // Name
              _label('Calendar Name'),
              const SizedBox(height: 4),
              _textField(_nameCtrl, hint: 'e.g. Consultation Calendar'),
              const SizedBox(height: 12),

              // Description
              _label('Description (optional)'),
              const SizedBox(height: 4),
              _textField(_descCtrl, hint: 'Brief description...', maxLines: 2),
              const SizedBox(height: 20),

              // Scheduling type
              _label('Scheduling Type'),
              const SizedBox(height: 8),
              ...(_calTypes.map((t) {
                final (val, title, desc) = t;
                final sel = _calType == val;
                return Clickable(
                  onTap: () => setState(() => _calType = val),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: sel ? AppTheme.brand.withValues(alpha: 0.05) : AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: sel ? AppTheme.brand : AppTheme.borderColor, width: sel ? 2 : 1),
                    ),
                    child: Row(children: [
                      Container(
                        width: 18, height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: sel ? AppTheme.brand : AppTheme.borderColor, width: 2),
                          color: sel ? AppTheme.brand : Colors.transparent,
                        ),
                        child: sel ? const Icon(Icons.check, size: 11, color: Colors.white) : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: sel ? AppTheme.brand : AppTheme.textPrimary)),
                        Text(desc, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      ])),
                    ]),
                  ),
                );
              })),
              const SizedBox(height: 20),

              // Duration
              _label('Meeting Duration'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                ...[15, 30, 45, 60, 90, 120].map((min) {
                  final sel = _duration == min;
                  return Clickable(
                    onTap: () => setState(() => _duration = min),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: sel ? AppTheme.brand : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: sel ? AppTheme.brand : AppTheme.borderColor),
                      ),
                      child: Text(
                        min < 60 ? '${min}m' : '${min ~/ 60}h${min % 60 > 0 ? ' ${min % 60}m' : ''}',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                            color: sel ? Colors.white : AppTheme.textSecondary),
                      ),
                    ),
                  );
                }),
                Clickable(
                  onTap: () => setState(() => _duration = -1),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: _duration == -1 ? AppTheme.brand : AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _duration == -1 ? AppTheme.brand : AppTheme.borderColor),
                    ),
                    child: Text('Custom', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                        color: _duration == -1 ? Colors.white : AppTheme.textSecondary)),
                  ),
                ),
              ]),
              if (_duration == -1) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: 140,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    controller: TextEditingController(text: '$_customDuration')
                      ..selection = TextSelection.collapsed(offset: '$_customDuration'.length),
                    onChanged: (v) {
                      final p = int.tryParse(v);
                      if (p != null && p > 0) setState(() => _customDuration = p);
                    },
                    decoration: _inputDecor(hint: 'Minutes'),
                  ),
                ),
              ],
              const SizedBox(height: 20),

              // Team members
              if (widget.teamMembers.isNotEmpty) ...[
                _label('Team Members'),
                const SizedBox(height: 8),
                ...widget.teamMembers.map((m) {
                  final id      = m['id']?.toString() ?? '';
                  final name    = m['full_name']?.toString() ?? 'Unknown';
                  final initials = name.trim().split(' ')
                      .map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
                  final checked = _selectedMemberIds.contains(id);
                  return Clickable(
                    onTap: () => setState(() {
                      if (checked) _selectedMemberIds.remove(id);
                      else         _selectedMemberIds.add(id);
                    }),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: checked ? AppTheme.brand.withValues(alpha: 0.05) : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: checked ? AppTheme.brand.withValues(alpha: 0.3) : AppTheme.borderColor),
                      ),
                      child: Row(children: [
                        Container(
                          width: 30, height: 30,
                          decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                          alignment: Alignment.center,
                          child: Text(initials, style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(name, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
                        Checkbox(
                          value: checked,
                          onChanged: (_) => setState(() {
                            if (checked) _selectedMemberIds.remove(id);
                            else         _selectedMemberIds.add(id);
                          }),
                          activeColor: AppTheme.brand,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ]),
                    ),
                  );
                }),
                const SizedBox(height: 20),
              ],

              // Availability
              _label('Booking Availability'),
              const SizedBox(height: 4),
              const Text('Set when this calendar accepts bookings.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              const SizedBox(height: 12),
              ...List.generate(days.length, (i) {
                final day     = days[i];
                final label   = dayLabels[i];
                final dayData = _availability[day]!;
                final enabled = dayData['enabled'] as bool;
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor.withValues(alpha: enabled ? 1.0 : 0.4)),
                  ),
                  child: Row(children: [
                    Switch(
                      value: enabled,
                      onChanged: (v) => setState(() => _availability[day]!['enabled'] = v),
                      activeColor: AppTheme.brand,
                    ),
                    const SizedBox(width: 10),
                    SizedBox(width: 110, child: Text(label,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
                    if (!enabled)
                      const Expanded(child: Text('Unavailable', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                    else ...[
                      Expanded(child: _timeDropdown(
                        value: dayData['start'] as String,
                        onChanged: (v) => setState(() => _availability[day]!['start'] = v!),
                      )),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text('to', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      ),
                      Expanded(child: _timeDropdown(
                        value: dayData['end'] as String,
                        onChanged: (v) => setState(() => _availability[day]!['end'] = v!),
                      )),
                    ],
                  ]),
                );
              }),
              const SizedBox(height: 16),

              // Active toggle
              Row(children: [
                Switch(value: _isActive, onChanged: (v) => setState(() => _isActive = v), activeColor: AppTheme.brand),
                const SizedBox(width: 8),
                const Text('Calendar is active', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
              ]),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(fontSize: 13, color: AppTheme.error)),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity, height: 44,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _saving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(widget.existing != null ? 'Save Changes' : 'Create Calendar',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          )),
        ]),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary));

  Widget _textField(TextEditingController ctrl, {String? hint, int maxLines = 1}) {
    return TextField(
      controller: ctrl, maxLines: maxLines,
      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
      decoration: _inputDecor(hint: hint),
    );
  }

  InputDecoration _inputDecor({String? hint}) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
    filled: true, fillColor: AppTheme.pageBg,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border:        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
  );

  Widget _timeDropdown({required String value, required ValueChanged<String?> onChanged}) {
    final vals      = _timeValues;
    final lbls      = _timeLabels;
    final safeValue = vals.contains(value) ? value : vals.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(
        value: safeValue, isExpanded: true, dropdownColor: AppTheme.cardBg,
        style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
        items: List.generate(vals.length, (i) => DropdownMenuItem(value: vals[i], child: Text(lbls[i]))),
        onChanged: onChanged,
      )),
    );
  }
}
// ═══════════════ END OF PART 2 — continue with appt_part3.dart ═══════════════
// ═══════════════ PART 3 OF 4 — paste directly after Part 2 ═══════════════

// ══════════════════════════════════════════════════════════════════════════════
//  NEW APPOINTMENT DIALOG  (Appointment | Blocked Off Time tabs)
// ══════════════════════════════════════════════════════════════════════════════

class _NewAppointmentDialog extends StatefulWidget {
  final List<String> appointmentTypes;
  final List<String> appointmentStatuses;
  final List<Map<String, dynamic>> teamMembers;
  final List<Map<String, dynamic>> leads;
  final List<Map<String, dynamic>> calendars;
  final int? businessId;
  final VoidCallback onSaved;

  const _NewAppointmentDialog({
    required this.appointmentTypes,
    required this.appointmentStatuses,
    required this.teamMembers,
    required this.leads,
    required this.calendars,
    required this.businessId,
    required this.onSaved,
  });

  @override
  State<_NewAppointmentDialog> createState() => _NewAppointmentDialogState();
}

class _NewAppointmentDialogState extends State<_NewAppointmentDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 780),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header + tabs
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
                child: Row(children: [
                  Expanded(child: Text(
                    _tabs.index == 0 ? 'Book Appointment' : 'Block Off Time',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                  )),
                  IconButton(
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    icon: const Icon(Icons.close, size: 20, color: AppTheme.textSecondary),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ]),
              ),
              TabBar(
                controller: _tabs,
                labelColor: AppTheme.brand,
                unselectedLabelColor: AppTheme.textSecondary,
                labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                unselectedLabelStyle: const TextStyle(fontSize: 13),
                indicatorColor: AppTheme.brand,
                indicatorWeight: 2,
                dividerColor: Colors.transparent,
                tabs: const [
                  Tab(text: 'Appointment'),
                  Tab(text: 'Blocked Off Time'),
                ],
              ),
            ]),
          ),
          // Tab content
          Flexible(child: TabBarView(
            controller: _tabs,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _AppointmentFormTab(
                appointmentTypes:    widget.appointmentTypes,
                appointmentStatuses: widget.appointmentStatuses,
                teamMembers:         widget.teamMembers,
                leads:               widget.leads,
                calendars:           widget.calendars,
                businessId:          widget.businessId,
                onSaved:             widget.onSaved,
              ),
              _BlockedOffTimeTab(
                businessId: widget.businessId,
                calendars:  widget.calendars,
                onSaved:    widget.onSaved,
              ),
            ],
          )),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  APPOINTMENT FORM TAB
// ══════════════════════════════════════════════════════════════════════════════

class _AppointmentFormTab extends StatefulWidget {
  final List<String> appointmentTypes;
  final List<String> appointmentStatuses;
  final List<Map<String, dynamic>> teamMembers;
  final List<Map<String, dynamic>> leads;
  final List<Map<String, dynamic>> calendars;
  final int? businessId;
  final VoidCallback onSaved;

  const _AppointmentFormTab({
    required this.appointmentTypes,
    required this.appointmentStatuses,
    required this.teamMembers,
    required this.leads,
    required this.calendars,
    required this.businessId,
    required this.onSaved,
  });

  @override
  State<_AppointmentFormTab> createState() => _AppointmentFormTabState();
}

class _AppointmentFormTabState extends State<_AppointmentFormTab> {
  final _db           = Supabase.instance.client;
  final _titleCtrl    = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _notesCtrl    = TextEditingController();
  final _phoneCtrl    = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _contactCtrl  = TextEditingController();

  String?  _calendarId;
  String   _type       = 'Consultation';
  String   _status     = 'New';
  String?  _teamMember;
  DateTime _startDt    = DateTime.now().add(const Duration(hours: 1));
  DateTime _endDt      = DateTime.now().add(const Duration(hours: 2));
  bool     _saving     = false;
  String?  _error;

  // Contact dropdown state
  List<Map<String, dynamic>> _filteredLeads = [];
  bool    _showDropdown    = false;
  String? _selectedLeadId;

  @override
  void initState() {
    super.initState();
    _filteredLeads = widget.leads;
    if (widget.calendars.isNotEmpty) {
      _calendarId = widget.calendars.first['id'].toString();
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    _notesCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _contactCtrl.dispose();
    super.dispose();
  }

  void _filterContacts(String q) {
    setState(() {
      _showDropdown  = true;
      _filteredLeads = q.isEmpty
          ? widget.leads
          : widget.leads.where((l) {
              final n = (l['lead_name']  ?? '').toString().toLowerCase();
              final e = (l['lead_email'] ?? '').toString().toLowerCase();
              final p = (l['lead_phone'] ?? '').toString().toLowerCase();
              final query = q.toLowerCase();
              return n.contains(query) || e.contains(query) || p.contains(query);
            }).toList();
    });
  }

  void _selectLead(Map<String, dynamic> lead) {
    setState(() {
      _selectedLeadId   = lead['id']?.toString();
      _contactCtrl.text = lead['lead_name']  ?? '';
      _phoneCtrl.text   = lead['lead_phone'] ?? '';
      _emailCtrl.text   = lead['lead_email'] ?? '';
      _showDropdown     = false;
    });
  }

  Future<void> _pickDateTime(bool isStart) async {
    final date = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDt : _endDt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate:  DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(isStart ? _startDt : _endDt),
    );
    if (time == null || !mounted) return;
    final result = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _startDt = result;
        if (_endDt.isBefore(_startDt)) _endDt = _startDt.add(const Duration(hours: 1));
      } else {
        _endDt = result;
      }
    });
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Appointment title is required');
      return;
    }
    if (_endDt.isBefore(_startDt)) {
      setState(() => _error = 'End time must be after start time');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final userId = _db.auth.currentUser?.id;
      final payload = {
        'appointment_name': _titleCtrl.text.trim(),
        'appointment_type': _type,
        'status':           _status,
        'start_date_time':  _startDt.toIso8601String(),
        'end_date_time':    _endDt.toIso8601String(),
        'location':         _locationCtrl.text.trim(),
        'lead_name':        _contactCtrl.text.trim(),
        'lead_phone':       _phoneCtrl.text.trim(),
        'lead_email':       _emailCtrl.text.trim(),
        'notes':            _notesCtrl.text.trim(),
        'business_id':      widget.businessId,
        'user_id':          userId,
        'confirmation_sent': false,
        'is_recurring':     false,
        if (_calendarId != null) 'calendar_id': int.tryParse(_calendarId!),
        if (_teamMember != null) 'assigned_to':  _teamMember,
      };
      final newAppt = await _db.from('appointments').insert(payload).select().maybeSingle();
      try {
        await http.post(
          Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/run-automation'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'trigger_type': 'appointment_booked',
            'business_id':  widget.businessId,
            'payload': {
              'appointment_id':   newAppt?['id'],
              'appointment_name': _titleCtrl.text.trim(),
              'lead_name':        _contactCtrl.text.trim(),
              'lead_id':          _selectedLeadId,
              'phone':            _phoneCtrl.text.trim(),
              'email':            _emailCtrl.text.trim(),
            },
          }),
        );
      } catch (e) {
        debugPrint('Automation error: $e');
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
    // Calendar dropdown items
    final calItems = widget.calendars.isEmpty
        ? ['No calendars']
        : widget.calendars.map((c) => c['name']?.toString() ?? 'Unnamed').toList();
    final calValue = widget.calendars.isEmpty
        ? 'No calendars'
        : (widget.calendars.firstWhere(
              (c) => c['id'].toString() == _calendarId,
              orElse: () => widget.calendars.first,
            )['name']?.toString() ?? 'Unnamed');

    // Team member dropdown items
    final memberItems = [
      'Calendar Default',
      ...widget.teamMembers.map((m) => m['full_name']?.toString() ?? 'Unknown'),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Calendar
        _label('Calendar'),
        const SizedBox(height: 4),
        _dropdownWidget(
          items: calItems,
          value: calValue,
          onChanged: (v) {
            if (v == null || widget.calendars.isEmpty) return;
            final match = widget.calendars.firstWhere(
                (c) => c['name'] == v, orElse: () => widget.calendars.first);
            setState(() => _calendarId = match['id'].toString());
          },
        ),
        const SizedBox(height: 14),

        // Appointment Title
        _label('Appointment Title'),
        const SizedBox(height: 4),
        _textField(_titleCtrl, hint: 'e.g. Initial Consultation'),
        const SizedBox(height: 14),

        // Type + Status
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _label('Type'),
            const SizedBox(height: 4),
            _dropdownWidget(
              items: widget.appointmentTypes,
              value: _type,
              onChanged: (v) => setState(() => _type = v!),
            ),
          ])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _label('Status'),
            const SizedBox(height: 4),
            _dropdownWidget(
              items: widget.appointmentStatuses,
              value: _status,
              onChanged: (v) => setState(() => _status = v!),
            ),
          ])),
        ]),
        const SizedBox(height: 14),

        // Team Member
        _label('Team Member'),
        const SizedBox(height: 4),
        _dropdownWidget(
          items: memberItems,
          value: _teamMember ?? 'Calendar Default',
          onChanged: (v) => setState(() => _teamMember = (v == 'Calendar Default') ? null : v),
        ),
        const SizedBox(height: 14),

        // Start / End
        Row(children: [
          Expanded(child: _DateTimePickerField(label: 'Start', value: _startDt, onTap: () => _pickDateTime(true))),
          const SizedBox(width: 12),
          Expanded(child: _DateTimePickerField(label: 'End',   value: _endDt,   onTap: () => _pickDateTime(false))),
        ]),
        const SizedBox(height: 14),

        // Location
        _label('Location'),
        const SizedBox(height: 4),
        _textField(_locationCtrl, hint: 'Office, Zoom, Phone...'),
        const SizedBox(height: 16),

        // Contact Info heading
        const Text('Contact Info',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const SizedBox(height: 8),

        // Contact Name — dropdown with manual entry fallback
        _label('Contact Name'),
        const SizedBox(height: 4),
        TextField(
  controller: _contactCtrl,
  onChanged: _filterContacts,
  onTap: () => setState(() {
    _showDropdown  = true;
    _filteredLeads = widget.leads;
  }),
  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
  decoration: InputDecoration(
    hintText: 'Search or type a name',
    hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
    filled: true,
    fillColor: AppTheme.pageBg,
    suffixIcon: const Icon(Icons.arrow_drop_down, color: AppTheme.textSecondary),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border:        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
  ),
),
if (_showDropdown) ...[
  const SizedBox(height: 4),
  Container(
    constraints: const BoxConstraints(maxHeight: 200),
    decoration: BoxDecoration(
      color: AppTheme.cardBg,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppTheme.borderColor),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, 2))],
    ),
    child: SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        onTap: () => setState(() {
          _showDropdown   = false;
          _selectedLeadId = null;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.borderColor.withValues(alpha: 0.5))),
          ),
          child: Row(children: [
            const Icon(Icons.edit_outlined, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            const Text('Enter manually',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
          ]),
        ),
      ),
      if (_filteredLeads.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No contacts found',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        )
      else
        Flexible(child: ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: _filteredLeads.length,
          itemBuilder: (_, i) {
            final lead     = _filteredLeads[i];
            final name     = lead['lead_name']?.toString() ?? '';
            final initial  = name.isNotEmpty ? name[0].toUpperCase() : '?';
            final subtitle = [lead['lead_email'], lead['lead_phone']]
                .where((v) => (v ?? '').isNotEmpty).join(' · ');
            return InkWell(
              onTap: () => _selectLead(lead),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.borderColor.withValues(alpha: 0.4))),
                ),
                child: Row(children: [
                  Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Text(initial, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.brand)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name.isNotEmpty ? name : 'Unknown',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
                    if (subtitle.isNotEmpty)
                      Text(subtitle, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ])),
                ]),
              ),
            );
          },
        )),
    ]),
  )),
],
        const SizedBox(height: 8),

        // Phone + Email (auto-populated or manual)
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _label('Phone'),
            const SizedBox(height: 4),
            _textField(_phoneCtrl, hint: '555-0100', keyboard: TextInputType.phone),
          ])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _label('Email'),
            const SizedBox(height: 4),
            _textField(_emailCtrl, hint: 'jane@example.com', keyboard: TextInputType.emailAddress),
          ])),
        ]),
        const SizedBox(height: 8),

        // Notes
        _label('Notes'),
        const SizedBox(height: 4),
        _textField(_notesCtrl, hint: 'Any notes...', maxLines: 3),

        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(fontSize: 13, color: AppTheme.error)),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity, height: 44,
          child: ElevatedButton(
            onPressed: _saving ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Book Appointment', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary));

  Widget _textField(TextEditingController ctrl, {String? hint, TextInputType? keyboard, int maxLines = 1}) {
    return TextField(
      controller: ctrl, keyboardType: keyboard, maxLines: maxLines,
      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        filled: true, fillColor: AppTheme.pageBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border:        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
      ),
    );
  }

  Widget _dropdownWidget({required List<String> items, required String value, required ValueChanged<String?> onChanged}) {
    final safeValue = items.contains(value) ? value : items.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(
        value: safeValue, isExpanded: true, dropdownColor: AppTheme.cardBg,
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        items: items.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
        onChanged: onChanged,
      )),
    );
  }
}
// ═══════════════ END OF PART 3 — continue with appt_part4.dart ═══════════════
// ═══════════════ PART 4 OF 4 — paste directly after Part 3 ═══════════════

// ══════════════════════════════════════════════════════════════════════════════
//  BLOCKED OFF TIME TAB
// ══════════════════════════════════════════════════════════════════════════════

class _BlockedOffTimeTab extends StatefulWidget {
  final int? businessId;
  final List<Map<String, dynamic>> calendars;
  final VoidCallback onSaved;

  const _BlockedOffTimeTab({
    required this.businessId,
    required this.calendars,
    required this.onSaved,
  });

  @override
  State<_BlockedOffTimeTab> createState() => _BlockedOffTimeTabState();
}

class _BlockedOffTimeTabState extends State<_BlockedOffTimeTab> {
  final _titleCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  String?  _calendarId;
  bool     _isRecurring = false;
  bool     _saving      = false;
  String?  _error;

  // One-time fields
  DateTime _startDt = DateTime.now().add(const Duration(hours: 1));
  DateTime _endDt   = DateTime.now().add(const Duration(hours: 2));
  bool     _allDay  = false;

  // Recurring fields — one row per day exactly like Calendar Settings
 // Each day holds a list of time block maps: {'start': '09:00', 'end': '17:00'}
  Map<String, List<Map<String, String>>> _recurringDays = {
    'monday':    [],
    'tuesday':   [],
    'wednesday': [],
    'thursday':  [],
    'friday':    [],
    'saturday':  [],
    'sunday':    [],
  };

  static const _days      = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
  static const _dayLabels = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];

  List<String> get _timeValues => List.generate(48, (i) {
    final h = i ~/ 2;
    final m = i % 2 == 0 ? '00' : '30';
    return '${h.toString().padLeft(2, '0')}:$m';
  });

  List<String> get _timeLabels => List.generate(48, (i) {
    final h    = i ~/ 2;
    final m    = i % 2 == 0 ? '00' : '30';
    final hour = h == 0 ? 12 : h > 12 ? h - 12 : h;
    return '${hour.toString().padLeft(2, '0')}:$m ${h < 12 ? 'AM' : 'PM'}';
  });

  @override
  void initState() {
    super.initState();
    if (widget.calendars.isNotEmpty) {
      _calendarId = widget.calendars.first['id'].toString();
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime(bool isStart) async {
    final date = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDt : _endDt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate:  DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    if (_allDay) {
      setState(() {
        if (isStart) _startDt = DateTime(date.year, date.month, date.day, 0, 0);
        else         _endDt   = DateTime(date.year, date.month, date.day, 23, 59);
        if (_endDt.isBefore(_startDt)) _endDt = _startDt;
      });
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(isStart ? _startDt : _endDt),
    );
    if (time == null || !mounted) return;
    final result = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _startDt = result;
        if (_endDt.isBefore(_startDt)) _endDt = _startDt.add(const Duration(hours: 1));
      } else {
        _endDt = result;
      }
    });
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Title is required');
      return;
    }
    if (_isRecurring) {
      final anyEnabled = _recurringDays.values.any((blocks) => blocks.isNotEmpty);
      if (!anyEnabled) {
        setState(() => _error = 'Select at least one day and add a time block');
        return;
      }
    }
    setState(() { _saving = true; _error = null; });
    try {
      final db     = Supabase.instance.client;
      final userId = db.auth.currentUser?.id;

      if (_isRecurring) {
        // Insert one block per enabled day for the next 8 weeks
        final now  = DateTime.now();
        final rows = <Map<String, dynamic>>[];

        for (int week = 0; week < 8; week++) {
          for (int di = 0; di < _days.length; di++) {
            final day    = _days[di];
            final blocks = _recurringDays[day]!;
            if (blocks.isEmpty) continue;

            final targetWeekday = di + 1;
            final daysFromNow   = (targetWeekday - now.weekday + 7) % 7;
            final firstDate     = now.add(Duration(days: daysFromNow));
            final date          = firstDate.add(Duration(days: week * 7));

            for (final block in blocks) {
              final startParts = block['start']!.split(':');
              final endParts   = block['end']!.split(':');
              final startDt    = DateTime(date.year, date.month, date.day,
                  int.parse(startParts[0]), int.parse(startParts[1]));
              final endDt      = DateTime(date.year, date.month, date.day,
                  int.parse(endParts[0]),   int.parse(endParts[1]));

              rows.add({
                'appointment_name':  _titleCtrl.text.trim(),
                'appointment_type':  'Blocked',
                'status':            'Blocked',
                'start_date_time':   startDt.toIso8601String(),
                'end_date_time':     endDt.toIso8601String(),
                'notes':             _notesCtrl.text.trim(),
                'business_id':       widget.businessId,
                'user_id':           userId,
                'confirmation_sent': false,
                'is_recurring':      true,
                'recurrence_days':   jsonEncode(_recurringDays),
                if (_calendarId != null) 'calendar_id': int.tryParse(_calendarId!),
              });
            }
          }
        }
        if (rows.isNotEmpty) await db.from('appointments').insert(rows);
      } else {
        // One-time block
        final startDt = _allDay
            ? DateTime(_startDt.year, _startDt.month, _startDt.day,  0,  0)
            : _startDt;
        final endDt = _allDay
            ? DateTime(_endDt.year,   _endDt.month,   _endDt.day,   23, 59)
            : _endDt;
        await db.from('appointments').insert({
          'appointment_name':  _titleCtrl.text.trim(),
          'appointment_type':  'Blocked',
          'status':            'Blocked',
          'start_date_time':   startDt.toIso8601String(),
          'end_date_time':     endDt.toIso8601String(),
          'notes':             _notesCtrl.text.trim(),
          'business_id':       widget.businessId,
          'user_id':           userId,
          'confirmation_sent': false,
          'is_recurring':      false,
          if (_calendarId != null) 'calendar_id': int.tryParse(_calendarId!),
        });
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
    final calItems = widget.calendars.isEmpty
        ? ['No calendars']
        : widget.calendars.map((c) => c['name']?.toString() ?? 'Unnamed').toList();
    final calValue = widget.calendars.isEmpty
        ? 'No calendars'
        : (widget.calendars.firstWhere(
              (c) => c['id'].toString() == _calendarId,
              orElse: () => widget.calendars.first,
            )['name']?.toString() ?? 'Unnamed');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Calendar
        _label('Calendar'),
        const SizedBox(height: 4),
        _dropdownWidget(items: calItems, value: calValue, onChanged: (v) {
          if (v == null || widget.calendars.isEmpty) return;
          final match = widget.calendars.firstWhere(
              (c) => c['name'] == v, orElse: () => widget.calendars.first);
          setState(() => _calendarId = match['id'].toString());
        }),
        const SizedBox(height: 14),

        // Title
        _label('Title'),
        const SizedBox(height: 4),
        TextField(
          controller: _titleCtrl,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          decoration: _inputDecor(hint: 'e.g. Lunch break, Team meeting...'),
        ),
        const SizedBox(height: 14),

        // One-Time / Recurring toggle
        Row(children: [
          Expanded(child: Clickable(
            onTap: () => setState(() => _isRecurring = false),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: !_isRecurring ? AppTheme.brand : AppTheme.pageBg,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
                border: Border.all(color: !_isRecurring ? AppTheme.brand : AppTheme.borderColor),
              ),
              alignment: Alignment.center,
              child: Text('One-Time', style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500,
                  color: !_isRecurring ? Colors.white : AppTheme.textSecondary)),
            ),
          )),
          Expanded(child: Clickable(
            onTap: () => setState(() => _isRecurring = true),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: _isRecurring ? AppTheme.brand : AppTheme.pageBg,
                borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
                border: Border.all(color: _isRecurring ? AppTheme.brand : AppTheme.borderColor),
              ),
              alignment: Alignment.center,
              child: Text('Recurring', style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500,
                  color: _isRecurring ? Colors.white : AppTheme.textSecondary)),
            ),
          )),
        ]),
        const SizedBox(height: 16),

        // ── ONE-TIME ──────────────────────────────────────────────────────
        if (!_isRecurring) ...[
          Row(children: [
            Switch(value: _allDay, onChanged: (v) => setState(() => _allDay = v), activeColor: AppTheme.brand),
            const SizedBox(width: 8),
            const Text('All day', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _DateTimePickerField(label: 'Start', value: _startDt, onTap: () => _pickDateTime(true))),
            const SizedBox(width: 12),
            Expanded(child: _DateTimePickerField(label: 'End',   value: _endDt,   onTap: () => _pickDateTime(false))),
          ]),
        ],

        // ── RECURRING ─────────────────────────────────────────────────────
        if (_isRecurring) ...[
          const Text('Select which days and time blocks to repeat each week:',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 10),
          ...List.generate(_days.length, (i) {
            final day    = _days[i];
            final label  = _dayLabels[i];
            final blocks = _recurringDays[day]!;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: blocks.isNotEmpty ? AppTheme.error.withValues(alpha: 0.03) : AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: blocks.isNotEmpty
                      ? AppTheme.error.withValues(alpha: 0.25)
                      : AppTheme.borderColor.withValues(alpha: 0.5),
                ),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Day header row
                Row(children: [
                  SizedBox(width: 110, child: Text(label,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary))),
                  const Spacer(),
                  Clickable(
                    onTap: () => setState(() {
                      _recurringDays[day]!.add({'start': '09:00', 'end': '10:00'});
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.add, size: 12, color: AppTheme.error),
                        SizedBox(width: 4),
                        Text('Add block', style: TextStyle(fontSize: 11, color: AppTheme.error, fontWeight: FontWeight.w500)),
                      ]),
                    ),
                  ),
                ]),
                // Block rows
                if (blocks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('No blocks — tap Add block to block time on this day',
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  )
                else
                  ...blocks.asMap().entries.map((entry) {
                    final idx   = entry.key;
                    final block = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(children: [
                        const Icon(Icons.block, size: 12, color: AppTheme.error),
                        const SizedBox(width: 6),
                        Expanded(child: _timeDropdownWidget(
                          value: block['start']!,
                          onChanged: (v) => setState(() => _recurringDays[day]![idx]['start'] = v!),
                        )),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('to', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                        ),
                        Expanded(child: _timeDropdownWidget(
                          value: block['end']!,
                          onChanged: (v) => setState(() => _recurringDays[day]![idx]['end'] = v!),
                        )),
                        const SizedBox(width: 8),
                        Clickable(
                          onTap: () => setState(() => _recurringDays[day]!.removeAt(idx)),
                          child: const Icon(Icons.close, size: 14, color: AppTheme.error),
                        ),
                      ]),
                    );
                  }),
              ]),
            );
          }),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline, size: 14, color: AppTheme.brand),
              SizedBox(width: 8),
              Expanded(child: Text('Recurring blocks are created for the next 8 weeks.',
                  style: TextStyle(fontSize: 11, color: AppTheme.brand))),
            ]),
          ),
        ],

        const SizedBox(height: 14),
        _label('Reason (optional)'),
        const SizedBox(height: 4),
        TextField(
          controller: _notesCtrl,
          maxLines: 2,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          decoration: _inputDecor(hint: 'e.g. Lunch, Team meeting, Holiday...'),
        ),

        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(fontSize: 13, color: AppTheme.error)),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity, height: 44,
          child: ElevatedButton(
            onPressed: _saving ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Block Time', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary));

  InputDecoration _inputDecor({String? hint}) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
    filled: true, fillColor: AppTheme.pageBg,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border:        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
  );

  Widget _dropdownWidget({required List<String> items, required String value, required ValueChanged<String?> onChanged}) {
    final safeValue = items.contains(value) ? value : items.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(
        value: safeValue, isExpanded: true, dropdownColor: AppTheme.cardBg,
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        items: items.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
        onChanged: onChanged,
      )),
    );
  }

  Widget _timeDropdownWidget({required String value, required ValueChanged<String?> onChanged}) {
    final vals      = _timeValues;
    final lbls      = _timeLabels;
    final safeValue = vals.contains(value) ? value : vals.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.borderColor)),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(
        value: safeValue, isExpanded: true, dropdownColor: AppTheme.cardBg,
        style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
        items: List.generate(vals.length, (i) => DropdownMenuItem(value: vals[i], child: Text(lbls[i]))),
        onChanged: onChanged,
      )),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  SHARED WIDGETS
// ══════════════════════════════════════════════════════════════════════════════

class _MiniStat extends StatelessWidget {
  final String label, value;
  final Color color;
  const _MiniStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]),
    ));
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  final Color Function(String) colorFn;
  const _StatusBadge({required this.status, required this.colorFn});

  @override
  Widget build(BuildContext context) {
    final color = colorFn(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color)),
    );
  }
}

class _DateTimePickerField extends StatelessWidget {
  final String label;
  final DateTime value;
  final VoidCallback onTap;
  const _DateTimePickerField({required this.label, required this.value, required this.onTap});

  String _format(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day} · $h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
      const SizedBox(height: 4),
      Clickable(onTap: onTap, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(children: [
          const Icon(Icons.access_time, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Expanded(child: Text(_format(value), style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
        ]),
      )),
    ]);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  APPOINTMENT DETAIL SHEET
// ══════════════════════════════════════════════════════════════════════════════

class _AppointmentDetailSheet extends StatefulWidget {
  final Map<String, dynamic> appointment;
  final VoidCallback onUpdated;
  final List<String> appointmentStatuses;
  final Color Function(String) colorFn;

  const _AppointmentDetailSheet({
    required this.appointment,
    required this.onUpdated,
    required this.appointmentStatuses,
    required this.colorFn,
  });

  @override
  State<_AppointmentDetailSheet> createState() => _AppointmentDetailSheetState();
}

class _AppointmentDetailSheetState extends State<_AppointmentDetailSheet> {
  final _db = Supabase.instance.client;
  late String _status;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _status = widget.appointment['status'] ?? 'New';
    if (!widget.appointmentStatuses.contains(_status)) {
      _status = widget.appointmentStatuses.first;
    }
  }

  Future<void> _updateStatus(String s) async {
    setState(() { _saving = true; _status = s; });
    try {
      await _db.from('appointments').update({'status': s}).eq('id', widget.appointment['id']);
    } catch (e) {
      debugPrint('Update error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Appointment'),
        content: const Text('Are you sure you want to delete this appointment?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
              child: const Text('Delete', style: TextStyle(color: AppTheme.error))),
        ],
      ),
    );
    if (confirm != true) return;
    await _db.from('appointments').delete().eq('id', widget.appointment['id']);
    widget.onUpdated();
  }

  String _fmtTime(DateTime dt) {
    final local = dt.isUtc ? dt.toLocal() : dt;
    final h = local.hour == 0 ? 12 : local.hour > 12 ? local.hour - 12 : local.hour;
    return '$h:${local.minute.toString().padLeft(2, '0')} ${local.hour < 12 ? 'AM' : 'PM'}';
  }

  String _fmtFullDate(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days   = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final a       = widget.appointment;
    final startDtRaw = DateTime.tryParse(a['start_date_time'] ?? '') ?? DateTime.now();
    final endDtRaw   = DateTime.tryParse(a['end_date_time']   ?? '') ?? DateTime.now();
    final startDt = startDtRaw.isUtc ? startDtRaw.toLocal() : startDtRaw;
    final endDt   = endDtRaw.isUtc   ? endDtRaw.toLocal()   : endDtRaw;
    final blocked = (a['appointment_type'] ?? '').toString().toLowerCase() == 'blocked' ||
                    (a['status'] ?? '').toString().toLowerCase() == 'blocked';

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4,
            decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 20),

        // Title row
        Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              color: blocked
                  ? const Color(0xFF94a3b8).withValues(alpha: 0.15)
                  : AppTheme.brand.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(
              blocked ? Icons.block : Icons.calendar_today,
              color: blocked ? const Color(0xFF94a3b8) : AppTheme.brand,
              size: 22,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a['appointment_name'] ?? 'Untitled',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
            Text(a['appointment_type'] ?? '—',
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ])),
          IconButton(onPressed: _delete,
              icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.error)),
        ]),
        const SizedBox(height: 20),

        // Date/time block
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.brand.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.brand.withValues(alpha: 0.15)),
          ),
          child: Row(children: [
            const Icon(Icons.access_time, size: 16, color: AppTheme.brand),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_fmtFullDate(startDt),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
              Text('${_fmtTime(startDt)} – ${_fmtTime(endDt)}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          ]),
        ),
        const SizedBox(height: 12),

        // Detail rows
        if ((a['location']   ?? '').isNotEmpty) _row(Icons.location_on_outlined, a['location']),
        if (!blocked) ...[
          _row(Icons.person_outline, a['lead_name'] ?? '—'),
          if ((a['lead_phone'] ?? '').isNotEmpty) _row(Icons.phone_outlined,  a['lead_phone']),
          if ((a['lead_email'] ?? '').isNotEmpty) _row(Icons.email_outlined,  a['lead_email']),
        ],
        if ((a['notes'] ?? '').isNotEmpty) _row(Icons.notes_outlined, a['notes']),

        // Status chips — only for real appointments, not blocked time
        if (!blocked) ...[
          const SizedBox(height: 20),
          const Text('Update Status',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: widget.appointmentStatuses.map((s) {
            final sel = s == _status;
            return Clickable(
              onTap: () => _updateStatus(s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: sel ? AppTheme.brand : AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: sel ? AppTheme.brand : AppTheme.borderColor),
                ),
                child: Text(s, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                    color: sel ? Colors.white : AppTheme.textSecondary)),
              ),
            );
          }).toList()),
        ],

        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity, height: 44,
          child: ElevatedButton(
            onPressed: widget.onUpdated,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Done', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ])),
    );
  }

  Widget _row(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
      ]),
    );
  }
}
// ════════════════════════════ END OF PART 4 ════════════════════════════════
// Assemble final file: Part1 + Part2 + Part3 + Part4
// Remove all comment lines starting with // ═══ before saving