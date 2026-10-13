#!/usr/bin/env node
// Poste un message du bot sur le Discord d'Onyx. C'est la seule sortie de la
// tournée du matin décrite dans docs/agents/discord-triage.md.
//
//   node scripts/discord/reply.mjs --channel <id> --file <texte.md>
//        [--reply-to <id du message>]   répond à un message précis
//        [--tag <étiquette>]            pose une étiquette sur un post de forum
//        [--team]                       note interne : pas de signature
//
// Le texte se lit dans un fichier et non sur la ligne de commande : une
// apostrophe ou un accent n'y survivent pas d'un shell à l'autre.

import { readFileSync } from 'node:fs';

import { api } from './api.mjs';

// Discord coupe à 2000 caractères ; la signature en prend une partie.
const LIMIT = 2000;
// `-#` est le petit texte grisé de Discord. Un membre doit savoir qu'il lit
// une réponse automatique et qu'un humain peut la corriger.
const SIGNATURE = '\n-# Réponse automatique du bot Onyx. L’équipe repasse si besoin.';

function args() {
  const out = { tags: [] };
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === '--team') out.team = true;
    else if (flag === '--tag') out.tags.push(argv[++i]);
    else if (flag === '--channel') out.channel = argv[++i];
    else if (flag === '--file') out.file = argv[++i];
    else if (flag === '--reply-to') out.replyTo = argv[++i];
    else throw new Error(`Option inconnue : ${flag}`);
  }
  if (!out.channel || !out.file) throw new Error('--channel et --file sont obligatoires.');
  return out;
}

async function main() {
  const opts = args();
  const content = readFileSync(opts.file, 'utf8').trim() + (opts.team ? '' : SIGNATURE);
  if (content.length > LIMIT) {
    throw new Error(`Message trop long : ${content.length} caractères pour ${LIMIT}. Raccourcis-le.`);
  }

  const message = await api('POST', `/channels/${opts.channel}/messages`, {
    content,
    // Le texte peut citer un membre : rien ne doit notifier @everyone, un rôle
    // ou un tiers. Seul l'auteur du message auquel on répond est prévenu.
    allowed_mentions: { parse: [], replied_user: true },
    ...(opts.replyTo
      ? { message_reference: { message_id: opts.replyTo, fail_if_not_exists: false } }
      : {}),
  });

  if (opts.tags.length > 0) {
    const thread = await api('GET', `/channels/${opts.channel}`);
    const forum = await api('GET', `/channels/${thread.parent_id}`);
    const ids = opts.tags.map((name) => {
      const tag = forum.available_tags?.find((t) => t.name === name);
      if (!tag) throw new Error(`Étiquette inconnue dans ce forum : ${name}`);
      return tag.id;
    });
    // Discord accepte cinq étiquettes par post.
    const applied = [...new Set([...(thread.applied_tags ?? []), ...ids])].slice(-5);
    await api('PATCH', `/channels/${opts.channel}`, { applied_tags: applied });
  }

  console.log(`Posté : message ${message.id} dans le salon ${opts.channel}.`);
}

main().catch((err) => {
  console.error(err.message);
  // `process.exit` coupe les connexions encore ouvertes et fait planter Node
  // sous Windows (assertion libuv) : on laisse le processus finir seul.
  process.exitCode = 1;
});
