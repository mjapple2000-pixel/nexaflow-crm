import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';

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
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      if (mounted) context.go('/dashboard');
    } on AuthException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (e) {
      setState(() => _errorMessage = 'An unexpected error occurred.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showPricingSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _PricingBottomSheet(),
    );
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
          // ── LEFT BRAND PANEL ──────────────────
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

          // ── RIGHT LOGIN PANEL ─────────────────
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
                    const SizedBox(height: 32),

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
                        // ── Show/hide password icon with pointer cursor ──
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
                          color:
                              AppTheme.error.withValues(alpha: 0.1),
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

                    // ── Sign In button with pointer cursor ──
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
                    // ── Forgot password link with pointer cursor ──
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

                    // ── Start Free Trial button with pointer cursor ──
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: OutlinedButton(
                          onPressed: _showPricingSheet,
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
                    borderSide:
                        const BorderSide(color: AppTheme.borderColor),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: AppTheme.borderColor),
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
              // ── Send Reset Link button with pointer cursor ──
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

// ── PRICING BOTTOM SHEET ───────────────────────────────────────────────────────

class _PricingBottomSheet extends StatelessWidget {
  const _PricingBottomSheet();

  static const _plans = [
    _Plan(
      name: 'Starter',
      price: '\$97',
      description: 'Perfect for small businesses getting started.',
      stripeUrl: 'https://buy.stripe.com/dRm7sLcnqdsrfTZ3eM8og08',
      isPopular: false,
    ),
    _Plan(
      name: 'Growth',
      price: '\$297',
      description: 'For growing teams ready to scale their marketing.',
      stripeUrl: 'https://buy.stripe.com/5kQ5kDdru4VVgY37v28og09',
      isPopular: true,
    ),
    _Plan(
      name: 'Pro',
      price: '\$497',
      description:
          'Full power for agencies and high-volume businesses.',
      stripeUrl: 'https://buy.stripe.com/8x214n4UY0FF6jp9Da8og0a',
      isPopular: false,
    ),
  ];

  Future<void> _openStripe(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
          const Text('Choose Your Plan',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 6),
          const Text('15-day free trial on all plans · Cancel anytime',
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary)),
          const SizedBox(height: 24),

          // Plan cards
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _plans
                .map((plan) => Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6),
                        child: _PlanCard(
                          plan: plan,
                          onTap: () =>
                              _openStripe(context, plan.stripeUrl),
                        ),
                      ),
                    ))
                .toList(),
          ),

          const SizedBox(height: 20),
          Text(
            'After payment you\'ll receive your login credentials via email within 24 hours.',
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}

// ── PLAN CARD ──────────────────────────────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  final _Plan plan;
  final VoidCallback onTap;
  const _PlanCard({required this.plan, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: plan.isPopular
            ? AppTheme.brand.withValues(alpha: 0.06)
            : AppTheme.pageBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color:
              plan.isPopular ? AppTheme.brand : AppTheme.borderColor,
          width: plan.isPopular ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          if (plan.isPopular)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.brand,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(10)),
              ),
              child: const Text('MOST POPULAR',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1)),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan.name,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary)),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(plan.price,
                        style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary)),
                    const Text('/mo',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(plan.description,
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary)),
                const SizedBox(height: 16),
                // ── Start Free Trial button with pointer cursor ──
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onTap,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: plan.isPopular
                            ? AppTheme.brand
                            : AppTheme.cardBg,
                        foregroundColor: plan.isPopular
                            ? Colors.white
                            : AppTheme.brand,
                        elevation: 0,
                        side: plan.isPopular
                            ? null
                            : const BorderSide(
                                color: AppTheme.brand),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(
                            vertical: 10),
                      ),
                      child: const Text('Start Free Trial',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── PLAN DATA ──────────────────────────────────────────────────────────────────

class _Plan {
  final String name;
  final String price;
  final String description;
  final String stripeUrl;
  final bool isPopular;
  const _Plan({
    required this.name,
    required this.price,
    required this.description,
    required this.stripeUrl,
    required this.isPopular,
  });
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