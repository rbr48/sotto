import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/call/ui/common.dart';
import 'package:sotto/core/ui_kit.dart';

void main() {
  test('initials leave out titles and the practice', () {
    expect(InitialsAvatar.initials('Dr Meera Rao'), 'MR');
    expect(InitialsAvatar.initials('Prof. Kim Lee'), 'KL');
    expect(InitialsAvatar.initials('Sara Okafor'), 'SO');
    expect(InitialsAvatar.initials('Madonna'), 'M');
    expect(InitialsAvatar.initials('Dr'), 'D', reason: 'only a title: keep it');
    expect(InitialsAvatar.initials(''), '?');
    expect(initialsOf('Dr Meera Rao (Rao Physiotherapy)'), 'MR');
  });
}
