import 'package:cross_shell/src/ui/session/files/path_style.dart';
import 'package:cross_shell/src/ui/session/session_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PosixPathStyle', () {
    const s = PosixPathStyle();

    test('normalize collapses dots and slashes and cannot escape root', () {
      expect(s.normalize('/a/./b//c/'), '/a/b/c');
      expect(s.normalize('/a/b/../../..'), '/');
      expect(s.normalize(''), '/');
    });

    test('join treats an absolute name as the answer', () {
      expect(s.join('/home/me', 'x.txt'), '/home/me/x.txt');
      expect(s.join('/home/me', '/etc'), '/etc');
      expect(s.join('/', 'a'), '/a');
    });

    test('parent and basename', () {
      expect(s.parent('/a/b'), '/a');
      expect(s.parent('/a'), '/');
      expect(s.parent('/'), '/');
      expect(s.basename('/a/b.txt'), 'b.txt');
      expect(s.basename('/'), '');
    });

    test('breadcrumbs', () {
      expect(s.breadcrumbs('/a/b'), const [
        PathCrumb('/', '/'),
        PathCrumb('a', '/a'),
        PathCrumb('b', '/a/b'),
      ]);
    });

    test('isWithin does not confuse prefixes', () {
      expect(s.isWithin('/a/b', '/a/b/c'), isTrue);
      expect(s.isWithin('/a/b', '/a/bc'), isFalse);
      expect(s.isWithin('/a/b', '/a/b'), isTrue);
    });

    test('hidden and name validation', () {
      expect(s.isHidden('.bashrc'), isTrue);
      expect(s.isHidden('bashrc'), isFalse);
      expect(s.invalidNameReason('a/b'), isNotNull);
      expect(s.invalidNameReason('..'), isNotNull);
      expect(s.invalidNameReason('ok name'), isNull);
      // Colons are legal on POSIX.
      expect(s.invalidNameReason('a:b'), isNull);
    });
  });

  group('SftpWindowsPathStyle (/C:/Users/me)', () {
    const s = SftpWindowsPathStyle();

    test('recognises the server grammar', () {
      expect(SftpWindowsPathStyle.looksLikeWindows('/C:/Users/alex'), isTrue);
      expect(SftpWindowsPathStyle.looksLikeWindows('/C:'), isTrue);
      expect(SftpWindowsPathStyle.looksLikeWindows('C:\\Users'), isTrue);
      expect(SftpWindowsPathStyle.looksLikeWindows('/home/alex'), isFalse);
      expect(SftpWindowsPathStyle.looksLikeWindows('/'), isFalse);
      expect(SftpWindowsPathStyle.looksLikeWindows('/CD:/x'), isFalse);
    });

    test('normalize keeps the drive as the first segment', () {
      expect(s.normalize('/C:/Users/alex'), '/C:/Users/alex');
      expect(s.normalize('/C:/Users/alex/'), '/C:/Users/alex');
      expect(s.normalize('/C:/Users/../alex'), '/C:/alex');
    });

    test('drive roots are canonical with a trailing slash', () {
      expect(s.normalize('/C:'), '/C:/');
      expect(s.normalize('/c:'), '/C:/');
      expect(s.normalize('C:'), '/C:/');
      expect(s.normalize('/C:/'), '/C:/');
      expect(s.normalize('/'), '/');
    });

    test('accepts what a user would type', () {
      expect(s.normalize(r'C:\Users\alex'), '/C:/Users/alex');
      expect(s.normalize(r'c:\dev\crossshell'), '/C:/dev/crossshell');
      expect(s.resolveInput(r'D:\data', '/C:/Users'), '/D:/data');
      expect(
        s.resolveInput('Documents', '/C:/Users/alex'),
        '/C:/Users/alex/Documents',
      );
      expect(s.resolveInput('..', '/C:/Users/alex'), '/C:/Users');
      expect(
        s.resolveInput('~', '/C:/x', home: '/C:/Users/alex'),
        '/C:/Users/alex',
      );
    });

    test('going up from a drive root lists the drives', () {
      expect(s.parent('/C:/Users'), '/C:/');
      expect(s.parent('/C:/'), '/');
      expect(s.parent('/C:'), '/');
      expect(s.parent('/'), '/');
      expect(s.normalize('/C:/..'), '/');
    });

    test('join onto the drive list yields a drive root', () {
      expect(s.join('/', 'C:'), '/C:/');
      expect(s.join('/C:/', 'Users'), '/C:/Users');
      expect(s.join('/C:/Users', 'alex'), '/C:/Users/alex');
      expect(s.join('/C:/Users', '/D:/x'), '/D:/x');
      expect(s.join('/C:/Users', r'D:\x'), '/D:/x');
    });

    test('basename of a drive is its letter', () {
      expect(s.basename('/C:/'), 'C:');
      expect(s.basename('/C:/Users/alex'), 'alex');
      expect(s.basename('/'), '');
    });

    test('breadcrumbs start at the drive list', () {
      expect(s.breadcrumbs('/C:/Users/alex'), const [
        PathCrumb('Drives', '/'),
        PathCrumb('C:', '/C:/'),
        PathCrumb('Users', '/C:/Users'),
        PathCrumb('alex', '/C:/Users/alex'),
      ]);
      expect(s.breadcrumbs('/'), const [PathCrumb('Drives', '/')]);
    });

    test('isWithin ignores case', () {
      expect(s.isWithin('/C:/Users', '/c:/users/alex'), isTrue);
      expect(s.isWithin('/C:/Users', '/C:/UsersX'), isFalse);
      expect(s.isWithin('/C:/', '/C:/a'), isTrue);
    });

    test('Windows names: forbidden characters and hidden heuristics', () {
      expect(s.invalidNameReason('a:b'), isNotNull);
      expect(s.invalidNameReason('a?b'), isNotNull);
      expect(s.invalidNameReason('trailing.'), isNotNull);
      expect(s.invalidNameReason('fine.txt'), isNull);
      expect(s.sanitizeName('a:b?c.'), 'a_b_c');
      expect(s.isHidden(r'$Recycle.Bin'), isTrue);
      expect(s.isHidden('AppData'), isTrue);
      expect(s.isHidden('NTUSER.DAT{abc}.TM.blf'), isTrue);
      expect(s.isHidden('Documents'), isFalse);
    });

    test('remote() prefers what the server said over the paired OS', () {
      expect(
        PathStyle.remote(RemoteOs.linux, home: '/C:/Users/x'),
        isA<SftpWindowsPathStyle>(),
      );
      expect(PathStyle.remote(RemoteOs.windows), isA<SftpWindowsPathStyle>());
      expect(
        PathStyle.remote(RemoteOs.linux, home: '/home/x'),
        isA<PosixPathStyle>(),
      );
      expect(PathStyle.remote(RemoteOs.other), isA<PosixPathStyle>());
      // Windows peer whose home is odd still stays Windows unless the server
      // shows a POSIX path with a Linux home.
      expect(
        PathStyle.remote(RemoteOs.windows, home: '/'),
        isA<SftpWindowsPathStyle>(),
      );
    });
  });

  group('LocalWindowsPathStyle (C:\\Users\\me)', () {
    const s = LocalWindowsPathStyle();

    test('normalize', () {
      expect(s.normalize('C:/Users/me/'), r'C:\Users\me');
      expect(s.normalize('c:'), r'C:\');
      expect(s.normalize(r'C:\'), r'C:\');
      expect(s.normalize(''), '');
    });

    test('parent of a drive root is the drive list', () {
      expect(s.parent(r'C:\Users'), r'C:\');
      expect(s.parent(r'C:\'), '');
      expect(s.parent(''), '');
      expect(s.isRoot(''), isTrue);
      expect(s.displayPath(''), 'This PC');
    });

    test('join and basename', () {
      expect(s.join(r'C:\Users', 'me'), r'C:\Users\me');
      expect(s.join('', 'D:'), r'D:\');
      expect(s.join(r'C:\Users', r'D:\x'), r'D:\x');
      expect(s.basename(r'C:\'), 'C:');
      expect(s.basename(r'C:\Users\me.txt'), 'me.txt');
    });

    test('breadcrumbs', () {
      expect(s.breadcrumbs(r'C:\Users\me'), const [
        PathCrumb('This PC', ''),
        PathCrumb('C:', r'C:\'),
        PathCrumb('Users', r'C:\Users'),
        PathCrumb('me', r'C:\Users\me'),
      ]);
    });

    test('isWithin', () {
      expect(s.isWithin(r'C:\Users', r'c:\users\me'), isTrue);
      expect(s.isWithin(r'C:\Users', r'C:\UsersX'), isFalse);
    });
  });
}
