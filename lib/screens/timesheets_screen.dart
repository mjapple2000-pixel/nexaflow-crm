import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:web/web.dart' as web;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

class TimesheetsScreen extends StatefulWidget {
  const TimesheetsScreen({super.key});

  @override
  State<TimesheetsScreen> createState() => _TimesheetsScreenState();
}

class _TimesheetsScreenState extends State<TimesheetsScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  bool _isOwner = false;
  bool _hasTimeTrackingAccess = true;
  Map<String, dynamic>? _myActiveEntry;
  List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> _totals = [];
  List<Map<String, dynamic>> _teamProfiles = [];
  String? _error;

  // Clock timer
  Timer? _clockTimer;
  Duration _elapsed = Duration.zero;

  // Clock action
  bool _clockActionInProgress = false;

  // Filters (owner only)
  String? _filterUserId;
  DateTime? _filterStart;
  DateTime? _filterEnd;

  // Week / Day toggle — Week is the default landing view for owners.
  // Non-owners have nothing to summarize across teammates, so they skip
  // straight to Day view and never see the toggle at all.
  String _viewMode = 'week';
  String _weekStartDay = 'monday';
  String _payPeriodType = 'weekly';
  bool _canViewPayRates = false;
  bool _canManageTimesheets = false;
  bool _canManagePayPeriods = false;
  List<Map<String, dynamic>> _payPeriods = [];
  bool _lockActionInProgress = false;
  late DateTime _weekStart;
  bool _weekLoading = true;
  String? _weekError;
  List<Map<String, dynamic>> _weekTotals = [];
  // Raw entries for whatever range is currently loaded (Week/Month/Period) —
  // used only for the Detailed CSV export mode. get-timesheets already
  // returns this regardless of group_by; it's just discarded outside Day
  // view today, so capturing it costs nothing extra.
  List<Map<String, dynamic>> _rangeEntries = [];

  // Month view — Summary (per-employee totals) and Calendar (per-day grid)
  // sub-views, both scoped to the currently loaded month.
  String _monthSubView = 'summary';
  late DateTime _monthCursor;
  bool _monthLoading = true;
  String? _monthError;
  List<Map<String, dynamic>> _monthTotals = [];
  List<Map<String, dynamic>> _dailyTotals = [];

  // Pay Period view — only shown when the business's pay_period_type is
  // biweekly or semimonthly (never weekly, since Week view already covers
  // that). Boundaries are computed client-side from pay_period_config.
  Map<String, dynamic> _payPeriodConfig = {};
  late DateTime _periodCursor;
  bool _periodLoading = true;
  String? _periodError;
  List<Map<String, dynamic>> _periodTotals = [];
  bool _exportingPdf = false;

  static const _dayOrder = [
    'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
  ];

  bool _initialLoadDone = false;
  late final Future<void> _weekStartDayFuture;

  @override
  void initState() {
    super.initState();
    _weekStart = _startOfWeekContaining(DateTime.now(), _weekStartDay);
    _monthCursor = DateTime(DateTime.now().year, DateTime.now().month, 1);
    final now = DateTime.now();
    _periodCursor = DateTime(now.year, now.month, now.day);
    _weekStartDayFuture = _loadWeekStartDay();
  }

  // The Week→Day and Month drill-ins are URL-driven (?view=...&user=...
  // &start=...&end=...&sub=...&month=...) via context.go(), rather than
  // pure setState, so the browser back button has a real GoRouter history
  // entry to return to instead of leaving the page entirely. GoRouter
  // reuses this widget on the same route when only query params change,
  // so the params must be read here in didChangeDependencies — not
  // initState, which only runs once.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncFromUrl();
  }

  Future<void> _syncFromUrl() async {
    // On the very first sync, wait for the business's real week_start_day
    // (and pay_period_type) to come back before triggering the default
    // Week load — otherwise the initial load can race ahead using the
    // 'monday' fallback and compute the wrong week boundary.
    if (!_initialLoadDone) {
      await _weekStartDayFuture;
      if (!mounted) return;
    }
    if (!_hasTimeTrackingAccess) return;

    final params = GoRouterState.of(context).uri.queryParameters;
    final view = params['view'];
    final userId = params['user'];
    final startStr = params['start'];
    final endStr = params['end'];
    final sub = params['sub'];
    final monthStr = params['month'];
    final pcursorStr = params['pcursor'];

    final newViewMode = view == 'day'
        ? 'day'
        : view == 'month'
            ? 'month'
            : view == 'period'
                ? 'period'
                : 'week';
    final newStart = startStr != null ? DateTime.tryParse(startStr) : null;
    final newEnd = endStr != null ? DateTime.tryParse(endStr) : null;
    final newMonthSub = sub == 'calendar' ? 'calendar' : 'summary';
    DateTime newMonthCursor = _monthCursor;
    if (monthStr != null) {
      final parts = monthStr.split('-');
      if (parts.length == 2) {
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (y != null && m != null) newMonthCursor = DateTime(y, m, 1);
      }
    }
    final newPeriodCursor = pcursorStr != null
        ? (DateTime.tryParse(pcursorStr) ?? _periodCursor)
        : _periodCursor;

    final unchanged = _initialLoadDone &&
        newViewMode == _viewMode &&
        userId == _filterUserId &&
        newStart == _filterStart &&
        newEnd == _filterEnd &&
        (newViewMode != 'month' ||
            (newMonthSub == _monthSubView && newMonthCursor == _monthCursor)) &&
        (newViewMode != 'period' || newPeriodCursor == _periodCursor);
    if (unchanged) return;

    _initialLoadDone = true;
    setState(() {
      _viewMode = newViewMode;
      _filterUserId = userId;
      _filterStart = newStart;
      _filterEnd = newEnd;
      if (newViewMode == 'month') {
        _monthSubView = newMonthSub;
        _monthCursor = newMonthCursor;
      }
      if (newViewMode == 'period') {
        _periodCursor = newPeriodCursor;
      }
    });

    if (_viewMode == 'day') {
      _load();
    } else if (_viewMode == 'month') {
      _loadMonthTotals();
    } else if (_viewMode == 'period') {
      _loadPeriodTotals();
    } else {
      _loadWeekTotals();
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  DateTime _startOfWeekContaining(DateTime date, String startDayName) {
    final startIdx = _dayOrder.indexOf(startDayName);
    final safeStartIdx = startIdx == -1 ? 0 : startIdx;
    final dateIdx = date.weekday - 1; // Monday=0 .. Sunday=6
    final diff = (dateIdx - safeStartIdx + 7) % 7;
    final d = DateTime(date.year, date.month, date.day);
    return d.subtract(Duration(days: diff));
  }

  // ignore: unused_element -- retained as an async function so initState
  // can capture and await its Future (see _weekStartDayFuture).
  Future<void> _loadWeekStartDay() async {
    try {
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId == null) return;
      final biz = await _db
          .from('businesses')
          .select('week_start_day, pay_period_type, pay_period_config, plan, is_paid, subscription_status, is_beta')
          .eq('id', activeBusinessId)
          .maybeSingle();
      final day = biz?['week_start_day'] as String?;
      final periodType = biz?['pay_period_type'] as String?;
      final periodConfig = biz?['pay_period_config'] as Map<String, dynamic>?;
      // Client-side mirror of check_plan_feature('time_tracking'): is_beta
      // bypass, else is_paid + subscription_status active/trialing +
      // plan growth/pro. Keep in sync if check_plan_feature's SQL changes.
      final plan = biz?['plan'] as String?;
      final isPaid = biz?['is_paid'] as bool? ?? false;
      final subStatus = biz?['subscription_status'] as String?;
      final isBeta = biz?['is_beta'] as bool? ?? false;
      final hasTimeTrackingAccess = isBeta ||
          (isPaid &&
              (subStatus == 'active' || subStatus == 'trialing') &&
              (plan == 'growth' || plan == 'pro'));
      if (!mounted) return;
      setState(() {
        if (day != null && _dayOrder.contains(day)) {
          _weekStartDay = day;
          _weekStart = _startOfWeekContaining(_weekStart, day);
        }
        if (periodType != null) _payPeriodType = periodType;
        if (periodConfig != null) _payPeriodConfig = periodConfig;
        _hasTimeTrackingAccess = hasTimeTrackingAccess;
      });
    } catch (e) {
      debugPrint('Week start day load error: $e');
    }
  }

  Future<void> _loadWeekTotals() async {
    if (!mounted) return;
    setState(() { _weekLoading = true; _weekError = null; });
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final startStr = _weekStart.toIso8601String().substring(0, 10);
      final endStr = _weekStart.add(const Duration(days: 6)).toIso8601String().substring(0, 10);
      final body = <String, dynamic>{'start_date': startStr, 'end_date': endStr};

      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-timesheets'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return;

      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to load timesheets');
      }

      setState(() {
        _isOwner              = data['is_owner'] as bool? ?? false;
        _canViewPayRates      = data['can_view_pay_rates'] as bool? ?? false;
        _canManageTimesheets  = data['can_manage_timesheets'] as bool? ?? false;
        _canManagePayPeriods  = data['can_manage_pay_periods'] as bool? ?? false;
        _payPeriods           = List<Map<String, dynamic>>.from(data['pay_periods'] as List? ?? []);
        _myActiveEntry        = data['my_active_entry'] as Map<String, dynamic>?;
        _weekTotals           = List<Map<String, dynamic>>.from(data['totals'] as List? ?? []);
        _rangeEntries          = List<Map<String, dynamic>>.from(data['entries'] as List? ?? []);
        _teamProfiles         = List<Map<String, dynamic>>.from(data['team_profiles'] as List? ?? []);
      });
      _startOrStopTicker();

      // Non-owners have no team to summarize — land them on Day view
      // (their own entries only) instead of an empty Week screen.
      if (!_isOwner) {
        _viewMode = 'day';
        await _load();
      }
    } catch (e) {
      if (mounted) setState(() => _weekError = e.toString());
    } finally {
      if (mounted) setState(() => _weekLoading = false);
    }
  }

  Future<void> _loadMonthTotals() async {
    if (!mounted) return;
    setState(() { _monthLoading = true; _monthError = null; });
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final monthEnd = DateTime(_monthCursor.year, _monthCursor.month + 1, 0);
      final startStr = _monthCursor.toIso8601String().substring(0, 10);
      final endStr = monthEnd.toIso8601String().substring(0, 10);
      final body = <String, dynamic>{
        'start_date': startStr,
        'end_date': endStr,
        'group_by': 'day',
      };

      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-timesheets'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return;

      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to load timesheets');
      }

      setState(() {
        _isOwner              = data['is_owner'] as bool? ?? false;
        _canViewPayRates      = data['can_view_pay_rates'] as bool? ?? false;
        _canManageTimesheets  = data['can_manage_timesheets'] as bool? ?? false;
        _canManagePayPeriods  = data['can_manage_pay_periods'] as bool? ?? false;
        _payPeriods           = List<Map<String, dynamic>>.from(data['pay_periods'] as List? ?? []);
        _myActiveEntry        = data['my_active_entry'] as Map<String, dynamic>?;
        _monthTotals          = List<Map<String, dynamic>>.from(data['totals'] as List? ?? []);
        _dailyTotals          = List<Map<String, dynamic>>.from(data['daily_totals'] as List? ?? []);
        _rangeEntries          = List<Map<String, dynamic>>.from(data['entries'] as List? ?? []);
        _teamProfiles         = List<Map<String, dynamic>>.from(data['team_profiles'] as List? ?? []);
      });
      _startOrStopTicker();
    } catch (e) {
      if (mounted) setState(() => _monthError = e.toString());
    } finally {
      if (mounted) setState(() => _monthLoading = false);
    }
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  // Returns [periodStart, periodEnd] for the pay period containing `date`.
  // Confirmed semimonthly rule: [day_one, day_two-1] and
  // [day_two, last day of month] — the standard 1st–15th / 16th–end split.
  List<DateTime> _currentPayPeriod(DateTime date) {
    if (_payPeriodType == 'biweekly') {
      final anchorStr = _payPeriodConfig['anchor_date'] as String?;
      final anchor = anchorStr != null ? DateTime.tryParse(anchorStr) : null;
      if (anchor == null) {
        // No anchor configured yet — fall back to a 14-day window starting
        // at the reference date rather than crashing.
        return [date, date.add(const Duration(days: 13))];
      }
      final anchorDate = DateTime(anchor.year, anchor.month, anchor.day);
      final dateOnly = DateTime(date.year, date.month, date.day);
      final daysSince = dateOnly.difference(anchorDate).inDays;
      final periodIndex = daysSince >= 0
          ? daysSince ~/ 14
          : -(((-daysSince) + 13) ~/ 14);
      final start = anchorDate.add(Duration(days: periodIndex * 14));
      return [start, start.add(const Duration(days: 13))];
    }

    // semimonthly
    final dayOneRaw = (_payPeriodConfig['day_one'] as num?)?.toInt() ?? 1;
    final dayTwoRaw = (_payPeriodConfig['day_two'] as num?)?.toInt() ?? 16;
    final maxDay = _daysInMonth(date.year, date.month);
    final dayOne = dayOneRaw > maxDay ? maxDay : dayOneRaw;
    final dayTwo = dayTwoRaw > maxDay ? maxDay : dayTwoRaw;

    if (date.day < dayOne) {
      final prevMonth = DateTime(date.year, date.month - 1, 1);
      final prevMax = _daysInMonth(prevMonth.year, prevMonth.month);
      final prevDayTwoRaw = (_payPeriodConfig['day_two'] as num?)?.toInt() ?? 16;
      final prevDayTwo = prevDayTwoRaw > prevMax ? prevMax : prevDayTwoRaw;
      return [
        DateTime(prevMonth.year, prevMonth.month, prevDayTwo),
        DateTime(date.year, date.month, dayOne).subtract(const Duration(days: 1)),
      ];
    } else if (date.day < dayTwo) {
      return [
        DateTime(date.year, date.month, dayOne),
        DateTime(date.year, date.month, dayTwo).subtract(const Duration(days: 1)),
      ];
    } else {
      return [
        DateTime(date.year, date.month, dayTwo),
        DateTime(date.year, date.month, maxDay),
      ];
    }
  }

  String _periodRangeLabel(DateTime start, DateTime end) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    if (start.month == end.month && start.year == end.year) {
      return '${months[start.month - 1]} ${start.day} – ${end.day}, ${end.year}';
    }
    return '${months[start.month - 1]} ${start.day} – ${months[end.month - 1]} ${end.day}, ${end.year}';
  }

  Future<void> _loadPeriodTotals() async {
    if (!mounted) return;
    setState(() { _periodLoading = true; _periodError = null; });
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final bounds = _currentPayPeriod(_periodCursor);
      final startStr = bounds[0].toIso8601String().substring(0, 10);
      final endStr = bounds[1].toIso8601String().substring(0, 10);
      final body = <String, dynamic>{'start_date': startStr, 'end_date': endStr};

      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-timesheets'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return;

      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to load timesheets');
      }

      setState(() {
        _isOwner              = data['is_owner'] as bool? ?? false;
        _canViewPayRates      = data['can_view_pay_rates'] as bool? ?? false;
        _canManageTimesheets  = data['can_manage_timesheets'] as bool? ?? false;
        _canManagePayPeriods  = data['can_manage_pay_periods'] as bool? ?? false;
        _payPeriods           = List<Map<String, dynamic>>.from(data['pay_periods'] as List? ?? []);
        _myActiveEntry        = data['my_active_entry'] as Map<String, dynamic>?;
        _periodTotals         = List<Map<String, dynamic>>.from(data['totals'] as List? ?? []);
        _rangeEntries          = List<Map<String, dynamic>>.from(data['entries'] as List? ?? []);
        _teamProfiles         = List<Map<String, dynamic>>.from(data['team_profiles'] as List? ?? []);
      });
      _startOrStopTicker();
    } catch (e) {
      if (mounted) setState(() => _periodError = e.toString());
    } finally {
      if (mounted) setState(() => _periodLoading = false);
    }
  }

  void _prevWeek() {
    setState(() => _weekStart = _weekStart.subtract(const Duration(days: 7)));
    _loadWeekTotals();
  }

  void _nextWeek() {
    setState(() => _weekStart = _weekStart.add(const Duration(days: 7)));
    _loadWeekTotals();
  }

  String _weekRangeLabel() {
    final end = _weekStart.add(const Duration(days: 6));
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    if (_weekStart.month == end.month) {
      return '${months[_weekStart.month - 1]} ${_weekStart.day} – ${end.day}, ${end.year}';
    }
    return '${months[_weekStart.month - 1]} ${_weekStart.day} – ${months[end.month - 1]} ${end.day}, ${end.year}';
  }

  // Returns the pay_periods row for the week starting on this date, if any.
  Map<String, dynamic>? _payPeriodForWeek(DateTime weekStart) {
    final weekStartStr = weekStart.toIso8601String().substring(0, 10);
    for (final p in _payPeriods) {
      if (p['week_start'] == weekStartStr) return p;
    }
    return null;
  }

  // Whether this calendar date falls inside any locked pay period. String
  // comparison works here since week_start/week_end/date are all
  // YYYY-MM-DD, which sorts lexicographically the same as chronologically.
  bool _isDateLocked(DateTime date) {
    final dateStr = date.toIso8601String().substring(0, 10);
    for (final p in _payPeriods) {
      if (p['locked_at'] == null) continue;
      final ws = p['week_start'] as String?;
      final we = p['week_end'] as String?;
      if (ws == null || we == null) continue;
      if (dateStr.compareTo(ws) >= 0 && dateStr.compareTo(we) <= 0) return true;
    }
    return false;
  }

  void _switchToWeekView() {
    context.go('/timesheets');
  }

  void _switchToDayView({String? userId, DateTime? start, DateTime? end}) {
    final params = <String, String>{'view': 'day'};
    if (userId != null) params['user'] = userId;
    if (start != null) params['start'] = start.toIso8601String().substring(0, 10);
    if (end != null) params['end'] = end.toIso8601String().substring(0, 10);
    context.go(Uri(path: '/timesheets', queryParameters: params).toString());
  }

  String _monthParam(DateTime cursor) =>
      '${cursor.year}-${cursor.month.toString().padLeft(2, '0')}';

  void _goToMonth(DateTime cursor, String sub) {
    context.go(Uri(path: '/timesheets', queryParameters: {
      'view': 'month',
      'sub': sub,
      'month': _monthParam(cursor),
    }).toString());
  }

  void _switchToMonthView() => _goToMonth(_monthCursor, _monthSubView);

  void _switchToMonthSub(String sub) => _goToMonth(_monthCursor, sub);

  void _prevMonth() =>
      _goToMonth(DateTime(_monthCursor.year, _monthCursor.month - 1, 1), _monthSubView);

  void _nextMonth() =>
      _goToMonth(DateTime(_monthCursor.year, _monthCursor.month + 1, 1), _monthSubView);

  void _goToPeriod(DateTime cursor) {
    context.go(Uri(path: '/timesheets', queryParameters: {
      'view': 'period',
      'pcursor': cursor.toIso8601String().substring(0, 10),
    }).toString());
  }

  void _switchToPeriodView() => _goToPeriod(_periodCursor);

  void _prevPeriod() {
    final bounds = _currentPayPeriod(_periodCursor);
    _goToPeriod(bounds[0].subtract(const Duration(days: 1)));
  }

  void _nextPeriod() {
    final bounds = _currentPayPeriod(_periodCursor);
    _goToPeriod(bounds[1].add(const Duration(days: 1)));
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final body = <String, dynamic>{};
      if (_filterStart != null) body['start_date'] = _filterStart!.toIso8601String().substring(0, 10);
      if (_filterEnd != null)   body['end_date']   = _filterEnd!.toIso8601String().substring(0, 10);
      if (_filterUserId != null) body['user_id_filter'] = _filterUserId;

      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-timesheets'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return;

      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to load timesheets');
      }

      setState(() {
        _isOwner              = data['is_owner'] as bool? ?? false;
        _canManageTimesheets  = data['can_manage_timesheets'] as bool? ?? false;
        _canManagePayPeriods  = data['can_manage_pay_periods'] as bool? ?? false;
        _payPeriods           = List<Map<String, dynamic>>.from(data['pay_periods'] as List? ?? []);
        _myActiveEntry        = data['my_active_entry'] as Map<String, dynamic>?;
        _entries              = List<Map<String, dynamic>>.from(data['entries'] as List? ?? []);
        _totals               = List<Map<String, dynamic>>.from(data['totals'] as List? ?? []);
        _teamProfiles         = List<Map<String, dynamic>>.from(data['team_profiles'] as List? ?? []);
      });
      _startOrStopTicker();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startOrStopTicker() {
    _clockTimer?.cancel();
    if (_myActiveEntry == null) {
      setState(() => _elapsed = Duration.zero);
      return;
    }
    final clockedInAt = DateTime.tryParse(_myActiveEntry!['clocked_in_at'] ?? '');
    if (clockedInAt == null) return;
    void tick() {
      if (!mounted) return;
      setState(() => _elapsed = DateTime.now().toUtc().difference(clockedInAt.toUtc()));
    }
    tick();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<Position?> _getLocation() async {
    // GPS/location capture is intentionally scoped to the Employee Hub
    // (field-tech magic-link) clock-in flow only, not this in-app CRM
    // Timesheets screen — office staff clocking in from a desktop have no
    // real GPS hardware, and attempting geolocation here previously caused
    // the Clock In button to hang indefinitely with no way to recover.
    return null;
  }

  Future<void> _toggleClock() async {
    setState(() => _clockActionInProgress = true);
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final action = _myActiveEntry == null ? 'clock_in' : 'clock_out';
      final position = await _getLocation();
      final body = <String, dynamic>{'action': action};
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
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        final errCode = data['error'] as String?;
        if (errCode == 'location_required') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Location is required by your business. Please allow location access and try again.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 4),
              ),
            );
          }
          return;
        }
        throw Exception(data['error'] ?? 'Clock action failed');
      }
      await _load();
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

  String _formatDuration(int? minutes) {
    if (minutes == null || minutes == 0) return '—';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  double? _computePay(Map<String, dynamic> t) {
    if (!_canViewPayRates) return null;
    final payType = t['pay_type'] as String? ?? 'hourly';
    final minutes = (t['total_minutes'] as num?)?.toInt() ?? 0;
    if (payType == 'salary') {
      final salary = (t['annual_salary'] as num?)?.toDouble();
      if (salary == null) return null;
      final periodsPerYear = _payPeriodType == 'biweekly'
          ? 26
          : _payPeriodType == 'semimonthly'
              ? 24
              : 52;
      return salary / periodsPerYear;
    }
    final rate = (t['hourly_rate'] as num?)?.toDouble();
    if (rate == null) return null;
    return (minutes / 60.0) * rate;
  }

  String _formatCurrency(double? amount) {
    if (amount == null) return '—';
    return '\$${amount.toStringAsFixed(2)}';
  }

  // Export is only meaningful for the per-employee summary shapes (Week,
  // Month → Summary, Pay Period) — not Day (raw entries) or Month →
  // Calendar (a different, per-day shape).
  List<Map<String, dynamic>> _currentTotalsForExport() {
    if (_viewMode == 'week') return _weekTotals;
    if (_viewMode == 'month' && _monthSubView == 'summary') return _monthTotals;
    if (_viewMode == 'period') return _periodTotals;
    return [];
  }

  (DateTime, DateTime, String) _currentExportRange() {
    if (_viewMode == 'week') {
      return (_weekStart, _weekStart.add(const Duration(days: 6)), 'Week of ${_weekRangeLabel()}');
    }
    if (_viewMode == 'month') {
      final end = DateTime(_monthCursor.year, _monthCursor.month + 1, 0);
      const monthNames = ['January','February','March','April','May','June',
          'July','August','September','October','November','December'];
      return (_monthCursor, end, '${monthNames[_monthCursor.month - 1]} ${_monthCursor.year}');
    }
    final bounds = _currentPayPeriod(_periodCursor);
    return (bounds[0], bounds[1], 'Pay Period: ${_periodRangeLabel(bounds[0], bounds[1])}');
  }

  String _currentExportFilenamePrefix() {
    final range = _currentExportRange();
    final startStr = range.$1.toIso8601String().substring(0, 10);
    final endStr = range.$2.toIso8601String().substring(0, 10);
    return 'timesheets_${startStr}_to_$endStr';
  }

  bool get _canExport =>
      _isOwner &&
      ((_viewMode == 'week' && _weekTotals.isNotEmpty) ||
          (_viewMode == 'month' && _monthSubView == 'summary' && _monthTotals.isNotEmpty) ||
          (_viewMode == 'period' && _periodTotals.isNotEmpty));

  String _csvEscape(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  String _buildCsv(List<Map<String, dynamic>> totals) {
    final buffer = StringBuffer();
    final headers = ['Employee', 'Total Hours', 'Entries'];
    if (_canViewPayRates) headers.addAll(['Pay Type', 'Rate', 'Total Pay']);
    buffer.writeln(headers.map(_csvEscape).join(','));

    int grandMinutes = 0;
    int grandEntries = 0;
    double grandPay = 0;

    for (final t in totals) {
      final name = t['full_name'] as String? ?? 'Unknown';
      final minutes = (t['total_minutes'] as num?)?.toInt() ?? 0;
      final count = (t['entry_count'] as num?)?.toInt() ?? 0;
      grandMinutes += minutes;
      grandEntries += count;

      final row = <String>[name, (minutes / 60.0).toStringAsFixed(2), '$count'];
      if (_canViewPayRates) {
        final payType = t['pay_type'] as String? ?? 'hourly';
        final rateVal = payType == 'salary'
            ? (t['annual_salary'] as num?)?.toDouble()
            : (t['hourly_rate'] as num?)?.toDouble();
        final pay = _computePay(t);
        grandPay += pay ?? 0;
        row.addAll([
          payType,
          rateVal != null ? rateVal.toStringAsFixed(2) : '',
          pay != null ? pay.toStringAsFixed(2) : '',
        ]);
      }
      buffer.writeln(row.map(_csvEscape).join(','));
    }

    final totalRow = <String>['TOTAL', (grandMinutes / 60.0).toStringAsFixed(2), '$grandEntries'];
    if (_canViewPayRates) totalRow.addAll(['', '', grandPay.toStringAsFixed(2)]);
    buffer.writeln(totalRow.map(_csvEscape).join(','));

    return buffer.toString();
  }

  // One row per clock-in/clock-out event, for anyone who wants to
  // double-check individual shifts rather than just totals.
  String _buildDetailedCsv(List<Map<String, dynamic>> entries) {
    final buffer = StringBuffer();
    buffer.writeln(['Employee', 'Clock In', 'Clock Out', 'Duration (Hours)', 'Status', 'Job', 'Notes']
        .map(_csvEscape).join(','));

    for (final e in entries) {
      final name = e['full_name'] as String? ?? 'Unknown';
      final clockedIn = _formatDateTime(e['clocked_in_at'] as String?);
      final status = e['status'] as String? ?? 'completed';
      final clockedOut = status == 'active' ? '—' : _formatDateTime(e['clocked_out_at'] as String?);
      final minutes = (e['duration_minutes'] as num?)?.toInt();
      final hours = minutes != null ? (minutes / 60.0).toStringAsFixed(2) : '';
      final job = (e['appointment_info'] as Map<String, dynamic>?)?['appointment_type'] as String? ?? '';
      final notes = e['notes'] as String? ?? '';
      buffer.writeln([name, clockedIn, clockedOut, hours, status, job, notes].map(_csvEscape).join(','));
    }

    return buffer.toString();
  }

  void _downloadBytes(List<int> bytes, String filename, String mimeType) {
    final blob = web.Blob(
      [Uint8List.fromList(bytes).toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);
    web.HTMLAnchorElement()
      ..href = url
      ..style.display = 'none'
      ..download = filename
      ..click();
    web.URL.revokeObjectURL(url);
  }

  void _exportCsv() {
    final totals = _currentTotalsForExport();
    if (totals.isEmpty) return;
    final csv = _buildCsv(totals);
    _downloadBytes(utf8.encode(csv), '${_currentExportFilenamePrefix()}.csv', 'text/csv');
  }

  void _exportDetailedCsv() {
    if (_rangeEntries.isEmpty) return;
    final csv = _buildDetailedCsv(_rangeEntries);
    _downloadBytes(utf8.encode(csv), '${_currentExportFilenamePrefix()}_detailed.csv', 'text/csv');
  }

  Future<void> _exportPdf() async {
    final totals = _currentTotalsForExport();
    if (totals.isEmpty) return;
    setState(() => _exportingPdf = true);
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final range = _currentExportRange();
      final body = <String, dynamic>{
        'start_date': range.$1.toIso8601String().substring(0, 10),
        'end_date': range.$2.toIso8601String().substring(0, 10),
        'label': range.$3,
      };
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/export-timesheets-pdf'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return;

      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to generate PDF');
      }
      final bytes = base64Decode(data['pdf_base64'] as String);
      _downloadBytes(bytes, '${_currentExportFilenamePrefix()}.pdf', 'application/pdf');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _exportingPdf = false);
    }
  }

  String _formatDateTime(String? raw) {
    if (raw == null) return '—';
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return '—';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day} · $h:$m $ampm';
  }

  Future<void> _pickDateFilter(bool isStart) async {
    final initial = isStart ? (_filterStart ?? DateTime.now()) : (_filterEnd ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (!mounted || picked == null) return;
    setState(() {
      if (isStart) _filterStart = picked;
      else         _filterEnd   = picked;
    });
    _load();
  }

  void _showEntryDetail(Map<String, dynamic> entry) {
    showDialog(
      context: context,
      builder: (_) => _TimeEntryDetailDialog(
        entry: entry,
        isOwner: _isOwner,
        canManageTimesheets: _canManageTimesheets,
        onForceClockOut: () => _forceClockOut(entry['id'] as int),
        onSave: (entryId, clockedInAt, clockedOutAt, notes) => _saveTimeEntry(
          entryId: entryId,
          clockedInAt: clockedInAt,
          clockedOutAt: clockedOutAt,
          notes: notes,
        ),
        onDelete: (entryId) => _deleteTimeEntry(entryId),
      ),
    );
  }

  // Refreshes _payPeriods from the full business history (not just the
  // currently-loaded view's date window) so _isDateLocked is accurate for
  // any date the Add Entry dialog might be pointed at, regardless of
  // which view (Week/Month/Period) the user was on when they opened it.
  Future<void> _refreshAllPayPeriods() async {
    try {
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId == null) return;
      final rows = await _db
          .from('pay_periods')
          .select('id, week_start, week_end, locked_at, locked_by')
          .eq('business_id', activeBusinessId);
      if (!mounted) return;
      final nameByUserId = {
        for (final p in _teamProfiles)
          if (p['user_id'] != null) p['user_id'] as String: p['full_name'] as String? ?? 'Unknown',
      };
      setState(() {
        _payPeriods = List<Map<String, dynamic>>.from(rows).map((p) {
          final lockedBy = p['locked_by'] as String?;
          return {
            ...p,
            'locked_by_name': lockedBy != null ? nameByUserId[lockedBy] : null,
          };
        }).toList();
      });
    } catch (e) {
      debugPrint('Pay period refresh error: $e');
    }
  }

  Future<void> _showAddEntryDialog() async {
    await _refreshAllPayPeriods();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => _AddTimeEntryDialog(
        teamProfiles: _teamProfiles,
        onCreate: (targetUserId, clockedInAt, clockedOutAt, notes) => _createTimeEntry(
          targetUserId: targetUserId,
          clockedInAt: clockedInAt,
          clockedOutAt: clockedOutAt,
          notes: notes,
        ),
        onUpdate: (entryId, clockedInAt, clockedOutAt, notes) => _saveTimeEntry(
          entryId: entryId,
          clockedInAt: clockedInAt,
          clockedOutAt: clockedOutAt,
          notes: notes,
        ),
        onFetchEntriesForUser: _fetchEntriesForUser,
        isDateLocked: _isDateLocked,
      ),
    );
  }

  Future<void> _forceClockOut(int entryId) async {
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final body = <String, dynamic>{'entry_id': entryId};
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/force-clock-out'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return;
      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to force clock out');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Team member clocked out.')),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // Resolves who to stamp as locked_by. Mirrors the edited_by guard from
  // TS-02: profiles.user_id has an FK from pay_periods.locked_by, and
  // superuser accounts have no profiles row by design, so stamping their
  // id unconditionally would violate that FK. Branch on whether a real
  // profile row exists, not on any specific account.
  Future<String?> _resolveLockedByUserId() async {
    final currentUserId = _db.auth.currentUser?.id;
    if (currentUserId == null) return null;
    final myProfile = await _db
        .from('profiles')
        .select('user_id')
        .eq('user_id', currentUserId)
        .maybeSingle();
    return myProfile != null ? currentUserId : null;
  }

  // A locked week should never contain a still-open clock-in — that hour
  // count isn't final yet. Checked directly against time_entries, which
  // is readable under the existing business-isolation RLS policy.
  Future<bool> _weekHasActiveEntry(int businessId, String weekStartStr, String weekEndStr) async {
    final rows = await _db
        .from('time_entries')
        .select('id')
        .eq('business_id', businessId)
        .eq('status', 'active')
        .isFilter('deleted_at', null)
        .gte('clocked_in_at', '${weekStartStr}T00:00:00.000Z')
        .lte('clocked_in_at', '${weekEndStr}T23:59:59.999Z')
        .limit(1);
    return rows.isNotEmpty;
  }

  Future<void> _lockWeek() async {
    if (_lockActionInProgress) return;
    setState(() => _lockActionInProgress = true);
    try {
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId == null) throw Exception('No active business');
      final weekStartStr = _weekStart.toIso8601String().substring(0, 10);
      final weekEndStr = _weekStart.add(const Duration(days: 6)).toIso8601String().substring(0, 10);
      final hasActive = await _weekHasActiveEntry(activeBusinessId, weekStartStr, weekEndStr);
      if (!mounted) return;
      if (hasActive) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Someone is still clocked in this week. Have them clock out (or force clock out) before locking.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
        setState(() => _lockActionInProgress = false);
        return;
      }
      final lockedBy = await _resolveLockedByUserId();
      if (!mounted) return;
      await _db.from('pay_periods').upsert({
        'business_id': activeBusinessId,
        'week_start': weekStartStr,
        'week_end': weekEndStr,
        'locked_at': DateTime.now().toUtc().toIso8601String(),
        'locked_by': lockedBy,
      }, onConflict: 'business_id,week_start');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Week locked for payroll.')),
      );
      await _loadWeekTotals();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _lockActionInProgress = false);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchPayPeriodHistory(int payPeriodId) async {
    try {
      final rows = await _db
          .from('pay_period_audit_log')
          .select('id, action, actor_user_id, created_at')
          .eq('pay_period_id', payPeriodId)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading history: $e'), backgroundColor: Colors.red),
        );
      }
      return [];
    }
  }

  void _showPayPeriodHistory(int payPeriodId) {
    final nameByUserId = {
      for (final p in _teamProfiles)
        if (p['user_id'] != null) p['user_id'] as String: p['full_name'] as String? ?? 'Unknown',
    };
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Lock History'),
        content: SizedBox(
          width: 380,
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _fetchPayPeriodHistory(payPeriodId),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 80,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final history = snapshot.data ?? [];
              if (history.isEmpty) {
                return const Text('No lock activity recorded for this week.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary));
              }
              return SizedBox(
                width: double.maxFinite,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: history.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
                  itemBuilder: (_, i) {
                    final h = history[i];
                    final action = h['action'] as String? ?? 'unknown';
                    final actorId = h['actor_user_id'] as String?;
                    final actorName = actorId != null ? (nameByUserId[actorId] ?? 'Unknown') : 'NexaFlow Support';
                    final at = _formatDateTime(h['created_at'] as String?);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        Icon(
                          action == 'locked' ? Icons.lock_outline : Icons.lock_open_outlined,
                          size: 16,
                          color: action == 'locked' ? AppTheme.error : AppTheme.success,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(action == 'locked' ? 'Locked' : 'Unlocked',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                            Text('by $actorName · $at',
                                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                          ]),
                        ),
                      ]),
                    );
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndUnlockWeek() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Unlock this week?'),
        content: const Text(
            'This week was already locked for payroll. Unlocking it will allow edits to time entries again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _unlockWeek();
  }

  Future<void> _unlockWeek() async {
    if (_lockActionInProgress) return;
    setState(() => _lockActionInProgress = true);
    try {
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId == null) throw Exception('No active business');
      final weekStartStr = _weekStart.toIso8601String().substring(0, 10);
      await _db
          .from('pay_periods')
          .update({'locked_at': null, 'locked_by': null})
          .eq('business_id', activeBusinessId)
          .eq('week_start', weekStartStr);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Week unlocked.')),
      );
      await _loadWeekTotals();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _lockActionInProgress = false);
    }
  }

  // Reloads whichever view is currently active — used after a manual
  // edit/create/delete so the totals and table reflect the change.
  Future<void> _reloadCurrentView() async {
    if (_viewMode == 'week') {
      await _loadWeekTotals();
    } else if (_viewMode == 'month') {
      await _loadMonthTotals();
    } else if (_viewMode == 'period') {
      await _loadPeriodTotals();
    } else {
      await _load();
    }
  }

  Future<bool> _saveTimeEntry({
    required int entryId,
    required DateTime clockedInAt,
    DateTime? clockedOutAt,
    String? notes,
  }) async {
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final body = <String, dynamic>{
        'action': 'update',
        'entry_id': entryId,
        'clocked_in_at': clockedInAt.toUtc().toIso8601String(),
        if (clockedOutAt != null) 'clocked_out_at': clockedOutAt.toUtc().toIso8601String(),
        'notes': notes,
      };
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/edit-timesheet-entry'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return false;
      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to update entry');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Time entry updated.')),
      );
      await _reloadCurrentView();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
      return false;
    }
  }

  Future<bool> _deleteTimeEntry(int entryId) async {
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final body = <String, dynamic>{'action': 'delete', 'entry_id': entryId};
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/edit-timesheet-entry'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return false;
      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to delete entry');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Time entry deleted.')),
      );
      await _reloadCurrentView();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
      return false;
    }
  }

  Future<bool> _createTimeEntry({
    required String targetUserId,
    required DateTime clockedInAt,
    required DateTime clockedOutAt,
    String? notes,
  }) async {
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final body = <String, dynamic>{
        'action': 'create',
        'target_user_id': targetUserId,
        'clocked_in_at': clockedInAt.toUtc().toIso8601String(),
        'clocked_out_at': clockedOutAt.toUtc().toIso8601String(),
        'notes': notes,
      };
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/edit-timesheet-entry'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      if (!mounted) return false;
      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to create entry');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Time entry added.')),
      );
      await _reloadCurrentView();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _fetchEntriesForUser(String userId) async {
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final endDate = DateTime.now();
      final startDate = endDate.subtract(const Duration(days: 60));
      final body = <String, dynamic>{
        'user_id_filter': userId,
        'start_date': startDate.toIso8601String().substring(0, 10),
        'end_date': endDate.toIso8601String().substring(0, 10),
      };
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId != null) body['business_id'] = activeBusinessId;

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/get-timesheets'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'Failed to load shifts');
      }
      return List<Map<String, dynamic>>.from(data['entries'] as List? ?? []);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading shifts: $e'), backgroundColor: Colors.red),
        );
      }
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasTimeTrackingAccess) return _buildLockedTeaser();

    final isWeekView = _viewMode == 'week';
    final isMonthView = _viewMode == 'month';
    final isPeriodView = _viewMode == 'period';
    final showLoading = isWeekView
        ? _weekLoading
        : isMonthView
            ? _monthLoading
            : isPeriodView
                ? _periodLoading
                : _loading;
    final showError = isWeekView
        ? _weekError
        : isMonthView
            ? _monthError
            : isPeriodView
                ? _periodError
                : _error;

    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        _buildTopBar(),
        Expanded(
          child: showLoading
              ? const Center(child: CircularProgressIndicator())
              : showError != null
                  ? Center(child: Text(showError, style: const TextStyle(color: AppTheme.error)))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _buildClockCard(),
                        const SizedBox(height: 24),
                        if (isWeekView)
                          _buildWeekView()
                        else if (isMonthView)
                          _buildMonthView()
                        else if (isPeriodView)
                          _buildPeriodView()
                        else ...[
                          if (_isOwner && _totals.isNotEmpty) ...[
                            _buildTotalsSection(),
                            const SizedBox(height: 24),
                          ],
                          if (_isOwner) _buildOwnerFilters(),
                          if (_isOwner) const SizedBox(height: 16),
                          _buildEntriesTable(),
                        ],
                      ]),
                    ),
        ),
      ]),
    );
  }

  Widget _buildLockedTeaser() {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: const Row(children: [
            Text('Timesheets',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          ]),
        ),
        Expanded(
          child: Center(
            child: Container(
              width: 420,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.lock_outline, size: 26, color: AppTheme.brand),
                ),
                const SizedBox(height: 16),
                const Text('Timesheets & Payroll is a Growth feature',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                const Text(
                  'Clock in/out, pay rate tracking, pay period locking, and payroll export are available on the Growth plan and above.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity, height: 44,
                  child: ElevatedButton(
                    onPressed: () => context.go('/settings?section=billing'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Upgrade Plan', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
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
      child: Row(children: [
        const Text('Timesheets',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const SizedBox(width: 20),
        if (_isOwner) _buildViewToggle(),
        const Spacer(),
        if (_canManageTimesheets) ...[
          _buildAddEntryButton(),
          const SizedBox(width: 8),
        ],
        if (_canExport) ...[
          _buildExportButton(),
          const SizedBox(width: 8),
        ],
        IconButton(
          onPressed: () {
            if (_viewMode == 'week') {
              _loadWeekTotals();
            } else if (_viewMode == 'month') {
              _loadMonthTotals();
            } else if (_viewMode == 'period') {
              _loadPeriodTotals();
            } else {
              _load();
            }
          },
          icon: const Icon(Icons.refresh, size: 18, color: AppTheme.textSecondary),
          tooltip: 'Refresh',
        ),
      ]),
    );
  }

  Widget _buildAddEntryButton() {
    return Clickable(
      onTap: _showAddEntryDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add, size: 16, color: AppTheme.textSecondary),
          SizedBox(width: 6),
          Text('Add Entry', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }

  Widget _buildExportButton() {
    return PopupMenuButton<String>(
      enabled: !_exportingPdf,
      onSelected: (v) {
        if (v == 'csv') _exportCsv();
        if (v == 'csv_detailed') _exportDetailedCsv();
        if (v == 'pdf') _exportPdf();
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'csv', child: Text('Download CSV (Summary)')),
        PopupMenuItem(value: 'csv_detailed', child: Text('Download CSV (Detailed)')),
        PopupMenuItem(value: 'pdf', child: Text('Download PDF')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _exportingPdf
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download_outlined, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 6),
          const Text('Export', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
          const Icon(Icons.arrow_drop_down, size: 16, color: AppTheme.textSecondary),
        ]),
      ),
    );
  }

  Widget _buildViewToggle() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _viewToggleBtn('Week', 'week'),
        _viewToggleBtn('Day', 'day'),
        _viewToggleBtn('Month', 'month'),
        if (_payPeriodType != 'weekly') _viewToggleBtn('Pay Period', 'period'),
      ]),
    );
  }

  Widget _viewToggleBtn(String label, String mode) {
    final sel = _viewMode == mode;
    return Clickable(
      onTap: () {
        if (mode == 'week') {
          _switchToWeekView();
        } else if (mode == 'month') {
          _switchToMonthView();
        } else if (mode == 'period') {
          _switchToPeriodView();
        } else {
          _switchToDayView();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppTheme.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                color: sel ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  Widget _buildClockCard() {
    final isClockedIn = _myActiveEntry != null;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isClockedIn ? AppTheme.success.withValues(alpha: 0.08) : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isClockedIn ? AppTheme.success.withValues(alpha: 0.4) : AppTheme.borderColor,
          width: isClockedIn ? 1.5 : 1,
        ),
      ),
      child: Row(children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            color: isClockedIn
                ? AppTheme.success.withValues(alpha: 0.15)
                : AppTheme.brand.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            isClockedIn ? Icons.timer : Icons.timer_outlined,
            size: 24,
            color: isClockedIn ? AppTheme.success : AppTheme.brand,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            isClockedIn ? 'Currently Clocked In' : 'Not Clocked In',
            style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700,
              color: isClockedIn ? AppTheme.success : AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          if (isClockedIn) ...[
            Text(
              _formatElapsed(_elapsed),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
            ),
            if ((_myActiveEntry!['appointment_id']) != null)
              const Text('On a scheduled job', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ] else
            const Text('Tap Clock In to start tracking your time',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ])),
        const SizedBox(width: 16),
        SizedBox(
          height: 44, width: 120,
          child: ElevatedButton.icon(
            onPressed: _clockActionInProgress ? null : _toggleClock,
            icon: _clockActionInProgress
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(isClockedIn ? Icons.stop_circle_outlined : Icons.play_circle_outline, size: 18),
            label: Text(isClockedIn ? 'Clock Out' : 'Clock In',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: isClockedIn ? AppTheme.error : AppTheme.brand,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildTotalsSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('TEAM SUMMARY',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary, letterSpacing: 1)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 12, runSpacing: 12,
        children: _totals.map((t) {
          final name    = t['full_name'] as String? ?? 'Unknown';
          final minutes = (t['total_minutes'] as num?)?.toInt() ?? 0;
          final count   = (t['entry_count'] as num?)?.toInt() ?? 0;
          final initials = name.trim().split(' ')
              .map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
          return Container(
            width: 180,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Row(children: [
              Container(
                width: 34, height: 34,
                decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(initials,
                    style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary), overflow: TextOverflow.ellipsis),
                Text(_formatDuration(minutes),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.brand)),
                Text('$count ${count == 1 ? 'entry' : 'entries'}',
                    style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
              ])),
            ]),
          );
        }).toList(),
      ),
    ]);
  }

  Widget _buildWeekView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(_weekRangeLabel(),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const SizedBox(width: 8),
        IconButton(
          onPressed: _prevWeek,
          icon: const Icon(Icons.chevron_left, size: 18, color: AppTheme.textSecondary),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
        IconButton(
          onPressed: _nextWeek,
          icon: const Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
        Clickable(
          onTap: () {
            setState(() => _weekStart = _startOfWeekContaining(DateTime.now(), _weekStartDay));
            _loadWeekTotals();
          },
          child: Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(border: Border.all(color: AppTheme.borderColor), borderRadius: BorderRadius.circular(6)),
            child: const Text('This Week', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
        ),
        const Spacer(),
        _buildWeekLockControl(),
      ]),
      const SizedBox(height: 16),
      if (_weekTotals.isEmpty)
        Container(
          padding: const EdgeInsets.all(48),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.calendar_view_week_outlined, size: 48, color: AppTheme.textMuted),
            SizedBox(height: 12),
            Text('No time entries this week', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
          ])),
        )
      else
        Container(
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(children: [
                const Expanded(flex: 4, child: Text('EMPLOYEE',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 1))),
                const Expanded(flex: 2, child: Text('TOTAL HOURS',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 1))),
                const Expanded(flex: 2, child: Text('ENTRIES',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 1))),
                if (_canViewPayRates)
                  const Expanded(flex: 2, child: Text('TOTAL PAY',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                          color: AppTheme.textSecondary, letterSpacing: 1))),
                const SizedBox(width: 24),
              ]),
            ),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _weekTotals.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
              itemBuilder: (_, i) {
                final t = _weekTotals[i];
                final userId  = t['user_id'] as String?;
                final name    = t['full_name'] as String? ?? 'Unknown';
                final minutes = (t['total_minutes'] as num?)?.toInt() ?? 0;
                final count   = (t['entry_count'] as num?)?.toInt() ?? 0;
                final pay     = _computePay(t);
                final initials = name.trim().split(' ')
                    .map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
                return Clickable(
                  onTap: () {
                    if (userId == null) return;
                    _switchToDayView(
                      userId: userId,
                      start: _weekStart,
                      end: _weekStart.add(const Duration(days: 6)),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(children: [
                      Expanded(flex: 4, child: Row(children: [
                        Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                          alignment: Alignment.center,
                          child: Text(initials,
                              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(name,
                            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                            overflow: TextOverflow.ellipsis)),
                      ])),
                      Expanded(flex: 2, child: Text(_formatDuration(minutes),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.brand))),
                      Expanded(flex: 2, child: Text('$count',
                          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
                      if (_canViewPayRates)
                        Expanded(flex: 2, child: Text(_formatCurrency(pay),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
                      const Icon(Icons.chevron_right, size: 16, color: AppTheme.textMuted),
                    ]),
                  ),
                );
              },
            ),
            if (_canViewPayRates) _buildWeekGrandTotalRow(),
          ]),
        ),
    ]);
  }

  Widget _buildWeekGrandTotalRow() {
    final totalMinutes = _weekTotals.fold<int>(0, (sum, t) => sum + ((t['total_minutes'] as num?)?.toInt() ?? 0));
    final totalEntries = _weekTotals.fold<int>(0, (sum, t) => sum + ((t['entry_count'] as num?)?.toInt() ?? 0));
    final totalPay = _weekTotals.fold<double>(0, (sum, t) => sum + (_computePay(t) ?? 0));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(children: [
        const Expanded(flex: 4, child: Text('TOTAL',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
        Expanded(flex: 2, child: Text(_formatDuration(totalMinutes),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.brand))),
        Expanded(flex: 2, child: Text('$totalEntries',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
        Expanded(flex: 2, child: Text(_formatCurrency(totalPay),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
        const SizedBox(width: 24),
      ]),
    );
  }

  Widget _buildWeekLockControl() {
    final period = _payPeriodForWeek(_weekStart);
    final isLocked = period != null && period['locked_at'] != null;
    if (!isLocked && !_canManagePayPeriods) return const SizedBox.shrink();

    if (isLocked) {
      final lockedByName = period['locked_by_name'] as String?;
      final lockedAt = period['locked_at'] as String?;
      final periodId = period['id'] as int?;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.error.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 14, color: AppTheme.error),
            const SizedBox(width: 6),
            Text(
              lockedByName != null
                  ? 'Locked by $lockedByName · ${_formatDateTime(lockedAt)}'
                  : 'Locked · ${_formatDateTime(lockedAt)}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.error),
            ),
          ]),
        ),
        if (_isOwner && periodId != null) ...[
          const SizedBox(width: 8),
          Clickable(
            onTap: () => _showPayPeriodHistory(periodId),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(border: Border.all(color: AppTheme.borderColor), borderRadius: BorderRadius.circular(6)),
              child: const Text('History', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ),
          ),
        ],
        if (_canManagePayPeriods) ...[
          const SizedBox(width: 8),
          Clickable(
            onTap: _lockActionInProgress ? null : _confirmAndUnlockWeek,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(border: Border.all(color: AppTheme.borderColor), borderRadius: BorderRadius.circular(6)),
              child: _lockActionInProgress
                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Unlock', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ),
          ),
        ],
      ]);
    }

    return Clickable(
      onTap: _lockActionInProgress ? null : _lockWeek,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(border: Border.all(color: AppTheme.borderColor), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _lockActionInProgress
              ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.lock_open_outlined, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 6),
          const Text('Lock Week', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }

  Widget _buildMonthView() {
    const monthNames = ['January','February','March','April','May','June',
        'July','August','September','October','November','December'];
    final label = '${monthNames[_monthCursor.month - 1]} ${_monthCursor.year}';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        const SizedBox(width: 8),
        IconButton(
          onPressed: _prevMonth,
          icon: const Icon(Icons.chevron_left, size: 18, color: AppTheme.textSecondary),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
        IconButton(
          onPressed: _nextMonth,
          icon: const Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
        Clickable(
          onTap: () {
            final now = DateTime.now();
            _goToMonth(DateTime(now.year, now.month, 1), _monthSubView);
          },
          child: Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(border: Border.all(color: AppTheme.borderColor), borderRadius: BorderRadius.circular(6)),
            child: const Text('This Month', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
        ),
        const Spacer(),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _monthSubToggleBtn('Summary', 'summary'),
            _monthSubToggleBtn('Calendar', 'calendar'),
          ]),
        ),
      ]),
      const SizedBox(height: 16),
      if (_monthSubView == 'calendar') _buildMonthCalendar() else _buildMonthSummary(),
    ]);
  }

  Widget _monthSubToggleBtn(String label, String sub) {
    final sel = _monthSubView == sub;
    return Clickable(
      onTap: () => _switchToMonthSub(sub),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppTheme.brand : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                color: sel ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  Widget _buildMonthSummary() {
    if (_monthTotals.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.calendar_view_month_outlined, size: 48, color: AppTheme.textMuted),
          SizedBox(height: 12),
          Text('No time entries this month', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
        ])),
      );
    }

    final monthEnd = DateTime(_monthCursor.year, _monthCursor.month + 1, 0);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: Row(children: [
            const Expanded(flex: 4, child: Text('EMPLOYEE',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 2, child: Text('TOTAL HOURS',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 2, child: Text('ENTRIES',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            if (_canViewPayRates)
              const Expanded(flex: 2, child: Text('TOTAL PAY',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary, letterSpacing: 1))),
            const SizedBox(width: 24),
          ]),
        ),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _monthTotals.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
          itemBuilder: (_, i) {
            final t = _monthTotals[i];
            final userId  = t['user_id'] as String?;
            final name    = t['full_name'] as String? ?? 'Unknown';
            final minutes = (t['total_minutes'] as num?)?.toInt() ?? 0;
            final count   = (t['entry_count'] as num?)?.toInt() ?? 0;
            final pay     = _computePay(t);
            final initials = name.trim().split(' ')
                .map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
            return Clickable(
              onTap: () {
                if (userId == null) return;
                _switchToDayView(userId: userId, start: _monthCursor, end: monthEnd);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(children: [
                  Expanded(flex: 4, child: Row(children: [
                    Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: Text(initials,
                          style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(name,
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                        overflow: TextOverflow.ellipsis)),
                  ])),
                  Expanded(flex: 2, child: Text(_formatDuration(minutes),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.brand))),
                  Expanded(flex: 2, child: Text('$count',
                      style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
                  if (_canViewPayRates)
                    Expanded(flex: 2, child: Text(_formatCurrency(pay),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
                  const Icon(Icons.chevron_right, size: 16, color: AppTheme.textMuted),
                ]),
              ),
            );
          },
        ),
        if (_canViewPayRates) _buildMonthGrandTotalRow(),
      ]),
    );
  }

  Widget _buildMonthGrandTotalRow() {
    final totalMinutes = _monthTotals.fold<int>(0, (sum, t) => sum + ((t['total_minutes'] as num?)?.toInt() ?? 0));
    final totalEntries = _monthTotals.fold<int>(0, (sum, t) => sum + ((t['entry_count'] as num?)?.toInt() ?? 0));
    final totalPay = _monthTotals.fold<double>(0, (sum, t) => sum + (_computePay(t) ?? 0));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(children: [
        const Expanded(flex: 4, child: Text('TOTAL',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
        Expanded(flex: 2, child: Text(_formatDuration(totalMinutes),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.brand))),
        Expanded(flex: 2, child: Text('$totalEntries',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
        Expanded(flex: 2, child: Text(_formatCurrency(totalPay),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
        const SizedBox(width: 24),
      ]),
    );
  }

  Widget _buildMonthCalendar() {
    final firstDay = _monthCursor;
    final daysInMonth = DateTime(_monthCursor.year, _monthCursor.month + 1, 0).day;
    // Grid starts on Sunday regardless of the business's week_start_day —
    // a calendar month grid is a different concept from the Week view's
    // pay-period-aligned week, so it always reads left-to-right Sun–Sat.
    final leadingBlanks = firstDay.weekday % 7;

    final minutesByDate = <String, int>{};
    for (final d in _dailyTotals) {
      final date = d['date'] as String?;
      if (date == null) continue;
      minutesByDate[date] = (d['total_minutes'] as num?)?.toInt() ?? 0;
    }

    const dayLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(children: [
        Row(children: dayLabels.map((l) => Expanded(
          child: Center(child: Text(l,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
        )).toList()),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: leadingBlanks + daysInMonth,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            childAspectRatio: 1.1,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemBuilder: (_, i) {
            if (i < leadingBlanks) return const SizedBox.shrink();
            final dayNum = i - leadingBlanks + 1;
            final date = DateTime(_monthCursor.year, _monthCursor.month, dayNum);
            final dateKey = date.toIso8601String().substring(0, 10);
            final minutes = minutesByDate[dateKey] ?? 0;
            final hasEntries = minutes > 0;
            return Clickable(
              onTap: () => _switchToDayView(start: date, end: date),
              child: Container(
                decoration: BoxDecoration(
                  color: hasEntries ? AppTheme.brand.withValues(alpha: 0.08) : AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: hasEntries ? AppTheme.brand.withValues(alpha: 0.3) : AppTheme.borderColor,
                  ),
                ),
                padding: const EdgeInsets.all(6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$dayNum',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  const Spacer(),
                  if (hasEntries)
                    Text(_formatDuration(minutes),
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.brand)),
                ]),
              ),
            );
          },
        ),
      ]),
    );
  }

  Widget _buildPeriodView() {
    final bounds = _currentPayPeriod(_periodCursor);
    final label = _periodRangeLabel(bounds[0], bounds[1]);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label,
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
          onTap: () => _goToPeriod(DateTime.now()),
          child: Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(border: Border.all(color: AppTheme.borderColor), borderRadius: BorderRadius.circular(6)),
            child: const Text('Current Period', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      if (_periodTotals.isEmpty)
        Container(
          padding: const EdgeInsets.all(48),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.event_note_outlined, size: 48, color: AppTheme.textMuted),
            SizedBox(height: 12),
            Text('No time entries this pay period', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
          ])),
        )
      else
        Container(
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
              ),
              child: Row(children: [
                const Expanded(flex: 4, child: Text('EMPLOYEE',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 1))),
                const Expanded(flex: 2, child: Text('TOTAL HOURS',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 1))),
                const Expanded(flex: 2, child: Text('ENTRIES',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary, letterSpacing: 1))),
                if (_canViewPayRates)
                  const Expanded(flex: 2, child: Text('TOTAL PAY',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                          color: AppTheme.textSecondary, letterSpacing: 1))),
                const SizedBox(width: 24),
              ]),
            ),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _periodTotals.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
              itemBuilder: (_, i) {
                final t = _periodTotals[i];
                final userId  = t['user_id'] as String?;
                final name    = t['full_name'] as String? ?? 'Unknown';
                final minutes = (t['total_minutes'] as num?)?.toInt() ?? 0;
                final count   = (t['entry_count'] as num?)?.toInt() ?? 0;
                final pay     = _computePay(t);
                final initials = name.trim().split(' ')
                    .map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
                return Clickable(
                  onTap: () {
                    if (userId == null) return;
                    _switchToDayView(userId: userId, start: bounds[0], end: bounds[1]);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(children: [
                      Expanded(flex: 4, child: Row(children: [
                        Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                          alignment: Alignment.center,
                          child: Text(initials,
                              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(name,
                            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                            overflow: TextOverflow.ellipsis)),
                      ])),
                      Expanded(flex: 2, child: Text(_formatDuration(minutes),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.brand))),
                      Expanded(flex: 2, child: Text('$count',
                          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
                      if (_canViewPayRates)
                        Expanded(flex: 2, child: Text(_formatCurrency(pay),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
                      const Icon(Icons.chevron_right, size: 16, color: AppTheme.textMuted),
                    ]),
                  ),
                );
              },
            ),
            if (_canViewPayRates) _buildPeriodGrandTotalRow(),
          ]),
        ),
    ]);
  }

  Widget _buildPeriodGrandTotalRow() {
    final totalMinutes = _periodTotals.fold<int>(0, (sum, t) => sum + ((t['total_minutes'] as num?)?.toInt() ?? 0));
    final totalEntries = _periodTotals.fold<int>(0, (sum, t) => sum + ((t['entry_count'] as num?)?.toInt() ?? 0));
    final totalPay = _periodTotals.fold<double>(0, (sum, t) => sum + (_computePay(t) ?? 0));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: Row(children: [
        const Expanded(flex: 4, child: Text('TOTAL',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
        Expanded(flex: 2, child: Text(_formatDuration(totalMinutes),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.brand))),
        Expanded(flex: 2, child: Text('$totalEntries',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
        Expanded(flex: 2, child: Text(_formatCurrency(totalPay),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
        const SizedBox(width: 24),
      ]),
    );
  }

  Widget _buildOwnerFilters() {
    final memberItems = [
      {'user_id': null, 'full_name': 'All Team Members'},
      ..._teamProfiles.where((p) => p['user_id'] != null).toList(),
    ];
    final selectedName = _filterUserId == null
        ? 'All Team Members'
        : (_teamProfiles.firstWhere(
            (p) => p['user_id'] == _filterUserId,
            orElse: () => {'full_name': 'All Team Members'},
          )['full_name'] as String? ?? 'All Team Members');

    return Row(children: [
      // Team member filter
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: DropdownButtonHideUnderline(child: DropdownButton<String?>(
          value: _filterUserId,
          dropdownColor: AppTheme.cardBg,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          hint: const Text('All Team Members', style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
          items: memberItems.map((m) => DropdownMenuItem<String?>(
            value: m['user_id'] as String?,
            child: Text(m['full_name'] as String? ?? 'Unknown'),
          )).toList(),
          onChanged: (v) { setState(() => _filterUserId = v); _load(); },
        )),
      ),
      const SizedBox(width: 10),

      // Start date
      Clickable(
        onTap: () => _pickDateFilter(true),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _filterStart != null ? AppTheme.brand.withValues(alpha: 0.08) : AppTheme.cardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _filterStart != null ? AppTheme.brand.withValues(alpha: 0.4) : AppTheme.borderColor,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.calendar_today_outlined, size: 13, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(
              _filterStart == null ? 'Start Date' : _formatDate(_filterStart!),
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            ),
          ]),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Text('—', style: TextStyle(color: AppTheme.textSecondary)),
      ),

      // End date
      Clickable(
        onTap: () => _pickDateFilter(false),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _filterEnd != null ? AppTheme.brand.withValues(alpha: 0.08) : AppTheme.cardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _filterEnd != null ? AppTheme.brand.withValues(alpha: 0.4) : AppTheme.borderColor,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.calendar_today_outlined, size: 13, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(
              _filterEnd == null ? 'End Date' : _formatDate(_filterEnd!),
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            ),
          ]),
        ),
      ),

      // Clear filters
      if (_filterStart != null || _filterEnd != null || _filterUserId != null) ...[
        const SizedBox(width: 10),
        Clickable(
          onTap: () {
            setState(() { _filterStart = null; _filterEnd = null; _filterUserId = null; });
            _load();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.close, size: 13, color: AppTheme.textSecondary),
              SizedBox(width: 4),
              Text('Clear', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          ),
        ),
      ],
    ]);
  }

  String _formatDate(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  Widget _buildEntriesTable() {
    if (_entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.access_time_outlined, size: 48, color: AppTheme.textMuted),
          SizedBox(height: 12),
          Text('No time entries found', style: TextStyle(fontSize: 15, color: AppTheme.textSecondary)),
          SizedBox(height: 6),
          Text('Use the Clock In button to start tracking time.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        ])),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: Row(children: [
            if (_isOwner)
              const Expanded(flex: 3, child: Text('TEAM MEMBER',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 3, child: Text('CLOCKED IN',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 3, child: Text('CLOCKED OUT',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 3, child: Text('JOB',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 2, child: Text('DURATION',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            const Expanded(flex: 2, child: Text('STATUS',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary, letterSpacing: 1))),
            if (_isOwner)
              const SizedBox(width: 24),
          ]),
        ),
        // Rows
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _entries.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.borderColor),
          itemBuilder: (_, i) {
            final e       = _entries[i];
            final status  = e['status'] as String? ?? 'completed';
            final isActive = status == 'active';
            final isStale  = e['is_stale_display'] as bool? ?? false;
            final name     = e['full_name'] as String? ?? 'Unknown';
            final initials = name.trim().split(' ')
                .map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();

            Color statusColor;
            String statusLabel;
            if (isStale) {
              statusColor = AppTheme.error;
              statusLabel = 'Forgot to clock out';
            } else if (isActive) {
              statusColor = AppTheme.success;
              statusLabel = 'Clocked In';
            } else {
              statusColor = AppTheme.textSecondary;
              statusLabel = 'Completed';
            }

            return Clickable(
              onTap: () => _showEntryDetail(e),
              child: Container(
              color: isStale ? AppTheme.error.withValues(alpha: 0.04) : null,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                if (_isOwner)
                  Expanded(flex: 3, child: Row(children: [
                    Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: Text(initials,
                          style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(name,
                        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                        overflow: TextOverflow.ellipsis)),
                  ])),
                Expanded(flex: 3, child: Text(_formatDateTime(e['clocked_in_at'] as String?),
                    style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary))),
                Expanded(flex: 3, child: Text(
                  isActive ? '—' : _formatDateTime(e['clocked_out_at'] as String?),
                  style: TextStyle(fontSize: 12,
                      color: isActive ? AppTheme.textMuted : AppTheme.textPrimary),
                )),
                Expanded(flex: 3, child: Text(
                  (e['appointment_info'] as Map<String, dynamic>?)?['appointment_type'] as String? ?? '—',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                  overflow: TextOverflow.ellipsis,
                )),
                Expanded(flex: 2, child: isActive
                    ? _LiveDuration(
                        clockedInAt: e['clocked_in_at'] as String?,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: AppTheme.success),
                      )
                    : Text(
                        _formatDuration(e['duration_minutes'] as int?),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary),
                      )),
                Expanded(flex: 2, child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(statusLabel,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: statusColor)),
                )),
                if (_isOwner)
                  isStale
                      ? Tooltip(
                          message: 'This entry has been open for 14+ hours',
                          child: Icon(Icons.warning_amber_rounded, size: 16, color: AppTheme.error),
                        )
                      : const SizedBox(width: 24),
              ]),
              ),
            );
          },
        ),
      ]),
    );
  }
}

