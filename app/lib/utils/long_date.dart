import '../l10n/tr.dart';

const _months = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre'
];

/// « 20 octobre 2026 », le mois traduit. L'app n'initialise pas les locales
/// d'intl, et une date longue ne justifie pas de le faire.
String formatLongDate(DateTime date) =>
    '${date.day} ${tr(_months[date.month - 1])} ${date.year}';
