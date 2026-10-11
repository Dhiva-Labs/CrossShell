import 'package:dartssh2/dartssh2.dart';

/// Algorithm preferences that make SFTP and port forwards fast.
///
/// dartssh2 4.x offers AES-GCM first, and its AES is pure Dart: measured over
/// a LAN to a Windows peer, SFTP moved 1 MB/s with AES-GCM, 4-6 MB/s with
/// AES-CTR and 19 MB/s with ChaCha20-Poly1305 (plain OpenSSH scp: 15 MB/s).
/// Every server OpenSSH 6.5 or newer, including Win32-OpenSSH, offers
/// ChaCha20, so list it first and keep the others as fallbacks.
///
/// Pass this as `SSHClient(algorithms: fastSshAlgorithms)` when building the
/// client for [SessionPage.connect].
const SSHAlgorithms fastSshAlgorithms = SSHAlgorithms(
  cipher: [
    SSHCipherType.chacha20poly1305,
    SSHCipherType.aes128ctr,
    SSHCipherType.aes256ctr,
    SSHCipherType.aes128gcm,
    SSHCipherType.aes256gcm,
  ],
);
