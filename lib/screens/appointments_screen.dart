import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../utils/business_utils.dart';
import '../widgets/office_job_form_viewer_sheet.dart';
import '../utils/phone_utils.dart';
import 'package:image_picker/image_picker.dart';
import '../navigation/app_router.dart';

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
  List<Map<String, dynamic>> _calendarGroups = [];
  List<Map<String, dynamic>> _serviceMenuItems = [];
  List<Map<String, dynamic>> _calendarRooms = [];
  List<Map<String, dynamic>> _calendarEquipment = [];
  List<Map<String, dynamic>> _teamMembers  = [];
  List<Map<String, dynamic>> _leads        = [];
  List<Map<String, dynamic>> _jobTypes     = [];
  int? _businessId;
  Map<String, dynamic>? _business;
  bool _jobCostingEnabled = false;
  bool _laborCostEnabled = false;

  // Mirrors check_plan_feature('job_costing') server-side exactly — beta
  // bypasses everything, otherwise requires a paid, active/trialing
  // subscription on Growth or Pro. Kept in sync so the teaser shown here
  // never disagrees with what log-job-expense actually allows.
  bool _computeJobCostingEnabled(Map<String, dynamic>? business) {
    if (business == null) return false;
    if (business['is_beta'] == true) return true;
    if (business['is_paid'] != true) return false;
    final sub = business['subscription_status'] as String?;
    if (sub != 'active' && sub != 'trialing') return false;
    final plan = business['plan'] as String?;
    return plan == 'growth' || plan == 'pro';
  }

  // Mirrors check_plan_feature('labor_cost_tracking') server-side exactly —
  // Pro only (TS-07), stricter than job_costing above. Kept in sync so this
  // teaser never disagrees with pay_rate_history's RLS.
  bool _computeLaborCostEnabled(Map<String, dynamic>? business) {
    if (business == null) return false;
    if (business['is_beta'] == true) return true;
    if (business['is_paid'] != true) return false;
    final sub = business['subscription_status'] as String?;
    if (sub != 'active' && sub != 'trialing') return false;
    final plan = business['plan'] as String?;
    return plan == 'pro';
  }

  late final _AppLifecycleObserver _observer = _AppLifecycleObserver(onResume: _load);
  String   _calView   = 'week';
  DateTime _focusDate = DateTime.now();

  String _statusFilter = 'All';
  final _statuses = ['All','New','Confirmed','Showed','No-Show','Cancelled','Completed','Invalid','Rescheduled'];
  final _apptSearchCtrl = TextEditingController();

  int _panelTab = 0;
  final _usersSearchCtrl     = TextEditingController();
  final _calendarsSearchCtrl = TextEditingController();
  final _groupsSearchCtrl    = TextEditingController();
  Set<String> _selectedCalendarIds = {};
  Set<String> _selectedUserIds = {};
  Set<String> _selectedGroupIds = {};

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
    'New','Confirmed','Showed','No-Show','Cancelled','Completed','Invalid','Rescheduled',
  ];

  bool _autoOpenedFromLink = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _load().then((_) => _checkDeepLink());
    WidgetsBinding.instance.addObserver(_observer);
  }

  // Opens a specific appointment automatically when arriving via a
  // Recommended Action link (?appointmentId=...) instead of just landing
  // on the general calendar view.
  void _checkDeepLink() {
    if (_autoOpenedFromLink || !mounted) return;
    final idParam = GoRouterState.of(context).uri.queryParameters['appointmentId'];
    final id = int.tryParse(idParam ?? '');
    if (id == null) return;
    _autoOpenedFromLink = true;
    final match = _appointments.where((a) => a['id'] == id).toList();
    if (match.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAppointmentDetail(match.first);
      });
    }
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loading) _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    WidgetsBinding.instance.removeObserver(_observer);
    _usersSearchCtrl.dispose();
    _calendarsSearchCtrl.dispose();
    _groupsSearchCtrl.dispose();
    _apptSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) return;
      final results = await Future.wait([
        _db.from('appointments').select().eq('business_id', _businessId!).order('start_date_time', ascending: true),
        _db.from('businesses').select('availability_hours, slot_duration_minutes, plan, is_paid, subscription_status, is_beta').eq('id', _businessId!).maybeSingle(),
        _db.from('profiles').select('id, full_name, role').eq('business_id', _businessId!),
        _db.from('leads').select('id, lead_name, lead_email, lead_phone, lead_address').eq('business_id', _businessId!).order('lead_name', ascending: true),
        _db.from('calendars').select().eq('business_id', _businessId!).order('created_at', ascending: true),
        _db.from('calendar_groups').select().eq('business_id', _businessId!).order('created_at', ascending: true),
        _db.from('service_menu_items').select().eq('business_id', _businessId!).order('created_at', ascending: true),
        _db.from('calendar_rooms').select().eq('business_id', _businessId!).order('created_at', ascending: true),
        _db.from('calendar_equipment').select().eq('business_id', _businessId!).order('created_at', ascending: true),
        _db.from('job_types').select().eq('business_id', _businessId!).filter('deleted_at', 'is', null).eq('is_active', true).order('name', ascending: true),
      ]);
      _appointments  = List<Map<String, dynamic>>.from(results[0] as List);
      _business      = results[1] as Map<String, dynamic>?;
      _jobCostingEnabled = _computeJobCostingEnabled(_business);
      _laborCostEnabled = _computeLaborCostEnabled(_business);
      await _mergeResolvedContactInfo();
      _teamMembers   = List<Map<String, dynamic>>.from(results[2] as List);
      if (_selectedUserIds.isEmpty) {
        _selectedUserIds = _teamMembers.map((m) => m['id'].toString()).toSet();
      }
      _leads         = List<Map<String, dynamic>>.from(results[3] as List);
      _calendars     = List<Map<String, dynamic>>.from(results[4] as List);
      if (_selectedCalendarIds.isEmpty) {
        _selectedCalendarIds = _calendars.map((c) => c['id'].toString()).toSet();
      }
      _calendarGroups = List<Map<String, dynamic>>.from(results[5] as List);
      if (_selectedGroupIds.isEmpty) {
        _selectedGroupIds = _calendarGroups.map((g) => g['id'].toString()).toSet();
      }
      _serviceMenuItems = List<Map<String, dynamic>>.from(results[6] as List);
      _calendarRooms = List<Map<String, dynamic>>.from(results[7] as List);
      _calendarEquipment = List<Map<String, dynamic>>.from(results[8] as List);
      _jobTypes = List<Map<String, dynamic>>.from(results[9] as List);
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

  // JG-17 hybrid contact resolution: pulls resolved_name/phone/email from
  // appointment_contact_info (live lead data when available, otherwise the
  // frozen snapshot already on the appointment) and attaches them as
  // resolved_lead_name/resolved_lead_phone/resolved_lead_email. Does NOT
  // touch the existing lead_name/lead_phone/lead_email keys — those stay
  // exactly as the raw frozen snapshot for the Edit Appointment sheet.
  // Additive only, non-blocking: a failure here never breaks appointment loading.
  Future<void> _mergeResolvedContactInfo() async {
    if (_appointments.isEmpty || _businessId == null) return;
    try {
      final ids = _appointments.map((a) => a['id']).whereType<int>().toList();
      if (ids.isEmpty) return;
      final resolved = await _db
          .from('appointment_contact_info')
          .select('appointment_id, resolved_name, resolved_phone, resolved_email')
          .inFilter('appointment_id', ids);
      final byId = {
        for (final r in List<Map<String, dynamic>>.from(resolved)) r['appointment_id']: r,
      };
      for (final a in _appointments) {
        final r = byId[a['id']];
        a['resolved_lead_name']  = r?['resolved_name']  ?? a['lead_name'];
        a['resolved_lead_phone'] = r?['resolved_phone'] ?? a['lead_phone'];
        a['resolved_lead_email'] = r?['resolved_email'] ?? a['lead_email'];
      }
    } catch (e) {
      debugPrint('Merge resolved contact info error: $e');
      for (final a in _appointments) {
        a['resolved_lead_name']  ??= a['lead_name'];
        a['resolved_lead_phone'] ??= a['lead_phone'];
        a['resolved_lead_email'] ??= a['lead_email'];
      }
    }
  }

  List<Map<String, dynamic>> get _visibleAppointments {
    final allCalsSelected = _selectedCalendarIds.length == _calendars.length;
    final allUsersSelected = _selectedUserIds.length == _teamMembers.length;
    final allGroupsSelected = _selectedGroupIds.length == _calendarGroups.length;

    // A group is a named collection of calendar_ids. "Matches" means the
    // appointment's calendar belongs to at least one currently-selected
    // group. If no groups exist at all, this filter is a no-op.
    final selectedGroupCalendarIds = <String>{};
    for (final g in _calendarGroups) {
      if (!_selectedGroupIds.contains(g['id'].toString())) continue;
      final ids = (g['calendar_ids'] as List?)?.map((e) => e.toString()) ?? const [];
      selectedGroupCalendarIds.addAll(ids);
    }

    return _appointments.where((a) {
      final calId = a['calendar_id'];
      final matchesCalendar = calId == null
          ? allCalsSelected
          : _selectedCalendarIds.contains(calId.toString());

      final assignedProfileId = a['assigned_to_profile_id'];
      final matchesUser = assignedProfileId == null
          ? allUsersSelected
          : _selectedUserIds.contains(assignedProfileId.toString());

      final matchesGroup = _calendarGroups.isEmpty
          ? true
          : (calId == null ? allGroupsSelected : selectedGroupCalendarIds.contains(calId.toString()));

      return matchesCalendar && matchesUser && matchesGroup;
    }).toList();
  }

  List<Map<String, dynamic>> get _filtered {
    var list = _statusFilter == 'All'
        ? _appointments
        : _appointments.where((a) => a['status'] == _statusFilter).toList();

    final query = _apptSearchCtrl.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      list = list.where((a) {
        final name     = (a['appointment_name'] ?? '').toString().toLowerCase();
        final leadName = (a['resolved_lead_name']  ?? '').toString().toLowerCase();
        final phone    = (a['resolved_lead_phone'] ?? '').toString().toLowerCase();
        final assigned = (a['assigned_to'] ?? '').toString().toLowerCase();
        return name.contains(query) || leadName.contains(query) ||
               phone.contains(query) || assigned.contains(query);
      }).toList();
    }

    final now = DateTime.now();
    final upcoming = list.where((a) {
      final dt = DateTime.tryParse(a['start_date_time'] ?? '');
      return dt != null && !dt.isBefore(now);
    }).toList()
      ..sort((a, b) => (DateTime.tryParse(a['start_date_time'] ?? '') ?? now)
          .compareTo(DateTime.tryParse(b['start_date_time'] ?? '') ?? now));
    final past = list.where((a) {
      final dt = DateTime.tryParse(a['start_date_time'] ?? '');
      return dt == null || dt.isBefore(now);
    }).toList()
      ..sort((a, b) => (DateTime.tryParse(b['start_date_time'] ?? '') ?? now)
          .compareTo(DateTime.tryParse(a['start_date_time'] ?? '') ?? now));

    return [...upcoming, ...past];
  }

  ({int startHour, int endHour}) _visibleHourRange() {
    int? earliest; int? latest;
    final activeCalendars = _calendars.where((c) => _selectedCalendarIds.contains(c['id'].toString()));
    for (final cal in activeCalendars) {
      final ah = cal['availability_hours'];
      if (ah == null) continue;
      final map = ah is String ? jsonDecode(ah) : ah;
      if (map is! Map) continue;
      map.forEach((_, v) {
        if (v is Map && v['enabled'] == true) {
          final s = _parseHour(v['start'] as String? ?? '09:00');
          final e = _parseHour(v['end']   as String? ?? '17:00');
          if (earliest == null || s < earliest!) earliest = s;
          if (latest   == null || e > latest!)   latest   = e;
        }
      });
    }
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
    final start = (DateTime.tryParse(a['start_date_time'] as String) ?? DateTime.now()).toLocal();
    final end   = (DateTime.tryParse(a['end_date_time']   as String) ?? DateTime.now()).toLocal();
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
                  if (!blocked && (a['resolved_lead_name'] ?? '').isNotEmpty)
                    Text(a['resolved_lead_name'], style: const TextStyle(fontSize: 10, color: Colors.white70)),
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
    final dayAppts = _visibleAppointments.where((a) {
      final dt = DateTime.tryParse(a['start_date_time'] ?? '')?.toLocal();
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
                Container(width: 8, height: 8, decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.7), shape: BoxShape.circle)),
                Expanded(child: Container(height: 1, color: Colors.red.withValues(alpha: 0.4))),
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
          ..._visibleAppointments.where((a) {
            final dt = DateTime.tryParse(a['start_date_time'] ?? '')?.toLocal();
            return dt != null && days.any((d) => DateUtils.isSameDay(d, dt));
          }).map((a) {
            final start    = (DateTime.tryParse(a['start_date_time'] as String) ?? DateTime.now()).toLocal();
            final dayIndex = days.indexWhere((d) => DateUtils.isSameDay(d, start));
            if (dayIndex < 0) return const SizedBox.shrink();
            return _buildApptBlock(a, range, gutterWidth, colWidth, dayIndex: dayIndex);
          }),
          if (days.any((d) => DateUtils.isSameDay(d, now)) && now.hour >= range.startHour && now.hour < range.endHour)
            Positioned(
              top: (now.hour + now.minute / 60.0 - range.startHour) * hourHeight - 1,
              left: gutterWidth, right: 0,
              child: Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.7), shape: BoxShape.circle)),
                Expanded(child: Container(height: 1, color: Colors.red.withValues(alpha: 0.4))),
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
          final dayAppts = _visibleAppointments.where((a) {
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
    final filteredUsers     = _teamMembers.where((m) =>
        (m['full_name'] as String? ?? '').toLowerCase().contains(_usersSearchCtrl.text.toLowerCase())).toList();
    final filteredCalendars = _calendars.where((c) => (c['name'] ?? '').toString().toLowerCase().contains(_calendarsSearchCtrl.text.toLowerCase())).toList();
    final filteredGroups    = _calendarGroups.where((g) => (g['name'] ?? '').toString().toLowerCase().contains(_groupsSearchCtrl.text.toLowerCase())).toList();

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
                      Text('${_fmtTime(dt)} · ${a['resolved_lead_name'] ?? ''}', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
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
              ? [
                  _panelAllRow(
                    checked: _selectedUserIds.length == _teamMembers.length && _teamMembers.isNotEmpty,
                    onToggle: () => setState(() {
                      if (_selectedUserIds.length == _teamMembers.length) {
                        _selectedUserIds.clear();
                      } else {
                        _selectedUserIds = _teamMembers.map((m) => m['id'].toString()).toSet();
                      }
                    }),
                  ),
                  ...filteredUsers.map((m) {
                    final id = m['id'].toString();
                    final checked = _selectedUserIds.contains(id);
                    return _panelUserRow(
                      m['full_name'] as String? ?? 'Unknown',
                      AppTheme.brand,
                      checked: checked,
                      onToggle: () => setState(() {
                        if (checked) {
                          _selectedUserIds.remove(id);
                        } else {
                          _selectedUserIds.add(id);
                        }
                      }),
                    );
                  }),
                ]
              : _panelTab == 1
                  ? [
                      _panelAllRow(
                        checked: _selectedCalendarIds.length == _calendars.length && _calendars.isNotEmpty,
                        onToggle: () => setState(() {
                          if (_selectedCalendarIds.length == _calendars.length) {
                            _selectedCalendarIds.clear();
                          } else {
                            _selectedCalendarIds = _calendars.map((c) => c['id'].toString()).toSet();
                          }
                        }),
                      ),
                      ...filteredCalendars.map((c) {
                        final id = c['id'].toString();
                        final checked = _selectedCalendarIds.contains(id);
                        return _panelCheckRow(c['name'] ?? 'Unnamed', const Color(0xFF6366F1),
                            checked: checked,
                            onToggle: () => setState(() {
                              if (checked) {
                                _selectedCalendarIds.remove(id);
                              } else {
                                _selectedCalendarIds.add(id);
                              }
                            }));
                      }),
                    ]
                  : [
                      _panelAllRow(
                        checked: _selectedGroupIds.length == _calendarGroups.length && _calendarGroups.isNotEmpty,
                        onToggle: () => setState(() {
                          if (_selectedGroupIds.length == _calendarGroups.length) {
                            _selectedGroupIds.clear();
                          } else {
                            _selectedGroupIds = _calendarGroups.map((g) => g['id'].toString()).toSet();
                          }
                        }),
                      ),
                      ...filteredGroups.map((g) {
                        final id = g['id'].toString();
                        final checked = _selectedGroupIds.contains(id);
                        return _panelCheckRow(g['name'] ?? 'Unnamed', const Color(0xFF6366F1),
                            checked: checked,
                            onToggle: () => setState(() {
                              if (checked) {
                                _selectedGroupIds.remove(id);
                              } else {
                                _selectedGroupIds.add(id);
                              }
                            }));
                      }),
                    ],
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

  Widget _panelAllRow({bool checked = true, VoidCallback? onToggle}) {
    return Clickable(onTap: onToggle, child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
      Container(width: 28, height: 28, decoration: BoxDecoration(color: AppTheme.textSecondary.withValues(alpha: 0.15), shape: BoxShape.circle), alignment: Alignment.center,
          child: const Icon(Icons.done_all, size: 14, color: AppTheme.textSecondary)),
      const SizedBox(width: 8),
      const Expanded(child: Text('All', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary))),
      Checkbox(value: checked, onChanged: (_) => onToggle?.call(), activeColor: AppTheme.brand, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
    ])));
  }

  Widget _panelUserRow(String name, Color color, {bool checked = true, VoidCallback? onToggle}) {
    final initials = name.trim().split(' ').map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
    return Clickable(onTap: onToggle, child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
      Container(width: 28, height: 28, decoration: BoxDecoration(color: color, shape: BoxShape.circle), alignment: Alignment.center,
          child: Text(initials, style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600))),
      const SizedBox(width: 8),
      Expanded(child: Text(name, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
      Checkbox(value: checked, onChanged: (_) => onToggle?.call(), activeColor: AppTheme.brand, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
    ])));
  }

  Widget _panelCheckRow(String label, Color color, {bool checked = true, VoidCallback? onToggle}) {
    return Clickable(onTap: onToggle, child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
      Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 8),
      Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
      Checkbox(value: checked, onChanged: (_) => onToggle?.call(), activeColor: color, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
    ])));
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
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
          width: 340,
          child: TextField(
            controller: _apptSearchCtrl,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: 'Search by name, phone, or assigned to...',
              hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              prefixIcon: const Icon(Icons.search, size: 16, color: AppTheme.textSecondary),
              filled: true, fillColor: AppTheme.cardBg,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border:        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand)),
            ),
          ),
          ),
        ),
        const SizedBox(height: 12),
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
                        Expanded(flex: 2, child: Text('DATE',        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
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
                        const dateMonths = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
                        final dateLabel = '${dateMonths[startDt.month-1]} ${startDt.day}, ${startDt.year}';
                        return MouseRegion(cursor: SystemMouseCursors.click, child: InkWell(
                          onTap: () => _showAppointmentDetail(appt),
                          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(children: [
                            Expanded(flex: 3, child: Row(children: [
                              Container(width: 30, height: 30, decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)), alignment: Alignment.center, child: const Icon(Icons.calendar_today, size: 14, color: AppTheme.brand)),
                              const SizedBox(width: 10),
                              Expanded(child: Text(appt['appointment_name'] ?? 'Untitled', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
                            ])),
                            Expanded(flex: 2, child: Text(dateLabel, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                            Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(appt['resolved_lead_name'] ?? '—', style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                              if ((appt['resolved_lead_phone'] ?? '').isNotEmpty)
                                Text(appt['resolved_lead_phone'], style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))
                              else if ((appt['resolved_lead_name'] ?? '').isNotEmpty && appt['resolved_lead_name'] != '—')
                                const Text('No phone on file', style: TextStyle(fontSize: 11, color: AppTheme.textMuted, fontStyle: FontStyle.italic)),
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
                onPressed: () => _showEquipmentDialog(),
                icon: const Icon(Icons.build_outlined, size: 16),
                label: const Text('Add Equipment'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => _showServiceMenuDialog(),
                icon: const Icon(Icons.room_service_outlined, size: 16),
                label: const Text('Add Service'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => _showGroupDialog(),
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
            _buildGroupsTab(),
            _buildServiceMenuTab(),
            _buildRoomsTab(),
            _buildEquipmentTab(),
          ],
        )),
      ]),
    );
  }

// ══════════════════════════════════════════════════════════════════════════
  //  GROUPS TAB
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildGroupsTab() {
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
            Expanded(flex: 4, child: Text('GROUP NAME', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 3, child: Text('CALENDARS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('STATUS',    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            SizedBox(width: 80),
          ]),
        ),
        Expanded(
          child: _calendarGroups.isEmpty
              ? Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.group_work_outlined, size: 48, color: AppTheme.textMuted),
                    const SizedBox(height: 12),
                    const Text('No groups yet', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => _showGroupDialog(),
                      child: const Text('Create your first group'),
                    ),
                  ])),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: ListView.separated(
                    itemCount: _calendarGroups.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                    itemBuilder: (_, i) {
                      final group    = _calendarGroups[i];
                      final isActive = group['is_active'] as bool? ?? true;
                      final calIds   = (group['calendar_ids'] as List?)?.map((e) => e.toString()).toList() ?? [];
                      final assignedCals = _calendars.where((c) => calIds.contains(c['id'].toString())).toList();
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Row(children: [
                          Expanded(flex: 4, child: Row(children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(color: const Color(0xFF6366F1).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                              alignment: Alignment.center,
                              child: const Icon(Icons.group_work_outlined, size: 18, color: Color(0xFF6366F1)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(group['name'] ?? 'Unnamed', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                              if ((group['description'] ?? '').isNotEmpty)
                                Text(group['description'], style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                            ])),
                          ])),
                          Expanded(flex: 3, child: assignedCals.isEmpty
                              ? const Text('No calendars', style: TextStyle(fontSize: 12, color: AppTheme.textMuted))
                              : Wrap(spacing: 4, runSpacing: 4, children: assignedCals.take(3).map((c) => Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppTheme.brand.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(c['name'] ?? '', style: const TextStyle(fontSize: 10, color: AppTheme.brand, fontWeight: FontWeight.w500)),
                                )).toList()
                              ),
                          ),
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
                            IconButton(icon: const Icon(Icons.edit_outlined,  size: 16, color: AppTheme.textSecondary), onPressed: () => _showGroupDialog(existing: group)),
                            IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.error),         onPressed: () => _deleteGroup(group)),
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

  void _showGroupDialog({Map<String, dynamic>? existing}) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _GroupFormDialog(
        businessId: _businessId,
        calendars: _calendars,
        existing: existing,
        onSaved: () {
          Navigator.of(ctx, rootNavigator: true).pop();
          _load();
        },
      ),
    );
  }

  Future<void> _deleteGroup(Map<String, dynamic> group) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Group'),
        content: Text('Delete "${group['name']}"? This will not affect the calendars in this group.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () { confirmed = true; Navigator.of(ctx, rootNavigator: true).pop(); },
            child: const Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (!confirmed) return;
    await _db.from('calendar_groups').delete().eq('id', group['id']);
    _load();
  }
  // ══════════════════════════════════════════════════════════════════════════
  //  SERVICE MENU TAB
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildServiceMenuTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: const Row(children: [
            Expanded(flex: 4, child: Text('SERVICE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('DURATION', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('PRICE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('STATUS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            SizedBox(width: 80),
          ]),
        ),
        Expanded(
          child: _serviceMenuItems.isEmpty
              ? Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.room_service_outlined, size: 48, color: AppTheme.textMuted),
                    const SizedBox(height: 12),
                    const Text('No services yet', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                    const SizedBox(height: 8),
                    TextButton(onPressed: () => _showServiceMenuDialog(), child: const Text('Add your first service')),
                  ])),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: ListView.separated(
                    itemCount: _serviceMenuItems.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                    itemBuilder: (_, i) {
                      final item     = _serviceMenuItems[i];
                      final isActive = item['is_active'] as bool? ?? true;
                      final duration = item['duration_minutes'] as int? ?? 60;
                      final price    = item['price'];
                      final durationLabel = duration < 60 ? '${duration}m' : duration % 60 == 0 ? '${duration ~/ 60}h' : '${duration ~/ 60}h ${duration % 60}m';
                      final priceLabel = price != null ? '\$${(price as num).toStringAsFixed(2)}' : '—';
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Row(children: [
                          Expanded(flex: 4, child: Row(children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(color: const Color(0xFF10B981).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                              alignment: Alignment.center,
                              child: const Icon(Icons.room_service_outlined, size: 18, color: Color(0xFF10B981)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(item['name'] ?? 'Unnamed', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                              if ((item['description'] ?? '').isNotEmpty)
                                Text(item['description'], style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                            ])),
                          ])),
                          Expanded(flex: 2, child: Text(durationLabel, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                          Expanded(flex: 2, child: Text(priceLabel, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
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
                            IconButton(icon: const Icon(Icons.edit_outlined, size: 16, color: AppTheme.textSecondary), onPressed: () => _showServiceMenuDialog(existing: item)),
                            IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.error), onPressed: () => _deleteServiceMenuItem(item)),
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

  void _showServiceMenuDialog({Map<String, dynamic>? existing}) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _ServiceMenuFormDialog(
        businessId: _businessId,
        calendars: _calendars,
        existing: existing,
        onSaved: () {
          Navigator.of(ctx, rootNavigator: true).pop();
          _load();
        },
      ),
    );
  }

  Future<void> _deleteServiceMenuItem(Map<String, dynamic> item) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Service'),
        content: Text('Delete "${item['name']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () { confirmed = true; Navigator.of(ctx, rootNavigator: true).pop(); },
            child: const Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (!confirmed) return;
    await _db.from('service_menu_items').delete().eq('id', item['id']);
    _load();
  }
  // ══════════════════════════════════════════════════════════════════════════
  //  ROOMS TAB
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildRoomsTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: const Row(children: [
            Expanded(flex: 4, child: Text('ROOM', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('CAPACITY', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('LOCATION', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('STATUS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            SizedBox(width: 80),
          ]),
        ),
        Expanded(
          child: _calendarRooms.isEmpty
              ? Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.meeting_room_outlined, size: 48, color: AppTheme.textMuted),
                    const SizedBox(height: 12),
                    const Text('No rooms yet', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                    const SizedBox(height: 8),
                    TextButton(onPressed: () => _showRoomDialog(), child: const Text('Add your first room')),
                  ])),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: ListView.separated(
                    itemCount: _calendarRooms.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                    itemBuilder: (_, i) {
                      final room     = _calendarRooms[i];
                      final isActive = room['is_active'] as bool? ?? true;
                      final capacity = room['capacity'] as int?;
                      final location = room['location'] as String? ?? '';
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Row(children: [
                          Expanded(flex: 4, child: Row(children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(color: const Color(0xFF0EA5E9).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                              alignment: Alignment.center,
                              child: const Icon(Icons.meeting_room_outlined, size: 18, color: Color(0xFF0EA5E9)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(room['name'] ?? 'Unnamed', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                              if ((room['description'] ?? '').isNotEmpty)
                                Text(room['description'], style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                            ])),
                          ])),
                          Expanded(flex: 2, child: Text(
                            capacity != null ? '$capacity people' : '—',
                            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                          )),
                          Expanded(flex: 2, child: Text(
                            location.isNotEmpty ? location : '—',
                            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                            overflow: TextOverflow.ellipsis,
                          )),
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
                            IconButton(icon: const Icon(Icons.edit_outlined, size: 16, color: AppTheme.textSecondary), onPressed: () => _showRoomDialog(existing: room)),
                            IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.error), onPressed: () => _deleteRoom(room)),
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

  void _showRoomDialog({Map<String, dynamic>? existing}) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _RoomFormDialog(
        businessId: _businessId,
        calendars: _calendars,
        existing: existing,
        onSaved: () {
          Navigator.of(ctx, rootNavigator: true).pop();
          _load();
        },
      ),
    );
  }

  Future<void> _deleteRoom(Map<String, dynamic> room) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Room'),
        content: Text('Delete "${room['name']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () { confirmed = true; Navigator.of(ctx, rootNavigator: true).pop(); },
            child: const Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (!confirmed) return;
    await _db.from('calendar_rooms').delete().eq('id', room['id']);
    _load();
  }
  Widget _buildEquipmentTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: const Row(children: [
            Expanded(flex: 3, child: Text('EQUIPMENT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('TYPE',     style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 1, child: Text('QTY',      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            Expanded(flex: 2, child: Text('STATUS',   style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 1))),
            SizedBox(width: 80),
          ]),
        ),
        Expanded(
          child: _calendarEquipment.isEmpty
              ? Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.build_outlined, size: 48, color: AppTheme.textMuted),
                    const SizedBox(height: 12),
                    const Text('No equipment yet', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
                    const SizedBox(height: 8),
                    TextButton(onPressed: () => _showEquipmentDialog(), child: const Text('Add your first equipment')),
                  ])),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: AppTheme.cardBg,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                    border: const Border(left: BorderSide(color: AppTheme.borderColor), right: BorderSide(color: AppTheme.borderColor), bottom: BorderSide(color: AppTheme.borderColor)),
                  ),
                  child: ListView.separated(
                    itemCount: _calendarEquipment.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                    itemBuilder: (_, i) {
                      final eq       = _calendarEquipment[i];
                      final isActive = eq['is_active'] as bool? ?? true;
                      final qty      = eq['quantity']  as int?  ?? 1;
                      final type     = eq['equipment_type'] as String? ?? '';
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Row(children: [
                          Expanded(flex: 3, child: Row(children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(color: const Color(0xFFf59e0b).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                              alignment: Alignment.center,
                              child: const Icon(Icons.build_outlined, size: 18, color: Color(0xFFf59e0b)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(eq['name'] ?? 'Unnamed', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                              if ((eq['description'] ?? '').isNotEmpty)
                                Text(eq['description'], style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                            ])),
                          ])),
                          Expanded(flex: 2, child: Text(type.isNotEmpty ? type : '—', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                          Expanded(flex: 1, child: Text('$qty', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
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
                            IconButton(icon: const Icon(Icons.edit_outlined,  size: 16, color: AppTheme.textSecondary), onPressed: () => _showEquipmentDialog(existing: eq)),
                            IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.error),         onPressed: () => _deleteEquipment(eq)),
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

  void _showEquipmentDialog({Map<String, dynamic>? existing}) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _EquipmentFormDialog(
        businessId: _businessId,
        calendars: _calendars,
        existing: existing,
        onSaved: () {
          Navigator.of(ctx, rootNavigator: true).pop();
          _load();
        },
      ),
    );
  }

  Future<void> _deleteEquipment(Map<String, dynamic> eq) async {
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Equipment'),
        content: Text('Delete "${eq['name']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () { confirmed = true; Navigator.of(ctx, rootNavigator: true).pop(); },
            child: const Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (!confirmed) return;
    await _db.from('calendar_equipment').delete().eq('id', eq['id']);
    if (!mounted) return;
    _load();
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
                      final isPublic = cal['is_public'] as bool? ?? false;
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
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            // Public booking toggle
                            Tooltip(
                              message: isPublic ? 'Public booking on' : 'Public booking off',
                              child: InkWell(
                                onTap: () async {
                                  await _db
                                      .from('calendars')
                                      .update({'is_public': !isPublic})
                                      .eq('id', cal['id']);
                                  _load();
                                },
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isPublic
                                        ? AppTheme.success.withValues(alpha: 0.1)
                                        : AppTheme.pageBg,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: isPublic
                                          ? AppTheme.success.withValues(alpha: 0.4)
                                          : AppTheme.borderColor,
                                    ),
                                  ),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(
                                      Icons.public_rounded,
                                      size: 13,
                                      color: isPublic ? AppTheme.success : AppTheme.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      isPublic ? 'Public' : 'Private',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: isPublic ? AppTheme.success : AppTheme.textSecondary,
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ),
                            if (isPublic) ...[
                              const SizedBox(width: 6),
                              Tooltip(
                                message: 'Copy booking link',
                                child: InkWell(
                                  onTap: () async {
                                    final url = 'https://nexaflow-crm.web.app/book/${cal['id']}';
                                    await Clipboard.setData(ClipboardData(text: url));
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Booking link copied'),
                                          behavior: SnackBarBehavior.floating,
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  },
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: AppTheme.pageBg,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: AppTheme.borderColor),
                                    ),
                                    child: const Icon(Icons.copy_rounded, size: 13, color: AppTheme.textSecondary),
                                  ),
                                ),
                              ),
                            ],
                            IconButton(icon: const Icon(Icons.edit_outlined,  size: 16, color: AppTheme.textSecondary), onPressed: () => _showCreateCalendarDialog(existing: cal)),
                            IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.error),         onPressed: () => _deleteCalendar(cal)),
                          ]),
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
      businessDefaultHours: _business?['availability_hours'],
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
      jobTypes: _jobTypes,
      businessDefaultHours: _business?['availability_hours'],
      onSaved: (newApptId) async {
        Navigator.of(ctx, rootNavigator: true).pop();
        await _load();
        if (newApptId != null && mounted) {
          final match = _appointments.where((a) => a['id'] == newApptId).toList();
          if (match.isNotEmpty) _showAppointmentDetail(match.first);
        }
      },
    ));
  }

  void _showAppointmentDetail(Map<String, dynamic> appt) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _AppointmentDetailSheet(
        appointment: appt,
        appointmentStatuses: _appointmentStatuses,
        colorFn: _statusColor,
        calendars: _calendars,
        teamMembers: _teamMembers,
        jobTypes: _jobTypes,
        businessDefaultHours: _business?['availability_hours'],
        jobCostingEnabled: _jobCostingEnabled,
        laborCostEnabled: _laborCostEnabled,
        onUpdated: () { Navigator.pop(context); _load(); },
      ));
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
                Text('${_fmtTime(DateTime.tryParse(a['start_date_time'] ?? '') ?? DateTime.now())} · ${a['resolved_lead_name'] ?? ''}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ])),
              const Icon(Icons.chevron_right, size: 16, color: AppTheme.textMuted),
            ]),
          ),
        )),
      ]),
    ));
  }
}
// ══════════════════════════════════════════════════════════════════════════════
//  GROUP FORM DIALOG
// ══════════════════════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════
//  SERVICE MENU FORM DIALOG
// ══════════════════════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════
//  ROOM FORM DIALOG
// ══════════════════════════════════════════════════════════════════════════════
class _EquipmentFormDialog extends StatefulWidget {
  final int? businessId;
  final List<Map<String, dynamic>> calendars;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;

