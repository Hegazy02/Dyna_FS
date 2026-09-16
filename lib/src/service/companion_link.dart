import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';

import '../models/auth_session.dart';

/// What the companion app is asking this one to do.
enum CompanionRequest {
  /// `dyngis://signin` — the rep wants tracking running without typing a
  /// password here.
  ///
  /// It comes in two shapes. Bare, it means "you already know who I am, hand
  /// a session back" — the rep started in the PWA, found it signed out, and
  /// this app is the one holding the credential. With `?handoff=<payload>` it
  /// means the opposite: the rep signed in over there, and the PWA is passing
  /// the session here so this app can take permissions and start reporting
  /// without a second login.
  signIn,

  /// `dyngis://signout` — the rep signed out over there. Stop reporting and
  /// clear the session here too, so one sign-out means one sign-out.
  signOut,
}

/// A parsed inbound link: what was asked, and the session that came with it.
class CompanionCall {
  const CompanionCall(this.request, {this.session});

  final CompanionRequest request;

  /// Present only on a `signIn` that carried a usable `handoff` payload.
  final AuthSession? session;
}

/// Inbound half of the link between the two apps.
///
/// The outbound half is [CompanionApp]. Together they make the pair behave like
/// one product: whichever icon the rep taps, they sign in once and sign out
/// once.
///
/// The scheme is private (`dyngis://`) rather than an https app link on
/// purpose. These are two apps on one device talking to each other; there is no
/// web address involved and nothing here should be routable from a browser
/// someone else controls.
class CompanionLink {
  CompanionLink({AppLinks? links}) : _links = links ?? AppLinks();

  final AppLinks _links;
  StreamSubscription<Uri>? _subscription;

  /// Starts listening, and replays the link that launched the app if there was
  /// one. [onRequest] may fire immediately.
  ///
  /// A cold start and a resume arrive by different paths — the launch intent
  /// versus a new one delivered to the running activity — and both matter here:
  /// the tracker is usually already running when the PWA calls out to it.
  Future<void> start(void Function(CompanionCall) onCall) async {
    _subscription ??= _links.uriLinkStream.listen(
      (Uri uri) {
        final CompanionCall? call = parse(uri);
        if (call != null) onCall(call);
      },
      // A malformed link is not worth taking the app down for.
      onError: (Object _) {},
    );

    try {
      final Uri? initial = await _links.getInitialLink();
      if (initial == null) return;
      final CompanionCall? call = parse(initial);
      if (call != null) onCall(call);
    } catch (_) {
      // No launch link, or the platform channel is unavailable in a test.
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Reads a call out of an inbound URI, or null if it is not one of ours.
  ///
  /// Both spellings are accepted — `dyngis://signin` puts the verb in the host,
  /// `dyngis:/signin` in the path — because which one a URI parser produces
  /// depends on the slashes the caller wrote, and a sign-out that silently did
  /// nothing would be the worst possible failure here.
  static CompanionCall? parse(Uri uri) {
    if (uri.scheme.toLowerCase() != 'dyngis') return null;

    final String verb = (uri.host.isNotEmpty
            ? uri.host
            : uri.pathSegments.isNotEmpty
                ? uri.pathSegments.first
                : '')
        .toLowerCase();

    return switch (verb) {
      'signin' => CompanionCall(
          CompanionRequest.signIn,
          session: _readSession(uri.queryParameters['handoff']),
        ),
      'signout' => const CompanionCall(CompanionRequest.signOut),
      _ => null,
    };
  }

  /// Decodes a session the PWA passed in, or null if it is unusable.
  ///
  /// Everything about the payload is treated as hostile. A custom scheme is
  /// not a verified channel — any app on the device can send one — so nothing
  /// here trusts the caller's arithmetic: expiry is recomputed from the JWT's
  /// own `exp` claim by [AuthSession.fromLoginData], not read from whatever
  /// `expireAt` string arrived, and a token that is malformed, identity-less
  /// or already dead is dropped rather than stored.
  ///
  /// Dropping it is safe: the rep simply sees this app's own login screen,
  /// which is where they would have been anyway.
  static AuthSession? _readSession(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;

    try {
      final String json = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      final Object? decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;

      final AuthSession session = AuthSession.fromLoginData(decoded);
      if (!session.isValid || session.isExpired) return null;
      return session;
    } catch (_) {
      return null;
    }
  }
}
