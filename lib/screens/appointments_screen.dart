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
  int? _businessId;
  Map<String, dynamic>? _business;
  String _ownerName = '';

  String _calView = 'week';
  DateTime _focusDate = DateTime.now();

  String _statusFilter = 'All';
  final _statuses = ['All', 'New', 'Confirmed', 'Showed', 'No-Show', 'Cancelled', 'Invalid', 'Rescheduled'];

  bool _savingSettings = false;
  int _slotDuration = 60; // -1 = custom
  int _customDurationMinutes = 45;
  Map<String, Map<String, dynamic>> _availability = {
    'monday':    {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'tuesday':   {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'wednesday': {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'thursday':  {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'friday':    {'enabled': true,  'start': '09:00', 'end': '17:00', 'blocks': []},
    'saturday':  {'enabled': false, 'start': '09:00', 'end': '17:00', 'blocks': []},
    'sunday':    {'enabled': false, 'start': '09:00', 'end': '17:00', 'blocks': []},
  };

  // Right panel
  int _panelTab = 0;
  final _usersSearchCtrl     = TextEditingController();
  final _calendarsSearchCtrl = TextEditingController();
  final _groupsSearchCtrl    = TextEditingController();

  // GHL-style appointment types
  static const _appointmentTypes = [
    'Consultation',
    'Discovery Call',
    'Demo',
    'Strategy Session',
    'Follow-Up',
    'Check-In',
    'Onboarding',
    'Renewal',
    'Support Call',
    'Sales Call',
    'Service Appointment',
    'In-Person Meeting',
    'Virtual Meeting',
    'Round Robin',
    'Class / Event',
    'Collective Meeting',
    'Internal Meeting',
    'Interview',
    'Training',
    'Other',
  ];

  // GHL-style statuses
  static const _appointmentStatuses = [
    'New',
    'Confirmed',
    'Showed',
    'No-Show',
    'Cancelled',
    'Invalid',
    'Rescheduled',
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
      _ownerName  = 'Owner';
      if (_businessId == null) return;

      final results = await Future.wait([
        _db.from('appointments').select().eq('business_id', _businessId!).order('start_date_time', ascending: true),
        _db.from('businesses').select('availability_hours, slot_duration_minutes').eq('id', _businessId!).maybeSingle(),
      ]);

      _appointments = List<Map<String, dynamic>>.from(results[0] as List);
      _business     = results[1] as Map<String, dynamic>?;

      if (_business != null) {
        _slotDuration = _business!['slot_duration_minutes'] as int? ?? 60;
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

  Future<void> _saveSettings() async {
    if (_businessId == null) return;
    setState(() => _savingSettings = true);
    try {
      final effectiveDuration = _slotDuration == -1 ? _customDurationMinutes : _slotDuration;
      await _db.from('businesses').update({
        'availability_hours':    _availability,
        'slot_duration_minutes': effectiveDuration,
      }).eq('id', _businessId!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Calendar settings saved'),
          backgroundColor: Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      debugPrint('Save settings error: $e');
    } finally {
      if (mounted) setState(() => _savingSettings = false);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Returns the hour range to display (based on enabled availability hours)
  ({int startHour, int endHour}) _visibleHourRange() {
    // Only compute from ENABLED days. If nothing is enabled yet (first load),
    // fall back to sensible business hours so we don't show midnight–midnight.
    int? earliest;
    int? latest;
    _availability.forEach((_, v) {
      if (v['enabled'] == true) {
        final s = _parseHour(v['start'] as String);
        final e = _parseHour(v['end']   as String);
        if (earliest == null || s < earliest!) earliest = s;
        if (latest   == null || e > latest!)   latest   = e;
      }
    });
    // Fall back to 8 AM – 6 PM if no enabled days found
    final start = earliest ?? 8;
    final end   = latest   ?? 18;
    // +1 on end so the final hour's full slot is rendered (e.g. 17:00 end → show 17:00–18:00 row)
    return (startHour: start.clamp(0, 23), endHour: (end + 1).clamp(1, 24));
  }

  int _parseHour(String t) {
    final parts = t.split(':');
    return int.tryParse(parts[0]) ?? 9;
  }

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
      // legacy compat
      case 'scheduled':   return const Color(0xFF6366f1);
      case 'completed':   return AppTheme.success;
      case 'no show':     return const Color(0xFFf59e0b);
      default:            return AppTheme.textSecondary;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(
        children: [
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
                      _buildSettingsTab(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 24),
          const Text('Calendars',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(width: 32),
          Expanded(
            child: TabBar(
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
                const Tab(text: 'Calendars'),
                const Tab(text: 'Appointments'),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.settings_outlined, size: 14),
                      SizedBox(width: 6),
                      Text('Calendar Settings'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          AnimatedBuilder(
            animation: _tabController,
            builder: (_, __) {
              if (_tabController.index == 2) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(right: 16),
                child: ElevatedButton.icon(
                  onPressed: _showAddAppointment,
                  icon: const Icon(Icons.add, size: 16),
                  // FIX: removed extra "+" prefix — GHL calls it "New Appointment"
                  label: const Text('New Appointment'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 1 — CALENDARS
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildCalendarsTab() {
    return Column(
      children: [
        _buildCalendarToolbar(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (_calView == 'day')  return _buildDayView(constraints);
                    if (_calView == 'week') return _buildWeekView(constraints);
                    return _buildMonthView(constraints);
                  },
                ),
              ),
              _buildRightPanel(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCalendarToolbar() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(
        children: [
          Text(_dateRangeLabel(),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _prevPeriod,
            icon: const Icon(Icons.chevron_left, size: 18, color: AppTheme.textSecondary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            onPressed: _nextPeriod,
            icon: const Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          Clickable(
            onTap: () => setState(() => _focusDate = DateTime.now()),
            child: Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.borderColor),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('Today', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ),
          ),
          const Spacer(),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(children: [
              _calViewBtn('Day', 'day'),
              _calViewBtn('Week', 'week'),
              _calViewBtn('Month', 'month'),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _calViewBtn(String label, String val) {
    final sel = _calView == val;
    return Clickable(
      onTap: () => setState(() => _calView = val),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppTheme.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                color: sel ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  String _dateRangeLabel() {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const fullMonths = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    if (_calView == 'day') {
      return '${months[_focusDate.month - 1]} ${_focusDate.day}, ${_focusDate.year}';
    } else if (_calView == 'week') {
      final monday = _focusDate.subtract(Duration(days: _focusDate.weekday - 1));
      final sunday = monday.add(const Duration(days: 6));
      if (monday.month == sunday.month) {
        return '${months[monday.month - 1]} ${monday.day} – ${sunday.day}, ${monday.year}';
      }
      return '${months[monday.month - 1]} ${monday.day} – ${months[sunday.month - 1]} ${sunday.day}';
    } else {
      return '${fullMonths[_focusDate.month - 1]} ${_focusDate.year}';
    }
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

  // ── DAY VIEW ───────────────────────────────────────────────────────────────

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

    return SingleChildScrollView(
      child: Column(
        children: [
          // Day header
          Container(
            height: 48,
            decoration: const BoxDecoration(
              color: AppTheme.cardBg,
              border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
            ),
            child: Row(
              children: [
                const SizedBox(width: gutterWidth),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: isToday ? AppTheme.brand.withValues(alpha: 0.04) : null,
                      border: const Border(left: BorderSide(color: AppTheme.borderColor)),
                    ),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][_focusDate.weekday - 1],
                          style: TextStyle(fontSize: 11, color: isToday ? AppTheme.brand : AppTheme.textSecondary),
                        ),
                        Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(
                            color: isToday ? AppTheme.brand : null,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text('${_focusDate.day}',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                                  color: isToday ? Colors.white : AppTheme.textPrimary)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Time grid — only visible hours
          SizedBox(
            height: hourHeight * hours.length,
            child: Stack(
              children: [
                Column(
                  children: hours.map((hour) => SizedBox(
                    height: hourHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center, // FIX: center vertically
                      children: [
                        // FIX: time label centered vertically in the row
                        SizedBox(
                          width: gutterWidth,
                          child: Text(
                            _formatHour(hour),
                            textAlign: TextAlign.center, // FIX: centered horizontally too
                            style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
                          ),
                        ),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border(
                                left: const BorderSide(color: AppTheme.borderColor),
                                top: BorderSide(
                                  color: hour == hours.first ? Colors.transparent : AppTheme.borderColor,
                                ),
                              ),
                              color: isToday ? AppTheme.brand.withValues(alpha: 0.01) : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )).toList(),
                ),
                // Appointment blocks
                ...dayAppts.map((a) {
                  final start = DateTime.parse(a['start_date_time'] as String).toLocal();
                  final end   = DateTime.parse(a['end_date_time']   as String).toLocal();
                  final offsetHours = start.hour + start.minute / 60.0 - range.startHour;
                  if (offsetHours < 0) return const SizedBox.shrink();
                  final top    = offsetHours * hourHeight;
                  final height = ((end.difference(start).inMinutes) / 60.0) * hourHeight;
                  return Positioned(
                    top: top, left: gutterWidth + 4, right: 4,
                    height: height.clamp(20.0, double.infinity),
                    child: Clickable(
                      onTap: () => _showAppointmentDetail(a),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _statusColor(a['status'] ?? '').withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(a['appointment_name'] ?? '',
                              style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                          if ((a['lead_name'] ?? '').isNotEmpty)
                            Text(a['lead_name'], style: const TextStyle(fontSize: 10, color: Colors.white70)),
                        ]),
                      ),
                    ),
                  );
                }),
                // Current time red line
                if (isToday && now.hour >= range.startHour && now.hour < range.endHour)
                  Positioned(
                    top: (now.hour + now.minute / 60.0 - range.startHour) * hourHeight - 1,
                    left: gutterWidth,
                    right: 0,
                    child: Row(children: [
                      Container(width: 8, height: 8,
                          decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                      Expanded(child: Container(height: 1.5, color: Colors.red)),
                    ]),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── WEEK VIEW ──────────────────────────────────────────────────────────────

  Widget _buildWeekView(BoxConstraints constraints) {
    const double hourHeight  = 60.0;
    const double gutterWidth = 48.0;
    final monday   = _focusDate.subtract(Duration(days: _focusDate.weekday - 1));
    final days     = List.generate(7, (i) => monday.add(Duration(days: i)));
    final now      = DateTime.now();
    final colWidth = (constraints.maxWidth - gutterWidth) / 7;
    final range    = _visibleHourRange();
    final hours    = List.generate(range.endHour - range.startHour, (i) => range.startHour + i);

    return SingleChildScrollView(
      child: Column(
        children: [
          // Day headers
          SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: gutterWidth),
                ...days.map((d) {
                  final isToday = DateUtils.isSameDay(d, now);
                  return SizedBox(
                    width: colWidth,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isToday ? AppTheme.brand.withValues(alpha: 0.04) : AppTheme.cardBg,
                        border: const Border(
                          left: BorderSide(color: AppTheme.borderColor),
                          bottom: BorderSide(color: AppTheme.borderColor),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][d.weekday - 1],
                              style: TextStyle(fontSize: 11, color: isToday ? AppTheme.brand : AppTheme.textSecondary)),
                          const SizedBox(height: 2),
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                              color: isToday ? AppTheme.brand : null,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Text('${d.day}',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                                    color: isToday ? Colors.white : AppTheme.textPrimary)),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          // Time grid — only visible hours
          SizedBox(
            height: hourHeight * hours.length,
            child: Stack(
              children: [
                Column(
                  children: hours.map((hour) => SizedBox(
                    height: hourHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center, // FIX: centered
                      children: [
                        SizedBox(
                          width: gutterWidth,
                          child: Text(
                            _formatHour(hour),
                            textAlign: TextAlign.center, // FIX: centered
                            style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
                          ),
                        ),
                        ...days.map((d) => SizedBox(
                          width: colWidth,
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border(
                                left: const BorderSide(color: AppTheme.borderColor),
                                top: BorderSide(
                                  color: hour == hours.first ? Colors.transparent : AppTheme.borderColor,
                                ),
                              ),
                              color: DateUtils.isSameDay(d, now)
                                  ? AppTheme.brand.withValues(alpha: 0.02)
                                  : null,
                            ),
                          ),
                        )),
                      ],
                    ),
                  )).toList(),
                ),
                // Appointment blocks
                ..._appointments.where((a) {
                  final dt = DateTime.tryParse(a['start_date_time'] ?? '')?.toLocal();
                  return dt != null && days.any((d) => DateUtils.isSameDay(d, dt));
                }).map((a) {
                  final start    = DateTime.parse(a['start_date_time'] as String).toLocal();
                  final end      = DateTime.parse(a['end_date_time']   as String).toLocal();
                  final dayIndex = days.indexWhere((d) => DateUtils.isSameDay(d, start));
                  if (dayIndex < 0) return const SizedBox.shrink();
                  final offsetHours = start.hour + start.minute / 60.0 - range.startHour;
                  if (offsetHours < 0) return const SizedBox.shrink();
                  final top    = offsetHours * hourHeight;
                  final height = ((end.difference(start).inMinutes) / 60.0) * hourHeight;
                  final left   = gutterWidth + dayIndex * colWidth + 2;
                  return Positioned(
                    top: top, left: left, width: colWidth - 4,
                    height: height.clamp(20.0, double.infinity),
                    child: Clickable(
                      onTap: () => _showAppointmentDetail(a),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: _statusColor(a['status'] ?? '').withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(a['appointment_name'] ?? '',
                            style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  );
                }),
                // Current time red line
                if (days.any((d) => DateUtils.isSameDay(d, now)) &&
                    now.hour >= range.startHour && now.hour < range.endHour)
                  Positioned(
                    top: (now.hour + now.minute / 60.0 - range.startHour) * hourHeight - 1,
                    left: gutterWidth,
                    right: 0,
                    child: Row(children: [
                      Container(width: 8, height: 8,
                          decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                      Expanded(child: Container(height: 1.5, color: Colors.red)),
                    ]),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── MONTH VIEW ─────────────────────────────────────────────────────────────

  Widget _buildMonthView(BoxConstraints constraints) {
    final firstDay    = DateTime(_focusDate.year, _focusDate.month, 1);
    final daysInMonth = DateUtils.getDaysInMonth(_focusDate.year, _focusDate.month);
    final startOffset = firstDay.weekday % 7;
    final totalCells  = startOffset + daysInMonth;
    final rowCount    = (totalCells / 7).ceil();
    final now         = DateTime.now();
    final cellHeight  = (constraints.maxHeight - 36.0 - 8.0) / rowCount;

    return Column(
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'].map((d) => Expanded(
              child: Container(
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppTheme.cardBg,
                  border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
                ),
                child: Text(d, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
              ),
            )).toList(),
          ),
        ),
        ...List.generate(rowCount, (row) => SizedBox(
          height: cellHeight,
          child: Row(
            children: List.generate(7, (col) {
              final cellIndex = row * 7 + col;
              final dayNum    = cellIndex - startOffset + 1;
              if (dayNum < 1 || dayNum > daysInMonth) {
                return Expanded(child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.3)),
                    color: AppTheme.pageBg.withValues(alpha: 0.3),
                  ),
                ));
              }
              final date     = DateTime(_focusDate.year, _focusDate.month, dayNum);
              final isToday  = DateUtils.isSameDay(date, now);
              final dayAppts = _appointments.where((a) {
              final dt = DateTime.tryParse(a['start_date_time'] ?? '')?.toLocal();
                return dt != null && DateUtils.isSameDay(dt, date);
              }).toList();

              return Expanded(
                child: Clickable(
                  onTap: () {
                    if (dayAppts.isNotEmpty) {
                      _showDaySheet(date, dayAppts);
                    } else {
                      setState(() { _focusDate = date; _calView = 'day'; });
                    }
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: isToday ? AppTheme.brand.withValues(alpha: 0.04) : AppTheme.cardBg,
                      border: Border.all(color: AppTheme.borderColor.withValues(alpha: 0.5)),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 24, height: 24,
                          decoration: BoxDecoration(
                            color: isToday ? AppTheme.brand : null,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text('$dayNum',
                              style: TextStyle(fontSize: 12,
                                  fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                                  color: isToday ? Colors.white : AppTheme.textPrimary)),
                        ),
                        ...dayAppts.take(2).map((a) => Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                          decoration: BoxDecoration(
                            color: _statusColor(a['status'] ?? '').withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(a['appointment_name'] ?? '',
                              style: TextStyle(fontSize: 9, color: _statusColor(a['status'] ?? ''), fontWeight: FontWeight.w500),
                              overflow: TextOverflow.ellipsis),
                        )),
                        if (dayAppts.length > 2)
                          Text('+${dayAppts.length - 2} more',
                              style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        )),
      ],
    );
  }

  // ── RIGHT PANEL ────────────────────────────────────────────────────────────

  Widget _buildRightPanel() {
    final now         = DateTime.now();
    final firstDay    = DateTime(_focusDate.year, _focusDate.month, 1);
    final daysInMonth = DateUtils.getDaysInMonth(_focusDate.year, _focusDate.month);
    final startOffset = firstDay.weekday % 7;
    const fullMonths  = ['January','February','March','April','May','June','July','August','September','October','November','December'];

    final allUsers     = [_ownerName];
    final allCalendars = ['Main Calendar'];
    final allGroups    = ['Default Group'];

    final filteredUsers     = allUsers.where((u) => u.toLowerCase().contains(_usersSearchCtrl.text.toLowerCase())).toList();
    final filteredCalendars = allCalendars.where((c) => c.toLowerCase().contains(_calendarsSearchCtrl.text.toLowerCase())).toList();
    final filteredGroups    = allGroups.where((g) => g.toLowerCase().contains(_groupsSearchCtrl.text.toLowerCase())).toList();

    final activeCtrl = _panelTab == 0 ? _usersSearchCtrl : _panelTab == 1 ? _calendarsSearchCtrl : _groupsSearchCtrl;
    final activeHint = _panelTab == 0 ? 'Search for User' : _panelTab == 1 ? 'Search Calendars' : 'Search Groups';

    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(left: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Column(
        children: [
          // Mini calendar
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('${fullMonths[_focusDate.month - 1]} ${_focusDate.year}',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  ),
                  Clickable(
                    onTap: () => setState(() => _focusDate = DateTime(_focusDate.year, _focusDate.month - 1)),
                    child: const Icon(Icons.chevron_left, size: 16, color: AppTheme.textSecondary),
                  ),
                  Clickable(
                    onTap: () => setState(() => _focusDate = DateTime(_focusDate.year, _focusDate.month + 1)),
                    child: const Icon(Icons.chevron_right, size: 16, color: AppTheme.textSecondary),
                  ),
                ]),
                const SizedBox(height: 6),
                Row(
                  children: ['S','M','T','W','T','F','S'].map((d) => Expanded(
                    child: Center(child: Text(d, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.textSecondary))),
                  )).toList(),
                ),
                const SizedBox(height: 2),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7, childAspectRatio: 1,
                  ),
                  itemCount: startOffset + daysInMonth,
                  itemBuilder: (context, index) {
                    if (index < startOffset) return const SizedBox();
                    final day  = index - startOffset + 1;
                    final date = DateTime(_focusDate.year, _focusDate.month, day);
                    final isToday    = DateUtils.isSameDay(date, now);
                    final isSelected = DateUtils.isSameDay(date, _focusDate);
                    final hasAppt = _appointments.any((a) {
                    final dt = DateTime.tryParse(a['start_date_time'] ?? '')?.toLocal();
                    return dt != null && DateUtils.isSameDay(dt, date);
                  });
                    return Clickable(
                      onTap: () => setState(() { _focusDate = date; _calView = 'day'; }),
                      child: Container(
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: isSelected ? AppTheme.brand : isToday ? AppTheme.brand.withValues(alpha: 0.1) : null,
                          shape: BoxShape.circle,
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Text('$day', style: TextStyle(fontSize: 10,
                                color: isSelected ? Colors.white : isToday ? AppTheme.brand : AppTheme.textPrimary)),
                            if (hasAppt && !isSelected)
                              Positioned(
                                bottom: 1,
                                child: Container(width: 3, height: 3,
                                    decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle)),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          // Upcoming
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Upcoming', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                const SizedBox(height: 8),
                ..._appointments.where((a) {
                  final dt = DateTime.tryParse(a['start_date_time'] ?? '');
                  return dt != null && dt.isAfter(DateTime.now().subtract(const Duration(hours: 1)));
                }).take(3).map((a) {
                  final dt = DateTime.parse(a['start_date_time'] as String);
                  return Clickable(
                    onTap: () => _showAppointmentDetail(a),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: _statusColor(a['status'] ?? '').withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _statusColor(a['status'] ?? '').withValues(alpha: 0.2)),
                      ),
                      child: Row(children: [
                        Container(width: 3, height: 28,
                            decoration: BoxDecoration(color: _statusColor(a['status'] ?? ''), borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 7),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(a['appointment_name'] ?? '', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textPrimary), overflow: TextOverflow.ellipsis),
                          Text('${_fmtTime(dt)} · ${a['lead_name'] ?? ''}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                        ])),
                      ]),
                    ),
                  );
                }),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.borderColor),
          // Users / Calendars / Groups tabs
          Row(children: [
            _panelTabBtn('Users', 0),
            _panelTabBtn('Calendars', 1),
            _panelTabBtn('Groups', 2),
          ]),
          const Divider(height: 1, color: AppTheme.borderColor),
          // Search bar — per tab
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: activeCtrl,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: activeHint,
                hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                prefixIcon: const Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
                filled: true,
                fillColor: AppTheme.pageBg,
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: AppTheme.borderColor)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: AppTheme.brand)),
              ),
            ),
          ),
          // Panel content
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: _panelTab == 0
                  ? filteredUsers.map((u) => _panelUserRow(u, AppTheme.brand)).toList()
                  : _panelTab == 1
                      ? filteredCalendars.map((c) => _panelCheckRow(c, const Color(0xFF6366F1))).toList()
                      : filteredGroups.map((g) => _panelCheckRow(g, AppTheme.brand)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panelTabBtn(String label, int idx) {
    final sel = _panelTab == idx;
    return Expanded(
      child: Clickable(
        onTap: () => setState(() => _panelTab = idx),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: sel ? AppTheme.brand : Colors.transparent, width: 2)),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(fontSize: 11,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  color: sel ? AppTheme.brand : AppTheme.textSecondary)),
        ),
      ),
    );
  }

  Widget _panelUserRow(String name, Color color) {
    final initials = name.trim().split(' ').map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Container(width: 28, height: 28,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(initials, style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600))),
        const SizedBox(width: 8),
        Expanded(child: Text(name, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
        Checkbox(value: true, onChanged: (_) {}, activeColor: AppTheme.brand, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      ]),
    );
  }

  Widget _panelCheckRow(String label, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
        Checkbox(value: true, onChanged: (_) {}, activeColor: color, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      ]),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 2 — APPOINTMENTS LIST
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildAppointmentsTab() {
    final filtered = _filtered;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Row(children: [
            _MiniStat(label: 'Total',     value: '${_appointments.length}',                                                         color: AppTheme.brand),
            const SizedBox(width: 8),
            _MiniStat(label: 'New',       value: '${_appointments.where((a) => a['status'] == 'New').length}',                      color: const Color(0xFF6366f1)),
            const SizedBox(width: 8),
            _MiniStat(label: 'Confirmed', value: '${_appointments.where((a) => a['status'] == 'Confirmed').length}',                color: const Color(0xFF0EA5E9)),
            const SizedBox(width: 8),
            _MiniStat(label: 'Showed',    value: '${_appointments.where((a) => a['status'] == 'Showed').length}',                   color: AppTheme.success),
            const SizedBox(width: 8),
            _MiniStat(label: 'No-Show',   value: '${_appointments.where((a) => a['status'] == 'No-Show' || a['status'] == 'No Show').length}', color: const Color(0xFFf59e0b)),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            ..._statuses.map((s) {
              final selected = _statusFilter == s;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Clickable(
                  onTap: () => setState(() => _statusFilter = s),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: selected ? AppTheme.brand : AppTheme.cardBg,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: selected ? AppTheme.brand : AppTheme.borderColor),
                    ),
                    child: Text(s, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: selected ? Colors.white : AppTheme.textSecondary)),
                  ),
                ),
              );
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
                    TextButton(onPressed: _showAddAppointment, child: const Text('Schedule your first appointment')),
                  ]))
                : Container(
                    decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
                    child: Column(children: [
                      _buildListHeader(),
                      Expanded(child: ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                        itemBuilder: (_, i) => _buildAppointmentRow(filtered[i]),
                      )),
                    ]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader() {
    return Container(
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
    );
  }

  Widget _buildAppointmentRow(Map<String, dynamic> appt) {
    final startDt = DateTime.tryParse(appt['start_date_time'] ?? '') ?? DateTime.now();
    final endDt   = DateTime.tryParse(appt['end_date_time']   ?? '') ?? DateTime.now();
    final status  = appt['status'] ?? 'New';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: () => _showAppointmentDetail(appt),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Expanded(flex: 3, child: Row(children: [
              Container(width: 30, height: 30,
                  decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                  alignment: Alignment.center,
                  child: const Icon(Icons.calendar_today, size: 14, color: AppTheme.brand)),
              const SizedBox(width: 10),
              Expanded(child: Text(appt['appointment_name'] ?? 'Untitled',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
            ])),
            Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(appt['lead_name'] ?? '—', style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
              if ((appt['lead_phone'] ?? '').isNotEmpty)
                Text(appt['lead_phone'], style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ])),
            Expanded(flex: 2, child: Text('${_fmtTime(startDt)} – ${_fmtTime(endDt)}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text(appt['appointment_type'] ?? '—',
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: _StatusBadge(status: status, colorFn: _statusColor)),
            SizedBox(width: 40, child: IconButton(
              icon: const Icon(Icons.more_vert, size: 16, color: AppTheme.textMuted),
              onPressed: () => _showAppointmentDetail(appt),
            )),
          ]),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TAB 3 — CALENDAR SETTINGS
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildSettingsTab() {
    const days      = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
    // FIX: Saturday and Sunday now show their full names
    const dayLabels = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];

    final timeValues = List.generate(48, (i) {
      final h = i ~/ 2;
      final m = i % 2 == 0 ? '00' : '30';
      return '${h.toString().padLeft(2, '0')}:$m';
    });
    final timeLabels = List.generate(48, (i) {
      final h    = i ~/ 2;
      final m    = i % 2 == 0 ? '00' : '30';
      final hour = h == 0 ? 12 : h > 12 ? h - 12 : h;
      final per  = h < 12 ? 'AM' : 'PM';
      return '${hour.toString().padLeft(2, '0')}:$m $per';
    });

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // FIX: Settings icon beside title
              Row(children: [
                const Icon(Icons.settings_outlined, size: 22, color: AppTheme.textPrimary),
                const SizedBox(width: 10),
                const Text('Calendar Settings',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
              ]),
              const SizedBox(height: 4),
              const Text('Set your availability and slot duration. The AI will use these to offer booking times to leads.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const SizedBox(height: 32),

              // ── Slot duration ──────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Appointment Duration', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  const SizedBox(height: 4),
                  const Text('How long is each appointment slot?', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10, runSpacing: 10,
                    children: [
                      // Fixed presets
                      ...[15, 30, 45, 60, 90, 120].map((min) {
                        final sel = _slotDuration == min;
                        return Clickable(
                          onTap: () => setState(() => _slotDuration = min),
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
                      // FIX: Custom duration option
                      Clickable(
                        onTap: () => setState(() => _slotDuration = -1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: _slotDuration == -1 ? AppTheme.brand : AppTheme.pageBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: _slotDuration == -1 ? AppTheme.brand : AppTheme.borderColor),
                          ),
                          child: Text('Custom',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                                  color: _slotDuration == -1 ? Colors.white : AppTheme.textSecondary)),
                        ),
                      ),
                    ],
                  ),
                  // Custom duration input
                  if (_slotDuration == -1) ...[
                    const SizedBox(height: 16),
                    Row(children: [
                      SizedBox(
                        width: 120,
                        child: TextField(
                          keyboardType: TextInputType.number,
                          controller: TextEditingController(text: '$_customDurationMinutes')
                            ..selection = TextSelection.collapsed(offset: '$_customDurationMinutes'.length),
                          onChanged: (v) {
                            final parsed = int.tryParse(v);
                            if (parsed != null && parsed > 0) setState(() => _customDurationMinutes = parsed);
                          },
                          decoration: InputDecoration(
                            labelText: 'Minutes',
                            labelStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                            filled: true, fillColor: AppTheme.pageBg,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppTheme.brand, width: 2)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _customDurationMinutes >= 60
                            ? '= ${_customDurationMinutes ~/ 60}h ${_customDurationMinutes % 60 > 0 ? '${_customDurationMinutes % 60}m' : ''}'
                            : '',
                        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                      ),
                    ]),
                  ],
                ]),
              ),
              const SizedBox(height: 20),

              // ── Availability hours ──────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.borderColor)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Availability Hours', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  const SizedBox(height: 4),
                  const Text('Set the days and hours you\'re available. The AI will only offer slots within these windows.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(height: 20),
                  ...List.generate(days.length, (i) {
                    final day     = days[i];
                    final label   = dayLabels[i];
                    final dayData = _availability[day]!;
                    final enabled = dayData['enabled'] as bool;
                    final blocks  = (dayData['blocks'] as List?)?.cast<Map<String, dynamic>>() ?? [];

                    return Column(
                      children: [
                        Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppTheme.pageBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: enabled ? AppTheme.borderColor : AppTheme.borderColor.withValues(alpha: 0.4)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Switch(value: enabled, onChanged: (v) => setState(() => _availability[day]!['enabled'] = v), activeColor: AppTheme.brand),
                                const SizedBox(width: 10),
                                // Day name always full opacity regardless of enabled state
                                SizedBox(
                                  width: 110,
                                  child: Text(label,
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                                          color: AppTheme.textPrimary)),
                                ),
                                if (!enabled)
                                  const Expanded(child: Text('Unavailable', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                                else ...[
                                  Expanded(child: _timeDropdown(value: dayData['start'] as String, items: timeValues, labels: timeLabels, onChanged: (v) => setState(() => _availability[day]!['start'] = v!))),
                                  const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('to', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                  Expanded(child: _timeDropdown(value: dayData['end'] as String, items: timeValues, labels: timeLabels, onChanged: (v) => setState(() => _availability[day]!['end'] = v!))),
                                  // FIX: add block button
                                  if (enabled)
                                    Clickable(
                                      onTap: () => _addBlock(day),
                                      child: Container(
                                        margin: const EdgeInsets.only(left: 8),
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          border: Border.all(color: AppTheme.borderColor),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                                          const Icon(Icons.block, size: 12, color: AppTheme.textSecondary),
                                          const SizedBox(width: 4),
                                          const Text('Block', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                        ]),
                                      ),
                                    ),
                                ],
                              ]),
                              // FIX: blocked time slots shown below the day row
                              if (enabled && blocks.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                ...blocks.asMap().entries.map((entry) {
                                  final idx   = entry.key;
                                  final block = entry.value;
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: AppTheme.error.withValues(alpha: 0.05),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: AppTheme.error.withValues(alpha: 0.2)),
                                    ),
                                    child: Row(children: [
                                      const Icon(Icons.block, size: 12, color: AppTheme.error),
                                      const SizedBox(width: 6),
                                      const Text('Blocked: ', style: TextStyle(fontSize: 11, color: AppTheme.error, fontWeight: FontWeight.w500)),
                                      Expanded(child: Row(children: [
                                        Expanded(child: _timeDropdown(
                                          value: block['start'] as String? ?? '12:00',
                                          items: timeValues, labels: timeLabels,
                                          onChanged: (v) => setState(() {
                                            final newBlocks = List<Map<String, dynamic>>.from(blocks);
                                            newBlocks[idx] = {...newBlocks[idx], 'start': v!};
                                            _availability[day]!['blocks'] = newBlocks;
                                          }),
                                        )),
                                        const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('–', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                                        Expanded(child: _timeDropdown(
                                          value: block['end'] as String? ?? '13:00',
                                          items: timeValues, labels: timeLabels,
                                          onChanged: (v) => setState(() {
                                            final newBlocks = List<Map<String, dynamic>>.from(blocks);
                                            newBlocks[idx] = {...newBlocks[idx], 'end': v!};
                                            _availability[day]!['blocks'] = newBlocks;
                                          }),
                                        )),
                                      ])),
                                      Clickable(
                                        onTap: () => setState(() {
                                          final newBlocks = List<Map<String, dynamic>>.from(blocks)..removeAt(idx);
                                          _availability[day]!['blocks'] = newBlocks;
                                        }),
                                        child: const Padding(
                                          padding: EdgeInsets.only(left: 8),
                                          child: Icon(Icons.close, size: 14, color: AppTheme.error),
                                        ),
                                      ),
                                    ]),
                                  );
                                }),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                    );
                  }),
                ]),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity, height: 48,
                child: ElevatedButton(
                  onPressed: _savingSettings ? null : _saveSettings,
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  child: _savingSettings
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save Settings', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _addBlock(String day) {
    setState(() {
      final existing = ((_availability[day]!['blocks'] as List?) ?? []).cast<Map<String, dynamic>>();
      _availability[day]!['blocks'] = [...existing, {'start': '12:00', 'end': '13:00'}];
    });
  }

  Widget _timeDropdown({required String value, required List<String> items, required List<String> labels, required ValueChanged<String?> onChanged}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.borderColor)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: AppTheme.cardBg,
          style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
          items: List.generate(items.length, (i) => DropdownMenuItem(value: items[i], child: Text(labels[i]))),
          onChanged: onChanged,
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  SHARED HELPERS
  // ══════════════════════════════════════════════════════════════════════════

  void _showAddAppointment() {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _AppointmentFormSheet(
        appointmentTypes: _appointmentTypes,
        appointmentStatuses: _appointmentStatuses,
        onSaved: () { Navigator.pop(context); _load(); },
      ),
    );
  }

  void _showAppointmentDetail(Map<String, dynamic> appt) {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _AppointmentDetailSheet(
        appointment: appt,
        appointmentStatuses: _appointmentStatuses,
        colorFn: _statusColor,
        onUpdated: () { Navigator.pop(context); _load(); },
      ),
    );
  }

  void _showDaySheet(DateTime date, List<Map<String, dynamic>> appts) {
    showModalBottomSheet(
      context: context, backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          Text(_formatDateKey(date), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
          const SizedBox(height: 12),
          ...appts.map((a) => Clickable(
            onTap: () { Navigator.pop(context); _showAppointmentDetail(a); },
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
              child: Row(children: [
                _StatusBadge(status: a['status'] ?? '', colorFn: _statusColor),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a['appointment_name'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  Text('${_fmtTime(DateTime.tryParse(a['start_date_time'] ?? '') ?? DateTime.now())} · ${a['lead_name'] ?? ''}',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ])),
                const Icon(Icons.chevron_right, size: 16, color: AppTheme.textMuted),
              ]),
            ),
          )),
        ]),
      ),
    );
  }
}

// ── MINI STAT ─────────────────────────────────────────────────────────────────

class _MiniStat extends StatelessWidget {
  final String label, value;
  final Color color;
  const _MiniStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withValues(alpha: 0.2))),
        child: Row(children: [
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }
}

// ── STATUS BADGE ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  final Color Function(String) colorFn;
  const _StatusBadge({required this.status, required this.colorFn});

  @override
  Widget build(BuildContext context) {
    final color = colorFn(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(99), border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color)),
    );
  }
}

// ── APPOINTMENT FORM SHEET ────────────────────────────────────────────────────

class _AppointmentFormSheet extends StatefulWidget {
  final VoidCallback onSaved;
  final Map<String, dynamic>? existing;
  final List<String> appointmentTypes;
  final List<String> appointmentStatuses;
  const _AppointmentFormSheet({
    required this.onSaved,
    required this.appointmentTypes,
    required this.appointmentStatuses,
    this.existing,
  });

  @override
  State<_AppointmentFormSheet> createState() => _AppointmentFormSheetState();
}

class _AppointmentFormSheetState extends State<_AppointmentFormSheet> {
  final _db            = Supabase.instance.client;
  final _nameCtrl      = TextEditingController();
  final _locationCtrl  = TextEditingController();
  final _leadNameCtrl  = TextEditingController();
  final _leadPhoneCtrl = TextEditingController();
  final _leadEmailCtrl = TextEditingController();
  final _notesCtrl     = TextEditingController();

  String   _type    = 'Consultation';
  String   _status  = 'New';
  DateTime _startDt = DateTime.now().add(const Duration(hours: 1));
  DateTime _endDt   = DateTime.now().add(const Duration(hours: 2));
  bool     _saving  = false;
  String?  _error;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _nameCtrl.text      = e['appointment_name'] ?? '';
      _locationCtrl.text  = e['location']         ?? '';
      _leadNameCtrl.text  = e['lead_name']         ?? '';
      _leadPhoneCtrl.text = e['lead_phone']        ?? '';
      _leadEmailCtrl.text = e['lead_email']        ?? '';
      _notesCtrl.text     = e['notes']             ?? '';
      _type    = widget.appointmentTypes.contains(e['appointment_type']) ? e['appointment_type'] : widget.appointmentTypes.first;
      _status  = widget.appointmentStatuses.contains(e['status'])        ? e['status']           : widget.appointmentStatuses.first;
      _startDt = DateTime.tryParse(e['start_date_time'] ?? '') ?? _startDt;
      _endDt   = DateTime.tryParse(e['end_date_time']   ?? '') ?? _endDt;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _locationCtrl.dispose(); _leadNameCtrl.dispose();
    _leadPhoneCtrl.dispose(); _leadEmailCtrl.dispose(); _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime(bool isStart) async {
    final date = await showDatePicker(context: context,
      initialDate: isStart ? _startDt : _endDt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate:  DateTime.now().add(const Duration(days: 365 * 2)));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(isStart ? _startDt : _endDt));
    if (time == null || !mounted) return;
    final result = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) { _startDt = result; if (_endDt.isBefore(_startDt)) _endDt = _startDt.add(const Duration(hours: 1)); }
      else _endDt = result;
    });
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) { setState(() => _error = 'Appointment name is required'); return; }
    if (_endDt.isBefore(_startDt))     { setState(() => _error = 'End time must be after start time'); return; }
    setState(() { _saving = true; _error = null; });
    try {
      final userId = _db.auth.currentUser?.id;
      final profileRes = await _db.from('profiles').select('business_id').eq('user_id', userId!).maybeSingle();
      final businessId = profileRes?['business_id'] as int?;
      final payload = {
        'appointment_name': _nameCtrl.text.trim(),
        'appointment_type': _type,
        'status':           _status,
        'start_date_time':  _startDt.toIso8601String(),
        'end_date_time':    _endDt.toIso8601String(),
        'location':         _locationCtrl.text.trim(),
        'lead_name':        _leadNameCtrl.text.trim(),
        'lead_phone':       _leadPhoneCtrl.text.trim(),
        'lead_email':       _leadEmailCtrl.text.trim(),
        'notes':            _notesCtrl.text.trim(),
        'business_id':      businessId,
        'user_id':          userId,
        'confirmation_sent': false,
      };
      if (widget.existing != null) {
        await _db.from('appointments').update(payload).eq('id', widget.existing!['id']);
      } else {
        final newAppt = await _db.from('appointments').insert(payload).select().maybeSingle();
        try {
          await http.post(
            Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/run-automation'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'trigger_type': 'appointment_booked', 'business_id': businessId, 'payload': {
              'appointment_id': newAppt?['id'], 'appointment_name': _nameCtrl.text.trim(),
              'lead_name': _leadNameCtrl.text.trim(), 'lead_id': null,
              'phone': _leadPhoneCtrl.text.trim(), 'email': _leadEmailCtrl.text.trim(),
            }}),
          );
        } catch (e) { debugPrint('Automation error: $e'); }
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
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 20),
            Text(widget.existing != null ? 'Edit Appointment' : 'New Appointment',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
            const SizedBox(height: 20),
            _field('Appointment Name', _nameCtrl, hint: 'e.g. Initial Consultation'),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _dropdown('Type', widget.appointmentTypes, _type, (v) => setState(() => _type = v!))),
              const SizedBox(width: 12),
              Expanded(child: _dropdown('Status', widget.appointmentStatuses, _status, (v) => setState(() => _status = v!))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _DateTimePickerField(label: 'Start', value: _startDt, onTap: () => _pickDateTime(true))),
              const SizedBox(width: 12),
              Expanded(child: _DateTimePickerField(label: 'End',   value: _endDt,   onTap: () => _pickDateTime(false))),
            ]),
            const SizedBox(height: 12),
            _field('Location', _locationCtrl, hint: 'Office, Zoom, Phone...'),
            const SizedBox(height: 16),
            const Text('Contact Info', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            _field('Contact Name', _leadNameCtrl, hint: 'Jane Smith'),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _field('Phone', _leadPhoneCtrl, hint: '555-0100', keyboard: TextInputType.phone)),
              const SizedBox(width: 12),
              Expanded(child: _field('Email', _leadEmailCtrl, hint: 'jane@example.com', keyboard: TextInputType.emailAddress)),
            ]),
            const SizedBox(height: 8),
            _field('Notes', _notesCtrl, hint: 'Any notes...', maxLines: 3),
            if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: const TextStyle(fontSize: 13, color: AppTheme.error))],
            const SizedBox(height: 20),
            SizedBox(width: double.infinity, height: 44,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(widget.existing != null ? 'Save Changes' : 'Save Appointment', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl, {String? hint, TextInputType? keyboard, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
      const SizedBox(height: 4),
      TextField(controller: ctrl, keyboardType: keyboard, maxLines: maxLines,
        decoration: InputDecoration(hintText: hint, filled: true, fillColor: AppTheme.pageBg,
          border:        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
      ),
    ]);
  }

  Widget _dropdown(String label, List<String> items, String value, ValueChanged<String?> onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(value: value, isExpanded: true, dropdownColor: AppTheme.cardBg,
            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            items: items.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
            onChanged: onChanged),
        ),
      ),
    ]);
  }
}

// ── DATE TIME PICKER FIELD ────────────────────────────────────────────────────

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
      Clickable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
          child: Row(children: [
            const Icon(Icons.access_time, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            Expanded(child: Text(_format(value), style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
          ]),
        ),
      ),
    ]);
  }
}

