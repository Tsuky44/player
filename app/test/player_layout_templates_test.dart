import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/player_layout.dart';
import 'package:onyx/models/player_layout_templates.dart';

void main() {
  test('prefab templates all satisfy CORE roles', () {
    expect(PlayerLayoutTemplates.all, hasLength(6));
    for (final t in PlayerLayoutTemplates.all) {
      final config = t.buildValidated();
      expect(
        config.satisfiesCoreRoles,
        isTrue,
        reason: '${t.name} missing ${config.missingCoreRoles()}',
      );
    }
  });

  test('net uses the flat skin and doux the neumorphic skin', () {
    expect(PlayerLayoutTemplates.net().skin, ControlSkinStyle.flat);
    expect(PlayerLayoutTemplates.doux().skin, ControlSkinStyle.neumorphic);
  });

  test('net and doux expose control sets distinct from the other templates', () {
    final signatures = {
      for (final t in PlayerLayoutTemplates.all)
        t.id: t.buildValidated().controls.map((c) => c.type).toSet(),
    };
    final net = signatures[PlayerTemplateId.net]!;
    final doux = signatures[PlayerTemplateId.doux]!;
    for (final entry in signatures.entries) {
      if (entry.key == PlayerTemplateId.net) continue;
      expect(net, isNot(equals(entry.value)),
          reason: 'net duplicates ${entry.key.name}\'s control set');
    }
    for (final entry in signatures.entries) {
      if (entry.key == PlayerTemplateId.doux) continue;
      expect(doux, isNot(equals(entry.value)),
          reason: 'doux duplicates ${entry.key.name}\'s control set');
    }
  });

  test('doux spaces its tightest pair of controls further apart than net', () {
    // The tightest (nearest-neighbour) gap anywhere in the layout is what
    // determines whether the neumorphic extrusion actually reads as
    // "breathing room" — a wide layout with one cramped corner still feels
    // cramped there, so we check the closest pair, not the overall average.
    double tightestGap(PlayerLayoutConfig config) {
      final points = config.controls
          .map((c) => Offset(c.config.xPercentage, c.config.yPercentage))
          .toList();
      if (points.length < 2) return double.infinity;
      var closest = double.infinity;
      for (var i = 0; i < points.length; i++) {
        for (var j = i + 1; j < points.length; j++) {
          closest = math.min(closest, (points[i] - points[j]).distance);
        }
      }
      return closest;
    }

    final net = tightestGap(PlayerLayoutTemplates.net());
    final doux = tightestGap(PlayerLayoutTemplates.doux());
    expect(doux, greaterThan(net));
  });

  test('series and pro expose extras beyond cinema', () {
    final cinema = PlayerLayoutTemplates.cinema().controls.length;
    final series = PlayerLayoutTemplates.series().controls.length;
    final pro = PlayerLayoutTemplates.pro().controls.length;
    expect(series, greaterThan(cinema));
    expect(pro, greaterThan(cinema));
  });

  test('cinema keeps compact relative sizes', () {
    final cinema = PlayerLayoutTemplates.cinema();
    for (final c in cinema.controls) {
      if (c.type.isProgressBar || c.type.isTimelineBar) continue;
      expect(
        c.config.sizePercentage,
        lessThanOrEqualTo(0.055),
        reason: '${c.id} too large for cinema',
      );
    }
    expect(cinema.hasControl(PlayerControlType.mute), isTrue);
  });

  test('skin field round-trips through encode/decode for every skin value', () {
    for (final skin in ControlSkinStyle.values) {
      final config = PlayerLayoutConfig.standard().copyWith(
        skin: skin,
        flatAccentColor: const Color(0xFFFF6B00),
        flatElevation: FlatElevation.marked,
        neumorphicIntensity: 0.8,
      );
      final decoded = PlayerLayoutConfig.decode(config.encode());
      expect(decoded.skin, skin);
      expect(decoded.flatAccentColor, const Color(0xFFFF6B00));
      expect(decoded.flatElevation, FlatElevation.marked);
      expect(decoded.neumorphicIntensity, 0.8);
    }
  });

  test('decoding a config without a skin key defaults to glass', () {
    final legacyJson = PlayerLayoutConfig.standard().toJson()..remove('skin');
    final decoded = PlayerLayoutConfig.fromJson(legacyJson);
    expect(decoded.skin, ControlSkinStyle.glass);
  });

  test('modularControlPixelSize clamps across phone desktop TV', () {
    expect(
      modularControlPixelSize(const Size(390, 844), 0.04),
      inInclusiveRange(36, 50),
    );
    final desk = modularControlPixelSize(const Size(1280, 720), 0.08);
    expect(desk, lessThanOrEqualTo(44));
    final tv = modularControlPixelSize(const Size(1920, 1080), 0.10);
    expect(tv, lessThanOrEqualTo(52));
  });
}
