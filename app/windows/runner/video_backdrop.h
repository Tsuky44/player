#ifndef RUNNER_VIDEO_BACKDROP_H_
#define RUNNER_VIDEO_BACKDROP_H_

#include <windows.h>

// La fenêtre de mpv glissée sous celle de l'app (ADR-0061).
//
// Le côté Dart (`win32_video_window_io.dart`) dit laquelle et où, par des
// propriétés posées sur la fenêtre de l'app ; ce fichier la recolle à chaque
// fois que Windows déplace, redimensionne, réduit ou remonte l'app.
//
// En natif et non depuis Dart : pendant qu'on fait glisser une fenêtre,
// Windows garde son fil dans une boucle modale et aucune minuterie Dart ne
// tourne. Vu sur le premier essai — seul le chrome suivait la souris, et la
// vidéo se raccrochait au lâcher.
namespace video_backdrop {

// Les noms doivent rester ceux de `Win32VideoWindow` côté Dart.
inline constexpr wchar_t kWindow[] = L"OnyxVideoWindow";
// Les marges de la vidéo dans la vue Flutter, en pixels physiques. Des
// marges et non un rectangle : pendant un redimensionnement, Flutter n'a pas
// encore refait sa mise en page, et la vidéo doit déjà suivre le bord.
inline constexpr wchar_t kLeft[] = L"OnyxVideoLeft";
inline constexpr wchar_t kTop[] = L"OnyxVideoTop";
inline constexpr wchar_t kRight[] = L"OnyxVideoRight";
inline constexpr wchar_t kBottom[] = L"OnyxVideoBottom";

inline int Inset(HWND app, const wchar_t* name) {
  return static_cast<int>(reinterpret_cast<INT_PTR>(GetPropW(app, name)));
}

// La vue Flutter, en coordonnées écran. C'est elle la référence, pas la zone
// cliente de la fenêtre : avec une barre de titre masquée ou une fenêtre
// agrandie, les deux ne coïncident pas forcément.
inline bool ViewArea(HWND app, RECT* area) {
  HWND view = FindWindowExW(app, nullptr, L"FLUTTERVIEW", nullptr);
  if (view != nullptr && GetWindowRect(view, area)) {
    return true;
  }
  POINT origin{0, 0};
  if (!GetClientRect(app, area) || !ClientToScreen(app, &origin)) {
    return false;
  }
  OffsetRect(area, origin.x, origin.y);
  return true;
}

// À appeler sur WM_WINDOWPOSCHANGED de la fenêtre de l'app, une fois le
// message traité : c'est son traitement qui redimensionne la vue Flutter.
inline void Sync(HWND app) {
  HWND video = static_cast<HWND>(GetPropW(app, kWindow));
  if (video == nullptr) {
    return;
  }
  if (!IsWindow(video)) {
    // mpv a fermé sa sortie : la propriété ne désigne plus rien.
    RemovePropW(app, kWindow);
    return;
  }
  if (IsIconic(app)) {
    ShowWindow(video, SW_HIDE);
    return;
  }

  RECT area;
  if (!ViewArea(app, &area)) {
    return;
  }
  const int left = area.left + Inset(app, kLeft);
  const int top = area.top + Inset(app, kTop);
  const int width = area.right - Inset(app, kRight) - left;
  const int height = area.bottom - Inset(app, kBottom) - top;
  if (width <= 0 || height <= 0) {
    return;
  }
  // Juste sous l'app, dans le même message que son propre déplacement.
  SetWindowPos(video, app, left, top, width, height,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
}

}  // namespace video_backdrop

#endif  // RUNNER_VIDEO_BACKDROP_H_
