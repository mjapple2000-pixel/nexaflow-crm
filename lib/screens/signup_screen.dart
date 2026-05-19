import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final PageController _pageController = PageController();
  int _currentStep = 0; // 0 = info, 1 = plan

  // Step 1 controllers
  final _fullNameController = TextEditingController();
  final _businessNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _errorMessage;

  // Step 2
  String? _selectedPlan;

  @override
  void dispose() {
    _pageController.dispose();
    _fullNameController.dispose();
    _businessNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // ── Password strength ─────────────────────────────────────────────
  int _passwordStrength(String pw) {
    if (pw.isEmpty) return 0;
    int score = 0;
    if (pw.length >= 8) score++;
    if (pw.length >= 12) score++;
    if (RegExp(r'[A-Z]').hasMatch(pw)) score++;
    if (RegExp(r'[0-9]').hasMatch(pw)) score++;
    if (RegExp(r'[!@#\$%^&*(),.?":{}|<>]').hasMatch(pw)) score++;
    return score;
  }

  Color _strengthColor(int s) {
    if (s <= 1) return AppTheme.error;
    if (s <= 2) return const Color(0xFFFF9800);
    if (s <= 3) return const Color(0xFFFFD600);
    return AppTheme.success;
  }

  String _strengthLabel(int s) {
    if (s <= 1) return 'Weak';
    if (s <= 2) return 'Fair';
    if (s <= 3) return 'Good';
    return 'Strong';
  }

  // ── Validation ────────────────────────────────────────────────────
  String? _validateStep1() {
    if (_fullNameController.text.trim().isEmpty) return 'Please enter your full name.';
    if (_businessNameController.text.trim().isEmpty) return 'Please enter your business name.';
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) return 'Please enter a valid email address.';
    if (_phoneController.text.trim().length < 7) return 'Please enter a valid phone number.';
    if (_passwordController.text.length < 8) return 'Password must be at least 8 characters.';
    if (_passwordController.text != _confirmPasswordController.text) return 'Passwords do not match.';
    return null;
  }

  void _goToStep2() {
    final err = _validateStep1();
    if (err != null) {
      setState(() => _errorMessage = err);
      return;
    }
    setState(() => _errorMessage = null);
    _pageController.animateToPage(1,
        duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    setState(() => _currentStep = 1);
  }

  Future<void> _selectPlan(String planName, String stripeUrl) async {
    setState(() => _selectedPlan = planName);
    final uri = Uri.parse(
      '$stripeUrl?prefilled_email=${Uri.encodeComponent(_emailController.text.trim())}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    // After Stripe opens, send them back to login with a success note
    if (mounted) {
      context.go('/login?signup=complete');
    }
  }

  // ── Plans ─────────────────────────────────────────────────────────
  static const _plans = [
    _Plan(
      name: 'Starter',
      price: '\$97',
      period: '/mo',
      description: 'Perfect for small businesses getting started with marketing automation.',
      stripeUrl: 'https://buy.stripe.com/dRm7sLcnqdsrfTZ3eM8og08',
      isPopular: false,
      features: ['Up to 500 contacts', 'SMS & Email campaigns', 'Pipeline management', 'AI chat widget'],
    ),
    _Plan(
      name: 'Growth',
      price: '\$297',
      period: '/mo',
      description: 'For growing teams ready to scale their marketing and automation.',
      stripeUrl: 'https://buy.stripe.com/5kQ5kDdru4VVgY37v28og09',
      isPopular: true,
      features: ['Up to 5,000 contacts', 'Everything in Starter', 'Advanced automations', 'Priority support'],
    ),
    _Plan(
      name: 'Pro',
      price: '\$497',
      period: '/mo',
      description: 'Full power for agencies and high-volume businesses.',
      stripeUrl: 'https://buy.stripe.com/8x214n4UY0FF6jp9Da8og0a',
      isPopular: false,
      features: ['Unlimited contacts', 'Everything in Growth', 'White-label options', 'Dedicated onboarding'],
    ),
  ];

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
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Logo
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppTheme.brand,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const Text('N',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 12),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('NexaFlow',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold)),
                          Text('Marketing Suite',
                              style: TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 48),

                  // Step indicator
                  _StepIndicator(currentStep: _currentStep),
                  const SizedBox(height: 48),

                  // Feature bullets
                  const _FeatureItem(
                      icon: Icons.people_alt_outlined,
                      text: 'Full CRM & Contact Management'),
                  const _FeatureItem(
                      icon: Icons.campaign_outlined,
                      text: 'Email & SMS Campaigns'),
                  const _FeatureItem(
                      icon: Icons.bar_chart_rounded,
                      text: 'Pipeline & Deal Tracking'),
                  const _FeatureItem(
                      icon: Icons.chat_bubble_outline_rounded,
                      text: 'Unified Conversations Inbox'),
                  const _FeatureItem(
                      icon: Icons.bolt_outlined,
                      text: 'Powerful Automations'),

                  const SizedBox(height: 48),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.brand.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppTheme.brand.withValues(alpha: 0.25)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.verified_outlined,
                            size: 18, color: AppTheme.brand),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '15-day free trial · No credit card charged until trial ends · Cancel anytime',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.brand,
                                height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── RIGHT CONTENT PANEL ───────────────────────────────────
          Expanded(
            flex: 2,
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // ── STEP 1: Account Info ──────────────────────────
                _buildStep1(),
                // ── STEP 2: Plan Selection ────────────────────────
                _buildStep2(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── STEP 1 WIDGET ─────────────────────────────────────────────────
  Widget _buildStep1() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Back to login
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => context.go('/login'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.arrow_back_ios_rounded,
                          size: 14, color: AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text('Back to login',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              const Text('Create your account',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              const Text('Tell us about you and your business',
                  style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
              const SizedBox(height: 32),

              // ── Two columns: Full Name + Business Name ──────────
              Row(
                children: [
                  Expanded(
                    child: _field(
                      label: 'Your Full Name',
                      hint: 'John Smith',
                      controller: _fullNameController,
                      icon: Icons.person_outline,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _field(
                      label: 'Business Name',
                      hint: 'Acme Roofing Co.',
                      controller: _businessNameController,
                      icon: Icons.business_outlined,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Two columns: Email + Phone ───────────────────────
              Row(
                children: [
                  Expanded(
                    child: _field(
                      label: 'Business Email',
                      hint: 'you@yourbusiness.com',
                      controller: _emailController,
                      icon: Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _field(
                      label: 'Business Phone',
                      hint: '(555) 555-5555',
                      controller: _phoneController,
                      icon: Icons.phone_outlined,
                      keyboardType: TextInputType.phone,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Password ──────────────────────────────────────────
              const Text('Password',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 6),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                onChanged: (_) => setState(() {}),
                decoration: _inputDeco(
                  hint: 'Min. 8 characters',
                  prefixIcon: Icons.lock_outline,
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
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                ),
              ),

              // Password strength bar
              if (_passwordController.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                _PasswordStrengthBar(
                  strength: _passwordStrength(_passwordController.text),
                  color: _strengthColor(_passwordStrength(_passwordController.text)),
                  label: _strengthLabel(_passwordStrength(_passwordController.text)),
                ),
              ],
              const SizedBox(height: 16),

              // ── Confirm Password ──────────────────────────────────
              const Text('Confirm Password',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 6),
              TextField(
                controller: _confirmPasswordController,
                obscureText: _obscureConfirm,
                onChanged: (_) => setState(() {}),
                decoration: _inputDeco(
                  hint: 'Re-enter your password',
                  prefixIcon: Icons.lock_outline,
                  suffixIcon: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      icon: Icon(
                        _obscureConfirm
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 18,
                        color: AppTheme.textSecondary,
                      ),
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                ),
              ),

              // Match indicator
              if (_confirmPasswordController.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      _passwordController.text == _confirmPasswordController.text
                          ? Icons.check_circle_outline
                          : Icons.cancel_outlined,
                      size: 14,
                      color: _passwordController.text == _confirmPasswordController.text
                          ? AppTheme.success
                          : AppTheme.error,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _passwordController.text == _confirmPasswordController.text
                          ? 'Passwords match'
                          : 'Passwords do not match',
                      style: TextStyle(
                        fontSize: 12,
                        color: _passwordController.text == _confirmPasswordController.text
                            ? AppTheme.success
                            : AppTheme.error,
                      ),
                    ),
                  ],
                ),
              ],

              // Error message
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          size: 16, color: AppTheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_errorMessage!,
                            style: const TextStyle(
                                fontSize: 13, color: AppTheme.error)),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 28),

              // Continue button
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _goToStep2,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Continue to Plan Selection',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                        SizedBox(width: 8),
                        Icon(Icons.arrow_forward_rounded, size: 18),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Already have an account? ',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                ),
              ),
              Center(
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: TextButton(
                    onPressed: () => context.go('/login'),
                    child: const Text('Sign in instead',
                        style: TextStyle(fontSize: 13, color: AppTheme.brand)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── STEP 2 WIDGET ─────────────────────────────────────────────────
  Widget _buildStep2() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Back button
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    _pageController.animateToPage(0,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut);
                    setState(() => _currentStep = 0);
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.arrow_back_ios_rounded,
                          size: 14, color: AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text('Back',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              const Text('Choose your plan',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              const Text(
                  '15-day free trial on all plans · No credit card charged until trial ends',
                  style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
              const SizedBox(height: 32),

              // Account summary pill
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppTheme.brand.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline,
                        size: 16, color: AppTheme.brand),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Account for ${_businessNameController.text.trim().isEmpty ? 'your business' : _businessNameController.text.trim()} · ${_emailController.text.trim()}',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.brand),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

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
                              selected: _selectedPlan == plan.name,
                              onTap: () =>
                                  _selectPlan(plan.name, plan.stripeUrl),
                            ),
                          ),
                        ))
                    .toList(),
              ),

              const SizedBox(height: 28),
              Center(
                child: Text(
                  'Clicking a plan opens our secure checkout.\nAfter payment, return here to sign in.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────
  Widget _field({
    required String label,
    required String hint,
    required TextEditingController controller,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          decoration: _inputDeco(hint: hint, prefixIcon: icon),
        ),
      ],
    );
  }

  InputDecoration _inputDeco({
    required String hint,
    required IconData prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(prefixIcon, size: 18, color: AppTheme.textSecondary),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppTheme.pageBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.brand, width: 2),
      ),
    );
  }
}

// ── STEP INDICATOR ────────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  final int currentStep;
  const _StepIndicator({required this.currentStep});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Step ${currentStep + 1} of 2',
          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _StepDot(
                label: 'Your Info',
                active: currentStep == 0,
                done: currentStep > 0),
            _StepLine(filled: currentStep > 0),
            _StepDot(
                label: 'Choose Plan',
                active: currentStep == 1,
                done: false),
          ],
        ),
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  final String label;
  final bool active;
  final bool done;
  const _StepDot(
      {required this.label, required this.active, required this.done});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
                ? AppTheme.brand
                : active
                    ? AppTheme.brand
                    : AppTheme.sidebarBg,
            border: Border.all(
              color: (active || done) ? AppTheme.brand : AppTheme.borderColor,
              width: 2,
            ),
          ),
          alignment: Alignment.center,
          child: done
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : Text(
                  active ? '●' : '○',
                  style: TextStyle(
                      fontSize: 10,
                      color: active
                          ? Colors.white
                          : AppTheme.textMuted),
                ),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                fontSize: 10,
                color: (active || done)
                    ? AppTheme.brand
                    : AppTheme.textMuted)),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  final bool filled;
  const _StepLine({required this.filled});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 16, left: 4, right: 4),
        color: filled ? AppTheme.brand : AppTheme.borderColor,
      ),
    );
  }
}

