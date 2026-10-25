import 'dart:io';

// A real independent process using the production lock contract, without any
// Flutter runtime so the OS lock test does not depend on another UI engine.
Future<void> main(List<String> arguments) async {
  final lock = File('${arguments[0]}.owner.lock')
      .openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.exclusive);
  } on FileSystemException {
    lock.closeSync();
    stdout.writeln('BUSY');
    exitCode = 23;
    return;
  }
  stdout.writeln('HELD');
  await stdout.flush();
  if (arguments.length > 1 && arguments[1] == 'hold') {
    await stdin.first;
  }
  lock.unlockSync();
  lock.closeSync();
}
