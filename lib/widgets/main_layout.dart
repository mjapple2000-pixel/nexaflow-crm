import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

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
      body: Row(
        children: [
          AppNavBar(),
          Expanded(child: child),
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

  @override
  void initState() {
    super.initState();
    _loadUnreadCount();
    _subscribeToUnread();
  }

  @override
  void dispose() {
    _unreadChannel?.unsubscribe();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final String location = GoRouterState.of(context).uri.toString();

    return Material(
      color: AppTheme.sidebarBg,
      child: SizedBox(
        width: 220,
        height: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LogoArea(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                primary: false,
                physics: const ClampingScrollPhysics(),
                children: [
                  _SectionLabel('Main'),
                  _NavItem(
                    icon: Icons.grid_view_rounded,
                    label: 'Dashboard',
                    route: '/dashboard',
                    active: location.startsWith('/dashboard'),
                  ),
                  _SectionLabel('CRM'),
                  _NavItem(
                    icon: Icons.people_alt_outlined,
                    label: 'Contacts',
                    route: '/contacts',
                    active: location.startsWith('/contacts'),
                  ),
                  _NavItem(
                    icon: Icons.bar_chart_rounded,
                    label: 'Pipelines',
                    route: '/pipelines',
                    active: location.startsWith('/pipelines'),
                  ),
                  _SectionLabel('Marketing'),
                  _NavItem(
                    icon: Icons.campaign_outlined,
                    label: 'Campaigns',
                    route: '/campaigns',
                    active: location.startsWith('/campaigns'),
                  ),
                  _SectionLabel('Engage'),
                  _NavItem(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: 'Conversations',
                    route: '/conversations',
                    active: location.startsWith('/conversations'),
                    badge: _unreadCount > 0 ? '$_unreadCount' : null,
                  ),
                  _SectionLabel('Analytics'),
                  _NavItem(
                    icon: Icons.show_chart_rounded,
                    label: 'Reporting',
                    route: '/reporting',
                    active: location.startsWith('/reporting'),
                  ),
                  _SectionLabel('Account'),
                  _NavItem(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    route: '/settings',
                    active: location.startsWith('/settings'),
                  ),
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
                color: active
                    ? AppTheme.textActive
                    : AppTheme.textNormal),
            const SizedBox(width: 9),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: active
                        ? AppTheme.textActive
                        : AppTheme.textNormal,
                  )),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
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
  String _name = '';
  String _initials = '?';

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final db = Supabase.instance.client;
    final profile = await db
        .from('profiles')
        .select('full_name')
        .eq('user_id', db.auth.currentUser!.id)
        .maybeSingle();
    if (profile != null && mounted) {
      final name = profile['full_name'] ?? '';
      final parts = name.split(' ');
      final initials = parts.length >= 2
          ? '${parts[0][0]}${parts[1][0]}'.toUpperCase()
          : name.isNotEmpty
              ? name[0].toUpperCase()
              : '?';
      setState(() {
        _name = name;
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
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red),
              child: const Text('Log out'),
            ),
          ),
        ],
      ),
    );
    if (doLogout && context.mounted) {
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
      padding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                style: const TextStyle(
                    color: AppTheme.textSub, fontSize: 11.5),
              ),
            ),
          ),
          Clickable(
            onTap: () => _logout(context),
            child: const Tooltip(
              message: 'Log out',
              child: Icon(Icons.logout,
                  size: 14, color: AppTheme.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}