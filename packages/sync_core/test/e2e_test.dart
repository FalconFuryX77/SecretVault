// End to end against the real server (python + uvicorn) and a flaky TCP
// proxy that cuts connections mid-stream. No Docker needed.
//
// Run:  dart test test/e2e_test.dart   (needs `pip install -r ../../server/requirements.txt`)
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

final serverDir = Directory('../../server').absolute.path;

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<void> waitHttp(Uri url) async {
  final c = HttpClient();
  for (var i = 0; i < 100; i++) {
    try {
      final r = await (await c.getUrl(url)).close();
      if (r.statusCode == 200) {
        c.close();
        return;
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('server did not start at $url');
}

Uint8List noise(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late Directory tmp;
  late Process server;
  late Uri direct;
  final proxies = <Process>[];

  Future<Uri> startProxy({double cutRate = 0, double kbps = 0, double up = 0, double down = 0, int seed = 1}) async {
    final port = await freePort();
    final p = await Process.start('python', [
      'harness/flaky_proxy.py',
      '--listen', '$port',
      '--upstream', '127.0.0.1:${direct.port}',
      '--cut-rate', '$cutRate',
      '--kbps', '$kbps',
      '--up', '$up',
      '--down', '$down',
      '--seed', '$seed',
    ], workingDirectory: serverDir);
    proxies.add(p);
    await p.stdout.transform(utf8.decoder).firstWhere((l) => l.contains('flaky proxy on'));
    return Uri.parse('http://127.0.0.1:$port');
  }

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('sync_e2e');
    final port = await freePort();
    server = await Process.start(
      'python',
      ['-m', 'uvicorn', 'app.main:create_app', '--factory', '--port', '$port', '--log-level', 'warning'],
      workingDirectory: serverDir,
      environment: {
        'SYNC_DB_URL': 'sqlite:///${tmp.path.replaceAll('\\', '/')}/sync.db',
        'SYNC_BLOB_DIR': '${tmp.path}/blobs',
        'SYNC_STAGING_DIR': '${tmp.path}/staging',
        'SYNC_APPEND_ONLY_DEFAULT': 'true',
      },
    );
    server.stderr.transform(utf8.decoder).listen((l) => stderr.write('[server] $l'));
    direct = Uri.parse('http://127.0.0.1:$port');
    await waitHttp(direct.resolve('/health'));
  });

  tearDownAll(() async {
    for (final p in proxies) {
      p.kill();
    }
    server.kill();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<(SyncIdentity, Uint8List)> newAccount() async {
    final api = SyncApi(direct);
    final r = await createAccount(api);
    api.close();
    return r;
  }

  Future<SyncEngine> engineFor(SyncIdentity id, Uri url, {JournalStore? journal}) async {
    final api = SyncApi(url, timeout: const Duration(seconds: 10));
    await useIdentity(api, id);
    return SyncEngine.create(
      api: api,
      keys: await id.keys(),
      journal: journal ?? MemoryJournalStore(),
      retry: const RetryPolicy(initialBackoff: Duration(milliseconds: 50), maxBackoff: Duration(milliseconds: 500)),
    );
  }

  Future<File> writeFile(String name, Uint8List data) async {
    final f = File('${tmp.path}/src/$name');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(data);
    return f;
  }

  test('backup through a link that cuts 30% of connections; restore on a new phone from the phrase alone', () async {
    final (id, phrase) = await newAccount();
    final flaky = await startProxy(cutRate: 0.3, seed: 3);
    final engine = await engineFor(id, flaky);

    final files = {
      'video.mp4': noise(3 * 1024 * 1024, 1),
      'notes.txt': Uint8List.fromList(utf8.encode('Source met at the bridge. ' * 40000)),
      'tiny.json': Uint8List.fromList(utf8.encode('{"k":1}')),
    };
    for (final MapEntry(key: name, value: data) in files.entries) {
      final r = await engine.backupFile(
        await writeFile(name, data),
        fileId: name,
        meta: {'title': name, 'mime': name.endsWith('.txt') ? 'text/plain' : 'application/octet-stream'},
      );
      print('[measure] $r');
    }

    // New phone: only the account id and the recovery secret.
    final api2 = SyncApi(direct);
    final id2 = await recoverAccess(api2, id.account, phrase);
    expect(id2.device, isNot(id.device));
    expect(id2.srk, id.srk);
    final engine2 = await engineFor(id2, direct);
    final restored = await engine2.restoreAll(Directory('${tmp.path}/restored'));
    expect(restored.length, files.length);
    for (final f in restored) {
      expect(await f.readAsBytes(), files[f.uri.pathSegments.last], reason: f.path);
    }
  });

  test('the same content is never uploaded twice (dedup), across files', () async {
    final (id, _) = await newAccount();
    final engine = await engineFor(id, direct);
    final data = noise(2 * 1024 * 1024, 9);
    final a = await engine.backupFile(await writeFile('a.bin', data), fileId: 'a', meta: {'title': 'a.bin'});
    final b = await engine.backupFile(await writeFile('b.bin', data), fileId: 'b', meta: {'title': 'b.bin'});
    print('[measure] first: $a');
    print('[measure] duplicate: $b');
    expect(a.piecesUploaded, a.piecesTotal);
    expect(b.piecesUploaded, 0);
    expect(b.wireBytes, lessThan(a.wireBytes ~/ 50));
  });

  test('pockets of signal: link up 2 s, down 3 s, 64 kB/s', () async {
    final (id, _) = await newAccount();
    final pocketLink = await startProxy(kbps: 512, up: 2, down: 3, seed: 5);
    final engine = await engineFor(id, pocketLink);
    final data = noise(1024 * 1024, 11);
    final r = await engine.backupFile(await writeFile('pocket.bin', data), fileId: 'p', meta: {'title': 'p.bin'});
    print('[measure] pockets: $r');
    // piecesUploaded can be lower than piecesTotal: a piece whose final
    // acknowledgement was lost was completed by the server, not re-sent.
    // The byte-for-byte restore below is the real check.
    final restored = await (await engineFor(id, direct)).restoreAll(Directory('${tmp.path}/pocket_out'));
    expect(await restored.single.readAsBytes(), data);
  });

  test('a lost acknowledgement on the log append is recovered, not duplicated', () async {
    final (id, _) = await newAccount();
    final journal = MemoryJournalStore();
    final engine = await engineFor(id, direct, journal: journal);
    await engine.backupFile(await writeFile('one.txt', noise(1000, 1)), fileId: 'one', meta: {'title': 'one.txt'});
    final before = Map<String, dynamic>.from(jsonDecode(jsonEncode(journal.data)) as Map);
    await engine.backupFile(await writeFile('two.txt', noise(1000, 2)), fileId: 'two', meta: {'title': 'two.txt'});
    // Simulate: the append for "two" reached the server, but the phone crashed
    // before saving its journal. It still thinks it's at the old position.
    journal.data['chain'] = before['chain'];
    (journal.data['jobs'] as Map)['two']['state'] = 'planned';
    await engine.backupFile(await writeFile('two.txt', noise(1000, 2)), fileId: 'two', meta: {'title': 'two.txt'});
    await engine.backupFile(await writeFile('three.txt', noise(1000, 3)), fileId: 'three', meta: {'title': 'three.txt'});

    final log = await engine.api.readLog();
    final bodies = await verifyLog(engine.sealer, log);
    final twos = bodies.expand((b) => b.ops).where((o) => o.file == 'two').length;
    expect(twos, 1, reason: 'the retried commit must not append a duplicate');
    expect(bodies.length, 3);
  });

  test('a server that tampers with a stored piece is caught on restore', () async {
    final (id, _) = await newAccount();
    final engine = await engineFor(id, direct);
    await engine.backupFile(await writeFile('t.bin', noise(300000, 4)), fileId: 't', meta: {'title': 't.bin'});
    final blobs = Directory('${tmp.path}/blobs/${id.account}');
    final victim = blobs.listSync(recursive: true).whereType<File>().where((f) => !f.path.contains('.tmp')).first;
    final bytes = await victim.readAsBytes();
    bytes[bytes.length ~/ 2] ^= 1;
    await victim.writeAsBytes(bytes);
    await expectLater(
      (await engineFor(id, direct)).restoreAll(Directory('${tmp.path}/tampered')),
      throwsA(isA<IntegrityException>()),
    );
  });

  test('a server that silently drops a log record is caught', () async {
    final (id, _) = await newAccount();
    final engine = await engineFor(id, direct);
    for (var i = 0; i < 3; i++) {
      await engine.backupFile(await writeFile('d$i.txt', noise(500, i)), fileId: 'd$i', meta: {'title': 'd$i.txt'});
    }
    final py = await Process.run('python', [
      '-c',
      'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); '
          'c.execute("delete from log where account_id=? and counter=2",(sys.argv[2],)); c.commit()',
      '${tmp.path}/sync.db',
      id.account,
    ]);
    expect(py.exitCode, 0, reason: '${py.stderr}');
    await expectLater(
      (await engineFor(id, direct)).restoreAll(Directory('${tmp.path}/dropped')),
      throwsA(isA<IntegrityException>()),
    );
  });
}
