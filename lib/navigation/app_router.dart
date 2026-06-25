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
import '../screens/business_picker_screen.dart';
import '../theme/app_theme.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../screens/tickets_screen.dart';
import '../screens/reset_password_screen.dart';
import '../screens/beta_testers_screen.dart';
import '../screens/beta_signup_screen.dart';
import '../screens/snippets_screen.dart';
import '../screens/reviews_screen.dart';
import '../screens/public_booking_screen.dart';
import '../screens/jobs_screen.dart';
import '../screens/quotes_screen.dart';
import '../screens/quote_detail_screen.dart';
import '../screens/new_quote_screen.dart';
import '../screens/invoices_screen.dart';
import '../screens/invoice_detail_screen.dart';
import '../screens/new_invoice_screen.dart';
import '../screens/client_hub_screen.dart';

class AppRouter {
  static bool? cachedIsSuperuser;
  static String? pendingRecoveryToken;
  static bool pendingInvite = false;
  static bool pendingError = false;
  static bool isPasswordRecovery = false;

  static String _initialLocation = '/login';
  static void setInitialLocation(String path) => _initialLocation = path;
  static GoRouter? _router;
  static GoRouter get router => _router ??= _buildRouter();
  static GoRouter _buildRouter() => GoRouter(
    initialLocation: _initialLocation,
    refreshListenable: GoRouterRefreshStream(
      Supabase.instance.client.auth.onAuthStateChange,
    ),
    redirect: (context, state) async {
      final loc = state.uri.path;
      final realPath = Uri.base.path;
      debugPrint('DEBUG ROUTER loc=$loc realPath=$realPath');
      if (loc.startsWith('/book/') || realPath.startsWith('/book/')) return null;
      if (loc.startsWith('/client/') || realPath.startsWith('/client/')) return null;
      if (loc.startsWith('/client')) return null;
      final session = Supabase.instance.client.auth.currentSession;
      final isLoggedIn = session != null;
      final isLoginPage = loc == '/login';
      final isSignupPage = loc == '/signup';
      final isSetupPage = loc == '/setup-account';
      final isErrorPage = loc == '/error';
      final isRootPage = loc == '/';
      final isBusinessPicker = loc == '/business-picker';
      final isResetPassword = loc == '/reset-password';

      // Password recovery event fired by Supabase — go to reset screen
      if (isPasswordRecovery) {
        return '/reset-password';
      }

      // Handle other flags set by main.dart
      if (pendingError) {
        pendingError = false;
        return '/error';
      }
      if (pendingInvite) {
        pendingInvite = false;
        return '/setup-account';
      }

      // Always allow these through unconditionally
      if (isErrorPage) return null;
      if (isResetPassword) return null;
      if (loc == '/beta-signup') return null; // Never redirect away from reset screen
      if (isRootPage) return '/login';
      if (isSetupPage) return isLoggedIn ? null : '/login';
      if (isBusinessPicker) return isLoggedIn ? null : '/login';

      if (isLoginPage || isSignupPage) {
        if (isLoggedIn) {
          try {
            final userId = Supabase.instance.client.auth.currentUser?.id;
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

      if (isLoggedIn &&
          !isBusinessPicker &&
          !loc.startsWith('/book/') &&
          cachedIsSuperuser == true &&
          SuperuserState.impersonatedBusinessId == null) {
        return '/business-picker';
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
        path: '/business-picker',
        name: 'business-picker',
        builder: (context, state) => const BusinessPickerScreen(),
      ),
      GoRoute(
        path: '/reset-password',
        name: 'reset-password',
        builder: (context, state) => const ResetPasswordScreen(),
      ),
      GoRoute(
        path: '/beta-signup',
        name: 'beta-signup',
        builder: (context, state) => BetaSignupScreen(
          token: state.uri.queryParameters['token'] ?? '',
        ),
      ),
      GoRoute(
        path: '/book/:calendarId',
        name: 'public-booking',
        redirect: (context, state) {
          debugPrint('DEBUG BOOK ROUTE HIT calendarId=${state.pathParameters['calendarId']}');
          return null;
        },
        builder: (context, state) {
          debugPrint('DEBUG BOOK BUILDER HIT');
          return PublicBookingScreen(
            calendarId: state.pathParameters['calendarId']!,
          );
        },
      ),
      GoRoute(
        path: '/client/:token',
        name: 'client-hub',
        builder: (context, state) => ClientHubScreen(
          token: state.pathParameters['token']!,
        ),
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
                      'This invite link has expired. Please request a new one.',
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
            path: '/opportunities',
            name: 'opportunities',
            builder: (context, state) => const PipelinesScreen(),
          ),
          GoRoute(
            path: '/jobs',
            name: 'jobs',
            builder: (context, state) {
              final tab = int.tryParse(state.uri.queryParameters['tab'] ?? '0') ?? 0;
              return JobsScreen(initialTab: tab);
            },
          ),
          GoRoute(
            path: '/jobs/quotes/new',
            name: 'quote-new',
            builder: (context, state) {
              final quoteId = state.uri.queryParameters['quoteId'];
              return NewQuoteScreen(quoteId: quoteId);
            },
          ),
          GoRoute(
            path: '/jobs/quotes/:id',
            name: 'quote-detail',
            builder: (context, state) => QuoteDetailScreen(
              quoteId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/jobs/invoices/new',
            name: 'invoice-new',
            builder: (context, state) => const NewInvoiceScreen(),
          ),
          GoRoute(
            path: '/jobs/invoices/edit',
            name: 'invoice-edit',
            builder: (context, state) {
              final invoiceId = state.uri.queryParameters['invoiceId'];
              return NewInvoiceScreen(invoiceId: invoiceId);
            },
          ),
          GoRoute(
            path: '/jobs/invoices/:id',
            name: 'invoice-detail',
            builder: (context, state) => InvoiceDetailScreen(
              invoiceId: state.pathParameters['id']!,
            ),
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
          GoRoute(
            path: '/tickets',
            name: 'tickets',
            builder: (context, state) => const TicketsScreen(),
          ),
          GoRoute(
            path: '/beta-testers',
            name: 'beta-testers',
            builder: (context, state) => const BetaTestersScreen(),
          ),
          GoRoute(
            path: '/snippets',
            name: 'snippets',
            builder: (context, state) => const SnippetsScreen(),
          ),
          GoRoute(
            path: '/reviews',
            name: 'reviews',
            builder: (context, state) => const ReviewsScreen(),
          ),
        ],
      ),
    ],
  );
}

class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<AuthState> stream) {
    _subscription = stream.listen((authState) {
      // When Supabase fires the passwordRecovery event, set the flag
      // and notify the router to redirect to /reset-password.
      // The session is already established at this point.
      if (authState.event == AuthChangeEvent.passwordRecovery) {
        AppRouter.isPasswordRecovery = true;
      }
      notifyListeners();
    });
  }

  late final StreamSubscription<AuthState> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}