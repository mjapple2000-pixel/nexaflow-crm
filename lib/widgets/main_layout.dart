import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../widgets/nexaflow_support_bubble.dart';
import '../navigation/app_router.dart';
import '../screens/business_picker_screen.dart';
import '../screens/tickets_screen.dart';
import '../utils/business_utils.dart';

// Below this width, show the "please use desktop" screen
const double _kMinDesktopWidth = 800;

class MainLayout extends StatelessWidget {
  final Widget child;
  const MainLayout({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    if (width < _kMinDesktopWidth) {
      return const _DesktopOnlyScreen();
    }

    return Scaffold(
  body: Stack(
    children: [
      Row(
        children: [
          AppNavBar(),
          Expanded(child: child),
        ],
      ),
      const NexaFlowSupportBubble(),
    ],
  ),
);
  }
}

// ─────────────────────────────────────────────
//  DESKTOP ONLY SCREEN
// ─────────────────────────────────────────────
class _DesktopOnlyScreen extends StatelessWidget {
  const _DesktopOnlyScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppTheme.brand,
                  borderRadius: BorderRadius.circular(18),
                ),
                alignment: Alignment.center,
                child: const Text('N',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 36,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 24),
              const Text('NexaFlow',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 12),
              const Icon(Icons.desktop_windows_outlined,
                  size: 48, color: AppTheme.textSecondary),
              const SizedBox(height: 20),
              const Text(
                'Please use a desktop browser',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              const Text(
                'NexaFlow is optimised for desktop.\nFor the best experience, open it on a larger screen.',
                style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                    height: 1.5),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  NAVBAR
// ─────────────────────────────────────────────
class AppNavBar extends StatefulWidget {
  const AppNavBar({super.key});

  @override
  State<AppNavBar> createState() => _AppNavBarState();
}

class _AppNavBarState extends State<AppNavBar> {
  final _supabase = Supabase.instance.client;

  int _unreadCount = 0;
  RealtimeChannel? _unreadChannel;

  Map<String, dynamic>? _activeTimeEntry;
  Timer? _clockCheckTimer;

  // Profile state
  String _role        = 'member';
  Map<String, dynamic> _permissions = {};
  bool _profileLoaded = false;
  StreamSubscription<AuthState>? _authSub;

  // Settings nav sections (mirrors settings_screen.dart _sections)
  static const _settingsSections = [
    // MY BUSINESS (indices 0–10, .take(11))
    ('/settings',                          Icons.business_outlined,          'Business Profile'),
    ('/settings?section=profile',          Icons.person_outline,             'My Profile'),
    ('/settings?section=ai',               Icons.smart_toy_outlined,         'AI Settings'),
    ('/settings?section=knowledge',        Icons.menu_book_outlined,         'Knowledge Base'),
    ('/settings?section=phone',            Icons.phone_outlined,             'AI Phone Number'),
    ('/settings?section=email',            Icons.email_outlined,             'Email Config'),
    ('/settings?section=team',             Icons.people_outline,             'My Staff'),
    ('/settings?section=notifications',    Icons.notifications_outlined,     'Notifications'),
    ('/settings?section=payments',         Icons.payments_outlined,          'Payment Options'),
    ('/settings?section=social',           Icons.share_rounded,              'Social Media'),
    ('/settings?section=billing',          Icons.credit_card_outlined,       'Billing'),
    // BUSINESS SERVICES (indices 11–19, .skip(11).take(9))
    ('/settings?section=pipelines',        Icons.bar_chart_rounded,          'Opportunities & Pipelines'),
    ('/settings?section=automation',       Icons.bolt_outlined,              'Automation'),
    ('/settings?section=calendars',        Icons.calendar_today_outlined,    'Calendars'),
    ('/settings?section=conversation_ai',  Icons.chat_bubble_outline_rounded,'Conversation AI'),
    ('/settings?section=voice_ai',         Icons.mic_outlined,               'Voice AI Agents'),
    ('/settings?section=email_services',   Icons.alternate_email_rounded,    'Email Services'),
    ('/settings?section=phone_numbers',    Icons.phone_in_talk_outlined,     'Phone Numbers'),
    ('/settings?section=whatsapp',         Icons.message_outlined,           'WhatsApp'),
    // OTHER SETTINGS (indices 19+, .skip(19))
    ('/settings?section=objects',          Icons.category_outlined,          'Objects'),
    ('/settings?section=custom_fields',    Icons.tune_rounded,               'Custom Fields'),
    ('/settings?section=custom_values',    Icons.data_object_rounded,        'Custom Values'),
    ('/settings?section=scoring',          Icons.scoreboard_outlined,        'Manage Scoring'),
    ('/settings?section=domains',          Icons.language_rounded,           'Domains'),
    ('/settings?section=url_redirects',    Icons.alt_route_rounded,          'URL Redirects'),
        // JOBS
    ('/settings?section=service_library', Icons.inventory_2_outlined,       'Service Library'),
    ('/settings?section=job_types',        Icons.category_outlined,         'Job Types'),
    ('/settings?section=expense_categories', Icons.receipt_long_outlined,   'Expense Categories'),
    ('/settings?section=payroll',          Icons.calendar_view_week_outlined, 'Payroll'),
    // DOCUMENTS
    ('/settings?section=documents',        Icons.picture_as_pdf_outlined,   'Client Document Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadUnreadCount();
    _subscribeToUnread();
    _checkActiveTimeEntry();
    _clockCheckTimer = Timer.periodic(const Duration(seconds: 60), (_) => _checkActiveTimeEntry());
    // On a hard browser reload, Supabase's session restore from local storage
    // is async — if _loadProfile() races ahead of it, the profile query comes
    // back null/empty and role+permissions silently stick at their 'member'/{}
    // defaults, collapsing the sidebar to just Launchpad+Dashboard. Re-run
    // _loadProfile() once a real session is confirmed so a reload never
    // leaves the sidebar stuck in that state.
    _authSub = _supabase.auth.onAuthStateChange.listen((state) {
      if (state.session != null) _loadProfile();
    });
  }

  @override
  void dispose() {
    _unreadChannel?.unsubscribe();
    _clockCheckTimer?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _checkActiveTimeEntry() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;
      final entry = await _supabase
          .from('time_entries')
          .select()
          .eq('user_id', userId)
          .eq('status', 'active')
          .filter('deleted_at', 'is', null)
          .maybeSingle();
      if (mounted) setState(() => _activeTimeEntry = entry);
    } catch (e) {
      debugPrint('Clock status check error: $e');
    }
  }

  // ── Load role + permissions + unread in one query ─────────────────────────
  Future<void> _loadProfile() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      final profile = await _supabase
          .from('profiles')
          .select('role, permissions, business_id')
          .eq('user_id', userId)
          .maybeSingle();

      if (!mounted) return;
      if (profile != null) {
        setState(() {
          _role        = profile['role'] as String? ?? 'member';
          _permissions = Map<String, dynamic>.from(
              (profile['permissions'] as Map?)  ?? {});
          _profileLoaded = true;
        });
      } else {
        // No profile row (e.g. superuser) — still mark loaded so the
        // sidebar renders; _can() already bypasses via cachedIsSuperuser.
        setState(() => _profileLoaded = true);
      }
    } catch (e) {
      debugPrint('Profile load error: $e');
      if (mounted) setState(() => _profileLoaded = true);
    }
  }