class _CheckInDetailSheet extends StatefulWidget {
  final int appointmentId;
  final String appointmentName;
  final String? location;
  final DateTime? checkedInAt;

  const _CheckInDetailSheet({
    required this.appointmentId,
    required this.appointmentName,
    this.location,
    this.checkedInAt,
  });

  @override
  State<_CheckInDetailSheet> createState() => _CheckInDetailSheetState();
}

class _CheckInDetailSheetState extends State<_CheckInDetailSheet> {
  final _db = Supabase.instance.client;
  bool _loading = true;
  Map<String, dynamic>? _appt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await _db
          .from('appointments')
          .select('appointment_type, lead_name, lead_phone, status, start_date_time, notes')
          .eq('id', widget.appointmentId)
          .maybeSingle();
      if (!mounted) return;
      setState(() { _appt = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmtDateTime(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '—';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day} · $h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  String _fmtTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppTheme.borderColor, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          Row(children: [
            const Icon(Icons.location_on_outlined, size: 20, color: AppTheme.success),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.appointmentName,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary))),
          ]),
          if (widget.checkedInAt != null) ...[
            const SizedBox(height: 4),
            Text('Checked in at ${_fmtTime(widget.checkedInAt!)}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ],
          const SizedBox(height: 16),

          if (_loading)
            const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 24), child: CircularProgressIndicator()))
          else if (_appt == null)
            const Text('Could not load appointment details.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary))
          else ...[
            _row('Type', _appt!['appointment_type'] as String? ?? '—'),
            _row('Status', _appt!['status'] as String? ?? '—'),
            _row('Scheduled', _fmtDateTime(_appt!['start_date_time'] as String?)),
            if ((_appt!['lead_name'] as String? ?? '').isNotEmpty)
              _row('Customer', _appt!['lead_name'] as String),
            if ((_appt!['lead_phone'] as String? ?? '').isNotEmpty)
              _row('Phone', _appt!['lead_phone'] as String),
          ],

          const SizedBox(height: 12),
          const Text('Location', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          if (widget.location != null && widget.location!.isNotEmpty)
            InkWell(
              onTap: () async {
                final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(widget.location!)}');
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
                ),
                child: Row(children: [
                  const Icon(Icons.map_outlined, size: 18, color: AppTheme.brand),
                  const SizedBox(width: 10),
                  Expanded(child: Text(widget.location!, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
                  const Icon(Icons.open_in_new_rounded, size: 15, color: AppTheme.brand),
                ]),
              ),
            )
          else
            const Text('No address on file.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),

          if (_appt != null && (_appt!['notes'] as String? ?? '').isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Notes', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.pageBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Text(_appt!['notes'] as String, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
            ),
          ],

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity, height: 44,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand, foregroundColor: Colors.white, elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Close'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary))),
        ],
      ),
    );
  }
}

