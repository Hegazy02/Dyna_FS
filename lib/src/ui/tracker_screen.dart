import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../config/app_config.dart';
import '../models/auth_session.dart';
import '../models/http_exchange.dart';
import '../models/tracker_status.dart';
import '../permissions/permission_gate.dart';
import '../service/companion_app.dart';
import '../service/tracking_service.dart';

/// The app's only screen.
///
/// Blank by design: there is nothing for the user to do here, and a tracker
/// that shows a live map invites people to sit and watch it, which costs
/// battery for no benefit. The screen only speaks up when something is
/// actually blocking tracking, and hides a diagnostics panel behind seven taps
/// so a device can be debugged in the field without a laptop.
class TrackerScreen extends StatefulWidget {
  const TrackerScreen({
    super.key,
    required this.session,
    required this.onSignOut,
    required this.onSessionRejected,
    this.handoffRequest = 0,
  });

  final AuthSession session;
  final Future<void> Function() onSignOut;

  /// Increments each time the gate wants the user handed to the companion PWA
  /// — after a sign-in, or when the PWA itself asks for a session. Each new
  /// value is served once, so a resume from the PWA cannot bounce the rep
  /// straight back out of the tracker.
  final int handoffRequest;

  /// Invoked when the background service reports that the server refused the
  /// token, so the gate can send the user back to the login screen.
  final VoidCallback onSessionRejected;

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen>
    with WidgetsBindingObserver {
  TrackingReadiness? _readiness;
  TrackerStatus? _status;
  bool _serviceRunning = false;
  bool _busy = false;

  int _tapCount = 0;
  DateTime? _firstTapAt;

  /// The highest [TrackerScreen.handoffRequest] already acted on.
  int _servedHandoff = 0;

  /// Set when a launch found no installed app, so the screen can explain
  /// instead of leaving the rep wondering why nothing happened. Only ever set
  /// from an actual attempt — there is no way to ask Android whether the PWA
  /// is installed without trying to open it.
  bool _companionMissing = false;

  /// What the last launch attempt did, for the diagnostics panel. "The PWA
  /// asked me to sign in again" is otherwise impossible to place: it could be
  /// this app not sending the session, or the PWA not reading it, and from a
  /// phone in the field there is no way to tell those apart.
  CompanionLaunch? _lastLaunch;
  DateTime? _lastLaunchAt;
  bool _lastLaunchCarriedSession = false;

  /// Open from the start in debug builds, so a test APK shows what it is
  /// sending without anyone having to know about the seven-tap gesture.
  bool _showDiagnostics = AppConfig.showDebugPanel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(TrackerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The PWA asked for a session while this screen was already up — the
    // common case, since the tracker is usually running when it calls in.
    // A cold start is handled at the end of _bootstrap instead.
    if (widget.handoffRequest != oldWidget.handoffRequest) {
      unawaited(_serveHandoff());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have just returned from the settings screen, having granted
    // "Allow all the time" or re-enabled location. Re-check without prompting.
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  void _onTaskData(Object data) {
    final status = TrackerStatus.tryParse(data);
    if (status == null || !mounted) return;

    setState(() => _status = status);

    // The service just found out the token is dead. Hand control back to the
    // gate so the user gets the login screen instead of a white screen that
    // silently stopped uploading.
    if (status.reauthRequired) widget.onSessionRejected();
  }

  Future<void> _bootstrap() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final readiness = await PermissionGate.request();
      if (!mounted) return;
      setState(() => _readiness = readiness);

      if (_canTrack(readiness)) {
        await PermissionGate.ensureBatteryExemption();
        final running = await TrackingService.start();
        if (!mounted) return;
        setState(() => _serviceRunning = running);
        TrackingService.requestStatus();

        // Last, on purpose. Opening the PWA sends this app to the background,
        // and doing that mid-permission-flow would bury the system dialogs the
        // user still has to answer.
        await _serveHandoff();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Serves a pending hand-off request, at most once per request.
  ///
  /// Blocked permissions skip it: the rep needs to read the notice on this
  /// screen, not have it hidden behind a browser window. The request stays
  /// unserved in that case rather than being consumed, so granting the
  /// permission and coming back still works.
  Future<void> _serveHandoff() async {
    if (widget.handoffRequest <= _servedHandoff) return;
    if (!CompanionApp.isConfigured) return;

    final TrackingReadiness? readiness = _readiness;
    if (readiness == null || !_canTrack(readiness)) return;

    _servedHandoff = widget.handoffRequest;
    await _openCompanion();
  }

  /// Opens the companion app, and stays put to explain if it is not there.
  ///
  /// No silent browser fallback: a rep dropped into a signed-out browser tab
  /// with no explanation has no way to work out that they were supposed to
  /// install something.
  Future<void> _openCompanion() async {
    final bool carriedSession = !widget.session.isExpired;
    final CompanionLaunch result =
        await CompanionApp.open(session: widget.session);
    if (!mounted) return;

    setState(() {
      _companionMissing = result != CompanionLaunch.openedApp;
      _lastLaunch = result;
      _lastLaunchAt = DateTime.now();
      _lastLaunchCarriedSession = carriedSession;
    });

    if (result == CompanionLaunch.unavailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open DynaOps365.')),
      );
    }
  }

  /// The deliberate fallback, offered on the install notice rather than taken
  /// automatically. Carries no session: see [CompanionApp.open].
  Future<void> _openCompanionInBrowser() async {
    await CompanionApp.open(allowBrowser: true);
  }

  Future<void> _copyCompanionUrl() async {
    await Clipboard.setData(
      ClipboardData(text: CompanionApp.uri?.toString() ?? ''),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied.')),
    );
  }

  /// Silent re-check used on resume.
  Future<void> _refresh() async {
    final readiness = await PermissionGate.check();
    final running = await TrackingService.isRunning;
    if (!mounted) return;

    setState(() {
      _readiness = readiness;
      _serviceRunning = running;
    });

    if (_canTrack(readiness) && !running) {
      final started = await TrackingService.start();
      if (mounted) setState(() => _serviceRunning = started);
    }
    if (running) TrackingService.requestStatus();
  }

  static bool _canTrack(TrackingReadiness readiness) =>
      readiness == TrackingReadiness.ready ||
      readiness == TrackingReadiness.foregroundOnly;

  void _registerDiagnosticsTap() {
    final now = DateTime.now();
    final first = _firstTapAt;
    if (first == null || now.difference(first) > const Duration(seconds: 3)) {
      _firstTapAt = now;
      _tapCount = 1;
      return;
    }

    _tapCount++;
    if (_tapCount >= 7) {
      _tapCount = 0;
      _firstTapAt = null;
      setState(() => _showDiagnostics = !_showDiagnostics);
      if (_showDiagnostics) TrackingService.requestStatus();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Intercepts the back button so the service is not torn down by a stray
    // back press; the app minimises instead.
    return WithForegroundTask(
      child: Scaffold(
        backgroundColor: Colors.white,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _registerDiagnosticsTap,
          child: SafeArea(child: _body()),
        ),
      ),
    );
  }

  Widget _body() {
    if (_showDiagnostics) {
      return _DiagnosticsPanel(
        status: _status,
        readiness: _readiness,
        serviceRunning: _serviceRunning,
        session: widget.session,
        lastLaunch: _lastLaunch,
        lastLaunchAt: _lastLaunchAt,
        lastLaunchCarriedSession: _lastLaunchCarriedSession,
        onOpenCompanion: _openCompanion,
        onSignOut: widget.onSignOut,
        onClose: () => setState(() => _showDiagnostics = false),
      );
    }

    final readiness = _readiness;
    if (readiness != null && !_canTrack(readiness)) {
      return _BlockedNotice(readiness: readiness, onRetry: _bootstrap);
    }

    if (readiness == TrackingReadiness.foregroundOnly) {
      return _BackgroundUpgradeNotice(onOpenSettings: PermissionGate.openAppSettings);
    }

    // Everything is working. Two things earn their place on an otherwise idle
    // screen: the way back into the companion app, and the way to stop. Ending
    // a shift used to mean finding a sign-out buried behind seven taps, which
    // is no way to offer the one control that stops location sharing.
    if (_companionMissing) {
      return _InstallCompanionNotice(
        url: CompanionApp.uri?.toString() ?? '',
        onRetry: _openCompanion,
        onOpenBrowser: _openCompanionInBrowser,
        onCopyUrl: _copyCompanionUrl,
        onSignOut: _confirmSignOut,
      );
    }

    return _IdleScreen(
      showOpenCompanion: CompanionApp.isConfigured,
      onOpenCompanion: _openCompanion,
      onSignOut: _confirmSignOut,
    );
  }

  /// Sign-out stops tracking for the rest of the shift, so it asks first. The
  /// copy names the consequence rather than the action: "sign out" reads as
  /// housekeeping, "stop sharing your location" is what actually happens.
  Future<void> _confirmSignOut() async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Sign out?'),
            content: const Text(
              'This stops sharing your location and signs you out of '
              'DynaOps365 on this device.\n\n'
              'Anything not yet uploaded is kept and will be sent when you '
              'sign in again.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFB3261E),
                ),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ) ??
        false;

    if (confirmed) await widget.onSignOut();
  }
}

/// Shown after a launch found no installed companion app.
///
/// Three causes produce that result and none of them can be told apart from
/// here — not installed, saved as a home-screen shortcut instead of installed,
/// or "Open supported links" turned off — so the notice covers all three
/// rather than guessing. Tracking is unaffected throughout: this screen is
/// about the rep's other app, not about whether their location is reporting.
class _InstallCompanionNotice extends StatelessWidget {
  const _InstallCompanionNotice({
    required this.url,
    required this.onRetry,
    required this.onOpenBrowser,
    required this.onCopyUrl,
    required this.onSignOut,
  });

