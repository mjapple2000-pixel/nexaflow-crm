import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';

class BetaSignupScreen extends StatefulWidget {
  final String token;
  const BetaSignupScreen({super.key, required this.token});

  @override
  State<BetaSignupScreen> createState() => _BetaSignupScreenState();
}

class _BetaSignupScreenState extends State<BetaSignupScreen> {
  final _db = Supabase.instance.client;

  // Token validation
  bool _validating = true;
  bool _tokenValid = false;
  Map<String, dynamic>? _invite;

  // Form
  final _fullNameCtrl = TextEditingController();
  final _businessNameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _saving = false;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _validateToken();
  }

  @override
  void dispose() {
    _fullNameCtrl.dispose();
    _businessNameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _validateToken() async {
    if (widget.token.isEmpty) {
      setState(() { _validating = false; _tokenValid = false; });
      return;
    }
    try {
      final res = await _db
          .rpc('get_beta_invite', params: {'p_token': widget.token});

      if (res == null) {
        setState(() { _validating = false; _tokenValid = false; });
        return;
      }

      final invite = Map<String, dynamic>.from(res as Map);
      setState(() {
        _invite = invite;
        _validating = false;
        _tokenValid = true;
      });
    } catch (e) {
      setState(() { _validating = false; _tokenValid = false; });
    }
  }

  Future<void> _submit() async {
    final fullName = _fullNameCtrl.text.trim();
    final businessName = _businessNameCtrl.text.trim();
    final password = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;

    if (fullName.isEmpty) {
      setState(() => _error = 'Full name is required');
      return;
    }
    if (businessName.isEmpty) {
      setState(() => _error = 'Business name is required');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Passwords do not match');
      return;
    }

    setState(() { _saving = true; _error = null; });

    try {
      final email = _invite!['email'] as String;

      // 1. Create the Supabase auth user
      final authRes = await _db.auth.signUp(
        email: email,
        password: password,
        data: {'full_name': fullName},
      );

      if (authRes.user == null) {
        setState(() { _error = 'Failed to create account. Please try again.'; _saving = false; });
        return;
      }

      // Sign in immediately to establish a proper session
      await _db.auth.signInWithPassword(email: email, password: password);
      if (!mounted) return;

      final userId = authRes.user!.id;

      // 2. Create business, profile, and update beta_testers via RPC
      await _db.rpc('create_beta_business', params: {
        'p_business_name': businessName,
        'p_email': email,
        'p_full_name': fullName,
        'p_user_id': userId,
        'p_beta_tester_id': _invite!['id'] as int,
      });

      if (!mounted) return;
      setState(() { _done = true; _saving = false; });
    } catch (e) {
      if (mounted) {
        setState(() { _error = e.toString(); _saving = false; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: 480,
            decoration: BoxDecoration(
              color: AppTheme.cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderColor),
              boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 24, offset: const Offset(0, 8))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Top color bar
              Container(
                height: 5,
                decoration: BoxDecoration(
                  color: AppTheme.brand,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                ),
              ),

              Padding(
                padding: const EdgeInsets.all(32),
                child: _validating
                    ? const Center(child: CircularProgressIndicator())
                    : !_tokenValid
                        ? _buildInvalidToken()
                        : _done
                            ? _buildSuccess()
                            : _buildForm(),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildInvalidToken() {
    return Column(children: [
      Container(
        width: 56, height: 56,
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.link_off_rounded, color: AppTheme.error, size: 28)),
      const SizedBox(height: 20),
      const Text('Invalid or Expired Link',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary)),
      const SizedBox(height: 12),
      const Text(
          'This beta invite link is invalid or has expired.\nPlease contact your NexaFlow representative for a new invite.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: AppTheme.textSecondary, height: 1.5)),
      const SizedBox(height: 24),
      OutlinedButton(
        onPressed: () => context.go('/login'),
        style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.brand,
            side: BorderSide(color: AppTheme.brand),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
        child: const Text('Back to Login')),
    ]);
  }

  Widget _buildSuccess() {
    return Column(children: [
      Container(
        width: 56, height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF10B981).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.check_circle_outline_rounded,
            color: Color(0xFF10B981), size: 28)),
      const SizedBox(height: 20),
      const Text('Welcome to NexaFlow Beta!',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary)),
      const SizedBox(height: 12),
      const Text(
          'Your account has been created successfully.\nYou now have full access to all NexaFlow features.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: AppTheme.textSecondary, height: 1.5)),
      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => context.go('/dashboard'),
          style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          child: const Text('Go to Dashboard',
              style: TextStyle(fontWeight: FontWeight.w600))),
      ),
    ]);
  }

  Widget _buildForm() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Logo
      Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
              color: AppTheme.brand, borderRadius: BorderRadius.circular(10)),
          alignment: Alignment.center,
          child: const Text('N',
              style: TextStyle(color: Colors.white, fontSize: 20,
                  fontWeight: FontWeight.bold))),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('NexaFlow',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.brand.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('BETA ACCESS',
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
                    color: AppTheme.brand, letterSpacing: 1)),
          ),
        ]),
      ]),
      const SizedBox(height: 24),
      const Text('Create Your Account',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary)),
      const SizedBox(height: 6),
      Text('Setting up beta access for ${_invite?['email'] ?? ''}',
          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      const SizedBox(height: 28),

      if (_error != null) Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Icon(Icons.error_outline, size: 16, color: AppTheme.error),
          const SizedBox(width: 8),
          Expanded(child: Text(_error!,
              style: TextStyle(fontSize: 13, color: AppTheme.error))),
        ])),

      // Full Name
      _label('Full Name'),
      const SizedBox(height: 6),
      TextFormField(
        controller: _fullNameCtrl,
        style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        decoration: const InputDecoration(
            hintText: 'John Smith',
            hintStyle: TextStyle(color: AppTheme.textSecondary)),
      ),
      const SizedBox(height: 16),

      // Business Name
      _label('Business Name'),
      const SizedBox(height: 6),
      TextFormField(
        controller: _businessNameCtrl,
        style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        decoration: const InputDecoration(
            hintText: 'Smith Roofing LLC',
            hintStyle: TextStyle(color: AppTheme.textSecondary)),
      ),
      const SizedBox(height: 16),

      // Password
      _label('Password'),
      const SizedBox(height: 6),
      TextFormField(
        controller: _passwordCtrl,
        obscureText: _obscurePassword,
        style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: 'Min. 8 characters',
          hintStyle: const TextStyle(color: AppTheme.textSecondary),
          suffixIcon: GestureDetector(
            onTap: () => setState(() => _obscurePassword = !_obscurePassword),
            child: Icon(_obscurePassword
                ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                size: 18, color: AppTheme.textSecondary)),
          suffixIconConstraints: const BoxConstraints(minWidth: 40),
        ),
      ),
      const SizedBox(height: 16),

      // Confirm Password
      _label('Confirm Password'),
      const SizedBox(height: 6),
      TextFormField(
        controller: _confirmCtrl,
        obscureText: _obscureConfirm,
        style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: 'Re-enter your password',
          hintStyle: const TextStyle(color: AppTheme.textSecondary),
          suffixIcon: GestureDetector(
            onTap: () => setState(() => _obscureConfirm = !_obscureConfirm),
            child: Icon(_obscureConfirm
                ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                size: 18, color: AppTheme.textSecondary)),
          suffixIconConstraints: const BoxConstraints(minWidth: 40),
        ),
      ),
      const SizedBox(height: 28),

      // Submit
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: _saving ? null : _submit,
          style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8))),
          child: _saving
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Text('Create My Account',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
      ),
      const SizedBox(height: 16),
      Center(child: Text(
          'Already have an account? ',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
      Center(child: GestureDetector(
        onTap: () => context.go('/login'),
        child: Text('Sign in',
            style: TextStyle(fontSize: 13, color: AppTheme.brand,
                fontWeight: FontWeight.w600)),
      )),
    ]);
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
          color: AppTheme.textSecondary));
}