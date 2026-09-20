// ignore_for_file: avoid_print

import 'dart:io';

import 'package:hooks/hooks.dart';

/// Build hook.
///
/// Downloads the VITS model archive at build time so it ships with the app
/// as an asset (declared in `pubspec.yaml`). The app extracts it on-device at
/// runtime (see `_initVitsModel` in `lib/main.dart`).
Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    final archiveFile = File.fromUri(input.packageRoot.resolve('assets/models/vits-inflect-en-nano-v2.tar.bz2'));

    // Once-check: only download if the archive isn't already present.
    if (!archiveFile.existsSync() || archiveFile.lengthSync() == 0) {
      final request = await HttpClient().getUrl(Uri.parse('https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-inflect-en-nano-v2.tar.bz2'));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException(
          'Failed to download VITS model: HTTP ${response.statusCode}',
        );
      }
      archiveFile.parent.createSync(recursive: true);
      await response.pipe(archiveFile.openWrite());
      print('[Build Hook] VITS model archive downloaded');
    }

    // Re-run the hook if the archive file changes.
    output.dependencies.add(archiveFile.uri);
  });
}