// ── APPOINTMENT DETAIL SHEET ──────────────────────────────────────────────────

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
    // Migrate legacy status values
    if (!widget.appointmentStatuses.contains(_status)) _status = widget.appointmentStatuses.first;
  }

  Future<void> _updateStatus(String s) async {
    setState(() { _saving = true; _status = s; });
    try { await _db.from('appointments').update({'status': s}).eq('id', widget.appointment['id']); }
    catch (e) { debugPrint('Update error: $e'); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete Appointment'),
      content: const Text('Are you sure you want to delete this appointment?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, true),  child: const Text('Delete', style: TextStyle(color: AppTheme.error))),
      ],
    ));
    if (confirm != true) return;
    await _db.from('appointments').delete().eq('id', widget.appointment['id']);
    widget.onUpdated();
  }

  void _showEdit() {
    Navigator.pop(context);
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _AppointmentFormSheet(
        existing: widget.appointment,
        appointmentTypes: _AppointmentsScreenState._appointmentTypes,
        appointmentStatuses: widget.appointmentStatuses,
        onSaved: widget.onUpdated,
      ));
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
    final startDt = DateTime.tryParse(a['start_date_time'] ?? '') ?? DateTime.now();
    final endDt   = DateTime.tryParse(a['end_date_time']   ?? '') ?? DateTime.now();

    return Container(
      decoration: const BoxDecoration(color: AppTheme.cardBg, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 20),
          Row(children: [
            Container(width: 48, height: 48,
                decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: const Icon(Icons.calendar_today, color: AppTheme.brand, size: 22)),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a['appointment_name'] ?? 'Untitled', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
              Text(a['appointment_type'] ?? '—',        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ])),
            IconButton(onPressed: _showEdit, icon: const Icon(Icons.edit_outlined,  size: 18, color: AppTheme.textSecondary)),
            IconButton(onPressed: _delete,   icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.error)),
          ]),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.brand.withValues(alpha: 0.15))),
            child: Row(children: [
              const Icon(Icons.access_time, size: 16, color: AppTheme.brand),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_fmtFullDate(startDt), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                Text('${_fmtTime(startDt)} – ${_fmtTime(endDt)}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ]),
            ]),
          ),
          const SizedBox(height: 12),
          if ((a['location']   ?? '').isNotEmpty) _row(Icons.location_on_outlined, a['location']),
          _row(Icons.person_outline, a['lead_name'] ?? '—'),
          if ((a['lead_phone'] ?? '').isNotEmpty) _row(Icons.phone_outlined,  a['lead_phone']),
          if ((a['lead_email'] ?? '').isNotEmpty) _row(Icons.email_outlined,  a['lead_email']),
          if ((a['notes']      ?? '').isNotEmpty) _row(Icons.notes_outlined,  a['notes']),
          const SizedBox(height: 20),
          const Text('Update Status', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8,
            children: widget.appointmentStatuses.map((s) {
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
                  child: Text(s, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: sel ? Colors.white : AppTheme.textSecondary)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, height: 44,
            child: ElevatedButton(
              onPressed: widget.onUpdated,
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: const Text('Done', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
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