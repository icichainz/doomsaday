import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'data/biometrics.dart';
import 'data/models.dart';
import 'data/preferences.dart';
import 'data/providers.dart';
import 'data/server_store.dart';
import 'data/servers_repository.dart';
import 'edition/edition.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final SharedPreferences prefs = await SharedPreferences.getInstance();

  // Servers and the pinned fingerprints come out of shared_preferences; the
  // device keys come out of the platform keystore. Both are read before the
  // first frame so the Servers screen never flashes an empty state.
  final ServersRepository servers = ServersRepository(
    store: PrefsServerStore(prefs),
    maxServers: currentEdition.maxServers,
  );
  final Authenticator authenticator = LocalAuthAuthenticator();
  // A 428 the confirm dialog did not already answer runs the same prompt.
  // A device with no biometrics confirms by typing in the dialog instead, so
  // here a failed prompt means "send nothing".
  servers.confirmationHandler = () async =>
      await authenticator.confirm('Confirm this action on the server')
      ? Confirmed.biometric
      : Confirmed.none;
  await servers.ensureLoaded();

  // "Open the app on": the last server's Overview while that server is still
  // paired, the Servers list otherwise. Resolved here, before the router is
  // built, so the app never opens on one screen and jumps to another.
  final String start = startLocation(Preferences.read(prefs), servers.servers);

  runApp(
    ProviderScope(
      overrides: <Override>[
        sharedPreferencesProvider.overrideWithValue(prefs),
        serversRepositoryProvider.overrideWithValue(servers),
        authenticatorProvider.overrideWithValue(authenticator),
        startLocationProvider.overrideWithValue(start),
      ],
      child: const DoomsadayApp(),
    ),
  );
}
