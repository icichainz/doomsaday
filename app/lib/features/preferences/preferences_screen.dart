/// App preferences — the boards `AppSettings` (phone) and `DesktopPreferences`
/// (D7).
///
/// Preferences is about **this app on this device**, across every server:
/// theme, density, the app lock, how fast live data arrives, what the app
/// opens on, demo data, the edition and the version. Server settings stays
/// about one agent, and no longer carries the theme switch.
///
/// Below 600 this is one scrolling screen. From 600 it is a 680×520 dialog
/// with the section list on the left, which remembers the section you were on
/// for as long as the app is running.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../data/preferences.dart';
import '../../data/providers.dart';
import '../../edition/edition.dart';
import '../../edition/pro_badge.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/notify.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/stroke_icons.dart';
import '../servers/servers_screen.dart';
import 'app_lock.dart';

/// What the boards call this machine. D7 is drawn on a Mac and says so; a
/// phone or a PC gets the neutral wording.
bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

String get _osName => _isMac ? 'macOS' : 'the device';

String get _deviceName => _isMac ? 'this Mac' : 'this device';

/// The agent REST API this build speaks, as the About row names it.
const String kAgentApiVersion = 'v1.1';

/// Shown until `package_info_plus` answers, and wherever it cannot — a widget
/// test has no platform channel behind it.
const String kFallbackVersion = '0.1.0';

/// The app's own version, from the platform rather than a constant in Dart.
final appVersionProvider = FutureProvider<String>((ref) async {
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    return info.version.isEmpty ? kFallbackVersion : info.version;
  } on Object {
    // No platform channel (tests, the screenshot harness): the pubspec value.
    return kFallbackVersion;
  }
});

/// The dialog's left-hand list. Edition lives inside About, as the README says.
enum PreferenceSection {
  appearance('Appearance', StrokeGlyph.sun),
  security('Security', StrokeGlyph.lock),
  liveData('Live data', StrokeGlyph.pulse),
  general('General', StrokeGlyph.cog),
  about('About', StrokeGlyph.info);

  const PreferenceSection(this.label, this.glyph);

  final String label;
  final StrokeGlyph glyph;
}

/// Which section the dialog was left on. Deliberately not persisted: the
/// README asks for "remembers the last section while the app runs".
final _sectionProvider = StateProvider<PreferenceSection>(
  (ref) => PreferenceSection.appearance,
);

// --------------------------------------------------------------- opening it

/// Opens Preferences the way this window wants it.
///
/// Below 600 that is a pushed screen with a back link; from 600 it is the
/// dialog over whatever is on screen. Both land on the same content.
Future<void> openPreferences(BuildContext context) async {
  if (!WindowClass.of(context).usesDialogs) {
    GoRouter.of(context).push('/preferences');
    return;
  }
  await showPreferencesDialog(context);
}

/// The dialog on its own, for the route and for the entry points from 600 up.
Future<void> showPreferencesDialog(BuildContext context) => showDialog<void>(
  context: context,
  useRootNavigator: true,
  barrierDismissible: true,
  barrierColor: const Color(0xB8040709),
  builder: (BuildContext context) => const PreferencesDialog(),
);

/// What `/preferences` renders.
///
/// Below 600 the pushed screen. From 600 the default page with the dialog over
/// it, which is what a link straight to the route should look like: the
/// preferences are a layer, never a window of their own.
class PreferencesRoute extends StatelessWidget {
  const PreferencesRoute({super.key});

  @override
  Widget build(BuildContext context) {
    if (!WindowClass.of(context).usesDialogs) return const PreferencesScreen();
    return const _DialogOverDefaultPage();
  }
}

class _DialogOverDefaultPage extends StatefulWidget {
  const _DialogOverDefaultPage();

  @override
  State<_DialogOverDefaultPage> createState() => _DialogOverDefaultPageState();
}

class _DialogOverDefaultPageState extends State<_DialogOverDefaultPage> {
  bool _opened = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opened) return;
    _opened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showPreferencesDialog(context);
      // Closing the dialog leaves the route, so the URL stops saying
      // preferences are open when they are not.
      if (mounted) GoRouter.of(context).go('/');
    });
  }

  // The default page: the Servers list below 1100, the fleet above it.
  @override
  Widget build(BuildContext context) => const ServersScreen();
}