  const _EquipmentFormDialog({
    required this.businessId,
    required this.calendars,
    required this.onSaved,
    this.existing,
  });

  @override
  State<_EquipmentFormDialog> createState() => _EquipmentFormDialogState();
}

class _EquipmentFormDialogState extends State<_EquipmentFormDialog> {
  final _db           = Supabase.instance.client;
  final _nameCtrl     = TextEditingController();
  final _descCtrl     = TextEditingController();
  final _typeCtrl     = TextEditingController();
  final _qtyCtrl      = TextEditingController();

  bool    _isActive = true;
  bool    _saving   = false;
  String? _error;
  Set<String> _selectedCalendarIds = {};

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _nameCtrl.text = e['name']           ?? '';
      _descCtrl.text = e['description']    ?? '';
      _typeCtrl.text = e['equipment_type'] ?? '';
      _qtyCtrl.text  = (e['quantity'] ?? 1).toString();
      _isActive      = e['is_active'] as bool? ?? true;
      _selectedCalendarIds = (e['calendar_ids'] as List?)
          ?.map((v) => v.toString()).toSet() ?? {};
    } else {
      _qtyCtrl.text = '1';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _typeCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Equipment name is required');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final payload = {
        'business_id':    widget.businessId,
        'name':           _nameCtrl.text.trim(),
        'description':    _descCtrl.text.trim(),
        'equipment_type': _typeCtrl.text.trim(),
        'quantity':       int.tryParse(_qtyCtrl.text.trim()) ?? 1,
        'calendar_ids':   _selectedCalendarIds.toList(),
        'is_active':      _isActive,
        'updated_at':     DateTime.now().toIso8601String(),
      };
      if (widget.existing != null) {
        await _db.from('calendar_equipment').update(payload).eq('id', widget.existing!['id']);
      } else {
        await _db.from('calendar_equipment').insert(payload);
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
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 700),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.build_outlined, size: 20, color: Color(0xFFf59e0b)),
              const SizedBox(width: 10),
              Expanded(child: Text(
                widget.existing != null ? 'Edit Equipment' : 'New Equipment',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
              )),
              IconButton(
                onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                icon: const Icon(Icons.close, size: 20, color: AppTheme.textSecondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ]),
          ),
          Flexible(child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              _label('Equipment Name *'),
              const SizedBox(height: 4),
              _textField(_nameCtrl, hint: 'e.g. Pressure Washer, Company Van'),
              const SizedBox(height: 14),

              _label('Description (optional)'),
              const SizedBox(height: 4),
              _textField(_descCtrl, hint: 'Brief description...', maxLines: 2),
              const SizedBox(height: 14),

              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Equipment Type (optional)'),
                  const SizedBox(height: 4),
                  _textField(_typeCtrl, hint: 'e.g. Vehicle, Tool, Machine'),
                ])),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Quantity'),
                  const SizedBox(height: 4),
                  _textField(_qtyCtrl, hint: '1', keyboard: TextInputType.number),
                ])),
              ]),
              const SizedBox(height: 20),

              if (widget.calendars.isNotEmpty) ...[
                _label('Available On Calendars'),
                const SizedBox(height: 4),
                const Text('Select which calendars can use this equipment.',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                const SizedBox(height: 12),
                ...widget.calendars.map((cal) {
                  final id      = cal['id'].toString();
                  final name    = cal['name']?.toString() ?? 'Unnamed';
                  final checked = _selectedCalendarIds.contains(id);
                  return Clickable(
                    onTap: () => setState(() {
                      if (checked) _selectedCalendarIds.remove(id);
                      else         _selectedCalendarIds.add(id);
                    }),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: checked ? AppTheme.brand.withValues(alpha: 0.05) : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: checked ? AppTheme.brand.withValues(alpha: 0.3) : AppTheme.borderColor,
                          width: checked ? 1.5 : 1,
                        ),
                      ),
                      child: Row(children: [
                        Container(
                          width: 30, height: 30,
                          decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                          alignment: Alignment.center,
                          child: const Icon(Icons.calendar_month, size: 15, color: AppTheme.brand),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(name, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
                        Checkbox(
                          value: checked,
                          onChanged: (_) => setState(() {
                            if (checked) _selectedCalendarIds.remove(id);
                            else         _selectedCalendarIds.add(id);
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

              Row(children: [
                Switch(value: _isActive, onChanged: (v) => setState(() => _isActive = v), activeColor: AppTheme.brand),
                const SizedBox(width: 8),
                const Text('Equipment is active', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
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
                      : Text(widget.existing != null ? 'Save Changes' : 'Add Equipment',
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
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary));

  Widget _textField(TextEditingController ctrl, {String? hint, int maxLines = 1, TextInputType? keyboard}) {
    return TextField(
      controller: ctrl, maxLines: maxLines, keyboardType: keyboard,
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
}
class _RoomFormDialog extends StatefulWidget {
  final int? businessId;
  final List<Map<String, dynamic>> calendars;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;

  const _RoomFormDialog({
    required this.businessId,
    required this.calendars,
    required this.onSaved,
    this.existing,
  });

  @override
  State<_RoomFormDialog> createState() => _RoomFormDialogState();
}

class _RoomFormDialogState extends State<_RoomFormDialog> {
  final _db           = Supabase.instance.client;
  final _nameCtrl     = TextEditingController();
  final _descCtrl     = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _capacityCtrl = TextEditingController();

  bool    _isActive = true;
  bool    _saving   = false;
  String? _error;
  Set<String> _selectedCalendarIds = {};

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _nameCtrl.text     = e['name']        ?? '';
      _descCtrl.text     = e['description'] ?? '';
      _locationCtrl.text = e['location']    ?? '';
      _capacityCtrl.text = e['capacity']?.toString() ?? '';
      _isActive          = e['is_active'] as bool? ?? true;
      _selectedCalendarIds = (e['calendar_ids'] as List?)
          ?.map((v) => v.toString()).toSet() ?? {};
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _locationCtrl.dispose();
    _capacityCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Room name is required');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final capacityText = _capacityCtrl.text.trim();
      final payload = {
        'business_id':  widget.businessId,
        'name':         _nameCtrl.text.trim(),
        'description':  _descCtrl.text.trim(),
        'location':     _locationCtrl.text.trim(),
        'capacity':     capacityText.isNotEmpty ? int.tryParse(capacityText) : null,
        'calendar_ids': _selectedCalendarIds.toList(),
        'is_active':    _isActive,
        'updated_at':   DateTime.now().toIso8601String(),
      };
      if (widget.existing != null) {
        await _db.from('calendar_rooms').update(payload).eq('id', widget.existing!['id']);
      } else {
        await _db.from('calendar_rooms').insert(payload);
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
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 700),
        child: Column(children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.meeting_room_outlined, size: 20, color: Color(0xFF0EA5E9)),
              const SizedBox(width: 10),
              Expanded(child: Text(
                widget.existing != null ? 'Edit Room' : 'New Room',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
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

              _label('Room Name *'),
              const SizedBox(height: 4),
              _textField(_nameCtrl, hint: 'e.g. Conference Room A'),
              const SizedBox(height: 14),

              _label('Description (optional)'),
              const SizedBox(height: 4),
              _textField(_descCtrl, hint: 'Brief description...', maxLines: 2),
              const SizedBox(height: 14),

              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Location (optional)'),
                  const SizedBox(height: 4),
                  _textField(_locationCtrl, hint: 'e.g. Floor 2, Building A'),
                ])),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _label('Capacity (optional)'),
                  const SizedBox(height: 4),
                  _textField(_capacityCtrl, hint: 'e.g. 10', keyboard: TextInputType.number),
                ])),
              ]),
              const SizedBox(height: 20),

              if (widget.calendars.isNotEmpty) ...[
                _label('Available On Calendars'),
                const SizedBox(height: 4),
                const Text('Select which calendars can book this room.',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                const SizedBox(height: 12),
                ...widget.calendars.map((cal) {
                  final id      = cal['id'].toString();
                  final name    = cal['name']?.toString() ?? 'Unnamed';
                  final checked = _selectedCalendarIds.contains(id);
                  return Clickable(
                    onTap: () => setState(() {
                      if (checked) _selectedCalendarIds.remove(id);
                      else         _selectedCalendarIds.add(id);
                    }),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: checked ? AppTheme.brand.withValues(alpha: 0.05) : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: checked ? AppTheme.brand.withValues(alpha: 0.3) : AppTheme.borderColor,
                          width: checked ? 1.5 : 1,
                        ),
                      ),
                      child: Row(children: [
                        Container(
                          width: 30, height: 30,
                          decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                          alignment: Alignment.center,
                          child: const Icon(Icons.calendar_month, size: 15, color: AppTheme.brand),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(name, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
                        Checkbox(
                          value: checked,
                          onChanged: (_) => setState(() {
                            if (checked) _selectedCalendarIds.remove(id);
                            else         _selectedCalendarIds.add(id);
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

              Row(children: [
                Switch(value: _isActive, onChanged: (v) => setState(() => _isActive = v), activeColor: AppTheme.brand),
                const SizedBox(width: 8),
                const Text('Room is active', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
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
                      : Text(widget.existing != null ? 'Save Changes' : 'Add Room',
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
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary));

  Widget _textField(TextEditingController ctrl, {String? hint, int maxLines = 1, TextInputType? keyboard}) {
    return TextField(
      controller: ctrl, maxLines: maxLines, keyboardType: keyboard,
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
}
class _ServiceMenuFormDialog extends StatefulWidget {
  final int? businessId;
  final List<Map<String, dynamic>> calendars;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;

  const _ServiceMenuFormDialog({
    required this.businessId,
    required this.calendars,
    required this.onSaved,
    this.existing,
  });

  @override
  State<_ServiceMenuFormDialog> createState() => _ServiceMenuFormDialogState();
}

class _ServiceMenuFormDialogState extends State<_ServiceMenuFormDialog> {
  final _db       = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();

  int     _duration  = 60;
  int     _customDuration = 45;
  bool    _isActive  = true;
  bool    _saving    = false;
  String? _error;
  Set<String> _selectedCalendarIds = {};

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _nameCtrl.text  = e['name']        ?? '';
      _descCtrl.text  = e['description'] ?? '';
      _priceCtrl.text = e['price']?.toString() ?? '';
      _duration       = e['duration_minutes'] as int? ?? 60;
      _isActive       = e['is_active'] as bool? ?? true;
      _selectedCalendarIds = (e['calendar_ids'] as List?)
          ?.map((v) => v.toString()).toSet() ?? {};
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Service name is required');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final effectiveDuration = _duration == -1 ? _customDuration : _duration;
      final priceText = _priceCtrl.text.trim();
      final payload = {
        'business_id':      widget.businessId,
        'name':             _nameCtrl.text.trim(),
        'description':      _descCtrl.text.trim(),
        'duration_minutes': effectiveDuration,
        'price':            priceText.isNotEmpty ? double.tryParse(priceText) : null,
        'calendar_ids':     _selectedCalendarIds.toList(),
        'is_active':        _isActive,
        'updated_at':       DateTime.now().toIso8601String(),
      };
      if (widget.existing != null) {
        await _db.from('service_menu_items').update(payload).eq('id', widget.existing!['id']);
      } else {
        await _db.from('service_menu_items').insert(payload);
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
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
        child: Column(children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.room_service_outlined, size: 20, color: Color(0xFF10B981)),
              const SizedBox(width: 10),
              Expanded(child: Text(
                widget.existing != null ? 'Edit Service' : 'New Service',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
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

              _label('Service Name *'),
              const SizedBox(height: 4),
              _textField(_nameCtrl, hint: 'e.g. Initial Consultation'),
              const SizedBox(height: 14),

              _label('Description (optional)'),
              const SizedBox(height: 4),
              _textField(_descCtrl, hint: 'Brief description...', maxLines: 2),
              const SizedBox(height: 20),

              _label('Duration'),
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

              _label('Price (optional)'),
              const SizedBox(height: 4),
              _textField(_priceCtrl, hint: 'e.g. 150.00', keyboard: TextInputType.numberWithOptions(decimal: true)),
              const SizedBox(height: 20),

              if (widget.calendars.isNotEmpty) ...[
                _label('Available On Calendars'),
                const SizedBox(height: 4),
                const Text('Select which calendars offer this service.',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                const SizedBox(height: 12),
                ...widget.calendars.map((cal) {
                  final id      = cal['id'].toString();
                  final name    = cal['name']?.toString() ?? 'Unnamed';
                  final checked = _selectedCalendarIds.contains(id);
                  return Clickable(
                    onTap: () => setState(() {
                      if (checked) _selectedCalendarIds.remove(id);
                      else         _selectedCalendarIds.add(id);
                    }),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: checked ? AppTheme.brand.withValues(alpha: 0.05) : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: checked ? AppTheme.brand.withValues(alpha: 0.3) : AppTheme.borderColor,
                          width: checked ? 1.5 : 1,
                        ),
                      ),
                      child: Row(children: [
                        Container(
                          width: 30, height: 30,
                          decoration: BoxDecoration(color: AppTheme.brand.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                          alignment: Alignment.center,
                          child: const Icon(Icons.calendar_month, size: 15, color: AppTheme.brand),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(name, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
                        Checkbox(
                          value: checked,
                          onChanged: (_) => setState(() {
                            if (checked) _selectedCalendarIds.remove(id);
                            else         _selectedCalendarIds.add(id);
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

              Row(children: [
                Switch(value: _isActive, onChanged: (v) => setState(() => _isActive = v), activeColor: AppTheme.brand),
                const SizedBox(width: 8),
                const Text('Service is active', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
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
                      : Text(widget.existing != null ? 'Save Changes' : 'Add Service',
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
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary));

  Widget _textField(TextEditingController ctrl, {String? hint, int maxLines = 1, TextInputType? keyboard}) {
    return TextField(
      controller: ctrl, maxLines: maxLines, keyboardType: keyboard,
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
}
class _GroupFormDialog extends StatefulWidget {
  final int? businessId;
  final List<Map<String, dynamic>> calendars;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;

  const _GroupFormDialog({
    required this.businessId,
    required this.calendars,
    required this.onSaved,
    this.existing,
  });

  @override
  State<_GroupFormDialog> createState() => _GroupFormDialogState();
}

class _GroupFormDialogState extends State<_GroupFormDialog> {
  final _db       = Supabase.instance.client;
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool    _isActive = true;
  bool    _saving   = false;
  String? _error;
  Set<String> _selectedCalendarIds = {};

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _nameCtrl.text = e['name']        ?? '';
      _descCtrl.text = e['description'] ?? '';
      _isActive      = e['is_active']   as bool? ?? true;
      _selectedCalendarIds = (e['calendar_ids'] as List?)
          ?.map((v) => v.toString()).toSet() ?? {};
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
      setState(() => _error = 'Group name is required');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final payload = {
        'business_id':  widget.businessId,
        'name':         _nameCtrl.text.trim(),
        'description':  _descCtrl.text.trim(),
        'calendar_ids': _selectedCalendarIds.toList(),
        'is_active':    _isActive,
        'updated_at':   DateTime.now().toIso8601String(),
      };
      if (widget.existing != null) {
        await _db.from('calendar_groups').update(payload).eq('id', widget.existing!['id']);
      } else {
        await _db.from('calendar_groups').insert(payload);
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
    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 700),
        child: Column(children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.borderColor))),
            child: Row(children: [
              const Icon(Icons.group_work_outlined, size: 20, color: Color(0xFF6366F1)),
              const SizedBox(width: 10),
              Expanded(child: Text(
                widget.existing != null ? 'Edit Group' : 'New Calendar Group',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
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
              _label('Group Name *'),
              const SizedBox(height: 4),
              _textField(_nameCtrl, hint: 'e.g. Sales Team Calendars'),
              const SizedBox(height: 14),

              // Description
              _label('Description (optional)'),
              const SizedBox(height: 4),
              _textField(_descCtrl, hint: 'Brief description...', maxLines: 2),
              const SizedBox(height: 20),

              // Calendar selection
              _label('Calendars in this Group'),
              const SizedBox(height: 4),
              const Text('Select which calendars belong to this group.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              const SizedBox(height: 12),

              if (widget.calendars.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: const Text('No calendars available. Create a calendar first.',
                      style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                )
              else
                ...widget.calendars.map((cal) {
                  final id      = cal['id'].toString();
                  final name    = cal['name']?.toString() ?? 'Unnamed';
                  final checked = _selectedCalendarIds.contains(id);
                  final type    = cal['calendar_type'] ?? 'personal';
                  final typeLabel = {
                    'personal':    'Personal',
                    'round_robin': 'Round Robin',
                    'class':       'Class',
                    'collective':  'Collective',
                  }[type] ?? type;

                  return Clickable(
                    onTap: () => setState(() {
                      if (checked) _selectedCalendarIds.remove(id);
                      else         _selectedCalendarIds.add(id);
                    }),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: checked ? AppTheme.brand.withValues(alpha: 0.05) : AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: checked ? AppTheme.brand.withValues(alpha: 0.3) : AppTheme.borderColor,
                          width: checked ? 1.5 : 1,
                        ),
                      ),
                      child: Row(children: [
                        Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: AppTheme.brand.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(Icons.calendar_month, size: 16, color: AppTheme.brand),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
                          Text(typeLabel, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                        ])),
                        Checkbox(
                          value: checked,
                          onChanged: (_) => setState(() {
                            if (checked) _selectedCalendarIds.remove(id);
                            else         _selectedCalendarIds.add(id);
                          }),
                          activeColor: AppTheme.brand,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ]),
                    ),
                  );
                }),

              const SizedBox(height: 20),

              // Active toggle
              Row(children: [
                Switch(value: _isActive, onChanged: (v) => setState(() => _isActive = v), activeColor: AppTheme.brand),
                const SizedBox(width: 8),
                const Text('Group is active', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
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
                      : Text(widget.existing != null ? 'Save Changes' : 'Create Group',
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
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary));

  Widget _textField(TextEditingController ctrl, {String? hint, int maxLines = 1}) {
    return TextField(
      controller: ctrl, maxLines: maxLines,
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
}
class _AppLifecycleObserver extends WidgetsBindingObserver {
  final VoidCallback onResume;
  _AppLifecycleObserver({required this.onResume});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  SCHEDULING CONFLICT HELPERS (employee double-booking)
// ══════════════════════════════════════════════════════════════════════════════

Future<List<Map<String, dynamic>>> _findEmployeeConflicts({
  required SupabaseClient db,
  required int businessId,
  required int profileId,
  required DateTime startDt,
  required DateTime endDt,
  int? excludeApptId,
}) async {
  final data = await db
      .from('appointments')
      .select()
      .eq('business_id', businessId)
      .eq('assigned_to_profile_id', profileId)
      .neq('status', 'Cancelled')
      .lt('start_date_time', endDt.toUtc().toIso8601String())
      .gt('end_date_time', startDt.toUtc().toIso8601String());
  var list = List<Map<String, dynamic>>.from(data);
  if (excludeApptId != null) {
    list = list.where((a) => a['id'] != excludeApptId).toList();
  }
  return list;
}

Future<List<Map<String, dynamic>>> _findLeadConflicts({
  required SupabaseClient db,
  required int businessId,
  required int leadId,
  required DateTime startDt,
  required DateTime endDt,
  int? excludeApptId,
}) async {
  final data = await db
      .from('appointments')
      .select()
      .eq('business_id', businessId)
      .eq('lead_id', leadId)
      .neq('status', 'Cancelled')
      .lt('start_date_time', endDt.toUtc().toIso8601String())
      .gt('end_date_time', startDt.toUtc().toIso8601String());
  var list = List<Map<String, dynamic>>.from(data);
  if (excludeApptId != null) {
    list = list.where((a) => a['id'] != excludeApptId).toList();
  }
  return list;
}

// Returns the profile IDs of team members who have ANY overlapping,
// non-cancelled appointment (including Blocked Off Time) during the given
// window. Used to build the "pick someone else who's free" list.
Future<Set<int>> _findBusyProfileIds({
  required SupabaseClient db,
  required int businessId,
  required DateTime startDt,
  required DateTime endDt,
  int? excludeApptId,
}) async {
  final data = await db
      .from('appointments')
      .select('id, assigned_to_profile_id')
      .eq('business_id', businessId)
      .neq('status', 'Cancelled')
      .lt('start_date_time', endDt.toUtc().toIso8601String())
      .gt('end_date_time', startDt.toUtc().toIso8601String());
  final list = List<Map<String, dynamic>>.from(data);
  final busy = <int>{};
  for (final a in list) {
    if (excludeApptId != null && a['id'] == excludeApptId) continue;
    final pid = a['assigned_to_profile_id'];
    if (pid is int) busy.add(pid);
  }
  return busy;
}

// Computes real open slots (of at least `duration`) for one employee on the
// calendar day of `onDate`, using the given calendar's availability_hours
// (falling back to business-wide hours if the appointment has no calendar)
// minus that employee's existing busy blocks that day. Returns the start
// time of each open gap rather than every sub-slot within it.
Future<List<DateTime>> _findEmployeeOpenSlotStarts({
  required SupabaseClient db,
  required int businessId,
  required int profileId,
  required DateTime onDate,
  required Duration duration,
  Map<String, dynamic>? calendar,
  dynamic businessDefaultHours,
  int? excludeApptId,
}) async {
  const dayKeys = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday'];
  final dayKey = dayKeys[onDate.weekday - 1];

  final hoursSource = calendar?['availability_hours'] ?? businessDefaultHours;
  Map<String, dynamic>? dayHours;
  if (hoursSource != null) {
    final map = hoursSource is String ? jsonDecode(hoursSource) : hoursSource;
    if (map is Map && map[dayKey] is Map) dayHours = Map<String, dynamic>.from(map[dayKey]);
  }
  if (dayHours == null || dayHours['enabled'] != true) return [];

  int parseHour(String t) => int.tryParse(t.split(':')[0]) ?? 9;
  int parseMin(String t)  => int.tryParse(t.split(':')[1]) ?? 0;
  final windowStart = DateTime(onDate.year, onDate.month, onDate.day,
      parseHour(dayHours['start'] ?? '09:00'), parseMin(dayHours['start'] ?? '09:00'));
  final windowEnd = DateTime(onDate.year, onDate.month, onDate.day,
      parseHour(dayHours['end'] ?? '17:00'), parseMin(dayHours['end'] ?? '17:00'));
  if (!windowEnd.isAfter(windowStart)) return [];

  final dayStartUtc = DateTime(onDate.year, onDate.month, onDate.day).toUtc().toIso8601String();
  final dayEndUtc   = DateTime(onDate.year, onDate.month, onDate.day, 23, 59, 59).toUtc().toIso8601String();
  final data = await db
      .from('appointments')
      .select('id, start_date_time, end_date_time')
      .eq('business_id', businessId)
      .eq('assigned_to_profile_id', profileId)
      .neq('status', 'Cancelled')
      .gte('start_date_time', dayStartUtc)
      .lte('start_date_time', dayEndUtc);

  final busyList = List<Map<String, dynamic>>.from(data)
      .where((a) => excludeApptId == null || a['id'] != excludeApptId)
      .map((a) => MapEntry<DateTime, DateTime>(
            (DateTime.tryParse(a['start_date_time'] ?? '') ?? onDate).toLocal(),
            (DateTime.tryParse(a['end_date_time']   ?? '') ?? onDate).toLocal(),
          ))
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  final slots = <DateTime>[];
  var cursor = windowStart;
  for (final busy in busyList) {
    if (busy.key.isAfter(cursor) && busy.key.difference(cursor) >= duration) {
      slots.add(cursor);
    }
    if (busy.value.isAfter(cursor)) cursor = busy.value;
  }
  if (windowEnd.difference(cursor) >= duration) {
    slots.add(cursor);
  }
  return slots;
}

// ══════════════════════════════════════════════════════════════════════════════
//  EMPLOYEE CONFLICT DIALOG
// ══════════════════════════════════════════════════════════════════════════════

class _EmployeeConflictDialog extends StatefulWidget {
  final String employeeName;
  final List<Map<String, dynamic>> conflicts;
  final List<Map<String, dynamic>> teamMembers;
  final int businessId;
  final DateTime startDt;
  final DateTime endDt;
  final Map<String, dynamic>? calendar;
  final dynamic businessDefaultHours;
  final int? excludeApptId;
  final void Function(int profileId, String name) onPickEmployee;
  final void Function(DateTime start, DateTime end) onPickSlot;

  const _EmployeeConflictDialog({
    required this.employeeName,
    required this.conflicts,
    required this.teamMembers,
    required this.businessId,
    required this.startDt,
    required this.endDt,
    required this.onPickEmployee,
    required this.onPickSlot,
    this.calendar,
    this.businessDefaultHours,
    this.excludeApptId,
  });

  @override
  State<_EmployeeConflictDialog> createState() => _EmployeeConflictDialogState();
}

class _EmployeeConflictDialogState extends State<_EmployeeConflictDialog> {
  final _db = Supabase.instance.client;
  int _mode = 0; // 0 = choice, 1 = pick employee, 2 = pick time
  bool _loading = false;
  List<Map<String, dynamic>> _freeEmployees = [];
  List<DateTime> _openSlots = [];

  Future<void> _loadFreeEmployees() async {
    setState(() { _loading = true; _mode = 1; });
    try {
      final busy = await _findBusyProfileIds(
        db: _db, businessId: widget.businessId,
        startDt: widget.startDt, endDt: widget.endDt,
        excludeApptId: widget.excludeApptId,
      );
      _freeEmployees = widget.teamMembers.where((m) => !busy.contains(m['id'] as int)).toList();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadOpenSlots() async {
    setState(() { _loading = true; _mode = 2; });
    try {
      final profileId = widget.teamMembers.firstWhere(
        (m) => m['full_name'] == widget.employeeName, orElse: () => {})['id'] as int?;
      if (profileId == null) { _openSlots = []; return; }
      _openSlots = await _findEmployeeOpenSlotStarts(
        db: _db, businessId: widget.businessId, profileId: profileId,
        onDate: widget.startDt, duration: widget.endDt.difference(widget.startDt),
        calendar: widget.calendar, businessDefaultHours: widget.businessDefaultHours,
        excludeApptId: widget.excludeApptId,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmtTime(DateTime dt) {
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final conflict = widget.conflicts.first;
    final conflictStart = (DateTime.tryParse(conflict['start_date_time'] ?? '') ?? widget.startDt).toLocal();

    return Dialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 60, vertical: 100),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.event_busy, size: 20, color: AppTheme.error),
              const SizedBox(width: 10),
              const Expanded(child: Text('Scheduling Conflict',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary))),
              IconButton(
                onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                icon: const Icon(Icons.close, size: 18, color: AppTheme.textSecondary),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ]),
            const SizedBox(height: 12),
            Text(
              '${widget.employeeName} is already booked for "${conflict['appointment_name'] ?? 'an appointment'}" at ${_fmtTime(conflictStart)}.',
              style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            if (_mode == 0) ...[
              SizedBox(width: double.infinity, child: OutlinedButton(
                onPressed: _loadFreeEmployees,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Choose a Different Available Employee', style: TextStyle(color: AppTheme.textPrimary)),
              )),
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, child: OutlinedButton(
                onPressed: _loadOpenSlots,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppTheme.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text('Choose an Available Time for ${widget.employeeName}', style: const TextStyle(color: AppTheme.textPrimary)),
              )),
            ],
            if (_mode != 0) ...[
              if (_loading)
                const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: CircularProgressIndicator()))
              else if (_mode == 1) ...[
                if (_freeEmployees.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No other employees are free at this exact time.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)))
                else
                  Flexible(child: ListView(shrinkWrap: true, children: _freeEmployees.map((m) => Clickable(
                    onTap: () {
                      widget.onPickEmployee(m['id'] as int, m['full_name'] ?? 'Unknown');
                      Navigator.of(context, rootNavigator: true).pop();
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                      child: Text(m['full_name'] ?? 'Unknown', style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                    ),
                  )).toList())),
              ] else ...[
                if (_openSlots.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No open slots for this employee on this day.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)))
                else
                  Flexible(child: ListView(shrinkWrap: true, children: _openSlots.map((s) {
                    final duration = widget.endDt.difference(widget.startDt);
                    final end = s.add(duration);
                    return Clickable(
                      onTap: () {
                        widget.onPickSlot(s, end);
                        Navigator.of(context, rootNavigator: true).pop();
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
                        child: Text('${_fmtTime(s)} - ${_fmtTime(end)}', style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                      ),
                    );
                  }).toList())),
              ],
              const SizedBox(height: 8),
              TextButton(onPressed: () => setState(() => _mode = 0), child: const Text('Back')),
            ],
          ]),
        ),
      ),
    );
  }
}

class _LeadConflictDialog extends StatelessWidget {
  final String leadName;
  final List<Map<String, dynamic>> conflicts;

  const _LeadConflictDialog({required this.leadName, required this.conflicts});

  String _fmtTime(DateTime dt) {
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final conflict = conflicts.first;
    final conflictStart = (DateTime.tryParse(conflict['start_date_time'] ?? '') ?? DateTime.now()).toLocal();
    return AlertDialog(
      backgroundColor: AppTheme.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('Lead Already Scheduled',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
      content: Text(
        '$leadName already has an appointment "${conflict['appointment_name'] ?? 'an appointment'}" at ${_fmtTime(conflictStart)} that overlaps this time. Book this appointment anyway?',
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
          child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('Book Anyway'),
        ),
      ],
    );
  }
}

// ═══════════════ END OF PART 1 — continue with appt_part2.dart ═══════════════
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
  final dynamic businessDefaultHours;

  const _CalendarFormDialog({
    required this.businessId,
    required this.teamMembers,
    required this.onSaved,
    this.existing,
    this.preselectedType,
    this.businessDefaultHours,
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
  bool    _isPublic      = false;
  bool    _saving        = false;
  String? _error;
  Set<String> _selectedMemberIds = {};
  late final TextEditingController _bookingTitleCtrl;
  late final TextEditingController _bookingDescCtrl;

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
    _bookingTitleCtrl = TextEditingController();
    _bookingDescCtrl  = TextEditingController();

    if (widget.preselectedType != null && widget.existing == null) {
      _calType = widget.preselectedType!;
    }
    if (widget.existing == null && widget.businessDefaultHours != null) {
      final raw = widget.businessDefaultHours;
      final map = raw is String ? jsonDecode(raw) : raw;
      if (map is Map) {
        map.forEach((day, val) {
          if (_availability.containsKey(day) && val is Map) {
            _availability[day] = {
              'enabled': val['enabled'] ?? false,
              'start':   val['start']   ?? '09:00',
              'end':     val['end']     ?? '17:00',
            };
          }
        });
      }
    }
    if (widget.existing != null) {
      final e = widget.existing!;
      _nameCtrl.text         = e['name']                  ?? '';
      _descCtrl.text         = e['description']           ?? '';
      _bookingTitleCtrl.text = e['booking_page_title']    ?? '';
      _bookingDescCtrl.text  = e['booking_page_description'] ?? '';
      _calType               = e['calendar_type']         ?? 'personal';
      _duration              = e['duration_minutes'] as int? ?? 60;
      _isActive              = e['is_active']        as bool? ?? true;
      _isPublic              = e['is_public']        as bool? ?? false;
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
    _bookingTitleCtrl.dispose();
    _bookingDescCtrl.dispose();
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
        'business_id':              widget.businessId,
        'name':                     _nameCtrl.text.trim(),
        'description':              _descCtrl.text.trim(),
        'calendar_type':            _calType,
        'duration_minutes':         effectiveDuration,
        'availability_hours':       _availability,
        'team_member_ids':          _selectedMemberIds.toList(),
        'is_active':                _isActive,
        'is_public':                _isPublic,
        'booking_page_title':       _bookingTitleCtrl.text.trim(),
        'booking_page_description': _bookingDescCtrl.text.trim(),
        'updated_at':               DateTime.now().toIso8601String(),
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

              // Public Booking
              _label('Public Booking'),
              const SizedBox(height: 8),
              Row(children: [
                Switch(
                  value: _isPublic,
                  onChanged: (v) => setState(() => _isPublic = v),
                  activeColor: AppTheme.brand,
                ),
                const SizedBox(width: 8),
                const Text('Enable public booking page', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
              ]),
              if (_isPublic) ...[
                const SizedBox(height: 12),
                _label('Booking Page Title (optional)'),
                const SizedBox(height: 4),
                _textField(_bookingTitleCtrl, hint: 'e.g. Book a Free Roof Inspection'),
                const SizedBox(height: 12),
                _label('Booking Page Description (optional)'),
                const SizedBox(height: 4),
                _textField(_bookingDescCtrl, hint: 'e.g. Schedule your free inspection in under 2 minutes.', maxLines: 3),
              ],
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
  final List<Map<String, dynamic>> jobTypes;
  final int? businessId;
  final dynamic businessDefaultHours;
  final void Function(int? newApptId) onSaved;

  const _NewAppointmentDialog({
    required this.appointmentTypes,
    required this.appointmentStatuses,
    required this.teamMembers,
    required this.leads,
    required this.calendars,
    required this.jobTypes,
    required this.businessId,
    required this.onSaved,
    this.businessDefaultHours,
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
                jobTypes:            widget.jobTypes,
                businessId:          widget.businessId,
                businessDefaultHours: widget.businessDefaultHours,
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
  final List<Map<String, dynamic>> jobTypes;
  final int? businessId;
  final dynamic businessDefaultHours;
  final void Function(int? newApptId) onSaved;

  const _AppointmentFormTab({
    required this.appointmentTypes,
    required this.appointmentStatuses,
    required this.teamMembers,
    required this.leads,
    required this.calendars,
    required this.jobTypes,
    required this.businessId,
    required this.onSaved,
    this.businessDefaultHours,
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
  final _sourceCtrl     = TextEditingController();
  final _adminEmailCtrl = TextEditingController();

  String?  _calendarId;
  String   _type       = 'Consultation';
  String   _status     = 'New';
  String?  _teamMember;
  int?     _selectedJobTypeId;
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
    _sourceCtrl.dispose();
    _adminEmailCtrl.dispose();
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
      final leadAddress = (lead['lead_address'] ?? '').toString();
      if (_locationCtrl.text.trim().isEmpty && leadAddress.isNotEmpty) {
        _locationCtrl.text = leadAddress;
      }
      _showDropdown     = false;
    });
  }

  int? _teamMemberProfileId() {
    if (_teamMember == null) return null;
    final match = widget.teamMembers.firstWhere(
      (m) => m['full_name'] == _teamMember,
      orElse: () => {},
    );
    return match['id'] as int?;
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

  // Matches the typed Contact Name/Phone against existing leads for this
  // business, so typing a name without selecting it from the dropdown
  // doesn't silently create a second, disconnected copy of a contact's
  // info that only LOOKS the same in the UI. Phone match takes priority
  // over name match since phone is the more reliable identifier.
  Map<String, dynamic>? _findMatchingLead() {
    final typedName  = _contactCtrl.text.trim().toLowerCase();
    final typedPhone = _phoneCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
    if (typedName.isEmpty) return null;
    for (final lead in widget.leads) {
      final leadPhone = (lead['lead_phone'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
      if (typedPhone.length >= 10 && leadPhone.isNotEmpty && leadPhone == typedPhone) return lead;
    }
    for (final lead in widget.leads) {
      final leadName = (lead['lead_name'] ?? '').toString().trim().toLowerCase();
      if (leadName.isNotEmpty && leadName == typedName) return lead;
    }
    return null;
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Appointment title is required');
      return;
    }
    if (_phoneCtrl.text.trim().isNotEmpty && normalizeUsPhone(_phoneCtrl.text.trim()) == null) {
      setState(() => _error = 'Phone number must be a valid 10-digit US number');
      return;
    }
    if (_selectedLeadId == null) {
      final match = _findMatchingLead();
      if (match != null && mounted) {
        final useExisting = await showDialog<bool>(
          context: context,
          barrierColor: Colors.black54,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.cardBg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: const Text('Contact Already Exists',
                style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
            content: Text(
              'A contact named "${match['lead_name']}" already exists. Link this appointment to that contact instead of creating a separate, disconnected entry?',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
                child: const Text('Create Separate Entry', style: TextStyle(color: AppTheme.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Link to Existing'),
              ),
            ],
          ),
        );
        if (useExisting == true) {
          _selectLead(match);
        }
      }
    }
    if (_endDt.isBefore(_startDt)) {
      setState(() => _error = 'End time must be after start time');
      return;
    }
    if (widget.businessId != null && _teamMember != null) {
      final profileId = _teamMemberProfileId();
      if (profileId != null) {
        final conflicts = await _findEmployeeConflicts(
          db: _db, businessId: widget.businessId!, profileId: profileId,
          startDt: _startDt, endDt: _endDt,
        );
        if (conflicts.isNotEmpty && mounted) {
          Map<String, dynamic>? cal;
          if (_calendarId != null) {
            final match = widget.calendars.firstWhere((c) => c['id'].toString() == _calendarId, orElse: () => {});
            if (match.isNotEmpty) cal = match;
          }
          await showDialog<void>(
            context: context,
            barrierColor: Colors.black54,
            builder: (ctx) => _EmployeeConflictDialog(
              employeeName: _teamMember!,
              conflicts: conflicts,
              teamMembers: widget.teamMembers,
              businessId: widget.businessId!,
              startDt: _startDt,
              endDt: _endDt,
              calendar: cal,
              businessDefaultHours: widget.businessDefaultHours,
              onPickEmployee: (id, name) => setState(() => _teamMember = name),
              onPickSlot: (s, e) => setState(() { _startDt = s; _endDt = e; }),
            ),
          );
          return;
        }
      }
    }
    if (widget.businessId != null && _selectedLeadId != null) {
      final leadId = int.tryParse(_selectedLeadId!);
      if (leadId != null) {
        final leadConflicts = await _findLeadConflicts(
          db: _db, businessId: widget.businessId!, leadId: leadId,
          startDt: _startDt, endDt: _endDt,
        );
        if (leadConflicts.isNotEmpty && mounted) {
          final proceed = await showDialog<bool>(
            context: context,
            barrierColor: Colors.black54,
            builder: (ctx) => _LeadConflictDialog(
              leadName: _contactCtrl.text.trim().isEmpty ? 'This lead' : _contactCtrl.text.trim(),
              conflicts: leadConflicts,
            ),
          );
          if (proceed != true) return;
        }
      }
    }
    setState(() { _saving = true; _error = null; });
    try {
      final userId = _db.auth.currentUser?.id;

      // JG-17 write-through: if an existing lead was selected, any edits
      // made to name/phone/email on this form update that lead's real
      // record too, not just this new appointment's own copy — same
      // reasoning as the Edit Appointment sheet, so the two never diverge
      // from the moment this appointment is created.
      final normalizedPhone = _phoneCtrl.text.trim().isEmpty
          ? ''
          : (normalizeUsPhone(_phoneCtrl.text.trim()) ?? _phoneCtrl.text.trim());

      if (_selectedLeadId != null) {
        final leadId = int.tryParse(_selectedLeadId!);
        if (leadId != null) {
          try {
            await _db.from('leads').update({
              'lead_name':  _contactCtrl.text.trim(),
              'lead_phone': normalizedPhone,
              'lead_email': _emailCtrl.text.trim(),
            }).eq('id', leadId);
          } catch (e) {
            debugPrint('Write-through to lead error: $e');
          }
        }
      }

      final payload = {
        'appointment_name': _titleCtrl.text.trim(),
        'appointment_type': _type,
        'status':           _status,
        'start_date_time':  _startDt.toUtc().toIso8601String(),
        'end_date_time':    _endDt.toUtc().toIso8601String(),
        'location':         _locationCtrl.text.trim(),
        'lead_id':          _selectedLeadId != null ? int.tryParse(_selectedLeadId!) : null,
        'lead_name':        _contactCtrl.text.trim(),
        'lead_phone':       normalizedPhone,
        'lead_email':       _emailCtrl.text.trim(),
        'notes':            _notesCtrl.text.trim(),
        'booking_source':   _sourceCtrl.text.trim(),
        'admin_email':      _adminEmailCtrl.text.trim(),
        'business_id':      widget.businessId,
        'user_id':          userId,
        'confirmation_sent': false,
        'is_recurring':     false,
        if (_calendarId != null) 'calendar_id': int.tryParse(_calendarId!),
        if (_teamMember != null) 'assigned_to':  _teamMember,
        if (_teamMember != null) 'assigned_to_profile_id': _teamMemberProfileId(),
        if (_selectedJobTypeId != null) 'job_type': widget.jobTypes.firstWhere((j) => j['id'] == _selectedJobTypeId)['name'],
        if (_status.toLowerCase() == 'cancelled') 'canceled_at': DateTime.now().toUtc().toIso8601String(),
      };
      final newAppt = await _db.from('appointments').insert(payload).select().maybeSingle();

      // Auto-attach any job forms flagged for it on this business — mirrors
      // Jobber's "auto-attach to new jobs" toggle from Manage Job Forms.
      // Non-blocking: a failure here should never prevent the appointment
      // itself from being saved.
      final apptIdForAutoAttach = newAppt?['id'] as int?;
      if (apptIdForAutoAttach != null && widget.businessId != null) {
        try {
          final autoAttachForms = await _db
              .from('job_forms')
              .select('id')
              .eq('business_id', widget.businessId!)
              .eq('auto_attach_to_new_appointments', true)
              .eq('is_active', true)
              .filter('deleted_at', 'is', null);
          final autoAttachList = List<Map<String, dynamic>>.from(autoAttachForms);
          if (autoAttachList.isNotEmpty) {
            await _db.from('job_form_submissions').insert(autoAttachList.map((f) => {
              'business_id': widget.businessId,
              'job_form_id': f['id'],
              'appointment_id': apptIdForAutoAttach,
              'status': 'not_started',
            }).toList());
          }
        } catch (e) {
          debugPrint('Auto-attach job forms error: $e');
        }
      }

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
      final locationText = _locationCtrl.text.trim();
      if (locationText.isNotEmpty && newAppt?['id'] != null) {
        try {
          final token = _db.auth.currentSession?.accessToken;
          if (token != null) {
            await http.post(
              Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/geocode-location'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'appointment_id': newAppt!['id'],
                'address': locationText,
              }),
            );
          }
        } catch (e) {
          debugPrint('Geocode error: $e');
        }
      }
      widget.onSaved(newAppt?['id'] as int?);
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

        // Job Type
        if (widget.jobTypes.isNotEmpty) ...[
          _label('Job Type (optional)'),
          const SizedBox(height: 4),
          _dropdownWidget(
            items: ['None', ...widget.jobTypes.map((j) => j['name']?.toString() ?? 'Unnamed')],
            value: _selectedJobTypeId == null
                ? 'None'
                : widget.jobTypes.firstWhere(
                    (j) => j['id'] == _selectedJobTypeId,
                    orElse: () => {'name': 'None'},
                  )['name']?.toString() ?? 'None',
            onChanged: (v) {
              if (v == null || v == 'None') {
                setState(() => _selectedJobTypeId = null);
                return;
              }
              final match = widget.jobTypes.firstWhere((j) => j['name'] == v, orElse: () => {});
              setState(() => _selectedJobTypeId = match['id'] as int?);
            },
          ),
          const SizedBox(height: 14),
        ],

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
            _textField(_phoneCtrl, hint: '555-0100', keyboard: TextInputType.phone, inputFormatters: [PhoneNumberInputFormatter()]),
          ])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _label('Email'),
            const SizedBox(height: 4),
            _textField(_emailCtrl, hint: 'jane@example.com', keyboard: TextInputType.emailAddress),
          ])),
        ]),
        const SizedBox(height: 8),

        _label('Booking Source'),
        const SizedBox(height: 4),
        _textField(_sourceCtrl, hint: 'e.g. Website, Referral, Facebook...'),
        const SizedBox(height: 8),

        _label('Admin Email'),
        const SizedBox(height: 4),
        _textField(_adminEmailCtrl, hint: 'admin@yourbusiness.com', keyboard: TextInputType.emailAddress),
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

  Widget _textField(TextEditingController ctrl, {String? hint, TextInputType? keyboard, int maxLines = 1, List<TextInputFormatter>? inputFormatters}) {
    return TextField(
      controller: ctrl, keyboardType: keyboard, maxLines: maxLines, inputFormatters: inputFormatters,
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
  final void Function(int? newApptId) onSaved;

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
      widget.onSaved(null);
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
  final List<Map<String, dynamic>> calendars;
  final List<Map<String, dynamic>> teamMembers;
  final List<Map<String, dynamic>> jobTypes;
  final dynamic businessDefaultHours;
  final bool jobCostingEnabled;
  final bool laborCostEnabled;

  const _AppointmentDetailSheet({
    required this.appointment,
    required this.onUpdated,
    required this.appointmentStatuses,
    required this.colorFn,
    this.calendars = const [],
    this.teamMembers = const [],
    this.jobTypes = const [],
    this.businessDefaultHours,
    this.jobCostingEnabled = false,
    this.laborCostEnabled = false,
  });

  @override
  State<_AppointmentDetailSheet> createState() => _AppointmentDetailSheetState();
}

class _AppointmentDetailSheetState extends State<_AppointmentDetailSheet> {
  final _db = Supabase.instance.client;
  bool _saving = false;
  bool _deleting = false;

  Map<String, dynamic>? _activeTimeEntry;
  bool _loadingClock = false;
  bool _clockActionInProgress = false;
  Timer? _clockTimer;
  Duration _elapsed = Duration.zero;

  bool _sendingOnMyWay = false;
  String? _onMyWaySentAt;

  // Job Costs state
  List<Map<String, dynamic>> _jobExpenses = [];
  bool _loadingExpenses = false;
  bool _jobCostsSectionExpanded = true;
  String? _expenseError;

  // Labor Cost state (TS-07) — compensation-derived, so only ever shown to
  // viewers who can already manage pay rates, on top of the Pro plan gate.
  bool _canViewLaborCost = false;
  bool _loadingLaborCost = false;
  double? _laborCostTotal;
  List<Map<String, dynamic>> _laborCostBreakdown = [];
  bool _laborCostSectionExpanded = true;

  // Job Forms state
  List<Map<String, dynamic>> _attachedForms = [];
  List<Map<String, dynamic>> _availableJobForms = [];
  bool _loadingForms = false;
  bool _jobFormsSectionExpanded = true;

  late final TextEditingController _nameCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _leadNameCtrl;
  late final TextEditingController _leadPhoneCtrl;
  late final TextEditingController _leadEmailCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _sourceCtrl;
  late final TextEditingController _adminEmailCtrl;

  late String _status;
  late String _type;
  late DateTime _startDt;
  late DateTime _endDt;
  String? _calendarId;
  String? _assignedTo;
  String? _selectedJobType;

  static const _appointmentTypes = [
    'Consultation','Discovery Call','Demo','Strategy Session','Follow-Up',
    'Check-In','Onboarding','Renewal','Support Call','Sales Call',
    'Service Appointment','In-Person Meeting','Virtual Meeting','Round Robin',
    'Class / Event','Collective Meeting','Internal Meeting','Interview','Training','Other',
  ];

  @override
  void initState() {
    super.initState();
    final a = widget.appointment;
    _nameCtrl      = TextEditingController(text: a['appointment_name'] ?? '');
    _locationCtrl  = TextEditingController(text: a['location'] ?? '');
    _leadNameCtrl  = TextEditingController(text: a['lead_name'] ?? '');
    _leadPhoneCtrl = TextEditingController(text: a['lead_phone'] ?? '');
    _leadEmailCtrl = TextEditingController(text: a['lead_email'] ?? '');
    _notesCtrl     = TextEditingController(text: a['notes'] ?? '');
    _sourceCtrl    = TextEditingController(text: a['booking_source'] ?? '');
    _adminEmailCtrl = TextEditingController(text: a['admin_email'] ?? '');

    _status = a['status'] ?? 'New';
    if (!widget.appointmentStatuses.contains(_status)) {
      _status = widget.appointmentStatuses.first;
    }
    _type = a['appointment_type'] ?? 'Consultation';
    if (!_appointmentTypes.contains(_type)) _type = 'Consultation';

    final startRaw = DateTime.tryParse(a['start_date_time'] ?? '') ?? DateTime.now();
    final endRaw   = DateTime.tryParse(a['end_date_time']   ?? '') ?? DateTime.now();
    _startDt = startRaw.isUtc ? startRaw.toLocal() : startRaw;
    _endDt   = endRaw.isUtc   ? endRaw.toLocal()   : endRaw;

    _calendarId = a['calendar_id']?.toString();
    _assignedTo = a['assigned_to'] as String?;
    _selectedJobType = a['job_type'] as String?;
    _onMyWaySentAt = a['on_my_way_sent_at'] as String?;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadExpenses();
      _loadActiveTimeEntry();
      _loadAttachedForms();
      _loadAvailableJobForms();
      _checkLaborCostViewCapability().then((_) => _loadLaborCost());
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _locationCtrl.dispose();
    _leadNameCtrl.dispose();
    _leadPhoneCtrl.dispose();
    _leadEmailCtrl.dispose();
    _notesCtrl.dispose();
    _sourceCtrl.dispose();
    _adminEmailCtrl.dispose();
    _clockTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkLaborCostViewCapability() async {
    if (AppRouter.cachedIsSuperuser == true) {
      if (mounted) setState(() => _canViewLaborCost = true);
      return;
    }
    try {
      final userId = _db.auth.currentUser?.id;
      if (userId == null) return;
      final me = await _db
          .from('profiles')
          .select('role, permissions')
          .eq('user_id', userId)
          .maybeSingle();
      final role = me?['role'] as String? ?? 'member';
      final perms = Map<String, dynamic>.from((me?['permissions'] as Map?) ?? {});
      if (mounted) {
        setState(() {
          _canViewLaborCost = role == 'owner' || role == 'admin' || perms['manage_pay_rates'] == true;
        });
      }
    } catch (e) {
      debugPrint('Check labor cost capability error: $e');
    }
  }

  // Salaried employees have no hourly figure on file, so this approximates
  // one using a standard 2,080-hour work year (52 weeks x 40 hours) — the
  // same assumption most payroll tools default to. Flagged since it's an
  // approximation, not an exact figure.
  double? _hourlyEquivalent(String? payType, dynamic hourlyRate, dynamic annualSalary) {
    if (payType == 'salary') {
      final salary = (annualSalary as num?)?.toDouble();
      return salary == null ? null : salary / 2080.0;
    }
    return (hourlyRate as num?)?.toDouble();
  }

  String _fmtRateDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '—';
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }

  // Calculated on read, per TS-07's spec — never stored on time_entries,
  // since rates can change retroactively and a stored number would go
  // stale. For each tracked hour on this job, picks the pay_rate_history
  // row that was in effect on the day the hour was worked (falling back to
  // the profiles cache for rates set before TS-07 shipped), so the total
  // holds up correctly even if a customer questions the cost later.
  Future<void> _loadLaborCost() async {
    if (!widget.laborCostEnabled || !_canViewLaborCost) return;
    if (!mounted) return;
    setState(() => _loadingLaborCost = true);
    try {
      final apptId = widget.appointment['id'] as int;
      final entries = await _db
          .from('time_entries')
          .select('id, user_id, clocked_in_at, clocked_out_at, duration_minutes, status')
          .eq('appointment_id', apptId)
          .filter('deleted_at', 'is', null);
      final entryList = List<Map<String, dynamic>>.from(entries);
      if (entryList.isEmpty) {
        if (mounted) setState(() { _laborCostTotal = 0; _laborCostBreakdown = []; _loadingLaborCost = false; });
        return;
      }

      // time_entries.user_id is the login-identity uuid, but pay_rate_history
      // keys off profiles.id — resolve every worker on this job in one query.
      final userIds = entryList.map((e) => e['user_id']).whereType<String>().toSet().toList();
      final profiles = await _db
          .from('profiles')
          .select('id, user_id, pay_type, hourly_rate, annual_salary')
          .inFilter('user_id', userIds);
      final profileByUserId = {
        for (final p in List<Map<String, dynamic>>.from(profiles)) p['user_id'] as String: p,
      };
      final profileIds = profileByUserId.values.map((p) => p['id'] as int).toSet().toList();

      final history = profileIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await _db
              .from('pay_rate_history')
              .select('profile_id, pay_type, hourly_rate, annual_salary, effective_date, created_at')
              .inFilter('profile_id', profileIds)
              .filter('deleted_at', 'is', null)
              .order('effective_date', ascending: false)
              .order('created_at', ascending: false));

      ({double? rate, String? effectiveDate, bool isCurrent}) rateInfoFor(int profileId, DateTime onDate) {
        final dateOnly = DateTime(onDate.year, onDate.month, onDate.day);
        for (final h in history) {
          if (h['profile_id'] != profileId) continue;
          final eff = DateTime.tryParse(h['effective_date'] as String? ?? '');
          if (eff == null || eff.isAfter(dateOnly)) continue;
          return (
            rate: _hourlyEquivalent(h['pay_type'] as String?, h['hourly_rate'], h['annual_salary']),
            effectiveDate: h['effective_date'] as String?,
            isCurrent: false,
          );
        }
        final p = profileByUserId.values.firstWhere((p) => p['id'] == profileId, orElse: () => {});
        if (p.isEmpty) return (rate: null, effectiveDate: null, isCurrent: true);
        return (
          rate: _hourlyEquivalent(p['pay_type'] as String?, p['hourly_rate'], p['annual_salary']),
          effectiveDate: null,
          isCurrent: true,
        );
      }

      double total = 0;
      final breakdown = <Map<String, dynamic>>[];
      final now = DateTime.now().toUtc();
      for (final e in entryList) {
        final profile = profileByUserId[e['user_id']];
        if (profile == null) continue;
        final profileId = profile['id'] as int;
        final clockedIn = DateTime.tryParse(e['clocked_in_at'] as String? ?? '');
        if (clockedIn == null) continue;
        double minutes;
        if (e['status'] == 'active') {
          minutes = now.difference(clockedIn.toUtc()).inMinutes.toDouble();
        } else if (e['duration_minutes'] != null) {
          minutes = (e['duration_minutes'] as num).toDouble();
        } else {
          final clockedOut = DateTime.tryParse(e['clocked_out_at'] as String? ?? '');
          minutes = clockedOut == null ? 0 : clockedOut.toUtc().difference(clockedIn.toUtc()).inMinutes.toDouble();
        }
        final info = rateInfoFor(profileId, clockedIn);
        if (info.rate == null) continue;
        final hours = minutes / 60.0;
        final subtotal = hours * info.rate!;
        total += subtotal;

        final member = widget.teamMembers.firstWhere((m) => m['id'] == profileId, orElse: () => {});
        breakdown.add({
          'name': member['full_name'] as String? ?? 'Unknown',
          'hours': hours,
          'rate': info.rate,
          'subtotal': subtotal,
          'effective_date': info.effectiveDate,
          'is_current_rate': info.isCurrent,
        });
      }

      breakdown.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      if (mounted) setState(() {
        _laborCostTotal = total;
        _laborCostBreakdown = breakdown;
        _loadingLaborCost = false;
      });
    } catch (e) {
      debugPrint('Load labor cost error: $e');
      if (mounted) setState(() => _loadingLaborCost = false);
    }
  }

  Future<void> _loadExpenses() async {
    if (!mounted) return;
    setState(() => _loadingExpenses = true);
    try {
      final apptId = widget.appointment['id'] as int;
      final data = await _db
          .from('job_expenses')
          .select('*, expense_categories(id, name)')
          .eq('appointment_id', apptId)
          .filter('deleted_at', 'is', null)
          .order('logged_at', ascending: true);
      if (!mounted) return;
      setState(() => _jobExpenses = List<Map<String, dynamic>>.from(data));
    } catch (e) {
      debugPrint('Load expenses error: $e');
    } finally {
      if (mounted) setState(() => _loadingExpenses = false);
    }
  }

  // Mirrors job_form_fill_screen.dart's _missingRequiredLabels and the
  // same computation already used server-side in get-employee-hub-data
  // and get-checklists-report — required text/number/checkbox/select/photo
  // fields, required signature, required photo markers — kept in sync so
  // the appointment-completion guardrail below never disagrees with what
  // actually blocks Fill Screen completion or the badge shown elsewhere.
  Map<String, int> _countRequiredForForm(
    Map<String, dynamic>? form,
    Map<String, dynamic> sub,
    Map<String, int> markerPhotoCounts,
  ) {
    final fields = List<Map<String, dynamic>>.from(form?['fields'] as List? ?? []);
    final answers = Map<String, dynamic>.from(sub['answers'] as Map? ?? {});
    var total = 0;
    var missing = 0;

    for (final f in fields) {
      if (f['required'] != true) continue;
      total++;
      final val = answers[f['id']];
      bool filled;
      if (f['type'] == 'checkbox') {
        filled = val == true;
      } else if (f['type'] == 'photo') {
        filled = (val as List?)?.isNotEmpty == true;
      } else {
        filled = val != null && val.toString().trim().isNotEmpty;
      }
      if (!filled) missing++;
    }

    if (form?['requires_signature'] == true) {
      total++;
      if (sub['signature_url'] == null) missing++;
    }

    final markers = List<Map<String, dynamic>>.from(form?['photo_attachment_markers'] as List? ?? []);
    for (final m in markers) {
      if (m['required'] != true) continue;
      total++;
      final count = markerPhotoCounts['${sub['id']}:${m['id']}'] ?? 0;
      if (count == 0) missing++;
    }

    return {'total': total, 'missing': missing};
  }

  Future<void> _loadAttachedForms() async {
    if (!mounted) return;
    setState(() => _loadingForms = true);
    try {
      final apptId = widget.appointment['id'] as int;
      final subs = await _db
          .from('job_form_submissions')
          .select('id, status, job_form_id, submission_label, answers, signature_url')
          .eq('appointment_id', apptId)
          .filter('deleted_at', 'is', null)
          .order('created_at', ascending: true);
      final subsList = List<Map<String, dynamic>>.from(subs);

      if (subsList.isEmpty) {
        if (!mounted) return;
        setState(() => _attachedForms = []);
        return;
      }

      final formIds = subsList.map((s) => s['job_form_id']).whereType<int>().toSet().toList();
      final forms = await _db
          .from('job_forms')
          .select('id, name, fields, requires_signature, photo_attachment_markers')
          .inFilter('id', formIds);
      final formsById = {for (final f in List<Map<String, dynamic>>.from(forms)) f['id']: f};

      final subIds = subsList.map((s) => s['id']).toList();
      final markerPhotos = await _db
          .from('job_form_photo_attachments')
          .select('submission_id, marker_id')
          .inFilter('submission_id', subIds)
          .filter('deleted_at', 'is', null);
      final markerPhotoCounts = <String, int>{};
      for (final p in List<Map<String, dynamic>>.from(markerPhotos)) {
        final key = '${p['submission_id']}:${p['marker_id']}';
        markerPhotoCounts[key] = (markerPhotoCounts[key] ?? 0) + 1;
      }

      final merged = subsList.map((s) {
        final form = formsById[s['job_form_id']];
        final counts = _countRequiredForForm(form, s, markerPhotoCounts);
        return {
          ...s,
          'form_name': form?['name'] ?? 'Unknown Form',
          'submission_label': s['submission_label'],
          'total_required': counts['total'],
          'missing_required': s['status'] == 'completed' ? 0 : counts['missing'],
        };
      }).toList();

      if (!mounted) return;
      setState(() => _attachedForms = merged);
    } catch (e) {
      debugPrint('Load attached forms error: $e');
    } finally {
      if (mounted) setState(() => _loadingForms = false);
    }
  }

  Future<void> _loadAvailableJobForms() async {
    try {
      final businessId = widget.appointment['business_id'];
      if (businessId == null) return;
      final data = await _db
          .from('job_forms')
          .select('id, name')
          .eq('business_id', businessId)
          .filter('deleted_at', 'is', null)
          .order('name', ascending: true);
      if (!mounted) return;
      setState(() => _availableJobForms = List<Map<String, dynamic>>.from(data));
    } catch (e) {
      debugPrint('Load available job forms error: $e');
    }
  }

  Future<void> _attachForm(int jobFormId) async {
    try {
      final apptId = widget.appointment['id'] as int;
      final businessId = widget.appointment['business_id'];
      await _db.from('job_form_submissions').insert({
        'business_id': businessId,
        'job_form_id': jobFormId,
        'appointment_id': apptId,
        'status': 'not_started',
      });
      await _loadAttachedForms();
    } catch (e) {
      debugPrint('Attach form error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to attach form: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _detachForm(int submissionId) async {
    try {
      await _db
          .from('job_form_submissions')
          .update({
            'deleted_at': DateTime.now().toUtc().toIso8601String(),
            'appointment_id': null,
          })
          .eq('id', submissionId);
      await _loadAttachedForms();
    } catch (e) {
      debugPrint('Detach form error: $e');
    }
  }

  void _openCompletedFormViewer(int submissionId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => OfficeJobFormViewerSheet(
        submissionId: submissionId,
        businessId: widget.appointment['business_id'] as int?,
        onSent: _loadAttachedForms,
      ),
    );
  }

  void _showAttachFormSheet(BuildContext context) {
    // No filtering by prior attachment at all — the same form can be
    // attached to the same appointment any number of times. Techs
    // distinguish duplicates using submission_label. No DB uniqueness
    // constraint exists on job_form_submissions to conflict with this.
    final unattached = _availableJobForms;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          const Text('Attach Job Form',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 16),
          if (unattached.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('No more job forms to attach — either none exist yet or all are already attached.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            )
          else
            ...unattached.map((form) => Clickable(
              onTap: () {
                Navigator.pop(context);
                _attachForm(form['id'] as int);
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Row(children: [
                  const Icon(Icons.assignment_outlined, size: 16, color: AppTheme.brand),
                  const SizedBox(width: 10),
                  Expanded(child: Text(form['name'] ?? '',
                      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
                  const Icon(Icons.add_circle_outline, size: 16, color: AppTheme.textSecondary),
                ]),
              ),
            )),
        ]),
      ),
    );
  }

  String _formStatusLabel(String status) => switch (status) {
        'not_started' => 'Not Started',
        'in_progress' => 'In Progress',
        'completed' => 'Completed',
        _ => status,
      };

  Color _formStatusColor(String status) => switch (status) {
        'not_started' => AppTheme.textSecondary,
        'in_progress' => const Color(0xFFF59E0B),
        'completed' => AppTheme.success,
        _ => AppTheme.textSecondary,
      };

  Future<void> _loadActiveTimeEntry() async {
    if (!mounted) return;
    setState(() => _loadingClock = true);
    try {
      final userId = _db.auth.currentUser?.id;
      if (userId == null) return;
      final entry = await _db
          .from('time_entries')
          .select()
          .eq('user_id', userId)
          .eq('status', 'active')
          .filter('deleted_at', 'is', null)
          .maybeSingle();
      if (!mounted) return;
      setState(() => _activeTimeEntry = entry);
      _startOrStopTicker();
    } catch (e) {
      debugPrint('Load active time entry error: $e');
    } finally {
      if (mounted) setState(() => _loadingClock = false);
    }
  }

  void _startOrStopTicker() {
    _clockTimer?.cancel();
    if (_activeTimeEntry == null) return;
    final clockedInAt = DateTime.tryParse(_activeTimeEntry!['clocked_in_at'] ?? '');
    if (clockedInAt == null) return;
    void tick() {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().toUtc().difference(clockedInAt.toUtc()));
    }
    tick();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<Position?> _getLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }
      if (permission == LocationPermission.deniedForever) return null;
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      debugPrint('Location error: $e');
      return null;
    }
  }

  Future<void> _toggleClock() async {
    setState(() => _clockActionInProgress = true);
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');
      final action = _activeTimeEntry == null ? 'clock_in' : 'clock_out';
      final position = await _getLocation();
      final body = <String, dynamic>{'action': action};
      if (action == 'clock_in') {
        body['appointment_id'] = widget.appointment['id'];
      }
      if (position != null) {
        body['lat'] = position.latitude;
        body['lng'] = position.longitude;
      }
      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/clock-in-out'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      final data = jsonDecode(resp.body);
      if (!mounted) return;
      if (resp.statusCode != 200 || data['success'] != true) {
        final errCode = data['error'] as String?;
        if (errCode == 'location_required') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Location is required by your business. Please allow location access and try again.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['error'] ?? 'Clock action failed'), backgroundColor: Colors.red),
        );
        return;
      }
      _clockTimer?.cancel();
      setState(() {
        _activeTimeEntry = action == 'clock_in' ? data['entry'] : null;
        _elapsed = Duration.zero;
      });
      _startOrStopTicker();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _clockActionInProgress = false);
    }
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Future<void> _sendOnMyWay() async {
    setState(() => _sendingOnMyWay = true);
    try {
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');
      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/send-on-my-way-sms'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'appointment_id': widget.appointment['id']}),
      );
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode == 200 && data['success'] == true) {
        setState(() => _onMyWaySentAt = data['sent_at'] as String?);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Text sent to ${_leadNameCtrl.text.trim().isEmpty ? 'customer' : _leadNameCtrl.text.trim()}')),
        );
        return;
      }
      if (resp.statusCode == 409 && data['error'] == 'already_sent') {
        setState(() => _onMyWaySentAt = data['sent_at'] as String?);
        return;
      }
      if (resp.statusCode == 403 && data['error'] == 'upgrade_required') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['message'] ?? 'This feature requires the Growth plan.'), backgroundColor: Colors.orange),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(data['error'] ?? 'Failed to send text'), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingOnMyWay = false);
    }
  }

  Future<void> _softDeleteExpense(int expenseId) async {
    try {
      await _db
          .from('job_expenses')
          .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', expenseId);
      await _loadExpenses();
    } catch (e) {
      debugPrint('Delete expense error: $e');
    }
  }

  void _showAddExpenseSheet(BuildContext context, {Map<String, dynamic>? existing}) {
    final apptId = widget.appointment['id'] as int;
    final businessId = widget.appointment['business_id'] as int?;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddExpenseSheet(
        appointmentId: apptId,
        businessId: businessId,
        existing: existing,
        onSaved: () {
          Navigator.pop(context);
          _loadExpenses();
        },
      ),
    );
  }

  // Soft warning, matching Jobber's own confirmed behavior: a visit can
  // still be marked complete with an unfinished checklist — the person
  // just gets a chance to go back first. Only fires when status is
  // actually changing TO Completed (not on every save of an
  // already-completed appointment), and only for forms that have
  // required fields still missing — an attached-but-optional form never
  // blocks anything.
  Future<bool> _confirmCompleteWithIncompleteFormsIfNeeded() async {
    final prevStatus = (widget.appointment['status'] ?? '').toString().toLowerCase();
    final newStatus = _status.toLowerCase();
    if (newStatus != 'completed' || prevStatus == newStatus) return true;

    final incomplete = _attachedForms.where((f) => (f['missing_required'] as int? ?? 0) > 0).toList();
    if (incomplete.isEmpty) return true;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Job Form Not Finished',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              incomplete.length == 1
                  ? 'This appointment has a job form that isn\'t finished yet:'
                  : 'This appointment has ${incomplete.length} job forms that aren\'t finished yet:',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 10),
            ...incomplete.map((f) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• ${f['form_name']} — ${(f['total_required'] as int) - (f['missing_required'] as int)} of ${f['total_required']} required',
                    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                  ),
                )),
            const SizedBox(height: 10),
            const Text(
              'You can go back and finish it, or complete the appointment anyway and leave it unfinished.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
            child: const Text('Go Back', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Complete Anyway'),
          ),
        ],
      ),
    );
    return proceed == true;
  }

  Future<void> _save() async {
    if (_leadPhoneCtrl.text.trim().isNotEmpty && normalizeUsPhone(_leadPhoneCtrl.text.trim()) == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Phone number must be a valid 10-digit US number'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    final shouldProceed = await _confirmCompleteWithIncompleteFormsIfNeeded();
    if (!shouldProceed) return;

    final apptId = widget.appointment['id'] as int?;
    final businessIdForConflict = widget.appointment['business_id'] as int?;

    if (businessIdForConflict != null && _assignedTo != null) {
      final profileId = _assignedToProfileId();
      if (profileId != null) {
        final conflicts = await _findEmployeeConflicts(
          db: _db, businessId: businessIdForConflict, profileId: profileId,
          startDt: _startDt, endDt: _endDt, excludeApptId: apptId,
        );
        if (conflicts.isNotEmpty && mounted) {
          Map<String, dynamic>? cal;
          if (_calendarId != null) {
            final match = widget.calendars.firstWhere((c) => c['id'].toString() == _calendarId, orElse: () => {});
            if (match.isNotEmpty) cal = match;
          }
          await showDialog<void>(
            context: context,
            barrierColor: Colors.black54,
            builder: (ctx) => _EmployeeConflictDialog(
              employeeName: _assignedTo!,
              conflicts: conflicts,
              teamMembers: widget.teamMembers,
              businessId: businessIdForConflict,
              startDt: _startDt,
              endDt: _endDt,
              calendar: cal,
              businessDefaultHours: widget.businessDefaultHours,
              excludeApptId: apptId,
              onPickEmployee: (id, name) => setState(() => _assignedTo = name),
              onPickSlot: (s, e) => setState(() { _startDt = s; _endDt = e; }),
            ),
          );
          return;
        }
      }
    }

    final leadId = widget.appointment['lead_id'] as int?;
    if (businessIdForConflict != null && leadId != null) {
      final leadConflicts = await _findLeadConflicts(
        db: _db, businessId: businessIdForConflict, leadId: leadId,
        startDt: _startDt, endDt: _endDt, excludeApptId: apptId,
      );
      if (leadConflicts.isNotEmpty && mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          barrierColor: Colors.black54,
          builder: (ctx) => _LeadConflictDialog(
            leadName: _leadNameCtrl.text.trim().isEmpty ? 'This lead' : _leadNameCtrl.text.trim(),
            conflicts: leadConflicts,
          ),
        );
        if (proceed != true) return;
      }
    }

    setState(() => _saving = true);
    try {
      // canceled_at is the real system-of-record for cancellation (not the
      // status string alone) — Late Appointments logic on the Jobs Overview
      // page relies on this being set/cleared in sync with Cancelled status.
      final wasCancelled = (widget.appointment['status'] ?? '').toString().toLowerCase() == 'cancelled';
      final isCancelled  = _status.toLowerCase() == 'cancelled';

      // JG-17 write-through: when this appointment has a linked lead, the
      // phone/name/email fields edited here are the actual contact record,
      // not just this appointment's own copy — write them to leads first so
      // there is never a case where editing here silently diverges from the
      // live contact (the bug that caused a stale phone number on the "On My
      // Way" text tonight). appointments.lead_name/phone/email still get
      // updated too, right alongside, so the frozen fallback captured by
      // appointment_contact_info stays reasonably fresh if this lead is ever
      // deleted later — it's just no longer the only writable copy.
      final normalizedPhone = _leadPhoneCtrl.text.trim().isEmpty
          ? ''
          : (normalizeUsPhone(_leadPhoneCtrl.text.trim()) ?? _leadPhoneCtrl.text.trim());

      final leadId = widget.appointment['lead_id'] as int?;
      if (leadId != null) {
        try {
          await _db.from('leads').update({
            'lead_name':  _leadNameCtrl.text.trim(),
            'lead_phone': normalizedPhone,
            'lead_email': _leadEmailCtrl.text.trim(),
          }).eq('id', leadId);
        } catch (e) {
          debugPrint('Write-through to lead error: $e');
        }
      }

      await _db.from('appointments').update({
        'appointment_name': _nameCtrl.text.trim(),
        'appointment_type': _type,
        'status':           _status,
        'start_date_time':  _startDt.toUtc().toIso8601String(),
        'end_date_time':    _endDt.toUtc().toIso8601String(),
        'location':         _locationCtrl.text.trim(),
        'lead_name':        _leadNameCtrl.text.trim(),
        'lead_phone':       normalizedPhone,
        'lead_email':       _leadEmailCtrl.text.trim(),
        'notes':            _notesCtrl.text.trim(),
        'booking_source':   _sourceCtrl.text.trim(),
        'admin_email':      _adminEmailCtrl.text.trim(),
        if (_calendarId != null) 'calendar_id': int.tryParse(_calendarId!),
        'assigned_to': _assignedTo,
        'assigned_to_profile_id': _assignedToProfileId(),
        'job_type': _selectedJobType,
        if (isCancelled && !wasCancelled) 'canceled_at': DateTime.now().toUtc().toIso8601String(),
        if (!isCancelled && wasCancelled) 'canceled_at': null,
      }).eq('id', widget.appointment['id']);

      // Fire appointment_completed automation trigger
      final prevStatus = (widget.appointment['status'] ?? '').toString().toLowerCase();
      final newStatus  = _status.toLowerCase();
      if (newStatus == 'completed') {
        if (prevStatus != newStatus) {
          try {
            final businessId = widget.appointment['business_id'];
            await http.post(
              Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/run-automation'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'trigger_type': 'appointment_completed',
                'business_id':  businessId,
                'payload': {
                  'appointment_id':   widget.appointment['id'],
                  'appointment_name': _nameCtrl.text.trim(),
                  'lead_name':        _leadNameCtrl.text.trim(),
                  'lead_phone':       _leadPhoneCtrl.text.trim(),
                  'lead_email':       _leadEmailCtrl.text.trim(),
                  'phone':            _leadPhoneCtrl.text.trim(),
                },
              }),
            );
          } catch (e) {
            debugPrint('Review request automation error: $e');
          }
        }
      }

      final locationText = _locationCtrl.text.trim();
      if (locationText.isNotEmpty) {
        try {
          final token = _db.auth.currentSession?.accessToken;
          if (token != null) {
            await http.post(
              Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/geocode-location'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'appointment_id': widget.appointment['id'],
                'address': locationText,
              }),
            );
          }
        } catch (e) {
          debugPrint('Geocode error: $e');
        }
      }

      widget.onUpdated();
    } catch (e) {
      debugPrint('Save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_attachedForms.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cannot Delete Appointment'),
          content: Text(
            'This appointment has ${_attachedForms.length} attached job form${_attachedForms.length == 1 ? '' : 's'}. '
            'Remove ${_attachedForms.length == 1 ? 'it' : 'them'} from the Job Forms section below before deleting this appointment.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    bool confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Appointment'),
        content: const Text('Are you sure you want to delete this appointment?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () { confirmed = true; Navigator.of(ctx, rootNavigator: true).pop(); },
            child: const Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      await _db.from('appointments').delete().eq('id', widget.appointment['id']);
      if (!mounted) return;
      widget.onUpdated();
    } catch (e) {
      debugPrint('Delete appointment error: $e');
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete: $e'), backgroundColor: AppTheme.error),
      );
    }
  }

  int? _assignedToProfileId() {
    if (_assignedTo == null) return null;
    final match = widget.teamMembers.firstWhere(
      (m) => m['full_name'] == _assignedTo,
      orElse: () => {},
    );
    return match['id'] as int?;
  }

  Future<void> _pickDateTime(bool isStart) async {
    final initial = isStart ? _startDt : _endDt;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
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

  @override
  Widget build(BuildContext context) {
    final blocked = (widget.appointment['appointment_type'] ?? '').toString().toLowerCase() == 'blocked' ||
                    (widget.appointment['status'] ?? '').toString().toLowerCase() == 'blocked';

    final calItems = widget.calendars.isEmpty
        ? <String>[]
        : widget.calendars.map((c) => c['name']?.toString() ?? 'Unnamed').toList();
    final calValue = widget.calendars.isEmpty ? null
        : widget.calendars.where((c) => c['id'].toString() == _calendarId).map((c) => c['name']?.toString()).firstOrNull
          ?? (calItems.isNotEmpty ? calItems.first : null);

    final memberItems = ['Unassigned', ...widget.teamMembers.map((m) => m['full_name']?.toString() ?? 'Unknown')];
    final memberValue = _assignedTo != null && memberItems.contains(_assignedTo) ? _assignedTo! : 'Unassigned';

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Drag handle
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),

          // Header
          Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: blocked ? const Color(0xFF94a3b8).withValues(alpha: 0.15) : AppTheme.brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(blocked ? Icons.block : Icons.edit_calendar_outlined,
                  color: blocked ? const Color(0xFF94a3b8) : AppTheme.brand, size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('Edit Appointment',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
            IconButton(
              onPressed: _deleting ? null : _delete,
              icon: _deleting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red))
                  : const Icon(Icons.delete_outline, size: 18, color: AppTheme.error),
            ),
          ]),
          const SizedBox(height: 20),

          // ── Clock In / Out ───────────────────────────────────────────
          if (!blocked) ...[
            _buildClockSection(),
            const SizedBox(height: 12),
            _buildOnMyWaySection(),
            const SizedBox(height: 12),
            _buildCheckInSection(),
            const SizedBox(height: 20),
          ],

          // ── Appointment Info ──────────────────────────────────────────
          _sectionLabel('Appointment Info'),
          const SizedBox(height: 8),
          _field('Title', _nameCtrl),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _dropdownField(
              label: 'Type',
              value: _type,
              items: _appointmentTypes,
              onChanged: (v) => setState(() => _type = v!),
            )),
            const SizedBox(width: 12),
            Expanded(child: _dropdownField(
              label: 'Status',
              value: _status,
              items: widget.appointmentStatuses,
              onChanged: (v) => setState(() => _status = v!),
            )),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _dateTimeField('Start', _startDt, () => _pickDateTime(true))),
            const SizedBox(width: 12),
            Expanded(child: _dateTimeField('End', _endDt, () => _pickDateTime(false))),
          ]),
          const SizedBox(height: 10),
          _field('Location', _locationCtrl, hint: 'Office, Zoom, Phone...'),

          if (calItems.isNotEmpty) ...[
            const SizedBox(height: 10),
            _dropdownField(
              label: 'Calendar',
              value: calValue ?? calItems.first,
              items: calItems,
              onChanged: (v) {
                final match = widget.calendars.firstWhere((c) => c['name'] == v, orElse: () => widget.calendars.first);
                setState(() => _calendarId = match['id'].toString());
              },
            ),
          ],

          if (widget.jobTypes.isNotEmpty) ...[
            const SizedBox(height: 10),
            _dropdownField(
              label: 'Job Type',
              value: (_selectedJobType != null &&
                      widget.jobTypes.any((j) => j['name'] == _selectedJobType))
                  ? _selectedJobType!
                  : 'None',
              items: ['None', ...widget.jobTypes.map((j) => j['name']?.toString() ?? 'Unnamed')],
              onChanged: (v) => setState(() => _selectedJobType = (v == 'None') ? null : v),
            ),
          ],

          if (widget.teamMembers.isNotEmpty) ...[
            const SizedBox(height: 10),
            _dropdownField(
              label: 'Assigned To',
              value: memberValue,
              items: memberItems,
              onChanged: (v) => setState(() => _assignedTo = v == 'Unassigned' ? null : v),
            ),
          ],

          const SizedBox(height: 20),

          // ── Contact Info ──────────────────────────────────────────────
          if (!blocked) ...[
            _sectionLabel('Contact Info'),
            const SizedBox(height: 8),
            _field('Contact Name', _leadNameCtrl),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _field('Phone', _leadPhoneCtrl, hint: '555-0100', keyboard: TextInputType.phone, inputFormatters: [PhoneNumberInputFormatter()])),
              const SizedBox(width: 12),
              Expanded(child: _field('Email', _leadEmailCtrl, hint: 'jane@example.com', keyboard: TextInputType.emailAddress)),
            ]),
            const SizedBox(height: 10),
            _field('Booking Source', _sourceCtrl, hint: 'e.g. Website, Referral, Facebook...'),
            const SizedBox(height: 10),
            _field('Admin Email', _adminEmailCtrl, hint: 'admin@yourbusiness.com', keyboard: TextInputType.emailAddress),
            const SizedBox(height: 20),
          ],

          // ── Notes ─────────────────────────────────────────────────────
          _sectionLabel('Notes'),
          const SizedBox(height: 8),
          _field('Notes', _notesCtrl, hint: 'Any notes...', maxLines: 3),
          const SizedBox(height: 24),

          // ── Job Costs ─────────────────────────────────────────────────
          if (!blocked) _buildJobCostsSection(context),
          if (!blocked) const SizedBox(height: 24),

          // ── Labor Cost ────────────────────────────────────────────────
          if (!blocked && _canViewLaborCost) _buildLaborCostSection(context),
          if (!blocked && _canViewLaborCost) const SizedBox(height: 24),

          // ── Job Forms ─────────────────────────────────────────────────
          if (!blocked) _buildJobFormsSection(context),
          if (!blocked) const SizedBox(height: 24),

          // ── Save button ───────────────────────────────────────────────
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
                  : const Text('Save Changes', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildClockSection() {
    final isClockedIn = _activeTimeEntry != null;
    final isClockedInToThis = isClockedIn &&
        _activeTimeEntry!['appointment_id']?.toString() == widget.appointment['id']?.toString();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isClockedIn ? AppTheme.success.withValues(alpha: 0.06) : AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isClockedIn ? AppTheme.success.withValues(alpha: 0.3) : AppTheme.borderColor),
      ),
      child: Row(children: [
        Icon(isClockedIn ? Icons.timer : Icons.timer_outlined,
            size: 18, color: isClockedIn ? AppTheme.success : AppTheme.textSecondary),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            _loadingClock
                ? 'Checking status...'
                : isClockedIn
                    ? (isClockedInToThis ? 'Clocked in on this job' : 'Clocked in on another job')
                    : 'Not clocked in',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: isClockedIn ? AppTheme.success : AppTheme.textPrimary),
          ),
          if (isClockedIn)
            Text(_formatElapsed(_elapsed), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        SizedBox(
          height: 34,
          child: ElevatedButton(
            onPressed: (_loadingClock || _clockActionInProgress) ? null : _toggleClock,
            style: ElevatedButton.styleFrom(
              backgroundColor: isClockedIn ? AppTheme.error : AppTheme.brand,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: _clockActionInProgress
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(isClockedIn ? 'Clock Out' : 'Clock In', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }

  Widget _buildCheckInSection() {
    final checkedInAtRaw = widget.appointment['checked_in_at'] as String?;
    final checkedInAt = checkedInAtRaw != null ? DateTime.tryParse(checkedInAtRaw)?.toLocal() : null;
    final address = _locationCtrl.text.trim();

    String timeStr(DateTime dt) {
      final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: checkedInAt != null ? AppTheme.success.withValues(alpha: 0.06) : AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: checkedInAt != null ? AppTheme.success.withValues(alpha: 0.3) : AppTheme.borderColor),
      ),
      child: Row(children: [
        Icon(Icons.location_on_outlined,
            size: 18, color: checkedInAt != null ? AppTheme.success : AppTheme.textSecondary),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            checkedInAt != null ? 'Tech checked in at ${timeStr(checkedInAt)}' : 'Not checked in yet',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: checkedInAt != null ? AppTheme.success : AppTheme.textPrimary),
          ),
          if (checkedInAt != null && address.isNotEmpty)
            Text(address, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
      ]),
    );
  }

  Widget _buildOnMyWaySection() {
    final hasPhone = _leadPhoneCtrl.text.trim().isNotEmpty;
    final alreadySent = _onMyWaySentAt != null;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: alreadySent ? AppTheme.success.withValues(alpha: 0.06) : AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: alreadySent ? AppTheme.success.withValues(alpha: 0.3) : AppTheme.borderColor),
      ),
      child: Row(children: [
        Icon(Icons.directions_car_filled_outlined,
            size: 18, color: alreadySent ? AppTheme.success : AppTheme.textSecondary),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            alreadySent ? 'On My Way text sent' : "Let the customer know you're on the way",
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: alreadySent ? AppTheme.success : AppTheme.textPrimary),
          ),
          if (!hasPhone)
            const Text('No phone number on file', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
        SizedBox(
          height: 34,
          child: ElevatedButton(
            onPressed: (!hasPhone || _sendingOnMyWay) ? null : _sendOnMyWay,
            style: ElevatedButton.styleFrom(
              backgroundColor: alreadySent ? AppTheme.borderColor : AppTheme.brand,
              foregroundColor: alreadySent ? AppTheme.textSecondary : Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: _sendingOnMyWay
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(alreadySent ? 'Sent' : 'On My Way', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }

  Widget _buildJobCostsSection(BuildContext context) {
    final totalCents = _jobExpenses.fold<int>(0, (s, e) => s + ((e['amount_cents'] as int?) ?? 0));
    final totalDollars = totalCents / 100.0;
    const categoryColor = Color(0xFF6366F1);

    if (!widget.jobCostingEnabled) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('JOB COSTS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
            color: AppTheme.textSecondary, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.lock_outline, size: 16, color: AppTheme.brand),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Job Costing is a Growth plan feature',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
              const SizedBox(height: 2),
              const Text('Track fuel, materials, and other job expenses.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ])),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => context.go('/settings?section=billing'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.brand,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('Upgrade', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
              ),
            ),
          ]),
        ),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header row
      Row(children: [
        Expanded(child: GestureDetector(
          onTap: () => setState(() => _jobCostsSectionExpanded = !_jobCostsSectionExpanded),
          child: Row(children: [
            const Text('JOB COSTS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary, letterSpacing: 0.5)),
            const SizedBox(width: 6),
            Icon(_jobCostsSectionExpanded ? Icons.expand_less : Icons.expand_more,
                size: 16, color: AppTheme.textSecondary),
          ]),
        )),
        if (totalCents > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text('\$${totalDollars.toStringAsFixed(2)} total',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.brand)),
          ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _showAddExpenseSheet(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.brand,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add, size: 12, color: Colors.white),
              SizedBox(width: 4),
              Text('Add', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
            ]),
          ),
        ),
      ]),
      const SizedBox(height: 8),

      if (_jobCostsSectionExpanded) ...[
        if (_loadingExpenses)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))),
          )
        else if (_jobExpenses.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: const Row(children: [
              Icon(Icons.receipt_long_outlined, size: 16, color: AppTheme.textMuted),
              SizedBox(width: 8),
              Text('No expenses logged yet',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Column(children: [
              ..._jobExpenses.asMap().entries.map((entry) {
                final i = entry.key;
                final exp = entry.value;
                final cents = (exp['amount_cents'] as int?) ?? 0;
                final dollars = cents / 100.0;
                final category = exp['expense_categories'] as Map<String, dynamic>?;
                final label = category?['name'] as String? ?? 'Other';
                final desc = exp['description'] as String? ?? '';
                final billable = exp['billable'] as bool? ?? true;
                final hasReceipt = (exp['receipt_photo_path'] as String?)?.isNotEmpty == true;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: i < _jobExpenses.length - 1
                        ? const Border(bottom: BorderSide(color: AppTheme.borderColor))
                        : null,
                  ),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: categoryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(label, style: const TextStyle(fontSize: 10,
                          fontWeight: FontWeight.w600, color: categoryColor)),
                    ),
                    if (!billable) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.textSecondary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('Not billable', style: TextStyle(fontSize: 9,
                            fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                      ),
                    ],
                    if (hasReceipt) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.receipt_long, size: 12, color: AppTheme.textSecondary),
                    ],
                    const SizedBox(width: 10),
                    Expanded(child: Text(
                      desc.isNotEmpty ? desc : label,
                      style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    )),
                    Text('\$${dollars.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => _showAddExpenseSheet(context, existing: exp),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.edit_outlined, size: 13, color: AppTheme.textSecondary),
                      ),
                    ),
                    GestureDetector(
                      onTap: () async {
                        final id = exp['id'] as int?;
                        if (id != null) await _softDeleteExpense(id);
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close, size: 13, color: AppTheme.error),
                      ),
                    ),
                  ]),
                );
              }),
            ]),
          ),
      ],
    ]);
  }

  Widget _buildLaborCostSection(BuildContext context) {
    if (!widget.laborCostEnabled) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('LABOR COST', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
            color: AppTheme.textSecondary, letterSpacing: 0.5)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.lock_outline, size: 16, color: AppTheme.brand),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Labor Cost is a Pro plan feature',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
              const SizedBox(height: 2),
              const Text('See what this job cost in tracked hours, using each tech\'s pay rate.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ])),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => context.go('/settings?section=billing'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.brand,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('Upgrade', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
              ),
            ),
          ]),
        ),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: GestureDetector(
          onTap: () => setState(() => _laborCostSectionExpanded = !_laborCostSectionExpanded),
          child: Row(children: [
            const Text('LABOR COST', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary, letterSpacing: 0.5)),
            const SizedBox(width: 6),
            Icon(_laborCostSectionExpanded ? Icons.expand_less : Icons.expand_more,
                size: 16, color: AppTheme.textSecondary),
          ]),
        )),
        if (_laborCostTotal != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text('\$${_laborCostTotal!.toStringAsFixed(2)} total',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.brand)),
          ),
      ]),
      const SizedBox(height: 8),
      if (_laborCostSectionExpanded) ...[
        if (_loadingLaborCost)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))),
          )
        else if (_laborCostBreakdown.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: const Row(children: [
              Icon(Icons.payments_outlined, size: 16, color: AppTheme.textMuted),
              SizedBox(width: 8),
              Expanded(child: Text(
                'No tracked hours with a pay rate on file for this job yet.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              )),
            ]),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Column(children: [
              for (int i = 0; i < _laborCostBreakdown.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: i < _laborCostBreakdown.length - 1
                        ? const Border(bottom: BorderSide(color: AppTheme.borderColor))
                        : null,
                  ),
                  child: Row(children: [
                    const Icon(Icons.person_outline, size: 14, color: AppTheme.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_laborCostBreakdown[i]['name'] as String,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                      Text(
                        '${(_laborCostBreakdown[i]['hours'] as double).toStringAsFixed(2)} hrs × \$${(_laborCostBreakdown[i]['rate'] as double).toStringAsFixed(2)}/hr'
                        '${_laborCostBreakdown[i]['is_current_rate'] == true ? ' (current rate)' : ' (rate effective ${_fmtRateDate(_laborCostBreakdown[i]['effective_date'] as String?)})'}',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ])),
                    Text('\$${(_laborCostBreakdown[i]['subtotal'] as double).toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  ]),
                ),
            ]),
          ),
      ],
    ]);
  }

  Widget _buildJobFormsSection(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: GestureDetector(
          onTap: () => setState(() => _jobFormsSectionExpanded = !_jobFormsSectionExpanded),
          child: Row(children: [
            const Text('JOB FORMS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary, letterSpacing: 0.5)),
            const SizedBox(width: 6),
            Icon(_jobFormsSectionExpanded ? Icons.expand_less : Icons.expand_more,
                size: 16, color: AppTheme.textSecondary),
          ]),
        )),
        GestureDetector(
          onTap: () => _showAttachFormSheet(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.brand,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add, size: 12, color: Colors.white),
              SizedBox(width: 4),
              Text('Attach Form', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
            ]),
          ),
        ),
      ]),
      const SizedBox(height: 8),

      if (_jobFormsSectionExpanded) ...[
        if (_loadingForms)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))),
          )
        else if (_attachedForms.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: const Row(children: [
              Icon(Icons.assignment_outlined, size: 16, color: AppTheme.textMuted),
              SizedBox(width: 8),
              Text('No job forms attached yet',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: AppTheme.pageBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Column(children: [
              ..._attachedForms.asMap().entries.map((entry) {
                final i = entry.key;
                final sub = entry.value;
                final status = sub['status'] as String? ?? 'not_started';
                final name = sub['form_name'] as String? ?? 'Unknown Form';
                final color = _formStatusColor(status);
                final isCompleted = status == 'completed';
                final label = sub['submission_label'] as String?;
                final rowContent = Row(children: [
                  const Icon(Icons.assignment_outlined, size: 14, color: AppTheme.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name,
                        style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                        overflow: TextOverflow.ellipsis),
                    if (label != null && label.isNotEmpty)
                      Text(label,
                          style: const TextStyle(fontSize: 10, color: AppTheme.brand, fontStyle: FontStyle.italic),
                          overflow: TextOverflow.ellipsis),
                  ])),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(_formStatusLabel(status), style: TextStyle(fontSize: 10,
                        fontWeight: FontWeight.w600, color: color)),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () async {
                      final id = sub['id'] as int?;
                      if (id != null) await _detachForm(id);
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 13, color: AppTheme.error),
                    ),
                  ),
                ]);
                return Container(
                  decoration: BoxDecoration(
                    border: i < _attachedForms.length - 1
                        ? const Border(bottom: BorderSide(color: AppTheme.borderColor))
                        : null,
                  ),
                  child: isCompleted
                      ? InkWell(
                          onTap: () {
                            final id = sub['id'] as int?;
                            if (id != null) _openCompletedFormViewer(id);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: rowContent,
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: rowContent,
                        ),
                );
              }),
            ]),
          ),
      ],
    ]);
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
        color: AppTheme.textSecondary, letterSpacing: 0.5)),
  );

  Widget _field(String label, TextEditingController ctrl,
      {String? hint, TextInputType? keyboard, int maxLines = 1, List<TextInputFormatter>? inputFormatters}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl, keyboardType: keyboard, maxLines: maxLines, inputFormatters: inputFormatters,
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
      ),
    ]);
  }

  Widget _dropdownField({required String label, required String value, required List<String> items, required ValueChanged<String?> onChanged}) {
    final safe = items.contains(value) ? value : items.first;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
        child: DropdownButtonHideUnderline(child: DropdownButton<String>(
          value: safe, isExpanded: true, dropdownColor: AppTheme.cardBg,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          items: items.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
          onChanged: onChanged,
        )),
      ),
    ]);
  }

  Widget _dateTimeField(String label, DateTime value, VoidCallback onTap) {
    final h = value.hour == 0 ? 12 : value.hour > 12 ? value.hour - 12 : value.hour;
    final m = value.minute.toString().padLeft(2, '0');
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final formatted = '${months[value.month-1]} ${value.day} · $h:$m ${value.hour < 12 ? 'AM' : 'PM'}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      Clickable(onTap: onTap, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
        child: Row(children: [
          const Icon(Icons.access_time, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(formatted, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
        ]),
      )),
    ]);
  }
}
// ══════════════════════════════════════════════════════════════════════════════
//  ADD / EDIT EXPENSE SHEET
// ══════════════════════════════════════════════════════════════════════════════

