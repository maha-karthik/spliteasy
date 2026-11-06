import 'package:flutter_test/flutter_test.dart';
import 'package:spliteasy/logic/auth_utils.dart';

void main() {
  test('email check', () {
    for (final ok in ['a@b.co', 'karthik.m+x@gmail.com', ' priya@mail.example.in ']) {
      expect(isValidEmail(ok), isTrue, reason: ok);
    }
    for (final bad in ['', 'abc', 'a@b', 'a@@b.com', '@b.com', 'a b@c.com', 'a@b.c']) {
      expect(isValidEmail(bad), isFalse, reason: bad);
    }
  });
  test('password rules', () {
    expect(passwordProblem('abc123'), isNotNull);
    expect(passwordProblem('abcdefgh'), isNotNull);
    expect(passwordProblem('12345678'), isNotNull);
    expect(passwordProblem('abcd1234'), isNull);
  });
  test('confirm password', () {
    expect(confirmProblem('abcd1234', 'abcd1234'), isNull);
    expect(confirmProblem('abcd1234', 'abcd1235'), isNotNull);
    expect(friendlyAuthError('operation-not-allowed'), contains('switched off'));
  });
  test('friendly errors', () {
    expect(friendlyAuthError('wrong-password'), contains('incorrect'));
    expect(friendlyAuthError('invalid-credential'), contains('incorrect'));
    expect(friendlyAuthError('network-request-failed'), contains('internet'));
    expect(friendlyAuthError('something-new'), contains('something-new'));
  });
}
