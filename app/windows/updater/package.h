#pragma once

#include <windows.h>

#include <string>

// Issue d'une mise a jour. Ces valeurs sont aussi le code de sortie du service
// (dwServiceSpecificExitCode) : ne pas les renumeroter.
enum UpdateResult : DWORD {
  kUpdateOk = 0,
  // Paquet absent, illisible, trop gros, ou chemin refuse.
  kUpdateUnreadable = 1,
  // Pas de signature, ou pas la notre.
  kUpdateBadSignature = 2,
  // Version signee inferieure ou egale a celle installee.
  kUpdateNotNewer = 3,
  kUpdateExtractFailed = 4,
  // Un fichier n'a pas pu etre deplace ; tout a ete remis en place.
  kUpdateInUse = 5,
  // Echange ET retour arriere rates : l'installation est a refaire.
  kUpdateBroken = 6,
  // Dossier protege et service absent (installation anterieure au service).
  kUpdateNoService = 7,
  kUpdateServiceFailed = 8,
};

// Chemin de cet executable, et son dossier : celui d'app.exe.
std::wstring ModulePath();
std::wstring ModuleDirectory();

// Verifie le paquet (signature, version) puis remplace le contenu de
// [app_dir] par le sien, avec retour arriere en cas d'echec.
//
// [as_service] : appele par le service SYSTEM au nom d'un utilisateur. Le
// chemin du paquet est alors une donnee hostile, et sa copie de travail est
// gardee hors de portee des utilisateurs.
UpdateResult ApplyUpdate(const std::wstring& package,
                         const std::wstring& app_dir,
                         bool as_service);