  final String url;
  final Future<void> Function() onRetry;
  final Future<void> Function() onOpenBrowser;
  final Future<void> Function() onCopyUrl;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Icon(
            Icons.install_mobile_outlined,
            size: 40,
            color: Color(0xFF0A84FF),
          ),
          const SizedBox(height: 16),
          const Text(
            'DynaOps365 is not installed',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1C1C1E),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Your location is still being shared — only the app that shows '
            'your work is missing.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: Color(0xFF3C3C43),
            ),
          ),
          const SizedBox(height: 22),
          const _Step(
            number: '1',
            text: 'Open the link below in Chrome.',
          ),
          const _Step(
            number: '2',
            text: 'Tap the ⋮ menu, then "Install app".',
          ),
          const _Step(
            number: '3',
            text: 'Come back here and tap Try again.',
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F7),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              url,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: Color(0xFF1C1C1E),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  onPressed: () => onOpenBrowser(),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                  ),
                  child: const Text('Open in browser'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onCopyUrl(),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                  ),
                  child: const Text('Copy link'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text(
            'Already installed it? Android may be sending the link to the '
            'browser instead. Open Settings → Apps → DynaOps365 → Open by '
            'default, and turn on "Open supported links".',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xFF8A8A8E),
            ),
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: () => onRetry(),
            style: TextButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            child: const Text('Try again'),
          ),
          TextButton(
            onPressed: () => onSignOut(),
            style: TextButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              foregroundColor: const Color(0xFFB3261E),
            ),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFFE8F0FE),
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF0A84FF),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                height: 1.4,
                color: Color(0xFF3C3C43),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the rep sees when tracking is healthy: confirmation that it is on, the
