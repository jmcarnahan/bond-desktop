import 'dart:async';
import 'dart:typed_data';

import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/people_backend.dart';
import 'package:bond_inbox/services/profile_photos.dart';
import 'package:flutter/widgets.dart' show MemoryImage;
import 'package:flutter_test/flutter_test.dart';

/// The face cache, which exists to make a hundred avatars cost as few calls as
/// possible.
///
/// Three rules carry the whole file. A key is fetched ONCE however many
/// avatars ask for it. A null answer is remembered as hard as a picture,
/// because most senders have no photo and re-asking would spend the session
/// learning that. And the two failures are not the same: a missing scope stops
/// every later key, while a throttle leaves the key askable again — get that
/// backwards and either the app hammers a refusal or it draws initials forever
/// after one bad second.

/// A directory that answers from a script and counts what it was asked.
class _FakePeople implements PeopleBackend {
  /// Per key: what to do. A [ProfilePhoto] or null is answered; anything else
  /// is thrown. An unscripted key answers null.
  final Map<String, Object?> scripted;

  /// Keys whose call is held open until [release] is called.
  final Map<String, Completer<void>> held = {};

  final List<String> asked = [];
  final List<String> sizes = [];

  _FakePeople([this.scripted = const {}]);

  void hold(String key) => held[key] = Completer<void>();

  void release(String key) => held.remove(key)!.complete();

  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async =>
      const [];

  @override
  Future<ProfilePhoto?> profilePhoto(String user, {String size = '96x96'}) async {
    asked.add(user);
    sizes.add(size);
    final gate = held[user];
    if (gate != null) await gate.future;
    final answer = scripted[user];
    if (answer == null || answer is ProfilePhoto) return answer as ProfilePhoto?;
    throw answer;
  }
}

ProfilePhoto _photo([int byte = 1]) => ProfilePhoto(
      bytes: Uint8List.fromList([byte]),
      contentType: 'image/png',
    );

DirectoryProfilePhotos _photos(
  _FakePeople backend, {
  bool enabled = true,
  int maxInFlight = 4,
}) =>
    DirectoryProfilePhotos(
      backend,
      enabled: () async => enabled,
      maxInFlight: maxInFlight,
    );

