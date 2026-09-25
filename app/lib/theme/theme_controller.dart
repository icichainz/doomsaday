/// The app's System/Light/Dark choice.
///
/// It used to be its own little store on the Server settings screen. It now
/// comes out of [preferencesProvider] with everything else that is about this
/// app rather than one agent, and this file is the thin read-only view of it
/// that `MaterialApp` and the screens watch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/preferences.dart';

export '../data/preferences.dart' show sharedPreferencesProvider;

final themeModeProvider = Provider<ThemeMode>(
  (ref) =>
      ref.watch(preferencesProvider.select((Preferences p) => p.themeMode)),
);
