/// A DNS answer classified by the platform resolver.
///
/// Keeping the classification next to the lookup avoids importing `dart:io`
/// into the Google image service, which must still compile for Flutter web.
final class ResolvedHostAddress {
  const ResolvedHostAddress(this.address, {required this.isPublic});

  final String address;
  final bool isPublic;
}
