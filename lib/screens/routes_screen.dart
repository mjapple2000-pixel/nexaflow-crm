import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';
import '../navigation/app_router.dart';

class RoutesScreen extends StatefulWidget {
  const RoutesScreen({super.key});

  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  final _db = Supabase.instance.client;

  bool _loading = true;
  String? _error;

  // Gate state
  bool _hasAccess = false;   // route_management permission OR owner OR superuser
  bool _planAllows = false;  // check_plan_feature('route_optimization') OR is_beta

  // Team + date selection
  List<Map<String, dynamic>> _teamProfiles = [];
  String? _selectedUserId;
  DateTime _selectedDate = DateTime.now();

  int? _businessId;

  // Stage 2: route data + appointment join
  bool _routeLoading = false;
  bool _creatingRoute = false;
  String? _routeError;
  Map<String, dynamic>? _currentRoute; // routes row, or null if none exists
  Map<int, Map<String, dynamic>> _stopAppointments = {}; // appointment_id -> appointment row

  // Stage 3: instant-save state
  bool _savingStops = false;

  // Stage 3b: add-stop state
  List<Map<String, dynamic>> _availableAppointments = [];
  int? _addingApptId;

  // Phase 3: live map state
  bool _showMap = false;
  Map<String, dynamic>? _liveLocation; // latest team_locations row for _selectedUserId
  RealtimeChannel? _locationChannel;
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _unsubscribeFromLiveLocation();
    super.dispose();
  }

  Future<void> _init() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final activeBusinessId = await getActiveBusinessId();
      if (activeBusinessId == null) throw Exception('No active business');
      _businessId = activeBusinessId;

      final userId = _db.auth.currentUser?.id;
      if (userId == null) throw Exception('Not authenticated');

      // Caller's own profile — determines role + permissions for the gate check.
      final callerProfile = await _db
          .from('profiles')
          .select('role, permissions')
          .eq('user_id', userId)
          .maybeSingle();

      final role = callerProfile?['role'] as String?;
      final permissions = callerProfile?['permissions'] as Map<String, dynamic>?;
      final hasRouteManagement = permissions?['route_management'] == true;
      final isOwner = role == 'owner';
      final isSuperuser = AppRouter.cachedIsSuperuser == true;

      _hasAccess = isOwner || hasRouteManagement || isSuperuser;

      // Plan gate — mirrors optimize-route's own server-side check.
      bool planAllows = false;
      if (isSuperuser) {
        planAllows = true;
      } else {
        final biz = await _db
            .from('businesses')
            .select('is_beta')
            .eq('id', _businessId!)
            .maybeSingle();
        final isBeta = biz?['is_beta'] as bool? ?? false;
        if (isBeta) {
          planAllows = true;
        } else {
          final allowed = await _db.rpc('check_plan_feature', params: {
            'p_business_id': _businessId,
            'p_feature': 'route_optimization',
          });
          planAllows = allowed == true;
        }
      }
      _planAllows = planAllows;

      // Team member list — all team members in the business, no role filter.
      if (_hasAccess && _planAllows) {
        final team = await _db
            .from('profiles')
            .select('id, user_id, full_name')
            .eq('business_id', _businessId!)
            .not('user_id', 'is', null)
            .order('full_name');
        _teamProfiles = List<Map<String, dynamic>>.from(team);
        if (_teamProfiles.isNotEmpty) {
          _selectedUserId = _teamProfiles.first['user_id'] as String;
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    if (_hasAccess && _planAllows && _selectedUserId != null) {
      await _loadRoute();
    }
  }

  String _dateKey(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  /// Fetches all of this business's appointments for the selected day and
  /// filters out ones already present in THIS route's stops. Appointments
  /// already assigned to a different team member still show up — picking one
  /// reassigns it (see _addStop), matching a dispatch-board reassign pattern.
  Future<void> _refreshAvailableAppointments(Set<int> excludeIds) async {
    if (_businessId == null) {
      if (mounted) setState(() => _availableAppointments = []);
      return;
    }

    final dayStart = '${_dateKey(_selectedDate)}T00:00:00';
    final dayEnd = '${_dateKey(_selectedDate)}T23:59:59';
    try {
      final appts = await _db
          .from('appointments')
          .select('id, appointment_name, location, latitude, longitude, start_date_time, assigned_to, lead_id')
          .eq('business_id', _businessId!)
          .gte('start_date_time', dayStart)
          .lte('start_date_time', dayEnd)
          .order('start_date_time');
      if (!mounted) return;
      setState(() {
        _availableAppointments = List<Map<String, dynamic>>.from(appts)
            .where((a) => !excludeIds.contains(a['id']))
            .toList();
        _addingApptId = null;
      });
    } catch (e) {
      // Non-fatal — the Add Stop bar just shows nothing if this fails.
      if (mounted) setState(() => _availableAppointments = []);
    }
  }

  String? _selectedFullName() {
    final teamMember = _teamProfiles.firstWhere(
      (p) => p['user_id'] == _selectedUserId,
      orElse: () => {},
    );
    return teamMember['full_name'] as String?;
  }

  int? _selectedProfileId() {
    final teamMember = _teamProfiles.firstWhere(
      (p) => p['user_id'] == _selectedUserId,
      orElse: () => {},
    );
    return teamMember['id'] as int?;
  }

  Future<void> _fetchInitialLocation() async {
    if (_selectedUserId == null) return;
    try {
      final loc = await _db
          .from('team_locations')
          .select()
          .eq('user_id', _selectedUserId!)
          .maybeSingle();
      if (mounted) setState(() => _liveLocation = loc);
    } catch (e) {
      if (mounted) setState(() => _liveLocation = null);
    }
  }

  void _unsubscribeFromLiveLocation() {
    if (_locationChannel != null) {
      _db.removeChannel(_locationChannel!);
      _locationChannel = null;
    }
  }

  /// Subscribes to live position updates for the currently selected team
  /// member. RLS on team_locations (dispatcher-wide, route_management/owner/
  /// superuser) applies to Realtime the same way it applies to normal
  /// queries, so this only ever streams rows the caller is allowed to see.
  void _subscribeToLiveLocation() {
    _unsubscribeFromLiveLocation();
    if (_selectedUserId == null || _businessId == null) return;
    _fetchInitialLocation();
    _locationChannel = _db
        .channel('team_location_$_selectedUserId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'team_locations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: _selectedUserId!,
          ),
          callback: (payload) {
            if (!mounted) return;
            setState(() => _liveLocation = payload.newRecord);
          },
        )
        .subscribe();
  }

  List<ll.LatLng> _stopPoints() {
    final stops = List<Map<String, dynamic>>.from(_currentRoute?['stops'] as List? ?? []);
    return stops
        .where((s) => s['lat'] != null && s['lng'] != null)
        .map((s) => ll.LatLng((s['lat'] as num).toDouble(), (s['lng'] as num).toDouble()))
        .toList();
  }

  ll.LatLng? _liveLatLng() {
    final lat = _liveLocation?['latitude'];
    final lng = _liveLocation?['longitude'];
    if (lat == null || lng == null) return null;
    return ll.LatLng((lat as num).toDouble(), (lng as num).toDouble());
  }

  // Tampa fallback center — used only when there's no stop or live-location
  // data yet to compute a real center from.
  static const _fallbackCenter = ll.LatLng(27.9506, -82.4572);

  ll.LatLng _mapCenter() {
    final live = _liveLatLng();
    final points = [..._stopPoints(), if (live != null) live];
    if (points.isEmpty) return _fallbackCenter;
    final avgLat = points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
    final avgLng = points.map((p) => p.longitude).reduce((a, b) => a + b) / points.length;
    return ll.LatLng(avgLat, avgLng);
  }

  Future<void> _loadRoute() async {
    if (!mounted || _selectedUserId == null || _businessId == null) return;
    setState(() { _routeLoading = true; _routeError = null; });
    try {
      final route = await _db
          .from('routes')
          .select()
          .eq('business_id', _businessId!)
          .eq('assigned_user_id', _selectedUserId!)
          .eq('route_date', _dateKey(_selectedDate))
          .maybeSingle();

      if (!mounted) return;

      if (route == null) {
        setState(() {
          _currentRoute = null;
          _stopAppointments = {};
        });
        await _refreshAvailableAppointments({});
        _subscribeToLiveLocation();
        return;
      }

      final stops = List<Map<String, dynamic>>.from(route['stops'] as List? ?? []);
      final appointmentIds = stops
          .map((s) => s['appointment_id'])
          .whereType<int>()
          .toList();

      Map<int, Map<String, dynamic>> apptMap = {};
      if (appointmentIds.isNotEmpty) {
        final appts = await _db
            .from('appointments')
            .select('id, appointment_name, location, latitude, longitude, start_date_time, lead_id')
            .eq('business_id', _businessId!)
            .inFilter('id', appointmentIds);
        for (final a in List<Map<String, dynamic>>.from(appts)) {
          apptMap[a['id'] as int] = a;
        }
      }

      if (!mounted) return;
      setState(() {
        _currentRoute = route;
        _stopAppointments = apptMap;
      });
      await _refreshAvailableAppointments(appointmentIds.toSet());
      _subscribeToLiveLocation();
    } catch (e) {
      if (mounted) setState(() => _routeError = e.toString());
    } finally {
      if (mounted) setState(() => _routeLoading = false);
    }
  }

  Future<void> _createRoute() async {
    if (_selectedUserId == null) return;
    setState(() { _creatingRoute = true; _routeError = null; });
    try {
      await _db.auth.refreshSession();
      final token = _db.auth.currentSession?.accessToken;
      if (token == null) throw Exception('Not authenticated');

      final resp = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/optimize-route'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'assigned_user_id': _selectedUserId,
          'route_date': _dateKey(_selectedDate),
        }),
      );
      if (!mounted) return;

      final data = jsonDecode(resp.body);
      if (resp.statusCode != 200 || data['success'] != true) {
        final errCode = data['error'] as String?;
        if (errCode == 'upgrade_required') {
          throw Exception(data['message'] ?? 'Route optimization requires an upgraded plan.');
        }
        if (errCode == 'feature_disabled') {
          throw Exception(data['message'] ?? 'GPS tracking is not enabled for this business.');
        }
        throw Exception(data['error'] ?? 'Failed to create route');
      }

      await _loadRoute();
    } catch (e) {
      if (mounted) setState(() => _routeError = e.toString());
    } finally {
      if (mounted) setState(() => _creatingRoute = false);
    }
  }

  /// Renumbers `sequence` starting at 1 and writes straight to `routes.stops`.
  /// No Save button — every reorder/remove calls this immediately.
  Future<void> _saveStops(List<Map<String, dynamic>> newStops) async {
    if (_currentRoute == null) return;
    final renumbered = <Map<String, dynamic>>[];
    for (var i = 0; i < newStops.length; i++) {
      renumbered.add({
        ...newStops[i],
        'sequence': i + 1,
      });
    }

    // Optimistic local update so the UI feels instant.
    final previousRoute = _currentRoute;
    setState(() {
      _currentRoute = {..._currentRoute!, 'stops': renumbered};
      _savingStops = true;
    });

    try {
      await _db
          .from('routes')
          .update({'stops': renumbered})
          .eq('id', _currentRoute!['id']);
    } catch (e) {
      // Roll back on failure so the UI doesn't lie about what's saved.
      if (mounted) {
        setState(() => _currentRoute = previousRoute);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save route: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _savingStops = false);
    }
  }

  void _handleReorder(int oldIndex, int newIndex) {
    if (_currentRoute == null) return;
    final stops = List<Map<String, dynamic>>.from(_currentRoute!['stops'] as List? ?? []);
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = stops.removeAt(oldIndex);
    stops.insert(newIndex, moved);
    _saveStops(stops);
  }

  Future<void> _removeStop(int index) async {
    if (_currentRoute == null) return;
    final stops = List<Map<String, dynamic>>.from(_currentRoute!['stops'] as List? ?? []);
    if (index < 0 || index >= stops.length) return;
    final removed = stops.removeAt(index);
    final apptId = removed['appointment_id'] as int?;

    await _saveStops(stops);

    if (apptId != null) {
      try {
        await _db.from('appointments').update({
          'assigned_to': null,
          'assigned_to_profile_id': null,
        }).eq('id', apptId);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Stop removed but failed to unassign appointment: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
      await _refreshAvailableAppointments(
        stops.map((s) => s['appointment_id'] as int).toSet(),
      );
    }
  }

  /// If an appointment being added here already sits as a stop on someone
  /// else's route for the same day, strip it from that route so it's never
  /// duplicated across two dispatch boards at once.
  Future<void> _stripStopFromOtherRoutes(int apptId, int excludeRouteId) async {
    if (_businessId == null) return;
    final otherRoutes = await _db
        .from('routes')
        .select('id, stops')
        .eq('business_id', _businessId!)
        .eq('route_date', _dateKey(_selectedDate));

    for (final row in List<Map<String, dynamic>>.from(otherRoutes)) {
      if (row['id'] == excludeRouteId) continue;
      final stops = List<Map<String, dynamic>>.from(row['stops'] as List? ?? []);
      if (!stops.any((s) => s['appointment_id'] == apptId)) continue;

      final remaining = stops.where((s) => s['appointment_id'] != apptId).toList();
      final renumbered = <Map<String, dynamic>>[];
      for (var i = 0; i < remaining.length; i++) {
        renumbered.add({...remaining[i], 'sequence': i + 1});
      }
      await _db.from('routes').update({'stops': renumbered}).eq('id', row['id']);
    }
  }

  Future<void> _addStop(int apptId) async {
    if (_currentRoute == null || _selectedUserId == null) return;
    final appt = _availableAppointments.firstWhere(
      (a) => a['id'] == apptId,
      orElse: () => {},
    );
    if (appt.isEmpty) return;

    final fullName = _selectedFullName();
    if (fullName == null) return;

    setState(() => _addingApptId = null);

    try {
      final previousAssignee = appt['assigned_to'] as String?;
      if (previousAssignee != null && previousAssignee != fullName) {
        await _stripStopFromOtherRoutes(apptId, _currentRoute!['id'] as int);
      }

      await _db.from('appointments').update({
        'assigned_to': fullName,
        'assigned_to_profile_id': _selectedProfileId(),
      }).eq('id', apptId);

      final stops = List<Map<String, dynamic>>.from(_currentRoute!['stops'] as List? ?? []);
      stops.add({
        'appointment_id': apptId,
        'sequence': stops.length + 1,
        'lat': appt['latitude'],
        'lng': appt['longitude'],
      });

      setState(() {
        _stopAppointments = {..._stopAppointments, apptId: appt};
      });

      await _saveStops(stops);
      await _refreshAvailableAppointments(
        stops.map((s) => s['appointment_id'] as int).toSet(),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add stop: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (!mounted || picked == null) return;
    setState(() => _selectedDate = picked);
    await _loadRoute();
  }

  void _shiftDate(int days) {
    setState(() => _selectedDate = _selectedDate.add(Duration(days: days)));
    _loadRoute();
  }

  String _formatDate(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        _buildTopBar(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.error)))
                  : !_hasAccess
                      ? _buildNoAccessState()
                      : !_planAllows
                          ? _buildTeaserState()
                          : _buildMainContent(),
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
        const Text('Routes',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
        if (_savingStops) ...[
          const SizedBox(width: 12),
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 6),
          const Text('Saving…', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ],
        const Spacer(),
        if (!_loading && _hasAccess && _planAllows) ...[
          _buildTeamPicker(),
          const SizedBox(width: 10),
          _buildDatePicker(),
          if (_currentRoute != null) ...[
            const SizedBox(width: 10),
            _buildViewToggle(),
          ],
        ],
      ]),
    );
  }

  Widget _buildTeamPicker() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.pageBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(
        value: _selectedUserId,
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        items: _teamProfiles.map((p) => DropdownMenuItem<String>(
          value: p['user_id'] as String,
          child: Text(p['full_name'] as String? ?? 'Unknown'),
        )).toList(),
        onChanged: (v) {
          setState(() => _selectedUserId = v);
          _loadRoute();
        },
      )),
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
        _viewToggleButton('List', Icons.list, !_showMap, () => setState(() => _showMap = false)),
        _viewToggleButton('Map', Icons.map_outlined, _showMap, () => setState(() => _showMap = true)),
      ]),
    );
  }

  Widget _viewToggleButton(String label, IconData icon, bool selected, VoidCallback onTap) {
    return Clickable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppTheme.brand.withValues(alpha: 0.1) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: selected ? AppTheme.brand : AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: selected ? AppTheme.brand : AppTheme.textSecondary)),
        ]),
      ),
    );
  }

  Widget _buildDatePicker() {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        onPressed: () => _shiftDate(-1),
        icon: const Icon(Icons.chevron_left, size: 20, color: AppTheme.textSecondary),
        tooltip: 'Previous day',
      ),
      Clickable(
        onTap: _pickDate,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.pageBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderColor),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.calendar_today_outlined, size: 13, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(_formatDate(_selectedDate),
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
          ]),
        ),
      ),
      IconButton(
        onPressed: () => _shiftDate(1),
        icon: const Icon(Icons.chevron_right, size: 20, color: AppTheme.textSecondary),
        tooltip: 'Next day',
      ),
    ]);
  }

  Widget _buildNoAccessState() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lock_outline, size: 40, color: AppTheme.textMuted),
          const SizedBox(height: 16),
          const Text('No Access to Routes',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          const Text(
              'Ask your business owner to grant you route management access.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }

  Widget _buildTeaserState() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderColor),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.route_outlined, size: 40, color: AppTheme.brand),
          const SizedBox(height: 16),
          const Text('Route Optimization',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          const Text(
              'Automatically build the fastest route for your team and manage stops in real time. Available on the Growth plan and above.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5)),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () => context.go('/settings?section=billing'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Upgrade Plan', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }

  Widget _buildMainContent() {
    if (_routeLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_routeError != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_routeError!, style: const TextStyle(color: AppTheme.error), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _loadRoute, child: const Text('Retry')),
        ]),
      );
    }
    if (_currentRoute == null) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.route_outlined, size: 40, color: AppTheme.textMuted),
            const SizedBox(height: 16),
            const Text('No Route Yet',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            const Text(
                'Build an optimized route from this team member\'s scheduled appointments for the selected day.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _creatingRoute ? null : _createRoute,
              icon: _creatingRoute
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.auto_awesome, size: 16),
              label: const Text('Create Route', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ]),
        ),
      );
    }

    // Route exists — draggable, instantly-saving stop list.
    final stops = List<Map<String, dynamic>>.from(_currentRoute!['stops'] as List? ?? []);
    if (stops.isEmpty) {
      return Column(children: [
        Expanded(
          child: _showMap
              ? _buildMapView()
              : const Center(
                  child: Text('This route has no stops.', style: TextStyle(color: AppTheme.textSecondary)),
                ),
        ),
        _buildAddStopBar(),
      ]);
    }
    return Column(children: [
      Expanded(
        child: _showMap ? _buildMapView() : ReorderableListView.builder(
          padding: const EdgeInsets.all(24),
          itemCount: stops.length,
          onReorder: _handleReorder,
          buildDefaultDragHandles: false,
          itemBuilder: (_, i) {
            final stop = stops[i];
            final apptId = stop['appointment_id'] as int?;
            final appt = apptId != null ? _stopAppointments[apptId] : null;
            final hasLocation = stop['lat'] != null && stop['lng'] != null;
            return Container(
              key: ValueKey('stop-$i-${apptId ?? 'none'}'),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Row(children: [
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.only(right: 10),
                    child: Icon(Icons.drag_handle, size: 20, color: AppTheme.textSecondary),
                  ),
                ),
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(color: AppTheme.brand, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: Text('${stop['sequence'] ?? i + 1}',
                      style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Clickable(
                  onTap: appt?['lead_id'] != null
                      ? () => context.go('/contacts/${appt!['lead_id']}')
                      : null,
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(appt?['appointment_name'] as String? ?? 'Unknown appointment',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                      if (appt?['location'] != null)
                        Text(appt!['location'] as String,
                            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                      if (!hasLocation)
                        const Text('No location — not optimized',
                            style: TextStyle(fontSize: 11, color: AppTheme.error)),
                    ])),
                    if (appt?['lead_id'] != null)
                      const Icon(Icons.chevron_right, size: 18, color: AppTheme.textMuted),
                  ]),
                )),
                IconButton(
                  onPressed: () => _removeStop(i),
                  icon: const Icon(Icons.close, size: 20, color: AppTheme.textSecondary),
                  tooltip: 'Remove stop',
                ),
              ]),
            );
          },
        ),
      ),
      _buildAddStopBar(),
    ]);
  }

  // Map tiles come from OpenStreetMap — free, no API key required. To switch
  // to Google Maps later (e.g. once billing is set up), replace the
  // TileLayer's urlTemplate below with a Google-tiles source, or swap this
  // whole widget for google_maps_flutter. Nothing else in this file (stop
  // data, Realtime subscription, geometry helpers) needs to change.
  Widget _buildMapView() {
    final stops = List<Map<String, dynamic>>.from(_currentRoute?['stops'] as List? ?? []);
    final stopPoints = _stopPoints();
    final live = _liveLatLng();

    return Stack(children: [
      FlutterMap(
        mapController: _mapController,
        options: MapOptions(initialCenter: _mapCenter(), initialZoom: 11),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.nexaflow.crm',
          ),
          if (stopPoints.length > 1)
            PolylineLayer(polylines: [
              Polyline(points: stopPoints, strokeWidth: 3, color: AppTheme.brand),
            ]),
          MarkerLayer(markers: [
            for (var i = 0; i < stops.length; i++)
              if (stops[i]['lat'] != null && stops[i]['lng'] != null)
                Marker(
                  point: ll.LatLng((stops[i]['lat'] as num).toDouble(), (stops[i]['lng'] as num).toDouble()),
                  width: 32,
                  height: 32,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppTheme.brand,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text('${stops[i]['sequence'] ?? i + 1}',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
            if (live != null)
              Marker(
                point: live,
                width: 36,
                height: 36,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.success,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                  child: const Icon(Icons.person_pin_circle, color: Colors.white, size: 20),
                ),
              ),
          ]),
        ],
      ),
      if (live == null)
        Positioned(
          top: 12, left: 12, right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderColor),
            ),
            child: Text(
              '${_selectedFullName() ?? 'This team member'} hasn\'t shared their location yet.',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
        ),
    ]);
  }

  Widget _buildAddStopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: AppTheme.cardBg,
        border: Border(top: BorderSide(color: AppTheme.borderColor)),
      ),
      child: _availableAppointments.isEmpty
          ? const Text('No additional appointments available to add for this day.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
          : Row(children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderColor),
                  ),
                  child: DropdownButtonHideUnderline(child: DropdownButton<int>(
                    value: _addingApptId,
                    isExpanded: true,
                    hint: const Text('Select an appointment to add',
                        style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    items: _availableAppointments.map((a) {
                      final name = a['appointment_name'] as String? ?? 'Appointment';
                      final location = a['location'] as String?;
                      final assignedTo = a['assigned_to'] as String?;
                      final isReassign = assignedTo != null && assignedTo != _selectedFullName();
                      var label = location != null ? '$name — $location' : name;
                      if (isReassign) label = '$label (currently: $assignedTo)';
                      return DropdownMenuItem<int>(
                        value: a['id'] as int,
                        child: Text(label, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13,
                                color: isReassign ? AppTheme.error : AppTheme.textPrimary)),
                      );
                    }).toList(),
                    onChanged: (v) => setState(() => _addingApptId = v),
                  )),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: _addingApptId == null ? null : () => _addStop(_addingApptId!),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Stop', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ]),
    );
  }
}