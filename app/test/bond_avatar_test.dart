import 'dart:typed_data';

import 'package:bond_inbox/services/profile_photos.dart';
import 'package:bond_inbox/widgets/bond_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The avatar, whose whole job is to be right BEFORE the photo arrives.
///
/// What is pinned here is the order of things: initials first and always, a
/// picture on top of them only once it exists, and a face already in hand
/// painted on the very first frame — scrolling back through a transcript must
/// not re-flash initials at people the session has already seen.

/// A 1×1 transparent PNG. Real bytes rather than a stub because an
/// [ImageProvider] with nonsense in it logs a decode error the harness reports
/// as a failure.
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

/// A face service scripted per key, which records every key it was asked for.
class _FakePhotos implements ProfilePhotos {
  /// Keys that have a face. Everything else answers null.
  final Map<String, ImageProvider> images;

  /// Keys already in hand, so [cached] answers without a fetch.
  final Set<String> warm;

  final List<String> asked = [];

  _FakePhotos({this.images = const {}, this.warm = const {}});

  @override
  ImageProvider? cached(String key) => warm.contains(key) ? images[key] : null;

  @override
  Future<ImageProvider?> photoFor(String key) async {
    asked.add(key);
    return images[key];
  }
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('one face', () {
    testWidgets('is initials on a stable colour when there is no photo',
        (tester) async {
      await tester.pumpWidget(_host(const BondAvatar(
        name: 'Sarah Chen',
        address: 'sarah@example.com',
      )));

      expect(find.text('SC'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('draws a picture handed to it outright, and no initials',
        (tester) async {
      await tester.pumpWidget(_host(BondAvatar(
        name: 'Sarah Chen',
        address: 'sarah@example.com',
        photo: MemoryImage(_png),
      )));

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('SC'), findsNothing);
    });

    testWidgets('takes a fetched picture once it lands', (tester) async {
      final photos = _FakePhotos(images: {'u1': MemoryImage(_png)});

      await tester.pumpWidget(_host(BondAvatar(
        name: 'Sarah Chen',
        address: 'sarah@example.com',
        photoKey: 'u1',
        photos: photos,
      )));

      // The frame the widget was built on has initials; the picture is one
      // microtask behind it.
      expect(find.text('SC'), findsOneWidget);
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('SC'), findsNothing);
      expect(photos.asked, ['u1']);
    });

    testWidgets('paints a face already in hand on the first frame',
        (tester) async {
      final image = MemoryImage(_png);
      final photos = _FakePhotos(images: {'u1': image}, warm: const {'u1'});

      await tester.pumpWidget(_host(BondAvatar(
        name: 'Sarah Chen',
        photoKey: 'u1',
        photos: photos,
      )));

      expect(find.byType(Image), findsOneWidget);
      expect(
        identical(tester.widget<Image>(find.byType(Image)).image, image),
        isTrue,
      );
      // Nothing was fetched: it was already there.
      expect(photos.asked, isEmpty);
    });

    testWidgets('asks for nothing when there is no key', (tester) async {
      final photos = _FakePhotos(images: {'u1': MemoryImage(_png)});

      await tester.pumpWidget(_host(BondAvatar(
        name: 'Sarah Chen',
        address: 'sarah@example.com',
        photos: photos,
      )));
      await tester.pump();

      expect(photos.asked, isEmpty);
      expect(find.text('SC'), findsOneWidget);
    });

    testWidgets('follows the key onto a different person', (tester) async {
      // A recycled row can be pointed at somebody else between frames.
      final photos = _FakePhotos(images: {'u2': MemoryImage(_png)});

      await tester.pumpWidget(_host(BondAvatar(
        name: 'Sarah Chen',
        photoKey: 'u1',
        photos: photos,
      )));
      await tester.pump();
      expect(find.byType(Image), findsNothing);

      await tester.pumpWidget(_host(BondAvatar(
        name: 'Owen Park',
        photoKey: 'u2',
        photos: photos,
      )));
      await tester.pump();

      expect(photos.asked, ['u1', 'u2']);
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('a stack of faces', () {
    testWidgets('shows the first few and counts the rest', (tester) async {
      await tester.pumpWidget(_host(AvatarStack(
        people: const [
          (name: 'Sarah Chen', address: 'sarah@example.com', photoKey: null),
          (name: 'Owen Park', address: 'owen@example.com', photoKey: null),
          (name: 'Ana Reyes', address: 'ana@example.com', photoKey: null),
          (name: 'Ben Idris', address: 'ben@example.com', photoKey: null),
          (name: 'Kit Fry', address: 'kit@example.com', photoKey: null),
        ],
      )));

      expect(find.byType(BondAvatar), findsNWidgets(3));
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets('counts nothing when everybody fits', (tester) async {
      await tester.pumpWidget(_host(AvatarStack(
        people: const [
          (name: 'Sarah Chen', address: 'sarah@example.com', photoKey: null),
        ],
      )));

      expect(find.byType(BondAvatar), findsOneWidget);
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('draws nothing at all for nobody', (tester) async {
      await tester.pumpWidget(_host(const AvatarStack(people: [])));

      expect(find.byType(BondAvatar), findsNothing);
    });
  });
}
