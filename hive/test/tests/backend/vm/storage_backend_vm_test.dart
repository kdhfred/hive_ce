@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/backend/vm/read_write_sync.dart';
import 'package:hive_ce/src/backend/vm/storage_backend_vm.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:hive_ce/src/binary/frame.dart';
import 'package:hive_ce/src/io/frame_io_helper.dart';
import 'package:hive_ce/src/registry/type_registry_impl.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../common.dart';
import '../../frames.dart';
import '../../mocks.dart';

const testMap = {
  'SomeKey': 123,
  'AnotherKey': ['Just', 456, 'a', 333, 'List'],
  'Random Double list': [1.0, 2.0, 10.0, double.infinity],
  'Unicode:': '👋',
  'Null': null,
  'LastKey': true,
};

Uint8List getFrameBytes(Iterable<Frame> frames) {
  final writer = BinaryWriterImpl(testRegistry);
  for (final frame in frames) {
    writer.writeFrame(frame);
  }
  return writer.toBytes();
}

StorageBackendVm _getBackend({
  File? file,
  File? lockFile,
  bool crashRecovery = false,
  HiveCipher? cipher,
  FrameIoHelper? ioHelper,
  ReadWriteSync? sync,
  RandomAccessFile? readRaf,
  RandomAccessFile? writeRaf,
}) {
  final backend = StorageBackendVm.debug(
    file ?? MockFile(),
    lockFile ?? MockFile(),
    crashRecovery,
    cipher,
    ioHelper ?? MockFrameIoHelper(),
    sync ?? ReadWriteSync(),
  );
  if (readRaf != null) {
    backend.readRaf = readRaf;
  }
  if (writeRaf != null) {
    backend.writeRaf = writeRaf;
  }
  return backend;
}

