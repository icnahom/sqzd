// ignore_for_file: avoid_print

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:native_assets_cli/native_assets_cli.dart';

void main(List<String> args) async {
  await build(args, (config, output) async {
    final assetDir = Directory('assets/models/vits-inflect-en-nano-v2');

    if (!assetDir.existsSync()) {
      assetDir.createSync(recursive: true);

      final modelUrl = Uri.parse(
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-inflect-en-nano-v2.tar.bz2',
      );
      final modelTarFile = File(
        'assets/models/vits-inflect-en-nano-v2-model.tar.bz2',
      );

      modelTarFile.parent.createSync(recursive: true);
      final request = await HttpClient().getUrl(modelUrl);
      final response = await request.close();
      await response.pipe(modelTarFile.openWrite());

      final bytes = modelTarFile.readAsBytesSync();
      final tarBytes = BZip2Decoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(tarBytes);

      // Detect + strip the archive's single top-level directory.
      final topLevelDirs = <String>{};
      for (final file in archive.where((f) => f.isFile)) {
        final parts = file.name.split('/').where((p) => p.isNotEmpty).toList();
        if (parts.length > 1) topLevelDirs.add(parts.first);
      }
      final hasTopLevel = topLevelDirs.length == 1;

      final fileList = <String>[];
      final espeakArchive = Archive();

      for (final file in archive.where((f) => f.isFile)) {
        final parts = file.name.split('/').where((p) => p.isNotEmpty).toList();
        if (parts.isEmpty) continue;

        final relParts = hasTopLevel ? parts.skip(1).toList() : parts;
        final relPath = relParts.join('/');
        if (relPath.isEmpty || relPath.split('/').last.startsWith('.')) {
          continue;
        }

        if (relPath.startsWith('espeak-ng-data/')) {
          espeakArchive.addFile(
            ArchiveFile(relPath, file.size, file.content as List<int>),
          );
          continue;
        }

        final outFile = File('${assetDir.path}/$relPath');
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(file.content as List<int>);
        fileList.add(relPath);
      }

      if (espeakArchive.isNotEmpty) {
        final tar = TarEncoder().encode(espeakArchive);
        final gz = GZipEncoder().encode(tar)!;
        File('${assetDir.path}/espeak-ng-data.tar.gz').writeAsBytesSync(gz);
        fileList.add('espeak-ng-data.tar.gz');
      }

      fileList.sort();
      File(
        '${assetDir.path}/filelist.txt',
      ).writeAsStringSync('${fileList.join('\n')}\n');

      modelTarFile.deleteSync();
      print('[Build Hook] VITS model ready');
    }
  });
}