  Future<void> _loadUnreadCount() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;
      final profileRes = await _supabase
          .from('profiles')
          .select('business_id')
          .eq('user_id', userId)
          .maybeSingle();
      final businessId = profileRes?['business_id'] as int?;
      if (businessId == null) return;
      final res = await _supabase
          .from('conversations')
          .select('unread_count')
          .eq('business_id', businessId);
      final total = (res as List)
          .fold(0, (s, c) => s + ((c['unread_count'] as int?) ?? 0));
      if (mounted) setState(() => _unreadCount = total);
    } catch (e) {
      debugPrint('Unread badge error: $e');
    }
  }

  void _subscribeToUnread() {
    _unreadChannel = _supabase
        .channel('nav_unread_watch')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'conversations',
          callback: (_) => _loadUnreadCount(),
        )
        .subscribe();
  }

  // ── Owners see everything. Members only see permitted pages. ──────────────
  // Launchpad and Dashboard are always visible to everyone.
  bool _can(String key) {
    if (AppRouter.cachedIsSuperuser == true) return true;
    if (_role == 'owner' || _role == 'admin') return true;
    return _permissions[key] == true;
  }

  // Parallel to _settingsSections, same order, one entry per section.
  // null = always visible (My Profile — everyone manages their own
  // account regardless of role or permissions).
  static const List<String?> _settingsPermissionKeys = [
    'settings_business_profile',
    null, // My Profile
    'settings_ai',
    'settings_knowledge',
    'settings_phone',
    'settings_email',
    'settings_team',
    'settings_notifications',
    'settings_payments',
    'settings_social',
    'settings_billing',
    'settings_pipelines',
    'settings_automation',
    'settings_calendars',
    'settings_conversation_ai',
    'settings_voice_ai',
    'settings_email_services',
    'settings_phone_numbers',
    'settings_whatsapp',
    'settings_objects',
    'settings_custom_fields',
    'settings_custom_values',
    'settings_scoring',
    'settings_domains',
    'settings_url_redirects',
    'settings_service_library',
    'settings_job_types',
    'settings_expense_categories', // position 27 in _settingsSections
    'settings_payroll',            // position 28 in _settingsSections
    'settings_documents',          // position 29 in _settingsSections
  ];

  // A single granted page's worth of access. Honors a legacy blanket
  // 'settings' grant too, so nobody who was already given full access
  // loses it silently — going forward, new grants should be per-page.
  bool _hasSettingsPageAccess(String? key) {
    if (key == null) return true; // My Profile
    if (AppRouter.cachedIsSuperuser == true) return true;
    if (_role == 'owner' || _role == 'admin') return true;
    if (_permissions['settings'] == true) return true;
    return _permissions[key] == true;
  }

  // Whether the main "Settings" nav item itself should show at all —
  // true if they can reach at least one page inside it.
  bool _hasAnySettingsAccess() {
    if (AppRouter.cachedIsSuperuser == true) return true;
    if (_role == 'owner' || _role == 'admin') return true;
    if (_permissions['settings'] == true) return true;
    return _settingsPermissionKeys.any((k) => k != null && _permissions[k] == true);
  }

  // Returns only the entries in _settingsSections[start, start+count)
  // that this user can actually reach.
  List<(String, IconData, String)> _visibleSettingsSlice(int start, int count) {
    final slice = <(String, IconData, String)>[];
    for (int i = start; i < start + count && i < _settingsSections.length; i++) {
      if (_hasSettingsPageAccess(_settingsPermissionKeys[i])) {
        slice.add(_settingsSections[i]);
      }
    }
    return slice;
  }

  // Someone with only Timesheets access has no reason to land on the Jobs
  // Overview page — they'd see a dashboard for a section they can't use.
  // Send them straight to whichever Jobs sub-page they actually have,
  // in the same priority order the Jobs sub-nav itself displays them.
  String _jobsLandingRoute() {
    if (_can('jobs_overview')) return '/jobs';
    if (_can('job_board')) return '/jobs/board';
    if (_can('timesheets')) return '/timesheets';
    if (_can('routes')) return '/routes';
    if (_can('manage_job_forms')) return '/jobs/manage-forms';
    return '/jobs';
  }

  Widget _buildJobsNav(BuildContext context, String location) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      primary: false,
      physics: const ClampingScrollPhysics(),
      children: [
        Clickable(
          onTap: () => context.go('/dashboard'),
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
            ),
            child: const Row(
              children: [
                Icon(Icons.arrow_back_rounded, size: 14, color: Colors.white),
                SizedBox(width: 8),
                Text('Go Back',
                    style: TextStyle(fontSize: 12.5, color: Colors.white, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
        _SectionLabel('Jobs'),
        if (_can('jobs_overview'))
          _NavItem(
            icon: Icons.space_dashboard_outlined,
            label: 'Overview',
            route: '/jobs',
            active: location == '/jobs',
          ),
        if (_can('job_board'))
          _NavItem(
            icon: Icons.work_outline_rounded,
            label: 'Job Board',
            route: '/jobs/board',
            active: location.startsWith('/jobs/board'),
          ),
        if (_can('timesheets'))
          _NavItem(
            icon: Icons.access_time_outlined,
            label: 'Timesheets',
            route: '/timesheets',
            active: location.startsWith('/timesheets'),
          ),
        if (_can('routes'))
          _NavItem(
            icon: Icons.route_outlined,
            label: 'Routes',
            route: '/routes',
            active: location.startsWith('/routes'),
          ),
        if (_can('manage_job_forms'))
          _NavItem(
            icon: Icons.checklist_rtl_rounded,
            label: 'Manage Job Forms',
            route: '/jobs/manage-forms',
            active: location.startsWith('/jobs/manage-forms'),
          ),
      ],
    );
  }

  Widget _buildSettingsNav(BuildContext context, String location) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      primary: false,
      physics: const ClampingScrollPhysics(),
      children: [
        Clickable(
          onTap: () => context.go('/dashboard'),
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
            ),
            child: const Row(
              children: [
                Icon(Icons.arrow_back_rounded, size: 14, color: Colors.white),
                SizedBox(width: 8),
                Text('Go Back',
                    style: TextStyle(fontSize: 12.5, color: Colors.white, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
        _SectionLabel('My Business'),
        ..._visibleSettingsSlice(0, 11).map((s) {
          final isActive = location == s.$1 ||
              (s.$1 == '/settings' && location == '/settings');
          return Clickable(
            onTap: () => context.go(s.$1),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: isActive ? AppTheme.brandActive : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    color: isActive ? AppTheme.brand : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(s.$2, size: 16,
                      color: isActive ? AppTheme.textActive : AppTheme.textNormal),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(s.$3,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isActive ? AppTheme.textActive : AppTheme.textNormal,
                        )),
                  ),
                ],
              ),
            ),
          );
        }),
        _SectionLabel('Business Services'),
        ..._visibleSettingsSlice(11, 8).map((s) {
          final isActive = location == s.$1;
          return Clickable(
            onTap: () => context.go(s.$1),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: isActive ? AppTheme.brandActive : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    color: isActive ? AppTheme.brand : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(s.$2, size: 16,
                      color: isActive ? AppTheme.textActive : AppTheme.textNormal),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(s.$3,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isActive ? AppTheme.textActive : AppTheme.textNormal,
                        )),
                  ),
                ],
              ),
            ),
          );
        }),
                _SectionLabel('Other Settings'),
        ..._visibleSettingsSlice(19, 6).map((s) {
          final isActive = location == s.$1 ||
              (s.$1 == '/settings' && location == '/settings');
          return Clickable(
            onTap: () => context.go(s.$1),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: isActive ? AppTheme.brandActive : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    color: isActive ? AppTheme.brand : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(s.$2, size: 16,
                      color: isActive ? AppTheme.textActive : AppTheme.textNormal),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(s.$3,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isActive ? AppTheme.textActive : AppTheme.textNormal,
                        )),
                  ),
                ],
              ),
            ),
          );
        }),

        // JOBS SECTION
        _SectionLabel('JOBS'),
        ..._visibleSettingsSlice(25, 4).map((s) {
          final isActive = location == s.$1;
          return Clickable(
            onTap: () => context.go(s.$1),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: isActive ? AppTheme.brandActive : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    color: isActive ? AppTheme.brand : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(s.$2, size: 16,
                      color: isActive ? AppTheme.textActive : AppTheme.textNormal),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(s.$3,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isActive ? AppTheme.textActive : AppTheme.textNormal,
                        )),
                  ),
                ],
              ),
            ),
          );
        }),

        // DOCUMENTS SECTION
        _SectionLabel('DOCUMENTS'),
        ..._visibleSettingsSlice(29, 1).map((s) {
          final isActive = location == s.$1;
          return Clickable(
            onTap: () => context.go(s.$1),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: isActive ? AppTheme.brandActive : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    color: isActive ? AppTheme.brand : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(s.$2, size: 16,
                      color: isActive ? AppTheme.textActive : AppTheme.textNormal),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(s.$3,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isActive ? AppTheme.textActive : AppTheme.textNormal,
                        )),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final String location = GoRouterState.of(context).uri.toString();

    // Don't render nav items until permissions are loaded —
    // prevents a flash where member briefly sees all items
    if (!_profileLoaded) {
      return Material(
        color: AppTheme.sidebarBg,
        child: SizedBox(
          width: 220,
          height: double.infinity,
          child: Column(
            children: [
              _LogoArea(),
              const Expanded(
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.brand,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: AppTheme.sidebarBg,
      child: SizedBox(
        width: 220,
        height: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LogoArea(),
            _SidebarSearch(),

            // ── Superuser business switcher — only visible to superusers ──
            if (AppRouter.cachedIsSuperuser == true)
              _SuperuserBanner(),

            if (_activeTimeEntry != null)
              _ClockedInBanner(clockedInAt: _activeTimeEntry!['clocked_in_at'] as String?),

            Expanded(
              child: location.startsWith('/settings')
                  ? _buildSettingsNav(context, location)
                  : (location.startsWith('/jobs') || location.startsWith('/timesheets') || location.startsWith('/routes'))
                      ? _buildJobsNav(context, location)
                      : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      primary: false,
                      physics: const ClampingScrollPhysics(),
                      children: [
                  // ── MAIN — always visible ──────────────────────────────
                  _SectionLabel('Main'),
                  _NavItem(
                    icon: Icons.rocket_launch_rounded,
                    label: 'Launchpad',
                    route: '/launchpad',
                    active: location.startsWith('/launchpad'),
                  ),
                  _NavItem(
                    icon: Icons.grid_view_rounded,
                    label: 'Dashboard',
                    route: '/dashboard',
                    active: location.startsWith('/dashboard'),
                  ),

                  // ── CRM ───────────────────────────────────────────────
                  if (_can('contacts') || _can('pipelines') || _can('appointments') || _can('tasks'))
                    _SectionLabel('CRM'),
                  if (_can('contacts'))
                    _NavItem(
                      icon: Icons.people_alt_outlined,
                      label: 'Contacts',
                      route: '/contacts',
                      active: location.startsWith('/contacts'),
                    ),
                  
                  if (_can('pipelines'))
                    _NavItem(
                      icon: Icons.bar_chart_rounded,
                      label: 'Opportunities',
                      route: '/opportunities',
                      active: location.startsWith('/opportunities'),
                    ),
                  if (_can('appointments'))
                    _NavItem(
                      icon: Icons.calendar_today_outlined,
                      label: 'Calendars',
                      route: '/appointments',
                      active: location.startsWith('/appointments'),
                    ),
                  if (_can('jobs_overview') || _can('job_board') || _can('timesheets') || _can('routes') || _can('manage_job_forms'))
                    _NavItem(
                      icon: Icons.work_outline_rounded,
                      label: 'Jobs',
                      route: _jobsLandingRoute(),
                      active: location.startsWith('/jobs') || location.startsWith('/timesheets') || location.startsWith('/routes'),
                    ),
                  if (_can('tasks'))
                    _NavItem(
                      icon: Icons.task_alt_outlined,
                      label: 'Tasks',
                      route: '/tasks',
                      active: location.startsWith('/tasks'),
                    ),

                  // ── MARKETING ─────────────────────────────────────────
                  if (_can('campaigns'))
                    _SectionLabel('Marketing'),
                  if (_can('campaigns'))
                    _NavItem(
                      icon: Icons.campaign_outlined,
                      label: 'Campaigns',
                      route: '/campaigns',
                      active: location.startsWith('/campaigns'),
                    ),

                  // ── ENGAGE ────────────────────────────────────────────
                  if (_can('conversations') || _can('automations'))
                    _SectionLabel('Engage'),
                  if (_can('conversations'))
                    _NavItem(
                      icon: Icons.chat_bubble_outline_rounded,
                      label: 'Conversations',
                      route: '/conversations',
                      active: location.startsWith('/conversations'),
                      badge: _unreadCount > 0 ? '$_unreadCount' : null,
                    ),
                  if (_can('automations'))
                    _NavItem(
                      icon: Icons.bolt_outlined,
                      label: 'Automations',
                      route: '/automations',
                      active: location.startsWith('/automations'),
                    ),

                  // ── ANALYTICS ─────────────────────────────────────────
                  if (_can('reporting'))
                    _SectionLabel('Analytics'),
                  if (_can('reporting'))
                    _NavItem(
                      icon: Icons.show_chart_rounded,
                      label: 'Reporting',
                      route: '/reporting',
                      active: location.startsWith('/reporting'),
                    ),

                  // ── ACCOUNT ───────────────────────────────────────────
                  if (_can('forms') || _can('ai_chat') || _can('settings'))
                    _SectionLabel('Account'),
                  if (_can('forms'))
                    _NavItem(
                      icon: Icons.dynamic_form_outlined,
                      label: 'Forms',
                      route: '/forms',
                      active: location.startsWith('/forms'),
                    ),
                  if (_can('ai_chat'))
                    _NavItem(
                      icon: Icons.smart_toy_outlined,
                      label: 'AI Chat Widget',
                      route: '/ai-chat',
                      active: location.startsWith('/ai-chat'),
                    ),
                  if (_hasAnySettingsAccess())
                    _NavItem(
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      route: '/settings',
                      active: location.startsWith('/settings'),
                    ),
                  if (_can('settings'))
                    _NavItem(
                      icon: Icons.star_outline,
                      label: 'Reviews',
                      route: '/reviews',
                      active: location.startsWith('/reviews'),
                    ),
                    // ── SUPERUSER ONLY ────────────────────────────────────
                  if (AppRouter.cachedIsSuperuser == true) ...[
                    _SectionLabel('Admin'),
                    _NavItem(
                      icon: Icons.confirmation_number_outlined,
                      label: 'Support Tickets',
                      route: '/tickets',
                      active: location.startsWith('/tickets'),
                    ),
                    _NavItem(
                      icon: Icons.science_outlined,
                      label: 'Beta Testers',
                      route: '/beta-testers',
                      active: location.startsWith('/beta-testers'),
                    ),
                  ],
                ],
              ),
            ),
            _UserRow(),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  SUPERUSER BUSINESS SWITCHER BANNER
// ─────────────────────────────────────────────
// ─────────────────────────────────────────────
//  SIDEBAR SEARCH
// ─────────────────────────────────────────────
class _SidebarSearch extends StatefulWidget {
  @override
  State<_SidebarSearch> createState() => _SidebarSearchState();
}

class _SidebarSearchState extends State<_SidebarSearch> {
  final _ctrl   = TextEditingController();
  final _focus  = FocusNode();
  final _db     = Supabase.instance.client;

  Timer?        _debounce;
  bool          _loading = false;

  List<_SearchResult> _results = [];

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _debounce?.cancel();
    super.dispose();
  }


  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q.trim()));
  }

  Future<void> _search(String q) async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final bizId = await _loadBizId();
      if (!mounted) return;
      if (bizId == null) {
        return;
      }

      final lower = q.toLowerCase();

      final results = <_SearchResult>[];

      // Contacts
      final contacts = await _db.from('leads')
          .select('id, lead_name, lead_phone, lead_email')
          .eq('business_id', bizId)
          .or('lead_name.ilike.%$lower%,lead_phone.ilike.%$lower%,lead_email.ilike.%$lower%')
          .limit(4);
      for (final c in (contacts as List)) {
        results.add(_SearchResult(
          type: 'Contact',
          title: c['lead_name'] ?? 'Unknown',
          subtitle: c['lead_phone'] ?? c['lead_email'] ?? '',
          icon: Icons.person_outline,
          color: const Color(0xFF6366F1),
          route: '/contacts/${c['id']}',
        ));
      }

      // Deals
      final deals = await _db.from('deals')
          .select('id, deal_name, value, status')
          .eq('business_id', bizId)
          .ilike('deal_name', '%$lower%')
          .limit(3);
      for (final d in (deals as List)) {
        final val = (d['value'] as num?)?.toDouble() ?? 0;
        final valStr = val >= 1000
            ? '\$${(val / 1000).toStringAsFixed(1)}K'
            : '\$${val.toStringAsFixed(0)}';
        results.add(_SearchResult(
          type: 'Deal',
          title: d['deal_name'] ?? 'Untitled',
          subtitle: '$valStr · ${(d['status'] ?? 'open').toString().toUpperCase()}',
          icon: Icons.handshake_outlined,
          color: const Color(0xFF10B981),
          route: '/opportunities',
        ));
      }

      // Appointments
      final appts = await _db.from('appointments')
          .select('id, appointment_name, lead_name, start_date_time')
          .eq('business_id', bizId)
          .or('appointment_name.ilike.%$lower%,lead_name.ilike.%$lower%')
          .limit(3);
      for (final a in (appts as List)) {
        final dt = DateTime.tryParse(a['start_date_time'] ?? '')?.toLocal();
        const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        final dtStr = dt != null ? '${months[dt.month]} ${dt.day}' : '';
        results.add(_SearchResult(
          type: 'Appointment',
          title: a['appointment_name'] ?? 'Untitled',
          subtitle: '${a['lead_name'] ?? ''}${dtStr.isNotEmpty ? ' · $dtStr' : ''}',
          icon: Icons.calendar_today_outlined,
          color: const Color(0xFF0EA5E9),
          route: '/appointments',
        ));
      }

      // Conversations
      final convos = await _db.from('conversations')
          .select('id, contact_name, last_message')
          .eq('business_id', bizId)
          .ilike('contact_name', '%$lower%')
          .limit(3);
      for (final c in (convos as List)) {
        results.add(_SearchResult(
          type: 'Conversation',
          title: c['contact_name'] ?? 'Unknown',
          subtitle: c['last_message'] ?? '',
          icon: Icons.chat_bubble_outline_rounded,
          color: const Color(0xFFf59e0b),
          route: '/conversations',
        ));
      }

      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
      _showOverlay();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  int? _cachedBizId;
  Future<int?> _loadBizId() async {
    if (_cachedBizId != null) return _cachedBizId;
    _cachedBizId = await getActiveBusinessId();
    return _cachedBizId;
  }

  void _showOverlay() {
    // No-op — overlay is now driven by _results state in build()
    if (mounted) setState(() {});
  }

  List<Widget> _buildResultItems() {
    final grouped = <String, List<_SearchResult>>{};
    for (final r in _results) {
      grouped.putIfAbsent(r.type, () => []).add(r);
    }

    final items = <Widget>[];
    grouped.forEach((type, results) {
      items.add(Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(type.toUpperCase(),
            style: const TextStyle(
                fontSize: 9, fontWeight: FontWeight.w700,
                color: AppTheme.textMuted, letterSpacing: 1.0)),
      ));
      for (final r in results) {
        items.add(_ResultTile(result: r, onTap: () => _navigate(r)));
      }
    });
    return items;
  }

  void _navigate(_SearchResult r) {
    _clearSearch();
    context.go(r.route);
  }

  void _clearSearch() {
    _ctrl.clear();
    _focus.unfocus();
    if (mounted) setState(() => _results = []);
  }

  @override
  Widget build(BuildContext context) {
    final showDropdown = _results.isNotEmpty && _ctrl.text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.divider)),
          ),
          child: SizedBox(
            height: 32,
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              onChanged: _onChanged,
              style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: 'Search...',
                hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                prefixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(width: 12, height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5, color: AppTheme.brand)))
                    : const Icon(Icons.search, size: 14, color: AppTheme.textMuted),
                prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                suffixIcon: _ctrl.text.isNotEmpty
                    ? GestureDetector(
                        onTap: _clearSearch,
                        child: const Icon(Icons.close, size: 13, color: AppTheme.textMuted))
                    : null,
                suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                filled: true,
                fillColor: AppTheme.pageBg,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(7),
                    borderSide: const BorderSide(color: AppTheme.divider)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(7),
                    borderSide: const BorderSide(color: AppTheme.divider)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(7),
                    borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
              ),
            ),
          ),
        ),
        if (showDropdown)
          Container(
            constraints: const BoxConstraints(maxHeight: 380),
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              border: const Border(
                bottom: BorderSide(color: AppTheme.borderColor),
              ),
              boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(2, 4),
              )],
            ),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              shrinkWrap: true,
              children: _buildResultItems(),
            ),
          ),
      ],
    );
  }
}

