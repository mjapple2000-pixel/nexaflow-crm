import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:nexaflow/theme/app_theme.dart';
import 'package:nexaflow/navigation/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  if (!fragment.contains('access_token')) {
    await Supabase.instance.client.auth.signOut();
  }

  runApp(const NexaFlowApp());
}

class NexaFlowApp extends StatelessWidget {
  const NexaFlowApp({super.key});

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