class _LiveDuration extends StatefulWidget {
  final String? clockedInAt;
  final TextStyle style;
  const _LiveDuration({required this.clockedInAt, required this.style});

  @override
  State<_LiveDuration> createState() => _LiveDurationState();
}

class _LiveDurationState extends State<_LiveDuration> {
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    final clockedInAt = DateTime.tryParse(widget.clockedInAt ?? '');
    if (clockedInAt != null) {
      void tick() {
        if (!mounted) return;
        setState(() => _elapsed = DateTime.now().toUtc().difference(clockedInAt.toUtc()));
      }
      tick();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) => Text(_format(_elapsed), style: widget.style);
}

class _TimeEntryDetailDialog extends StatefulWidget {
  final Map<String, dynamic> entry;
  final bool isOwner;
  final bool canManageTimesheets;
  final VoidCallback onForceClockOut;
  final Future<bool> Function(int entryId, DateTime clockedInAt, DateTime? clockedOutAt, String? notes) onSave;
  final Future<bool> Function(int entryId) onDelete;

  const _TimeEntryDetailDialog({
    required this.entry,
    required this.isOwner,
    required this.canManageTimesheets,
    required this.onForceClockOut,
    required this.onSave,
    required this.onDelete,
  });

  @override
  State<_TimeEntryDetailDialog> createState() => _TimeEntryDetailDialogState();
}

