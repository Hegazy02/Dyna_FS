/// Build-time configuration for the tracker.
///
/// Nothing here is hard-coded into the source you have to edit before shipping.
/// Every value is overridable at build time, so one codebase can produce APKs
/// pointed at staging, production, or a customer-specific host:
///
/// ```
/// flutter build apk --release \
///   --dart-define=DYN_GIS_BASE_URL=https://daralshayapi.dynaops365.net \
///   --dart-define=DYN_GIS_INGEST_PATH=/api/Location/Track \
///   --dart-define=DYN_GIS_HEARTBEAT_SECONDS=30
/// ```
///
/// There is no API token setting: the app authenticates the user at the login
/// screen and uses the JWT it gets back.
class AppConfig {
  const AppConfig._();

  /// Scheme + host (+ optional base path) of the backend. No trailing slash.
  static const String baseUrl = String.fromEnvironment(
    'DYN_GIS_BASE_URL',
    defaultValue: 'https://daralshayapi.dynaops365.net',
  );

  /// Path appended to [baseUrl] for signing in.
  static const String loginPath = String.fromEnvironment(
    'DYN_GIS_LOGIN_PATH',
    defaultValue: '/api/Auth/Login',
  );

  /// Path appended to [baseUrl] for the location ingest endpoint.
  static const String ingestPath = String.fromEnvironment(
    'DYN_GIS_INGEST_PATH',
    defaultValue: '/api/LocationPings/batch',
  );

  /// Web address of the companion PWA, opened once the user has signed in and
  /// permissions are settled.
  ///
  /// A PWA installed from Chrome is a WebAPK that claims its own https links,
  /// so this plain URL opens the installed app in its own window rather than a
  /// browser tab. Nothing here is Android-specific, though: on a device where
  /// the PWA is not installed the same URL opens in the browser.
  ///
  /// Point a build at a different front end — or set it empty to switch the
  /// hand-off off entirely and leave the tracker on its own screen:
  ///
  ///     --dart-define=DYN_GIS_APP_URL=
  static const String companionUrl = String.fromEnvironment(
    'DYN_GIS_APP_URL',
    defaultValue: 'https://daralshayuat.dynaops365.net',
  );

  /// How the `at` field is written: `local` (default) or `utc`.
  ///
  /// The endpoint takes naive timestamps with no offset
  /// (`2026-09-09T09:59:00`), so the zone is a convention between the two
  /// sides rather than anything the wire format states. The convention here is
  /// **the rep's own local clock**: a fix taken at 09:59 in Riyadh is sent as
  /// `09:59`, and the supervisor screens show the time the rep would have read
  /// off their phone.
  ///
  /// The cost of that convention is that it only holds while the device and
  /// the server agree on what naive means. A phone travelling across a
  /// timezone, or a server that interprets these as its own local time rather
  /// than the device's, will shift the whole stream. If stored pings come back
  /// offset by a whole number of hours, that disagreement is why — flip this
  /// to `utc`, or have the API take an explicit offset, which is the only real
  /// fix.
  static const String timestampMode =
      String.fromEnvironment('DYN_GIS_TIMESTAMP_MODE', defaultValue: 'local');

  static bool get sendLocalTimestamps => timestampMode.toLowerCase() == 'local';

  /// How often a position is captured and pushed even when the device is still.
  static const int heartbeatSeconds =
      int.fromEnvironment('DYN_GIS_HEARTBEAT_SECONDS', defaultValue: 30);

  /// Metres of movement that trigger an out-of-band update between heartbeats.
  /// Lower values mean more fixes and more battery drain.
  static const int distanceFilterMeters =
      int.fromEnvironment('DYN_GIS_DISTANCE_FILTER_M', defaultValue: 25);

  /// How often the GNSS receiver is asked for a fix, which is deliberately not
  /// how often we report one — see [distanceFilterMeters] and
  /// [heartbeatSeconds] for the reporting cadence.
  ///
  /// These have to be separate knobs. GNSS speed and bearing come from the
  /// Doppler shift on the carrier signal, and that solution only exists while
  /// the receiver is continuously tracking satellites. Ask Android for a fix
  /// every 30 seconds and it duty-cycles the GPS hardware between requests;
  /// each fix then arrives from a cold-ish engine with a position but no
  /// velocity, so `Location.hasSpeed()` and `hasBearing()` come back false and
  /// every ping reports 0 km/h. Sampling every second keeps the engine warm
  /// and the velocity solution alive; the Dart-side distance gate keeps the
  /// number of pings we actually send unchanged.
  ///
  /// The cost is real: a continuously tracking GNSS receiver draws noticeably
  /// more power than a duty-cycled one. That is the price of a speed reading.
  static const int gpsSampleSeconds =
      int.fromEnvironment('DYN_GIS_GPS_SAMPLE_SECONDS', defaultValue: 1);

  /// Maximum pings sent in a single HTTP request when draining the queue.
  static const int batchSize =
      int.fromEnvironment('DYN_GIS_BATCH_SIZE', defaultValue: 100);

  /// Hard cap on the offline queue. Oldest rows are dropped beyond this so a
  /// device that is offline for weeks cannot fill the user's storage.
  static const int queueCapacity =
      int.fromEnvironment('DYN_GIS_QUEUE_CAPACITY', defaultValue: 20000);

  /// Upper bound for exponential backoff after repeated upload failures.
  static const int maxBackoffSeconds =
      int.fromEnvironment('DYN_GIS_MAX_BACKOFF_SECONDS', defaultValue: 900);

  static const Duration requestTimeout = Duration(seconds: 30);

  /// Shows the request/response log on the home screen instead of the blank
  /// white screen.
  ///
  /// Defaults to on so a test APK is useful out of the box. **Turn it off for
  /// production** — it puts live coordinates and an abbreviated token on a
  /// screen anyone holding the phone can read:
  ///
  ///     flutter build apk --release --dart-define=DYN_GIS_DEBUG_PANEL=false
  ///
  /// The seven-tap gesture reaches the same panel in every build, so turning
  /// this off costs nothing in the field.
  static const bool showDebugPanel =
      bool.fromEnvironment('DYN_GIS_DEBUG_PANEL', defaultValue: true);

  /// How many recent upload attempts are kept for the debug log.
  static const int debugExchangeCount =
      int.fromEnvironment('DYN_GIS_DEBUG_LOG_SIZE', defaultValue: 5);

  /// Request bodies are trimmed to this before crossing to the UI isolate.
  static const int debugBodyLimit = 3000;

  /// A build without an ingest path still tracks and queues, but cannot
  /// upload. Surfaced on the diagnostics overlay so a misbuilt APK is obvious.
  static bool get isConfigured => baseUrl.isNotEmpty && ingestPath.isNotEmpty;

  static bool get hasCompanionApp => companionUrl.trim().isNotEmpty;

  static Uri get ingestUri => Uri.parse('$baseUrl$ingestPath');

  static Uri get loginUri => Uri.parse('$baseUrl$loginPath');
}
