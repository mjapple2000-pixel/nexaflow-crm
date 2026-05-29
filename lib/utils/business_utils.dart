import 'package:supabase_flutter/supabase_flutter.dart';
import '../screens/business_picker_screen.dart';

Future<int?> getActiveBusinessId() async {
  if (SuperuserState.impersonatedBusinessId != null) {
    return SuperuserState.impersonatedBusinessId;
  }

  final db = Supabase.instance.client;
  final userId = db.auth.currentUser?.id;
  if (userId == null) return null;

  final profile = await db
      .from('profiles')
      .select('business_id')
      .eq('user_id', userId)
      .maybeSingle();

  return profile?['business_id'] as int?;
}

String? getActiveBusinessName() {
  return SuperuserState.impersonatedBusinessName;
}

bool isImpersonating() {
  return SuperuserState.impersonatedBusinessId != null;
}