/// Neutralizes CSV formula injection (a.k.a. "CSV injection"). If a cell
/// value starts with =, +, -, @, tab, or carriage return, Excel/Google
/// Sheets may interpret it as a formula when the file is opened — letting
/// attacker-controlled data (e.g. a public booking form's "name" field,
/// which has no content restriction) execute arbitrary formulas, exfiltrate
/// data via HYPERLINK(), or on old Excel versions even launch external
/// commands via DDE. Prefixing with a single quote forces spreadsheet apps
/// to treat it as literal text — the value still reads correctly for a
/// human opening the raw CSV.
String csvSafe(dynamic value) {
  final s = value?.toString() ?? '';
  if (s.isEmpty) return s;
  const dangerousPrefixes = ['=', '+', '-', '@', '\t', '\r'];
  if (dangerousPrefixes.any((p) => s.startsWith(p))) {
    return "'$s";
  }
  return s;
}