class _TimeEntryDetailDialogState extends State<_TimeEntryDetailDialog> {
  bool _editing = false;
  bool _saving = false;
  bool _deleting = false;
  late TimeOfDay _editStartTime;
  TimeOfDay? _editEndTime;
  late TextEditingController _notesController;
  String? _formError;

  Map<String, dynamic> get entry => widget.entry;

  @override
  void initState() {
    super.initState();
    final startDt = DateTime.tryParse(entry['clocked_in_at'] as String? ?? '')?.toLocal();
    final endDt = DateTime.tryParse(entry['clocked_out_at'] as String? ?? '')?.toLocal();
    _editStartTime = startDt != null
        ? TimeOfDay(hour: startDt.hour, minute: startDt.minute)
        : const TimeOfDay(hour: 8, minute: 0);
    _editEndTime = endDt != null ? TimeOfDay(hour: endDt.hour, minute: endDt.minute) : null;
    _notesController = TextEditingController(text: entry['notes'] as String? ?? '');
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  String _formatDateTime(String? raw) {
    if (raw == null) return '—';
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return '—';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = dt.hour == 0 ? 12 : dt.hour > 12 ? dt.hour - 12 : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day} · $h:$m $ampm';
  }

  String _formatTimeOfDay(TimeOfDay? t) {
    if (t == null) return 'Select time';
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
  }