// ── PASSWORD STRENGTH BAR ─────────────────────────────────────────────────────

class _PasswordStrengthBar extends StatelessWidget {
  final int strength;
  final Color color;
  final String label;
  const _PasswordStrengthBar(
      {required this.strength, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: List.generate(5, (i) {
            return Expanded(
              child: Container(
                height: 4,
                margin: EdgeInsets.only(right: i < 4 ? 4 : 0),
                decoration: BoxDecoration(
                  color: i < strength ? color : AppTheme.borderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }
}

// ── PLAN CARD ─────────────────────────────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  final _Plan plan;
  final bool selected;
  final VoidCallback onTap;
  const _PlanCard(
      {required this.plan, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: plan.isPopular
            ? AppTheme.brand.withValues(alpha: 0.05)
            : AppTheme.pageBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected
              ? AppTheme.brand
              : plan.isPopular
                  ? AppTheme.brand.withValues(alpha: 0.5)
                  : AppTheme.borderColor,
          width: selected || plan.isPopular ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (plan.isPopular)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.brand,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(10)),
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
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan.name,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary)),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(plan.price,
                        style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary)),
                    Text(plan.period,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(plan.description,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
                const SizedBox(height: 14),

                // Features
                ...plan.features.map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Icon(Icons.check_rounded,
                              size: 14, color: AppTheme.brand),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(f,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textNormal)),
                          ),
                        ],
                      ),
                    )),

                const SizedBox(height: 18),
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
                            : const BorderSide(color: AppTheme.brand),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('Start Free Trial',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
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

// ── PLAN DATA ─────────────────────────────────────────────────────────────────

class _Plan {
  final String name;
  final String price;
  final String period;
  final String description;
  final String stripeUrl;
  final bool isPopular;
  final List<String> features;
  const _Plan({
    required this.name,
    required this.price,
    required this.period,
    required this.description,
    required this.stripeUrl,
    required this.isPopular,
    required this.features,
  });
}

// ── FEATURE ITEM ──────────────────────────────────────────────────────────────

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _FeatureItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
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