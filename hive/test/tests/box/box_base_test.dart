import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/backend/storage_backend.dart';
import 'package:hive_ce/src/binary/frame.dart';
import 'package:hive_ce/src/box/box_base_impl.dart';

import 'package:hive_ce/src/box/change_notifier.dart';
import 'package:hive_ce/src/box/keystore.dart';
import 'package:hive_ce/src/hive_impl.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import '../common.dart';

import '../mocks.dart';

class _BoxBaseMock<E> extends BoxBaseImpl<E> with Mock {
  @override
  final lazy = false;

  _BoxBaseMock(
    super.hive,
    super.name,
    super.keyComparator,
    super.compactionStrategy,
    super.backend,
  );
}

_BoxBaseMock _openBoxBaseMock({
  HiveImpl? hive,
  String? name,
  Keystore? keystore,
  CompactionStrategy? cStrategy,
  StorageBackend? backend,
}) {
  hive ??= HiveImpl();
  name ??= 'testBox';
  backend ??= MockStorageBackend();
  final mock = _BoxBaseMock(
    hive,
    name,
    null,
    cStrategy ?? (_, __) => false,
    backend,
  );
  mock.keystore = keystore ?? Keystore(mock, ChangeNotifier(), null);
  return mock;
}

void main() {
  setUpAll(() {
    registerFallbackValue(KeystoreFake());
    registerFallbackValue(TypeRegistryFake());
  });

  group('BoxBase', () {
    test('.name', () {
      final box = _openBoxBaseMock(name: 'testName');
      expect(box.name, 'testName');
    });

    test('.path', () {
      final backend = MockStorageBackend();
      when(() => backend.path).thenReturn('some/path');

      final box = _openBoxBaseMock(backend: backend);
      expect(box.path, 'some/path');
    });

    group('.keys', () {
      test('returns keys from keystore', () {
        final box = _openBoxBaseMock();
        box.keystore
          ..insert(Frame.lazy('key1'))
          ..insert(Frame.lazy('key4'))
          ..insert(Frame.lazy('key2'));
        expect(box.keys, ['key1', 'key2', 'key4']);
      });

      test('throws if box is closed', () async {
        final backend = MockStorageBackend();
        returnFutureVoid(when(backend.close));

        final box = _openBoxBaseMock(backend: backend);
        await box.close();
        expect(() => box.keys, throwsHiveError(['closed']));
      });
    });

    group('.length / .isEmpty / .isNotEmpty', () {
      test('empty box', () {
        final box = _openBoxBaseMock();
        expect(box.length, 0);
        expect(box.isEmpty, true);
        expect(box.isNotEmpty, false);
      });

      test('non empty box', () {
        final keystore = Keystore.debug(
          frames: [
            Frame('key1', null),
            Frame('key2', null),
          ],
        );
        final box = _openBoxBaseMock(keystore: keystore);
        expect(box.length, 2);
        expect(box.isEmpty, false);
        expect(box.isNotEmpty, true);
      });

      test('throws if box is closed', () async {
        final backend = MockStorageBackend();
        returnFutureVoid(when(backend.close));

        final box = _openBoxBaseMock(backend: backend);
        await box.close();
        expect(() => box.length, throwsHiveError(['closed']));
        expect(() => box.isEmpty, throwsHiveError(['closed']));
        expect(() => box.isNotEmpty, throwsHiveError(['closed']));
      });
    });

    group('.watch()', () {
      test('calls keystore.watch()', () {
        final keystore = MockKeystore();
        final box = _openBoxBaseMock(keystore: keystore);
        when(() => keystore.watch(key: 123)).thenAnswer((_) => Stream.empty());

        box.watch(key: 123);
        verify(() => keystore.watch(key: 123));
      });

      test('throws if box is closed', () async {
        final backend = MockStorageBackend();
        returnFutureVoid(when(backend.close));

        final box = _openBoxBaseMock(backend: backend);
        await box.close();
        expect(box.watch, throwsHiveError(['closed']));
      });
    });

    group('.keyAt()', () {
      test('returns key at index', () {
        final box = _openBoxBaseMock();
        box.keystore
          ..insert(Frame.lazy(0))
          ..insert(Frame.lazy('test'));
        expect(box.keyAt(1), 'test');
      });

      test('throws if box is closed', () async {
        final backend = MockStorageBackend();
        returnFutureVoid(when(backend.close));

        final box = _openBoxBaseMock(backend: backend);
        await box.close();
        expect(() => box.keyAt(0), throwsHiveError(['closed']));
      });
    });

    test('.initialize()', () async {
      final backend = MockStorageBackend();
      final box = _openBoxBaseMock(backend: backend);

      when(() => backend.initialize(any(), any(), any())).thenAnswer((i) async {
        i.positionalArguments[1].insert(Frame('key1', 1));
      });

      await box.initialize();
      expect(box.keystore.frames, [Frame('key1', 1)]);
    });

    group('.containsKey()', () {
      test('returns true if key exists', () {
        final box = _openBoxBaseMock();
        box.keystore.insert(Frame.lazy('existingKey'));
        expect(box.containsKey('existingKey'), true);
      });

      test('returns false if key does not exist', () {
        final box = _openBoxBaseMock();
        box.keystore.insert(Frame.lazy('existingKey'));
        expect(box.containsKey('nonExistingKey'), false);
      });

      test('does not use backend', () {
        final backend = MockStorageBackend();
        final box = _openBoxBaseMock(backend: backend);
        box.keystore.insert(Frame.lazy('existingKey'));

        box.containsKey('existingKey');
        box.containsKey('nonExistingKey');
        verifyZeroInteractions(backend);
      });

      test('throws if box is closed', () async {
        final backend = MockStorageBackend();
        returnFutureVoid(when(backend.close));

        final box = _openBoxBaseMock(backend: backend);
        await box.close();
        expect(() => box.containsKey(0), throwsHiveError(['closed']));
      });
    });

    group('.add()', () {
      test('calls put()', () async {
        final box = _openBoxBaseMock();
        when(() => box.put(0, 123)).thenAnswer((i) => Future.value());

        expect(await box.add(123), 0);
        verify(() => box.put(0, 123));
      });

      test('updates auto increment', () async {
        final box = _openBoxBaseMock();
        returnFutureVoid(when(() => box.putAll({5: 123})));

        box.keystore.updateAutoIncrement(4);
        expect(await box.add(123), 5);
      });
    });

    test('.addAll()', () async {
      final box = _openBoxBaseMock();
      box.keystore.updateAutoIncrement(4);
      final vals = {5: 1, 6: 2, 7: 3};
      returnFutureVoid(when(() => box.putAll(vals)));

      expect(await box.addAll([1, 2, 3]), [5, 6, 7]);
      expect(box.keystore.autoIncrement(), 8);
      verify(() => box.putAll(vals));
    });

    group('.putAt()', () {
      test('override existing', () async {
        final box = _openBoxBaseMock();
        returnFutureVoid(when(() => box.putAll({'b': 'test'})));

        box.keystore.insert(Frame.lazy('a'));
        box.keystore.insert(Frame.lazy('b'));

        await box.putAt(1, 'test');
        verify(() => box.put('b', 'test'));
      });

      test('throws RangeError for negative index', () async {
        final box = _openBoxBaseMock();
        box.keystore.insert(Frame.lazy('a'));

        await expectLater(
          () async => await box.putAt(-1, 'test'),
          throwsRangeError,
        );
      });

      test('throws RangeError for index out of bounds', () async {
        final box = _openBoxBaseMock();
        box.keystore.insert(Frame.lazy('a'));

        await expectLater(
          () async => await box.putAt(1, 'test'),
          throwsRangeError,
        );
      });
    });

    group('.deleteAt()', () {
      test('delete frame', () async {
        final box = _openBoxBaseMock();
        returnFutureVoid(when(() => box.deleteAll(['b'])));

        box.keystore.insert(Frame.lazy('a'));
        box.keystore.insert(Frame.lazy('b'));

        await box.deleteAt(1);
        verify(() => box.delete('b'));
      });

      test('throws RangeError for negative index', () async {
        final box = _openBoxBaseMock();
        box.keystore.insert(Frame.lazy('a'));

        await expectLater(() async => await box.deleteAt(-1), throwsRangeError);
      });

      test('throws RangeError for index out of bounds', () async {
        final box = _openBoxBaseMock();
        box.keystore.insert(Frame.lazy('a'));

        await expectLater(() async => await box.deleteAt(1), throwsRangeError);
      });
    });

    group('.clear()', () {
      test('clears keystore and backend', () async {
        final backend = MockStorageBackend();
        final keystore = MockKeystore();

        returnFutureVoid(when(backend.clear));
        when(keystore.clear).thenReturn(2);

        final box = _openBoxBaseMock(backend: backend, keystore: keystore);

        expect(await box.clear(), 2);
        verifyInOrder([
          backend.clear,
          keystore.clear,
        ]);
      });

      test('throws if box is closed', () async {
        final backend = MockStorageBackend();
        returnFutureVoid(when(backend.close));

        final box = _openBoxBaseMock(backend: backend);
        await box.close();
        expect(box.clear, throwsHiveError(['closed']));
      });
    });

    group('.compact()', () {
      test('does nothing if backend does not support compaction', () async {
        final backend = MockStorageBackend();
        when(() => backend.supportsCompaction).thenReturn(false);
        final box = _openBoxBaseMock(backend: backend);

        await box.compact();
        verify(() => backend.supportsCompaction);
        verifyNoMoreInteractions(backend);
      });

      test('does nothing if there are no deleted entries', () async {
        final backend = MockStorageBackend();
        when(() => backend.supportsCompaction).thenReturn(true);
        final box = _openBoxBaseMock(backend: backend);
        box.keystore.insert(Frame.lazy('key1'));

        await box.compact();
        verify(() => backend.supportsCompaction);
        verifyNoMoreInteractions(backend);
      });

      test('compact', () async {
        final backend = MockStorageBackend();
        final keystore = MockKeystore();

        when(() => keystore.frames)
            .thenReturn([Frame('key', 1, length: 22, offset: 33)]);
        when(() => backend.supportsCompaction).thenReturn(true);
        // In case it is 0, we will bail out before compaction
        when(() => keystore.deletedEntries).thenReturn(1);
        returnFutureVoid(
          when(
            () => backend.compact([Frame('key', 1, length: 22, offset: 33)]),
          ),
        );

        final box = _openBoxBaseMock(backend: backend, keystore: keystore);

        await box.compact();
        verify(
          () => backend.compact([Frame('key', 1, length: 22, offset: 33)]),
        );
        verify(keystore.resetDeletedEntries);
      });

      test('throws if box is closed', () async {
        final backend = MockStorageBackend();
        returnFutureVoid(when(backend.close));

        final box = _openBoxBaseMock(backend: backend);
        await box.close();
        expect(box.compact, throwsHiveError(['closed']));
      });
    });

    test('.close()', () async {
      final hive = MockHiveImpl();
      final keystore = MockKeystore();
      final backend = MockStorageBackend();
      final box = _openBoxBaseMock(
        name: 'myBox',
        hive: hive,
        keystore: keystore,
        backend: backend,
      );
      returnFutureVoid(when(keystore.close));
      returnFutureVoid(when(backend.close));

      await box.close();
      verifyInOrder([
        keystore.close,
        () => hive.unregisterBox('myBox'),
        backend.close,
      ]);
      expect(box.isOpen, false);
    });

    group('.deleteFromDisk()', () {
      test('only deleted file if box is closed', () async {
        final backend = MockStorageBackend();
        final keystore = MockKeystore();
        final box = _openBoxBaseMock(backend: backend, keystore: keystore);
        returnFutureVoid(when(keystore.close));
        returnFutureVoid(when(backend.close));
        returnFutureVoid(when(backend.deleteFromDisk));

        await box.close();

        await box.deleteFromDisk();
        verify(backend.deleteFromDisk);
      });

      test('closes and deletes box', () async {
        final hive = MockHiveImpl();
        final keystore = MockKeystore();
        final backend = MockStorageBackend();
        final box = _openBoxBaseMock(
          name: 'myBox',
          hive: hive,
          keystore: keystore,
          backend: backend,
        );
        returnFutureVoid(when(keystore.close));
        returnFutureVoid(when(backend.close));
        returnFutureVoid(when(backend.deleteFromDisk));

        await box.deleteFromDisk();
        verifyInOrder([
          keystore.close,
          () => hive.unregisterBox('myBox'),
          backend.deleteFromDisk,
        ]);
        expect(box.isOpen, false);
      });
    });
  });
}
