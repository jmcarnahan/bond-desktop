import 'dart:async';

import 'package:flutter/material.dart';

import '../services/profile_photos.dart';
import '../theme/tokens.dart';

/// Inbound avatar fills, picked from the existing token set rather than a new
/// one. Five is enough that adjacent senders rarely collide and few enough
/// that the transcript still reads as one palette.
const List<Color> _avatarPalette = [
  BondColors.primaryDeep,
  BondColors.attention,
  BondColors.success,
  BondColors.darkTileAlt,
  BondColors.channelVideo,
];

/// Two letters from a display name, one from an address, "?" from nothing.
/// Never throws on the half-empty senders a mailbox is full of.
String initialsFor(String? name, String? address) {
  final words = [
    for (final w in (name ?? '').split(RegExp(r'\s+')))
      if (w.isNotEmpty) w,
  ];
  if (words.length >= 2) {
    return '${words.first[0]}${words.last[0]}'.toUpperCase();
  }
  if (words.length == 1) return words.first[0].toUpperCase();

  final addr = (address ?? '').trim();
  if (addr.isNotEmpty) return addr[0].toUpperCase();
  return '?';
}

/// The avatar fill. Outbound is always the product's own primary — "this one
/// is you" should not depend on which address the account signs with. Everyone
/// else gets a stable color per address, so a sender looks the same in every
/// thread.
Color avatarColorFor(String? address, {required bool outbound}) {
  if (outbound) return BondColors.primary;
  final hash = (address ?? '').toLowerCase().hashCode;
  final index = hash.remainder(_avatarPalette.length).abs();
  return _avatarPalette[index];
}


/// One person's face: their photo when the directory has one, their initials
/// on a stable colour until then and whenever it does not.
///
/// Initials FIRST, always. A photo arrives a network call after the frame that
/// needed it, and a placeholder that were blank — or worse, a spinner — would
/// make a transcript flicker on every scroll. The disc is the real avatar; the
/// picture is an upgrade that lands on top of it, and nothing about the layout
/// moves when it does.
///
/// The widget asks [photos] itself rather than taking bytes from its parent
/// because the parent is a transcript that rebuilds on every sync: a fetch
/// owned up there would restart on each one, while a fetch owned here is
/// memoised by the service and asked once per key per session.
class BondAvatar extends StatefulWidget {
  final String? name;
  final String? address;

  /// Whether this is the account's own message. Only the fill depends on it —
  /// see [avatarColorFor].
  final bool outbound;

  final double size;

  /// The [ProfilePhotos] key for this person, from [photoKeyFor]. Null asks
  /// for nothing, which is the right answer for a face nothing could look up.
  final String? photoKey;

  final ProfilePhotos? photos;

  /// A face supplied outright, which WINS over [photos]. For a caller that
  /// already holds one — the account header, a test — and never fetches.
  final ImageProvider? photo;

  const BondAvatar({
    super.key,
    required this.name,
    this.address,
    this.outbound = false,
    this.size = 36,
    this.photoKey,
    this.photos,
    this.photo,
  });

  @override
  State<BondAvatar> createState() => _BondAvatarState();
}

class _BondAvatarState extends State<BondAvatar> {
  /// The face on screen, or null while there is only a disc. Seeded from what
  /// is already in hand so a photo the service has fetched before paints on
  /// the FIRST frame — scrolling back through a transcript must not re-flash
  /// initials at faces already seen.
  ImageProvider? _resolved;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(BondAvatar old) {
    super.didUpdateWidget(old);
    if (old.photoKey != widget.photoKey ||
        !identical(old.photos, widget.photos) ||
        !identical(old.photo, widget.photo)) {
      _resolved = null;
      _resolve();
    }
  }

  void _resolve() {
    final given = widget.photo;
    if (given != null) {
      _resolved = given;
      return;
    }

    final photos = widget.photos;
    final key = widget.photoKey;
    if (photos == null || key == null) return;

    _resolved = photos.cached(key);
    if (_resolved != null) return;

    // Unawaited on purpose: [ProfilePhotos.photoFor] never throws, and an
    // avatar that waited would be a hole in the frame.
    unawaited(photos.photoFor(key).then((image) {
      // The key is re-checked because a recycled row can be pointed at a
      // different person while this call is open.
      if (!mounted || image == null || key != widget.photoKey) return;
      setState(() => _resolved = image);
    }));
  }

  /// The initials' size. Pinned to [BondType.caption] at the transcript's 36px
  /// so that avatar is unchanged to the pixel, scaled from there for the
  /// smaller ones a typeahead row and a stack draw, and floored so a 20px face
  /// still says something.
  double get _fontSize {
    const reference = 36.0;
    final base = BondType.caption.fontSize ?? 12;
    final scaled = base * widget.size / reference;
    return scaled < 9 ? 9 : scaled;
  }

  Widget _initials() {
    return Container(
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: avatarColorFor(widget.address, outbound: widget.outbound),
      ),
      child: Text(
        initialsFor(widget.name, widget.address),
        style: BondType.caption.copyWith(
          color: BondColors.onDarkPrimary,
          fontWeight: FontWeight.w600,
          fontSize: _fontSize,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _resolved;
    if (image == null) return _initials();

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipOval(
        child: Image(
          image: image,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          // The bytes are already decoded by the time a second build asks for
          // them; without this the face blinks out and back on every rebuild.
          gaplessPlayback: true,
          // Bytes that will not decode are somebody's broken upload, not an
          // error this app has anything to say about.
          errorBuilder: (_, _, _) => _initials(),
        ),
      ),
    );
  }
}

/// One person in an [AvatarStack]. A record rather than a class: a stack is
/// built inline from rows a caller already holds, and a model for it would be
/// a type nothing else ever names.
typedef AvatarPerson = ({String name, String? address, String? photoKey});

/// Up to [max] overlapping faces, and a `+N` disc for everyone past them.
///
/// The overlap is what says "these people are one room" rather than "here are
/// some avatars in a row", and each face wears a ring in the surface colour so
/// the one under it still reads as a circle.
class AvatarStack extends StatelessWidget {
  final List<AvatarPerson> people;
  final int max;
  final double size;
  final ProfilePhotos? photos;

  const AvatarStack({
    super.key,
    required this.people,
    this.max = 3,
    this.size = 20,
    this.photos,
  });

  /// How far each face slides under the one before it.
  static const double _overlap = 0.3;

  /// The ring that separates two overlapping faces.
  static const double _ring = 1.5;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();

    final shown = people.take(max).toList();
    final rest = people.length - shown.length;
    final step = size * (1 - _overlap);

    final faces = <Widget>[
      for (final person in shown)
        _ringed(BondAvatar(
          name: person.name,
          address: person.address,
          size: size,
          photoKey: person.photoKey,
          photos: photos,
        )),
      if (rest > 0) _ringed(_overflow(rest)),
    ];

    return SizedBox(
      width: size + _ring * 2 + step * (faces.length - 1),
      height: size + _ring * 2,
      child: Stack(
        children: [
          for (var i = 0; i < faces.length; i++)
            Positioned(left: i * step, top: 0, child: faces[i]),
        ],
      ),
    );
  }

  Widget _ringed(Widget face) {
    return Container(
      padding: const EdgeInsets.all(_ring),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: BondColors.surface,
      ),
      child: face,
    );
  }

  Widget _overflow(int rest) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: BondColors.faintGround,
      ),
      child: Text(
        '+$rest',
        style: BondType.caption.copyWith(
          color: BondColors.inkSecondary,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.4 < 9 ? 9 : size * 0.4,
        ),
      ),
    );
  }
}
