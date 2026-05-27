import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';

class SetupAccountScreen extends StatefulWidget {
  const SetupAccountScreen({super.key});

  @override
  State<SetupAccountScreen> createState() => _SetupAccountScreenState();
}

class _SetupAccountScreenState extends State<SetupAccountScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _errorMessage;
  String? _email;

  @override
  void initState() {
    super.initState();
    _email = Supabase.instance.client.auth.currentUser?.email;
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _setupAccount() async {
    final password = _passwordController.text.trim();
    final confirm = _confirmController.text.trim();

    if (password.isEmpty) {
      setState(() => _errorMessage = 'Please enter a password.');
      return;
    }
    if (password.length < 8) {
      setState(() => _errorMessage = 'Password must be at least 8 characters.');
      return;
    }
    if (password != confirm) {
      setState(() => _errorMessage = 'Passwords do not match.');
      return;
    }

    setState(() { _loading = true; _errorMessage = null; });

    try {
      // Set their password
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: password),
      );
      if (!mounted) return;

      // Update their profile status from pending to active
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        // Delete orphan active profile with no business
        await Supabase.instance.client
            .from('profiles')
            .delete()
            .eq('user_id', userId)
            .filter('business_id', 'is', null);

        // Update the pending profile with user_id and set active
        await Supabase.instance.client
            .from('profiles')
            .update({'status': 'active', 'user_id': userId})
            .eq('email', _email ?? '')
            .eq('status', 'pending');
      }

      if (!mounted) return;
      context.go('/dashboard');

    } on AuthException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (e) {
      setState(() => _errorMessage = 'An unexpected error occurred.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
                  const _InfoItem(
                      icon: Icons.lock_outline,
                      text: 'Set a secure password for your account'),
                  const _InfoItem(
                      icon: Icons.people_alt_outlined,
                      text: 'Access your team\'s NexaFlow workspace'),
                  const _InfoItem(
                      icon: Icons.verified_outlined,
                      text: 'Your email is already verified'),
                ],
              ),
            ),
          ),

          // ── RIGHT SETUP PANEL ─────────────────────────────────────
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
                    const Text('Set up your account',
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 8),
                    const Text('Create a password to access your workspace.',
                        style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.textSecondary)),
                    const SizedBox(height: 24),

                    // EMAIL (read only)
                    const Text('Email',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.pageBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.borderColor),
                      ),
                      child: Text(
                        _email ?? '',
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary),
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
                        hintText: 'At least 8 characters',
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
                          borderSide:
                              const BorderSide(color: AppTheme.brand, width: 2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // CONFIRM PASSWORD
                    const Text('Confirm Password',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _confirmController,
                      obscureText: _obscureConfirm,
                      decoration: InputDecoration(
                        hintText: 'Re-enter your password',
                        prefixIcon: const Icon(Icons.lock_outline,
                            size: 18, color: AppTheme.textSecondary),
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
                            onPressed: () => setState(() =>
                                _obscureConfirm = !_obscureConfirm),
                          ),
                        ),
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
                          borderSide:
                              const BorderSide(color: AppTheme.brand, width: 2),
                        ),
                      ),
                      onSubmitted: (_) => _setupAccount(),
                    ),

                    // ERROR
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
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

                    const SizedBox(height: 24),

                    // SUBMIT
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _setupAccount,
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
                                      strokeWidth: 2, color: Colors.white))
                              : const Text('Create Account',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),
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

class _InfoItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 48),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.brand),
          const SizedBox(width: 12),
          Text(text,
              style: const TextStyle(
                  color: AppTheme.textMuted, fontSize: 13)),
        ],
      ),
    );
  }
}