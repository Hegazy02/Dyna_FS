import 'dart:async';

import 'package:flutter/material.dart';

import '../data/auth_repository.dart';
import '../models/auth_session.dart';
import '../service/companion_app.dart';
import '../service/companion_link.dart';
import '../service/tracking_service.dart';
import 'login_screen.dart';
import 'tracker_screen.dart';

/// Decides whether the user sees the login screen or the tracker, and answers
/// the companion app when it calls in.
///
/// A cached session means the app goes straight to tracking — signing in is a
/// once-per-device event, not a daily ritual. The login screen only comes back
/// when there is no session, the token has expired, or the server refused it.
class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  final AuthRepository _auth = AuthRepository();
  final CompanionLink _link = CompanionLink();

  bool _loading = true;
  AuthSession? _session;
  String? _notice;
  String? _lastUsername;

  /// Bumped every time the user should be handed to the companion app: once
  /// after a real sign-in, and again whenever the PWA asks for a session. A
  /// counter rather than a flag because the same request can legitimately be
  /// made twice in one run of the app, and each one has to be served.
  int _handoffRequest = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  /// Restore the cached session first, *then* start listening.
  ///
  /// Order matters on a cold start. [CompanionLink.start] replays the link that
  /// launched the app, so a `dyngis://signout` can arrive while the restore is
  /// still in flight — and the cached session would land a moment later and
  /// sign the user straight back in. Sequencing them means the sign-out always
  /// acts on a settled state.
  Future<void> _open() async {
    await _restore();
    await _link.start(_onCompanionCall);
  }

  @override
  void dispose() {
    unawaited(_link.dispose());
    _auth.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final session = await _auth.load();
    final reauthRequired = await _auth.isReauthRequired();
    if (!mounted) return;

    String? notice;
    AuthSession? usable;

    if (session == null) {
      notice = null;
    } else if (session.isExpired) {
      notice = 'Your session has expired. Please sign in again.';
    } else if (reauthRequired) {
      notice = 'The server refused your saved sign-in. Please sign in again.';
    } else {
      usable = session;
    }

    setState(() {
      _session = usable;
      _notice = notice;
      _lastUsername = session?.username;
      _loading = false;
    });
  }

  /// The PWA calling in. See [CompanionRequest].
  void _onCompanionCall(CompanionCall call) {
    if (!mounted) return;

    switch (call.request) {
      case CompanionRequest.signIn:
        unawaited(_onSignInRequested(call.session));
      case CompanionRequest.signOut:
        // notifyCompanion: false — the PWA is the one that just told us.
        // Telling it back would bounce the rep between the two apps.
        unawaited(_signOut(
          notice: 'You signed out in DynaOps365.',
          notifyCompanion: false,
        ));
    }
  }

  /// Answers `dyngis://signin`.
  ///
  /// [incoming] is a session the PWA passed over, for the case where the rep
  /// signed in there: this app adopts it, takes the location permissions, and
  /// hands them straight back — one password, typed once, on whichever side
  /// they started.
  ///
  /// Without one, the request means "you already hold the credential, send it
  /// back". If this app has no session either, nothing happens on purpose: the
  /// login screen is already what the rep is looking at, and the hand-off
  /// follows the sign-in by itself.
  Future<void> _onSignInRequested(AuthSession? incoming) async {
    final AuthSession? current = _session;

    if (incoming != null && incoming.userId != current?.userId) {
      // A different person than this app is tracking — or the first person to
      // use it. Stop before switching: fixes already queued belong to the
      // previous rep and must not be uploaded under the new one's token.
      if (current != null) await TrackingService.stop();
      await _auth.save(incoming);
      if (!mounted) return;

      setState(() {
        _session = incoming;
        _notice = null;
        _lastUsername = incoming.username ?? _lastUsername;
        _handoffRequest++;
      });
      return;
    }

    if (current == null) return;
    setState(() => _handoffRequest++);
  }

  /// [notifyCompanion] passes the sign-out on to the PWA, so one sign-out means
  /// one sign-out. False only when the PWA is where it came from.
  Future<void> _signOut({String? notice, bool notifyCompanion = true}) async {
    // Stop reporting first, so nothing is captured without an owner. Anything
    // already queued stays on disk and uploads when this user signs back in.
    await TrackingService.stop();
    await _auth.clear();

    // After the local sign-out is done, never before: this hands the device to
    // another app, and the rep must be signed out here whether or not that
    // lands.
    if (notifyCompanion) await CompanionApp.signOut();

    if (!mounted) return;

    setState(() {
      _session = null;
      _notice = notice ?? 'You have been signed out.';
    });
  }

  void _onSignedIn(AuthSession session) {
    setState(() {
      _session = session;
      _notice = null;
      _lastUsername = session.username;
      _handoffRequest++;
    });
  }

  /// Called by the tracker when the running service reports a refused token.
  void _onSessionRejected() {
    if (_session == null) return;
    setState(() {
      _session = null;
      _notice = 'Your session has expired. Please sign in again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      // Blank while the cached session loads — a spinner here would flash for
      // a few milliseconds and look like a glitch.
      return const Scaffold(backgroundColor: Colors.white, body: SizedBox());
    }

    final session = _session;
    if (session == null) {
      return LoginScreen(
        initialUsername: _lastUsername,
        notice: _notice,
        onSignedIn: _onSignedIn,
      );
    }

    return TrackerScreen(
      session: session,
      handoffRequest: _handoffRequest,
      onSignOut: _signOut,
      onSessionRejected: _onSessionRejected,
    );
  }
}
