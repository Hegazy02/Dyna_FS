import 'dart:async';

import 'package:flutter/material.dart';

import '../data/auth_repository.dart';
import '../data/remembered_account.dart';
import '../models/auth_session.dart';

/// Sign-in screen. Shown only when there is no cached session, when the cached
/// one has expired, or when the server has refused the token — otherwise the
/// app goes straight to tracking.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.onSignedIn,
    this.initialUsername,
    this.notice,
  });

  final ValueChanged<AuthSession> onSignedIn;

  /// Prefilled so a re-login after expiry is one field, not two.
  final String? initialUsername;

  /// Why the user is looking at this screen again, if they have been here
  /// before ("Your session expired…").
  final String? notice;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthRepository _auth = AuthRepository();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

  final RememberedAccountStore _remembered = const RememberedAccountStore();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  /// The previous sign-in, offered as a one-tap suggestion. Null until the
  /// keystore read comes back, and null forever if nobody has signed in on
  /// this device yet.
  RememberedAccount? _suggestion;

  @override
  void initState() {
    super.initState();
    _username.text = widget.initialUsername ?? '';
    unawaited(_loadSuggestion());
  }

  Future<void> _loadSuggestion() async {
    final account = await _remembered.load();
    if (!mounted || account == null) return;

    setState(() => _suggestion = account);
  }

  /// Fills both fields from the suggestion, leaving the rep one tap from being
  /// signed in. Deliberately does not submit for them: a sign-in that fires on
  /// a stray tap, with no chance to read what it is about to send, is a worse
  /// experience than the one tap it saves.
  void _useSuggestion(RememberedAccount account) {
    FocusScope.of(context).unfocus();
    setState(() {
      _username.text = account.username;
      _password.text = account.password;
      _error = null;
    });
  }

  Future<void> _forgetSuggestion() async {
    setState(() => _suggestion = null);
    await _remembered.clear();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    _auth.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_form.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await _auth.login(
      username: _username.text.trim(),
      password: _password.text,
    );

    if (!mounted) return;

    switch (result) {
      case LoginSuccess(session: final session):
        // Only a credential the server has just accepted is worth keeping, so
        // this is the one place that writes it. Awaited before handing control
        // on, or the screen can be disposed mid-write.
        await _remembered.save(
          RememberedAccount(
            username: _username.text.trim(),
            password: _password.text,
            fullName: session.fullName,
          ),
        );
        if (!mounted) return;
        widget.onSignedIn(session);
      case LoginRejected(message: final message):
      case LoginFailed(message: final message):
        setState(() {
          _busy = false;
          _error = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Icon(
                      Icons.location_on_outlined,
                      size: 44,
                      color: Color(0xFF0A84FF),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Sign in',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Location sharing starts once you are signed in.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: Color(0xFF8A8A8E),
                      ),
                    ),
                    if (widget.notice != null) ...<Widget>[
                      const SizedBox(height: 20),
                      _Banner(
                        message: widget.notice!,
                        color: const Color(0xFFB25000),
                        background: const Color(0xFFFFF3E6),
                      ),
                    ],
                    if (_suggestion != null) ...<Widget>[
                      const SizedBox(height: 28),
                      _AccountSuggestion(
                        account: _suggestion!,
                        enabled: !_busy,
                        onUse: () => _useSuggestion(_suggestion!),
                        onForget: _forgetSuggestion,
                      ),
                    ],
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _username,
                      enabled: !_busy,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const <String>[AutofillHints.username],
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (String? value) =>
                          (value == null || value.trim().isEmpty)
                              ? 'Enter your username'
                              : null,
                      onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      focusNode: _passwordFocus,
                      enabled: !_busy,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      autofillHints: const <String>[AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          tooltip: _obscure ? 'Show password' : 'Hide password',
                        ),
                      ),
                      validator: (String? value) =>
                          (value == null || value.isEmpty)
                              ? 'Enter your password'
                              : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 16),
                      _Banner(
                        message: _error!,
                        color: const Color(0xFFB3261E),
                        background: const Color(0xFFFDECEA),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Sign in'),
                    ),
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

/// The previous sign-in, offered as a tappable row: the rep taps their own
/// name, then Sign in, and types nothing.
class _AccountSuggestion extends StatelessWidget {
  const _AccountSuggestion({
    required this.account,
    required this.enabled,
    required this.onUse,
    required this.onForget,
  });

  final RememberedAccount account;
  final bool enabled;
  final VoidCallback onUse;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    // The username is the subtitle only when it is not already the title, so
    // an account with no display name does not print the same string twice.
    final String? subtitle =
        account.label == account.username ? null : account.username;

    return Material(
      color: const Color(0xFFF2F7FF),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: enabled ? onUse : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF0A84FF),
                child: Text(
                  account.initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      account.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle ?? 'Tap to sign in',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF8A8A8E),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: enabled ? onForget : null,
                icon: const Icon(Icons.close, size: 18),
                color: const Color(0xFF8A8A8E),
                tooltip: 'Forget this account',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.message,
    required this.color,
    required this.background,
  });

  final String message;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: 13, height: 1.4, color: color),
      ),
    );
  }
}
