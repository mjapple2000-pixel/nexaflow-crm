import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _loading = true;
  bool _sessionReady = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initSession();
  }

  Future<void> _initSession() async {
    // If session already exists (Supabase auto-recovered it), we're good
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      if (mounted) setState(() { _sessionReady = true; _loading = false; });
      return;
    }

    // Try to recover from URL fragment manually
    try {
      final uri = Uri.base;
      // Supabase puts tokens after the path fragment, try the full URL string
      final fullUrl = uri.toString();
      final hashIndex = fullUrl.indexOf('#');
      if (hashIndex != -1) {
        final fragment = fullUrl.substring(hashIndex + 1);
        final params = Uri.splitQueryString(fragment);
        final accessToken = params['access_token'] ?? '';
        if (accessToken.isNotEmpty) {
          await Supabase.instance.client.auth.recoverSession(accessToken);
          if (mounted) setState(() { _sessionReady = true; _loading = false; });
          return;
        }
      }
    } catch (e) {
      debugPrint('Session recovery error: $e');
    }

    if (mounted) {
      setState(() {
        _errorMessage = 'This reset link has expired. Please request a new one.';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _savePassword() async {
    final password = _passwordController.text.trim();
    final confirm = _confirmController.text.trim();

    if (password.isEmpty || confirm.isEmpty) {
      setState(() => _errorMessage = 'Please fill in both fields.');
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
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: password),
      );
      if (!mounted) return;
      await Supabase.instance.client.auth.signOut();
      if (!mounted) return;
      context.go('/login?reset=complete');
    } on AuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'An unexpected error occurred.');
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
                ],
              ),
            ),
          ),

          // ── RIGHT PANEL ───────────────────────────────────────────
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
                child: _loading
                    ? const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: AppTheme.brand),
                          SizedBox(height: 16),
                          Text('Verifying reset link...',
                              style: TextStyle(color: AppTheme.textSecondary)),
                        ],
                      )
                    : !_sessionReady
                        ? Column(
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
                              Text(
                                _errorMessage ??
                                    'This reset link has expired. Please request a new one.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.textSecondary),
                              ),
                              const SizedBox(height: 24),
                              SizedBox(
                                width: double.infinity,
                                height: 44,
                                child: ElevatedButton(
                                  onPressed: () => context.go('/login'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.brand,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(8)),
                                  ),
                                  child: const Text('Back to Login'),
                                ),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.lock_reset_rounded,
                                  size: 36, color: AppTheme.brand),
                              const SizedBox(height: 16),
                              const Text('Set new password',
                                  style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.textPrimary)),
                              const SizedBox(height: 8),
                              const Text(
                                  'Choose a strong password for your account.',
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: AppTheme.textSecondary)),
                              const SizedBox(height: 28),

                              const Text('New Password',
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
                                      size: 18,
                                      color: AppTheme.textSecondary),
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
                              ),
                              const SizedBox(height: 16),

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
                                  hintText: '••••••••',
                                  prefixIcon: const Icon(Icons.lock_outline,
                                      size: 18,
                                      color: AppTheme.textSecondary),
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
                                onSubmitted: (_) => _savePassword(),
                              ),

                              if (_errorMessage != null) ...[
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: AppTheme.error
                                        .withValues(alpha: 0.1),
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

                              MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: SizedBox(
                                  width: double.infinity,
                                  height: 44,
                                  child: ElevatedButton(
                                    onPressed: _loading ? null : _savePassword,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppTheme.brand,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                    ),
                                    child: _loading
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white))
                                        : const Text('Save Password',
                                            style: TextStyle(
                                                fontSize: 15,
                                                fontWeight:
                                                    FontWeight.w600)),
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