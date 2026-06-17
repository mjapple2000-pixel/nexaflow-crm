import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:nexaflow/theme/app_theme.dart';
import 'package:nexaflow/navigation/app_router.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  final initLoc = Uri.base.path.startsWith('/book/') ? Uri.base.path : '/login';
  debugPrint('DEBUG setInitialLocation=$initLoc');
  AppRouter.setInitialLocation(initLoc);

  await Supabase.initialize(
    url: 'https://rllriopqojaraceytdno.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJsbHJpb3Bxb2phcmFjZXl0ZG5vIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzczOTQzMzgsImV4cCI6MjA5Mjk3MDMzOH0.BxTbaRRD_xc88gyWBm5k7ZVVGP8c3CqW5U8aXBmXPMw',
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
  final isBetaSignup = path.contains('beta-signup');
  final isPublicBooking = path.startsWith('/book/') || Uri.base.path.startsWith('/book/');
  debugPrint('DEBUG isPublicBooking=$isPublicBooking');
  if (!fragment.contains('access_token') && !isBetaSignup && !isPublicBooking) {
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
    if (widget.initialPath.startsWith('/book/')) {
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