void main() {
  group('the key', () {
    test('is the Graph id when there is one', () {
      expect(photoKeyFor(id: 'u-1', address: 'sarah@example.com'), 'u-1');
    });

    test('ignores an id this app invented and uses the address', () {
      // `mail:` ids are minted by Person.typed; there is no photo behind one.
      expect(
        photoKeyFor(id: 'mail:sarah@example.com', address: 'Sarah@Example.com'),
        'sarah@example.com',
      );
    });

    test('takes the Graph id out of a teams: address', () {
      // A stored Teams row spells the sender `teams:<id>`, and the id inside is
      // exactly what the photo endpoint looks people up by.
      expect(photoKeyFor(address: 'teams:u-9'), 'u-9');
    });

    test('lowercases and trims a mail address, so one person is one key', () {
      expect(photoKeyFor(address: '  Sarah@Example.com '), 'sarah@example.com');
    });

    test('is null when nothing usable was given', () {
      expect(photoKeyFor(), isNull);
      expect(photoKeyFor(id: '', address: '   '), isNull);
      expect(photoKeyFor(address: 'teams:'), isNull);
    });
  });

  group('the cache', () {
    test('asks nothing at all when photos are disabled', () async {
      final backend = _FakePeople({'u1': _photo()});

      expect(await _photos(backend, enabled: false).photoFor('u1'), isNull);
      expect(backend.asked, isEmpty);
    });

    test('fetches a key once however many avatars ask', () async {
      final backend = _FakePeople({'u1': _photo()});
      final photos = _photos(backend);

      final answers = await Future.wait([
        photos.photoFor('u1'),
        photos.photoFor('u1'),
        photos.photoFor('u1'),
      ]);

      expect(backend.asked, ['u1']);
      expect(answers.every((a) => a is MemoryImage), isTrue);
    });

    test('holds a picture, so the next paint needs no frame of initials',
        () async {
      final photos = _photos(_FakePeople({'u1': _photo(7)}));

      expect(photos.cached('u1'), isNull);
      final image = await photos.photoFor('u1');

      expect(image, isA<MemoryImage>());
      expect((image! as MemoryImage).bytes, [7]);
      expect(identical(photos.cached('u1'), image), isTrue);
    });

    test('remembers that somebody has no face, and stops asking', () async {
      // The common case: everyone outside the tenant. Re-asking would spend
      // the session learning the same nothing.
      final backend = _FakePeople(const {'u1': null});
      final photos = _photos(backend);

      expect(await photos.photoFor('u1'), isNull);
      expect(await photos.photoFor('u1'), isNull);
      expect(backend.asked, ['u1']);
    });

    test('asks at the size it was built with', () async {
      final backend = _FakePeople({'u1': _photo()});

      await DirectoryProfilePhotos(
        backend,
        enabled: () async => true,
        size: '240x240',
      ).photoFor('u1');

      expect(backend.sizes, ['240x240']);
    });

    test('the owner asks about themselves under the empty key', () async {
      final backend = _FakePeople({PeopleBackend.self: _photo()});

      expect(await _photos(backend).photoFor(PeopleBackend.self),
          isA<MemoryImage>());
      expect(backend.asked, ['']);
    });
  });

  group('failures', () {
    test('a missing scope stops every later key too', () async {
      final backend = _FakePeople({
        'u1': const DirectoryUnavailable(
          scopeMissing: true,
          message: 'no consent',
        ),
        'u2': _photo(),
      });
      final photos = _photos(backend);

      expect(await photos.photoFor('u1'), isNull);
      expect(await photos.photoFor('u2'), isNull);
      // One call for the whole session: the grant cannot change under it.
      expect(backend.asked, ['u1']);
    });

    test('a bad moment leaves the key askable again', () async {
      final backend = _FakePeople({
        'u1': const DirectoryUnavailable(scopeMissing: false, message: '429'),
      });
      final photos = _photos(backend);

      expect(await photos.photoFor('u1'), isNull);
      expect(photos.cached('u1'), isNull);
      backend.scripted['u1'] = _photo();

      expect(await photos.photoFor('u1'), isA<MemoryImage>());
      expect(backend.asked, ['u1', 'u1']);
    });

    test('an expired session is a bad moment, not a verdict', () async {
      // The avatar has nowhere to route a sign-in, so it draws initials — and
      // the key stays askable for after the user signs back in.
      final backend = _FakePeople({'u1': const ReconsentRequired()});
      final photos = _photos(backend);

      expect(await photos.photoFor('u1'), isNull);
      backend.scripted['u1'] = _photo();

      expect(await photos.photoFor('u1'), isA<MemoryImage>());
      expect(backend.asked, ['u1', 'u1']);
    });

    test('anything at all a backend throws is initials, never a throw',
        () async {
      final photos = _photos(_FakePeople({'u1': StateError('boom')}));

      expect(await photos.photoFor('u1'), isNull);
    });
  });

  group('the in-flight cap', () {
    test('never has more than its share of calls open', () async {
      final keys = ['u1', 'u2', 'u3', 'u4', 'u5', 'u6'];
      final backend = _FakePeople({for (final k in keys) k: _photo()});
      for (final key in keys) {
        backend.hold(key);
      }
      final photos = _photos(backend, maxInFlight: 2);

      final all = Future.wait([for (final key in keys) photos.photoFor(key)]);
      await Future<void>.delayed(Duration.zero);

      expect(backend.asked, ['u1', 'u2']);

      // Finishing one hands its slot straight to whoever waited longest.
      backend.release('u1');
      await Future<void>.delayed(Duration.zero);
      expect(backend.asked, ['u1', 'u2', 'u3']);

      for (final key in keys.skip(1)) {
        backend.release(key);
      }
      expect((await all).whereType<MemoryImage>(), hasLength(6));
    });
  });

  group('no photos at all', () {
    test('answers null and holds nothing', () async {
      const photos = NoProfilePhotos();

      expect(photos.cached('u1'), isNull);
      expect(await photos.photoFor('u1'), isNull);
    });
  });
}