class _SearchResult {
  final String type;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String route;

  const _SearchResult({
    required this.type, required this.title, required this.subtitle,
    required this.icon, required this.color, required this.route,
  });
}

class _ResultTile extends StatelessWidget {
  final _SearchResult result;
  final VoidCallback onTap;
  const _ResultTile({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: result.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Icon(result.icon, size: 13, color: result.color),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(result.title,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary),
                overflow: TextOverflow.ellipsis),
            if (result.subtitle.isNotEmpty)
              Text(result.subtitle,
                  style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
                  overflow: TextOverflow.ellipsis),
          ])),
        ]),
      ),
    );
  }
}
class _ClockedInBanner extends StatefulWidget {
  final String? clockedInAt;
  const _ClockedInBanner({required this.clockedInAt});

  @override
  State<_ClockedInBanner> createState() => _ClockedInBannerState();
}

class _ClockedInBannerState extends State<_ClockedInBanner> {
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
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.12),
        border: Border(bottom: BorderSide(color: AppTheme.success.withValues(alpha: 0.3))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        const Icon(Icons.timer, size: 12, color: AppTheme.success),
        const SizedBox(width: 6),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Clocked In',
              style: TextStyle(color: AppTheme.success, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
          Text(_format(_elapsed),
              style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ])),
      ]),
    );
  }
}

