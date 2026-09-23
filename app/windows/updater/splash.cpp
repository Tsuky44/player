#include "splash.h"

#include <dwmapi.h>

#include <algorithm>
#include <mutex>
#include <string>
#include <thread>

#include "package.h"
#include "resource.h"
#include "service.h"

namespace {

constexpr wchar_t kWindowClass[] = L"OnyxUpdaterSplash";
constexpr UINT kStatusChanged = WM_APP + 1;
constexpr UINT kFinished = WM_APP + 2;
constexpr UINT_PTR kAnimationTimer = 1;

// Les couleurs de l'installeur (installer.iss) : la meme marque, de
// l'installation a la mise a jour.
constexpr COLORREF kBackground = RGB(0x12, 0x14, 0x14);
constexpr COLORREF kText = RGB(0xE8, 0xE6, 0xE4);
constexpr COLORREF kMuted = RGB(0x9A, 0x97, 0x94);
constexpr COLORREF kTrack = RGB(0x2A, 0x2C, 0x2C);

// Dimensions logiques, a 96 dpi.
constexpr int kWidth = 320;
constexpr int kHeight = 300;
constexpr int kIconSize = 96;
constexpr int kBarWidth = 180;
constexpr int kBarHeight = 4;

// Assez pour lire la fenetre, pas assez pour faire attendre : une mise a jour
// rapide ne doit pas se reduire a un clignotement.
constexpr ULONGLONG kMinimumVisibleMs = 1500;
constexpr DWORD kErrorVisibleMs = 4000;

// Pas de DWMWA_WINDOW_CORNER_PREFERENCE / DWMWA_BORDER_COLOR dans les SDK plus
// anciens que Windows 11 : les valeurs brutes, ignorees par Windows 10.
constexpr DWORD kDwmCornerPreference = 33;
constexpr DWORD kDwmBorderColor = 34;
constexpr DWORD kDwmRoundCorners = 2;

struct Status {
  std::wstring title;
  std::wstring detail;
  bool busy = true;
};

std::mutex g_status_mutex;
Status g_status;

HWND g_window = nullptr;
HICON g_icon = nullptr;
HFONT g_title_font = nullptr;
HFONT g_detail_font = nullptr;
UINT g_dpi = USER_DEFAULT_SCREEN_DPI;
ULONGLONG g_shown_at = 0;

int Scale(int value) {
  return MulDiv(value, static_cast<int>(g_dpi), USER_DEFAULT_SCREEN_DPI);
}

void SetStatus(const wchar_t* title, const wchar_t* detail, bool busy) {
  {
    std::lock_guard<std::mutex> lock(g_status_mutex);
    g_status.title = title;
    g_status.detail = detail;
    g_status.busy = busy;
  }
  PostMessageW(g_window, kStatusChanged, 0, 0);
}

void CreateFonts() {
  if (g_title_font) DeleteObject(g_title_font);
  if (g_detail_font) DeleteObject(g_detail_font);
  g_title_font = CreateFontW(-Scale(19), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE,
                             FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                             CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                             DEFAULT_PITCH, L"Segoe UI");
  g_detail_font = CreateFontW(-Scale(13), 0, 0, 0, FW_NORMAL, FALSE, FALSE,
                              FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                              CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                              DEFAULT_PITCH, L"Segoe UI");
}

void LoadIconForDpi(HINSTANCE instance) {
  if (g_icon) DestroyIcon(g_icon);
  const int size = Scale(kIconSize);
  g_icon = static_cast<HICON>(LoadImageW(instance,
                                         MAKEINTRESOURCEW(IDI_APP_ICON),
                                         IMAGE_ICON, size, size, 0));
}

void FillColor(HDC dc, const RECT& rect, COLORREF color) {
  HBRUSH brush = CreateSolidBrush(color);
  FillRect(dc, &rect, brush);
  DeleteObject(brush);
}

// Barre indeterminee : un segment qui traverse la piste, accelere puis
// ralentit, et recommence.
void PaintProgress(HDC dc, const RECT& client) {
  const int width = Scale(kBarWidth);
  const int left = (client.right - width) / 2;
  const int top = Scale(252);
  const RECT track{left, top, left + width, top + Scale(kBarHeight)};
  FillColor(dc, track, kTrack);

  const double t =
      static_cast<double>((GetTickCount64() - g_shown_at) % 1400) / 1400.0;
  const double eased =
      t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) * (-2 * t + 2) / 2;
  const int segment = width * 35 / 100;
  const int x = left - segment + static_cast<int>((width + segment) * eased);
  const RECT fill{std::max(x, left), top, std::min(x + segment, left + width),
                  track.bottom};
  if (fill.right > fill.left) FillColor(dc, fill, kText);
}