// ------------------------------------------------------------- phone screen

/// The `AppSettings` board: one scrolling screen, sections in its order.
class PreferencesScreen extends ConsumerWidget {
  const PreferencesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool hasBiometrics =
        ref.watch(biometricsAvailableProvider).valueOrNull ?? false;
    return PushedPage(
      gap: 14,
      children: <Widget>[
        BackLink(
          'Servers',
          onTap: () {
            final NavigatorState navigator = Navigator.of(context);
            if (navigator.canPop()) {
              navigator.pop();
            } else {
              GoRouter.of(context).go('/');
            }
          },
        ),
        const ScreenHeader(
          title: 'Preferences',
          subtitle: 'For this app on this phone, across every server',
        ),
        const SectionHeader('Appearance'),
        const AppearanceSection(),
        // Hidden outright where the device cannot run the prompt: an app lock
        // nobody can pass is a locked-out phone.
        if (hasBiometrics) ...<Widget>[
          const SectionHeader('Security'),
          const SecuritySection(),
        ],
        const SectionHeader('Live data'),
        const LiveDataSection(),
        const SectionHeader('General'),
        const GeneralSection(),
        const SectionHeader('Edition'),
        const EditionCard(),
        const AboutSection(),
      ],
    );
  }
}

// ------------------------------------------------------------------ dialog

/// D7: 680×520, section list on the left, the chosen section on the right.
class PreferencesDialog extends ConsumerWidget {
  const PreferencesDialog({super.key});