class _SuperuserBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final businessName =
        SuperuserState.impersonatedBusinessName ?? 'Unknown Business';

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2D2200),
        border: Border(
          bottom: BorderSide(color: Colors.amber.withValues(alpha: 0.25)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined,
                  size: 10, color: Colors.amber),
              const SizedBox(width: 5),
              const Text(
                'SUPERUSER MODE',
                style: TextStyle(
                  color: Colors.amber,
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            businessName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          const SizedBox(height: 6),
          Clickable(
            onTap: () => context.go('/business-picker'),
            child: Container(
              height: 24,
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                    color: Colors.amber.withValues(alpha: 0.4), width: 1),
              ),
              alignment: Alignment.center,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.swap_horiz_rounded,
                      size: 12, color: Colors.amber),
                  SizedBox(width: 5),
                  Text(
                    'Switch Business',
                    style: TextStyle(
                      color: Colors.amber,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  LOGO AREA
// ─────────────────────────────────────────────
class _LogoArea extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.divider)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppTheme.brand,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: const Text('N',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('NexaFlow',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
              SizedBox(height: 2),
              Text('Marketing Suite',
                  style: TextStyle(
                      color: AppTheme.textMuted, fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  SECTION LABEL
// ─────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 6),
      child: Text(label.toUpperCase(),
          style: const TextStyle(
            color: AppTheme.textMuted,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          )),
    );
  }
}

// ─────────────────────────────────────────────
//  NAV ITEM
// ─────────────────────────────────────────────
class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String route;
  final bool active;
  final String? badge;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.route,
    required this.active,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: () => context.go(route),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: active ? AppTheme.brandActive : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: active ? AppTheme.brand : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(icon,
                size: 16,
                color: active ? AppTheme.textActive : AppTheme.textNormal),
            const SizedBox(width: 9),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: active ? AppTheme.textActive : AppTheme.textNormal,
                  )),
            ),
            if (badge != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.brand,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(badge!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    )),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  USER ROW
// ─────────────────────────────────────────────
class _UserRow extends StatefulWidget {
  @override
  State<_UserRow> createState() => _UserRowState();
}

class _UserRowState extends State<_UserRow> {
  String _name     = '';
  String _initials = '?';

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final db      = Supabase.instance.client;
    final profile = await db
        .from('profiles')
        .select('full_name')
        .eq('user_id', db.auth.currentUser!.id)
        .maybeSingle();
    if (profile != null && mounted) {
      final name   = profile['full_name'] ?? '';
      final parts  = name.split(' ');
      final initials = parts.length >= 2
          ? '${parts[0][0]}${parts[1][0]}'.toUpperCase()
          : name.isNotEmpty
              ? name[0].toUpperCase()
              : '?';
      setState(() {
        _name     = name;
        _initials = initials;
      });
    }
  }

  Future<void> _logout(BuildContext context) async {
    bool doLogout = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.cardBg,
        title: const Text('Log out?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text('Are you sure you want to log out?',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
              onPressed: () {
                doLogout = true;
                Navigator.of(dialogContext).pop();
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Log out'),
            ),
          ),
        ],
      ),
    );
    if (doLogout && context.mounted) {
      AppRouter.clearSuperuserFlag();
      SuperuserState.clear();
      await Supabase.instance.client.auth.signOut();
      if (context.mounted) context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Clickable(
            onTap: () => context.go('/settings'),
            child: Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                color: AppTheme.brand,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(_initials,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Clickable(
              onTap: () => context.go('/settings'),
              child: Text(
                _name.isNotEmpty ? _name : '...',
                style:
                    const TextStyle(color: AppTheme.textSub, fontSize: 11.5),
              ),
            ),
          ),
          Clickable(
            onTap: () => _logout(context),
            child: const Tooltip(
              message: 'Log out',
              child:
                  Icon(Icons.logout, size: 14, color: AppTheme.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}