void Paint(HWND window) {
  PAINTSTRUCT paint;
  HDC screen = BeginPaint(window, &paint);
  RECT client;
  GetClientRect(window, &client);

  // Double tampon : l'animation redessine toute la fenetre 60 fois par
  // seconde, directement a l'ecran elle scintillerait.
  HDC dc = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateCompatibleBitmap(screen, client.right, client.bottom);
  HGDIOBJ previous_bitmap = SelectObject(dc, bitmap);

  FillColor(dc, client, kBackground);
  const int icon = Scale(kIconSize);
  if (g_icon) {
    DrawIconEx(dc, (client.right - icon) / 2, Scale(44), g_icon, icon, icon, 0,
               nullptr, DI_NORMAL);
  }

  Status status;
  {
    std::lock_guard<std::mutex> lock(g_status_mutex);
    status = g_status;
  }

  SetBkMode(dc, TRANSPARENT);
  HGDIOBJ previous_font = SelectObject(dc, g_title_font);
  SetTextColor(dc, kText);
  RECT title{Scale(16), Scale(162), client.right - Scale(16), Scale(192)};
  DrawTextW(dc, status.title.c_str(), -1, &title,
            DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);

  SelectObject(dc, g_detail_font);
  SetTextColor(dc, kMuted);
  // Sans barre (erreur), le message prend sa place : il tient alors sur
  // trois lignes.
  RECT detail{Scale(28), Scale(198), client.right - Scale(28),
              Scale(status.busy ? 244 : 284)};
  DrawTextW(dc, status.detail.c_str(), -1, &detail,
            DT_CENTER | DT_WORDBREAK | DT_NOPREFIX);

  if (status.busy) PaintProgress(dc, client);

  BitBlt(screen, 0, 0, client.right, client.bottom, dc, 0, 0, SRCCOPY);
  SelectObject(dc, previous_font);
  SelectObject(dc, previous_bitmap);
  DeleteObject(bitmap);
  DeleteDC(dc);
  EndPaint(window, &paint);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  switch (message) {
    case WM_TIMER:
    case kStatusChanged:
      InvalidateRect(window, nullptr, FALSE);
      return 0;
    case WM_PAINT:
      Paint(window);
      return 0;
    case WM_ERASEBKGND:
      return 1;
    case WM_NCHITTEST:
      // Pas de barre de titre : toute la fenetre sert a la deplacer.
      return HTCAPTION;
    case WM_CLOSE:
      // Alt+F4 pendant l'echange des fichiers n'arreterait rien : la fenetre
      // se ferme d'elle-meme une fois Onyx relance.
      return 0;
    case WM_DPICHANGED: {
      g_dpi = HIWORD(wparam);
      CreateFonts();
      LoadIconForDpi(reinterpret_cast<HINSTANCE>(
          GetWindowLongPtrW(window, GWLP_HINSTANCE)));
      const RECT* suggested = reinterpret_cast<const RECT*>(lparam);
      SetWindowPos(window, nullptr, suggested->left, suggested->top,
                   suggested->right - suggested->left,
                   suggested->bottom - suggested->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case kFinished:
      DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      KillTimer(window, kAnimationTimer);
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

bool CreateSplashWindow(HINSTANCE instance) {
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.style = CS_DROPSHADOW;
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = instance;
  window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  window_class.lpszClassName = kWindowClass;
  window_class.hIcon = static_cast<HICON>(LoadImageW(
      instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0));
  window_class.hIconSm = static_cast<HICON>(LoadImageW(
      instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
  if (!RegisterClassExW(&window_class)) return false;

  // Au centre de l'ecran principal, la ou l'app s'ouvre par defaut.
  g_dpi = GetDpiForSystem();
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  const int width = Scale(kWidth);
  const int height = Scale(kHeight);
  const int x = work.left + (work.right - work.left - width) / 2;
  const int y = work.top + (work.bottom - work.top - height) / 2;

  // WS_EX_APPWINDOW : une entree dans la barre des taches, pour que la
  // mise a jour ne ressemble pas a une app qui a disparu.
  g_window = CreateWindowExW(WS_EX_APPWINDOW, kWindowClass, L"Onyx", WS_POPUP,
                             x, y, width, height, nullptr, nullptr, instance,
                             nullptr);
  if (!g_window) return false;

  DwmSetWindowAttribute(g_window, kDwmCornerPreference, &kDwmRoundCorners,
                        sizeof(kDwmRoundCorners));
  const COLORREF border = kBackground;
  DwmSetWindowAttribute(g_window, kDwmBorderColor, &border, sizeof(border));

  CreateFonts();
  LoadIconForDpi(instance);
  g_shown_at = GetTickCount64();
  ShowWindow(g_window, SW_SHOW);
  SetForegroundWindow(g_window);
  UpdateWindow(g_window);
  SetTimer(g_window, kAnimationTimer, 16, nullptr);
  return true;
}

const wchar_t* ErrorMessage(UpdateResult result) {
  switch (result) {
    case kUpdateBadSignature:
      return L"Le paquet téléchargé n’est pas signé "
             L"par Onyx. Onyx redémarre dans sa version actuelle.";
    case kUpdateNotNewer:
      return L"Cette version est déjà installée.";
    case kUpdateInUse:
      return L"Onyx est encore ouvert dans une autre session Windows. "
             L"La mise à jour sera retentée plus tard.";
    case kUpdateBroken:
      return L"L’installation est endommagée. Réinstallez "
             L"Onyx depuis la page de téléchargement.";
    case kUpdateNoService:
      return L"Le service de mise à jour est absent. Réinstallez "
             L"Onyx une fois pour l’ajouter.";
    default:
      return L"La mise à jour a échoué. Onyx redémarre "
             L"dans sa version actuelle.";
  }
}

void WaitForExit(DWORD pid) {
  HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (!process) return;
  WaitForSingleObject(process, 30 * 1000);
  CloseHandle(process);
}

// Un utilisateur standard ne peut pas ecrire dans Program Files : c'est la
// que le service prend le relais. Le ZIP portable, lui, vit dans un dossier a
// l'utilisateur et se met a jour sans service.
bool CanWrite(const std::wstring& dir) {
  const std::wstring probe =
      dir + L"\\.update-probe-" + std::to_wstring(GetCurrentProcessId());
  HANDLE file = CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_NEW,
                            FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  CloseHandle(file);
  return true;
}

struct WindowSearch {
  DWORD pid;
  bool found;
};

BOOL CALLBACK FindVisibleWindow(HWND window, LPARAM lparam) {
  auto* search = reinterpret_cast<WindowSearch*>(lparam);
  DWORD owner = 0;
  GetWindowThreadProcessId(window, &owner);
  if (owner == search->pid && IsWindowVisible(window)) {
    search->found = true;
    return FALSE;
  }
  return TRUE;
}

// Lance depuis ce processus sans console : app.exe, qui se rattache a la
// console de son parent quand il y en a une, n'en trouve aucune. On attend
// que sa fenetre soit visible — le runner ne la montre qu'a la premiere
// image — pour que le passage de l'une a l'autre soit sans trou, comme
// Discord.
void Relaunch(const std::wstring& app_dir) {
  const std::wstring exe = app_dir + L"\\app.exe";
  std::wstring command = L"\"" + exe + L"\"";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE, 0,
                      nullptr, app_dir.c_str(), &startup, &process)) {
    return;
  }
  CloseHandle(process.hThread);
  const ULONGLONG deadline = GetTickCount64() + 20 * 1000;
  WindowSearch search{process.dwProcessId, false};
  while (GetTickCount64() < deadline &&
         WaitForSingleObject(process.hProcess, 100) == WAIT_TIMEOUT) {
    EnumWindows(FindVisibleWindow, reinterpret_cast<LPARAM>(&search));
    if (search.found) break;
  }
  CloseHandle(process.hProcess);
}

UpdateResult g_result = kUpdateServiceFailed;

void Work(std::wstring package, DWORD pid) {
  const std::wstring app_dir = ModuleDirectory();
  WaitForExit(pid);

  g_result = CanWrite(app_dir)
                 ? ApplyUpdate(package, app_dir, /*as_service=*/false)
                 : ApplyThroughService(package);

  if (g_result == kUpdateOk) {
    SetStatus(L"Mise à jour terminée", L"Onyx redémarre…",
              true);
    const ULONGLONG shown = GetTickCount64() - g_shown_at;
    if (shown < kMinimumVisibleMs) {
      Sleep(static_cast<DWORD>(kMinimumVisibleMs - shown));
    }
  } else {
    SetStatus(L"Mise à jour impossible", ErrorMessage(g_result), false);
    Sleep(kErrorVisibleMs);
  }

  // En cas d'echec aussi : l'ancienne version est intacte (sauf installation
  // cassee, ou la relance echoue simplement).
  Relaunch(app_dir);
  PostMessageW(g_window, kFinished, 0, 0);
}

}  // namespace

int RunSplash(HINSTANCE instance, const std::wstring& package, DWORD pid) {
  g_status.title = L"Mise à jour d’Onyx";
  g_status.detail = L"Installation de la nouvelle version…";
  if (!CreateSplashWindow(instance)) {
    // Pas de fenetre : la mise a jour se fait quand meme, sans rien montrer.
    Work(package, pid);
    return g_result == kUpdateOk ? 0 : 1;
  }

  std::thread worker(Work, package, pid);
  MSG message;
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  worker.join();
  return g_result == kUpdateOk ? 0 : 1;
}