class _AddExpenseSheet extends StatefulWidget {
  final int appointmentId;
  final int? businessId;
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;

  const _AddExpenseSheet({
    required this.appointmentId,
    required this.onSaved,
    this.businessId,
    this.existing,
  });

  @override
  State<_AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends State<_AddExpenseSheet> {
  final _db = Supabase.instance.client;
  final _amountCtrl = TextEditingController();
  final _descCtrl   = TextEditingController();

  List<Map<String, dynamic>> _categories = [];
  int?    _categoryId;
  bool    _billable        = true;
  bool    _loadingCategories = true;
  bool    _saving          = false;
  String? _error;

  Uint8List? _receiptBytes;
  String?    _receiptName;
  bool       _pickingPhoto = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final e = widget.existing!;
      _categoryId = e['category_id'] as int?;
      _billable   = e['billable'] as bool? ?? true;
      final cents = (e['amount_cents'] as int?) ?? 0;
      _amountCtrl.text = (cents / 100.0).toStringAsFixed(2);
      _descCtrl.text   = e['description'] as String? ?? '';
    }
    _loadCategories();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    if (widget.businessId == null) {
      if (mounted) setState(() => _loadingCategories = false);
      return;
    }
    try {
      final data = await _db
          .from('expense_categories')
          .select()
          .eq('business_id', widget.businessId!)
          .eq('is_active', true)
          .filter('deleted_at', 'is', null)
          .order('name', ascending: true);
      if (!mounted) return;
      setState(() {
        _categories = List<Map<String, dynamic>>.from(data);
        if (_categoryId == null && _categories.isNotEmpty) {
          _categoryId = _categories.first['id'] as int?;
        }
      });
    } catch (e) {
      debugPrint('Load expense categories error: $e');
    } finally {
      if (mounted) setState(() => _loadingCategories = false);
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    setState(() => _pickingPhoto = true);
    try {
      final picked = await ImagePicker().pickImage(source: source, imageQuality: 80);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _receiptBytes = bytes;
        _receiptName  = picked.name;
      });
    } catch (e) {
      debugPrint('Pick photo error: $e');
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  Future<void> _uploadReceipt(int expenseId, String token) async {
    if (_receiptBytes == null) return;
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/upload-expense-receipt'),
      );
      req.headers['Authorization'] = 'Bearer $token';
      req.fields['expense_id'] = expenseId.toString();
      req.files.add(http.MultipartFile.fromBytes('receipt', _receiptBytes!, filename: _receiptName ?? 'receipt.jpg'));
      await req.send();
    } catch (e) {
      debugPrint('Upload receipt error: $e');
    }
  }

  Future<void> _save() async {
    if (_categoryId == null) {
      setState(() => _error = 'Select a category');
      return;
    }
    final amountText = _amountCtrl.text.trim().replaceAll(',', '');
    final dollars    = double.tryParse(amountText);
    if (dollars == null || dollars <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    final amountCents = (dollars * 100).round();
    setState(() { _saving = true; _error = null; });

    try {
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final body = <String, dynamic>{
        'appointment_id': widget.appointmentId,
        if (widget.businessId != null) 'business_id': widget.businessId,
        'category_id':    _categoryId,
        'amount_cents':   amountCents,
        'description':    _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
        'billable':       _billable,
        if (widget.existing != null) 'expense_id': widget.existing!['id'],
      };

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/log-job-expense'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode == 403 && data['error'] == 'upgrade_required') {
        setState(() { _error = 'Job Costing requires the Growth plan. Upgrade in Settings → Billing.'; _saving = false; });
        return;
      }
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to save expense');
      }

      final expenseId = data['expense']?['id'] as int?;
      if (expenseId != null && _receiptBytes != null) {
        await _uploadReceipt(expenseId, token);
      }
      if (!mounted) return;
      widget.onSaved();
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 32),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4,
            decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        Text(widget.existing != null ? 'Edit Expense' : 'Add Expense',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        const SizedBox(height: 20),

        // Category selector
        const Text('Category', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        if (_loadingCategories)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (_categories.isEmpty)
          const Text('No categories set up for this business yet.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
            child: DropdownButtonHideUnderline(child: DropdownButton<int>(
              value: _categoryId,
              isExpanded: true,
              dropdownColor: AppTheme.cardBg,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              items: _categories.map((c) => DropdownMenuItem<int>(
                value: c['id'] as int,
                child: Text(c['name'] as String? ?? 'Unnamed'),
              )).toList(),
              onChanged: (v) => setState(() => _categoryId = v),
            )),
          ),
        const SizedBox(height: 16),

        // Amount
        const Text('Amount', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        const SizedBox(height: 4),
        TextField(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
          decoration: InputDecoration(
            prefixText: '\$ ',
            prefixStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
            hintText: '0.00',
            hintStyle: const TextStyle(fontSize: 16, color: AppTheme.textMuted),
            filled: true, fillColor: AppTheme.pageBg,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border:        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
          ),
        ),
        const SizedBox(height: 12),

        // Description
        const Text('Description (optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        const SizedBox(height: 4),
        TextField(
          controller: _descCtrl,
          maxLines: 2,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'e.g. 3hrs crew labor, 2 bundles shingles...',
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            filled: true, fillColor: AppTheme.pageBg,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border:        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.brand, width: 2)),
          ),
        ),
        const SizedBox(height: 16),

        // Billable toggle
        Row(children: [
          Switch(value: _billable, onChanged: (v) => setState(() => _billable = v), activeColor: AppTheme.brand),
          const SizedBox(width: 8),
          const Text('Billable to customer', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
        ]),
        const SizedBox(height: 12),

        // Receipt photo
        const Text('Receipt (optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        if (_receiptBytes != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: AppTheme.pageBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderColor)),
            child: Row(children: [
              const Icon(Icons.image_outlined, size: 16, color: AppTheme.brand),
              const SizedBox(width: 8),
              Expanded(child: Text(_receiptName ?? 'Photo attached',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary), overflow: TextOverflow.ellipsis)),
              GestureDetector(
                onTap: () => setState(() { _receiptBytes = null; _receiptName = null; }),
                child: const Icon(Icons.close, size: 14, color: AppTheme.error),
              ),
            ]),
          )
        else
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: _pickingPhoto ? null : () => _pickPhoto(ImageSource.camera),
              icon: const Icon(Icons.camera_alt_outlined, size: 16),
              label: const Text('Take Photo'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textPrimary,
                side: const BorderSide(color: AppTheme.borderColor),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: _pickingPhoto ? null : () => _pickPhoto(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined, size: 16),
              label: const Text('Choose File'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textPrimary,
                side: const BorderSide(color: AppTheme.borderColor),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            )),
          ]),

        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(fontSize: 12, color: AppTheme.error)),
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
                : Text(widget.existing != null ? 'Save Changes' : 'Add Expense',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }
}

// ════════════════════════════ END OF PART 4 ════════════════════════════════
// Assemble final file: Part1 + Part2 + Part3 + Part4
// Remove all comment lines starting with // ═══ before saving