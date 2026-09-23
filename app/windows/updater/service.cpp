#include "service.h"

#include <windows.h>
#include <sddl.h>

namespace {

constexpr wchar_t kServiceName[] = L"OnyxUpdater";
constexpr wchar_t kDisplayName[] = L"Onyx – mise à jour";
constexpr wchar_t kDescription[] =
    L"Installe les mises à jour d’Onyx sans demander les droits "
    L"administrateur. Démarré uniquement pendant une mise à jour.";

// Droits par defaut d'un service, plus le demarrage (RP) pour tout
// utilisateur authentifie (AU). Arreter, reconfigurer ou supprimer reste
// reserve aux administrateurs. Ce que l'utilisateur peut demander au service
// est borne par ApplyUpdate : un paquet signe, plus recent, dans le dossier
// du service.
constexpr wchar_t kServiceSddl[] =
    L"D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)"
    L"(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)"
    L"(A;;CCLCSWRPLOCRRC;;;AU)";

SERVICE_STATUS_HANDLE g_status_handle = nullptr;

void ReportStatus(DWORD state, UpdateResult result) {
  SERVICE_STATUS status{};
  status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  status.dwCurrentState = state;
  // Aucun controle accepte : interrompre un echange de fichiers a mi-chemin
  // serait pire que de le laisser finir.
  status.dwControlsAccepted = 0;
  if (state == SERVICE_STOPPED && result != kUpdateOk) {
    status.dwWin32ExitCode = ERROR_SERVICE_SPECIFIC_ERROR;
    status.dwServiceSpecificExitCode = result;
  }
  SetServiceStatus(g_status_handle, &status);
}

DWORD WINAPI HandleControl(DWORD control, DWORD, void*, void*) {
  return control == SERVICE_CONTROL_INTERROGATE ? NO_ERROR
                                                : ERROR_CALL_NOT_IMPLEMENTED;
}

// argv[1] : le paquet, passe par StartService. Le dossier a mettre a jour
// n'est jamais un argument : c'est celui de l'executable du service.
void WINAPI ServiceMain(DWORD argc, wchar_t** argv) {
  g_status_handle =
      RegisterServiceCtrlHandlerExW(kServiceName, HandleControl, nullptr);
  if (!g_status_handle) return;
  ReportStatus(SERVICE_RUNNING, kUpdateOk);
  UpdateResult result = kUpdateUnreadable;
  if (argc >= 2 && argv[1] != nullptr) {
    result = ApplyUpdate(argv[1], ModuleDirectory(), /*as_service=*/true);
  }
  ReportStatus(SERVICE_STOPPED, result);
}

}  // namespace

int RunService() {
  SERVICE_TABLE_ENTRYW table[] = {
      {const_cast<wchar_t*>(kServiceName), ServiceMain},
      {nullptr, nullptr},
  };
  return StartServiceCtrlDispatcherW(table) ? 0 : 1;
}

int InstallService() {
  SC_HANDLE manager = OpenSCManagerW(
      nullptr, nullptr, SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
  if (!manager) return 1;

  const std::wstring command = L"\"" + ModulePath() + L"\" service";
  constexpr DWORD kAccess = SERVICE_CHANGE_CONFIG | WRITE_DAC | READ_CONTROL;
  // Deja la (mise a jour par Inno) : on remet sa configuration d'aplomb, le
  // chemin de l'exe a pu changer si l'app a ete deplacee.
  SC_HANDLE service = OpenServiceW(manager, kServiceName, kAccess);
  if (service) {
    ChangeServiceConfigW(service, SERVICE_WIN32_OWN_PROCESS,
                         SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL,
                         command.c_str(), nullptr, nullptr, nullptr, nullptr,
                         nullptr, kDisplayName);
  } else {
    // Compte nul : LocalSystem.
    service = CreateServiceW(manager, kServiceName, kDisplayName, kAccess,
                             SERVICE_WIN32_OWN_PROCESS, SERVICE_DEMAND_START,
                             SERVICE_ERROR_NORMAL, command.c_str(), nullptr,
                             nullptr, nullptr, nullptr, nullptr);
  }
  CloseServiceHandle(manager);
  if (!service) return 1;

  SERVICE_DESCRIPTIONW description{const_cast<wchar_t*>(kDescription)};
  ChangeServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, &description);

  bool secured = false;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
          kServiceSddl, SDDL_REVISION_1, &descriptor, nullptr)) {
    secured = SetServiceObjectSecurity(service, DACL_SECURITY_INFORMATION,
                                       descriptor) != 0;
    LocalFree(descriptor);
  }
  CloseServiceHandle(service);
  return secured ? 0 : 1;
}

int UninstallService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) return 1;
  SC_HANDLE service = OpenServiceW(manager, kServiceName, DELETE);
  const DWORD error = GetLastError();
  CloseServiceHandle(manager);
  if (!service) return error == ERROR_SERVICE_DOES_NOT_EXIST ? 0 : 1;
  // Jamais en cours d'execution hors d'une mise a jour ; s'il l'est, la
  // suppression prend effet a son arret.
  const bool deleted = DeleteService(service) != 0;
  CloseServiceHandle(service);
  return deleted ? 0 : 1;
}

UpdateResult ApplyThroughService(const std::wstring& package) {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) return kUpdateNoService;
  SC_HANDLE service = OpenServiceW(manager, kServiceName,
                                   SERVICE_START | SERVICE_QUERY_STATUS);
  CloseServiceHandle(manager);
  if (!service) return kUpdateNoService;

  // Une autre session peut etre en train de s'en servir : on attend son tour.
  const wchar_t* args[] = {package.c_str()};
  bool started = false;
  const ULONGLONG start_deadline = GetTickCount64() + 2 * 60 * 1000;
  while (!started && GetTickCount64() < start_deadline) {
    if (StartServiceW(service, 1, args)) {
      started = true;
    } else if (GetLastError() == ERROR_SERVICE_ALREADY_RUNNING) {
      Sleep(500);
    } else {
      break;
    }
  }

  UpdateResult result = kUpdateServiceFailed;
  if (started) {
    SERVICE_STATUS status{};
    const ULONGLONG deadline = GetTickCount64() + 10 * 60 * 1000;
    while (QueryServiceStatus(service, &status) &&
           status.dwCurrentState != SERVICE_STOPPED &&
           GetTickCount64() < deadline) {
      Sleep(200);
    }
    if (status.dwCurrentState == SERVICE_STOPPED) {
      if (status.dwWin32ExitCode == NO_ERROR) {
        result = kUpdateOk;
      } else if (status.dwWin32ExitCode == ERROR_SERVICE_SPECIFIC_ERROR) {
        result = static_cast<UpdateResult>(status.dwServiceSpecificExitCode);
      }
    }
  }
  CloseServiceHandle(service);
  return result;
}
