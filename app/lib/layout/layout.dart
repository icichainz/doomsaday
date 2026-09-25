/// One place for the breakpoints and the two densities the app draws at.
///
/// Everything adapts by **window width**, never by platform: a narrow window on
/// a Mac is the phone layout, and a wide Android tablet gets the rail. The
/// numbers come from the "Desktop and tablet (adaptive layout)" section of
/// `design/README.md`.
library;

import 'package:flutter/widgets.dart';

import '../data/preferences.dart' show DensityMode;

/// The three layouts the app has.
enum WindowClass {
  /// Under 600: the phone design, unchanged — bottom bar, pushed screens,
  /// bottom sheets, 44 px touch targets.
  compact,

  /// 600 to 1099: the 92 px icon-and-label rail (T1), one capped column,
  /// 2×2 stat cards, sheets become centred dialogs.
  medium,

  /// 1100 and up: the 264 px sidebar (D1), split views, tables, desktop extras.
  expanded;

  static const double mediumWidth = 600;
  static const double expandedWidth = 1100;

  static WindowClass fromWidth(double width) {
    if (width >= expandedWidth) return WindowClass.expanded;
    if (width >= mediumWidth) return WindowClass.medium;
    return WindowClass.compact;
  }

  /// Reads the live window width, so a resize rebuilds whatever depends on it.
  static WindowClass of(BuildContext context) =>
      fromWidth(MediaQuery.sizeOf(context).width);

  bool get isCompact => this == WindowClass.compact;
  bool get isMedium => this == WindowClass.medium;
  bool get isExpanded => this == WindowClass.expanded;

  /// The phone's bottom bar is the navigation only in the compact class.
  bool get usesBottomBar => this == WindowClass.compact;
  bool get usesRail => this == WindowClass.medium;
  bool get usesSidebar => this == WindowClass.expanded;

  /// Bottom sheets become centred dialogs from 600 up.
  bool get usesDialogs => this != WindowClass.compact;

  /// Split views, tables, the fleet, the log wall and the jump palette.
  bool get usesDesktopExtras => this == WindowClass.expanded;
}

/// Sizes that change between the touch layout and the pointer layout.
///
/// `design/README.md`: "Compact density with a pointer: rows 44 to 52 px,
/// buttons 36 px, icon buttons 32 to 36 px. Touch sizes (44 px minimum) stay
/// below 1100."
@immutable
class Density {
  const Density._({
    required this.compact,
    required this.row,
    required this.button,
    required this.iconButton,
    required this.chip,
    required this.field,
    required this.segment,
    required this.inlineLink,
    required this.gutter,
  });

  /// The pointer layout, used from 1100 up.
  static const Density pointer = Density._(
    compact: true,
    row: 46,
    button: 36,
    iconButton: 36,
    chip: 32,
    field: 36,
    segment: 30,
    inlineLink: 28,
    gutter: 32,
  );

  /// The touch layout, used below 1100.
  static const Density touch = Density._(
    compact: false,
    row: 66,
    button: 48,
    iconButton: 48,
    chip: 44,
    field: 44,
    segment: 44,
    inlineLink: 44,
    gutter: 20,
  );

  /// Compact asked for below 600, where there is no pointer to make a small
  /// target safe. Rows and cards tighten, but nothing you tap drops under the
  /// design's 44 px minimum, and the side padding stays the phone's 20.
  static const Density compactTouch = Density._(
    compact: true,
    row: 46,
    button: 44,
    iconButton: 44,
    chip: 44,
    field: 44,
    segment: 44,
    inlineLink: 44,
    gutter: 20,
  );

  static Density forClass(WindowClass windowClass) =>
      windowClass.isExpanded ? pointer : touch;

  /// The one density rule in the app.
  ///
  /// `Automatic` is what the app has always done — the pointer layout at 1100
  /// and up, touch below. `Comfortable` and `Compact` force one at every
  /// width, except that Compact keeps 44 px hit targets below 600.
  static Density resolve(DensityMode mode, double width) => switch (mode) {
    DensityMode.automatic => forClass(WindowClass.fromWidth(width)),
    DensityMode.comfortable => touch,
    DensityMode.compact =>
      width < WindowClass.mediumWidth ? compactTouch : pointer,
  };

  static Density of(BuildContext context) =>
      resolve(DensityScope.of(context), MediaQuery.sizeOf(context).width);

  /// True when the tighter pointer layout is in force. It no longer means
  /// "targets may shrink below 44": ask [button], [segment] or [inlineLink]
  /// for a height, because below 600 the floor still applies.
  final bool compact;

  /// A list or table row.
  final double row;
  final double button;
  final double iconButton;
  final double chip;
  final double field;

  /// One cell of a segmented control.
  final double segment;

  /// A text link sitting on a section header, such as "All alerts".
  final double inlineLink;

  /// Screen side padding.
  final double gutter;

  /// The buttons on a card (stacks, services, alerts, registries): 36 px with
  /// a pointer, the phone board's 44 everywhere else.
  double get cardButton => button < 44 ? button : 44;

  /// The corner radius that goes with [cardButton].
  double get cardButtonRadius => button < 44 ? 10 : 12;
}

/// Publishes the chosen [DensityMode] to the whole tree.
///
/// The app installs one above the chrome, so every widget picks the density up
/// through the single `Density.of` lookup and nothing has to be told twice.
/// Without one the app behaves exactly as it did: [DensityMode.automatic].
class DensityScope extends InheritedWidget {
  const DensityScope({super.key, required this.mode, required super.child});

  final DensityMode mode;

  static DensityMode of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DensityScope>()?.mode ??
      DensityMode.automatic;

  @override
  bool updateShouldNotify(DensityScope oldWidget) => oldWidget.mode != mode;
}

/// Widths the shell itself draws at.
abstract final class ShellMetrics {
  /// T1: the tablet rail.
  static const double railWidth = 92;
  static const double railItemWidth = 72;
  static const double railItemHeight = 60;

  /// D1: the desktop sidebar.
  static const double sidebarWidth = 264;
  static const double sidebarRowHeight = 38;

  /// D2: the container list pane.
  static const double listPaneWidth = 400;

  /// The single column the medium class centres its content in.
  static const double readableWidth = 720;

  /// T1's page padding on the tablet, against the phone's 20.
  static const double tabletGutter = 28;

  /// The tablet list rows (TabletContainers): between the phone's 66 and
  /// the desktop's 46, and still above the 44 px touch minimum.
  static const double tabletRow = 52;

  /// D3: the confirm dialog.
  static const double dialogWidth = 500;
}

/// `context.windowClass`, `context.density` instead of two long lookups.
extension LayoutContext on BuildContext {
  WindowClass get windowClass => WindowClass.of(this);

  Density get density => Density.of(this);
}
