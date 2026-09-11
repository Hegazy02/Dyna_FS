import 'dart:async';

import 'package:app_links/app_links.dart';

/// What the companion app is asking this one to do.
enum CompanionRequest {
  /// `dyngis://signin` — the rep is in the PWA with no session and would rather
  /// not type a password there. If this app holds a usable session it hands it
  /// straight back; otherwise the login screen appears and the hand-off follows
  /// the sign-in.
  signIn,

  /// `dyngis://signout` — the rep signed out over there. Stop reporting and
  /// clear the session here too, so one sign-out means one sign-out.
  signOut,
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
  Future<void> start(void Function(CompanionRequest) onRequest) async {
    _subscription ??= _links.uriLinkStream.listen(
      (Uri uri) {
        final CompanionRequest? request = parse(uri);
        if (request != null) onRequest(request);
      },
      // A malformed link is not worth taking the app down for.
      onError: (Object _) {},
    );

    try {
      final Uri? initial = await _links.getInitialLink();
      if (initial == null) return;
      final CompanionRequest? request = parse(initial);
      if (request != null) onRequest(request);
    } catch (_) {
      // No launch link, or the platform channel is unavailable in a test.
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Reads a request out of an inbound URI, or null if it is not one of ours.
  ///
  /// Both spellings are accepted — `dyngis://signin` puts the verb in the host,
  /// `dyngis:/signin` in the path — because which one a URI parser produces
  /// depends on the slashes the caller wrote, and a sign-out that silently did
  /// nothing would be the worst possible failure here.
  static CompanionRequest? parse(Uri uri) {
    if (uri.scheme.toLowerCase() != 'dyngis') return null;

    final String verb = (uri.host.isNotEmpty
            ? uri.host
            : uri.pathSegments.isNotEmpty
                ? uri.pathSegments.first
                : '')
        .toLowerCase();

    return switch (verb) {
      'signin' => CompanionRequest.signIn,
      'signout' => CompanionRequest.signOut,
      _ => null,
    };
  }
}
