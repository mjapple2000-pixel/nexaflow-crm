import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../screens/login_screen.dart';
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

class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final session = Supabase.instance.client.auth.currentSession;
      final isLoggedIn = session != null;
      final isLoginPage = state.matchedLocation == '/login';

      if (!isLoggedIn && !isLoginPage) return '/login';
      if (isLoggedIn && isLoginPage) return '/dashboard';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) {
          return MainLayout(child: child);
        },
        routes: [
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
            builder: (context, state) => const SettingsScreen(),
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