// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'handle_access_token_response.dart';
import 'parameters.dart';
import 'utils.dart';

/// Type of the callback when credentials are refreshed.
typedef CredentialsRefreshedCallback = void Function(Credentials);

/// Credentials that prove that a client is allowed to access a resource on the
/// resource owner's behalf.
///
/// These credentials are long-lasting and can be safely persisted across
/// multiple runs of the program.
///
/// Many authorization servers will attach an expiration date to a set of
/// credentials, along with a token that can be used to refresh the credentials
/// once they've expired. The [Client] will automatically refresh its
/// credentials when necessary. It's also possible to explicitly refresh them
/// via [Client.refreshCredentials] or [Credentials.refresh].
///
/// Note that a given set of credentials can only be refreshed once, so be sure
/// to save the refreshed credentials for future use.
class Credentials {
  /// A [String] used to separate scopes; defaults to `" "`.
  String _delimiter;

  /// The token that is sent to the resource server to prove the authorization
  /// of a client.
  final String accessToken;

  /// The token that is sent to the authorization server to refresh the
  /// credentials.
  ///
  /// This may be `null`, indicating that the credentials can't be refreshed.
  final String refreshToken;

  /// The URL of the authorization server endpoint that's used to refresh the
  /// credentials.
  ///
  /// This may be `null`, indicating that the credentials can't be refreshed.
  final Uri tokenEndpoint;

  /// The specific permissions being requested from the authorization server.
  ///
  /// The scope strings are specific to the authorization server and may be
  /// found in its documentation.
  final List<String> scopes;

  /// The date at which these credentials will expire.
  ///
  /// This is likely to be a few seconds earlier than the server's idea of the
  /// expiration date.
  final DateTime expiration;

  /// The function used to parse parameters from a host's response.
  final GetParameters _getParameters;

  /// Whether or not these credentials have expired.
  ///
  /// Note that it's possible the credentials will expire shortly after this is
  /// called. However, since the client's expiration date is kept a few seconds
  /// earlier than the server's, there should be enough leeway to rely on this.
  bool get isExpired =>
      expiration != null && new DateTime.now().isAfter(expiration);

  /// Whether it's possible to refresh these credentials.
  bool get canRefresh => refreshToken != null && tokenEndpoint != null;

  /// Creates a new set of credentials.
  ///
  /// This class is usually not constructed directly; rather, it's accessed via
  /// [Client.credentials] after a [Client] is created by
  /// [AuthorizationCodeGrant]. Alternately, it may be loaded from a serialized
  /// form via [Credentials.fromJson].
  ///
  /// The scope strings will be separated by the provided [delimiter]. This
  /// defaults to `" "`, the OAuth2 standard, but some APIs (such as Facebook's)
  /// use non-standard delimiters.
  ///
  /// By default, this follows the OAuth2 spec and requires the server's
  /// responses to be in JSON format. However, some servers return non-standard
  /// response formats, which can be parsed using the [getParameters] function.
  ///
  /// This function is passed the `Content-Type` header of the response as well
  /// as its body as a UTF-8-decoded string. It should return a map in the same
  /// format as the [standard JSON response][].
  ///
  /// [standard JSON response]: https://tools.ietf.org/html/rfc6749#section-5.1
  Credentials(this.accessToken,
      {this.refreshToken,
      this.tokenEndpoint,
      Iterable<String> scopes,
      this.expiration,
      String delimiter,
      Map<String, dynamic> getParameters(MediaType mediaType, String body)})
      : scopes = new UnmodifiableListView(
            // Explicitly type-annotate the list literal to work around
            // sdk#24202.
            scopes == null ? <String>[] : scopes.toList()),
        _delimiter = delimiter ?? ' ',
        _getParameters = getParameters ?? parseJsonParameters;

