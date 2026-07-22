import 'resolved_host_address.dart';

Future<List<ResolvedHostAddress>> resolveRemoteHost(String host) {
  throw UnsupportedError(
    'The browser does not expose the DNS answers needed for safe downloads.',
  );
}
