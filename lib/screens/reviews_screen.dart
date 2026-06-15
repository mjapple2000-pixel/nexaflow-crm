import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/clickable.dart';
import '../utils/business_utils.dart';

class ReviewsScreen extends StatefulWidget {
  const ReviewsScreen({super.key});

  @override
  State<ReviewsScreen> createState() => _ReviewsScreenState();
}

class _ReviewsScreenState extends State<ReviewsScreen> {
  final _supabase = Supabase.instance.client;

  bool _loading = true;
  String? _error;
  int? _businessId;
  Map<String, dynamic> _business = {};

  final _googleCtrl   = TextEditingController();
  final _facebookCtrl = TextEditingController();
  int _delayMinutes   = 0;
  bool _saving        = false;
  String? _successMsg;
  String? _saveError;

  static const _delayOptions = [
    (0,    'Immediately'),
    (60,   '1 hour after'),
    (240,  '4 hours after'),
    (1440, '1 day after'),
    (2880, '2 days after'),
    (4320, '3 days after'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _googleCtrl.dispose();
    _facebookCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      _businessId = await getActiveBusinessId();
      if (_businessId == null) throw Exception('No business found.');
      final res = await _supabase
          .from('businesses')
          .select()
          .eq('id', _businessId!)
          .maybeSingle();
      final b = res ?? {};
      _googleCtrl.text   = b['google_review_link']   ?? '';
      _facebookCtrl.text = b['facebook_review_link'] ?? '';
      _delayMinutes      = b['review_request_delay_minutes'] as int? ?? 0;
      if (!_delayOptions.any((o) => o.$1 == _delayMinutes)) _delayMinutes = 0;
      setState(() { _business = b; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _save() async {
    if (_businessId == null) return;
    setState(() { _saving = true; _saveError = null; _successMsg = null; });
    try {
      await _supabase.from('businesses').update({
        'google_review_link':           _googleCtrl.text.trim(),
        'facebook_review_link':         _facebookCtrl.text.trim(),
        'review_request_delay_minutes': _delayMinutes,
      }).eq('id', _businessId!);
      setState(() { _successMsg = 'Review settings saved.'; _saving = false; });
    } catch (e) {
      setState(() { _saveError = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.pageBg,
      body: Column(children: [
        // Top bar
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: AppTheme.cardBg,
            border: Border(bottom: BorderSide(color: AppTheme.borderColor)),
          ),
          child: const Row(children: [
            Icon(Icons.star_outline, size: 18, color: AppTheme.brand),
            SizedBox(width: 10),
            Text('Reviews',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary)),
          ]),
        ),
        // Body
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _errorView()
                  : _buildContent(),
        ),
      ]),
    );
  }

  Widget _errorView() {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.error_outline, color: Colors.red, size: 40),
      const SizedBox(height: 12),
      Text(_error!, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      const SizedBox(height: 12),
      ElevatedButton(onPressed: _load, child: const Text('Retry')),
    ]));
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Reviews',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 4),
        const Text('Set up automatic review requests sent to customers after a job is completed.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const SizedBox(height: 28),

        // Info banner
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFf59e0b).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFf59e0b).withValues(alpha: 0.3)),
          ),
          child: const Row(children: [
            Icon(Icons.star_outline, size: 16, color: Color(0xFFf59e0b)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'When an appointment is marked as Completed, an SMS is automatically sent to the customer with your review link. Set your links below, then create a "Send Review Request" automation using the "Appointment Completed" trigger.',
                style: TextStyle(fontSize: 12, color: Color(0xFFf59e0b), height: 1.5),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 28),

        // Review Links
        _group('Review Links', Column(children: [
          _field('Google Review Link', _googleCtrl,
              hint: 'https://g.page/r/your-business/review'),
          const SizedBox(height: 16),
          _field('Facebook Review Link', _facebookCtrl,
              hint: 'https://www.facebook.com/your-page/reviews'),
        ])),
        const SizedBox(height: 24),

        // Send Delay
        _group('Send Delay', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'How long after job completion before the review request SMS is sent.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _delayOptions.map((opt) {
              final selected = _delayMinutes == opt.$1;
              return Clickable(
                onTap: () => setState(() => _delayMinutes = opt.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    color: selected ? AppTheme.brand : AppTheme.pageBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: selected ? AppTheme.brand : AppTheme.borderColor),
                  ),
                  child: Text(opt.$2,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: selected ? Colors.white : AppTheme.textSecondary)),
                ),
              );
            }).toList(),
          ),
        ])),
        const SizedBox(height: 24),

        // Automation reminder
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.brand.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.brand.withValues(alpha: 0.2)),
          ),
          child: const Row(children: [
            Icon(Icons.bolt_outlined, size: 18, color: AppTheme.brand),
            SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Automation Required',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppTheme.brand)),
              SizedBox(height: 2),
              Text(
                'Save your links above, then go to Automations → New Automation → Trigger: Appointment Completed → Action: Send Review Request.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.4),
              ),
            ])),
          ]),
        ),
        const SizedBox(height: 28),

        // Save button
        Row(children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8))),
              child: _saving
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save Changes'),
            ),
          ),
          if (_successMsg != null) ...[
            const SizedBox(width: 12),
            const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 16),
            const SizedBox(width: 4),
            Text(_successMsg!,
                style: const TextStyle(color: Color(0xFF10B981), fontSize: 13)),
          ],
          if (_saveError != null) ...[
            const SizedBox(width: 12),
            Text(_saveError!,
                style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
        ]),
      ]),
    );
  }

  Widget _group(String title, Widget child) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary)),
      const SizedBox(height: 12),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.borderColor)),
        child: child,
      ),
    ]);
  }

  Widget _field(String label, TextEditingController ctrl, {String? hint}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary)),
      const SizedBox(height: 6),
      TextField(
        controller: ctrl,
        style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          filled: true,
          fillColor: AppTheme.pageBg,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.borderColor)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.borderColor)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppTheme.brand, width: 1.5)),
        ),
      ),
    ]);
  }
}