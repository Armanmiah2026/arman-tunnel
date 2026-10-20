import 'package:flutter_test/flutter_test.dart';

import 'package:snapdark_tunnel/models/vpn_state.dart';
import 'package:snapdark_tunnel/utils/user_error.dart';

// Tests run in debug mode (kReleaseMode == false), so showRaw is true and raw
// detail is appended. The RELEASE stripping is the whole point but is compiled
// behind kReleaseMode, so here we assert the DEBUG contract + the category
// wording that release also uses.
void main() {
  test('debug appends raw detail after the friendly sentence', () {
    final s = UserError.forCategory(
      ErrorCategory.network,
      raw: 'java.net.UnknownHostException: gstatic',
    );
    expect(s, startsWith('Network error'));
    expect(s, contains('UnknownHostException'));
  });

  test('withRaw omits empty / duplicate detail', () {
    expect(UserError.withRaw('Base error.', null), 'Base error.');
    expect(UserError.withRaw('Base error.', 'Base error.'), 'Base error.');
  });

  test('exception toast has a friendly base and truncates to one line', () {
    final s = UserError.forException(
      StateError('boom\nstack line 2'),
      friendly: 'App error — could not stop the tunnel.',
    );
    expect(s, startsWith('App error'));
    expect(s, contains('boom'));
    expect(s, isNot(contains('stack line 2')));
  });

  test('forRawLine keeps the line verbatim in debug', () {
    const raw = 'probe[gstatic:80] failed: ECONNREFUSED';
    expect(UserError.forRawLine(raw), raw);
  });
}
