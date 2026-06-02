import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef HttpResponseFactory = HttpClientResponse Function(
    Uri url, String method);

class FakeHttpClient implements HttpClient {
  final HttpResponseFactory responseFactory;
  @override
  BadCertificateCallback? badCertificateCallback;
  @override
  Duration? connectionTimeout;

  FakeHttpClient(this.responseFactory);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      FakeHttpClientRequest(responseFactory(url, 'GET'));

  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      FakeHttpClientRequest(responseFactory(url, 'POST'));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClientRequest implements HttpClientRequest {
  final HttpClientResponse response;
  final FakeHttpHeaders _headers = FakeHttpHeaders();

  FakeHttpClientRequest(this.response);

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  HttpHeaders get headers => _headers;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  final int statusCode;
  @override
  final HttpHeaders headers = FakeHttpHeaders();

  final String body;

  FakeHttpClientResponse(this.statusCode, this.body);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([utf8.encode(body)]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError ?? false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  String? host;

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    final key = name.toLowerCase();
    _values.putIfAbsent(key, () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  void remove(String name, Object value) {
    _values[name.toLowerCase()]?.remove(value.toString());
  }

  @override
  void removeAll(String name) {
    _values.remove(name.toLowerCase());
  }

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<T> withFakeHttpClient<T>(
  Future<T> Function() body,
  HttpResponseFactory factory,
) {
  return HttpOverrides.runZoned(
    body,
    createHttpClient: (SecurityContext? context) => FakeHttpClient(factory),
  );
}