  String _formatDuration(int? minutes) {
    if (minutes == null || minutes == 0) return '—';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  Widget _mapOrPlaceholder(double? lat, double? lng) {
    if (lat == null || lng == null) {
      return Container(
        height: 100,
        decoration: BoxDecoration(
          color: AppTheme.pageBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderColor),
        ),
        alignment: Alignment.center,
        child: const Text('No location recorded',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      );
    }
    final mapsUrl = 'https://www.google.com/maps?q=$lat,$lng';
    return InkWell(
      onTap: () async {
        final uri = Uri.parse(mapsUrl);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          color: AppTheme.brand.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_on_outlined, size: 24, color: AppTheme.brand),
            const SizedBox(height: 6),
            Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            const SizedBox(height: 4),
            const Text('Tap to view on map',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.brand)),
          ],
        ),
      ),
    );
  }

  String _fmtCheckInTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _pickEditStartTime() async {
    final picked = await showTimePicker(context: context, initialTime: _editStartTime);
    if (!mounted || picked == null) return;
    setState(() => _editStartTime = picked);
  }

  Future<void> _pickEditEndTime() async {
    final picked = await showTimePicker(context: context, initialTime: _editEndTime ?? const TimeOfDay(hour: 17, minute: 0));
    if (!mounted || picked == null) return;
    setState(() => _editEndTime = picked);
  }

  DateTime _combine(TimeOfDay time) {
    final baseDt = DateTime.tryParse(entry['clocked_in_at'] as String? ?? '')?.toLocal() ?? DateTime.now();
    return DateTime(baseDt.year, baseDt.month, baseDt.day, time.hour, time.minute);
  }

  Future<void> _saveEdit() async {
    var start = _combine(_editStartTime);
    DateTime? end = _editEndTime != null ? _combine(_editEndTime!) : null;
    if (end != null && !end.isAfter(start)) {
      // Overnight shift — end time-of-day is earlier than start, roll to next day.
      end = end.add(const Duration(days: 1));
    }
    setState(() { _formError = null; _saving = true; });
    final success = await widget.onSave(
      entry['id'] as int,
      start,
      end,
      _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
    );
    if (!mounted) return;
    if (success) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Delete this time entry?'),
        content: const Text(
            'This removes the entry from the employee\'s totals. This can\'t be undone from here — contact support if you need it restored.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    final success = await widget.onDelete(entry['id'] as int);
    if (!mounted) return;
    if (success) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = entry['status'] as String? ?? 'completed';
    final isActive = status == 'active';
    final isManual = status == 'manual';
    final isWeekLocked = entry['is_week_locked'] as bool? ?? false;
    final name = entry['full_name'] as String? ?? 'Unknown';
    final notes = entry['notes'] as String?;
    final editedByName = entry['edited_by_name'] as String?;
    final editedAt = entry['edited_at'] as String?;
    final shiftCheckIns = List<Map<String, dynamic>>.from(entry['shift_check_ins'] as List? ?? []);

    final clockInLat = (entry['clock_in_lat'] as num?)?.toDouble();
    final clockInLng = (entry['clock_in_lng'] as num?)?.toDouble();
    final clockOutLat = (entry['clock_out_lat'] as num?)?.toDouble();
    final clockOutLng = (entry['clock_out_lng'] as num?)?.toDouble();

    Color badgeColor = AppTheme.textSecondary;
    String badgeLabel = 'Completed';
    if (isActive) {
      badgeColor = AppTheme.success;
      badgeLabel = 'Clocked In';
    } else if (isManual) {
      badgeColor = AppTheme.brand;
      badgeLabel = 'Manual Entry';
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(name,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary)),
                  ),
                  if (widget.canManageTimesheets && !_editing && !isWeekLocked) ...[
                    IconButton(
                      onPressed: () => setState(() => _editing = true),
                      icon: const Icon(Icons.edit_outlined, size: 18, color: AppTheme.textSecondary),
                      tooltip: 'Edit entry',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    IconButton(
                      onPressed: _deleting ? null : _confirmDelete,
                      icon: _deleting
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.delete_outline, size: 18, color: AppTheme.error),
                      tooltip: 'Delete entry',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(badgeLabel,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: badgeColor)),
                  ),
                ]),
                if (editedByName != null && editedAt != null) ...[
                  const SizedBox(height: 4),
                  Text('Edited by $editedByName on ${_formatDateTime(editedAt)}',
                      style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: AppTheme.textSecondary)),
                ],
                if (isWeekLocked) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.lock_outline, size: 12, color: AppTheme.error),
                    const SizedBox(width: 4),
                    const Text('This week is locked for payroll.',
                        style: TextStyle(fontSize: 11, color: AppTheme.error)),
                  ]),
                ],
                const SizedBox(height: 16),
                if (_editing) ...[
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Clocked In', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const SizedBox(height: 4),
                      Clickable(
                        onTap: _pickEditStartTime,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppTheme.pageBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.borderColor),
                          ),
                          child: Text(_formatTimeOfDay(_editStartTime),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                        ),
                      ),
                    ])),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Clocked Out', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const SizedBox(height: 4),
                      Clickable(
                        onTap: _pickEditEndTime,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppTheme.pageBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.borderColor),
                          ),
                          child: Text(_formatTimeOfDay(_editEndTime),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                        ),
                      ),
                    ])),
                  ]),
                  const SizedBox(height: 4),
                  const Text('Correcting the date isn\'t supported here — only the time of day.',
                      style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                ] else
                  Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Clocked In', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const SizedBox(height: 2),
                      Text(_formatDateTime(entry['clocked_in_at'] as String?),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                    ])),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Clocked Out', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const SizedBox(height: 2),
                      Text(isActive ? '—' : _formatDateTime(entry['clocked_out_at'] as String?),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                    ])),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Duration', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const SizedBox(height: 2),
                      Text(isActive ? 'In progress' : _formatDuration(entry['duration_minutes'] as int?),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                    ])),
                  ]),
                const SizedBox(height: 20),
                Builder(builder: (context) {
                  final apptInfo = entry['appointment_info'] as Map<String, dynamic>?;
                  if (apptInfo == null) return const SizedBox.shrink();
                  final apptType = apptInfo['appointment_type'] as String? ?? 'Appointment';
                  final leadName = apptInfo['lead_name'] as String?;
                  final location = apptInfo['location'] as String?;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Job',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.pageBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(apptType,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                            if (leadName != null && leadName.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(leadName,
                                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                            ],
                            if (location != null && location.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(location,
                                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  );
                }),
                const Text('Clock-In Location',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                _mapOrPlaceholder(clockInLat, clockInLng),
                const SizedBox(height: 16),
                const Text('Clock-Out Location',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(height: 8),
                _mapOrPlaceholder(clockOutLat, clockOutLng),
                if (shiftCheckIns.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Job Site Check-Ins',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                  const SizedBox(height: 8),
                  ...shiftCheckIns.map((c) {
                    final ciName = c['appointment_name'] as String? ?? 'Job';
                    final loc = c['location'] as String?;
                    final at = DateTime.tryParse(c['checked_in_at'] as String? ?? '')?.toLocal();
                    return InkWell(
                      onTap: () => showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => _CheckInDetailSheet(
                          appointmentId: c['appointment_id'] as int,
                          appointmentName: ciName,
                          location: loc,
                          checkedInAt: at,
                        ),
                      ),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.success.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.success.withValues(alpha: 0.2)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.location_on_outlined, size: 15, color: AppTheme.success),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(ciName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                                if (loc != null && loc.isNotEmpty)
                                  Text(loc, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                              ],
                            ),
                          ),
                          if (at != null)
                            Text(_fmtCheckInTime(at), style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right, size: 15, color: AppTheme.textMuted),
                        ]),
                      ),
                    );
                  }),
                ],
                const SizedBox(height: 16),
                const Text('Notes',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                const SizedBox(height: 6),
                if (_editing)
                  TextField(
                    controller: _notesController,
                    maxLines: 3,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Add a note about this correction',
                      hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                      filled: true,
                      fillColor: AppTheme.pageBg,
                      contentPadding: const EdgeInsets.all(12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: AppTheme.borderColor),
                      ),
                    ),
                  )
                else if (notes != null && notes.trim().isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Text(notes,
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
                  )
                else
                  const Text('No notes.', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                if (_formError != null) ...[
                  const SizedBox(height: 10),
                  Text(_formError!, style: const TextStyle(fontSize: 12, color: AppTheme.error)),
                ],
                const SizedBox(height: 24),
                if (_editing)
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving ? null : () => setState(() => _editing = false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.textSecondary,
                          side: const BorderSide(color: AppTheme.borderColor),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _saving ? null : _saveEdit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.brand,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: _saving
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('Save Changes'),
                      ),
                    ),
                  ])
                else
                  Row(children: [
                    if (widget.isOwner && isActive) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context, rootNavigator: true).pop();
                            widget.onForceClockOut();
                          },
                          icon: const Icon(Icons.stop_circle_outlined, size: 16, color: AppTheme.error),
                          label: const Text('Force Clock Out'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.error,
                            side: const BorderSide(color: AppTheme.error),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.brand,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Close'),
                      ),
                    ),
                  ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddTimeEntryDialog extends StatefulWidget {
  final List<Map<String, dynamic>> teamProfiles;
  final Future<bool> Function(String targetUserId, DateTime clockedInAt, DateTime clockedOutAt, String? notes) onCreate;
  final Future<bool> Function(int entryId, DateTime clockedInAt, DateTime? clockedOutAt, String? notes) onUpdate;
  final Future<List<Map<String, dynamic>>> Function(String userId) onFetchEntriesForUser;
  final bool Function(DateTime date) isDateLocked;

  const _AddTimeEntryDialog({
    required this.teamProfiles,
    required this.onCreate,
    required this.onUpdate,
    required this.onFetchEntriesForUser,
    required this.isDateLocked,
  });

  @override
  State<_AddTimeEntryDialog> createState() => _AddTimeEntryDialogState();
}

