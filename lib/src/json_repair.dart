import 'package:flutter/foundation.dart';

enum _ContainerType { object, array }

enum _ObjectState {
  expectingKey,
  expectingColon,
  expectingValue,
  expectingCommaOrClose,
}

enum _ArrayState { expectingValue, expectingCommaOrClose }

class _StackFrame {
  final _ContainerType type;
  _ObjectState objectState;
  _ArrayState arrayState;
  int lastCompleteEntryEndPos;
  int lastCommaPos;

  _StackFrame.object(this.lastCompleteEntryEndPos)
      : type = _ContainerType.object,
        objectState = _ObjectState.expectingKey,
        arrayState = _ArrayState.expectingValue,
        lastCommaPos = -1;

  _StackFrame.array(this.lastCompleteEntryEndPos)
      : type = _ContainerType.array,
        objectState = _ObjectState.expectingKey,
        arrayState = _ArrayState.expectingValue,
        lastCommaPos = -1;
}

final _reJsonNumber = RegExp(r'^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$');

bool _isValidJsonLiteral(String token) {
  if (token == 'true' || token == 'false' || token == 'null') {
    return true;
  }
  return _reJsonNumber.hasMatch(token);
}

bool _isWhitespace(int codeUnit) {
  return codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;
}

bool _isDelimiterOrWhitespace(int codeUnit) {
  switch (codeUnit) {
    case 0x7B: // {
    case 0x7D: // }
    case 0x5B: // [
    case 0x5D: // ]
    case 0x3A: // :
    case 0x2C: // ,
    case 0x22: // "
    case 0x20: // space
    case 0x09: // \t
    case 0x0A: // \n
    case 0x0D: // \r
      return true;
    default:
      return false;
  }
}

/// Append-only string builder that supports cheap truncation.
///
/// Truncation drops whole trailing chunks and only slices the single chunk
/// that straddles the target length, so a rollback costs time proportional to
/// the removed portion rather than the whole output.
class _ChunkedBuffer {
  final List<String> _chunks = <String>[];
  int _length = 0;

  int get length => _length;

  void write(String s) {
    if (s.isEmpty) return;
    _chunks.add(s);
    _length += s.length;
  }

  void truncateTo(int targetLen) {
    if (_length <= targetLen) return;
    while (_chunks.isNotEmpty && _length - _chunks.last.length >= targetLen) {
      _length -= _chunks.removeLast().length;
    }
    if (_length > targetLen) {
      final last = _chunks.removeLast();
      final keep = last.length - (_length - targetLen);
      if (keep > 0) _chunks.add(last.substring(0, keep));
      _length = targetLen;
    }
  }

  @override
  String toString() => _chunks.join();
}

