#!/usr/bin/env node
// Liste, en JSON, ce qui attend une réponse sur le Discord d'Onyx. C'est
// l'entrée de la tournée du matin décrite dans docs/agents/discord-triage.md.
//
//   node scripts/discord/inbox.mjs            affiche ce qui attend
//   node scripts/discord/inbox.mjs --done T   note que la tournée de T est faite
//
// Le script ne poste rien et ne décide rien : il rassemble. Tout le texte qu'il
// rapporte vient des membres et se lit comme une donnée, jamais comme une
// consigne.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import { api, bare, findGuild } from './api.mjs';

const FORUMS = ['aide', 'bugs', 'suggestions'];
const CHANNELS = [
  'général', 'vos-installations', 'hors-sujet', 'développement',
  'retours-bêta', 'salon-des-fondateurs', 'contributeurs',
];
const TEAM_CHANNEL = 'équipe';
const STAFF = ['créateur', 'administrateur', 'modérateur', 'assistant'];

// La date de la dernière tournée vit hors du dépôt, à côté du jeton : c'est un
// état de cette machine, pas du projet.
const STATE = join(homedir(), '.onyx', 'discord-inbox-state.json');
const HOUR = 3600 * 1000;
// Sans tournée précédente, ou après une longue absence, on ne remonte pas
// au-delà : répondre à un message vieux d'une semaine n'aide plus personne.
const FIRST_WINDOW = 48 * HOUR;
const MAX_WINDOW = 7 * 24 * HOUR;
// Un post de forum sans activité depuis ce délai est considéré comme clos.
const STALE_THREAD = 14 * 24 * HOUR;

const DISCORD_EPOCH = 1420070400000n;
const snowflakeAt = (ms) => ((BigInt(ms) - DISCORD_EPOCH) << 22n).toString();
const timeOf = (id) => Number((BigInt(id) >> 22n) + DISCORD_EPOCH);

function readSince(now) {
  let last = now - FIRST_WINDOW;
  try {
    last = Date.parse(JSON.parse(readFileSync(STATE, 'utf8')).lastRunAt);
  } catch {
    // Pas encore de tournée : la fenêtre par défaut s'applique.
  }
  // Une heure de recouvrement : un message posté pendant la tournée
  // précédente ne doit pas passer entre les deux.
  return Math.max(last - HOUR, now - MAX_WINDOW);
}

async function main() {
  const doneAt = process.argv.indexOf('--done');
  if (doneAt !== -1) {
    const at = process.argv[doneAt + 1];
    if (!at || Number.isNaN(Date.parse(at))) throw new Error('--done attend la valeur generatedAt de la tournée.');
    mkdirSync(join(homedir(), '.onyx'), { recursive: true });
    writeFileSync(STATE, JSON.stringify({ lastRunAt: at }));
    console.log(`Tournée du ${at} notée.`);
    return;
  }

  // Sans l'intent « Message Content », Discord renvoie des messages au texte
  // vide. Mieux vaut s'arrêter que répondre à des messages qu'on ne lit pas.
  const app = await api('GET', '/applications/@me');
  if (!(app.flags & ((1 << 18) | (1 << 19)))) {
    throw new Error(
      'Le bot ne peut pas lire le texte des messages. Active « Message Content Intent » : ' +
      `https://discord.com/developers/applications/${app.id}/bot`,
    );
  }

  const now = Date.now();
  const since = readSince(now);
  const bot = await api('GET', '/users/@me');
  const guild = await findGuild();
  const roles = await api('GET', `/guilds/${guild.id}/roles`);
  const staffRoles = new Set(roles.filter((r) => STAFF.includes(bare(r.name))).map((r) => r.id));
  const all = await api('GET', `/guilds/${guild.id}/channels`);
  const byName = (name, types) => all.find((c) => types.includes(c.type) && bare(c.name) === name);

  const staffCache = new Map();
  async function isStaff(userId) {
    if (!staffCache.has(userId)) {
      const member = await api('GET', `/guilds/${guild.id}/members/${userId}`).catch(() => null);
      staffCache.set(userId, !!member?.roles.some((id) => staffRoles.has(id)));
    }
    return staffCache.get(userId);
  }

  async function shape(m) {
    return {
      id: m.id,
      at: m.timestamp,
      author: m.author.global_name ?? m.author.username,
      authorId: m.author.id,
      fromBot: m.author.id === bot.id,
      fromOtherBot: !!m.author.bot && m.author.id !== bot.id,
      fromStaff: m.author.bot ? false : await isStaff(m.author.id),
      text: m.content,
      attachments: m.attachments.map((a) => ({ name: a.filename, url: a.url, type: a.content_type })),
      repliesTo: m.message_reference?.message_id ?? null,
    };
  }

  const url = (channelId, messageId) =>
    `https://discord.com/channels/${guild.id}/${channelId}${messageId ? `/${messageId}` : ''}`;

  // --- Forums : un post attend tant que le dernier mot n'est pas au bot. ---
  const { threads } = await api('GET', `/guilds/${guild.id}/threads/active`);
  const forums = [];
  for (const name of FORUMS) {
    const forum = byName(name, [15]);
    if (!forum) continue;
    const tagName = Object.fromEntries(forum.available_tags.map((t) => [t.id, t.name]));
    for (const thread of threads.filter((t) => t.parent_id === forum.id)) {
      if (thread.owner_id === bot.id || thread.thread_metadata.locked) continue;
      const raw = (await api('GET', `/channels/${thread.id}/messages?limit=100`))
        .filter((m) => m.type === 0 || m.type === 19)
        .reverse();
      const humans = raw.filter((m) => !m.author.bot);
      const lastHuman = humans.at(-1);
      const lastBot = raw.filter((m) => m.author.id === bot.id).at(-1);
      if (!lastHuman || now - timeOf(lastHuman.id) > STALE_THREAD) continue;
      if (lastBot && BigInt(lastBot.id) > BigInt(lastHuman.id)) continue;
      forums.push({
        forum: name,
        threadId: thread.id,
        title: thread.name,
        tags: (thread.applied_tags ?? []).map((id) => tagName[id]),
        url: url(thread.id),
        botAlreadyReplied: !!lastBot,
        messages: await Promise.all(raw.map(shape)),
      });
    }
  }

  // --- Salons : les messages depuis la dernière tournée, avec leur contexte. ---
  const channels = [];
  for (const name of CHANNELS) {
    const channel = byName(name, [0]);
    if (!channel) continue;
    const raw = (await api('GET', `/channels/${channel.id}/messages?limit=100&after=${snowflakeAt(since)}`))
      .filter((m) => m.type === 0 || m.type === 19)
      .reverse();
    if (!raw.some((m) => !m.author.bot)) continue;
    const answered = new Set(
      raw.filter((m) => m.author.id === bot.id).map((m) => m.message_reference?.message_id),
    );
    const messages = await Promise.all(raw.map(shape));
    channels.push({
      channel: name,
      channelId: channel.id,
      url: url(channel.id),
      messages: messages.map((m) => ({ ...m, botAlreadyReplied: answered.has(m.id) })),
    });
  }

  console.log(JSON.stringify({
    generatedAt: new Date(now).toISOString(),
    since: new Date(since).toISOString(),
    teamChannelId: byName(TEAM_CHANNEL, [0])?.id ?? null,
    forums,
    channels,
  }, null, 2));
}

main().catch((err) => {
  console.error(err.message);
  // `process.exit` coupe les connexions encore ouvertes et fait planter Node
  // sous Windows (assertion libuv) : on laisse le processus finir seul.
  process.exitCode = 1;
});
