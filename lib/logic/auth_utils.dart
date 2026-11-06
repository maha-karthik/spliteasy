// Pure Dart. Checks and friendly messages for the sign-in screen.

final RegExp _emailRe = RegExp(r'^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}$');

bool isValidEmail(String s) => _emailRe.hasMatch(s.trim());

/// null when the password is acceptable, otherwise a short reason.
String? passwordProblem(String p) {
  if (p.length < 8) return 'Use at least 8 characters';
  if (!RegExp(r'[A-Za-z]').hasMatch(p) || !RegExp(r'\d').hasMatch(p)) return 'Use letters and at least one number';
  return null;
}

/// Turns a Firebase error code into a plain sentence.
String friendlyAuthError(String code) {
  switch (code) {
    case 'invalid-email':
      return 'That email address does not look right.';
    case 'user-not-found':
    case 'wrong-password':
    case 'invalid-credential':
    case 'invalid-login-credentials':
      return 'Email or password is incorrect.';
    case 'email-already-in-use':
      return 'An account with this email already exists. Try signing in.';
    case 'weak-password':
      return 'Choose a stronger password.';
    case 'network-request-failed':
      return 'No internet connection. Try again when you are online.';
    case 'too-many-requests':
      return 'Too many attempts. Wait a few minutes and try again.';
    case 'user-disabled':
      return 'This account has been disabled.';
    case 'canceled':
    case 'popup-closed-by-user':
    case 'web-context-canceled':
      return 'Sign-in was cancelled.';
    case 'account-exists-with-different-credential':
      return 'This email is already registered with another sign-in method.';
    default:
      return 'Sign-in failed ($code). Please try again.';
  }
}
