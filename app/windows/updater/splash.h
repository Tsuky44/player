#pragma once

#include <windows.h>

#include <string>

// `onyx-updater.exe apply` : lance par l'app juste avant qu'elle quitte.
// Affiche la petite fenetre « Mise a jour d'Onyx », attend la fin de [pid],
// applique [package] — directement si le dossier est inscriptible (ZIP
// portable), par le service sinon — puis relance Onyx et se ferme des que sa
// fenetre apparait.
int RunSplash(HINSTANCE instance, const std::wstring& package, DWORD pid);
