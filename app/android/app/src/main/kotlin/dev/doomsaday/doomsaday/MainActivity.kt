package dev.doomsaday.doomsaday

import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * FlutterFragmentActivity, not FlutterActivity: local_auth shows the system
 * BiometricPrompt from a FragmentActivity, which is what backs the
 * X-Confirmed: biometric header on every risky call.
 */
class MainActivity : FlutterFragmentActivity()
