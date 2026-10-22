import 'package:flutter/widgets.dart';

/// Un avatar de la galerie : une icône Phosphor pleine sur un dégradé.
class AvatarPreset {
  const AvatarPreset(this.key, this.icon, this.from, this.to);

  /// Ce que le serveur garde (`preset:<key>`). Ne se renomme jamais : un
  /// compte qui l'a choisi la porte déjà.
  final String key;
  final IconData icon;
  final Color from;
  final Color to;
}

// La variante pleine de Phosphor, embarquée comme celle d'AppIcons.
const _fill = 'PhosphorFill';

/// La galerie de « Qui regarde ? » (ADR-0078). Dessinée plutôt qu'en images :
/// elle tient dans la police déjà embarquée, s'affiche hors ligne, et reste
/// nette à toutes les tailles, de la pastille du menu à l'écran du salon.
///
/// Les dégradés sont les seules couleurs vives de l'interface, et réservés à
/// ces pastilles : c'est une personne qu'on reconnaît, pas un élément du
/// chrome. Une clé retirée d'ici retombe sur l'initiale chez qui l'avait.
abstract final class ProfileAvatars {
  static const gallery = <AvatarPreset>[
    AvatarPreset('cat', IconData(0xe748, fontFamily: _fill), Color(0xFFF59E0B),
        Color(0xFFB45309)),
    AvatarPreset('dog', IconData(0xe74a, fontFamily: _fill), Color(0xFF60A5FA),
        Color(0xFF1D4ED8)),
    AvatarPreset('rabbit', IconData(0xeac2, fontFamily: _fill),
        Color(0xFFF9A8D4), Color(0xFFBE185D)),
    AvatarPreset('bird', IconData(0xe72c, fontFamily: _fill), Color(0xFF34D399),
        Color(0xFF047857)),
    AvatarPreset('fish', IconData(0xe728, fontFamily: _fill), Color(0xFF22D3EE),
        Color(0xFF0E7490)),
    AvatarPreset('butterfly', IconData(0xea6e, fontFamily: _fill),
        Color(0xFFC084FC), Color(0xFF7E22CE)),
    AvatarPreset('rocket', IconData(0xe3fc, fontFamily: _fill),
        Color(0xFF818CF8), Color(0xFF3730A3)),
    AvatarPreset('alien', IconData(0xe8a6, fontFamily: _fill),
        Color(0xFFA3E635), Color(0xFF4D7C0F)),
    AvatarPreset('robot', IconData(0xe762, fontFamily: _fill),
        Color(0xFF94A3B8), Color(0xFF334155)),
    AvatarPreset('ghost', IconData(0xe62a, fontFamily: _fill),
        Color(0xFFA78BFA), Color(0xFF5B21B6)),
    AvatarPreset('planet', IconData(0xe652, fontFamily: _fill),
        Color(0xFFFB923C), Color(0xFFC2410C)),
    AvatarPreset('moon', IconData(0xe330, fontFamily: _fill), Color(0xFF6366F1),
        Color(0xFF1E1B4B)),
    AvatarPreset('sun', IconData(0xe472, fontFamily: _fill), Color(0xFFFDE047),
        Color(0xFFEA580C)),
    AvatarPreset('lightning', IconData(0xe2de, fontFamily: _fill),
        Color(0xFFFACC15), Color(0xFFA16207)),
    AvatarPreset('fire', IconData(0xe242, fontFamily: _fill), Color(0xFFF87171),
        Color(0xFFB91C1C)),
    AvatarPreset('flower', IconData(0xe75e, fontFamily: _fill),
        Color(0xFFF472B6), Color(0xFF9D174D)),
    AvatarPreset('cactus', IconData(0xe918, fontFamily: _fill),
        Color(0xFF4ADE80), Color(0xFF166534)),
    AvatarPreset('tree', IconData(0xe6da, fontFamily: _fill), Color(0xFF86EFAC),
        Color(0xFF15803D)),
    AvatarPreset('crown', IconData(0xe614, fontFamily: _fill),
        Color(0xFFFCD34D), Color(0xFFB45309)),
    AvatarPreset('game-controller', IconData(0xe26e, fontFamily: _fill),
        Color(0xFF2DD4BF), Color(0xFF115E59)),
    AvatarPreset('guitar', IconData(0xea8a, fontFamily: _fill),
        Color(0xFFFB7185), Color(0xFF9F1239)),
    AvatarPreset('popcorn', IconData(0xeb4e, fontFamily: _fill),
        Color(0xFFFCA5A5), Color(0xFFDC2626)),
    AvatarPreset('pizza', IconData(0xe796, fontFamily: _fill),
        Color(0xFFFDBA74), Color(0xFFC2410C)),
    AvatarPreset('ice-cream', IconData(0xe804, fontFamily: _fill),
        Color(0xFFFBCFE8), Color(0xFFDB2777)),
    AvatarPreset('soccer-ball', IconData(0xe716, fontFamily: _fill),
        Color(0xFFD9F99D), Color(0xFF3F6212)),
    AvatarPreset('basketball', IconData(0xe724, fontFamily: _fill),
        Color(0xFFFDBA74), Color(0xFF9A3412)),
    AvatarPreset('headphones', IconData(0xe2a6, fontFamily: _fill),
        Color(0xFF67E8F9), Color(0xFF155E75)),
    AvatarPreset('sunglasses', IconData(0xe816, fontFamily: _fill),
        Color(0xFF5EEAD4), Color(0xFF0F766E)),
    AvatarPreset('skull', IconData(0xe916, fontFamily: _fill),
        Color(0xFF71717A), Color(0xFF18181B)),
    AvatarPreset('heart', IconData(0xe2a8, fontFamily: _fill),
        Color(0xFFFDA4AF), Color(0xFFE11D48)),
  ];

  static AvatarPreset? byKey(String key) {
    for (final preset in gallery) {
      if (preset.key == key) return preset;
    }
    return null;
  }
}
