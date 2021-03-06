// Copyright (c) 2017, Anatoly Pulyaevskiy. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

/// HTTP client implementation for Node.
///
/// See [NodeClient] for details.
@JS()
library node_interop.http;

import 'dart:async';

import 'dart:js_util';
import 'package:http/http.dart' as http;
import 'package:js/js.dart';

import 'node_interop.dart';
import 'src/util.dart';

final HTTP _nodeHTTP = require('http');

/// HTTP client which uses Node IO (via 'http' module).
///
/// Make sure to call [close] when work with this client is done.
class NodeClient extends http.BaseClient {
  /// Keep sockets around even when there are no outstanding requests, so they
  /// can be used for future requests without having to reestablish a TCP
  /// connection. Defaults to `true`.
  final bool keepAlive;

  /// When using the keepAlive option, specifies the initial delay for TCP
  /// Keep-Alive packets. Ignored when the keepAlive option is false.
  /// Defaults to 1000.
  final int keepAliveMsecs;

  NodeClient({
    this.keepAlive = true,
    this.keepAliveMsecs = 1000,
  });

  /// Native JavaScript connection agent used by this client.
  Agent get agent => _agent ??= createAgent(new AgentOptions(
        keepAlive: keepAlive,
        keepAliveMsecs: keepAliveMsecs,
      ));
  Agent _agent;

  dynamic _jsifyHeaders(Map<String, dynamic> headers) {
    var object = newObject();
    for (var key in headers.keys) {
      setProperty(object, key, headers[key]);
    }
    return object;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    var url = request.url;
    var pathWithQuery =
        url.hasQuery ? [url.path, '?', url.query].join() : url.path;
    var options = new RequestOptions(
        protocol: "${url.scheme}:",
        hostname: url.host,
        port: url.port,
        method: request.method,
        path: pathWithQuery,
        headers: _jsifyHeaders(request.headers),
        agent: agent);
    var completer = new Completer<http.StreamedResponse>();

    void handleResponse(IncomingMessage response) {
      Map<String, dynamic> headers = jsObjectToMap(response.headers);
      var controller = new StreamController<List<int>>();
      completer.complete(new http.StreamedResponse(
        controller.stream,
        response.statusCode,
        request: request,
        headers: headers,
        reasonPhrase: response.statusMessage,
      ));

      response.on('data', allowInterop((Iterable<int> buffer) {
        // buffer is an instance of Node's Buffer.
        controller.add(new List.unmodifiable(buffer));
      }));
      response.on('end', allowInterop(() {
        controller.close();
      }));
    }

    var nodeRequest = _nodeHTTP.request(options, allowInterop(handleResponse));
    nodeRequest.on('error', allowInterop((e) {
      completer.completeError(e.message);
    }));
    http.ByteStream body = request.finalize();
    // TODO: Support StreamedRequest by consuming body asynchronously.
    body
        .toList()
        .then((List<List<int>> chunks) {
          chunks.forEach((List<int> chunk) {
            var buffer = Buffer.from(chunk);
            nodeRequest.write(buffer);
          });
        })
        .catchError(completer.completeError)
        .whenComplete(() => nodeRequest.end());

    return completer.future;
  }

  @override
  void close() {
    agent.destroy();
  }
}
