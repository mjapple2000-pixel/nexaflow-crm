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

  // Profile state
  String _role        = 'member';
  Map<String, dynamic> _permissions = {};
  bool _profileLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadUnreadCount();
    _subscribeToUnread();
  }

  @override
  void dispose() {
    _unreadChannel?.unsubscribe();
    super.dispose();
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

      if (profile != null && mounted) {
        setState(() {
          _role        = profile['role'] as String? ?? 'member';
          _permissions = Map<String, dynamic>.from(
              (profile['permissions'] as Map?)  ?? {});
          _profileLoaded = true;
        });
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
    if (_role == 'owner' || _role == 'admin') return true;
    return _permissions[key] == true;
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

            Expanded(
              child: ListView(
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
                  if (_can('settings'))
                    _NavItem(
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      route: '/settings',
                      active: location.startsWith('/settings'),
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
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return null;
    final profile = await _db.from('profiles').select('business_id').eq('user_id', userId).maybeSingle();
    _cachedBizId = profile?['business_id'] as int?;
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
      AppRouter.cachedIsSuperuser = null;
      SuperuserState.impersonatedBusinessId = null;
      SuperuserState.impersonatedBusinessName = null;
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