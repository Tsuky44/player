#pragma once

#include <string>

#include "package.h"

// Le service OnyxUpdater (ADR-0030) : installe par Inno, en SYSTEM, demarre a
// la demande par n'importe quel utilisateur pour appliquer un paquet signe
// dans Program Files — c'est ce qui evite la demande de droits admin.

// Point d'entree quand le SCM lance `onyx-updater.exe service`.
int RunService();

// Appeles par l'installeur Inno, deja eleve.
int InstallService();
int UninstallService();

// Cote utilisateur : demarre le service sur [package] et attend son verdict.
UpdateResult ApplyThroughService(const std::wstring& package);
