// L'accès à l'API Discord partagé par les scripts de ce dossier.
//
// Le jeton du bot se lit dans DISCORD_BOT_TOKEN, sinon dans
// ~/.onyx/discord-bot-token.txt. Il ne doit jamais entrer dans le dépôt.
// DISCORD_GUILD_ID choisit le serveur si le bot en a rejoint plusieurs.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const API = 'https://discord.com/api/v10';

const token = (
  process.env.DISCORD_BOT_TOKEN ??
  readFileSync(join(homedir(), '.onyx', 'discord-bot-token.txt'), 'utf8')
).trim();

export async function api(method, path, body) {
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

// Le nom affiché porte une icône (« 💬・général », « 🔨 Modérateur ») ; c'est
// le nom nu qui identifie l'objet, pour qu'un changement d'icône renomme au
// lieu de créer un doublon.
export const bare = (name) => name.replace(/^[^\p{L}\p{N}]+/u, '').toLowerCase();

export async function findGuild() {
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
