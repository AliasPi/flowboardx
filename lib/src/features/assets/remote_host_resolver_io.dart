import 'dart:io';

import 'resolved_host_address.dart';

Future<List<ResolvedHostAddress>> resolveRemoteHost(String host) async {
  final addresses = await InternetAddress.lookup(
    host,
    type: InternetAddressType.IPv4,
  );
  return List<ResolvedHostAddress>.unmodifiable(
    addresses.map(
      (address) => ResolvedHostAddress(
        address.address,
        isPublic: isPublicInternetAddress(address),
      ),
    ),
  );
}

bool isPublicInternetAddress(InternetAddress address) =>
    _isPublicAddress(address.rawAddress);

Future<List<InternetAddress>> resolvePublicInternetAddresses(
  String host,
) async {
  final addresses = await InternetAddress.lookup(
    host,
    type: InternetAddressType.IPv4,
  );
  if (addresses.isEmpty ||
      addresses.any((address) => !isPublicInternetAddress(address))) {
    throw const FormatException(
      'Remote host resolved to a non-public network address.',
    );
  }
  return addresses;
}

bool _isPublicAddress(List<int> bytes) {
  if (bytes.length == 4) return _isPublicIpv4(bytes);
  if (bytes.length != 16) return false;

  final allZero = bytes.every((value) => value == 0);
  if (allZero) return false; // IPv6 unspecified address.
  final loopback =
      bytes.take(15).every((value) => value == 0) && bytes.last == 1;
  if (loopback) return false;

  // IPv4-compatible and IPv4-mapped IPv6 addresses inherit the IPv4 scope.
  final firstTenZero = bytes.take(10).every((value) => value == 0);
  final firstTwelveZero = bytes.take(12).every((value) => value == 0);
  if ((firstTenZero && bytes[10] == 0xff && bytes[11] == 0xff) ||
      firstTwelveZero) {
    return _isPublicIpv4(bytes.sublist(12));
  }

  final first = bytes[0];
  final second = bytes[1];
  if ((first & 0xfe) == 0xfc) return false; // Unique-local fc00::/7.
  if (first == 0xfe && ((second & 0xc0) == 0x80 || (second & 0xc0) == 0xc0)) {
    return false; // Link-local fe80::/10 and deprecated site-local fec0::/10.
  }
  if (first == 0xff) return false; // Multicast.
  if (bytes[0] == 0x20 &&
      bytes[1] == 0x01 &&
      bytes[2] == 0x0d &&
      bytes[3] == 0xb8) {
    return false; // Documentation prefix 2001:db8::/32.
  }
  return true;
}

bool _isPublicIpv4(List<int> bytes) {
  if (bytes.length != 4 || bytes.any((value) => value < 0 || value > 255)) {
    return false;
  }
  final first = bytes[0];
  final second = bytes[1];
  final third = bytes[2];
  return first != 0 &&
      first != 10 &&
      first != 127 &&
      !(first == 100 && second >= 64 && second <= 127) &&
      !(first == 169 && second == 254) &&
      !(first == 172 && second >= 16 && second <= 31) &&
      !(first == 192 && second == 0 && third == 0) &&
      !(first == 192 && second == 0 && third == 2) &&
      !(first == 192 && second == 168) &&
      !(first == 198 && (second == 18 || second == 19)) &&
      !(first == 198 && second == 51 && third == 100) &&
      !(first == 203 && second == 0 && third == 113) &&
      first < 224;
}
