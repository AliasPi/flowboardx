import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'remote_host_resolver_io.dart';

http.Client createSecureHttpClient() {
  final inner = HttpClient();
  inner.findProxy = (_) => 'DIRECT';
  inner.connectionFactory = _connectToValidatedAddress;
  return IOClient(inner);
}

Future<ConnectionTask<Socket>> _connectToValidatedAddress(
  Uri uri,
  String? proxyHost,
  int? proxyPort,
) async {
  if (proxyHost != null || proxyPort != null) {
    throw const FormatException('Proxy connections are not permitted.');
  }
  final addresses = await resolvePublicInternetAddresses(uri.host);
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  final connection = await Socket.startConnect(addresses.first, port);
  Future<Socket> socket = connection.socket;
  if (uri.scheme == 'https') {
    socket = socket.then((value) => SecureSocket.secure(value, host: uri.host));
  }
  return ConnectionTask.fromSocket<Socket>(socket, connection.cancel);
}
