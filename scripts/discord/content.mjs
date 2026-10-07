// Les textes que le bot publie sur le serveur Discord. Ils vivent à part de
// provision.mjs pour se relire et se corriger sans toucher à la mécanique.

const REPO = 'https://github.com/Tsuky44/player';
// `tertiary` de design.md : la seule couleur d'accent de la marque.
const ACCENT = 0xadc6ff;

const mention = (id) => `<#${id}>`;
const role = (id) => `<@&${id}>`;
const block = (...lines) => ['```', ...lines, '```'].join('\n');

const SECRETS = '⚠️ Masque l’adresse de ton serveur, tes jetons et tes mots de passe dans les captures et les logs.';

export function rulesEmbeds(channels, roles) {
  return [
    {
      color: ACCENT,
      title: 'Bienvenue sur le Discord d’Onyx',
      description: [
        'Onyx est un serveur multimédia auto-hébergé et son application, pensés pour ta bibliothèque personnelle : Direct Play en priorité, un serveur léger, et un lecteur que tu règles comme tu veux.',
        '',
        'Le projet est en bêta. Ce serveur sert à s’entraider, remonter les bugs et discuter de la suite.',
      ].join('\n'),
    },
    {
      color: ACCENT,
      title: '📜 Règlement',
      description: [
        '**1. Reste respectueux.** Pas d’insulte, de harcèlement ni de propos discriminatoires. On critique le code, pas les personnes.',
        '',
        '**2. Pas de piratage.** Onyx lit ta bibliothèque personnelle. Pas de lien de téléchargement, de torrent ou de contenu protégé, et pas de demande d’accès au serveur de quelqu’un d’autre.',
        '',
        '**3. Protège tes accès.** Ne publie jamais d’adresse de serveur, de jeton, de mot de passe ou d’invitation à ton serveur Onyx. Masque-les dans tes captures et tes logs.',
        '',
        '**4. Poste au bon endroit.** Un sujet par post, et cherche avant d’en ouvrir un nouveau.',
        '',
        '**5. Pas de pub ni de spam.** Ni dans les salons, ni en message privé.',
        '',
        '**6. Le serveur est sur invitation.** Pour faire entrer quelqu’un, demande à l’équipe.',
        '',
        '**7. L’équipe a le dernier mot.** Les conditions d’utilisation et les règles de la communauté Discord s’appliquent aussi ici.',
      ].join('\n'),
    },
    {
      color: ACCENT,
      title: '🧭 Où aller',
      description: [
        `${mention(channels['annonces'])} et ${mention(channels['versions'])} : les nouvelles et les notes de version.`,
        `${mention(channels['aide'])} : un souci d’installation ou d’utilisation.`,
        `${mention(channels['bugs'])} : quelque chose ne marche pas comme prévu.`,
        `${mention(channels['suggestions'])} : une idée de fonctionnalité.`,
        `${mention(channels['développement'])} : le code et l’architecture.`,
        '',
        'Chaque forum commence par un post épinglé qui explique quoi écrire, avec un modèle à copier.',
        '',
        'Tu choisis tes plateformes et tes notifications dans **Salons et rôles**, en haut de la liste des salons.',
      ].join('\n'),
    },
    {
      color: ACCENT,
      title: '🛡️ L’équipe et les rôles',
      description: [
        `${role(roles['Créateur'])} : l’auteur d’Onyx.`,
        `${role(roles['Administrateur'])} : gère le serveur, ses salons et ses rôles.`,
        `${role(roles['Modérateur'])} : fait respecter le règlement, peut exclure et bannir.`,
        `${role(roles['Assistant'])} : range les salons, supprime les messages hors règlement et peut mettre en sourdine.`,
        '',
        `${role(roles['Contributeur'])}, ${role(roles['Membre fondateur'])} et ${role(roles['Bêta-testeur'])} sont attribués par l’équipe.`,
        '',
        'Un souci avec un message ou un membre ? Écris à un membre de l’équipe.',
      ].join('\n'),
    },
  ];
}

export function announcement(channels) {
  return {
    color: ACCENT,
    title: '🎬 Le Discord d’Onyx est ouvert',
    description: [
      'C’est ici que tu trouveras les annonces du projet.',
      '',
      `Commence par ${mention(channels['règlement'])}, puis passe dire bonjour dans ${mention(channels['général'])}.`,
      '',
      'Onyx est en bêta et tout y est gratuit aujourd’hui. Si tu installes un serveur pendant la bêta, tu gardes Onyx Premium à vie : c’est l’offre fondateur.',
    ].join('\n'),
  };
}

export function contributing() {
  return {
    color: ACCENT,
    title: '🔧 Contribuer à Onyx',
    description: [
      `Le code est sur [GitHub](${REPO}) : un serveur en Go et une application Flutter.`,
      '',
      'Onyx est en source disponible, sous licence PolyForm Noncommercial.',
      '',
      '**Avant une pull request**',
      `• Pour autre chose qu’une petite correction, ouvre d’abord une [issue](${REPO}/issues) pour en discuter.`,
      '• Un sujet par pull request, et la CI doit passer.',
      `• Accepte l’[accord de contribution](${REPO}/blob/main/CLA.md) en cochant la case dans la description de la pull request.`,
      '',
      `Le détail est dans [CONTRIBUTING.md](${REPO}/blob/main/CONTRIBUTING.md).`,
    ].join('\n'),
  };
}

