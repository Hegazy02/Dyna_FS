import 'dart:async';

import 'package:flutter/material.dart';

import '../data/auth_repository.dart';
import '../models/auth_session.dart';
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
    _restore();
    unawaited(_link.start(_onCompanionRequest));
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
  void _onCompanionRequest(CompanionRequest request) {
    if (!mounted) return;

    switch (request) {
      case CompanionRequest.signIn:
        // Only a usable session is worth acting on. Without one the login
        // screen is already what the rep is looking at, and the hand-off
        // happens on its own once they sign in.
        if (_session == null) return;
        setState(() => _handoffRequest++);
      case CompanionRequest.signOut:
        unawaited(_signOut(notice: 'You signed out in DynaOps365.'));
    }
  }

  Future<void> _signOut({String? notice}) async {
    // Stop reporting first, so nothing is captured without an owner. Anything
    // already queued stays on disk and uploads when this user signs back in.
    await TrackingService.stop();
    await _auth.clear();
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