void main() {
  setUpAll(() {
    registerFallbackValue(KeystoreFake());
    registerFallbackValue(TypeRegistryFake());
  });

  group('StorageBackendVm', () {
    test('.path returns path for of open box file', () {
      // This is a test
      // ignore: do_not_use_raw_paths
      final file = File('some/path');
      final backend = _getBackend(file: file);
      expect(backend.path, 'some/path');
    });

    test('.supportsCompaction is true', () {
      final backend = _getBackend();
      expect(backend.supportsCompaction, true);
    });

    group('.open()', () {
      test('readFile & writeFile', () async {
        final file = MockFile();
        final readRaf = MockRandomAccessFile();
        final writeRaf = MockRandomAccessFile();
        when(file.open).thenAnswer((i) => Future.value(readRaf));
        when(() => file.open(mode: FileMode.writeOnlyAppend))
            .thenAnswer((i) => Future.value(writeRaf));
        when(writeRaf.length).thenAnswer((_) => Future.value(0));

        final backend = _getBackend(file: file);
        await backend.open();
        expect(backend.readRaf, readRaf);
        expect(backend.writeRaf, writeRaf);
      });

      test('writeOffset', () async {
        final file = MockFile();
        final writeFile = MockRandomAccessFile();
        final readRaf = MockRandomAccessFile();
        when(() => file.open(mode: FileMode.writeOnlyAppend))
            .thenAnswer((i) => Future.value(writeFile));
        when(file.open).thenAnswer((i) => Future.value(readRaf));
        when(writeFile.length).thenAnswer((i) => Future.value(123));

        final backend = _getBackend(file: file);
        await backend.open();
        expect(backend.writeOffset, 123);
      });
    });

    group('.initialize()', () {
      File getLockFile() {
        final lockMockFile = MockFile();
        when(() => lockMockFile.open(mode: FileMode.write))
            .thenAnswer((i) => Future.value(MockRandomAccessFile()));
        return lockMockFile;
      }

      FrameIoHelper getFrameIoHelper(int recoveryOffset) {
        final helper = MockFrameIoHelper();
        when(
          () => helper.framesFromFile(
            any(),
            any(),
            any(),
            any(),
          ),
        ).thenAnswer((i) => Future.value(recoveryOffset));
        when(
          () => helper.keysFromFile(
            any(),
            any(),
            any(),
          ),
        ).thenAnswer((i) => Future.value(recoveryOffset));
        return helper;
      }

      void runTests(bool lazy) {
        test('opens lock file and acquires lock', () async {
          final lockFile = MockFile();
          final lockRaf = MockRandomAccessFile();
          when(() => lockFile.open(mode: FileMode.write))
              .thenAnswer((i) => Future.value(lockRaf));
          when(lockRaf.lock).thenAnswer((i) => Future.value(lockRaf));

          final backend = _getBackend(
            lockFile: lockFile,
            ioHelper: getFrameIoHelper(-1),
          );
          when(() => backend.path).thenReturn('nullPath');

          await backend.initialize(
            TypeRegistryImpl.nullImpl,
            MockKeystore(),
            lazy,
          );
          verify(lockRaf.lock);
        });

        test('recoveryOffset with crash recovery', () async {
          final writeRaf = MockRandomAccessFile();
          final lockFile = getLockFile();
          final lockRaf = MockRandomAccessFile();

          final backend = _getBackend(
            lockFile: lockFile,
            ioHelper: getFrameIoHelper(20),
            crashRecovery: true,
            writeRaf: writeRaf,
          );
          when(() => backend.path).thenReturn('nullPath');
          when(() => lockFile.open(mode: FileMode.write))
              .thenAnswer((i) => Future.value(lockRaf));
          when(lockRaf.lock).thenAnswer((i) => Future.value(lockRaf));
          when(() => writeRaf.truncate(20))
              .thenAnswer((i) => Future.value(writeRaf));
          when(() => writeRaf.setPosition(20))
              .thenAnswer((i) => Future.value(writeRaf));

          await backend.initialize(
            TypeRegistryImpl.nullImpl,
            MockKeystore(),
            lazy,
          );
          verify(() => writeRaf.truncate(20));
          verify(() => writeRaf.setPosition(20));
        });

        test('recoveryOffset without crash recovery', () async {
          final lockFile = getLockFile();
          final lockRaf = MockRandomAccessFile();

          final backend = _getBackend(
            lockFile: lockFile,
            ioHelper: getFrameIoHelper(20),
            crashRecovery: false,
          );
          when(() => backend.path).thenReturn('nullPath');
          when(() => lockFile.open(mode: FileMode.write))
              .thenAnswer((i) => Future.value(lockRaf));
          when(lockRaf.lock).thenAnswer((i) => Future.value(lockRaf));

          await expectLater(
            () => backend.initialize(
              TypeRegistryImpl.nullImpl,
              MockKeystore(),
              lazy,
            ),
            throwsHiveError(['corrupted']),
          );
        });
      }

      group('(not lazy)', () {
        runTests(false);
      });

      group('(lazy)', () {
        runTests(true);
      });
    });

    group('.readValue()', () {
      test('reads value with offset', () async {
        final frameBytes = getFrameBytes([Frame('test', 123)]);
        final readRaf = await getTempRaf([1, 2, 3, 4, 5, ...frameBytes]);

        final backend = _getBackend(readRaf: readRaf)
          // The registry needs to be initialized before reading values, and
          // because we do not call StorageBackendVM.initialize(), we set it
          // manually.
          ..registry = TypeRegistryImpl.nullImpl;
        final value = await backend.readValue(
          Frame('test', 123, length: frameBytes.length, offset: 5),
        );
        expect(value, 123);

        await readRaf.close();
      });

      test('throws exception when frame cannot be read', () async {
        final readRaf = await getTempRaf([1, 2, 3, 4, 5]);
        final backend = _getBackend(readRaf: readRaf)
          // The registry needs to be initialized before reading values, and
          // because we do not call StorageBackendVM.initialize(), we set it
          // manually.
          ..registry = TypeRegistryImpl.nullImpl;

        final frame = Frame('test', 123, length: frameBytes.length, offset: 0);
        await expectLater(
          () => backend.readValue(frame),
          throwsHiveError(['corrupted']),
        );

        await readRaf.close();
      });
    });

    group('.writeFrames()', () {
      test('writes bytes', () async {
        final frames = [Frame('key1', 'value'), Frame('key2', null)];
        final bytes = getFrameBytes(frames);

        final writeRaf = MockRandomAccessFile();
        when(() => writeRaf.setPosition(0))
            .thenAnswer((i) => Future.value(writeRaf));
        when(() => writeRaf.writeFrom(bytes))
            .thenAnswer((i) => Future.value(writeRaf));

        final backend = _getBackend(writeRaf: writeRaf)
          // The registry needs to be initialized before writing values, and
          // because we do not call StorageBackendVM.initialize(), we set it
          // manually.
          ..registry = TypeRegistryImpl.nullImpl;

        await backend.writeFrames(frames);
        verify(() => writeRaf.writeFrom(bytes));
      });

      test('updates offsets', () async {
        final frames = [Frame('key1', 'value'), Frame('key2', null)];

        final writeRaf = MockRandomAccessFile();
        when(() => writeRaf.setPosition(5))
            .thenAnswer((i) => Future.value(writeRaf));
        when(() => writeRaf.writeFrom(any()))
            .thenAnswer((i) => Future.value(writeRaf));

        final backend = _getBackend(writeRaf: writeRaf)
          // The registry needs to be initialized before writing values, and
          // because we do not call StorageBackendVM.initialize(), we set it
          // manually.
          ..registry = TypeRegistryImpl.nullImpl;
        backend.writeOffset = 5;

        await backend.writeFrames(frames);
        expect(frames, [
          Frame('key1', 'value', length: 24, offset: 5),
          Frame('key2', null, length: 15, offset: 29),
        ]);
        expect(backend.writeOffset, 44);
      });

      test('resets writeOffset on error', () async {
        final writeRaf = MockRandomAccessFile();
        when(() => writeRaf.writeFrom(any())).thenThrow('error');
        final backend = _getBackend(writeRaf: writeRaf)
          // The registry needs to be initialized before writing values, and
          // because we do not call StorageBackendVM.initialize(), we set it
          // manually.
          ..registry = TypeRegistryImpl.nullImpl;
        backend.writeOffset = 123;

        await expectLater(
          () => backend.writeFrames([Frame('key1', 'value')]),
          throwsA(anything),
        );
        verify(() => writeRaf.setPosition(123));
        expect(backend.writeOffset, 123);
      });
    });

    /*group('.compact()', () {
      //TODO improve this test
      test('check compaction', () async {
        var bytes = BytesBuilder();
        var comparisonBytes = BytesBuilder();
        var entries = <String, Frame>{};

        void addFrame(String key, dynamic val, [bool keep = false]) {
          var frameBytes = Frame(key, val).toBytes(null, null);
          if (keep) {
            entries[key] = Frame(key, val,
                length: frameBytes.length, offset: bytes.length);
            comparisonBytes.add(frameBytes);
          } else {
            entries.remove(key);
          }
          bytes.add(frameBytes);
        }

        for (var i = 0; i < 1000; i++) {
          for (var key in testMap.keys) {
            addFrame(key, testMap[key]);
            addFrame(key, null);
          }
        }

        for (var key in testMap.keys) {
          addFrame(key, 12345);
          addFrame(key, null);
          addFrame(key, 'This is a test');
          addFrame(key, testMap[key], true);
        }

        var boxFile = await getTempFile();
        await boxFile.writeAsBytes(bytes.toBytes());

        var syncedFile = SyncedFile(boxFile.path);
        await syncedFile.open();
        var backend = StorageBackendVm(syncedFile, null);

        await backend.compact(entries.values);

        var compactedBytes = await File(backend.path).readAsBytes();
        expect(compactedBytes, comparisonBytes.toBytes());

        await backend.close();
      });

      test('throws error if corrupted', () async {
        var bytes = BytesBuilder();
        var boxFile = await getTempFile(); 
        var syncedFile = SyncedFile(boxFile.path);
        await syncedFile.open();

        var box = BoxImplVm(
            HiveImpl(), path.basename(boxFile.path), BoxOptions(), syncedFile);
        await box.put('test', true);
        await box.put('test2', 'hello');
        await box.put('test', 'world');

        await syncedFile.truncate(await boxFile.length() - 1);

        expect(() => box.compact(), throwsHiveError(['unexpected eof']));
      });
    });*/

    test('.clear()', () async {
      final writeRaf = MockRandomAccessFile();
      when(() => writeRaf.truncate(0))
          .thenAnswer((i) => Future.value(writeRaf));
      when(() => writeRaf.setPosition(0))
          .thenAnswer((i) => Future.value(writeRaf));
      final backend = _getBackend(writeRaf: writeRaf);
      backend.writeOffset = 111;

      await backend.clear();
      verify(() => writeRaf.truncate(0));
      verify(() => writeRaf.setPosition(0));
      expect(backend.writeOffset, 0);
    });

    test('.close()', () async {
      final readRaf = MockRandomAccessFile();
      final writeRaf = MockRandomAccessFile();
      final lockRaf = MockRandomAccessFile();
      final lockFile = MockFile();

      returnFutureVoid(when(readRaf.close));
      returnFutureVoid(when(writeRaf.close));
      returnFutureVoid(when(lockRaf.close));
      when(lockFile.delete).thenAnswer((i) => Future.value(lockFile));

      final backend = _getBackend(
        lockFile: lockFile,
        readRaf: readRaf,
        writeRaf: writeRaf,
      );
      backend.lockRaf = lockRaf;

      await backend.close();
      verifyInOrder([
        readRaf.close,
        writeRaf.close,
        lockRaf.close,
        lockFile.delete,
      ]);
    });

    test('.deleteFromDisk()', () async {
      final readRaf = MockRandomAccessFile();
      final writeRaf = MockRandomAccessFile();
      final lockRaf = MockRandomAccessFile();
      final lockFile = MockFile();
      final file = MockFile();

      returnFutureVoid(when(readRaf.close));
      returnFutureVoid(when(writeRaf.close));
      returnFutureVoid(when(lockRaf.close));
      when(lockFile.delete).thenAnswer((i) => Future.value(lockFile));
      when(file.delete).thenAnswer((i) => Future.value(file));

      final backend = _getBackend(
        file: file,
        lockFile: lockFile,
        readRaf: readRaf,
        writeRaf: writeRaf,
      );
      backend.lockRaf = lockRaf;

      await backend.deleteFromDisk();
      verifyInOrder([
        readRaf.close,
        writeRaf.close,
        lockRaf.close,
        lockFile.delete,
        file.delete,
      ]);
    });
  });
}
