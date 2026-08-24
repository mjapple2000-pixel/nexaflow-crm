import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class PublicReferralScreen extends StatefulWidget {
  final String referralCode;
  const PublicReferralScreen({super.key, required this.referralCode});

  @override
  State<PublicReferralScreen> createState() => _PublicReferralScreenState();
}

class _PublicReferralScreenState extends State<PublicReferralScreen> {
  static const String _supabaseUrl =
      'https://rllriopqojaraceytdno.supabase.co/functions/v1';

  bool _loadingPreview = true;
  bool _validCode = false;
  String _invalidMessage = 'This referral link is no longer active.';
  String? _referrerFirstName;
  String? _businessName;

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _submitting = false;
  String? _submitError;

  bool _submitted = false;
  String _confirmationMessage = '';

  @override
  void initState() {
    super.initState();
    _fetchPreview();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _fetchPreview() async {
    try {
      final uri = Uri.parse('$_supabaseUrl/handle-referral-signup')
          .replace(queryParameters: {'code': widget.referralCode});
      final response = await http.get(uri);

      if (!mounted) return;

      final data = jsonDecode(response.body);
      setState(() {
        _validCode = data['valid'] == true;
        _invalidMessage = data['message'] ?? _invalidMessage;
        _referrerFirstName = data['referrer_first_name'];
        _businessName = data['business_name'];
        _loadingPreview = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _validCode = false;
        _invalidMessage = 'This referral link is no longer active.';
        _loadingPreview = false;
      });
    }
  }

  Future<void> _submitReferral() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _submitting = true;
      _submitError = null;
    });

    try {
      final response = await http.post(
        Uri.parse('$_supabaseUrl/handle-referral-signup'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'referral_code': widget.referralCode,
          'name': _nameController.text.trim(),
          'email': _emailController.text.trim(),
          'phone': _phoneController.text.trim(),
        }),
      );

      if (!mounted) return;

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        setState(() {
          _confirmationMessage = data['message'] ?? 'Thanks for the referral!';
          _submitted = true;
          _submitting = false;
        });
      } else {
        setState(() {
          _submitError = data['message'] ?? 'Something went wrong. Please try again.';
          _submitting = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitError = 'Network error. Please try again.';
        _submitting = false;
      });
    }
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: child,
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF374151),
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          validator: validator,
          style: const TextStyle(fontSize: 14, color: Color(0xFF111827)),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: Color(0xFF6366F1), width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFEF4444)),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
            ),
            filled: true,
            fillColor: const Color(0xFFFAFAFA),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F7),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_loadingPreview) _buildLoading(),
                if (!_loadingPreview && !_validCode) _buildInvalid(),
                if (!_loadingPreview && _validCode && !_submitted) _buildForm(),
                if (!_loadingPreview && _validCode && _submitted) _buildConfirmation(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return _buildCard(
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(
            color: Color(0xFF6366F1),
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }

  Widget _buildInvalid() {
    return _buildCard(
      child: Column(
        children: [
          const Icon(Icons.link_off_rounded, size: 48, color: Color(0xFF9CA3AF)),
          const SizedBox(height: 16),
          const Text(
            'Link No Longer Active',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _invalidMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    final referrerLabel = _referrerFirstName != null && _referrerFirstName!.isNotEmpty
        ? '$_referrerFirstName thinks you\'d like'
        : 'You\'ve been referred to';
    final businessLabel = _businessName ?? 'this business';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Column(
          children: [
            Text(
              referrerLabel,
              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              businessLabel,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF111827),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildCard(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your Information',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 16),
                _buildField(
                  controller: _nameController,
                  label: 'Full Name',
                  hint: 'John Smith',
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Name is required' : null,
                ),
                const SizedBox(height: 14),
                _buildField(
                  controller: _emailController,
                  label: 'Email Address',
                  hint: 'john@example.com',
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Email is required';
                    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())) {
                      return 'Enter a valid email';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                _buildField(
                  controller: _phoneController,
                  label: 'Phone Number',
                  hint: '(813) 555-0001',
                  keyboardType: TextInputType.phone,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Phone is required';
                    if (v.trim().replaceAll(RegExp(r'\D'), '').length < 7) {
                      return 'Enter a valid phone number';
                    }
                    return null;
                  },
                ),
                if (_submitError != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Text(
                      _submitError!,
                      style: const TextStyle(fontSize: 13, color: Color(0xFFDC2626)),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submitting ? null : _submitReferral,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6366F1),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFE5E7EB),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text(
                            'Get Started',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfirmation() {
    return _buildCard(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: Color(0xFFD1FAE5),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded, size: 36, color: Color(0xFF10B981)),
          ),
          const SizedBox(height: 20),
          const Text(
            'Thanks!',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _confirmationMessage,
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}