import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../screens/login_screen.dart';
import '../screens/signup_screen.dart';
import '../screens/dashboard_screen.dart';
import '../screens/contacts_screen.dart';
import '../screens/contact_detail_screen.dart';
import '../screens/pipelines_screen.dart';
import '../screens/campaigns_screen.dart';
import '../screens/conversations_screen.dart';
import '../screens/reporting_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/appointments_screen.dart';
import '../widgets/main_layout.dart';
import '../screens/forms_screen.dart';
import '../screens/ai_chat_screen.dart';
import '../screens/automations_screen.dart';
import '../screens/launchpad_screen.dart';
import '../screens/tasks_screen.dart';
import '../screens/setup_account_screen.dart';
import '../theme/app_theme.dart';

class AppRouter {
  static String _initialRoute = '/login';

  static void setInitialRoute(String route) {
    _initialRoute = route;
  }

  static final GoRouter router = GoRouter(
    initialLocation: _initialRoute,
    refreshListenable: GoRouterRefreshStream(
      Supabase.instance.client.auth.onAuthStateChange,
    ),
    redirect: (context, state) async {
      final session = Supabase.instance.client.auth.currentSession;
      final isLoggedIn = session != null;
      final loc = state.matchedLocation;
      final isLoginPage = loc == '/login';
      final isSignupPage = loc == '/signup';
      final isSetupPage = loc == '/setup-account';
      final isErrorPage = loc == '/error';
      final isRootPage = loc == '/';

      if (isRootPage) return '/login';
      if (isErrorPage) return null;
      if (isSetupPage) return isLoggedIn ? null : '/login';

      if (isLoginPage || isSignupPage) {
        if (isLoggedIn) {
          try {
            final userId =
                Supabase.instance.client.auth.currentUser?.id;
            if (userId != null) {
              final profileRes = await Supabase.instance.client
                  .from('profiles')
                  .select('business_id')
                  .eq('user_id', userId)
                  .maybeSingle();
              final businessId = profileRes?['business_id'] as int?;

              if (businessId != null) {
                final bizRes = await Supabase.instance.client
                    .from('businesses')
                    .select('has_logged_in_before')
                    .eq('id', businessId)
                    .maybeSingle();

                final hasLoggedInBefore =
                    bizRes?['has_logged_in_before'] as bool? ?? false;

                if (!hasLoggedInBefore) {
                  await Supabase.instance.client
                      .from('businesses')
                      .update({'has_logged_in_before': true})
                      .eq('id', businessId);
                  return '/launchpad';
                }
              } else {
                return '/setup-account';
              }
            }
          } catch (e) {
            debugPrint('Router redirect error: $e');
          }
          return '/dashboard';
        }
        return null;
      }

      if (!isLoggedIn) return '/login';
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        redirect: (_, __) => '/login',
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/signup',
        name: 'signup',
        builder: (context, state) => const SignupScreen(),
      ),
      GoRoute(
        path: '/setup-account',
        name: 'setup-account',
        builder: (context, state) => const SetupAccountScreen(),
      ),
      GoRoute(
        path: '/error',
        name: 'error',
        builder: (context, state) => Scaffold(
          backgroundColor: AppTheme.pageBg,
          body: Center(
            child: Container(
              width: 400,
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.borderColor),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.link_off_rounded,
                      size: 48, color: AppTheme.error),
                  const SizedBox(height: 16),
                  const Text('Link Expired',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 8),
                  const Text(
                      'This invite link has expired. Please ask your admin to send a new invite.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary)),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => context.go('/login'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Back to Login'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      ShellRoute(
        builder: (context, state, child) => MainLayout(child: child),
        routes: [
          GoRoute(
            path: '/launchpad',
            name: 'launchpad',
            builder: (_, __) => const LaunchpadScreen(),
          ),
          GoRoute(
            path: '/dashboard',
            name: 'dashboard',
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/contacts',
            name: 'contacts',
            builder: (context, state) => const ContactsScreen(),
          ),
          GoRoute(
            path: '/contacts/:id',
            name: 'contact-detail',
            builder: (context, state) => ContactDetailScreen(
              leadId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/pipelines',
            name: 'pipelines',
            builder: (context, state) => const PipelinesScreen(),
          ),
          GoRoute(
            path: '/campaigns',
            name: 'campaigns',
            builder: (context, state) => const CampaignsScreen(),
          ),
          GoRoute(
            path: '/conversations',
            name: 'conversations',
            builder: (context, state) => const ConversationsScreen(),
          ),
          GoRoute(
            path: '/reporting',
            name: 'reporting',
            builder: (context, state) => const ReportingScreen(),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            builder: (context, state) => SettingsScreen(
              initialSection: state.uri.queryParameters['section'],
            ),
          ),
          GoRoute(
            path: '/ai-chat',
            name: 'ai-chat',
            builder: (context, state) => const AiChatScreen(),
          ),
          GoRoute(
            path: '/automations',
            name: 'automations',
            builder: (context, state) => const AutomationsScreen(),
          ),
          GoRoute(
            path: '/tasks',
            name: 'tasks',
            builder: (context, state) => const TasksScreen(),
          ),
          GoRoute(
            path: '/forms',
            name: 'forms',
            builder: (context, state) => const FormsScreen(),
          ),
          GoRoute(
            path: '/appointments',
            name: 'appointments',
            builder: (context, state) => const AppointmentsScreen(),
          ),
        ],
      ),
    ],
  );
}

class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<AuthState> stream) {
    notifyListeners();
    _subscription = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<AuthState> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}