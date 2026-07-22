import 'remote_host_resolver_stub.dart'
    if (dart.library.io) 'remote_host_resolver_io.dart'
    as platform;
import 'resolved_host_address.dart';

export 'resolved_host_address.dart';

typedef RemoteHostResolver =
    Future<List<ResolvedHostAddress>> Function(String host);

Future<List<ResolvedHostAddress>> resolveRemoteHost(String host) =>
    platform.resolveRemoteHost(host);