class _AddTimeEntryDialogState extends State<_AddTimeEntryDialog> {
  // 'new' adds a fresh shift; 'edit' corrects the start/end time of a
  // shift the employee already clocked. Nothing is ever deleted either way.
  String _mode = 'new';

  String? _selectedUserId;
  DateTime _selectedDate = DateTime.now();
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;
  final _notesController = TextEditingController();
  bool _saving = false;
  String? _formError;

  bool _entriesLoading = false;
  List<Map<String, dynamic>> _userEntries = [];
  int? _selectedEntryId;
  DateTime? _selectedEntryBaseDate;

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _formatTime(TimeOfDay? t) {
    if (t == null) return 'Select time';
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
  }

  String _shiftLabel(Map<String, dynamic> e) {
    final start = DateTime.tryParse(e['clocked_in_at'] as String? ?? '')?.toLocal();
    final end = DateTime.tryParse(e['clocked_out_at'] as String? ?? '')?.toLocal();
    if (start == null) return 'Shift';
    final dateStr = _formatDate(start);
    final startStr = _formatTime(TimeOfDay(hour: start.hour, minute: start.minute));
    final endStr = end != null ? _formatTime(TimeOfDay(hour: end.hour, minute: end.minute)) : 'In progress';
    return '$dateStr · $startStr – $endStr';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (!mounted || picked == null) return;
    setState(() => _selectedDate = picked);
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime ?? const TimeOfDay(hour: 8, minute: 0),
    );
    if (!mounted || picked == null) return;
    setState(() => _startTime = picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime ?? const TimeOfDay(hour: 17, minute: 0),
    );
    if (!mounted || picked == null) return;
    setState(() => _endTime = picked);
  }

  Future<void> _onUserSelected(String? userId) async {
    setState(() {
      _selectedUserId = userId;
      _selectedEntryId = null;
      _selectedEntryBaseDate = null;
      _userEntries = [];
      _startTime = null;
      _endTime = null;
      _notesController.clear();
      _formError = null;
    });
    if (userId == null || _mode != 'edit') return;
    setState(() => _entriesLoading = true);
    final entries = await widget.onFetchEntriesForUser(userId);
    if (!mounted) return;
    setState(() {
      _userEntries = entries;
      _entriesLoading = false;
    });
  }

  void _onModeChanged(String mode) {
    setState(() {
      _mode = mode;
      _selectedEntryId = null;
      _selectedEntryBaseDate = null;
      _userEntries = [];
      _startTime = null;
      _endTime = null;
      _notesController.clear();
      _formError = null;
    });
    if (mode == 'edit' && _selectedUserId != null) {
      _onUserSelected(_selectedUserId);
    }
  }

  void _onEntrySelected(int? entryId) {
    final selected = _userEntries.firstWhere(
      (e) => e['id'] == entryId,
      orElse: () => <String, dynamic>{},
    );
    if (selected.isEmpty) return;
    final start = DateTime.tryParse(selected['clocked_in_at'] as String? ?? '')?.toLocal();
    final end = DateTime.tryParse(selected['clocked_out_at'] as String? ?? '')?.toLocal();
    setState(() {
      _selectedEntryId = entryId;
      _selectedEntryBaseDate = start;
      _startTime = start != null ? TimeOfDay(hour: start.hour, minute: start.minute) : null;
      _endTime = end != null ? TimeOfDay(hour: end.hour, minute: end.minute) : null;
      _notesController.text = selected['notes'] as String? ?? '';
      _formError = null;
    });
  }

  DateTime _combine(DateTime baseDate, TimeOfDay time) => DateTime(
        baseDate.year, baseDate.month, baseDate.day, time.hour, time.minute,
      );

  Future<void> _save() async {
    if (_selectedUserId == null) {
      setState(() => _formError = 'Select a team member.');
      return;
    }
    if (_mode == 'edit' && _selectedEntryId == null) {
      setState(() => _formError = 'Select which shift to correct.');
      return;
    }
    if (_startTime == null) {
      setState(() => _formError = 'Set a start time.');
      return;
    }
    if (_mode == 'new' && _endTime == null) {
      setState(() => _formError = 'Set an end time.');
      return;
    }

    final baseDate = _mode == 'edit' ? (_selectedEntryBaseDate ?? DateTime.now()) : _selectedDate;
    if (widget.isDateLocked(baseDate)) {
      setState(() => _formError = 'This week is locked for payroll — unlock it first to make changes.');
      return;
    }
    var start = _combine(baseDate, _startTime!);
    DateTime? end = _endTime != null ? _combine(baseDate, _endTime!) : null;
    if (end != null && !end.isAfter(start)) {
      // Overnight shift — end time-of-day is earlier than start, roll to next day.
      end = end.add(const Duration(days: 1));
    }

    setState(() { _formError = null; _saving = true; });

    final notes = _notesController.text.trim().isEmpty ? null : _notesController.text.trim();
    final success = _mode == 'edit'
        ? await widget.onUpdate(_selectedEntryId!, start, end, notes)
        : await widget.onCreate(_selectedUserId!, start, end!, notes);

    if (!mounted) return;
    if (success) {
      Navigator.of(context, rootNavigator: true).pop();
    } else {
      setState(() => _saving = false);
    }
  }

  Widget _modeToggleBtn(String label, String mode) {
    final sel = _mode == mode;
    return Expanded(
      child: Clickable(
        onTap: () => _onModeChanged(mode),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: sel ? AppTheme.brand : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: sel ? Colors.white : AppTheme.textSecondary)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final members = widget.teamProfiles.where((p) => p['user_id'] != null).toList();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Add Time Entry',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
              const SizedBox(height: 4),
              const Text('Nothing is ever deleted here — this only adds a shift or corrects one that was already clocked.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 16),

              Container(
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(children: [
                  _modeToggleBtn('Add New Shift', 'new'),
                  _modeToggleBtn('Correct Existing Shift', 'edit'),
                ]),
              ),
              const SizedBox(height: 20),

              const Text('Team Member', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppTheme.pageBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: DropdownButtonHideUnderline(child: DropdownButton<String>(
                  isExpanded: true,
                  value: _selectedUserId,
                  hint: const Text('Select team member', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                  dropdownColor: AppTheme.cardBg,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  items: members.map((m) => DropdownMenuItem<String>(
                    value: m['user_id'] as String,
                    child: Text(m['full_name'] as String? ?? 'Unknown'),
                  )).toList(),
                  onChanged: _onUserSelected,
                )),
              ),
              const SizedBox(height: 16),

              if (_mode == 'edit') ...[
                const Text('Shift to Correct', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                const SizedBox(height: 6),
                if (_selectedUserId == null)
                  const Text('Select a team member first.', style: TextStyle(fontSize: 12, color: AppTheme.textMuted))
                else if (_entriesLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (_userEntries.where((e) => e['is_week_locked'] != true).isEmpty)
                  const Text('No correctable shifts found in the last 60 days for this team member (some may be in locked pay periods).',
                      style: TextStyle(fontSize: 12, color: AppTheme.textMuted))
                else
                  Builder(builder: (context) {
                    final selectableEntries = _userEntries.where((e) => e['is_week_locked'] != true).toList();
                    final hiddenCount = _userEntries.length - selectableEntries.length;
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: AppTheme.pageBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.borderColor),
                        ),
                        child: DropdownButtonHideUnderline(child: DropdownButton<int>(
                          isExpanded: true,
                          value: _selectedEntryId,
                          hint: const Text('Select a shift', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          dropdownColor: AppTheme.cardBg,
                          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                          items: selectableEntries.map((e) => DropdownMenuItem<int>(
                            value: e['id'] as int,
                            child: Text(_shiftLabel(e)),
                          )).toList(),
                          onChanged: _onEntrySelected,
                        )),
                      ),
                      if (hiddenCount > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          '$hiddenCount shift${hiddenCount == 1 ? '' : 's'} from locked pay period${hiddenCount == 1 ? '' : 's'} not shown here.',
                          style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                        ),
                      ],
                    ]);
                  }),
                const SizedBox(height: 16),
              ],

              if (_mode == 'new') ...[
                const Text('Date', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                const SizedBox(height: 6),
                Clickable(
                  onTap: _pickDate,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppTheme.pageBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.borderColor),
                    ),
                    child: Row(children: [
                      const Icon(Icons.calendar_today_outlined, size: 14, color: AppTheme.textSecondary),
                      const SizedBox(width: 8),
                      Text(_formatDate(_selectedDate), style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                    ]),
                  ),
                ),
                if (widget.isDateLocked(_selectedDate)) ...[
                  const SizedBox(height: 4),
                  const Text('This date falls in a pay period that\'s locked for payroll.',
                      style: TextStyle(fontSize: 10, color: AppTheme.error)),
                ],
                const SizedBox(height: 16),
              ] else if (_selectedEntryBaseDate != null) ...[
                const Text('Date', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: Row(children: [
                    const Icon(Icons.calendar_today_outlined, size: 14, color: AppTheme.textMuted),
                    const SizedBox(width: 8),
                    Text(_formatDate(_selectedEntryBaseDate!), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    const Spacer(),
                    const Text('From original shift', style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                  ]),
                ),
                const SizedBox(height: 4),
                const Text('Only the time of day can be corrected here — not the date.',
                    style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                const SizedBox(height: 16),
              ],

              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Start Time', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                  const SizedBox(height: 6),
                  Clickable(
                    onTap: _pickStartTime,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: Row(children: [
                        const Icon(Icons.schedule_outlined, size: 14, color: AppTheme.textSecondary),
                        const SizedBox(width: 8),
                        Text(_formatTime(_startTime), style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                      ]),
                    ),
                  ),
                ])),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('End Time', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                  const SizedBox(height: 6),
                  Clickable(
                    onTap: _pickEndTime,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: Row(children: [
                        const Icon(Icons.schedule_outlined, size: 14, color: AppTheme.textSecondary),
                        const SizedBox(width: 8),
                        Text(_formatTime(_endTime), style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
                      ]),
                    ),
                  ),
                ])),
              ]),
              const SizedBox(height: 16),

              const Text('Notes (optional)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: _notesController,
                maxLines: 3,
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: _mode == 'edit'
                      ? 'Add a note about this correction'
                      : 'e.g. Forgot to clock in, confirmed with employee',
                  hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                  filled: true,
                  fillColor: AppTheme.pageBg,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppTheme.borderColor),
                  ),
                ),
              ),

              if (_formError != null) ...[
                const SizedBox(height: 10),
                Text(_formError!, style: const TextStyle(fontSize: 12, color: AppTheme.error)),
              ],

              const SizedBox(height: 24),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textSecondary,
                      side: const BorderSide(color: AppTheme.borderColor),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(_mode == 'edit' ? 'Save Correction' : 'Add Entry'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}