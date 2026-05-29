import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../navigation/app_router.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  String? _errorMessage;
@override
  void initState() {
    super.initState();
    _handleMagicLink();
  }

  Future<void> _handleMagicLink() async {
    final uri = Uri.base;
    final fragment = uri.fragment;
    if (fragment.contains('access_token')) {
      final params = Uri.splitQueryString(fragment);
      final accessToken = params['access_token'] ?? '';
      final refreshToken = params['refresh_token'] ?? '';
      final type = params['type'] ?? '';
      if (accessToken.isNotEmpty) {
        try {
        await Supabase.instance.client.auth.recoverSession(accessToken);          
          if (!mounted) return;
          if (type == 'invite') {
            context.go('/setup-account');
          } else {
            context.go('/dashboard');
          }
        } catch (e) {
          debugPrint('Magic link error: $e');
        }
      }
    }
  }
  // Show a success banner if coming back from signup flow
  bool get _showSignupSuccess =>
      GoRouterState.of(context).uri.queryParameters['signup'] == 'complete';

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final authResponse = await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      if (!mounted) return;

      final session = authResponse.session;
      if (session == null) {
        setState(() => _errorMessage = 'Login failed. Please try again.');
        return;
      }

      // ── Superuser check ──────────────────────────────────────────
      final superRes = await http.post(
        Uri.parse('https://rllriopqojaraceytdno.supabase.co/functions/v1/check-superuser'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${session.accessToken}',
        },
      );

      if (!mounted) return;

      if (superRes.statusCode == 200) {
        final body = jsonDecode(superRes.body);
        AppRouter.cachedIsSuperuser = body['is_superuser'] == true;
        if (AppRouter.cachedIsSuperuser == true) {
          context.go('/business-picker');
          return;
        }
      }

      // ── Normal user flow ─────────────────────────────────────────
      final userId = session.user.id;
      final profileRes = await Supabase.instance.client
          .from('profiles')
          .select('business_id')
          .eq('user_id', userId)
          .maybeSingle();
      final businessId = profileRes?['business_id'] as int?;

      if (!mounted) return;

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
          if (mounted) context.go('/launchpad');
          return;
        }
      }

      if (mounted) context.go('/dashboard');

    } on AuthException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (e) {
      setState(() => _errorMessage = 'An unexpected error occurred.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showForgotPassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ForgotPasswordSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Row(
        children: [
          // ── LEFT BRAND PANEL ──────────────────────────────────────
          Expanded(
            child: Container(
              color: AppTheme.sidebarBg,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppTheme.brand,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: const Text('N',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 20),
                  const Text('NexaFlow',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Marketing Suite',
                      style: TextStyle(
                          color: AppTheme.textMuted, fontSize: 14)),
                  const SizedBox(height: 48),
                  _FeatureItem(
                      icon: Icons.people_alt_outlined,
                      text: 'Full CRM & Contact Management'),
                  _FeatureItem(
                      icon: Icons.campaign_outlined,
                      text: 'Email & SMS Campaigns'),
                  _FeatureItem(
                      icon: Icons.bar_chart_rounded,
                      text: 'Pipeline & Deal Tracking'),
                  _FeatureItem(
                      icon: Icons.chat_bubble_outline_rounded,
                      text: 'Unified Conversations Inbox'),
                  _FeatureItem(
                      icon: Icons.show_chart_rounded,
                      text: 'Advanced Reporting & Analytics'),
                ],
              ),
            ),
          ),

          // ── RIGHT LOGIN PANEL ─────────────────────────────────────
          Expanded(
            child: Center(
              child: Container(
                width: 400,
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(
                  color: AppTheme.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.borderColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Welcome back',
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 8),
                    const Text('Sign in to your NexaFlow account',
                        style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.textSecondary)),

                    // ── Signup success banner ──────────────────────
                    if (_showSignupSuccess) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.success.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppTheme.success
                                  .withValues(alpha: 0.3)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.check_circle_outline,
                                size: 16, color: AppTheme.success),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Account setup complete! Your login credentials will be activated once your trial begins.',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.success),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // EMAIL
                    const Text('Email',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        hintText: 'you@example.com',
                        prefixIcon: const Icon(Icons.email_outlined,
                            size: 18, color: AppTheme.textSecondary),
                        filled: true,
                        fillColor: AppTheme.pageBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: AppTheme.borderColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: AppTheme.borderColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: AppTheme.brand, width: 2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // PASSWORD
                    const Text('Password',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        hintText: '••••••••',
                        prefixIcon: const Icon(Icons.lock_outline,
                            size: 18, color: AppTheme.textSecondary),
                        suffixIcon: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 18,
                              color: AppTheme.textSecondary,
                            ),
                            onPressed: () => setState(() =>
                                _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        filled: true,
                        fillColor: AppTheme.pageBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: AppTheme.borderColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: AppTheme.borderColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: AppTheme.brand, width: 2),
                        ),
                      ),
                      onSubmitted: (_) => _signIn(),
                    ),

                    // ERROR MESSAGE
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.error.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppTheme.error
                                  .withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline,
                                size: 16, color: AppTheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_errorMessage!,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.error)),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Sign In button
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _signIn,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.brand,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white))
                              : const Text('Sign In',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),
                    Center(
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: TextButton(
                          onPressed: _showForgotPassword,
                          child: const Text('Forgot your password?',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.brand)),
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Expanded(
                            child: Divider(
                                color: AppTheme.borderColor)),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12),
                          child: Text('New to NexaFlow?',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary)),
                        ),
                        const Expanded(
                            child: Divider(
                                color: AppTheme.borderColor)),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Start Free Trial → signup page
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: OutlinedButton(
                          onPressed: () => context.go('/signup'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.brand,
                            side: const BorderSide(
                                color: AppTheme.brand),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Text('Start Free Trial',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: Text(
                          '15-day free trial · No credit card charged today',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textMuted)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── FORGOT PASSWORD SHEET ──────────────────────────────────────────────────────

class _ForgotPasswordSheet extends StatefulWidget {
  const _ForgotPasswordSheet();

  @override
  State<_ForgotPasswordSheet> createState() =>
      _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  final _emailController = TextEditingController();
  bool _loading = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendReset() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth
          .resetPasswordForEmail(_emailController.text.trim());
      if (mounted) setState(() => _sent = true);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'An unexpected error occurred.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppTheme.borderColor),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            if (_sent) ...[
              const Icon(Icons.mark_email_read_outlined,
                  size: 48, color: AppTheme.brand),
              const SizedBox(height: 16),
              const Text('Check your email',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              const Text(
                'We sent a password reset link to your email address. Click the link to set a new password.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 24),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Done',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ] else ...[
              const Text('Reset your password',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              const Text(
                'Enter your email and we\'ll send you a reset link.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'you@example.com',
                  prefixIcon: const Icon(Icons.email_outlined,
                      size: 18, color: AppTheme.textSecondary),
                  filled: true,
                  fillColor: AppTheme.pageBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: AppTheme.borderColor),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: AppTheme.borderColor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                        color: AppTheme.brand, width: 2),
                  ),
                ),
                onSubmitted: (_) => _sendReset(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color:
                            AppTheme.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          size: 16, color: AppTheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.error)),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _sendReset,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white))
                        : const Text('Send Reset Link',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── FEATURE ITEM ───────────────────────────────────────────────────────────────

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _FeatureItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(vertical: 8, horizontal: 48),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.brand),
          const SizedBox(width: 12),
          Text(text,
              style: const TextStyle(
                  color: AppTheme.textNormal, fontSize: 13)),
        ],
      ),
    );
  }
}