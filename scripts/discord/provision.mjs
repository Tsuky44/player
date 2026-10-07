#!/usr/bin/env node
// Monte le serveur Discord d'Onyx : rôles, salons, droits, AutoMod, onboarding
// et messages d'accueil.
//
// Le script est relançable : chaque objet est retrouvé par son nom puis mis à
// jour, jamais dupliqué. La structure du serveur vit donc ici, pas dans des
// clics impossibles à relire.
//
//   node scripts/discord/provision.mjs
//
// Le jeton du bot se lit dans DISCORD_BOT_TOKEN, sinon dans
// ~/.onyx/discord-bot-token.txt. Il ne doit jamais entrer dans le dépôt.
// DISCORD_GUILD_ID choisit le serveur si le bot en a rejoint plusieurs.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { announcement, betaFeedback, contributing, forumGuides, rulesEmbeds } from './content.mjs';

const API = 'https://discord.com/api/v10';
const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

const token = (
  process.env.DISCORD_BOT_TOKEN ??
  readFileSync(join(homedir(), '.onyx', 'discord-bot-token.txt'), 'utf8')
).trim();

async function api(method, path, body) {
  for (let attempt = 1; ; attempt++) {
    let res;
    try {
      res = await fetch(API + path, {
        method,
        headers: {
          Authorization: `Bot ${token}`,
          ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (err) {
      // La connexion à discord.com expire parfois sans raison ; chaque appel
      // étant rejouable, on réessaie avant d'abandonner.
      if (attempt >= 4) throw new Error(`${method} ${path} : ${err.cause?.message ?? err.message}`);
      await new Promise((r) => setTimeout(r, 1500 * attempt));
      continue;
    }
    if (res.status === 429) {
      const { retry_after: retryAfter } = await res.json();
      await new Promise((r) => setTimeout(r, retryAfter * 1000 + 100));
      continue;
    }
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${text}`);
    return text ? JSON.parse(text) : null;
  }
}

// --- Permissions -----------------------------------------------------------

const P = {
  CREATE_INVITE: 1n << 0n,
  KICK_MEMBERS: 1n << 1n,
  BAN_MEMBERS: 1n << 2n,
  ADMINISTRATOR: 1n << 3n,
  MANAGE_CHANNELS: 1n << 4n,
  MANAGE_GUILD: 1n << 5n,
  ADD_REACTIONS: 1n << 6n,
  VIEW_AUDIT_LOG: 1n << 7n,
  STREAM: 1n << 9n,
  VIEW_CHANNEL: 1n << 10n,
  SEND_MESSAGES: 1n << 11n,
  MANAGE_MESSAGES: 1n << 13n,
  EMBED_LINKS: 1n << 14n,
  ATTACH_FILES: 1n << 15n,
  READ_MESSAGE_HISTORY: 1n << 16n,
  MENTION_EVERYONE: 1n << 17n,
  USE_EXTERNAL_EMOJIS: 1n << 18n,
  CONNECT: 1n << 20n,
  SPEAK: 1n << 21n,
  MUTE_MEMBERS: 1n << 22n,
  DEAFEN_MEMBERS: 1n << 23n,
  MOVE_MEMBERS: 1n << 24n,
  USE_VAD: 1n << 25n,
  CHANGE_NICKNAME: 1n << 26n,
  MANAGE_NICKNAMES: 1n << 27n,
  MANAGE_ROLES: 1n << 28n,
  MANAGE_WEBHOOKS: 1n << 29n,
  MANAGE_EXPRESSIONS: 1n << 30n,
  USE_APPLICATION_COMMANDS: 1n << 31n,
  MANAGE_EVENTS: 1n << 33n,
  MANAGE_THREADS: 1n << 34n,
  CREATE_PUBLIC_THREADS: 1n << 35n,
  CREATE_PRIVATE_THREADS: 1n << 36n,
  USE_EXTERNAL_STICKERS: 1n << 37n,
  SEND_MESSAGES_IN_THREADS: 1n << 38n,
  MODERATE_MEMBERS: 1n << 40n,
  SEND_POLLS: 1n << 49n,
};

const bits = (...names) => names.reduce((acc, n) => acc | P[n], 0n);

// Le serveur est sur invitation : @everyone ne peut ni créer d'invitation ni
// mentionner tout le monde. Seule l'équipe invite.
const EVERYONE = bits(
  'VIEW_CHANNEL', 'SEND_MESSAGES', 'SEND_MESSAGES_IN_THREADS',
  'CREATE_PUBLIC_THREADS', 'EMBED_LINKS', 'ATTACH_FILES', 'ADD_REACTIONS',
  'USE_EXTERNAL_EMOJIS', 'USE_EXTERNAL_STICKERS', 'READ_MESSAGE_HISTORY',
  'CONNECT', 'SPEAK', 'STREAM', 'USE_VAD', 'USE_APPLICATION_COMMANDS',
  'CHANGE_NICKNAME', 'SEND_POLLS',
);

// Trois niveaux d'équipe, chacun contenant le précédent. L'assistant nettoie
// et met en sourdine ; exclure et bannir demande un modérateur ; toucher à la
// structure du serveur demande un administrateur.
const ASSISTANT = bits(
  'MANAGE_MESSAGES', 'MANAGE_THREADS', 'MODERATE_MEMBERS', 'MUTE_MEMBERS',
);

const MODERATOR = ASSISTANT | bits(
  'CREATE_INVITE', 'KICK_MEMBERS', 'BAN_MEMBERS', 'MANAGE_NICKNAMES',
  'VIEW_AUDIT_LOG', 'MENTION_EVERYONE', 'DEAFEN_MEMBERS', 'MOVE_MEMBERS',
);

const ADMIN = MODERATOR | bits(
  'MANAGE_GUILD', 'MANAGE_CHANNELS', 'MANAGE_ROLES', 'MANAGE_WEBHOOKS',
  'MANAGE_EXPRESSIONS', 'MANAGE_EVENTS',
);

// Toute l'équipe voit les salons privés ; seuls ces rôles écrivent dans les
// salons en lecture seule.
const STAFF = ['Administrateur', 'Modérateur', 'Assistant'];
const ANNOUNCERS = ['Administrateur', 'Modérateur'];

const WRITE = bits(
  'SEND_MESSAGES', 'SEND_MESSAGES_IN_THREADS', 'CREATE_PUBLIC_THREADS',
  'CREATE_PRIVATE_THREADS',
);

// --- Structure ---------------------------------------------------------------

const PLATFORMS = [
  { role: 'Auto-hébergeur', tag: 'Serveur', emoji: '🖥️', hint: "J'héberge mon propre serveur Onyx" },
  { role: 'Android', tag: 'Android', emoji: '🤖', hint: 'Téléphone ou tablette' },
  { role: 'Android TV', tag: 'Android TV', emoji: '📺', hint: 'Télé ou boîtier Android TV' },
  { role: 'iOS', tag: 'iOS', emoji: '📱', hint: 'iPhone ou iPad' },
  { role: 'Apple TV', tag: 'Apple TV', emoji: '🍎', hint: 'tvOS' },
  { role: 'macOS', tag: 'macOS', emoji: '💻', hint: 'Mac' },
  { role: 'Windows', tag: 'Windows', emoji: '🪟', hint: 'PC' },
  { role: 'Web', tag: 'Web', emoji: '🌐', hint: 'Dans le navigateur' },
];

// Du plus haut au plus bas dans la hiérarchie.
const ROLES = [
  { name: 'Créateur', icon: '👑', color: 0xe8e6e4, hoist: true, permissions: P.ADMINISTRATOR },
  { name: 'Administrateur', icon: '🛡️', color: 0xf28b82, hoist: true, permissions: ADMIN },
  { name: 'Modérateur', icon: '🔨', color: 0xadc6ff, hoist: true, permissions: MODERATOR },
  { name: 'Assistant', icon: '🧹', color: 0x8ad0e6, hoist: true, permissions: ASSISTANT },
  { name: 'Contributeur', icon: '🔧', color: 0x7fd1ae, hoist: true },
  { name: 'Membre fondateur', icon: '⭐', color: 0xe6c068, hoist: true },
  { name: 'Bêta-testeur', icon: '🧪', color: 0xc9a7f5, hoist: true },
  ...PLATFORMS.map((p) => ({ name: p.role, icon: p.emoji })),
  { name: 'Notif versions', icon: '🔔', mentionable: true },
];

const platformTags = PLATFORMS.map((p) => ({ name: p.tag, emoji_name: p.emoji }));
const staffTag = (name, emoji) => ({ name, emoji_name: emoji, moderated: true });
// Étiquette du post épinglé qui explique comment écrire dans le forum.
const GUIDE_TAG = 'À lire';
const guideTag = staffTag(GUIDE_TAG, '📌');

const TEXT = 0;
const VOICE = 2;
const NEWS = 5;
const CATEGORY = 4;
const FORUM = 15;
const REQUIRE_TAG = 1 << 4;

// access : 'public' | 'readonly' | liste des rôles qui voient le salon.
// writers (avec une liste de rôles) : les seuls à pouvoir y écrire.
const CATEGORIES = [
  {
    name: 'ACCUEIL', icon: '🏠',
    channels: [
      { name: 'règlement', icon: '📜', access: 'readonly', topic: 'Les règles du serveur. À lire avant de poster.' },
      { name: 'annonces', icon: '📣', type: NEWS, access: 'readonly', topic: "Les nouvelles importantes d'Onyx." },
      { name: 'versions', icon: '🚀', type: NEWS, access: 'readonly', topic: 'Les notes de chaque version, serveur et applications.' },
    ],
  },
  {
    name: 'COMMUNAUTÉ', icon: '💬',
    channels: [
      { name: 'général', icon: '💬', topic: "Discussion libre autour d'Onyx." },
      { name: 'vos-installations', icon: '🍿', topic: 'Montre ton installation : serveur, salon, écran.' },
      { name: 'hors-sujet', icon: '🎲', topic: 'Tout le reste, dans le respect du règlement.' },
    ],
  },
  {
    name: 'ENTRAIDE', icon: '🛟',
    channels: [
      {
        name: 'aide', icon: '🆘', type: FORUM, flags: REQUIRE_TAG, reaction: '👍',
        topic: "Une question par post. Indique ta plateforme, la version d'Onyx et ce que tu as déjà essayé. Masque les adresses de serveur, jetons et mots de passe dans tes captures et tes logs.",
        tags: [guideTag, ...platformTags, staffTag('Résolu', '✅')],
      },
      {
        name: 'bugs', icon: '🐛', type: FORUM, flags: REQUIRE_TAG, reaction: '🐛',
        topic: "Un bug par post. Donne la plateforme, la version d'Onyx, les étapes pour reproduire, ce que tu attendais et ce qui s'est passé. Ajoute les logs si tu les as, sans adresse de serveur ni jeton. Les bugs confirmés sont suivis sur GitHub.",
        tags: [guideTag, ...platformTags, staffTag('Confirmé', '🔎'), staffTag("Besoin d'infos", '❓'), staffTag('Corrigé', '✅')],
      },
      {
        name: 'suggestions', icon: '💡', type: FORUM, reaction: '👍',
        topic: "Une idée par post. Décris le besoin avant la solution. Vote avec 👍 sur les idées des autres plutôt que d'ouvrir un doublon.",
        tags: [
          guideTag,
          { name: 'Lecteur', emoji_name: '🎬' }, { name: 'Médiathèque', emoji_name: '📚' },
          { name: 'Serveur', emoji_name: '🖥️' }, { name: 'Interface', emoji_name: '🎨' },
          { name: 'Hors ligne', emoji_name: '📥' },
          staffTag('Prévu', '🗓️'), staffTag('Fait', '✅'), staffTag('Écarté', '🚫'),
        ],
      },
    ],
  },
  {
    name: 'BÊTA', icon: '🧪',
    access: ['Bêta-testeur', 'Membre fondateur', 'Contributeur'],
    channels: [
      { name: 'annonces-bêta', icon: '📢', writers: [], topic: 'Les versions de test et ce qu’il faut y vérifier.' },
      { name: 'retours-bêta', icon: '📝', topic: 'Tes retours sur les versions de test.' },
    ],
  },
  {
    name: 'FONDATEURS', icon: '⭐',
    access: ['Membre fondateur'],
    channels: [
      { name: 'salon-des-fondateurs', icon: '⭐', topic: "Le salon de celles et ceux qui ont installé un serveur pendant la bêta." },
    ],
  },
  {
    name: 'CONTRIBUTION', icon: '🔧',
    channels: [
      { name: 'développement', icon: '💻', topic: "Discussion technique : serveur Go, app Flutter, architecture." },
      { name: 'github', icon: '🐙', access: 'readonly', topic: "Le fil d'activité du dépôt." },
      { name: 'contributeurs', icon: '🤝', access: ['Contributeur'], topic: 'Coordination entre contributeurs.' },
    ],
  },
  {
    name: 'VOCAL', icon: '🔊',
    channels: [{ name: 'Général', icon: '🔊', type: VOICE }],
  },
  {
    name: 'ÉQUIPE', icon: '🔒',
    access: [],
    channels: [
      { name: 'équipe', icon: '🔒', topic: "Discussion interne de l'équipe." },
      { name: 'journal-modération', icon: '🚨', topic: "Alertes AutoMod et messages de Discord destinés à l'équipe." },
    ],
  },
];

// Les salons proposés d'office à l'arrivée. Discord en exige au moins sept,
// dont cinq où @everyone peut écrire.
const DEFAULT_CHANNELS = [
  'règlement', 'annonces', 'versions', 'général', 'vos-installations',
  'hors-sujet', 'aide', 'bugs', 'suggestions', 'développement',
];

// --- Provisioning ------------------------------------------------------------

// Le nom affiché porte une icône (« 💬・général », « 🔨 Modérateur ») ; c'est
// le nom nu qui identifie l'objet, pour qu'un changement d'icône renomme au
// lieu de créer un doublon.
const bare = (name) => name.replace(/^[^\p{L}\p{N}]+/u, '').toLowerCase();
const sameName = (a, b) => bare(a) === bare(b);
const roleLabel = (spec) => `${spec.icon} ${spec.name}`;
const channelLabel = (spec) =>
  spec.type === CATEGORY ? `${spec.icon} ${spec.name}` : `${spec.icon}・${spec.name}`;
// Un salon texte et un salon d'annonces se convertissent l'un en l'autre : ils
// comptent comme le même salon quand on le cherche par son nom.
const kind = (type) => (type === NEWS ? TEXT : type);

// L'icône de l'app, au format que l'API attend pour une image.
function logo() {
  const png = readFileSync(join(REPO_ROOT, 'app', 'web', 'icons', 'Icon-512.png'));
  return `data:image/png;base64,${png.toString('base64')}`;
}

async function findGuild() {
  const guilds = await api('GET', '/users/@me/guilds');
  const wanted = process.env.DISCORD_GUILD_ID;
  const guild = wanted ? guilds.find((g) => g.id === wanted) : guilds[0];
  if (!guild || (!wanted && guilds.length !== 1)) {
    throw new Error(
      `Le bot voit ${guilds.length} serveur(s) : précise DISCORD_GUILD_ID (${guilds.map((g) => `${g.id} ${g.name}`).join(', ')}).`,
    );
  }
  return api('GET', `/guilds/${guild.id}`);
}

async function ensureRoles(bot, guild) {
  const existing = await api('GET', `/guilds/${guild.id}/roles`);
  await api('PATCH', `/guilds/${guild.id}/roles/${guild.id}`, { permissions: EVERYONE.toString() });

  const ids = {};
  for (const spec of ROLES) {
    const body = {
      name: roleLabel(spec),
      color: spec.color ?? 0,
      hoist: spec.hoist ?? false,
      mentionable: spec.mentionable ?? false,
      permissions: (spec.permissions ?? 0n).toString(),
    };
    const found = existing.find((r) => !r.managed && sameName(r.name, spec.name));
    const role = found
      ? await api('PATCH', `/guilds/${guild.id}/roles/${found.id}`, body)
      : await api('POST', `/guilds/${guild.id}/roles`, body);
    ids[spec.name] = role.id;
  }

  // Les rôles neufs arrivent tous à la position 1, à égalité avec celui du
  // bot. Discord refuse (50013) de les ordonner si celui du bot n'est pas
  // renvoyé au-dessus dans la même requête.
  const own = existing.find((r) => r.tags?.bot_id === bot.id);
  await api('PATCH', `/guilds/${guild.id}/roles`, [
    { id: own.id, position: ROLES.length + 1 },
    ...ROLES.map((spec, i) => ({ id: ids[spec.name], position: ROLES.length - i })),
  ]);
  return ids;
}

function overwrites(guild, roles, access, writers) {
  // Plusieurs listes peuvent nommer le même rôle : on cumule par rôle, Discord
  // n'acceptant qu'une entrée par rôle et par salon.
  const byRole = new Map();
  const grant = (name, allow, deny = 0n) => {
    const id = name === '@everyone' ? guild.id : roles[name];
    const entry = byRole.get(id) ?? { allow: 0n, deny: 0n };
    byRole.set(id, { allow: entry.allow | allow, deny: entry.deny | deny });
  };
  if (access === 'readonly') {
    grant('@everyone', 0n, WRITE);
    for (const name of ANNOUNCERS) grant(name, WRITE);
  } else if (Array.isArray(access)) {
    grant('@everyone', 0n, P.VIEW_CHANNEL | (writers ? WRITE : 0n));
    for (const name of [...STAFF, ...access]) grant(name, P.VIEW_CHANNEL);
    for (const name of [...(writers ? ANNOUNCERS : []), ...(writers ?? [])]) grant(name, WRITE);
  }
  return [...byRole].map(([id, { allow, deny }]) => (
    { id, type: 0, allow: allow.toString(), deny: deny.toString() }
  ));
}

async function ensureChannel(guild, channels, spec, parentId, position) {
  const type = spec.type ?? TEXT;
  const found = channels.find(
    (c) => kind(c.type) === kind(type) && sameName(c.name, spec.name),
  );
  const body = {
    name: channelLabel({ ...spec, type }),
    type,
    position,
    permission_overwrites: spec.permission_overwrites,
    ...(parentId ? { parent_id: parentId } : {}),
    ...(spec.topic ? { topic: spec.topic } : {}),
  };
  if (type === FORUM) {
    // Reprendre l'identifiant des étiquettes existantes garde celles déjà
    // posées sur les posts ; sans lui, Discord les recrée et les détache.
    const known = found?.available_tags ?? [];
    body.available_tags = spec.tags.map((tag) => {
      const id = known.find((t) => t.name === tag.name)?.id;
      return { ...tag, ...(id ? { id } : {}) };
    });
    body.flags = spec.flags ?? 0;
    body.default_reaction_emoji = { emoji_name: spec.reaction };
    body.default_forum_layout = 1;
    body.default_sort_order = 0;
  }
  const channel = found
    ? await api('PATCH', `/channels/${found.id}`, body)
    : await api('POST', `/guilds/${guild.id}/channels`, body);
  if (!found) channels.push(channel);
  return channel;
}

// only : ne monte que les salons de ce nom, et jamais d'annonces ni de forum.
// Sert à créer les deux salons que le mode Communauté exige avant de l'activer.
async function ensureChannels(guild, roles, only) {
  const channels = await api('GET', `/guilds/${guild.id}/channels`);
  const ids = {};
  let position = 0;
  for (const [index, category] of CATEGORIES.entries()) {
    const wanted = category.channels.filter((c) => !only || only.includes(c.name));
    if (wanted.length === 0) continue;
    const parent = await ensureChannel(guild, channels, {
      name: category.name,
      icon: category.icon,
      type: CATEGORY,
      permission_overwrites: overwrites(guild, roles, category.access ?? 'public'),
    }, null, index);
    for (const spec of wanted) {
      const access = spec.access ?? category.access ?? 'public';
      const channel = await ensureChannel(guild, channels, {
        ...spec,
        type: only ? TEXT : spec.type,
        permission_overwrites: overwrites(guild, roles, access, spec.writers),
      }, parent.id, position++);
      ids[spec.name] = channel.id;
    }
  }

  if (!only) {
    // Les catégories vides laissées par la création du serveur n'ont plus de
    // raison d'être une fois leurs salons rangés ailleurs.
    const ours = new Set(CATEGORIES.map((c) => bare(c.name)));
    const fresh = await api('GET', `/guilds/${guild.id}/channels`);
    for (const c of fresh) {
      const empty = !fresh.some((child) => child.parent_id === c.id);
      if (c.type === CATEGORY && empty && !ours.has(bare(c.name))) {
        await api('DELETE', `/channels/${c.id}`);
        console.log(`  catégorie vide supprimée : ${c.name}`);
      }
    }
  }
  return ids;
}

async function configureGuild(guild, channels) {
  const body = {
    features: [...new Set([...guild.features, 'COMMUNITY'])],
    rules_channel_id: channels['règlement'],
    public_updates_channel_id: channels['journal-modération'],
    system_channel_id: channels['général'],
    // Garde le message d'arrivée, coupe les rappels de boost et les astuces.
    system_channel_flags: (1 << 1) | (1 << 2),
    verification_level: 2,
    explicit_content_filter: 2,
    default_message_notifications: 1,
    preferred_locale: 'fr',
    description: 'Onyx, ton cinéma privé : un serveur multimédia auto-hébergé et son application.',
  };
  if (!guild.icon) body.icon = logo();
  await api('PATCH', `/guilds/${guild.id}`, body);
}

async function ensureAutoMod(bot, guild, roles, channels) {
  const alert = { type: 2, metadata: { channel_id: channels['journal-modération'] } };
  const block = (message) => ({ type: 1, metadata: { custom_message: message } });
  // Discord n'accepte qu'une règle par type de déclencheur : c'est lui qui
  // sert de clé, pas le nom.
  const rules = [
    {
      name: 'Insultes graves et contenu sexuel',
      trigger_type: 4,
      trigger_metadata: { presets: [2, 3] },
      actions: [block('Ce message enfreint le règlement.'), alert],
    },
    {
      name: 'Spam',
      trigger_type: 3,
      actions: [block('Ce message ressemble à du spam.'), alert],
    },
    {
      name: 'Mentions en masse',
      trigger_type: 5,
      trigger_metadata: { mention_total_limit: 8, mention_raid_protection_enabled: true },
      actions: [block('Trop de mentions dans un seul message.'), alert, { type: 3, metadata: { duration_seconds: 600 } }],
    },
  ];
  const existing = await api('GET', `/guilds/${guild.id}/auto-moderation/rules`);
  for (const rule of rules) {
    const body = { ...rule, event_type: 1, enabled: true, exempt_roles: ['Créateur', ...STAFF].map((name) => roles[name]) };
    // Le mode Communauté affiche une règle « Block Mention Spam » par défaut
    // qui n'appartient pas au serveur : la modifier répond 404, il faut créer
    // la nôtre par-dessus. On ne met donc à jour que les règles du bot.
    const found = existing.find(
      (r) => r.trigger_type === rule.trigger_type && r.creator_id === bot.id,
    );
    if (found) await api('PATCH', `/guilds/${guild.id}/auto-moderation/rules/${found.id}`, body);
    else await api('POST', `/guilds/${guild.id}/auto-moderation/rules`, body);
  }
}

async function ensureOnboarding(guild, roles, channels) {
  const current = await api('GET', `/guilds/${guild.id}/onboarding`);
  // Discord demande un identifiant pour chaque question et chaque réponse,
  // même neuves : n'importe quel snowflake unique convient.
  let counter = 0n;
  const newId = () => (((BigInt(Date.now()) - 1420070400000n) << 22n) | counter++).toString();

  const prompts = [
    {
      title: 'Où utilises-tu Onyx ?',
      options: PLATFORMS.map((p) => ({
        title: p.role, description: p.hint, emoji_name: p.emoji, role_ids: [roles[p.role]], channel_ids: [],
      })),
    },
    {
      title: 'Veux-tu être prévenu des nouvelles versions ?',
      options: [{
        title: 'Oui, préviens-moi', description: 'Une mention à chaque version publiée', emoji_name: '🔔',
        role_ids: [roles['Notif versions']], channel_ids: [],
      }],
    },
  ].map((prompt) => {
    const known = current.prompts.find((p) => p.title === prompt.title);
    return {
      id: known?.id ?? newId(),
      type: 0,
      title: prompt.title,
      single_select: false,
      required: false,
      in_onboarding: true,
      options: prompt.options.map((option) => ({
        id: known?.options.find((o) => o.title === option.title)?.id ?? newId(),
        ...option,
      })),
    };
  });

  await api('PUT', `/guilds/${guild.id}/onboarding`, {
    prompts,
    default_channel_ids: DEFAULT_CHANNELS.map((name) => channels[name]),
    enabled: true,
    mode: 0,
  });
}

// Réécrit les messages du bot dans l'ordre plutôt que d'en poster de nouveaux.
async function ensureMessages(bot, channelId, messages, { pin = false } = {}) {
  const history = await api('GET', `/channels/${channelId}/messages?limit=50`);
  const mine = history.filter((m) => m.author.id === bot.id && m.type === 0).reverse();
  for (const [i, body] of messages.entries()) {
    const message = mine[i]
      ? await api('PATCH', `/channels/${channelId}/messages/${mine[i].id}`, body)
      : await api('POST', `/channels/${channelId}/messages`, body);
    if (pin && !message.pinned) await api('PUT', `/channels/${channelId}/pins/${message.id}`);
  }
  if (pin) {
    // Épingler laisse une ligne « a épinglé un message » qui n'apprend rien.
    const after = await api('GET', `/channels/${channelId}/messages?limit=50`);
    for (const m of after.filter((m) => m.author.id === bot.id && m.type === 6)) {
      await api('DELETE', `/channels/${channelId}/messages/${m.id}`);
    }
  }
}

// Un forum n'a pas de message d'en-tête : son mode d'emploi est un post du
// bot, épinglé et verrouillé. Il n'y en a qu'un par forum, ce qui permet de le
// retrouver sans se fier à son titre.
async function ensureForumGuide(bot, guild, forumId, guide) {
  const forum = await api('GET', `/channels/${forumId}`);
  const tag = forum.available_tags.find((t) => t.name === GUIDE_TAG).id;
  const { threads: active } = await api('GET', `/guilds/${guild.id}/threads/active`);
  const { threads: archived } = await api('GET', `/channels/${forumId}/threads/archived/public`);
  const found = [...active, ...archived].find(
    (t) => t.parent_id === forumId && t.owner_id === bot.id,
  );
  let threadId = found?.id;
  if (found) {
    // Un post archivé ou verrouillé refuse la modification de son message.
    await api('PATCH', `/channels/${threadId}`, { archived: false, locked: false });
    await api('PATCH', `/channels/${threadId}/messages/${threadId}`, { embeds: guide.embeds });
  } else {
    const thread = await api('POST', `/channels/${forumId}/threads`, {
      name: guide.title,
      auto_archive_duration: 10080,
      applied_tags: [tag],
      message: { embeds: guide.embeds },
    });
    threadId = thread.id;
  }
  await api('PATCH', `/channels/${threadId}`, {
    name: guide.title, applied_tags: [tag], locked: true, flags: 1 << 1,
  });
}

async function main() {
  const bot = await api('GET', '/users/@me');
  const guild = await findGuild();
  console.log(`Serveur : ${guild.name} (${guild.id})`);

  const step = async (label, run) => {
    process.stdout.write(`- ${label}… `);
    const result = await run();
    console.log('ok');
    return result;
  };

  // Discord limite les changements d'avatar à quelques-uns par heure : on ne
  // le pose que s'il manque, pour que relancer le script ne bute pas dessus.
  if (!bot.avatar) await step('avatar du bot', () => api('PATCH', '/users/@me', { avatar: logo() }));
  const roles = await step('rôles',() => ensureRoles(bot, guild));
  // Les salons d'annonces et les forums n'existent qu'en mode Communauté, et
  // ce mode exige d'abord un salon de règles et un salon pour l'équipe.
  const seed = await step('salons requis par le mode Communauté', () =>
    ensureChannels(guild, roles, ['règlement', 'journal-modération', 'général']));
  await step('réglages du serveur', () => configureGuild(guild, seed));
  const channels = await step('catégories et salons', () => ensureChannels(guild, roles));
  await step('AutoMod', () => ensureAutoMod(bot, guild, roles, channels));
  await step('onboarding', () => ensureOnboarding(guild, roles, channels));
  await step('messages', async () => {
    await ensureMessages(bot, channels['règlement'], [{ embeds: rulesEmbeds(channels, roles) }]);
    await ensureMessages(bot, channels['annonces'], [{ embeds: [announcement(channels)] }]);
    await ensureMessages(bot, channels['développement'], [{ embeds: [contributing()] }], { pin: true });
    await ensureMessages(bot, channels['retours-bêta'], [{ embeds: [betaFeedback(channels)] }], { pin: true });
  });
  await step('modes d’emploi des forums', async () => {
    for (const [name, guide] of Object.entries(forumGuides(channels))) {
      await ensureForumGuide(bot, guild, channels[name], guide);
    }
  });
  await step('rôle Créateur du propriétaire', () =>
    api('PUT', `/guilds/${guild.id}/members/${guild.owner_id}/roles/${roles['Créateur']}`));
}

main().catch((err) => {
  console.error(`\n${err.message}`);
  process.exit(1);
});
