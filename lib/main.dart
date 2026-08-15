import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:nexaflow/theme/app_theme.dart';
import 'package:nexaflow/navigation/app_router.dart';
import 'package:nexaflow/screens/business_picker_screen.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:nexaflow/config/supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  // Restore a superuser's business impersonation choice before any screen
  // tries to resolve a business ID — otherwise a browser reload drops
  // straight back to "no business" and every screen shows zero data.
  SuperuserState.restore();
  AppRouter.restoreSuperuserFlag();
  debugPrint('DEBUG RAW URI BEFORE INITLOC: ${Uri.base.toString()}');
  debugPrint('DEBUG RAW PATH BEFORE INITLOC: ${Uri.base.path}');
  final initLoc = (Uri.base.path.startsWith('/book/') ||
          Uri.base.path.startsWith('/client/') ||
          Uri.base.path.startsWith('/hub/'))
      ? Uri.base.path
      : '/login';
  debugPrint('DEBUG setInitialLocation=$initLoc');
  AppRouter.resetRouter();
  AppRouter.setInitialLocation(initLoc);

  await Supabase.initialize(
    url: 'https://rllriopqojaraceytdno.supabase.co',
    anonKey: SupabaseConfig.anonKey,
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.implicit,
      // Let Supabase handle the token from the URL automatically.
      // We intercept via onAuthStateChange passwordRecovery event instead.
    ),
  );

  // Only sign out if there's no token in the URL (i.e. normal page load).
  // Supabase will fire passwordRecovery event automatically when the
  // recovery link is clicked — we handle routing in GoRouterRefreshStream.
  final fragment = Uri.base.fragment;
  final path = Uri.base.fragment.split('?').first;
  debugPrint('DEBUG URL: full=${Uri.base} path=${Uri.base.path} fragment=$fragment parsedPath=$path');
  debugPrint('DEBUG FULL URI BASE: ${Uri.base.toString()}');
  debugPrint('DEBUG PATH ONLY: ${Uri.base.path}');
  debugPrint('DEBUG STARTS WITH CLIENT: ${Uri.base.path.startsWith('/client/')}');
  final isBetaSignup = path.contains('beta-signup');
  final isPublicBooking = path.startsWith('/book/') || Uri.base.path.startsWith('/book/');
  final isClientPortal = Uri.base.path.startsWith('/client/');
  final isEmployeeHub = Uri.base.path.startsWith('/hub/');
  debugPrint('DEBUG isPublicBooking=$isPublicBooking');
  // Only force a sign-out on a plain load of the bare /login (or root) URL —
  // this clears a stale local session so a fresh visit to /login always shows
  // a real login form. It must NOT fire on a reload of an already-authenticated
  // route (e.g. /dashboard, /jobs) — that was wiping out valid sessions on
  // every browser refresh, silently breaking the sidebar and every
  // business-scoped data load app-wide.
  final isLoginOrRootPath = Uri.base.path == '/login' || Uri.base.path == '/';
  if (isLoginOrRootPath && !fragment.contains('access_token') && !isBetaSignup && !isPublicBooking && !isClientPortal && !isEmployeeHub) {
    await Supabase.instance.client.auth.signOut();
  }

  final initialPath = Uri.base.path;
  runApp(NexaFlowApp(initialPath: initialPath));
}

class NexaFlowApp extends StatefulWidget {
  final String initialPath;
  const NexaFlowApp({super.key, required this.initialPath});

  @override
  State<NexaFlowApp> createState() => _NexaFlowAppState();
}

class _NexaFlowAppState extends State<NexaFlowApp> {
  @override
  void initState() {
    super.initState();
    if (widget.initialPath.startsWith('/book/') ||
        widget.initialPath.startsWith('/client/') ||
        widget.initialPath.startsWith('/hub/')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppRouter.router.go(widget.initialPath);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'NexaFlow',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      routerConfig: AppRouter.router,
    );
  }
}