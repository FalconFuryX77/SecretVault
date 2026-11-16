// Against a running server (the Docker stack, PostgreSQL): set SYNC_LIVE,
// e.g. SYNC_LIVE=http://127.0.0.1:8080 dart test test/live_server_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:http/io_client.dart';
import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

/// SYNC_LIVE_CA: a CA certificate to trust (e.g. Caddy's local CA when
/// testing docker-compose.public.yml on localhost).
SyncApi _api(String url) {
  final ca = Platform.environment['SYNC_LIVE_CA'];
  if (ca == null) return SyncApi(Uri.parse(url));
  final ctx = SecurityContext(withTrustedRoots: false)..setTrustedCertificates(ca);
  return SyncApi(Uri.parse(url), client: IOClient(HttpClient(context: ctx)));
}

void main() {
  final live = Platform.environment['SYNC_LIVE'];
  test('lookup, devices, revoke and closing an account on a live server', () async {
    final api = _api(live!);
    final (id, rs) = await createAccount(api, invite: Platform.environment['SYNC_INVITE']);
    expect(await findAccounts(api, rs), [id.account]);
    final id2 = await recoverAccess(api, id.account, rs);
    await revokeDevices(api, id.account, rs, [id2.device]);
    final a = _api(live);
    await useIdentity(a, id);
    final devices = {for (final d in await a.devices()) d.id: d.revoked};
    expect(devices[id2.device], isNotNull);
    final engine = await SyncEngine.create(api: a, keys: await id.keys(), journal: MemoryJournalStore());
    await engine.backupSource(MemorySyncSource(Uint8List.fromList([1, 2, 3])), fileId: 'f', meta: {'title': 'f'});
    expect(await engine.liveFiles(), hasLength(1));
    await closeAccount(api, id.account, rs);
    expect(await findAccounts(api, rs), isEmpty);
    api.close();
    a.close();
  }, skip: live == null ? 'set SYNC_LIVE to a server URL' : null);
}
