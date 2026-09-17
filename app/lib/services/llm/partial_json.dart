/// Reads the STRING VALUES out of a JSON object while it is still arriving.
///
/// A streamed answer reaches this app as fragments of JSON text — `{"eviden`,
/// `ce":"Tom asks`, `s about Frid` — and a person waiting on a draft wants the
/// words, not the punctuation. [PartialJsonStrings] tracks just enough JSON
/// structure to say WHICH string each fragment belongs to, and hands back the
/// characters of that string as they complete.
///
/// Path-based and schema-agnostic on purpose. It knows nothing about
/// `draft_reply` — it reports `evidence`, `options[0].stance`,
/// `options[1].reply_body`, `reply_body`, whatever the object happens to
/// carry — so the same reader serves the cloud drafts of a later round without
/// a line changing. The caller decides which paths a person should see.
///
/// What it deliberately does NOT do: validate. The text it reads comes from a
/// grammar-constrained decoder, so the structure is already guaranteed, and a
/// reader that threw on an unexpected character would turn a whole visible
/// draft into a stack trace for the sake of a rule the server already enforces.
/// An unexpected character outside a string is ignored; a truncated tail —
/// mid-string, mid-escape, mid-number — is not an error, it is simply the part
/// that has not arrived yet.
library;

/// One frame of the structure the reader is standing inside.
class _Frame {
  _Frame.object()
      : isObject = true,
        index = 0;
  _Frame.array()
      : isObject = false,
        index = 0;

  final bool isObject;

  /// The key whose VALUE is being read, on an object frame.
  String key = '';

  /// Which element is being read, on an array frame.
  int index;

  /// True while the next string in an object frame would be a key rather than
  /// a value: right after `{`, and again after every `,`.
  bool expectKey = true;
}

/// Feeds JSON text in, gets string-value text out, tagged with its path.
class PartialJsonStrings {
  final List<_Frame> _stack = [];

  /// Inside a string literal.
  bool _inString = false;

  /// That string is a key, so nothing it holds is ever emitted.
  bool _isKey = false;

  /// The path of the value being read, resolved once when the string opens —
  /// the stack moves on as soon as it closes.
  String _path = '';

  /// The key being spelled out, and the value text not yet handed back.
  final StringBuffer _key = StringBuffer();
  final StringBuffer _value = StringBuffer();

  /// A `\` has been seen and its partner has not arrived yet.
  bool _escaped = false;

  /// The hex digits of a `\uXXXX` collected so far, or null when not in one.
  /// A chunk that ends after `\u12` leaves two digits here and continues
  /// correctly on the next.
  StringBuffer? _hex;

  /// A high surrogate held back until its low half arrives, so a delta never
  /// carries one half of an emoji. Emitted as it stands if what follows is not
  /// a low surrogate — Dart strings tolerate a lone unit, and dropping a
  /// character the model wrote would be worse.
  int? _highSurrogate;

  /// Feeds the next chunk and returns the string-value text that completed in
  /// it, as (path, delta) pairs in arrival order.
  ///
  /// Never throws, on any input.
  List<({String path, String delta})> feed(String chunk) {
    final out = <({String path, String delta})>[];
    for (var i = 0; i < chunk.length; i++) {
      final c = chunk[i];
      if (_inString) {
        _inStringChar(c, out);
      } else {
        _structuralChar(c);
      }
    }
    _flush(out);
    return out;
  }

  /// One character inside a string literal: an escape being assembled, the
  /// closing quote, or a character of the text itself.
  void _inStringChar(String c, List<({String path, String delta})> out) {
    final hex = _hex;
    if (hex != null) {
      hex.write(c);
      if (hex.length < 4) return;
      _hex = null;
      final unit = int.tryParse(hex.toString(), radix: 16);
      if (unit != null) _writeUnit(unit);
      return;
    }
    if (_escaped) {
      _escaped = false;
      switch (c) {
        case 'u':
          _hex = StringBuffer();
        case 'n':
          _write('\n');
        case 't':
          _write('\t');
        case 'r':
          _write('\r');
        case 'b':
          _write('\b');
        case 'f':
          _write('\f');
        // `\"`, `\\` and `\/` all stand for themselves.
        default:
          _write(c);
      }
      return;
    }
    switch (c) {
      case r'\':
        _escaped = true;
      case '"':
        // A held surrogate has nothing left to pair with.
        _releaseSurrogate();
        if (_isKey) {
          if (_stack.isNotEmpty) _stack.last.key = _key.toString();
          _key.clear();
        } else {
          // Emitted BEFORE the next string can open: the path belongs to this
          // string and the stack is about to move off it.
          _flush(out);
        }
        _inString = false;
      default:
        _write(c);
    }
  }

  /// One character outside a string: the braces, brackets and separators that
  /// say where the next string will sit. Everything else — numbers, `true`,
  /// `false`, `null`, whitespace — is structure the caller never sees, and is
  /// tracked only so the commas between them land on the right frame.
  void _structuralChar(String c) {
    switch (c) {
      case '{':
        _stack.add(_Frame.object());
      case '[':
        _stack.add(_Frame.array());
      case '}':
      case ']':
        if (_stack.isNotEmpty) _stack.removeLast();
      case ':':
        if (_stack.isNotEmpty) _stack.last.expectKey = false;
      case ',':
        if (_stack.isEmpty) return;
        final frame = _stack.last;
        if (frame.isObject) {
          frame.expectKey = true;
        } else {
          frame.index++;
        }
      case '"':
        final frame = _stack.isEmpty ? null : _stack.last;
        _isKey = frame != null && frame.isObject && frame.expectKey;
        _inString = true;
        if (!_isKey) _path = _pathFor();
    }
  }

  /// The dotted path of the value now being read: object keys joined with `.`,
  /// array positions as `[i]`.
  String _pathFor() {
    final path = StringBuffer();
    for (final frame in _stack) {
      if (frame.isObject) {
        if (path.isNotEmpty) path.write('.');
        path.write(frame.key);
      } else {
        path.write('[${frame.index}]');
      }
    }
    return path.toString();
  }

  /// One decoded UTF-16 code unit from a `\uXXXX` escape, with the surrogate
  /// pair held together across the chunk boundary that may split it.
  void _writeUnit(int unit) {
    final high = _highSurrogate;
    if (high != null && unit >= 0xDC00 && unit <= 0xDFFF) {
      _highSurrogate = null;
      _write(String.fromCharCodes([high, unit]));
      return;
    }
    _releaseSurrogate();
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      _highSurrogate = unit;
      return;
    }
    _write(String.fromCharCode(unit));
  }

  /// Lets go of a high surrogate that never found its partner.
  void _releaseSurrogate() {
    final high = _highSurrogate;
    if (high == null) return;
    _highSurrogate = null;
    _write(String.fromCharCode(high));
  }

  void _write(String text) {
    // A plain character after an unpaired high surrogate: the pair is not
    // coming, so the half that was held goes out first and in order.
    if (_highSurrogate != null) _releaseSurrogate();
    (_isKey ? _key : _value).write(text);
  }

  /// Hands back whatever value text has accumulated, under the path it was
  /// read at. A no-op when there is nothing — which is every chunk that
  /// carried only structure.
  void _flush(List<({String path, String delta})> out) {
    if (_value.isEmpty) return;
    out.add((path: _path, delta: _value.toString()));
    _value.clear();
  }
}