  static const double width = 680;
  static const double height = 520;
  static const double navWidth = 200;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final Size window = MediaQuery.sizeOf(context);
    final bool hasBiometrics =
        ref.watch(biometricsAvailableProvider).valueOrNull ?? false;
    PreferenceSection section = ref.watch(_sectionProvider);
    if (!hasBiometrics && section == PreferenceSection.security) {
      section = PreferenceSection.appearance;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context).maybePop(),
          },
          child: Focus(
            autofocus: true,
            child: Material(
              color: t.surface,
              borderRadius: BorderRadius.circular(AppShape.card),
              child: Container(
                width: width.clamp(320.0, window.width - 48),
                height: height.clamp(320.0, window.height - 48),
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(AppShape.card),
                  border: Border.all(color: t.strongBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _SectionList(
                      selected: section,
                      hasBiometrics: hasBiometrics,
                      onSelected: (PreferenceSection next) =>
                          ref.read(_sectionProvider.notifier).state = next,
                    ),
                    Expanded(child: _SectionPane(section: section)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionList extends StatelessWidget {
  const _SectionList({
    required this.selected,
    required this.hasBiometrics,
    required this.onSelected,
  });

  final PreferenceSection selected;
  final bool hasBiometrics;
  final ValueChanged<PreferenceSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      width: PreferencesDialog.navWidth,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
      decoration: BoxDecoration(
        color: t.tabBar,
        border: Border(right: BorderSide(color: t.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            child: Text(
              'Preferences',
              style: TextStyle(
                fontFamily: AppFonts.display,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: t.text,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              primary: false,
              padding: EdgeInsets.zero,
              children: <Widget>[
                for (final PreferenceSection s in PreferenceSection.values)
                  if (hasBiometrics || s != PreferenceSection.security)
                    _SectionRow(
                      section: s,
                      selected: s == selected,
                      onTap: () => onSelected(s),
                    ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    'Opens with ',
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tiny.copyWith(color: t.mutedText),
                  ),
                ),
                CommandKeyLabel(
                  letter: ',',
                  style: AppText.tiny.copyWith(color: t.mutedText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionRow extends StatefulWidget {
  const _SectionRow({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final PreferenceSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SectionRow> createState() => _SectionRowState();
}

class _SectionRowState extends State<_SectionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color foreground = widget.selected ? t.accent : t.codeText;
    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: widget.selected
                    ? t.iconButtonFill
                    : (_hover ? t.surface : null),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  StrokeIcon(widget.section.glyph, size: 16, color: foreground),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.section.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The right-hand half: a title with the close button, then the section.
class _SectionPane extends StatelessWidget {
  const _SectionPane({required this.section});

  final PreferenceSection section;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 24, 26, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  section.label,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
              ),
              DoomIconButton(
                glyph: StrokeGlyph.close,
                semanticLabel: 'Close preferences',
                size: 32,
                radius: 10,
                filled: false,
                foreground: t.mutedText,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  switch (section) {
                    PreferenceSection.appearance => const AppearanceSection(
                      bare: true,
                    ),
                    PreferenceSection.security => const SecuritySection(
                      bare: true,
                    ),
                    PreferenceSection.liveData => const LiveDataSection(
                      bare: true,
                    ),
                    PreferenceSection.general => const GeneralSection(
                      bare: true,
                    ),
                    PreferenceSection.about => const Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        EditionCard(),
                        SizedBox(height: 14),
                        AboutSection(),
                      ],
                    ),
                  },
                ],
              ),
            ),
          ),
          if (section == PreferenceSection.appearance) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              'Preferences apply to this app on $_deviceName, across every '
              'server. Settings of one server, such as alert rules and paired '
              'devices, are under that server in the sidebar.',
              style: AppText.tiny.copyWith(color: t.mutedText, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- sections

/// A labelled control with an optional explanation under it.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child, this.hint});

  final String label;
  final Widget child;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: AppText.label.copyWith(
            color: t.text,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        child,
        if (hint != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            hint!,
            style: AppText.tiny.copyWith(color: t.mutedText, height: 1.4),
          ),
        ],
      ],
    );
  }
}

/// The phone wraps each section in a card; the dialog already has one.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.bare, required this.children});

  final bool bare;
  final List<Widget> children;

  /// The gap the board leaves between two fields inside one card.
  static const double gap = 16;

  @override
  Widget build(BuildContext context) {
    final List<Widget> spaced = <Widget>[
      for (int i = 0; i < children.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(height: gap),
        children[i],
      ],
    ];
    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: spaced,
    );
    if (bare) return column;
    return DoomCard(child: column);
  }
}

class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key, this.bare = false});

  final bool bare;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Preferences prefs = ref.watch(preferencesProvider);
    final PreferencesController controller = ref.read(
      preferencesProvider.notifier,
    );
    return _SectionCard(
      bare: bare,
      children: <Widget>[
        _Field(
          label: 'Theme',
          hint: bare ? 'System follows $_osName and switches with it.' : null,
          child: SegmentedControl(
            semanticLabel: 'Theme',
            labels: const <String>['System', 'Light', 'Dark'],
            index: ThemeMode.values.indexOf(prefs.themeMode),
            onChanged: (int i) => controller.setThemeMode(ThemeMode.values[i]),
          ),
        ),
        _Field(
          label: 'Density',
          hint:
              'Automatic is compact with a mouse or trackpad and comfortable '
              'with touch.',
          child: SegmentedControl(
            semanticLabel: 'Density',
            labels: <String>[
              for (final DensityMode m in DensityMode.values) m.label,
            ],
            index: DensityMode.values.indexOf(prefs.density),
            onChanged: (int i) => controller.setDensity(DensityMode.values[i]),
          ),
        ),
      ],
    );
  }
}

class SecuritySection extends ConsumerWidget {
  const SecuritySection({super.key, this.bare = false});

  final bool bare;

  /// Turning the lock **on** has to pass the prompt first, so nobody can put a
  /// lock on the app that they cannot open.
  Future<void> _toggle(BuildContext context, WidgetRef ref, bool value) async {
    final PreferencesController controller = ref.read(
      preferencesProvider.notifier,
    );
    if (!value) {
      await controller.setAppLock(false);
      return;
    }
    final bool ok = await ref
        .read(authenticatorProvider)
        .confirm('Turn on the Doomsaday app lock');
    if (!ok) {
      if (context.mounted) {
        notify(
          context,
          'The app lock stays off until $lockMethodLabel works here',
          danger: true,
        );
      }
      return;
    }
    await controller.setAppLock(true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool on = ref.watch(
      preferencesProvider.select((Preferences p) => p.appLock),
    );
    final Widget row = SwitchRow(
      label: lockSettingLabel,
      description: 'Asked when the app opens and after 5 min in the background',
      value: on,
      onChanged: (bool value) => _toggle(context, ref, value),
    );
    if (bare) return row;
    return RowGroup(children: <Widget>[row]);
  }
}

class LiveDataSection extends ConsumerWidget {
  const LiveDataSection({super.key, this.bare = false});

  final bool bare;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Preferences prefs = ref.watch(preferencesProvider);
    final PreferencesController controller = ref.read(
      preferencesProvider.notifier,
    );
    return _SectionCard(
      bare: bare,
      children: <Widget>[
        _Field(
          label: 'Refresh stats every',
          child: SegmentedControl(
            semanticLabel: 'Refresh stats every',
            labels: <String>[
              for (final StatsInterval i in StatsInterval.ordered) i.label,
            ],
            index: StatsInterval.ordered.indexOf(prefs.statsInterval),
            onChanged: (int i) =>
                controller.setStatsInterval(StatsInterval.ordered[i]),
          ),
        ),
        _Field(
          label: 'Log lines kept per stream',
          hint:
              'Older lines are dropped from memory. The server keeps its own '
              'logs.',
          child: SegmentedControl(
            semanticLabel: 'Log lines kept per stream',
            labels: <String>[
              for (final LogBuffer b in LogBuffer.ordered) b.label,
            ],
            index: LogBuffer.ordered.indexOf(prefs.logBuffer),
            onChanged: (int i) => controller.setLogBuffer(LogBuffer.ordered[i]),
          ),
        ),
      ],
    );
  }
}

class GeneralSection extends ConsumerWidget {
  const GeneralSection({super.key, this.bare = false});

  final bool bare;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Preferences prefs = ref.watch(preferencesProvider);
    final PreferencesController controller = ref.read(
      preferencesProvider.notifier,
    );
    final bool demo = ref.watch(demoModeProvider);
    return _SectionCard(
      bare: bare,
      children: <Widget>[
        _Field(
          label: 'Open the app on',
          child: SegmentedControl(
            semanticLabel: 'Open the app on',
            labels: <String>[
              for (final StartScreen s in StartScreen.values) s.label,
            ],
            index: StartScreen.values.indexOf(prefs.startScreen),
            onChanged: (int i) =>
                controller.setStartScreen(StartScreen.values[i]),
          ),
        ),
        // The same switch as "Explore with demo data" and "Leave demo" on the
        // Servers screen, driven through the same controller so the two can
        // never disagree.
        SwitchRow(
          label: 'Demo data',
          description: 'Three sample servers to explore without pairing',
          value: demo,
          onChanged: (bool value) =>
              ref.read(demoModeProvider.notifier).set(value),
        ),
      ],
    );
  }
}

