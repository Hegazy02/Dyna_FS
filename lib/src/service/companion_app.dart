import 'dart:convert';

import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/auth_session.dart';

/// Hands the user — and their session — over to the companion PWA once they
/// are signed in.
///
/// **Getting there.** There is no API for "launch the PWA with id X"; an
/// installed PWA is not addressable by package name in any stable way. What
/// there *is*, on Android, is link capture: Chrome installs a PWA as a WebAPK
/// whose manifest declares verified intent filters for every URL inside the
/// app's `scope`. Firing an ordinary `ACTION_VIEW` at the PWA's own https
/// address therefore resolves to the installed app, which opens standalone —
/// no browser chrome, its own task in the recents list. That only holds when
/// the PWA really was installed (a WebAPK, not a home-screen bookmark) with
/// "Open supported links" left on, so the launch is attempted twice:
///
///  1. [LaunchMode.externalNonBrowserApplication] — succeeds only if a
///     non-browser app claims the link, i.e. the installed PWA.
///  2. [LaunchMode.externalApplication] — the browser, where the same PWA runs
///     and can offer its own install prompt.
///
/// Neither mode uses an in-app WebView or Custom Tab on purpose: those would
/// render the site inside this app, which is not what "open my PWA" means, and
/// would not share the storage the installed app already has.
///
/// **Arriving signed in.** Both apps authenticate against the same API, so the
/// JWT this app already holds is a valid credential over there too. Rather
/// than ask for the same password twice, the session travels in the URL
/// *fragment* — see [handoffUri].
/// How far a launch attempt got.
enum CompanionLaunch {
  /// The installed PWA took the link and opened standalone.
  openedApp,

  /// A browser took it, because the caller allowed that.
  openedBrowser,

  /// No non-browser app claimed the link. Three different causes look
  /// identical from here — the PWA is not installed, it was saved as a
  /// home-screen shortcut rather than installed, or its "Open supported
  /// links" was turned off — so whatever the rep is told has to cover all
  /// three.
  appMissing,

  /// Nothing is configured, the URL is unusable, or not even a browser would
  /// take it.
  unavailable,
}

class CompanionApp {
  const CompanionApp._();

  static bool get isConfigured => AppConfig.hasCompanionApp;

  static Uri? get uri {
    if (!isConfigured) return null;
    final Uri? parsed = Uri.tryParse(AppConfig.companionUrl.trim());
    return (parsed != null && parsed.hasScheme) ? parsed : null;
  }

  /// [target] with the session attached as `#handoff=<base64url json>`.
  ///
  /// The fragment is the point. A query string would be sent to the server on
  /// every request to that URL and land in access logs and `Referer` headers;
  /// a fragment never leaves the client. The receiving app reads it before it
  /// boots and strips it from the address bar immediately.
  ///
  /// The four fields are exactly the `Token` shape the PWA persists. `expireAt`
  /// is this app's *corrected* expiry — read from the JWT `exp` claim rather
  /// than the login response's ambiguous naive string — so the PWA's automatic
  /// logout lands on the moment the server actually stops honouring the token
  /// instead of seven hours out.
  static Uri handoffUri(Uri target, AuthSession session) {
    final String payload = base64Url.encode(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'token': session.token,
          'userId': session.userId,
          'expireAt': session.expireAt.toIso8601String(),
          'isSuperAdmin': session.isSuperAdmin,
        }),
      ),
    );
    return target.replace(fragment: 'handoff=$payload');
  }

  /// Opens the companion app, reporting which door it got through.
  ///
  /// Pass [session] to have the user arrive already signed in.
  ///
  /// [allowBrowser] is off by default, and that is the important part. Falling
  /// back to a browser silently is the worst outcome available: the rep is
  /// dumped into a tab, signed out, with no idea why — and this app is in the
  /// background, unable to tell them. Better to come back with
  /// [CompanionLaunch.appMissing] and explain while still on screen. The
  /// caller can then offer the browser as a deliberate choice.
  static Future<CompanionLaunch> open({
    AuthSession? session,
    bool allowBrowser = false,
  }) async {
    final Uri? target = uri;
    if (target == null) return CompanionLaunch.unavailable;

    // The credential rides only on the launch an installed app is the sole
    // possible receiver of. The browser fallback gets a bare URL: a JWT
    // written into browser history — which Chrome may then sync to the user's
    // Google account — is not a fair price for saving one sign-in.
    final bool carrySession = session != null && !session.isExpired;
    final Uri firstAttempt =
        carrySession ? handoffUri(target, session) : target;

    if (await _tryLaunch(
      firstAttempt,
      LaunchMode.externalNonBrowserApplication,
    )) {
      return CompanionLaunch.openedApp;
    }

    if (!allowBrowser) return CompanionLaunch.appMissing;

    return await _tryLaunch(target, LaunchMode.externalApplication)
        ? CompanionLaunch.openedBrowser
        : CompanionLaunch.unavailable;
  }

  static Future<bool> _tryLaunch(Uri target, LaunchMode mode) async {
    try {
      return await launchUrl(target, mode: mode);
    } catch (_) {
      // externalNonBrowserApplication throws rather than returning false when
      // nothing but a browser can handle the link, and on Android below API 30
      // it is not supported at all. Either way the fallback should still run.
      return false;
    }
  }
}
