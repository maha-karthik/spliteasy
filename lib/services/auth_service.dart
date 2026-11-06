import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

/// Cloud sign-in. Entirely optional: if Firebase is not configured in this build, or the phone
/// is offline, the app keeps working with local data ([ready] stays false).
class AuthService {
  static bool ready = false;
  static String? initError;

  static Future<void> init() async {
    try {
      await Firebase.initializeApp().timeout(const Duration(seconds: 8));
      ready = true;
    } catch (e) {
      initError = '$e';
    }
  }

  static User? get user => ready ? FirebaseAuth.instance.currentUser : null;

  /// Emits true/false whenever the person signs in or out.
  static Stream<bool> get signedIn =>
      ready ? FirebaseAuth.instance.authStateChanges().map((u) => u != null) : Stream<bool>.value(false);

  /// Google sign-in through Firebase's own browser flow (no extra Google Sign-In package).
  static Future<void> google() => FirebaseAuth.instance.signInWithProvider(GoogleAuthProvider());

  static Future<void> emailSignIn(String email, String password) =>
      FirebaseAuth.instance.signInWithEmailAndPassword(email: email.trim(), password: password);

  static Future<void> emailRegister(String email, String password) async {
    final c = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email.trim(), password: password);
    try {
      await c.user?.sendEmailVerification();
    } catch (_) {} // verification mail is a courtesy; never block sign-up on it
  }

  static Future<void> resetPassword(String email) => FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim());

  static Future<void> signOut() => FirebaseAuth.instance.signOut();
}
