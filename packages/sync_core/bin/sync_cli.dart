// Command-line client for the sync engine: for trying the protocol by hand
// and for the failure-injection harness. NOT for real secrets: the state
// file holds the sync key and device key in plain JSON. In the app these
// live inside the encrypted vault index.
//
//   dart run bin/sync_cli.dart init    --server URL [--invite CODE] --state me.json
//   dart run bin/sync_cli.dart backup  --state me.json FILE_OR_DIR...
//   dart run bin/sync_cli.dart restore --state me.json OUT_DIR
//   dart run bin/sync_cli.dart recover --server URL --account ID --secret HEX --state phone2.json
import 'dart:convert';
import 'dart:io';

import 'package:sync_core/sync_core.dart';

Never usage([String? why]) {
  if (why != null) stderr.writeln('error: $why\n');
  stderr.writeln('''usage:
  sync_cli init    --server URL [--invite CODE] --state FILE
  sync_cli backup  --state FILE PATH...
  sync_cli restore --state FILE OUT_DIR
  sync_cli recover --server URL --account ID --secret HEX --state FILE''');
  exit(64);
}

Future<void> main(List<String> argv) async {
  if (argv.isEmpty) usage();
  final cmd = argv.first;
  final opts = <String, String>{};
  final rest = <String>[];
  for (var i = 1; i < argv.length; i++) {
    final a = argv[i];
    if (a.startsWith('--')) {
      if (i + 1 >= argv.length) usage('$a needs a value');
      opts[a.substring(2)] = argv[++i];
    } else {
      rest.add(a);
    }
  }
  final statePath = opts['state'] ?? usage('--state is required');
  final stateFile = File(statePath);

  switch (cmd) {
    case 'init':
      final api = SyncApi(Uri.parse(opts['server'] ?? usage('--server is required')));
      final (id, secret) = await createAccount(api, invite: opts['invite']);
      await _save(stateFile, opts['server']!, id);
      stdout.writeln('account:          ${id.account}');
      stdout.writeln('device:           ${id.device}');
      stdout.writeln('recovery secret:  ${hex(secret)}');
      stdout.writeln('\nWrite the recovery secret down. It is the only way to restore on a new device,');
      stdout.writeln('and it is not stored anywhere. (The app will show it as 24 words.)');
      api.close();

    case 'recover':
      final api = SyncApi(Uri.parse(opts['server'] ?? usage('--server is required')));
      final id = await recoverAccess(
        api,
        opts['account'] ?? usage('--account is required'),
        unhex(opts['secret'] ?? usage('--secret is required')),
      );
      await _save(stateFile, opts['server']!, id);
      stdout.writeln('recovered; new device ${id.device}');
      api.close();

    case 'backup':
      if (rest.isEmpty) usage('nothing to back up');
      final (engine, api) = await _engine(stateFile);
      for (final path in rest) {
        final entity = FileSystemEntity.typeSync(path);
        final files = entity == FileSystemEntityType.directory
            ? Directory(path).listSync(recursive: true).whereType<File>().toList()
            : [File(path)];
        for (final f in files) {
          final name = f.uri.pathSegments.last;
          final r = await engine.backupFile(f, fileId: f.absolute.path, meta: {'title': name});
          stdout.writeln(r);
        }
      }
      api.close();

    case 'restore':
      if (rest.length != 1) usage('give exactly one output directory');
      final (engine, api) = await _engine(stateFile);
      final out = await engine.restoreAll(Directory(rest.single));
      for (final f in out) {
        stdout.writeln('restored ${f.path} (${await f.length()} bytes, verified)');
      }
      api.close();

    default:
      usage('unknown command $cmd');
  }
}

Future<void> _save(File f, String server, SyncIdentity id) async {
  await f.writeAsString(const JsonEncoder.withIndent('  ').convert({'server': server, 'identity': id.toJson()}));
}

Future<(SyncEngine, SyncApi)> _engine(File stateFile) async {
  if (!await stateFile.exists()) usage('no state file at ${stateFile.path}; run init first');
  final state = jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
  final id = SyncIdentity.fromJson(Map<String, dynamic>.from(state['identity'] as Map));
  final api = SyncApi(Uri.parse(state['server'] as String));
  await useIdentity(api, id);
  final engine = await SyncEngine.create(
    api: api,
    keys: await id.keys(),
    journal: FileJournalStore(File('${stateFile.path}.journal')),
  );
  return (engine, api);
}