/// way back into the companion app, and the way to stop.
class _IdleScreen extends StatelessWidget {
  const _IdleScreen({
    required this.showOpenCompanion,
    required this.onOpenCompanion,
    required this.onSignOut,
  });

  final bool showOpenCompanion;
  final Future<void> Function() onOpenCompanion;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.check_circle_outline,
              size: 40,
              color: Color(0xFF1B7F3B),
            ),
            const SizedBox(height: 16),
            const Text(
              'Location sharing is on.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                height: 1.5,
                color: Color(0xFF3C3C43),
              ),
            ),
            if (showOpenCompanion) ...<Widget>[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => onOpenCompanion(),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open app'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(200, 48),
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => onSignOut(),
              style: TextButton.styleFrom(
                minimumSize: const Size(200, 44),
                foregroundColor: const Color(0xFFB3261E),
              ),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when tracking cannot run at all.
class _BlockedNotice extends StatelessWidget {
  const _BlockedNotice({required this.readiness, required this.onRetry});

  final TrackingReadiness readiness;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (String message, String action, Future<void> Function() onPressed) =
        switch (readiness) {
      TrackingReadiness.locationServiceDisabled => (
          'Location is turned off on this device.',
          'Open location settings',
          PermissionGate.openLocationSettings,
        ),
      TrackingReadiness.permanentlyDenied => (
          'Location permission is blocked. Enable it in app settings, then '
              'choose "Allow all the time".',
          'Open app settings',
          PermissionGate.openAppSettings,
        ),
      _ => (
          'This app needs location permission to work.',
          'Grant permission',
          () async => onRetry(),
        ),
    };

    return _CenteredPrompt(
      message: message,
      actionLabel: action,
      onPressed: onPressed,
    );
  }
}

