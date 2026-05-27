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
    ),
  );

  // Handle magic link token in URL fragment before app starts
  final uri = Uri.base;
  final fragment = uri.fragment;
  if (fragment.contains('access_token')) {
    final params = Uri.splitQueryString(fragment);
    final accessToken = params['access_token'] ?? '';
    final type = params['type'] ?? '';
    if (accessToken.isNotEmpty) {
      try {
        await Supabase.instance.client.auth.recoverSession(accessToken);
        // Set initial route based on type
        if (type == 'invite') {
          AppRouter.setInitialRoute('/setup-account');
        } else {
          AppRouter.setInitialRoute('/dashboard');
        }
      } catch (e) {
        debugPrint('Magic link error: $e');
      }
    }
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