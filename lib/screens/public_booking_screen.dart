import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

class PublicBookingScreen extends StatefulWidget {
  final String calendarId;
  const PublicBookingScreen({super.key, required this.calendarId});

  @override
  State<PublicBookingScreen> createState() => _PublicBookingScreenState();
}

class _PublicBookingScreenState extends State<PublicBookingScreen> {
  static const String _supabaseUrl =
      'https://rllriopqojaraceytdno.supabase.co/functions/v1';

  // Steps: 0 = select date+slot, 1 = collect info, 2 = confirmation
  int _step = 0;

  // Calendar meta
  String _calendarName = '';
  String _businessName = '';
  String _bookingPageTitle = '';
  String _bookingPageDescription = '';
  int _durationMinutes = 60;

  // Step 0
  List<String> _availabilityDays = []; // e.g. ['monday','tuesday',...]
  DateTime _selectedDate = DateTime.now().add(const Duration(days: 1));
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, dynamic>> _slots = [];
  bool _loadingSlots = false;
  String? _slotsError;
  Map<String, dynamic>? _selectedSlot;

  // Step 1
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _submitting = false;
  String? _submitError;

  // Step 2
  String _confirmationMessage = '';

  @override
  void initState() {
    super.initState();
    _fetchSlots(_selectedDate);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _fetchSlots(DateTime date) async {
    setState(() {
      _loadingSlots = true;
      _slotsError = null;
      _slots = [];
      _selectedSlot = null;
    });

    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(date);
      final response = await http.post(
        Uri.parse('$_supabaseUrl/get-available-slots'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'calendar_id': int.parse(widget.calendarId),
          'date': dateStr,
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final calendar = data['calendar'] as Map<String, dynamic>? ?? {};
        setState(() {
          _slots = List<Map<String, dynamic>>.from(data['slots'] ?? []);
          _calendarName = calendar['name'] ?? '';
          _businessName = calendar['business_name'] ?? '';
          _bookingPageTitle = calendar['booking_page_title'] ?? '';
          _bookingPageDescription = calendar['booking_page_description'] ?? '';
          _durationMinutes = calendar['duration_minutes'] ?? 60;
          final days = calendar['availability_days'];
          if (days != null) {
            _availabilityDays = List<String>.from(days);
          }
          // Advance _selectedDate to first enabled day if current selection is disabled
          if (_availabilityDays.isNotEmpty) {
            DateTime candidate = _selectedDate;
            int tries = 0;
            while (tries < 14 && !_availabilityDays.contains(
                _dayName(candidate))) {
              candidate = candidate.add(const Duration(days: 1));
              tries++;
            }
            if (candidate != _selectedDate) {
              _selectedDate = candidate;
            }
          }
          _loadingSlots = false;
        });
      } else {
        final data = jsonDecode(response.body);
        setState(() {
          _slotsError = data['error'] ?? 'Failed to load availability';
          _loadingSlots = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _slotsError = 'Network error. Please try again.';
        _loadingSlots = false;
      });
    }
  }

  Future<void> _submitBooking() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedSlot == null) return;

    setState(() {
      _submitting = true;
      _submitError = null;
    });

    try {
      final response = await http.post(
        Uri.parse('$_supabaseUrl/submit-booking'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'calendar_id': int.parse(widget.calendarId),
          'slot_start': _selectedSlot!['start'],
          'slot_end': _selectedSlot!['end'],
          'name': _nameController.text.trim(),
          'email': _emailController.text.trim(),
          'phone': _phoneController.text.trim(),
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _confirmationMessage = data['message'] ?? 'Your appointment is confirmed!';
          _step = 2;
          _submitting = false;
        });
      } else {
        final data = jsonDecode(response.body);
        setState(() {
          _submitError = data['error'] ?? 'Booking failed. Please try again.';
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

  Widget _buildCalendarGrid() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final maxDate = today.add(const Duration(days: 60));

    // Clamp month navigation
    final minMonth = DateTime(today.year, today.month);
    final maxMonth = DateTime(maxDate.year, maxDate.month);

    final firstOfMonth = _calendarMonth;
    final daysInMonth = DateUtils.getDaysInMonth(firstOfMonth.year, firstOfMonth.month);
    // Weekday of the 1st (1=Mon..7=Sun), convert to 0-based Sun-start grid
    final firstWeekday = firstOfMonth.weekday % 7; // Sun=0,Mon=1..Sat=6

    final canGoPrev = DateTime(firstOfMonth.year, firstOfMonth.month).isAfter(minMonth);
    final canGoNext = DateTime(firstOfMonth.year, firstOfMonth.month).isBefore(maxMonth);

    const dayLabels = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

    return Column(
      children: [
        // Month nav header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: canGoPrev
                  ? () => setState(() => _calendarMonth =
                      DateTime(_calendarMonth.year, _calendarMonth.month - 1))
                  : null,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: canGoPrev
                      ? const Color(0xFFF9FAFB)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: canGoPrev
                        ? const Color(0xFFE5E7EB)
                        : Colors.transparent,
                  ),
                ),
                child: Icon(
                  Icons.chevron_left_rounded,
                  size: 20,
                  color: canGoPrev
                      ? const Color(0xFF374151)
                      : const Color(0xFFD1D5DB),
                ),
              ),
            ),
            Text(
              DateFormat('MMMM yyyy').format(firstOfMonth),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111827),
              ),
            ),
            GestureDetector(
              onTap: canGoNext
                  ? () => setState(() => _calendarMonth =
                      DateTime(_calendarMonth.year, _calendarMonth.month + 1))
                  : null,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: canGoNext
                      ? const Color(0xFFF9FAFB)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: canGoNext
                        ? const Color(0xFFE5E7EB)
                        : Colors.transparent,
                  ),
                ),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: canGoNext
                      ? const Color(0xFF374151)
                      : const Color(0xFFD1D5DB),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Day-of-week labels
        Row(
          children: dayLabels.map((d) => Expanded(
            child: Center(
              child: Text(d,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF9CA3AF),
                ),
              ),
            ),
          )).toList(),
        ),
        const SizedBox(height: 8),
        // Calendar grid
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 1,
          ),
          itemCount: firstWeekday + daysInMonth,
          itemBuilder: (ctx, i) {
            if (i < firstWeekday) return const SizedBox();
            final day = i - firstWeekday + 1;
            final date = DateTime(firstOfMonth.year, firstOfMonth.month, day);
            final isPast = date.isBefore(today) || date.isAtSameMomentAs(today);
            final isBeyondMax = date.isAfter(maxDate);
            final isEnabled = _availabilityDays.isEmpty ||
                _availabilityDays.contains(_dayName(date));
            final isSelectable = !isPast && !isBeyondMax && isEnabled;
            final isSelected = date.year == _selectedDate.year &&
                date.month == _selectedDate.month &&
                date.day == _selectedDate.day;

            return GestureDetector(
              onTap: isSelectable
                  ? () {
                      setState(() => _selectedDate = date);
                      _fetchSlots(date);
                    }
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF6366F1)
                      : isSelectable
                          ? const Color(0xFFF9FAFB)
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: isSelectable && !isSelected
                      ? Border.all(color: const Color(0xFFE5E7EB))
                      : null,
                ),
                child: Center(
                  child: Text(
                    '$day',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.w400,
                      color: isSelected
                          ? Colors.white
                          : isSelectable
                              ? const Color(0xFF111827)
                              : const Color(0xFFD1D5DB),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  String _dayName(DateTime date) {
    const days = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
    return days[date.weekday - 1];
  }

  String _formatSlotTime(String isoString) {
    final dt = DateTime.parse(isoString).toLocal();
    return DateFormat('h:mm a').format(dt);
  }

  String _formatSlotRange(Map<String, dynamic> slot) {
    final start = DateTime.parse(slot['start'] as String).toLocal();
    final end = DateTime.parse(slot['end'] as String).toLocal();
    return '${DateFormat('h:mm a').format(start)} – ${DateFormat('h:mm a').format(end)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F7),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                _buildHeader(),
                const SizedBox(height: 24),
                // Step content
                if (_step == 0) _buildStepSelectSlot(),
                if (_step == 1) _buildStepCollectInfo(),
                if (_step == 2) _buildStepConfirmation(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final title = _bookingPageTitle.isNotEmpty
        ? _bookingPageTitle
        : (_calendarName.isNotEmpty ? 'Book an Appointment' : 'Book an Appointment');
    final subtitle = _bookingPageDescription.isNotEmpty ? _bookingPageDescription : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (_businessName.isNotEmpty)
          Text(
            _businessName,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF111827),
              letterSpacing: 0.3,
            ),
            textAlign: TextAlign.center,
          ),
        if (_calendarName.isNotEmpty)
          Text(
            'Calendar: $_calendarName',
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF6B7280),
              letterSpacing: 0.3,
            ),
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 4),
        Text(
          title,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: Color(0xFF111827),
          ),
          textAlign: TextAlign.center,
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
            textAlign: TextAlign.center,
          ),
        ],
        if (_step < 2) ...[
          const SizedBox(height: 20),
          _buildStepIndicator(),
        ],
      ],
    );
  }

  Widget _buildStepIndicator() {
    return Row(
      children: [
        _stepDot(0, 'Select Time'),
        _stepLine(),
        _stepDot(1, 'Your Info'),
        _stepLine(),
        _stepDot(2, 'Confirmed'),
      ],
    );
  }

  Widget _stepDot(int index, String label) {
    final isActive = _step == index;
    final isDone = _step > index;
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDone
                  ? const Color(0xFF10B981)
                  : isActive
                      ? const Color(0xFF6366F1)
                      : const Color(0xFFE5E7EB),
            ),
            child: Center(
              child: isDone
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isActive ? Colors.white : const Color(0xFF9CA3AF),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: isActive
                  ? const Color(0xFF6366F1)
                  : isDone
                      ? const Color(0xFF10B981)
                      : const Color(0xFF9CA3AF),
              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepLine() {
    return Expanded(
      child: Container(
        height: 1,
        margin: const EdgeInsets.only(bottom: 20),
        color: const Color(0xFFE5E7EB),
      ),
    );
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

  Widget _buildStepSelectSlot() {
    return _buildCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Select a Date',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 12),
          _buildCalendarGrid(),
          const SizedBox(height: 24),
          const Text(
            'Available Times',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 12),
          if (_loadingSlots)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(
                  color: Color(0xFF6366F1),
                  strokeWidth: 2,
                ),
              ),
            )
          else if (_slotsError != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _slotsError!,
                  style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else if (_slots.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No availability on this day.\nPlease select another date.',
                  style: TextStyle(color: Color(0xFF6B7280), fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _slots.map((slot) {
                final isSelected = _selectedSlot == slot;
                return GestureDetector(
                  onTap: () => setState(() => _selectedSlot = slot),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF6366F1)
                          : const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF6366F1)
                            : const Color(0xFFE5E7EB),
                      ),
                    ),
                    child: Text(
                      _formatSlotTime(slot['start'] as String),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: isSelected
                            ? Colors.white
                            : const Color(0xFF374151),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _selectedSlot == null
                  ? null
                  : () => setState(() => _step = 1),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFE5E7EB),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text(
                'Continue',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepCollectInfo() {
    return _buildCard(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Selected slot summary
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE0E0FF)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_rounded,
                      size: 16, color: Color(0xFF6366F1)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${DateFormat('EEEE, MMMM d').format(_selectedDate)}  ·  ${_formatSlotRange(_selectedSlot!)}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF4F46E5),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _step = 0),
                    child: const Text(
                      'Change',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6366F1),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
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
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFFDC2626)),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => setState(() => _step = 0),
                  child: const Text(
                    'Back',
                    style: TextStyle(color: Color(0xFF6B7280)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _submitting ? null : _submitBooking,
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
                            'Confirm Booking',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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

  Widget _buildStepConfirmation() {
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
            child: const Icon(Icons.check_rounded,
                size: 36, color: Color(0xFF10B981)),
          ),
          const SizedBox(height: 20),
          const Text(
            'You\'re all set!',
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
          const SizedBox(height: 8),
          const Text(
            'A confirmation text has been sent to your phone.',
            style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          OutlinedButton(
            onPressed: () {
              setState(() {
                _step = 0;
                _selectedSlot = null;
                _nameController.clear();
                _emailController.clear();
                _phoneController.clear();
                _confirmationMessage = '';
              });
              _fetchSlots(_selectedDate);
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF6366F1),
              side: const BorderSide(color: Color(0xFF6366F1)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text('Book Another Appointment'),
          ),
        ],
      ),
    );
  }
}