/// The edition card: what this build is, and the one door to Pro.
///
/// It asks the edition layer, never the flavor, so the day Pro becomes an
/// in-app unlock this card is already right.
class EditionCard extends ConsumerWidget {
  const EditionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final Edition edition = ref.watch(editionProvider);
    final int? limit = edition.maxServers;
    final int paired = ref.watch(serversRepositoryProvider).servers.length;
    return DoomCard(
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  edition.editionName,
                  style: AppText.cardTitle.copyWith(
                    color: t.text,
                    fontSize: 15,
                  ),
                ),
                if (limit != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    '$paired of $limit servers paired',
                    style: AppText.small.copyWith(color: t.mutedText),
                  ),
                ],
              ],
            ),
          ),
          if (!edition.isPro) ...<Widget>[
            const SizedBox(width: 12),
            _GetProButton(onPressed: () => openProUpgrade(context)),
          ],
        ],
      ),
    );
  }
}

/// "Get Pro" with the PRO badge inside it, as the board draws it.
class _GetProButton extends StatelessWidget {
  const _GetProButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      button: true,
      label: 'Get Pro',
      child: Material(
        color: t.accent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Get Pro',
                  style: AppText.buttonLabel.copyWith(color: t.onAccent),
                ),
                const SizedBox(width: 8),
                const ProBadge(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AboutSection extends ConsumerWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Edition edition = ref.watch(editionProvider);
    final String version =
        ref.watch(appVersionProvider).valueOrNull ?? kFallbackVersion;
    return RowGroup(
      children: <Widget>[
        DetailRow(
          'Version',
          '$version · agent API $kAgentApiVersion',
          mono: true,
        ),
        NavRow(
          label: 'Open-source licences',
          onTap: () => showLicensePage(
            context: context,
            useRootNavigator: true,
            applicationName: edition.displayName,
            applicationVersion: version,
          ),
        ),
      ],
    );
  }
}