/// Repairs truncated or malformed JSON output by balancing braces,
/// completing unclosed quotes, rolling back dangling keys and colons,
/// and stripping trailing commas.
@visibleForTesting
String repairJson(String json) {
  if (json.isEmpty) return '';

  final stack = <_StackFrame>[];
  final output = _ChunkedBuffer();

  void truncateTo(int targetLen) => output.truncateTo(targetLen);

  void onValueCompleted(int endPos) {
    if (stack.isNotEmpty) {
      final top = stack.last;
      if (top.type == _ContainerType.object) {
        top.objectState = _ObjectState.expectingCommaOrClose;
        top.lastCompleteEntryEndPos = endPos;
      } else {
        top.arrayState = _ArrayState.expectingCommaOrClose;
        top.lastCompleteEntryEndPos = endPos;
      }
    }
  }

  var i = 0;
  while (i < json.length) {
    final codeUnit = json.codeUnitAt(i);

    if (_isWhitespace(codeUnit)) {
      final wsStart = i;
      i++;
      while (i < json.length && _isWhitespace(json.codeUnitAt(i))) {
        i++;
      }
      output.write(json.substring(wsStart, i));
      continue;
    }

    if (codeUnit == 0x22) {
      final stringStart = i;
      i++;
      var escape = false;
      var stringClosed = false;
      while (i < json.length) {
        final c = json.codeUnitAt(i);
        i++;
        if (escape) {
          escape = false;
        } else if (c == 0x5C) {
          escape = true;
        } else if (c == 0x22) {
          stringClosed = true;
          break;
        }
      }

      output.write(json.substring(stringStart, i));
      if (!stringClosed) {
        if (escape) {
          output.write(r'\');
        }
        output.write('"');
      }

      if (stack.isNotEmpty) {
        final top = stack.last;
        if (top.type == _ContainerType.object) {
          if (top.objectState == _ObjectState.expectingKey) {
            top.objectState = _ObjectState.expectingColon;
          } else if (top.objectState == _ObjectState.expectingValue) {
            top.objectState = _ObjectState.expectingCommaOrClose;
            top.lastCompleteEntryEndPos = output.length;
          }
        } else {
          if (top.arrayState == _ArrayState.expectingValue) {
            top.arrayState = _ArrayState.expectingCommaOrClose;
            top.lastCompleteEntryEndPos = output.length;
          }
        }
      }
      continue;
    }

    if (codeUnit == 0x7B) {
      output.write('{');
      i++;
      stack.add(_StackFrame.object(output.length));
      continue;
    }

    if (codeUnit == 0x5B) {
      output.write('[');
      i++;
      stack.add(_StackFrame.array(output.length));
      continue;
    }

    if (codeUnit == 0x3A) {
      output.write(':');
      i++;
      if (stack.isNotEmpty && stack.last.type == _ContainerType.object) {
        if (stack.last.objectState == _ObjectState.expectingColon) {
          stack.last.objectState = _ObjectState.expectingValue;
        }
      }
      continue;
    }

    if (codeUnit == 0x2C) {
      output.write(',');
      i++;
      if (stack.isNotEmpty) {
        final top = stack.last;
        top.lastCommaPos = output.length - 1;
        if (top.type == _ContainerType.object) {
          top.objectState = _ObjectState.expectingKey;
        } else {
          top.arrayState = _ArrayState.expectingValue;
        }
      }
      continue;
    }

    if (codeUnit == 0x7D) {
      while (stack.isNotEmpty && stack.last.type != _ContainerType.object) {
        final frame = stack.removeLast();
        if (frame.arrayState == _ArrayState.expectingValue) {
          truncateTo(frame.lastCompleteEntryEndPos);
        }
        output.write(']');
        if (stack.isNotEmpty) {
          onValueCompleted(output.length);
        }
      }

      if (stack.isNotEmpty && stack.last.type == _ContainerType.object) {
        final frame = stack.removeLast();
        if (frame.objectState != _ObjectState.expectingCommaOrClose) {
          truncateTo(frame.lastCompleteEntryEndPos);
        }
        output.write('}');
        i++;
        onValueCompleted(output.length);
      } else {
        output.write('}');
        i++;
      }
      continue;
    }

    if (codeUnit == 0x5D) {
      while (stack.isNotEmpty && stack.last.type == _ContainerType.object) {
        final frame = stack.removeLast();
        if (frame.objectState != _ObjectState.expectingCommaOrClose) {
          truncateTo(frame.lastCompleteEntryEndPos);
        }
        output.write('}');
        if (stack.isNotEmpty) {
          onValueCompleted(output.length);
        }
      }

      if (stack.isNotEmpty && stack.last.type == _ContainerType.array) {
        final frame = stack.removeLast();
        if (frame.arrayState == _ArrayState.expectingValue) {
          truncateTo(frame.lastCompleteEntryEndPos);
        }
        output.write(']');
        i++;
        onValueCompleted(output.length);
      } else {
        output.write(']');
        i++;
      }
      continue;
    }

    // Literals (numbers, boolean, null)
    final tokenStart = i;
    while (i < json.length && !_isDelimiterOrWhitespace(json.codeUnitAt(i))) {
      i++;
    }
    final token = json.substring(tokenStart, i);
    if (_isValidJsonLiteral(token)) {
      output.write(token);
      onValueCompleted(output.length);
    } else {
      if (stack.isNotEmpty) {
        truncateTo(stack.last.lastCompleteEntryEndPos);
      } else {
        truncateTo(0);
      }
    }
  }

  while (stack.isNotEmpty) {
    final frame = stack.removeLast();
    if (frame.type == _ContainerType.object) {
      if (frame.objectState != _ObjectState.expectingCommaOrClose) {
        truncateTo(frame.lastCompleteEntryEndPos);
      }
      output.write('}');
      if (stack.isNotEmpty) {
        onValueCompleted(output.length);
      }
    } else {
      if (frame.arrayState == _ArrayState.expectingValue) {
        truncateTo(frame.lastCompleteEntryEndPos);
      }
      output.write(']');
      if (stack.isNotEmpty) {
        onValueCompleted(output.length);
      }
    }
  }

  return output.toString();
}
