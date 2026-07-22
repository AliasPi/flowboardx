import 'package:http/http.dart' as http;

import 'secure_http_client_stub.dart'
    if (dart.library.io) 'secure_http_client_io.dart'
    as platform;

http.Client createSecureHttpClient() => platform.createSecureHttpClient();