// Le mode d'emploi épinglé en tête de chaque forum : quoi mettre dans un post,
// avec un modèle à copier.
export function forumGuides(channels) {
  return {
    aide: {
      title: '📌 À lire avant de demander de l’aide',
      embeds: [{
        color: ACCENT,
        title: '🆘 Comment demander de l’aide',
        description: [
          '**Avant de poster**',
          '• Cherche si la question a déjà une réponse dans ce forum.',
          '• Vérifie que ton serveur et ton application sont à jour.',
          '',
          '**Dans ton post**',
          '• Un titre qui décrit le souci : « Pas de son sur Apple TV avec un fichier DTS » plutôt que « Ça marche pas ».',
          '• L’étiquette de ta plateforme.',
          '• Une seule question par post.',
          '',
          '**Modèle à copier**',
          block(
            'Plateforme et version de l’app :',
            'Version du serveur et installation (Docker, NAS, autre) :',
            'Ce que je veux faire :',
            'Ce qui se passe :',
            'Ce que j’ai déjà essayé :',
          ),
          'La version de l’app se trouve dans Réglages → À propos.',
          '',
          SECRETS,
          '',
          'Quand c’est réglé, dis-le dans le post : l’équipe y mettra l’étiquette **Résolu**.',
        ].join('\n'),
      }],
    },
    bugs: {
      title: '📌 À lire avant de signaler un bug',
      embeds: [{
        color: ACCENT,
        title: '🐛 Comment signaler un bug',
        description: [
          '**Avant de poster**',
          '• Cherche si le bug est déjà signalé : ajoute ton cas dans le post existant plutôt que d’en ouvrir un autre.',
          `• Si tu n’es pas sûr que ce soit un bug, passe d’abord par ${mention(channels['aide'])}.`,
          '',
          '**Dans ton post**',
          '• Un bug par post, avec un titre précis.',
          '• L’étiquette de la plateforme touchée.',
          '• Une capture ou une courte vidéo si le problème se voit.',
          '',
          '**Modèle à copier**',
          block(
            'Plateforme et version de l’app :',
            'Version du serveur et installation (Docker, NAS, autre) :',
            'Étapes pour reproduire :',
            '1.',
            '2.',
            'Ce que j’attendais :',
            'Ce qui s’est passé :',
            'Fréquence : toujours / parfois / une seule fois',
            'Pour un souci de lecture, conteneur et codecs du fichier :',
          ),
          SECRETS,
          '',
          '**Ensuite**',
          '🔎 **Confirmé** : l’équipe a reproduit le bug, il est suivi sur GitHub.',
          '❓ **Besoin d’infos** : il manque de quoi le reproduire.',
          '✅ **Corrigé** : le correctif est dans une version publiée.',
        ].join('\n'),
      }],
    },
    suggestions: {
      title: '📌 À lire avant de proposer une idée',
      embeds: [{
        color: ACCENT,
        title: '💡 Comment proposer une idée',
        description: [
          '**Avant de poster**',
          '• Cherche si l’idée existe déjà : un 👍 sur le post d’origine compte plus qu’un doublon.',
          '',
          '**Dans ton post**',
          '• Une idée par post, avec un titre qui la résume : « Choisir la piste audio par défaut par série ».',
          '• Commence par le besoin, pas par la solution : ce que tu veux faire et pourquoi tu n’y arrives pas aujourd’hui.',
          '• L’étiquette de la partie concernée : Lecteur, Médiathèque, Serveur, Interface ou Hors ligne.',
          '',
          '**Modèle à copier**',
          block(
            'Le besoin :',
            'Ce que je fais aujourd’hui à la place :',
            'Ce que je propose :',
            'Plateformes concernées :',
          ),
          '**Ensuite**',
          'Les votes 👍 aident à choisir, mais ne décident pas seuls : Onyx doit rester léger.',
          '🗓️ **Prévu** : l’idée est retenue.',
          '✅ **Fait** : elle est dans une version publiée.',
          '🚫 **Écarté** : elle ne sera pas faite, avec la raison dans le post.',
        ].join('\n'),
      }],
    },
  };
}

export function betaFeedback(channels) {
  return {
    color: ACCENT,
    title: '📝 Comment faire un retour de bêta',
    description: [
      `Les versions de test sont annoncées dans ${mention(channels['annonces-bêta'])}, avec ce qu’il faut y vérifier.`,
      '',
      '**Modèle à copier**',
      block(
        'Version testée :',
        'Plateforme :',
        'Ce qui marche bien :',
        'Ce qui pose problème :',
      ),
      `Un bug précis et reproductible va plutôt dans ${mention(channels['bugs'])}, pour ne pas se perdre dans la discussion.`,
    ].join('\n'),
  };
}
