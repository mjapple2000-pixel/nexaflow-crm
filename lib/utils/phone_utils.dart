import 'package:flutter/services.dart';

/// Formats and validates US phone numbers throughout NexaFlow so every
/// phone field ends up as a clean, valid "954-557-7238" string in the
/// database — never a raw digit string, a malformed "+81..." E.164
/// mistake, or anything else that would silently fail at Twilio send time.

/// Formats digits as the user types: auto-inserts dashes as 3-3-4 groups,
/// caps at 10 digits. Attach to any phone TextField's inputFormatters.
class PhoneNumberInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final allDigits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final digits = allDigits.substring(0, allDigits.length.clamp(0, 10));
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i == 3 || i == 6) buffer.write('-');
      buffer.write(digits[i]);
    }
    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Validates and normalizes a phone number for storage. Returns a clean
/// "954-557-7238" string for a valid 10-digit US number (accepting an
/// optional leading 1 / +1), or null if the input isn't a usable US
/// number. Strips everything else (dashes, spaces, parens, a stray "+")
/// before checking length, so malformed input like "+8139518523" gets
/// caught here instead of reaching Twilio.
String? normalizeUsPhone(String raw) {
  var digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 11 && digits.startsWith('1')) {
    digits = digits.substring(1);
  }
  if (digits.length != 10) return null;
  return '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
}