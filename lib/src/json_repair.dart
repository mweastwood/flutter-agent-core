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

/// Repairs truncated or malformed JSON output by balancing braces,
/// completing unclosed quotes, rolling back dangling keys and colons,
/// and stripping trailing commas.
@visibleForTesting
String repairJson(String json) {
  if (json.isEmpty) return '';

  final stack = <_StackFrame>[];
  final output = StringBuffer();

  void truncateTo(int targetLen) {
    if (output.length > targetLen) {
      final current = output.toString().substring(0, targetLen);
      output.clear();
      output.write(current);
    }
  }

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
    final char = json[i];

    if (char == ' ' || char == '\t' || char == '\r' || char == '\n') {
      output.write(char);
      i++;
      continue;
    }

    if (char == '"') {
      output.write('"');
      i++;
      var escape = false;
      var stringClosed = false;
      while (i < json.length) {
        final strChar = json[i];
        output.write(strChar);
        i++;
        if (escape) {
          escape = false;
        } else if (strChar == r'\') {
          escape = true;
        } else if (strChar == '"') {
          stringClosed = true;
          break;
        }
      }

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

    if (char == '{') {
      output.write('{');
      i++;
      stack.add(_StackFrame.object(output.length));
      continue;
    }

    if (char == '[') {
      output.write('[');
      i++;
      stack.add(_StackFrame.array(output.length));
      continue;
    }

    if (char == ':') {
      output.write(':');
      i++;
      if (stack.isNotEmpty && stack.last.type == _ContainerType.object) {
        if (stack.last.objectState == _ObjectState.expectingColon) {
          stack.last.objectState = _ObjectState.expectingValue;
        }
      }
      continue;
    }

    if (char == ',') {
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

    if (char == '}') {
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

    if (char == ']') {
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
    while (i < json.length && !'{}[]:, \t\r\n"'.contains(json[i])) {
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