/// Shown when only foreground location was granted.
class _BackgroundUpgradeNotice extends StatelessWidget {
  const _BackgroundUpgradeNotice({required this.onOpenSettings});

  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return _CenteredPrompt(
      message: 'Tracking is running, but will stop when the phone restarts.\n\n'
          'To keep it reliable, set Location to "Allow all the time".',
      actionLabel: 'Open app settings',
      onPressed: onOpenSettings,
    );
  }
}

class _CenteredPrompt extends StatelessWidget {
  const _CenteredPrompt({
    required this.message,
    required this.actionLabel,
    required this.onPressed,
  });

  final String message;
  final String actionLabel;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
                color: Color(0xFF3C3C43),
              ),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => onPressed(),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hidden behind seven taps. Lets you confirm a field device is reporting
/// without attaching a debugger.
class _DiagnosticsPanel extends StatelessWidget {
  const _DiagnosticsPanel({
    required this.status,
    required this.readiness,
    required this.serviceRunning,
    required this.session,
    required this.lastLaunch,
    required this.lastLaunchAt,
    required this.lastLaunchCarriedSession,
    required this.onOpenCompanion,
    required this.onSignOut,
    required this.onClose,
  });

  final TrackerStatus? status;
  final TrackingReadiness? readiness;
  final bool serviceRunning;
  final CompanionLaunch? lastLaunch;
  final DateTime? lastLaunchAt;
  final bool lastLaunchCarriedSession;
  final Future<void> Function() onOpenCompanion;
  final AuthSession session;
  final Future<void> Function() onSignOut;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final s = status;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              const Text(
                'Diagnostics',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: <Widget>[
                _row('Service', serviceRunning ? 'running' : 'stopped'),
                _row('Permission', readiness?.name ?? 'unknown'),
                _row('Endpoint set', s?.configured == true ? 'yes' : 'NO'),
                _row('Location stream', s?.streaming == true ? 'live' : 'down'),
                _row('Durable queue', s?.durableQueue == true ? 'yes' : 'memory only'),
                _row('Queued', '${s?.pending ?? '-'}'),
                _row('Delivered', '${s?.delivered ?? '-'}'),
                _row('Discarded', '${s?.discarded ?? '-'}'),
                _row('Last fix', _fmt(s?.lastFixAt)),
                _row('Last upload', _fmt(s?.lastDeliveryAt)),
                _row(
                  'Last position',
                  s?.lastLat == null
                      ? '-'
                      : '${s!.lastLat!.toStringAsFixed(5)}, '
                          '${s.lastLng!.toStringAsFixed(5)}',
                ),
                _row('Signed in as', session.fullName ?? session.username ?? '-'),
                _row('User ID', session.userId),
                if (session.salesmanId != null)
                  _row('Salesman ID', session.salesmanId!),
                if (session.role != null) _row('Role', session.role!),
                _row('Token expires', _fmt(session.expireAt)),
                const SizedBox(height: 12),
                const Text(
                  'Companion app',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                _row('URL', CompanionApp.uri?.toString() ?? 'not configured'),
                _row(
                  'Last launch',
                  lastLaunch == null
                      ? 'not attempted yet'
                      : '${lastLaunch!.name}  ${_fmt(lastLaunchAt)}',
                ),
                // The question this panel exists to answer: did the session
                // actually leave this app? If it says "sent" and the PWA still
                // shows its login page, the fault is on the PWA side — an old
                // bundle cached by its service worker, or a deploy that never
                // ran — and no amount of poking at the tracker will move it.
                _row(
                  'Session sent',
                  lastLaunch == null
                      ? '-'
                      : (lastLaunchCarriedSession &&
                              lastLaunch == CompanionLaunch.openedApp
                          ? 'sent, in #handoff fragment'
                          : lastLaunchCarriedSession
                              ? 'not sent — no installed app took the link'
                              : 'not sent — session expired'),
                ),
                if (s?.lastError != null) _row('Last error', s!.lastError!),
                const SizedBox(height: 20),
                const Text(
                  'Requests',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                if (s == null || s.exchanges.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No upload attempted yet. The first one goes out within '
                      '30 seconds of the service starting.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF8A8A8E)),
                    ),
                  )
                else
                  for (final exchange in s.exchanges)
                    _ExchangeCard(exchange: exchange),
              ],
            ),
          ),
          Row(
            children: <Widget>[
              TextButton(
                onPressed: TrackingService.requestFlush,
                child: const Text('Send now'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => onOpenCompanion(),
                child: const Text('Open app'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: session.userId),
                ),
                child: const Text('Copy user ID'),
              ),
              const Spacer(),
              TextButton(
                onPressed: onSignOut,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFB3261E),
                ),
                child: const Text('Sign out'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(DateTime? value) =>
      value == null ? '-' : value.toLocal().toString().split('.').first;

  static Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF8A8A8E)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: Color(0xFF1C1C1E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One upload attempt: what went out, and what came back.
class _ExchangeCard extends StatefulWidget {
  const _ExchangeCard({required this.exchange});

  final HttpExchange exchange;

  @override
  State<_ExchangeCard> createState() => _ExchangeCardState();
}

class _ExchangeCardState extends State<_ExchangeCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.exchange;
    final ok = e.succeeded;
    final failed = e.error != null || (e.statusCode != null && !ok);

    final Color accent = ok
        ? const Color(0xFF1B7F3B)
        : (failed ? const Color(0xFFB3261E) : const Color(0xFF8A8A8E));

    final String verdict = e.error != null
        ? 'failed'
        : (e.statusCode?.toString() ?? '-');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE3E3E8)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      verdict,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${_clockTime(e.at)}  ·  '
                      '${e.pingCount} ping${e.pingCount == 1 ? '' : 's'}  ·  '
                      '${e.durationMs} ms',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF3C3C43),
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: const Color(0xFF8A8A8E),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _label('POST'),
                  _code(e.url),
                  if (e.authPreview != null) ...<Widget>[
                    _label('Authorization'),
                    _code('Bearer ${e.authPreview}'),
                  ],
                  _label('Request body'),
                  _code(e.requestBody),
                  if (e.responseBody != null) ...<Widget>[
                    _label('Response'),
                    _code(
                      e.responseBody!.isEmpty
                          ? '(empty body)'
                          : e.responseBody!,
                    ),
                  ],
                  if (e.error != null) ...<Widget>[
                    _label('Error'),
                    _code(e.error!),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _clockTime(DateTime value) =>
      value.toLocal().toString().split(' ').last.split('.').first;

  static Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xFF8A8A8E),
          ),
        ),
      );

  /// Selectable so a payload can be copied off the phone and pasted into a bug
  /// report, which is most of the point of having this on screen.
  static Widget _code(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F7),
          borderRadius: BorderRadius.circular(6),
        ),
        child: SelectableText(
          text,
          style: const TextStyle(
            fontSize: 11,
            height: 1.4,
            fontFamily: 'monospace',
            color: Color(0xFF1C1C1E),
          ),
        ),
      );
}
