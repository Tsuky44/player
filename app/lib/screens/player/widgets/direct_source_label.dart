/// Le nom de la ligne « sans transcodage » dans les menus Qualité.
///
/// Sur un média téléchargé, cette ligne lit la copie du disque (voir
/// `_directPlaySource`) : l'appeler « Direct », comme un fichier tiré du
/// serveur, ne disait pas que rien ne passe par le réseau, ni pourquoi la
/// lecture tient sans connexion. Les deux menus passent par ici pour ne jamais
/// nommer la même source de deux façons.
///
/// [streamSubtitle] reste propre à chaque menu : leurs sous-titres n'ont pas
/// la même longueur.
({String label, String subtitle}) directSourceLabel({
  required bool local,
  String streamSubtitle = '',
}) =>
    local
        ? (label: 'Téléchargé', subtitle: 'Lu depuis cet appareil')
        : (label: 'Direct', subtitle: streamSubtitle);
