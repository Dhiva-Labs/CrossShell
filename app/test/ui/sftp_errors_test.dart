import 'package:cross_shell/src/ui/session/files/fs_backend.dart';
import 'package:cross_shell/src/ui/session/files/sftp_backend.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SFTP status codes become typed, readable errors', () {
    FsException d(int code, String msg) =>
        describeSftpError(SftpStatusError(code, msg), '/C:/x');
    expect(d(2, 'No such file').kind, FsErrorKind.notFound);
    expect(d(2, 'No such file').message, contains('does not exist'));
    expect(d(3, 'Permission denied').kind, FsErrorKind.permissionDenied);
    expect(d(3, 'Permission denied').message, contains('/C:/x'));
    expect(d(4, 'Failure').message, contains('refused'));
    expect(d(7, 'No connection').kind, FsErrorKind.disconnected);
    expect(d(8, 'Op unsupported').message, contains('does not support'));
    expect(d(99, 'Weird').message, contains('Weird'));
  });

  test('connection-level failures say the connection was lost', () {
    expect(
      describeSftpError(SftpAbortError('closed'), '/x').kind,
      FsErrorKind.disconnected,
    );
    expect(
      describeSftpError(SSHStateError('SSH client closed'), '/x').kind,
      FsErrorKind.disconnected,
    );
  });

  test(
    'the raw error is kept for diagnostics and unknown errors are not swallowed',
    () {
      final e = describeSftpError(StateError('boom'), '/x');
      expect(e.message, contains('boom'));
      expect(e.details, contains('boom'));
      final again = describeSftpError(e, '/other');
      expect(
        identical(again, e),
        isTrue,
        reason: 'already described errors pass through',
      );
    },
  );
}
