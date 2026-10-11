/// The operating system on the other end, as paired. Decides defaults such as
/// SFTP path grammar and how "open a shell here" is spelled.
enum RemoteOs { linux, windows, other }

enum SessionTab { terminal, files, forwards }
