// onyx-updater.exe : les mises a jour Windows d'Onyx, sans console et sans
// demande de droits administrateur. Voir docs/adr/0030.
//
//   apply --package <zip> --pid <pid>   lance par l'app, avant qu'elle quitte
//   service                             lance par le SCM
//   install-service / uninstall-service lances par l'installeur Inno

#include <windows.h>
#include <shellapi.h>

#include <cwchar>
#include <string>

#include "service.h"
#include "splash.h"

namespace {

// Valeur qui suit [flag] sur la ligne de commande, ou "".
std::wstring FlagValue(int argc, wchar_t** argv, const wchar_t* flag) {
  for (int i = 2; i + 1 < argc; ++i) {
    if (wcscmp(argv[i], flag) == 0) return argv[i + 1];
  }
  return std::wstring();
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE,
                      _In_ wchar_t*, _In_ int) {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return 1;

  int exit_code = 1;
  const std::wstring mode = argc >= 2 ? argv[1] : L"";
  if (mode == L"service") {
    exit_code = RunService();
  } else if (mode == L"install-service") {
    exit_code = InstallService();
  } else if (mode == L"uninstall-service") {
    exit_code = UninstallService();
  } else if (mode == L"apply") {
    const std::wstring package = FlagValue(argc, argv, L"--package");
    const DWORD pid = wcstoul(FlagValue(argc, argv, L"--pid").c_str(), nullptr, 10);
    if (!package.empty()) exit_code = RunSplash(instance, package, pid);
  }

  LocalFree(argv);
  return exit_code;
}
