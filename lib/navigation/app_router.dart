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

class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: '/login',
    redirect: (context, state) async {
      final session = Supabase.instance.client.auth.currentSession;
      final isLoggedIn = session != null;
      final loc = state.matchedLocation;
      final isLoginPage = loc == '/login';
      final isSignupPage = loc == '/signup';

      if (isLoginPage || isSignupPage) {
        if (isLoggedIn && isLoginPage) {
          try {
            final userId =
                Supabase.instance.client.auth.currentUser?.id;
            if (userId != null) {
              // Get business_id from profile
              final profileRes = await Supabase.instance.client
                  .from('profiles')
                  .select('business_id')
                  .eq('user_id', userId)
                  .maybeSingle();
              final businessId = profileRes?['business_id'] as int?;

              if (businessId != null) {
                // Check if this is their first login
                final bizRes = await Supabase.instance.client
                    .from('businesses')
                    .select('has_logged_in_before')
                    .eq('id', businessId)
                    .maybeSingle();

                final hasLoggedInBefore =
                    bizRes?['has_logged_in_before'] as bool? ?? false;

                if (!hasLoggedInBefore) {
                  // First login — mark it and send to Launchpad
                  await Supabase.instance.client
                      .from('businesses')
                      .update({'has_logged_in_before': true})
                      .eq('id', businessId);
                  return '/launchpad';
                }
              }
            }
          } catch (e) {
            debugPrint('Router redirect error: $e');
          }
          // Every login after the first goes to Dashboard
          return '/dashboard';
        }
        return null;
      }

      if (!isLoggedIn) return '/login';
      return null;
    },
    routes: [
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