  /// Loads a set of credentials from a JSON-serialized form.
  ///
  /// Throws a [FormatException] if the JSON is incorrectly formatted.
  factory Credentials.fromJson(String json) {
    validate(condition, message) {
      if (condition) return;
      throw new FormatException(
          "Failed to load credentials: $message.\n\n$json");
    }

    var parsed;
    try {
      parsed = jsonDecode(json);
    } on FormatException {
      validate(false, 'invalid JSON');
    }

    validate(parsed is Map, 'was not a JSON map');
    validate(parsed.containsKey('accessToken'),
        'did not contain required field "accessToken"');
    validate(
        parsed['accessToken'] is String,
        'required field "accessToken" was not a string, was '
        '${parsed["accessToken"]}');

    for (var stringField in ['refreshToken', 'tokenEndpoint']) {
      var value = parsed[stringField];
      validate(value == null || value is String,
          'field "$stringField" was not a string, was "$value"');
    }

    var scopes = parsed['scopes'];
    validate(scopes == null || scopes is List,
        'field "scopes" was not a list, was "$scopes"');

    var tokenEndpoint = parsed['tokenEndpoint'];
    if (tokenEndpoint != null) {
      tokenEndpoint = Uri.parse(tokenEndpoint);
    }
    var expiration = parsed['expiration'];
    if (expiration != null) {
      validate(expiration is int,
          'field "expiration" was not an int, was "$expiration"');
      expiration = new DateTime.fromMillisecondsSinceEpoch(expiration);
    }

    return new Credentials(parsed['accessToken'],
        refreshToken: parsed['refreshToken'],
        tokenEndpoint: tokenEndpoint,
        scopes: (scopes as List).map((scope) => scope as String),
        expiration: expiration);
  }

  /// Serializes a set of credentials to JSON.
  ///
  /// Nothing is guaranteed about the output except that it's valid JSON and
  /// compatible with [Credentials.toJson].
  String toJson() => jsonEncode({
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'tokenEndpoint':
            tokenEndpoint == null ? null : tokenEndpoint.toString(),
        'scopes': scopes,
        'expiration':
            expiration == null ? null : expiration.millisecondsSinceEpoch
      });

  /// Returns a new set of refreshed credentials.
  ///
  /// See [Client.identifier] and [Client.secret] for explanations of those
  /// parameters.
  ///
  /// You may request different scopes than the default by passing in
  /// [newScopes]. These must be a subset of [scopes].
  ///
  /// This throws an [ArgumentError] if [secret] is passed without [identifier],
  /// a [StateError] if these credentials can't be refreshed, an
  /// [AuthorizationException] if refreshing the credentials fails, or a
  /// [FormatError] if the authorization server returns invalid responses.
  Future<Credentials> refresh(
      {String identifier,
      String secret,
      Iterable<String> newScopes,
      bool basicAuth = true,
      http.Client httpClient}) async {
    var scopes = this.scopes;
    if (newScopes != null) scopes = newScopes.toList();
    if (scopes == null) scopes = [];
    if (httpClient == null) httpClient = new http.Client();

    if (identifier == null && secret != null) {
      throw new ArgumentError("secret may not be passed without identifier.");
    }

    var startTime = new DateTime.now();
    if (refreshToken == null) {
      throw new StateError("Can't refresh credentials without a refresh "
          "token.");
    } else if (tokenEndpoint == null) {
      throw new StateError("Can't refresh credentials without a token "
          "endpoint.");
    }

    var headers = <String, String>{};

    var body = {"grant_type": "refresh_token", "refresh_token": refreshToken};
    if (scopes.isNotEmpty) body["scope"] = scopes.join(_delimiter);

    if (basicAuth && secret != null) {
      headers["Authorization"] = basicAuthHeader(identifier, secret);
    } else {
      if (identifier != null) body["client_id"] = identifier;
      if (secret != null) body["client_secret"] = secret;
    }

    var response =
        await httpClient.post(tokenEndpoint, headers: headers, body: body);
    var credentials = await handleAccessTokenResponse(
        response, tokenEndpoint, startTime, scopes, _delimiter,
        getParameters: _getParameters);

    // The authorization server may issue a new refresh token. If it doesn't,
    // we should re-use the one we already have.
    if (credentials.refreshToken != null) return credentials;
    return new Credentials(credentials.accessToken,
        refreshToken: this.refreshToken,
        tokenEndpoint: credentials.tokenEndpoint,
        scopes: credentials.scopes,
        expiration: credentials.expiration);
  }
}
